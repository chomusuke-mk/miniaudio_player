//! High-performance Polyphonic Voice Pool with SIMD mixing, LRU RAM eviction,
//! pinned buffer protection, 3D Spatial Audio & Doppler, and dynamic DSP routing.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use crate::sync::MonotonicInstant as Instant;

#[cfg(unix)]
use crate::buffer::FdOpenOutcome;
use crate::buffer::{DartResolveRegistry, ResolvedCoreSource};
use crate::core::dual_source::AudioSourceCore;
use crate::dsp::spatial::{SpatialEmitter, SpatialListener, SpatialProcessor};
pub use crate::dsp::voice_pool::{pseudo_random_jitter, SoundBuffer, VoiceStealingPolicy};
use crate::net::ureq;

/// Classifies an [`AudioSourceCore`] `source` into its cache retention [`EffectSourceType`].
#[inline]
pub(crate) fn classify_source_type(source: &AudioSourceCore) -> EffectSourceType {
    let is_memory = source.data_bytes.as_ref().is_some_and(|b| !b.is_empty());
    if is_memory {
        return EffectSourceType::Memory;
    }
    let trimmed = source.source.trim();
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        EffectSourceType::Network
    } else {
        EffectSourceType::LocalFile
    }
}

/// Computes left/right spatial attenuation gains and Doppler pitch multiplier from `emitter`, `listener`, `speed_of_sound`, and fallback stereo `balance`.
#[inline]
pub(crate) fn compute_spatial_and_doppler(
    emitter: Option<&SpatialEmitter>,
    listener: &SpatialListener,
    speed_of_sound: f32,
    balance: f32,
) -> (f32, f32, f64) {
    if let Some(em) = emitter {
        let eval = SpatialProcessor::evaluate(listener, em, speed_of_sound);
        let gl = if eval.pan > 0.0 {
            (1.0 - eval.pan) * eval.gain
        } else {
            eval.gain
        };
        let gr = if eval.pan < 0.0 {
            (1.0 + eval.pan) * eval.gain
        } else {
            eval.gain
        };
        (gl, gr, eval.doppler_ratio as f64)
    } else {
        let gl = if balance > 0.0 { 1.0 - balance } else { 1.0 };
        let gr = if balance < 0.0 { 1.0 + balance } else { 1.0 };
        (gl, gr, 1.0)
    }
}

/// Mutable per-voice playback state borrowed during [`render_voice_buffer`].
pub(crate) struct VoiceRenderState<'a> {
    /// Whether the voice slot remains active.
    pub active: &'a mut bool,
    /// Fractional playback cursor in source frames.
    pub cursor_frame: &'a mut f64,
    /// Whether the voice is currently ramping down to stop.
    pub stopping: &'a mut bool,
    /// Remaining fade-out frames when `stopping` is true.
    pub fade_samples_remaining: &'a mut usize,
    /// Initial fade-out duration in frames used to normalize linear ramp gain.
    pub total_fade_samples: usize,
    /// Total frames rendered since this voice started.
    pub age_frames: &'a mut u64,
}

/// Renders up to `frame_count` interleaved frames of `buf` into `target_out` across `channels`
/// at output `sample_rate`, updating `state` with `volume`, `pitch`, `balance`, `looping`,
/// optional `emitter`, `listener`, and `speed_of_sound`.
///
/// Returns `true` if the voice finished playback or completed its fade-out during this pass.
#[inline]
#[allow(clippy::too_many_arguments)]
pub(crate) fn render_voice_buffer(
    state: VoiceRenderState<'_>,
    buf: &SoundBuffer,
    volume: f32,
    pitch: f32,
    balance: f32,
    looping: bool,
    emitter: Option<&SpatialEmitter>,
    listener: &SpatialListener,
    speed_of_sound: f32,
    target_out: &mut [f32],
    frame_count: usize,
    channels: usize,
    sample_rate: f64,
) -> bool {
    let total_frames = buf.frame_count();
    if total_frames == 0 {
        *state.active = false;
        return false;
    }

    let (spatial_gain_l, spatial_gain_r, doppler_ratio) =
        compute_spatial_and_doppler(emitter, listener, speed_of_sound, balance);
    let step = (pitch as f64 * (buf.sample_rate as f64 / sample_rate)) * doppler_ratio;

    for k in 0..frame_count {
        let Some((f0, f1_clamped, frac)) =
            SoundBuffer::resolve_lerp_indices(state.cursor_frame, total_frames, looping)
        else {
            *state.active = false;
            return true;
        };

        let (sl, sr) = buf.sample_stereo_lerp(f0, f1_clamped, frac);

        let fade_gain = if *state.stopping {
            if *state.fade_samples_remaining == 0 {
                *state.active = false;
                return true;
            }
            let denom = state.total_fade_samples.max(1) as f32;
            let g = *state.fade_samples_remaining as f32 / denom;
            *state.fade_samples_remaining -= 1;
            g
        } else {
            1.0
        };

        let effective_vol = volume * fade_gain;
        let out_l = sl * effective_vol * spatial_gain_l;
        let out_r = sr * effective_vol * spatial_gain_r;

        if channels == 1 {
            target_out[k] += (out_l + out_r) * 0.5;
        } else {
            target_out[k * channels] += out_l;
            target_out[k * channels + 1] += out_r;
        }

        *state.cursor_frame += step;
        *state.age_frames += 1;
    }

    false
}

/// Source backing classification used by the multi-factor RAM eviction algorithm.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EffectSourceType {
    /// In-memory bytes (`MemoryAudioSource`): immune to eviction (`SourceWeight = inf`).
    Memory,
    /// Network HTTP/HTTPS URI: high cost to re-fetch (`SourceWeight = 5.0`).
    Network,
    /// Local file path: fast to re-read from disk (`SourceWeight = 1.0`).
    LocalFile,
}

impl EffectSourceType {
    /// Returns the source weight multiplier for the multi-factor retention score formula.
    #[inline]
    pub fn source_weight(self) -> f64 {
        match self {
            EffectSourceType::Memory => f64::INFINITY,
            EffectSourceType::Network => 5.0,
            EffectSourceType::LocalFile => 1.0,
        }
    }
}

/// Declarative sound effect descriptor passed to [`VoicePool::set_effects`].
#[derive(Debug, Clone)]
pub struct EffectCatalogItem {
    /// Unique identifier for the sound effect.
    pub id: String,
    /// Underlying audio source descriptor (memory bytes, local file path, or network URL).
    pub source: AudioSourceCore,
    /// Maximum concurrent voices allowed for this specific effect.
    pub max_polyphony: usize,
    /// Whether this effect is pinned in RAM and exempt from automatic eviction.
    pub pinned: bool,
}

/// Maximum concurrent polyphonic voices rendered by the pool.
pub const MAX_VOICES: usize = 64;

/// DSP routing policies for polyphonic sound effect voices.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DspRouting {
    /// Voice is mixed with the music bus and shares the master music DSP chain (default).
    Inherit = 0,
    /// Voice undergoes isolated dedicated DSP processing without affecting music.
    Isolate = 1,
    /// Voice bypasses all DSP processing and sums directly into the master output.
    Bypass = 2,
}

impl From<i32> for DspRouting {
    fn from(val: i32) -> Self {
        match val {
            1 => DspRouting::Isolate,
            2 => DspRouting::Bypass,
            _ => DspRouting::Inherit,
        }
    }
}

/// Dynamic playback parameters applied when triggering a sound effect voice.
#[derive(Debug, Clone)]
pub struct EffectConfig {
    /// Playback volume factor (0.0 to 2.0).
    pub volume: f32,
    /// Stereo panning balance (-1.0 to 1.0).
    pub balance: f32,
    /// Pitch shift multiplier (0.5 to 2.0).
    pub pitch: f32,
    /// Speed rate multiplier (0.5 to 2.0).
    pub rate: f32,
    /// Whether this voice should loop continuously.
    pub looping: bool,
    /// Voice stealing priority (0..255).
    pub priority: u8,
    /// Randomized pitch jitter range to reduce fatigue.
    pub pitch_jitter: f32,
    /// Randomized volume jitter range to reduce fatigue.
    pub volume_jitter: f32,
    /// Optional 3D spatial emitter parameters.
    pub spatial: Option<SpatialEmitter>,
    /// DSP routing mode (Inherit, Isolate, or Bypass).
    pub dsp_routing: DspRouting,
}

impl Default for EffectConfig {
    fn default() -> Self {
        Self {
            volume: 1.0,
            balance: 0.0,
            pitch: 1.0,
            rate: 1.0,
            looping: false,
            priority: 128,
            pitch_jitter: 0.0,
            volume_jitter: 0.0,
            spatial: None,
            dsp_routing: DspRouting::Inherit,
        }
    }
}

/// Registered sound effect metadata and optional resident PCM buffer.
pub struct RegisteredEffect {
    /// Unique identifier for this sound effect.
    pub id: String,
    /// Underlying source descriptor used for lazy decode or reload after eviction.
    pub source: AudioSourceCore,
    /// Retention classification governing eviction eligibility and weight.
    pub source_type: EffectSourceType,
    /// Resident decoded PCM buffer when cached in RAM.
    pub buffer: Option<SoundBuffer>,
    /// Maximum concurrent voices allowed for this effect.
    pub max_polyphony: usize,
    /// Whether this effect is pinned in RAM and exempt from LRU eviction.
    pub pinned: bool,
    /// Byte footprint of `buffer` currently counted against RAM budget.
    pub byte_size: usize,
    /// Total times this effect has been triggered.
    pub trigger_count: u64,
    /// Timestamp of the most recent voice trigger or completion.
    pub last_used: Instant,
    /// Number of non-stopping voices currently playing this effect.
    pub active_voices: usize,
}

impl RegisteredEffect {
    /// Returns whether this effect's decoded PCM buffer can be evicted from RAM.
    ///
    /// Memory-backed effects (`EffectSourceType::Memory`), pinned effects, and effects
    /// with active playing voices are strictly immune to eviction.
    #[inline]
    pub fn is_evictable(&self) -> bool {
        self.buffer.is_some()
            && !self.pinned
            && self.source_type != EffectSourceType::Memory
            && self.active_voices == 0
    }

    /// Computes the multi-factor retention score at timestamp `now`:
    /// `Score = SourceWeight * (1 + TriggerFrequency) * (1 / (1 + dt_seconds))`
    #[inline]
    pub fn retention_score(&self, now: Instant) -> f64 {
        if self.source_type == EffectSourceType::Memory || self.pinned {
            return f64::INFINITY;
        }
        let weight = self.source_type.source_weight();
        let freq = self.trigger_count as f64;
        let dt_seconds = now.saturating_duration_since(self.last_used).as_secs_f64();
        weight * (1.0 + freq) * (1.0 / (1.0 + dt_seconds))
    }
}

/// Applies deterministic proportional jitter of magnitude `jitter_amount` to `base` using `seed` and `salt`.
#[inline]
pub fn apply_jitter(base: f32, jitter_amount: f32, seed: u32, salt: u32) -> f32 {
    if jitter_amount <= 0.0 {
        base
    } else {
        let rand_val = pseudo_random_jitter(seed, salt);
        base * (1.0 + rand_val * jitter_amount)
    }
}

/// Fetches raw encoded bytes for network sound effect `id` from `url` with optional HTTP `headers`.
///
/// # Errors
///
/// Returns an error string if the HTTP request or response body read fails.
fn fetch_effect_bytes_via_ureq(
    id: &str,
    url: &str,
    headers: Option<&[crate::api::types::RustHttpHeader]>,
) -> Result<Vec<u8>, String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_connect(Some(std::time::Duration::from_secs(5)))
        .timeout_recv_response(Some(std::time::Duration::from_secs(10)))
        .timeout_per_read(Some(std::time::Duration::from_secs(10)))
        .max_idle_connections(0)
        .build()
        .into();
    let mut req = agent.get(url);
    if let Some(hdrs) = headers {
        for h in hdrs {
            req = req.header(&h.key, &h.value);
        }
    }
    let resp = req.call().map_err(|e| {
        let msg = format!("Failed to fetch network effect '{}' ({}): {}", id, url, e);
        crate::map_log!(1, "[VOICE_POOL] {}", msg);
        msg
    })?;
    let mut bytes = Vec::new();
    use std::io::Read;
    resp.into_body()
        .into_reader()
        .read_to_end(&mut bytes)
        .map_err(|e| {
            let msg = format!("Failed to read network effect '{}' bytes: {}", id, e);
            crate::map_log!(1, "[VOICE_POOL] {}", msg);
            msg
        })?;
    crate::map_log!(
        4,
        "[VOICE_POOL] Fetched network effect '{}' ({} bytes) from {}",
        id,
        bytes.len(),
        url
    );
    Ok(bytes)
}

/// Decodes an [`AudioSourceCore`] `source` for effect `id` into a PCM [`SoundBuffer`], resolving
/// `resolve_in_dart` sources via `dart_resolver` when needed.
///
/// # Errors
///
/// Returns an error string if Dart resolution, file/network reading, or audio decoding fails.
pub fn decode_effect_source(
    id: &str,
    source: &AudioSourceCore,
    dart_resolver: Option<&Arc<DartResolveRegistry>>,
) -> Result<SoundBuffer, String> {
    if let Some(ref bytes) = source.data_bytes {
        if !bytes.is_empty() {
            crate::map_log!(
                4,
                "[VOICE_POOL] Decoding memory effect '{}' ({} bytes)",
                id,
                bytes.len()
            );
            return SoundBuffer::decode_from_bytes(bytes).map_err(|e| {
                let msg = format!("Decoding memory effect '{}' failed: {}", id, e);
                crate::map_log!(1, "[VOICE_POOL] {}", msg);
                msg
            });
        }
    }

    if source.resolve_in_dart {
        let resolver = dart_resolver.ok_or_else(|| {
            let msg = format!(
                "Effect '{}' requires Dart resolution for '{}' which is unavailable",
                id, source.source
            );
            crate::map_log!(1, "[VOICE_POOL] {}", msg);
            msg
        })?;
        crate::map_log!(
            4,
            "[VOICE_POOL] Resolving effect '{}' via Dart resolver: {}",
            id,
            source.source
        );
        let resolved = resolver
            .resolve(&source.source, source.headers.as_deref(), None)
            .map_err(|f| {
                let msg = format!("Resolving effect '{}' failed: {} (code: {})", id, f.message, f.code);
                crate::map_log!(1, "[VOICE_POOL] {}", msg);
                msg
            })?;
        return match resolved {
            ResolvedCoreSource::Path(path) => decode_effect_uri_direct(id, &path, source.headers.as_deref()),
            ResolvedCoreSource::Url(url) => decode_effect_uri_direct(id, &url, source.headers.as_deref()),
            ResolvedCoreSource::Bytes { data, hint_ext } => {
                SoundBuffer::decode_from_owned_bytes(data, hint_ext.as_deref())
                    .map_err(|e| {
                        let msg = format!("Decoding effect '{}' failed: {}", id, e);
                        crate::map_log!(1, "[VOICE_POOL] {}", msg);
                        msg
                    })
            }
            #[cfg(unix)]
            ResolvedCoreSource::Fd {
                file,
                offset,
                length,
                hint_ext,
            } => match ResolvedCoreSource::open_fd_slice(file, offset, length) {
                Ok(FdOpenOutcome::Seekable(byte_src)) => {
                    SoundBuffer::decode_from_media_source(byte_src, hint_ext.as_deref())
                        .map_err(|e| {
                            let msg = format!("Decoding FD effect '{}' failed: {}", id, e);
                            crate::map_log!(1, "[VOICE_POOL] {}", msg);
                            msg
                        })
                }
                Ok(FdOpenOutcome::MemoryBytes(bytes)) => {
                    SoundBuffer::decode_from_owned_bytes(bytes, hint_ext.as_deref())
                        .map_err(|e| {
                            let msg = format!("Decoding pipe FD effect '{}' failed: {}", id, e);
                            crate::map_log!(1, "[VOICE_POOL] {}", msg);
                            msg
                        })
                }
                Err(e) => {
                    let msg = format!("Opening FD effect '{}' failed: {}", id, e);
                    crate::map_log!(1, "[VOICE_POOL] {}", msg);
                    Err(msg)
                }
            },
            #[cfg(not(unix))]
            ResolvedCoreSource::Fd { .. } => {
                Err("POSIX file descriptors are only supported on Unix targets (code: -10)".to_string())
            }
            ResolvedCoreSource::CustomStream { .. } => Err(format!(
                "CustomStream/WebSocket sources are not supported as buffered RAM SFX for '{}' (code: -10)",
                id
            )),
            ResolvedCoreSource::Error { code, message } => {
                let msg = format!("{} (code: {})", message, code);
                crate::map_log!(1, "[VOICE_POOL] Dart resolver error for '{}': {}", id, msg);
                Err(msg)
            }
        };
    }

    decode_effect_uri_direct(id, source.source.trim(), source.headers.as_deref())
}

/// Decodes effect `id` directly from a normalized URI or filesystem path `trimmed` with optional HTTP `headers`.
///
/// # Errors
///
/// Returns an error string if the URI scheme is unsupported, I/O fails, or audio decoding fails.
fn decode_effect_uri_direct(
    id: &str,
    trimmed: &str,
    headers: Option<&[crate::api::types::RustHttpHeader]>,
) -> Result<SoundBuffer, String> {
    #[cfg(target_arch = "wasm32")]
    {
        if trimmed.starts_with("http://")
            || trimmed.starts_with("https://")
            || trimmed.starts_with("blob:")
            || trimmed.starts_with("data:")
        {
            let bytes = fetch_effect_bytes_via_ureq(id, trimmed, headers)?;
            return SoundBuffer::decode_from_owned_bytes(bytes, None).map_err(|e| {
                let msg = format!("Decoding effect '{}' failed: {}", id, e);
                crate::map_log!(1, "[VOICE_POOL] {}", msg);
                msg
            });
        }
        if let Some(scheme) = crate::opfs::extract_uri_scheme(trimmed) {
            if !scheme.eq_ignore_ascii_case("opfs") {
                let msg = format!(
                    "Unsupported URI scheme '{}://' for Web effect '{}' (code: -10)",
                    scheme, id
                );
                crate::map_log!(1, "[VOICE_POOL] {}", msg);
                return Err(msg);
            }
        }
        let parsed = crate::opfs::parse_opfs_path_strict(trimmed)
            .map_err(|(code, msg)| format!("{} (code: {})", msg, code))?;
        if parsed.had_opfs_prefix {
            crate::map_log!(
                3,
                "[VOICE_POOL] The 'opfs://' prefix in '{}' is unnecessary on Web: relative and \
                 absolute paths resolve automatically to OPFS ('{}')",
                trimmed,
                parsed.canonical
            );
        }
        let ext_hint = crate::decoder::StreamClassifier::extract_extension_hint(&parsed.canonical);
        let opfs_src = crate::opfs::OpfsByteSource::open(&parsed.canonical).map_err(|(code, msg)| {
            let err = format!("{} (code: {})", msg, code);
            crate::map_log!(1, "[VOICE_POOL] Failed opening OPFS effect '{}': {}", id, err);
            err
        })?;
        SoundBuffer::decode_from_media_source(opfs_src, ext_hint).map_err(|e| {
            let msg = format!("Decoding OPFS effect '{}' failed: {}", id, e);
            crate::map_log!(1, "[VOICE_POOL] {}", msg);
            msg
        })
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        if crate::opfs::extract_uri_scheme(trimmed)
            .is_some_and(|s| s.eq_ignore_ascii_case("opfs"))
        {
            let msg = format!(
                "URI scheme 'opfs://' ('{}') for effect '{}' is only supported on Web (code: -10)",
                trimmed, id
            );
            crate::map_log!(1, "[VOICE_POOL] {}", msg);
            return Err(msg);
        }
        if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
            let bytes = fetch_effect_bytes_via_ureq(id, trimmed, headers)?;
            return SoundBuffer::decode_from_owned_bytes(bytes, None).map_err(|e| {
                let msg = format!("Decoding network effect '{}' failed: {}", id, e);
                crate::map_log!(1, "[VOICE_POOL] {}", msg);
                msg
            });
        }

        crate::map_log!(4, "[VOICE_POOL] Reading local effect '{}' from '{}'", id, trimmed);
        let bytes = std::fs::read(trimmed).map_err(|e| {
            let msg = format!("Failed to read effect file '{}' for '{}': {}", trimmed, id, e);
            crate::map_log!(1, "[VOICE_POOL] {}", msg);
            msg
        })?;
        SoundBuffer::decode_from_owned_bytes(bytes, None).map_err(|e| {
            let msg = format!("Decoding effect '{}' failed: {}", id, e);
            crate::map_log!(1, "[VOICE_POOL] {}", msg);
            msg
        })
    }
}

// ============================================================================
// Decoupled Real-Time (`VoicePoolRt`) & Cold (`EffectCatalog`) SFX Architecture
// ============================================================================

/// Wait-free atomic telemetry counters shared between [`EffectCatalog`] and [`VoicePoolRt`].
pub struct SharedVoiceMetrics {
    /// Monotonic command sequence counter assigned to cold-path state mutations.
    cmd_seq: AtomicU64,
    /// Packed `(seq: u48 << 16) | (active_count: u16)` allowing wait-free reads consistent with
    /// synchronous command issuance before the RT thread drains the command ring.
    packed_active: AtomicU64,
    /// Flag raised by the RT thread when completion notifications await draining.
    pending_done: AtomicBool,
    /// Total decoded sound effect PCM bytes currently resident in RAM.
    allocated_ram_bytes: AtomicUsize,
}

impl Default for SharedVoiceMetrics {
    fn default() -> Self {
        Self::new()
    }
}

impl SharedVoiceMetrics {
    /// Creates zero-initialized voice metrics.
    pub fn new() -> Self {
        Self {
            cmd_seq: AtomicU64::new(0),
            packed_active: AtomicU64::new(0),
            pending_done: AtomicBool::new(false),
            allocated_ram_bytes: AtomicUsize::new(0),
        }
    }

    /// Atomically allocates and returns the next monotonic command sequence number.
    #[inline]
    pub fn next_seq(&self) -> u64 {
        self.cmd_seq.fetch_add(1, Ordering::AcqRel) + 1
    }

    /// Publishes an optimistic active voice `count` tagged with sequence `seq` from the cold path.
    #[inline]
    pub fn publish_cold_count(&self, seq: u64, count: u16) {
        let packed = (seq << 16) | (count as u64);
        self.packed_active.store(packed, Ordering::Release);
    }

    /// Reconciles `live_count` from the RT thread only when no newer `last_rt_seq` command is in flight.
    #[inline]
    pub fn reconcile_rt_count(&self, last_rt_seq: u64, live_count: u16) {
        let cur = self.packed_active.load(Ordering::Acquire);
        if (cur >> 16) == last_rt_seq {
            let desired = (last_rt_seq << 16) | (live_count as u64);
            let _ = self.packed_active.compare_exchange(
                cur,
                desired,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
    }

    /// Returns the currently visible count of active non-stopping voices.
    #[inline]
    pub fn active_voices_count(&self) -> u32 {
        (self.packed_active.load(Ordering::Acquire) & 0xFFFF) as u32
    }

    /// Returns the total bytes of decoded PCM buffers resident in RAM.
    #[inline]
    pub fn allocated_ram_bytes(&self) -> usize {
        self.allocated_ram_bytes.load(Ordering::Acquire)
    }

    /// Updates the tracked resident PCM RAM usage in `bytes`.
    #[inline]
    pub fn set_allocated_ram_bytes(&self, bytes: usize) {
        self.allocated_ram_bytes.store(bytes, Ordering::Release);
    }

    /// Marks that one or more [`RtVoiceDone`] events have been pushed to the completion ring.
    #[inline]
    pub fn mark_pending_done(&self) {
        self.pending_done.store(true, Ordering::Release);
    }

    /// Returns `true` when RT voice completion events may be waiting in the ring buffer.
    #[inline]
    pub fn has_pending_done(&self) -> bool {
        self.pending_done.load(Ordering::Acquire)
    }

    /// Clears the pending completion notification flag prior to draining `done_rx`.
    #[inline]
    pub fn clear_pending_done(&self) {
        self.pending_done.store(false, Ordering::Release);
    }
}

/// Real-time SFX completion notification pushed from [`VoicePoolRt`] to [`EffectCatalog`].
#[derive(Debug, Clone, Copy)]
pub struct RtVoiceDone {
    /// Voice identifier that finished, faded out, or was stopped/stolen.
    pub voice_id: u32,
    /// Stable catalog entry key owning this voice when triggered.
    pub effect_key: u64,
}

/// Lock-free commands dispatched from control/API threads to [`VoicePoolRt`].
pub enum RtVoiceCmd {
    /// Starts rendering a voice using an owned `Arc<[f32]>` [`SoundBuffer`] handle.
    Start {
        /// Monotonic sequence number for metrics reconciliation.
        seq: u64,
        /// Unique voice instance identifier.
        voice_id: u32,
        /// Stable catalog entry key owning `buffer`.
        effect_key: u64,
        /// Pre-decoded PCM sound buffer.
        buffer: SoundBuffer,
        /// Linear playback volume multiplier.
        volume: f32,
        /// Pitch multiplier.
        pitch: f32,
        /// Stereo pan balance (`-1.0` to `1.0`).
        balance: f32,
        /// Voice stealing priority (`0..=255`).
        priority: u8,
        /// Whether playback loops indefinitely.
        looping: bool,
        /// Target DSP mixing bus routing.
        dsp_routing: DspRouting,
        /// Optional 3D spatial emitter configuration.
        emitter: Option<SpatialEmitter>,
    },
    /// Stops an active voice immediately (`fade_out_samples == 0`) or with a linear ramp.
    StopVoice {
        /// Monotonic sequence number for metrics reconciliation.
        seq: u64,
        /// Identifier of the voice to stop.
        voice_id: u32,
        /// Linear fade-out duration in frames (`0` for immediate stop).
        fade_out_samples: usize,
    },
    /// Stops all active voices immediately (`fade_out_samples == 0`) or with a linear ramp.
    StopAll {
        /// Monotonic sequence number for metrics reconciliation.
        seq: u64,
        /// Linear fade-out duration in frames (`0` for immediate stop).
        fade_out_samples: usize,
    },
    /// Updates playback volume on a live voice.
    SetVolume {
        /// Target active voice identifier.
        voice_id: u32,
        /// New linear volume multiplier.
        volume: f32,
    },
    /// Updates pitch multiplier on a live voice.
    SetPitch {
        /// Target active voice identifier.
        voice_id: u32,
        /// New pitch multiplier (`> 0.0`).
        pitch: f32,
    },
    /// Updates stereo pan balance on a live voice.
    SetBalance {
        /// Target active voice identifier.
        voice_id: u32,
        /// New stereo pan balance (`-1.0` to `1.0`).
        balance: f32,
    },
    /// Updates 3D emitter parameters on a live voice.
    SetEmitter {
        /// Target active voice identifier.
        voice_id: u32,
        /// Updated 3D spatial emitter parameters, or `None` to disable spatialization.
        emitter: Option<SpatialEmitter>,
    },
    /// Updates 3D spatial listener pose.
    SetListener {
        /// Updated 3D spatial listener pose and velocity.
        listener: SpatialListener,
    },
    /// Updates Doppler parameters.
    SetDoppler {
        /// Global Doppler scaling factor (carried in command wire format).
        factor: f32,
        /// Speed of sound in meters per second.
        speed_of_sound: f32,
    },
}

/// Fixed real-time voice slot owning its `SoundBuffer` handle independently of cold catalog reloads.
#[derive(Clone, Default)]
pub struct RtVoiceSlot {
    /// Active voice identifier assigned by [`EffectCatalog`].
    pub voice_id: u32,
    /// Stable catalog entry key owning this voice.
    pub effect_key: u64,
    /// Whether this slot is currently rendering audio.
    pub active: bool,
    /// Owned decoded PCM buffer rendered by this voice.
    pub buffer: Option<SoundBuffer>,
    /// Fractional playback cursor position in source frames.
    pub cursor_frame: f64,
    /// Linear playback volume multiplier.
    pub volume: f32,
    /// Pitch shift multiplier.
    pub pitch: f32,
    /// Stereo pan balance (`-1.0` to `1.0`).
    pub balance: f32,
    /// Voice stealing priority (`0..=255`).
    pub priority: u8,
    /// Whether this voice loops continuously.
    pub looping: bool,
    /// Output bus DSP routing policy.
    pub dsp_routing: DspRouting,
    /// Optional 3D spatial emitter configuration.
    pub emitter: Option<SpatialEmitter>,
    /// Whether this voice is currently fading out to stop.
    pub stopping: bool,
    /// Remaining fade-out frames when `stopping` is `true`.
    pub fade_samples_remaining: usize,
    /// Total fade-out frames configured when stopping began.
    pub total_fade_samples: usize,
    /// Age of this voice in rendered output frames.
    pub age_frames: u64,
}

impl Default for DspRouting {
    fn default() -> Self {
        DspRouting::Inherit
    }
}

/// Callback type for deferring off-thread deallocation of retired [`SoundBuffer`] instances.
pub type SoundBufferReaperFn = Box<dyn FnMut(SoundBuffer) + Send>;

/// Lock-free real-time polyphonic voice renderer driven strictly by [`RtVoiceCmd`] messages.
pub struct VoicePoolRt {
    /// Maximum concurrent voices allowed in `voices`.
    max_voices: usize,
    /// Pre-allocated fixed array of voice slots.
    voices: [RtVoiceSlot; MAX_VOICES],
    /// Current 3D spatial listener pose.
    listener: SpatialListener,
    /// Speed of sound in meters per second used for Doppler evaluation.
    speed_of_sound: f32,
    /// Policy selecting a victim slot when all `max_voices` slots are occupied.
    stealing_policy: VoiceStealingPolicy,
    /// Output device sample rate in Hertz.
    sample_rate: u32,
    /// Output device channel count.
    channels: usize,
    /// Highest command sequence number processed by the RT thread.
    last_seq: u64,
    /// Lock-free command receiver fed by [`EffectCatalog`] and [`EffectsControl`].
    cmd_rx: crossbeam_channel::Receiver<RtVoiceCmd>,
    /// Wait-free SPSC producer emitting [`RtVoiceDone`] events back to [`EffectCatalog`].
    done_tx: rtrb::Producer<RtVoiceDone>,
    /// Shared atomic metrics for lock-free active voice telemetry.
    metrics: std::sync::Arc<SharedVoiceMetrics>,
    /// Optional off-RT reaper callback deferring `SoundBuffer` drops off the audio thread.
    reaper_fn: Option<SoundBufferReaperFn>,
}

unsafe impl Send for VoicePoolRt {}

impl VoicePoolRt {
    /// Creates a new [`VoicePoolRt`] with `max_voices`, `sample_rate`, `channels`, paired with
    /// `cmd_rx`, `done_tx`, and shared atomic `metrics`.
    pub fn new(
        max_voices: usize,
        sample_rate: u32,
        channels: usize,
        cmd_rx: crossbeam_channel::Receiver<RtVoiceCmd>,
        done_tx: rtrb::Producer<RtVoiceDone>,
        metrics: std::sync::Arc<SharedVoiceMetrics>,
    ) -> Self {
        Self {
            max_voices: max_voices.clamp(1, MAX_VOICES),
            voices: std::array::from_fn(|_| RtVoiceSlot::default()),
            listener: SpatialListener::default(),
            speed_of_sound: 343.3,
            stealing_policy: VoiceStealingPolicy::LowestPriority,
            sample_rate: sample_rate.max(8000),
            channels: channels.max(1),
            last_seq: 0,
            cmd_rx,
            done_tx,
            metrics,
            reaper_fn: None,
        }
    }

    /// Attaches an off-RT `reaper` sink receiving retired `SoundBuffer` instances when slots deactivate.
    pub fn set_reaper(&mut self, reaper: SoundBufferReaperFn) {
        self.reaper_fn = Some(reaper);
    }

    /// Takes the buffer from voice slot `slot_idx` and forwards it to `reaper_fn` if installed.
    #[inline]
    fn retire_buffer(&mut self, slot_idx: usize) {
        if let Some(buf) = self.voices[slot_idx].buffer.take() {
            if let Some(ref mut reaper) = self.reaper_fn {
                reaper(buf);
            }
        }
    }

    /// Emits a non-blocking [`RtVoiceDone`] notification for `voice_id` and `effect_key`.
    #[inline]
    fn push_done(&mut self, voice_id: u32, effect_key: u64) {
        if self
            .done_tx
            .push(RtVoiceDone {
                voice_id,
                effect_key,
            })
            .is_ok()
        {
            self.metrics.mark_pending_done();
        }
    }

    /// Returns the index of an inactive slot, or steals an active slot according to `stealing_policy`.
    fn find_or_steal_slot(&mut self) -> usize {
        for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
            if !v.active {
                return i;
            }
        }

        let mut target = 0usize;
        match self.stealing_policy {
            VoiceStealingPolicy::LowestPriority => {
                let mut lowest = u8::MAX;
                let mut oldest = 0u64;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    if v.priority < lowest || (v.priority == lowest && v.age_frames > oldest) {
                        lowest = v.priority;
                        oldest = v.age_frames;
                        target = i;
                    }
                }
            }
            VoiceStealingPolicy::Oldest => {
                let mut oldest = 0u64;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    if v.age_frames > oldest {
                        oldest = v.age_frames;
                        target = i;
                    }
                }
            }
            VoiceStealingPolicy::Quietest => {
                let mut quietest = f32::MAX;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    if v.volume < quietest {
                        quietest = v.volume;
                        target = i;
                    }
                }
            }
            VoiceStealingPolicy::Farthest => {
                let mut farthest = -1.0f32;
                let lp = self.listener.position;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    let dist = if let Some(em) = v.emitter {
                        let dx = em.position.x - lp.x;
                        let dy = em.position.y - lp.y;
                        let dz = em.position.z - lp.z;
                        (dx * dx + dy * dy + dz * dz).sqrt()
                    } else {
                        0.0
                    };
                    if dist > farthest {
                        farthest = dist;
                        target = i;
                    }
                }
            }
        }

        if self.voices[target].active {
            let vid = self.voices[target].voice_id;
            let key = self.voices[target].effect_key;
            self.voices[target].active = false;
            self.retire_buffer(target);
            self.push_done(vid, key);
        }
        target
    }

    /// Drains all currently queued [`RtVoiceCmd`] messages without blocking.
    fn drain_commands(&mut self) {
        while let Ok(cmd) = self.cmd_rx.try_recv() {
            match cmd {
                RtVoiceCmd::Start {
                    seq,
                    voice_id,
                    effect_key,
                    buffer,
                    volume,
                    pitch,
                    balance,
                    priority,
                    looping,
                    dsp_routing,
                    emitter,
                } => {
                    self.last_seq = self.last_seq.max(seq);
                    let slot = self.find_or_steal_slot();
                    self.retire_buffer(slot);
                    self.voices[slot] = RtVoiceSlot {
                        voice_id,
                        effect_key,
                        active: true,
                        buffer: Some(buffer),
                        cursor_frame: 0.0,
                        volume,
                        pitch,
                        balance,
                        priority,
                        looping,
                        dsp_routing,
                        emitter,
                        stopping: false,
                        fade_samples_remaining: 0,
                        total_fade_samples: 0,
                        age_frames: 0,
                    };
                }
                RtVoiceCmd::StopVoice {
                    seq,
                    voice_id,
                    fade_out_samples,
                } => {
                    self.last_seq = self.last_seq.max(seq);
                    let mut completed_pair = None;
                    for i in 0..self.max_voices {
                        let v = &mut self.voices[i];
                        if v.active && v.voice_id == voice_id {
                            if fade_out_samples == 0 {
                                let key = v.effect_key;
                                v.active = false;
                                completed_pair = Some((i, voice_id, key));
                            } else {
                                v.stopping = true;
                                v.fade_samples_remaining = fade_out_samples;
                                v.total_fade_samples = fade_out_samples;
                            }
                            break;
                        }
                    }
                    if let Some((slot_idx, vid, key)) = completed_pair {
                        self.retire_buffer(slot_idx);
                        self.push_done(vid, key);
                    }
                }
                RtVoiceCmd::StopAll {
                    seq,
                    fade_out_samples,
                } => {
                    self.last_seq = self.last_seq.max(seq);
                    for i in 0..self.max_voices {
                        if self.voices[i].active {
                            if fade_out_samples == 0 {
                                let vid = self.voices[i].voice_id;
                                let key = self.voices[i].effect_key;
                                self.voices[i].active = false;
                                self.retire_buffer(i);
                                self.push_done(vid, key);
                            } else {
                                self.voices[i].stopping = true;
                                self.voices[i].fade_samples_remaining = fade_out_samples;
                                self.voices[i].total_fade_samples = fade_out_samples;
                            }
                        }
                    }
                }
                RtVoiceCmd::SetVolume { voice_id, volume } => {
                    if volume.is_finite() {
                        for v in self.voices[..self.max_voices].iter_mut() {
                            if v.active && v.voice_id == voice_id {
                                v.volume = volume.max(0.0);
                                break;
                            }
                        }
                    }
                }
                RtVoiceCmd::SetPitch { voice_id, pitch } => {
                    if pitch.is_finite() && pitch > 0.0 {
                        for v in self.voices[..self.max_voices].iter_mut() {
                            if v.active && v.voice_id == voice_id {
                                v.pitch = pitch;
                                break;
                            }
                        }
                    }
                }
                RtVoiceCmd::SetBalance { voice_id, balance } => {
                    for v in self.voices[..self.max_voices].iter_mut() {
                        if v.active && v.voice_id == voice_id {
                            v.balance = balance.clamp(-1.0, 1.0);
                            break;
                        }
                    }
                }
                RtVoiceCmd::SetEmitter { voice_id, emitter } => {
                    for v in self.voices[..self.max_voices].iter_mut() {
                        if v.active && v.voice_id == voice_id {
                            v.emitter = emitter;
                            break;
                        }
                    }
                }
                RtVoiceCmd::SetListener { listener } => {
                    self.listener = listener;
                }
                RtVoiceCmd::SetDoppler {
                    factor: _,
                    speed_of_sound,
                } => {
                    self.speed_of_sound = speed_of_sound;
                }
            }
        }
    }

    /// Wait-free real-time render pass: drains pending commands, mixes `frame_count` frames of
    /// all active slots into `inherit_buf`, `isolate_buf`, and `bypass_buf` without touching cold
    /// catalog locks, and reconciles active voice telemetry.
    pub fn render(
        &mut self,
        inherit_buf: &mut [f32],
        isolate_buf: &mut [f32],
        bypass_buf: &mut [f32],
        frame_count: usize,
    ) {
        self.drain_commands();

        let channels = self.channels;
        let sample_rate = self.sample_rate as f64;
        let mut live_count: u16 = 0;

        for i in 0..self.max_voices {
            if !self.voices[i].active {
                continue;
            }
            let Some(buf) = self.voices[i].buffer.clone() else {
                self.voices[i].active = false;
                continue;
            };

            let target_out = match self.voices[i].dsp_routing {
                DspRouting::Inherit => &mut *inherit_buf,
                DspRouting::Isolate => &mut *isolate_buf,
                DspRouting::Bypass => &mut *bypass_buf,
            };

            let completed = {
                let v = &mut self.voices[i];
                render_voice_buffer(
                    VoiceRenderState {
                        active: &mut v.active,
                        cursor_frame: &mut v.cursor_frame,
                        stopping: &mut v.stopping,
                        fade_samples_remaining: &mut v.fade_samples_remaining,
                        total_fade_samples: v.total_fade_samples,
                        age_frames: &mut v.age_frames,
                    },
                    &buf,
                    v.volume,
                    v.pitch,
                    v.balance,
                    v.looping,
                    v.emitter.as_ref(),
                    &self.listener,
                    self.speed_of_sound,
                    target_out,
                    frame_count,
                    channels,
                    sample_rate,
                )
            };

            drop(buf);

            if completed {
                let vid = self.voices[i].voice_id;
                let key = self.voices[i].effect_key;
                self.retire_buffer(i);
                self.push_done(vid, key);
            } else if !self.voices[i].active {
                self.retire_buffer(i);
            } else if !self.voices[i].stopping {
                live_count += 1;
            }
        }

        self.metrics.reconcile_rt_count(self.last_seq, live_count);
    }
}

/// Cold-side catalog entry adding a stable `effect_key` for lock-free RT decoupling.
pub struct CatalogEntry {
    /// Monotonic catalog-unique key identifying this effect version across reloads.
    pub effect_key: u64,
    /// Effect metadata and optional cached PCM buffer.
    pub inner: RegisteredEffect,
}

/// Cold-side mirror of an active RT voice used for polyphony accounting and victim selection.
#[derive(Clone, Copy)]
struct ShadowVoice {
    /// Voice identifier dispatched to [`VoicePoolRt`].
    voice_id: u32,
    /// Catalog key of the effect owned by this voice.
    effect_key: u64,
    /// Voice stealing priority (`0..=255`).
    priority: u8,
    /// Monotonic spawn sequence used as an age tie-breaker.
    spawn_order: u64,
    /// Effective linear playback volume after jitter.
    volume: f32,
    /// Optional 3D spatial emitter configuration.
    emitter: Option<SpatialEmitter>,
    /// Whether a fade-out stop command has already been issued for this voice.
    stopping: bool,
}

/// Pre-decoded memory batch produced outside [`EffectCatalog`] locks.
pub struct PreparedCatalogItem {
    /// Unique identifier for the sound effect.
    pub id: String,
    /// Underlying audio source descriptor (memory bytes stripped after pre-decode).
    pub source: AudioSourceCore,
    /// Retention classification for LRU eviction.
    pub source_type: EffectSourceType,
    /// Pre-decoded PCM buffer for memory-backed effects.
    pub predecoded: Option<SoundBuffer>,
    /// Maximum concurrent voices allowed for this effect.
    pub max_polyphony: usize,
    /// Whether this effect is pinned in RAM.
    pub pinned: bool,
}

/// Decodes memory-backed `effects` outside any mutex, using `dart_resolver` if needed,
/// and returns [`PreparedCatalogItem`] descriptors ready for [`EffectCatalog::apply_prepared_effects`].
///
/// # Errors
///
/// Returns an error string if decoding any memory-backed effect fails.
pub fn prepare_catalog_items(
    effects: Vec<EffectCatalogItem>,
    dart_resolver: Option<&Arc<DartResolveRegistry>>,
) -> Result<Vec<PreparedCatalogItem>, String> {
    crate::map_log!(
        4,
        "[VOICE_POOL] Preparing {} sound effect catalog items",
        effects.len()
    );
    let mut prepared = Vec::with_capacity(effects.len());
    for mut item in effects {
        let source_type = classify_source_type(&item.source);
        let predecoded = if source_type == EffectSourceType::Memory {
            let buf = decode_effect_source(&item.id, &item.source, dart_resolver)?;
            item.source.data_bytes = None;
            Some(buf)
        } else {
            None
        };
        prepared.push(PreparedCatalogItem {
            id: item.id,
            source: item.source,
            source_type,
            predecoded,
            max_polyphony: item.max_polyphony.max(1),
            pinned: item.pinned,
        });
    }
    Ok(prepared)
}

/// Cold-path sound effect catalog, LRU cache, and command producer for [`VoicePoolRt`].
pub struct EffectCatalog {
    /// Maximum concurrent voices allowed across the pool.
    pub max_voices: usize,
    /// Optional maximum RAM budget in bytes for cached PCM buffers.
    pub max_ram_bytes: Option<usize>,
    /// Total PCM buffer bytes currently cached across `entries`.
    pub allocated_ram_bytes: usize,
    /// Registered catalog entries indexed by `id_to_index`.
    pub entries: Vec<CatalogEntry>,
    /// Fast lookup map from effect `id` string to index in `entries`.
    pub id_to_index: HashMap<String, usize>,
    /// Next monotonic `effect_key` assigned to newly created catalog entries.
    next_effect_key: u64,
    /// Next monotonic non-zero `voice_id` assigned to triggered voices.
    next_voice_id: u32,
    /// Next monotonic spawn order counter for voice stealing age comparisons.
    next_spawn_order: u64,
    /// Cold-side shadow map of voices expected to be active on [`VoicePoolRt`].
    shadow_voices: HashMap<u32, ShadowVoice>,
    /// Cached 3D listener pose used for `Farthest` victim selection.
    pub listener: SpatialListener,
    /// Cached speed of sound in meters per second.
    pub speed_of_sound: f32,
    /// Active voice stealing policy when voice capacity is saturated.
    pub stealing_policy: VoiceStealingPolicy,
    /// Command sender dispatching [`RtVoiceCmd`] messages to [`VoicePoolRt`].
    cmd_tx: crossbeam_channel::Sender<RtVoiceCmd>,
    /// Completion ring consumer receiving [`RtVoiceDone`] messages from [`VoicePoolRt`].
    done_rx: rtrb::Consumer<RtVoiceDone>,
    /// Shared atomic telemetry counters mirrored with [`VoicePoolRt`].
    metrics: std::sync::Arc<SharedVoiceMetrics>,
}

unsafe impl Send for EffectCatalog {}

impl EffectCatalog {
    /// Creates a cold catalog configured with `max_voices` and optional `max_ram_bytes`,
    /// connected via `cmd_tx`, `done_rx`, and `metrics` to its paired [`VoicePoolRt`].
    pub fn new(
        max_voices: usize,
        max_ram_bytes: Option<usize>,
        cmd_tx: crossbeam_channel::Sender<RtVoiceCmd>,
        done_rx: rtrb::Consumer<RtVoiceDone>,
        metrics: std::sync::Arc<SharedVoiceMetrics>,
    ) -> Self {
        Self {
            max_voices: max_voices.clamp(1, MAX_VOICES),
            max_ram_bytes,
            allocated_ram_bytes: 0,
            entries: Vec::new(),
            id_to_index: HashMap::new(),
            next_effect_key: 1,
            next_voice_id: 1,
            next_spawn_order: 1,
            shadow_voices: HashMap::new(),
            listener: SpatialListener::default(),
            speed_of_sound: 343.3,
            stealing_policy: VoiceStealingPolicy::LowestPriority,
            cmd_tx,
            done_rx,
            metrics,
        }
    }

    /// Returns identifiers of all sound effects currently resident in RAM.
    pub fn loaded_effect_ids(&self) -> Vec<String> {
        self.entries
            .iter()
            .filter(|e| e.inner.buffer.is_some())
            .map(|e| e.inner.id.clone())
            .collect()
    }

    /// Publishes `allocated_ram_bytes` to [`SharedVoiceMetrics`].
    fn sync_metrics_ram(&self) {
        self.metrics.set_allocated_ram_bytes(self.allocated_ram_bytes);
    }

    /// Finds the index in `entries` matching `effect_key`, if still present.
    #[inline]
    fn find_index_by_key(&self, effect_key: u64) -> Option<usize> {
        self.entries.iter().position(|e| e.effect_key == effect_key)
    }

    /// Drains RT voice completions into cold accounting without touching RT state,
    /// returning `(completed_voice_ids, evicted_any)`.
    pub fn drain_completed(&mut self) -> (Vec<u32>, bool) {
        let mut completed_ids = Vec::new();
        let mut evicted = false;
        let now = Instant::now();
        self.metrics.clear_pending_done();

        while let Ok(done) = self.done_rx.pop() {
            completed_ids.push(done.voice_id);
            if let Some(sv) = self.shadow_voices.remove(&done.voice_id) {
                if let Some(idx) = self.find_index_by_key(sv.effect_key) {
                    let eff = &mut self.entries[idx].inner;
                    eff.active_voices = eff.active_voices.saturating_sub(1);
                    eff.last_used = now;
                }
            }
        }

        if !completed_ids.is_empty() && self.evict_if_over_budget(None).0 {
            evicted = true;
        }
        (completed_ids, evicted)
    }

    /// Applies pre-decoded `prepared` catalog items without blocking on memory decode or
    /// interrupting RT audio, returning displaced buffers for the caller to drop after
    /// releasing the catalog lock.
    pub fn apply_prepared_effects(
        &mut self,
        prepared: Vec<PreparedCatalogItem>,
    ) -> Vec<SoundBuffer> {
        let _ = self.drain_completed();
        let mut displaced_buffers = Vec::new();

        let mut old_map: HashMap<String, CatalogEntry> = self
            .entries
            .drain(..)
            .map(|mut e| {
                e.inner.active_voices = 0;
                (e.inner.id.clone(), e)
            })
            .collect();
        self.id_to_index.clear();
        self.allocated_ram_bytes = 0;

        for item in prepared {
            let entry = if let Some(buf) = item.predecoded {
                if let Some(mut prev) = old_map.remove(&item.id) {
                    if let Some(b) = prev.inner.buffer.take() {
                        displaced_buffers.push(b);
                    }
                }
                let byte_size = buf.samples.len() * 4;
                self.allocated_ram_bytes += byte_size;
                let key = self.next_effect_key;
                self.next_effect_key += 1;
                CatalogEntry {
                    effect_key: key,
                    inner: RegisteredEffect {
                        id: item.id,
                        source: item.source,
                        source_type: item.source_type,
                        buffer: Some(buf),
                        max_polyphony: item.max_polyphony,
                        pinned: item.pinned,
                        byte_size,
                        trigger_count: 0,
                        last_used: Instant::now(),
                        active_voices: 0,
                    },
                }
            } else if let Some(mut existing) = old_map.remove(&item.id) {
                if existing.inner.source.source == item.source.source
                    && existing.inner.buffer.is_some()
                {
                    self.allocated_ram_bytes += existing.inner.byte_size;
                    existing.inner.max_polyphony = item.max_polyphony;
                    existing.inner.pinned = item.pinned;
                    existing.inner.source = item.source;
                    existing
                } else {
                    if let Some(b) = existing.inner.buffer.take() {
                        displaced_buffers.push(b);
                    }
                    let key = self.next_effect_key;
                    self.next_effect_key += 1;
                    CatalogEntry {
                        effect_key: key,
                        inner: RegisteredEffect {
                            id: item.id,
                            source: item.source,
                            source_type: item.source_type,
                            buffer: None,
                            max_polyphony: item.max_polyphony,
                            pinned: item.pinned,
                            byte_size: 0,
                            trigger_count: 0,
                            last_used: Instant::now(),
                            active_voices: 0,
                        },
                    }
                }
            } else {
                let key = self.next_effect_key;
                self.next_effect_key += 1;
                CatalogEntry {
                    effect_key: key,
                    inner: RegisteredEffect {
                        id: item.id,
                        source: item.source,
                        source_type: item.source_type,
                        buffer: None,
                        max_polyphony: item.max_polyphony,
                        pinned: item.pinned,
                        byte_size: 0,
                        trigger_count: 0,
                        last_used: Instant::now(),
                        active_voices: 0,
                    },
                }
            };

            let idx = self.entries.len();
            self.id_to_index.insert(entry.inner.id.clone(), idx);
            self.entries.push(entry);
        }

        for (_, mut unused) in old_map {
            if let Some(b) = unused.inner.buffer.take() {
                displaced_buffers.push(b);
            }
        }

        // Preserve accurate active_voices counts for any surviving catalog keys.
        for sv in self.shadow_voices.values() {
            if !sv.stopping {
                if let Some(idx) = self.find_index_by_key(sv.effect_key) {
                    self.entries[idx].inner.active_voices += 1;
                }
            }
        }

        let (_, mut evicted_bufs) = self.evict_if_over_budget(None);
        displaced_buffers.append(&mut evicted_bufs);
        self.sync_metrics_ram();
        crate::map_log!(
            3,
            "[VOICE_POOL] Applied effect catalog (entries={} ram_bytes={} displaced={})",
            self.entries.len(),
            self.allocated_ram_bytes,
            displaced_buffers.len()
        );
        displaced_buffers
    }

    /// Evicts lowest-scoring evictable entries (skipping `exclude_idx`) until
    /// `allocated_ram_bytes <= target_bytes` or no evictable buffers remain, returning
    /// `(evicted_any, evicted_buffers)`.
    pub fn evict_lowest_scoring_until(
        &mut self,
        target_bytes: usize,
        exclude_idx: Option<usize>,
    ) -> (bool, Vec<SoundBuffer>) {
        let mut evicted_any = false;
        let mut evicted_buffers = Vec::new();
        let now = Instant::now();

        while self.allocated_ram_bytes > target_bytes {
            let mut candidate_idx: Option<usize> = None;
            let mut lowest_score = f64::INFINITY;

            for (idx, entry) in self.entries.iter().enumerate() {
                if Some(idx) == exclude_idx {
                    continue;
                }
                if entry.inner.is_evictable() {
                    let score = entry.inner.retention_score(now);
                    if candidate_idx.is_none() || score < lowest_score {
                        lowest_score = score;
                        candidate_idx = Some(idx);
                    }
                }
            }

            if let Some(evict_idx) = candidate_idx {
                let eff = &mut self.entries[evict_idx].inner;
                self.allocated_ram_bytes = self.allocated_ram_bytes.saturating_sub(eff.byte_size);
                if let Some(old_buf) = eff.buffer.take() {
                    evicted_buffers.push(old_buf);
                }
                eff.byte_size = 0;
                evicted_any = true;
            } else {
                break;
            }
        }

        if evicted_any {
            self.sync_metrics_ram();
            crate::map_log!(
                4,
                "[VOICE_POOL] LRU evicted {} buffer(s); ram_bytes={} target={}",
                evicted_buffers.len(),
                self.allocated_ram_bytes,
                target_bytes
            );
        }
        (evicted_any, evicted_buffers)
    }

    /// Evicts cached buffers if `allocated_ram_bytes` exceeds `max_ram_bytes`, skipping
    /// `exclude_idx`, and returns `(evicted_any, evicted_buffers)`.
    #[inline]
    pub fn evict_if_over_budget(&mut self, exclude_idx: Option<usize>) -> (bool, Vec<SoundBuffer>) {
        if let Some(limit) = self.max_ram_bytes {
            if self.allocated_ram_bytes > limit {
                return self.evict_lowest_scoring_until(limit, exclude_idx);
            }
        }
        (false, Vec::new())
    }

    /// Looks up effect `id` and returns `Ok(None)` if already cached in RAM, or
    /// `Ok(Some((effect_key, source)))` if decoding is required outside the lock.
    ///
    /// # Errors
    ///
    /// Returns an error string if `id` is not registered in the catalog.
    pub fn lookup_decode_target(&self, id: &str) -> Result<Option<(u64, AudioSourceCore)>, String> {
        let idx = match self.id_to_index.get(id) {
            Some(&i) => i,
            None => {
                return Err(format!(
                    "AudioEffectNotFound: Effect '{}' not registered in catalog",
                    id
                ));
            }
        };
        let entry = &self.entries[idx];
        if entry.inner.buffer.is_some() {
            Ok(None)
        } else {
            Ok(Some((entry.effect_key, entry.inner.source.clone())))
        }
    }

    /// Inserts a `decoded` PCM buffer for `id` (verifying `expected_key`), enforcing the RAM
    /// budget via LRU eviction, and returns `(installed, buffers_to_drop)`.
    pub fn install_decoded_buffer(
        &mut self,
        id: &str,
        expected_key: u64,
        decoded: SoundBuffer,
    ) -> (bool, Vec<SoundBuffer>) {
        let Some(&idx) = self.id_to_index.get(id) else {
            return (false, vec![decoded]);
        };
        if self.entries[idx].effect_key != expected_key {
            return (false, vec![decoded]);
        }
        if self.entries[idx].inner.buffer.is_some() {
            return (false, vec![decoded]);
        }

        let byte_size = decoded.samples.len() * 4;
        let mut displaced = Vec::new();
        if let Some(limit) = self.max_ram_bytes {
            if self.allocated_ram_bytes + byte_size > limit {
                let (_, mut bufs) =
                    self.evict_lowest_scoring_until(limit.saturating_sub(byte_size), Some(idx));
                displaced.append(&mut bufs);
            }
        }

        let eff = &mut self.entries[idx].inner;
        if let Some(old_buf) = eff.buffer.replace(decoded) {
            self.allocated_ram_bytes = self
                .allocated_ram_bytes
                .saturating_sub(old_buf.samples.len() * 4);
            displaced.push(old_buf);
        }
        eff.byte_size = byte_size;
        self.allocated_ram_bytes += byte_size;
        self.sync_metrics_ram();
        crate::map_log!(
            4,
            "[VOICE_POOL] Installed buffer for '{}' (bytes={} total_ram={})",
            id,
            byte_size,
            self.allocated_ram_bytes
        );
        (true, displaced)
    }

    /// Selects and removes a shadow voice victim belonging to `effect_key` when per-effect
    /// polyphony is saturated.
    fn steal_shadow_victim_for_effect(&mut self, effect_key: u64) -> Option<u32> {
        let victim = self
            .shadow_voices
            .values()
            .filter(|v| v.effect_key == effect_key && !v.stopping)
            .min_by_key(|v| (v.priority, v.spawn_order))
            .map(|v| v.voice_id)?;
        self.remove_shadow_voice(victim);
        Some(victim)
    }

    /// Selects and removes a global shadow voice victim according to `stealing_policy`.
    fn steal_global_shadow_victim(&mut self) -> Option<u32> {
        let victim = match self.stealing_policy {
            VoiceStealingPolicy::LowestPriority => self
                .shadow_voices
                .values()
                .min_by_key(|v| (v.priority, v.spawn_order))
                .map(|v| v.voice_id),
            VoiceStealingPolicy::Oldest => self
                .shadow_voices
                .values()
                .min_by_key(|v| v.spawn_order)
                .map(|v| v.voice_id),
            VoiceStealingPolicy::Quietest => self
                .shadow_voices
                .values()
                .min_by(|a, b| {
                    a.volume
                        .partial_cmp(&b.volume)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .map(|v| v.voice_id),
            VoiceStealingPolicy::Farthest => {
                let lp = self.listener.position;
                self.shadow_voices
                    .values()
                    .max_by(|a, b| {
                        let dist = |em: Option<SpatialEmitter>| -> f32 {
                            if let Some(e) = em {
                                let dx = e.position.x - lp.x;
                                let dy = e.position.y - lp.y;
                                let dz = e.position.z - lp.z;
                                (dx * dx + dy * dy + dz * dz).sqrt()
                            } else {
                                0.0
                            }
                        };
                        dist(a.emitter)
                            .partial_cmp(&dist(b.emitter))
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .map(|v| v.voice_id)
            }
        }?;
        self.remove_shadow_voice(victim);
        Some(victim)
    }

    /// Removes `voice_id` from `shadow_voices` and decrements its catalog entry's active count.
    fn remove_shadow_voice(&mut self, voice_id: u32) {
        if let Some(sv) = self.shadow_voices.remove(&voice_id) {
            if let Some(idx) = self.find_index_by_key(sv.effect_key) {
                let eff = &mut self.entries[idx].inner;
                eff.active_voices = eff.active_voices.saturating_sub(1);
                eff.last_used = Instant::now();
            }
        }
    }

    /// Returns the number of non-stopping voices tracked in `shadow_voices`.
    #[inline]
    fn live_shadow_count(&self) -> u16 {
        self.shadow_voices.values().filter(|v| !v.stopping).count() as u16
    }

    /// Triggers an already cached sound effect `id` with `config` via lock-free command dispatch
    /// to [`VoicePoolRt`], returning the assigned `voice_id`.
    ///
    /// # Errors
    ///
    /// Returns an error string if `id` is unregistered, its buffer is not loaded, or the RT
    /// command channel is full.
    pub fn play_cached_effect(&mut self, id: &str, config: EffectConfig) -> Result<u32, String> {
        let _ = self.drain_completed();
        let idx = *self
            .id_to_index
            .get(id)
            .ok_or_else(|| format!("AudioEffectNotFound: Effect '{}' not registered", id))?;

        let (effect_key, buffer, max_polyphony, active_for_effect) = {
            let entry = &self.entries[idx];
            let Some(ref buf) = entry.inner.buffer else {
                return Err("Effect buffer is not loaded".to_string());
            };
            (
                entry.effect_key,
                buf.clone(),
                entry.inner.max_polyphony,
                entry.inner.active_voices,
            )
        };

        let mut stolen_victims = Vec::new();
        if active_for_effect >= max_polyphony {
            if let Some(v) = self.steal_shadow_victim_for_effect(effect_key) {
                stolen_victims.push(v);
            }
        }
        if self.shadow_voices.len() >= self.max_voices {
            if let Some(v) = self.steal_global_shadow_victim() {
                stolen_victims.push(v);
            }
        }

        let voice_id = self.next_voice_id;
        self.next_voice_id = self.next_voice_id.wrapping_add(1).max(1);
        let spawn_order = self.next_spawn_order;
        self.next_spawn_order += 1;

        let final_pitch = apply_jitter(
            config.pitch * config.rate,
            config.pitch_jitter,
            voice_id,
            0x1234,
        )
        .max(0.001);
        let final_volume =
            apply_jitter(config.volume, config.volume_jitter, voice_id, 0x5678).max(0.0);
        let final_balance = config.balance.clamp(-1.0, 1.0);

        {
            let eff = &mut self.entries[idx].inner;
            eff.trigger_count += 1;
            eff.last_used = Instant::now();
            eff.active_voices += 1;
        }

        self.shadow_voices.insert(
            voice_id,
            ShadowVoice {
                voice_id,
                effect_key,
                priority: config.priority,
                spawn_order,
                volume: final_volume,
                emitter: config.spatial,
                stopping: false,
            },
        );

        for victim_id in stolen_victims {
            crate::map_log!(
                4,
                "[VOICE_POOL] Stole voice_id={} to spawn '{}' (new_voice_id={})",
                victim_id,
                id,
                voice_id
            );
            let s = self.metrics.next_seq();
            let _ = self.cmd_tx.try_send(RtVoiceCmd::StopVoice {
                seq: s,
                voice_id: victim_id,
                fade_out_samples: 0,
            });
        }

        let seq = self.metrics.next_seq();
        let count = self.live_shadow_count();
        self.metrics.publish_cold_count(seq, count);

        self.cmd_tx
            .try_send(RtVoiceCmd::Start {
                seq,
                voice_id,
                effect_key,
                buffer,
                volume: final_volume,
                pitch: final_pitch,
                balance: final_balance,
                priority: config.priority,
                looping: config.looping,
                dsp_routing: config.dsp_routing,
                emitter: config.spatial,
            })
            .map_err(|_| {
                crate::map_log!(1, "[VOICE_POOL] VoicePoolRt command channel full");
                "VoicePoolRt command channel full".to_string()
            })?;

        crate::map_log!(
            5,
            "[VOICE_POOL] Dispatched Start id='{}' voice_id={} active={}",
            id,
            voice_id,
            count
        );
        Ok(voice_id)
    }

    /// Stops `voice_id` over `fade_out_samples` frames (`0` for immediate), updating shadow count
    /// synchronously and sending the command to RT. Returns `true` if LRU eviction occurred.
    pub fn stop_voice(&mut self, voice_id: u32, fade_out_samples: usize) -> bool {
        let (_, mut evicted) = self.drain_completed();
        if fade_out_samples == 0 {
            self.remove_shadow_voice(voice_id);
            if self.evict_if_over_budget(None).0 {
                evicted = true;
            }
        } else {
            let stopping_key = self.shadow_voices.get_mut(&voice_id).and_then(|sv| {
                if !sv.stopping {
                    sv.stopping = true;
                    Some(sv.effect_key)
                } else {
                    None
                }
            });
            if let Some(effect_key) = stopping_key {
                if let Some(idx) = self.find_index_by_key(effect_key) {
                    let eff = &mut self.entries[idx].inner;
                    eff.active_voices = eff.active_voices.saturating_sub(1);
                }
            }
        }
        let seq = self.metrics.next_seq();
        let count = self.live_shadow_count();
        self.metrics.publish_cold_count(seq, count);
        let _ = self.cmd_tx.try_send(RtVoiceCmd::StopVoice {
            seq,
            voice_id,
            fade_out_samples,
        });
        evicted
    }

    /// Stops all active voices over `fade_out_samples` frames (`0` for immediate), updating
    /// shadow counts synchronously and sending the command to RT. Returns `true` if LRU eviction occurred.
    pub fn stop_all(&mut self, fade_out_samples: usize) -> bool {
        let (_, mut evicted) = self.drain_completed();
        if fade_out_samples == 0 {
            self.shadow_voices.clear();
            for entry in &mut self.entries {
                entry.inner.active_voices = 0;
            }
            if self.evict_if_over_budget(None).0 {
                evicted = true;
            }
        } else {
            for sv in self.shadow_voices.values_mut() {
                sv.stopping = true;
            }
            for entry in &mut self.entries {
                entry.inner.active_voices = 0;
            }
        }
        let seq = self.metrics.next_seq();
        let count = self.live_shadow_count();
        self.metrics.publish_cold_count(seq, count);
        let _ = self.cmd_tx.try_send(RtVoiceCmd::StopAll {
            seq,
            fade_out_samples,
        });
        crate::map_log!(
            4,
            "[VOICE_POOL] Dispatched StopAll (fade_out_samples={})",
            fade_out_samples
        );
        evicted
    }
}
