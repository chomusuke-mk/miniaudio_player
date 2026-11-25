//! Single-Owner Real-Time Audio Engine Actor (`map-engine-clock`) & Wait-Free UI Snapshots.
//!
//! `MiniaudioPlayer` is exclusively owned by the `map-engine-clock` thread—there is no
//! outer `Arc<Mutex<Box<MiniaudioPlayer>>>`. Control commands dispatch via lock-free
//! bounded/wakeup channels, while SFX control (`EffectsControl`), heavy drops (`ReaperHandle`),
//! and UI/telemetry getters (`EngineUiSnapshots`) bypass the RT clock completely.

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use std::time::Duration;
use crate::sync::thread::{self, JoinHandle};
use crate::sync::MonotonicInstant as Instant;

use crate::api::types::{RustAudioInfo, RustAudioInput, RustAudioMetadata, RustAudioOutput};
use crate::core::dual_source::AudioSourceCore;
use crate::core::dual_source_control::TransitionCommitMode;
use crate::core::effects_manager::EffectsControl;
use crate::core::miniaudio_player::MiniaudioPlayer;
use crate::core::types::{PlaybackState, QueueTransition};
use crate::dsp::visualizer::VisualizerData;
use crate::sync::{
    lock_unpoisoned, read_unpoisoned, wait_timeout_unpoisoned, write_unpoisoned, CachePaddedSeqlock,
    ReaperHandle, WakeQueue, WakeRecvError,
};

/// Bounded channel capacity for discrete engine lifecycle notices sent to the telemetry monitor.
const RT_NOTIFY_CAP: usize = 256;
/// Bounded channel capacity for non-blocking control hints sent to [`ControlCoordinator`].
const RT_HINT_CAP: usize = 64;

/// Wait-free and lock-free telemetry snapshots published by `map-engine-clock`.
pub struct EngineUiSnapshots {
    /// Immutable output engine sample rate in Hz.
    pub sample_rate: u32,
    /// Odd/even seqlock-style sequence counter incremented before and after each snapshot publish.
    pub_seq: AtomicU64,
    /// Current [`PlaybackState`] integer representation.
    playback_state: AtomicI32,
    /// Whether an active crossfade is currently in progress.
    is_xfading: AtomicBool,
    /// Whether live audio recording is currently active.
    is_recording: AtomicBool,
    /// Elapsed recorded duration in milliseconds.
    recorded_duration_ms: AtomicU64,
    /// Whether microphone auto-ducking attenuation is currently active.
    is_ducking: AtomicBool,
    /// IEEE-754 bit pattern of the latest microphone RMS level in dBFS.
    mic_rms_bits: AtomicU32,
    /// Active deck playback position in milliseconds (or pending seek target while opening).
    position_ms: AtomicI64,
    /// Buffered range start position in milliseconds.
    buffered_start_ms: AtomicI64,
    /// Buffered range end position in milliseconds.
    buffered_end_ms: AtomicI64,
    /// Whether the active deck is currently buffering or waiting on a pending open.
    is_buffering: AtomicBool,
    /// Whether `buffered_start_ms` / `buffered_end_ms` hold a valid buffered range.
    has_buffered_range: AtomicBool,
    /// Current queue track index (`-1` when none is selected).
    current_index: AtomicI64,
    /// Active deck slot index (`0 = Deck A`, `1 = Deck B`).
    active_deck: AtomicI32,
    /// Unique monotonic deck slot identifier for metadata/epoch correlation.
    active_deck_id: AtomicUsize,
    /// Open generation counter of the currently active deck.
    active_open_gen: AtomicU64,
    /// Metadata byte-payload version of the currently active deck.
    meta_version: AtomicU32,
    /// Seek/flush generation counter of the currently active deck.
    flush_generation: AtomicU64,
    /// Packed `(gain_db, peak)` ReplayGain telemetry bits (`gain_db` in upper 32 bits).
    replay_gain_packed: AtomicU64,
    /// Whether the real-time FFT visualizer is enabled.
    visualizer_enabled: AtomicBool,
    /// Configured [`AudioOutputSource`] integer for the visualizer tap.
    visualizer_source: AtomicI32,
    /// Whether playback auto-pauses when an output device disconnects or changes.
    pause_on_device_change: AtomicBool,
    /// Cached snapshot of active output endpoints.
    outputs: RwLock<Vec<RustAudioOutput>>,
    /// Cached snapshot of active capture input endpoints.
    inputs: RwLock<Vec<RustAudioInput>>,
    /// Cached [`RustAudioInfo`] for the active deck.
    audio_info: RwLock<RustAudioInfo>,
    /// Cached parsed [`RustAudioMetadata`] for the active deck.
    parsed_metadata: RwLock<Option<RustAudioMetadata>>,
    /// Seqlock-protected FFT/waveform visualizer frame data.
    visualizer_seqlock: CachePaddedSeqlock<VisualizerData>,
    /// Monotonic edge counter incremented when telemetry waiters should wake immediately.
    telemetry_seq: AtomicU64,
    /// Mutex paired with `telemetry_cvar` for edge-triggered telemetry monitor waits.
    telemetry_lock: Mutex<()>,
    /// Condition variable notified on snapshot transition edges.
    telemetry_cvar: Condvar,
}

impl EngineUiSnapshots {
    /// Initializes snapshots from the initial player configuration state in `ply`.
    pub fn from_player(ply: &MiniaudioPlayer) -> Self {
        let active_deck = ply.music_manager.active_deck_ref();
        let (rg_gain, rg_peak) = ply.active_replay_gain;
        Self {
            sample_rate: ply.sample_rate,
            pub_seq: AtomicU64::new(0),
            playback_state: AtomicI32::new(
                ply.music_manager
                    .inner
                    .playback_state
                    .load(Ordering::Relaxed),
            ),
            is_xfading: AtomicBool::new(ply.music_manager.is_crossfading()),
            is_recording: AtomicBool::new(ply.output_manager.is_recording()),
            recorded_duration_ms: AtomicU64::new(ply.output_manager.recorded_duration_ms()),
            is_ducking: AtomicBool::new(ply.input_manager.is_ducking_active()),
            mic_rms_bits: AtomicU32::new(ply.input_manager.last_rms_db().to_bits()),
            position_ms: AtomicI64::new(active_deck.position_ms.load(Ordering::Relaxed)),
            buffered_start_ms: AtomicI64::new(0),
            buffered_end_ms: AtomicI64::new(0),
            is_buffering: AtomicBool::new(active_deck.is_buffering.load(Ordering::Relaxed)),
            has_buffered_range: AtomicBool::new(false),
            current_index: AtomicI64::new(ply.music_manager.current_index() as i64),
            active_deck: AtomicI32::new(
                ply.music_manager
                    .inner
                    .active_deck
                    .load(Ordering::Relaxed),
            ),
            active_deck_id: AtomicUsize::new(active_deck.deck_id),
            active_open_gen: AtomicU64::new(active_deck.open_generation.load(Ordering::Acquire)),
            meta_version: AtomicU32::new(active_deck.get_meta_bytes_version()),
            flush_generation: AtomicU64::new(active_deck.flush_generation.load(Ordering::Acquire)),
            replay_gain_packed: AtomicU64::new(Self::pack_rg(rg_gain, rg_peak)),
            visualizer_enabled: AtomicBool::new(
                ply.output_manager
                    .visualizer_enabled
                    .load(Ordering::Relaxed),
            ),
            visualizer_source: AtomicI32::new(ply.output_manager.visualizer_source() as i32),
            pause_on_device_change: AtomicBool::new(
                ply.output_manager
                    .pause_on_device_change
                    .load(Ordering::Relaxed),
            ),
            outputs: RwLock::new(ply.output_manager.outputs.clone()),
            inputs: RwLock::new(ply.input_manager.current_inputs()),
            audio_info: RwLock::new(active_deck.get_audio_info()),
            parsed_metadata: RwLock::new(active_deck.get_parsed_metadata()),
            visualizer_seqlock: CachePaddedSeqlock::new(VisualizerData::default()),
            telemetry_seq: AtomicU64::new(0),
            telemetry_lock: Mutex::new(()),
            telemetry_cvar: Condvar::new(),
        }
    }

    /// Wakes any telemetry monitor waiting for snapshot edge transitions.
    pub fn notify_telemetry_waiters(&self) {
        let _guard = lock_unpoisoned(&self.telemetry_lock);
        self.telemetry_seq.fetch_add(1, Ordering::AcqRel);
        self.telemetry_cvar.notify_all();
    }

    /// Sleeps until snapshots publish a transition edge newer than `last_seq` or `timeout` elapses,
    /// updating `last_seq` to the latest observed sequence.
    pub fn wait_for_telemetry_tick(&self, timeout: Duration, last_seq: &mut u64) {
        let cur = self.telemetry_seq.load(Ordering::Acquire);
        if cur != *last_seq {
            *last_seq = cur;
            return;
        }
        let guard = lock_unpoisoned(&self.telemetry_lock);
        let cur_locked = self.telemetry_seq.load(Ordering::Acquire);
        if cur_locked != *last_seq {
            *last_seq = cur_locked;
            return;
        }
        let (_g, _) = wait_timeout_unpoisoned(&self.telemetry_cvar, guard, timeout);
        *last_seq = self.telemetry_seq.load(Ordering::Acquire);
    }

    /// Packs ReplayGain `gain_db` and linear `peak` into a single atomic `u64`.
    #[inline]
    fn pack_rg(gain_db: f32, peak: f32) -> u64 {
        ((gain_db.to_bits() as u64) << 32) | (peak.to_bits() as u64)
    }

    /// Unpacks the latest ReplayGain `(gain_db, peak)` tuple atomically.
    #[inline]
    pub fn unpack_rg(&self) -> (f32, f32) {
        let p = self.replay_gain_packed.load(Ordering::Acquire);
        (
            f32::from_bits((p >> 32) as u32),
            f32::from_bits((p & 0xFFFF_FFFF) as u32),
        )
    }

    /// Begins a consistent lock-free snapshot read, returning `None` if a publish is currently in progress.
    #[inline]
    pub fn begin_consistent_read(&self) -> Option<u64> {
        let seq = self.pub_seq.load(Ordering::Acquire);
        if seq & 1 != 0 {
            None
        } else {
            Some(seq)
        }
    }

    /// Returns `true` if no snapshot publish has occurred since `seq`.
    #[inline]
    pub fn is_consistent_since(&self, seq: u64) -> bool {
        std::sync::atomic::fence(Ordering::Acquire);
        self.pub_seq.load(Ordering::Acquire) == seq
    }

    /// Returns the latest published [`PlaybackState`].
    #[inline]
    pub fn playback_state(&self) -> PlaybackState {
        PlaybackState::from_i32(self.playback_state.load(Ordering::Acquire))
    }

    /// Returns `true` when a deck crossfade is active.
    #[inline]
    pub fn is_xfading(&self) -> bool {
        self.is_xfading.load(Ordering::Acquire)
    }

    /// Returns `true` when live recording is active.
    #[inline]
    pub fn is_recording(&self) -> bool {
        self.is_recording.load(Ordering::Acquire)
    }

    /// Returns the elapsed live recording duration in milliseconds.
    #[inline]
    pub fn recorded_duration_ms(&self) -> u64 {
        self.recorded_duration_ms.load(Ordering::Acquire)
    }

    /// Returns `true` when microphone auto-ducking is actively attenuating music.
    #[inline]
    pub fn is_ducking(&self) -> bool {
        self.is_ducking.load(Ordering::Acquire)
    }

    /// Returns the latest microphone RMS level in dBFS.
    #[inline]
    pub fn mic_rms_db(&self) -> f32 {
        f32::from_bits(self.mic_rms_bits.load(Ordering::Acquire))
    }

    /// Returns the active deck playback position in milliseconds.
    #[inline]
    pub fn position_ms(&self) -> i64 {
        self.position_ms.load(Ordering::Acquire)
    }

    /// Returns `true` when the active deck is buffering or waiting on an async track open.
    #[inline]
    pub fn is_buffering(&self) -> bool {
        self.is_buffering.load(Ordering::Acquire)
    }

    /// Returns `(start_ms, end_ms, is_buffering)` if a buffered range is available for the active deck.
    #[inline]
    pub fn buffered_range(&self) -> Option<(i64, i64, bool)> {
        if !self.has_buffered_range.load(Ordering::Acquire) {
            return None;
        }
        Some((
            self.buffered_start_ms.load(Ordering::Acquire),
            self.buffered_end_ms.load(Ordering::Acquire),
            self.is_buffering.load(Ordering::Acquire),
        ))
    }

    /// Returns the current queue index (`-1` when no track is selected).
    #[inline]
    pub fn current_index(&self) -> i64 {
        self.current_index.load(Ordering::Acquire)
    }

    /// Returns the active deck slot index (`0 = Deck A`, `1 = Deck B`).
    #[inline]
    pub fn active_deck(&self) -> i32 {
        self.active_deck.load(Ordering::Acquire)
    }

    /// Returns the unique identifier of the currently active deck slot.
    #[inline]
    pub fn active_deck_id(&self) -> usize {
        self.active_deck_id.load(Ordering::Acquire)
    }

    /// Returns the open generation counter of the currently active deck.
    #[inline]
    pub fn active_open_gen(&self) -> u64 {
        self.active_open_gen.load(Ordering::Acquire)
    }

    /// Returns the active deck's metadata payload version.
    #[inline]
    pub fn meta_version(&self) -> u32 {
        self.meta_version.load(Ordering::Acquire)
    }

    /// Returns the active deck's seek/flush generation counter.
    #[inline]
    pub fn flush_generation(&self) -> u64 {
        self.flush_generation.load(Ordering::Acquire)
    }

    /// Returns `true` when the real-time FFT visualizer is enabled.
    #[inline]
    pub fn visualizer_enabled(&self) -> bool {
        self.visualizer_enabled.load(Ordering::Acquire)
    }

    /// Returns the configured visualizer source bus integer.
    #[inline]
    pub fn visualizer_source(&self) -> i32 {
        self.visualizer_source.load(Ordering::Acquire)
    }

    /// Returns `true` when auto-pause on output device disconnect/change is enabled.
    #[inline]
    pub fn pause_on_device_change(&self) -> bool {
        self.pause_on_device_change.load(Ordering::Acquire)
    }

    /// Returns a cloned snapshot of the active output endpoints.
    #[inline]
    pub fn outputs(&self) -> Vec<RustAudioOutput> {
        read_unpoisoned(&self.outputs).clone()
    }

    /// Returns a cloned snapshot of the active capture input endpoints.
    #[inline]
    pub fn inputs(&self) -> Vec<RustAudioInput> {
        read_unpoisoned(&self.inputs).clone()
    }

    /// Returns a cloned snapshot of the active deck's [`RustAudioInfo`].
    #[inline]
    pub fn audio_info(&self) -> RustAudioInfo {
        read_unpoisoned(&self.audio_info).clone()
    }

    /// Returns a cloned snapshot of the active deck's parsed [`RustAudioMetadata`].
    #[inline]
    pub fn parsed_metadata(&self) -> Option<RustAudioMetadata> {
        read_unpoisoned(&self.parsed_metadata).clone()
    }

    /// Reads the latest seqlock-protected [`VisualizerData`] frame.
    #[inline]
    pub fn read_visualizer(&self) -> VisualizerData {
        self.visualizer_seqlock.read()
    }

    /// Updates the cached output endpoints snapshot to `outs`.
    #[inline]
    pub fn set_outputs_snapshot(&self, outs: Vec<RustAudioOutput>) {
        *write_unpoisoned(&self.outputs) = outs;
    }

    /// Updates the cached capture input endpoints snapshot to `ins`.
    #[inline]
    pub fn set_inputs_snapshot(&self, ins: Vec<RustAudioInput>) {
        *write_unpoisoned(&self.inputs) = ins;
    }
}

/// Discrete lifecycle notifications emitted by `map-engine-clock` to `map-telemetry-monitor`.
#[derive(Debug, Clone)]
pub enum RtEngineNotice {
    /// Emitted when crossfading starts (`true`) or completes/aborts (`false`).
    IsCrossfading(bool),
    /// Emitted when effective ReplayGain parameters change on track transition.
    ReplayGain {
        /// Effective ReplayGain adjustment in decibels.
        gain_db: f32,
        /// Effective ReplayGain peak linear amplitude.
        peak: f32,
    },
    /// Emitted when Infinite Mix remaining queue count falls below the configured threshold.
    NeedMoreTracks {
        /// Queue item ID of the currently playing track.
        current_track_id: i64,
        /// Number of tracks remaining after the current track.
        remaining_tracks: u32,
    },
    /// Emitted when the asynchronous live recording writer encounters an error.
    RecordingError {
        /// Human-readable diagnostic error message.
        message: String,
        /// Engine error code associated with the failure.
        code: i32,
    },
}

/// Non-blocking hints emitted from `map-engine-clock` to `ControlCoordinator`.
#[derive(Clone)]
pub enum RtControlHint {
    /// Standby deck is empty/unarmed near track end or after transition commit.
    PrewarmNeeded,
    /// Active track hit auto-crossfade point or EOF without a pre-warmed standby deck.
    AutoAdvanceNeeded {
        /// Expected active deck slot ID when the transition was triggered.
        expected_deck_id: usize,
        /// Expected active deck `open_generation` when the transition was triggered.
        expected_open_gen: u64,
        /// Expected active deck `seek_epoch` when the transition was triggered.
        expected_seek_epoch: u64,
        /// Target next queue index to open.
        next_idx: usize,
        /// Target queue item descriptor to open.
        item: AudioSourceCore,
        /// Whether an overlapping auto-crossfade is requested.
        should_auto_xfade: bool,
        /// Configured auto-crossfade duration in milliseconds.
        auto_ms: u64,
    },
}

/// Consolidated track state returned synchronously to FFI callers (`play`, `next`, `previous`).
#[derive(Clone)]
pub struct TrackTransitionSnapshot {
    /// Whether the queue membership changed during the transition.
    pub queue_changed: bool,
    /// Updated queue item IDs when `queue_changed` is `true`.
    pub queue_ids: Option<Vec<i64>>,
    /// Whether shuffle telemetry should be emitted for this transition.
    pub emit_shuffle: bool,
    /// Current queue index (`-1` if none).
    pub cur_idx: i64,
    /// Whether shuffle mode is currently enabled.
    pub is_shuffled: bool,
    /// Raw integer [`PlaybackState`] value.
    pub playback_state: i32,
    /// Convenience flag indicating `playback_state == PlaybackState::Playing`.
    pub is_playing: bool,
    /// Whether a crossfade is active after the transition.
    pub is_xfading: bool,
    /// Initial playback position in milliseconds.
    pub initial_pos: i64,
    /// Active deck stream format/duration telemetry.
    pub initial_info: RustAudioInfo,
    /// Active deck parsed metadata when requested.
    pub initial_meta: Option<RustAudioMetadata>,
    /// Active deck buffered range `(start_ms, end_ms, is_buffering)` when requested.
    pub buffered_range: Option<(i64, i64, bool)>,
    /// Effective ReplayGain `(gain_db, peak)` when a track is selected.
    pub replay_gain: Option<(f32, f32)>,
}

/// Captures a consistent [`TrackTransitionSnapshot`] from `ply`, including queue IDs if
/// `queue_changed`, parsed metadata if `include_metadata`, and buffered range if `include_buffered_range`.
pub fn capture_track_snapshot(
    ply: &mut MiniaudioPlayer,
    queue_changed: bool,
    include_metadata: bool,
    include_buffered_range: bool,
) -> TrackTransitionSnapshot {
    let queue_ids = if queue_changed {
        Some(snapshot_queue_ids(ply).0)
    } else {
        None
    };
    let cur_idx = ply.music_manager.current_index();
    let is_shuffled = ply.music_manager.is_shuffled();
    let active_deck = ply.music_manager.active_deck_ref();
    let playback_state = ply
        .music_manager
        .inner
        .playback_state
        .load(Ordering::Relaxed);
    let is_playing = playback_state == PlaybackState::Playing.as_i32();
    let is_xfading = ply.music_manager.inner.crossfade.is_active();
    let initial_pos = active_deck.position_ms.load(Ordering::Relaxed);
    let initial_info = active_deck.get_audio_info();
    let initial_meta = if include_metadata {
        active_deck.get_parsed_metadata()
    } else {
        None
    };
    let buffered_range = if include_buffered_range {
        let mut br = crate::bridge::ffi::MiniaudioBufferedRange::default();
        if active_deck.get_buffered_range(&mut br) == 0 {
            Some((br.start_ms, br.end_ms, br.is_buffering != 0))
        } else {
            None
        }
    } else {
        None
    };
    let replay_gain = if cur_idx >= 0 {
        Some(ply.recalculate_and_apply_replay_gain())
    } else {
        None
    };

    TrackTransitionSnapshot {
        queue_changed,
        queue_ids,
        emit_shuffle: false,
        cur_idx,
        is_shuffled,
        playback_state,
        is_playing,
        is_xfading,
        initial_pos,
        initial_info,
        initial_meta,
        buffered_range,
        replay_gain,
    }
}

/// Captures an immediate provisional queue-selection snapshot from `ply` while the target track
/// opens in I/O, optionally including `queue_changed` IDs and `emit_shuffle`.
pub fn capture_provisional_track_snapshot(
    ply: &mut MiniaudioPlayer,
    queue_changed: bool,
    emit_shuffle: bool,
) -> TrackTransitionSnapshot {
    let queue_ids = if queue_changed {
        Some(snapshot_queue_ids(ply).0)
    } else {
        None
    };
    let cur_idx = ply.music_manager.current_index();
    let is_shuffled = ply.music_manager.is_shuffled();
    let playback_state = ply
        .music_manager
        .inner
        .playback_state
        .load(Ordering::Relaxed);
    let is_playing = playback_state == PlaybackState::Playing.as_i32();
    let is_xfading = ply.music_manager.inner.crossfade.is_active();
    let initial_pos = ply
        .music_manager
        .inner
        .pending_open_seek_ms
        .load(Ordering::Relaxed);
    let replay_gain = if cur_idx >= 0 {
        Some(ply.recalculate_and_apply_replay_gain())
    } else {
        None
    };

    TrackTransitionSnapshot {
        queue_changed,
        queue_ids,
        emit_shuffle,
        cur_idx,
        is_shuffled,
        playback_state,
        is_playing,
        is_xfading,
        initial_pos,
        initial_info: RustAudioInfo::default(),
        initial_meta: None,
        buffered_range: Some((0, 0, true)),
        replay_gain,
    }
}

/// Captures the current active queue IDs and index cleanly from `ply` without poisoned-lock panics.
pub fn snapshot_queue_ids(ply: &MiniaudioPlayer) -> (Vec<i64>, i32) {
    let q: Vec<i64> = read_unpoisoned(&ply.music_manager.inner.queue)
        .iter()
        .map(|it| it.id)
        .collect();
    let cur_idx = ply
        .music_manager
        .inner
        .current_index
        .load(Ordering::Relaxed) as i32;
    (q, cur_idx)
}

/// Optional callback executed on `map-engine-clock` right after publishing snapshots for a command.
type PostPublishHook = Option<Box<dyn FnOnce() + Send>>;

/// Control messages dispatched to the `map-engine-clock` actor thread.
enum RtActorMsg {
    /// Executes a closure with mutable access to the owned [`MiniaudioPlayer`].
    Call(Box<dyn FnOnce(&mut MiniaudioPlayer) -> PostPublishHook + Send>),
    /// Disposes [`MiniaudioPlayer`] and signals the provided completion `(Mutex<bool>, Condvar)`.
    Shutdown(Arc<(Mutex<bool>, Condvar)>),
}

/// Deduplication keys avoiding redundant `RwLock` writes and condvar wakes during snapshot publishing.
struct SnapshotPublishCache {
    /// Cache key for `audio_info` updates: `(pending_open, active_deck, deck_id, open_gen, flush_gen, dur_ms, sr, ch)`.
    last_audio_info_key: (bool, i32, usize, u64, u64, i64, u32, u32),
    /// Cache key for `parsed_metadata` updates: `(pending_open, active_deck, deck_id, open_gen, meta_ver, flush_gen)`.
    last_meta_key: (bool, i32, usize, u64, u32, u64),
    /// Cache key for edge-triggered telemetry wakeups: `(current_index, playback_state, is_buffering)`.
    last_wake_key: (i64, i32, bool),
}

impl Default for SnapshotPublishCache {
    fn default() -> Self {
        Self {
            last_audio_info_key: (false, -1, usize::MAX, u64::MAX, u64::MAX, -1, 0, 0),
            last_meta_key: (false, -1, usize::MAX, u64::MAX, u32::MAX, u64::MAX),
            last_wake_key: (-1, 0, false),
        }
    }
}

/// Publishes player state from `ply` into `snap`, using `cache` to skip unchanged lock writes.
fn publish_snapshots(
    ply: &MiniaudioPlayer,
    snap: &EngineUiSnapshots,
    cache: &mut SnapshotPublishCache,
) {
    snap.pub_seq.fetch_add(1, Ordering::AcqRel);
    let active_deck = ply.music_manager.active_deck_ref();
    let active_deck_idx = ply.music_manager.inner.active_deck.load(Ordering::Relaxed);
    let deck_id = active_deck.deck_id;
    let open_gen = active_deck.open_generation.load(Ordering::Acquire);
    let flush_gen = active_deck.flush_generation.load(Ordering::Acquire);
    let meta_ver = active_deck.get_meta_bytes_version();
    let dur_ms = active_deck.duration_ms.load(Ordering::Relaxed);
    let pending_open = ply
        .music_manager
        .inner
        .pending_open_active
        .load(Ordering::Acquire);
    let playback_state_val = ply
        .music_manager
        .inner
        .playback_state
        .load(Ordering::Relaxed);
    let cur_idx_val = ply.music_manager.current_index();

    snap.active_deck_id.store(deck_id, Ordering::Release);
    snap.active_open_gen.store(open_gen, Ordering::Release);

    snap.playback_state
        .store(playback_state_val, Ordering::Release);
    snap.is_xfading
        .store(ply.music_manager.is_crossfading(), Ordering::Release);
    snap.is_recording
        .store(ply.output_manager.is_recording(), Ordering::Release);
    snap.recorded_duration_ms.store(
        ply.output_manager.recorded_duration_ms(),
        Ordering::Release,
    );
    snap.is_ducking
        .store(ply.input_manager.is_ducking_active(), Ordering::Release);
    snap.mic_rms_bits
        .store(ply.input_manager.last_rms_db().to_bits(), Ordering::Release);

    let is_buffering_val = if pending_open {
        let seek_ms = ply
            .music_manager
            .inner
            .pending_open_seek_ms
            .load(Ordering::Relaxed);
        snap.position_ms.store(seek_ms, Ordering::Release);
        snap.buffered_start_ms.store(0, Ordering::Release);
        snap.buffered_end_ms.store(0, Ordering::Release);
        snap.is_buffering.store(true, Ordering::Release);
        snap.has_buffered_range.store(true, Ordering::Release);
        true
    } else {
        snap.position_ms.store(
            active_deck.position_ms.load(Ordering::Relaxed),
            Ordering::Release,
        );
        let mut br = crate::bridge::ffi::MiniaudioBufferedRange::default();
        if active_deck.get_buffered_range(&mut br) == 0 {
            snap.buffered_start_ms.store(br.start_ms, Ordering::Release);
            snap.buffered_end_ms.store(br.end_ms, Ordering::Release);
            let buf = br.is_buffering != 0;
            snap.is_buffering.store(buf, Ordering::Release);
            snap.has_buffered_range.store(true, Ordering::Release);
            buf
        } else {
            let buf = active_deck.is_buffering.load(Ordering::Relaxed);
            snap.is_buffering.store(buf, Ordering::Release);
            snap.has_buffered_range.store(false, Ordering::Release);
            buf
        }
    };

    snap.current_index.store(cur_idx_val, Ordering::Release);
    snap.active_deck.store(active_deck_idx, Ordering::Release);
    snap.meta_version.store(meta_ver, Ordering::Release);
    snap.flush_generation.store(flush_gen, Ordering::Release);

    let (rg_gain, rg_peak) = ply.active_replay_gain;
    snap.replay_gain_packed.store(
        EngineUiSnapshots::pack_rg(rg_gain, rg_peak),
        Ordering::Release,
    );

    let vis_enabled = ply
        .output_manager
        .visualizer_enabled
        .load(Ordering::Relaxed);
    snap.visualizer_enabled
        .store(vis_enabled, Ordering::Release);
    if vis_enabled {
        let vis = ply.output_manager.visualizer_seqlock.read();
        snap.visualizer_seqlock.write(|dst| *dst = vis);
    }
    snap.visualizer_source.store(
        ply.output_manager.visualizer_source() as i32,
        Ordering::Release,
    );
    snap.pause_on_device_change.store(
        ply.output_manager
            .pause_on_device_change
            .load(Ordering::Relaxed),
        Ordering::Release,
    );

    let sr = active_deck.sample_rate.load(Ordering::Relaxed);
    let ch = active_deck.channels.load(Ordering::Relaxed);
    let audio_info_key = (
        pending_open,
        active_deck_idx,
        deck_id,
        open_gen,
        flush_gen,
        dur_ms,
        sr,
        ch,
    );
    if audio_info_key != cache.last_audio_info_key {
        cache.last_audio_info_key = audio_info_key;
        *write_unpoisoned(&snap.audio_info) = if pending_open {
            RustAudioInfo::default()
        } else {
            active_deck.get_audio_info()
        };
    }

    let meta_key = (
        pending_open,
        active_deck_idx,
        deck_id,
        open_gen,
        meta_ver,
        flush_gen,
    );
    if meta_key != cache.last_meta_key {
        cache.last_meta_key = meta_key;
        *write_unpoisoned(&snap.parsed_metadata) = if pending_open {
            None
        } else {
            active_deck.get_parsed_metadata()
        };
    }
    snap.pub_seq.fetch_add(1, Ordering::Release);

    let wake_key = (cur_idx_val, playback_state_val, is_buffering_val);
    if wake_key != cache.last_wake_key {
        cache.last_wake_key = wake_key;
        snap.notify_telemetry_waiters();
    }
}

/// Deduplication state preventing repeated `PrewarmNeeded` and `AutoAdvanceNeeded` hints
/// within the same deck/open/seek generation.
#[derive(Default)]
struct LifecycleHintState {
    /// Last emitted prewarm hint key: `(deck_id, open_gen, current_index)`.
    last_prewarm_hint_key: Option<(usize, u64, i64)>,
    /// Last emitted auto-advance hint key: `(deck_id, open_gen, seek_epoch, next_idx, item_id)`.
    last_auto_advance_key: Option<(usize, u64, u64, usize, i64)>,
}

/// Evaluates crossfade completion, standby prewarm readiness, track EOF/auto-advance,
/// recording errors, and Infinite Mix replenishment on `ply`, pushing discrete events to
/// `notices` and non-blocking coordinator hints to `hint_tx` using `hint_state` for deduplication.
fn tick_music_lifecycle(
    ply: &mut MiniaudioPlayer,
    notices: &mut Vec<RtEngineNotice>,
    hint_tx: &crossbeam_channel::Sender<RtControlHint>,
    hint_state: &mut LifecycleHintState,
) {
    if let Some(err_msg) = ply.output_manager.poll_async_recording_error() {
        notices.push(RtEngineNotice::RecordingError {
            message: err_msg,
            code: -1,
        });
    }
    let xfade_trans = ply.music_manager.inner.crossfade.transition();
    let is_xfade_active = xfade_trans != QueueTransition::Idle;
    let mut xfade_done = ply
        .music_manager
        .inner
        .crossfade_completed_flag
        .swap(false, Ordering::AcqRel);
    let cur_f = ply
        .music_manager
        .inner
        .crossfade
        .current_frame
        .load(Ordering::Relaxed);
    let tot_f = ply
        .music_manager
        .inner
        .crossfade
        .total_frames
        .load(Ordering::Relaxed);
    let target_id = ply
        .music_manager
        .inner
        .crossfade_target_id
        .load(Ordering::Relaxed);

    if !xfade_done && is_xfade_active && (tot_f > 0 && cur_f >= tot_f) {
        ply.music_manager.inner.crossfade.abort();
        xfade_done = true;
    }
    if !xfade_done && !is_xfade_active && target_id >= 0 {
        xfade_done = true;
    }
    if !xfade_done && xfade_trans == QueueTransition::AutoCrossfade {
        let from_deck_idx = ply
            .music_manager
            .inner
            .crossfade
            .from_deck
            .load(Ordering::Relaxed);
        let from_deck = if from_deck_idx == 0 {
            &ply.music_manager.inner.deck_a
        } else {
            &ply.music_manager.inner.deck_b
        };
        if from_deck.track_exhausted.load(Ordering::Acquire) {
            ply.music_manager.inner.crossfade.abort();
            xfade_done = true;
        }
    }

    if xfade_done {
        let to_deck = ply
            .music_manager
            .inner
            .crossfade
            .to_deck
            .load(Ordering::Relaxed);
        ply.music_manager
            .inner
            .active_deck
            .store(to_deck, Ordering::Release);
        let from_slot = if to_deck == 0 {
            &mut ply.music_manager.inner.deck_b
        } else {
            &mut ply.music_manager.inner.deck_a
        };
        from_slot.stop();
        from_slot.clear_queue_item_assignment();

        let target_id = ply
            .music_manager
            .inner
            .crossfade_target_id
            .swap(-1, Ordering::AcqRel);
        if target_id >= 0 {
            let new_idx_opt = read_unpoisoned(&ply.music_manager.inner.queue)
                .iter()
                .position(|it| it.id == target_id);
            if let Some(new_idx) = new_idx_opt {
                ply.music_manager
                    .inner
                    .current_index
                    .store(new_idx as i64, Ordering::Release);
                ply.music_manager.inner.sync_planned_index_to_current();
                let (g, p) = ply.recalculate_and_apply_replay_gain();
                notices.push(RtEngineNotice::ReplayGain {
                    gain_db: g,
                    peak: p,
                });
            }
        }

        hint_state.last_prewarm_hint_key = None;
        hint_state.last_auto_advance_key = None;
        let _ = hint_tx.try_send(RtControlHint::PrewarmNeeded);
        notices.push(RtEngineNotice::IsCrossfading(false));
    }

    let cur_playback = PlaybackState::from_i32(
        ply.music_manager
            .inner
            .playback_state
            .load(Ordering::Relaxed),
    );
    let is_xfading = ply.music_manager.inner.crossfade.is_active();
    let active_deck = ply.music_manager.active_deck_ref();
    let cur_deck_id = active_deck.deck_id;
    let cur_open_gen = active_deck.open_generation.load(Ordering::Acquire);
    let cur_seek_epoch = active_deck.seek_epoch.load(Ordering::Acquire);
    let pos = active_deck.position_ms.load(Ordering::Relaxed);
    let dur = active_deck.duration_ms.load(Ordering::Relaxed);
    let current_idx = ply
        .music_manager
        .inner
        .current_index
        .load(Ordering::Relaxed);

    let can_trigger = !is_xfading
        && !ply
            .music_manager
            .inner
            .pending_open_active
            .load(Ordering::Acquire)
        && active_deck.seek_request_ms.load(Ordering::Acquire) < 0
        && current_idx >= 0
        && cur_playback == PlaybackState::Playing;

    if can_trigger {
        let auto_ms = ply
            .music_manager
            .inner
            .auto_crossfade_duration_ms
            .load(Ordering::Relaxed);
        let q_len = read_unpoisoned(&ply.music_manager.inner.queue).len();
        let loop_m = ply.music_manager.inner.loop_mode.load(Ordering::Relaxed);
        let is_loop_one = loop_m == 1;

        let has_next_track = if q_len > 0 {
            let n = current_idx + 1;
            (n as usize) < q_len || loop_m == 2
        } else {
            false
        };
        let has_prewarm_target =
            has_next_track || (is_loop_one && q_len > 0 && (current_idx as usize) < q_len);

        let should_auto_xfade = !is_loop_one
            && has_next_track
            && auto_ms > 0
            && dur > (auto_ms as i64)
            && (pos + (auto_ms as i64) >= dur);
        let reached_eof = active_deck.track_exhausted.load(Ordering::Acquire)
            || (dur > 0 && pos >= dur && pos > 0);
        let is_eof = !should_auto_xfade && reached_eof;

        let standby_id = ply
            .music_manager
            .inner
            .standby_ready_id
            .load(Ordering::Relaxed);
        if has_prewarm_target
            && standby_id < 0
            && !should_auto_xfade
            && !reached_eof
            && (dur <= 0 || pos + (auto_ms as i64) + 15_000 >= dur)
        {
            let prewarm_key = (cur_deck_id, cur_open_gen, current_idx);
            if hint_state.last_prewarm_hint_key != Some(prewarm_key) {
                hint_state.last_prewarm_hint_key = Some(prewarm_key);
                let _ = hint_tx.try_send(RtControlHint::PrewarmNeeded);
            }
        }

        if should_auto_xfade || reached_eof {
            let next_idx_opt = if is_loop_one {
                if (current_idx as usize) < q_len {
                    Some(current_idx as usize)
                } else {
                    None
                }
            } else if has_next_track {
                let n = current_idx + 1;
                if (n as usize) < q_len {
                    Some(n as usize)
                } else {
                    Some(0)
                }
            } else {
                None
            };

            if let Some(next_idx) = next_idx_opt {
                let item_opt = read_unpoisoned(&ply.music_manager.inner.queue)
                    .get(next_idx)
                    .cloned();
                if let Some(item) = item_opt {
                    if ply.music_manager.inner.standby_is_ready_for(&item) {
                        let mode = if should_auto_xfade && !reached_eof {
                            let eff_ms = if dur > pos {
                                ((dur - pos) as u64).clamp(50, auto_ms)
                            } else {
                                auto_ms
                            };
                            TransitionCommitMode::AutoCrossfade { eff_ms }
                        } else {
                            TransitionCommitMode::AutoAdvanceGapless
                        };
                        let _displaced = ply.music_manager.inner.commit_transition_internal(
                            None,
                            &item,
                            None,
                            mode,
                        );
                        if should_auto_xfade && !reached_eof {
                            notices.push(RtEngineNotice::IsCrossfading(true));
                        } else {
                            let (g, p) = ply.recalculate_and_apply_replay_gain();
                            notices.push(RtEngineNotice::ReplayGain {
                                gain_db: g,
                                peak: p,
                            });
                        }
                        hint_state.last_auto_advance_key = None;
                        hint_state.last_prewarm_hint_key = None;
                        let _ = hint_tx.try_send(RtControlHint::PrewarmNeeded);
                    } else {
                        if reached_eof {
                            ply.music_manager
                                .inner
                                .pending_auto_advance_prev_index
                                .store(current_idx, Ordering::Release);
                            ply.music_manager
                                .inner
                                .current_index
                                .store(next_idx as i64, Ordering::Release);
                            ply.music_manager
                                .inner
                                .planned_index
                                .store(next_idx as i64, Ordering::Release);
                            ply.music_manager
                                .inner
                                .pending_open_seek_ms
                                .store(0, Ordering::Release);
                            ply.music_manager
                                .inner
                                .pending_open_active
                                .store(true, Ordering::Release);
                        }
                        let adv_key = (cur_deck_id, cur_open_gen, cur_seek_epoch, next_idx, item.id);
                        if hint_state.last_auto_advance_key != Some(adv_key) {
                            hint_state.last_auto_advance_key = Some(adv_key);
                            let _ = hint_tx.try_send(RtControlHint::AutoAdvanceNeeded {
                                expected_deck_id: cur_deck_id,
                                expected_open_gen: cur_open_gen,
                                expected_seek_epoch: cur_seek_epoch,
                                next_idx,
                                item,
                                should_auto_xfade: should_auto_xfade && !reached_eof,
                                auto_ms,
                            });
                        }
                    }
                }
            } else if is_eof {
                ply.music_manager
                    .inner
                    .playback_state
                    .store(PlaybackState::Stopped.as_i32(), Ordering::Release);
                let active_deck = ply.music_manager.active_deck_mut();
                active_deck.finish_at_end();
            }
        }
    }

    // Infinite Mix replenishment check
    if ply
        .music_manager
        .inner
        .infinite_mix_enabled
        .load(Ordering::Relaxed)
    {
        let cur_playback = PlaybackState::from_i32(
            ply.music_manager
                .inner
                .playback_state
                .load(Ordering::Relaxed),
        );
        if cur_playback == PlaybackState::Playing {
            let current_idx = ply
                .music_manager
                .inner
                .current_index
                .load(Ordering::Relaxed);
            let q = read_unpoisoned(&ply.music_manager.inner.queue);
            let q_len = q.len();
            if current_idx >= 0 && (current_idx as usize) < q_len {
                let current_id = q[current_idx as usize].id;
                let remaining = (q_len - 1).saturating_sub(current_idx as usize);
                let threshold = ply
                    .music_manager
                    .inner
                    .infinite_mix_threshold
                    .load(Ordering::Relaxed);
                if remaining < threshold {
                    let last_id = ply
                        .music_manager
                        .inner
                        .last_notified_infinite_mix_id
                        .load(Ordering::Relaxed);
                    if last_id != current_id {
                        ply.music_manager
                            .inner
                            .last_notified_infinite_mix_id
                            .store(current_id, Ordering::Release);
                        notices.push(RtEngineNotice::NeedMoreTracks {
                            current_track_id: current_id,
                            remaining_tracks: remaining as u32,
                        });
                    }
                }
            }
        }
    }
}

/// Handle to the single-owner `map-engine-clock` audio actor, SFX controller, and wait-free snapshots.
#[derive(Clone)]
pub struct EngineActorHandle {
    /// Wake-capable queue delivering synchronous and asynchronous commands to `map-engine-clock`.
    cmd_queue: Arc<WakeQueue<RtActorMsg>>,
    /// Lock-free / wait-free UI and telemetry snapshot store published by `map-engine-clock`.
    snapshots: Arc<EngineUiSnapshots>,
    /// Lock-free SFX control handle bypassing the real-time clock thread.
    effects: EffectsControl,
    /// Off-RT reaper handle used to drop heavy objects outside the audio clock thread.
    reaper: ReaperHandle,
    /// Lock-free multi-bus audio tap registry shared with callers and output sinks.
    tap_registry: Arc<crate::core::tap::TapBusRegistry>,
    /// Flag indicating whether [`EngineActorHandle::shutdown`] has been called.
    disposed: Arc<AtomicBool>,
    /// Join handle for the `map-engine-clock` thread.
    clock_thread: Arc<Mutex<Option<JoinHandle<()>>>>,
}

impl EngineActorHandle {
    /// Spawns `map-reaper` and `map-engine-clock`, giving the clock thread exclusive ownership of
    /// `MiniaudioPlayer`.
    ///
    /// Configures the engine with `sample_rate`, `channels`, `period_size`, `max_voices`,
    /// `max_ram_bytes`, `device_trigger`, `pause_on_device_change`, `visualizer_source`, and
    /// `initial_outputs`.
    pub fn spawn(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        max_voices: usize,
        max_ram_bytes: Option<usize>,
        device_trigger: Option<Arc<(Mutex<bool>, Condvar)>>,
        pause_on_device_change: bool,
        visualizer_source: i32,
        initial_outputs: Vec<RustAudioOutput>,
    ) -> Result<
        (
            Self,
            crossbeam_channel::Receiver<RtEngineNotice>,
            crossbeam_channel::Receiver<RtControlHint>,
        ),
        String,
    > {
        crate::map_log!(
            3,
            "[ENGINE_ACTOR] Spawning map-engine-clock (sr={}, ch={}, period={}, max_voices={}, outputs={})",
            sample_rate,
            channels,
            period_size,
            max_voices,
            initial_outputs.len()
        );
        let mut player = MiniaudioPlayer::new(
            sample_rate,
            channels,
            period_size,
            max_voices,
            max_ram_bytes,
            device_trigger,
        )?;
        player
            .output_manager
            .set_pause_on_device_change(pause_on_device_change);
        player
            .output_manager
            .set_visualizer_source(crate::api::types::AudioOutputSource::from(visualizer_source));
        if let Err(e) = player.output_manager.set_outputs(initial_outputs) {
            crate::map_log!(
                2,
                "[ENGINE_ACTOR] Failed to apply initial outputs during spawn: {}",
                e
            );
        }

        let reaper = ReaperHandle::spawn();
        player.effects_manager.attach_reaper(&reaper);

        let effects = player.effects_manager.control();
        let tap_registry = player.output_manager.tap_registry.clone();
        let snapshots = Arc::new(EngineUiSnapshots::from_player(&player));
        let cmd_queue = Arc::new(WakeQueue::<RtActorMsg>::new());
        let cmd_queue_worker = cmd_queue.clone();
        let (notify_tx, notify_rx) = crossbeam_channel::bounded::<RtEngineNotice>(RT_NOTIFY_CAP);
        let (hint_tx, hint_rx) = crossbeam_channel::bounded::<RtControlHint>(RT_HINT_CAP);

        let period_frames = period_size.max(64) as usize;
        let clock_sr = sample_rate.max(8000);
        let snap_clone = snapshots.clone();

        let clock_jh = {
            let jh = thread::Builder::new()
                .name("map-engine-clock".to_string())
                .spawn(move || {
                    let period_duration = Duration::from_nanos(
                        (period_frames as u64 * 1_000_000_000) / clock_sr as u64,
                    );
                    let mut next_tick = Instant::now();
                    let mut pub_cache = SnapshotPublishCache::default();
                    let mut hint_state = LifecycleHintState::default();
                    let mut pending_notices: Vec<RtEngineNotice> = Vec::with_capacity(8);
                    publish_snapshots(&player, &snap_clone, &mut pub_cache);

                    #[cfg(target_arch = "wasm32")]
                    let web_chunk_frames = period_frames.clamp(256, 512);
                    #[cfg(target_arch = "wasm32")]
                    let mut last_consumer_seq = crate::bridge::ffi::wasm_web_audio_frames_consumed();
                    #[cfg(target_arch = "wasm32")]
                    let mut last_consumer_seen: Option<Instant> = None;

                    let handle_msg = |msg: RtActorMsg,
                                      ply: &mut MiniaudioPlayer,
                                      cache: &mut SnapshotPublishCache|
                     -> bool {
                        match msg {
                            RtActorMsg::Call(task) => {
                                let post = task(ply);
                                publish_snapshots(ply, &snap_clone, cache);
                                if let Some(cb) = post {
                                    cb();
                                }
                                true
                            }
                            RtActorMsg::Shutdown(ack) => {
                                ply.dispose();
                                let (lock, cvar) = &*ack;
                                *lock_unpoisoned(lock) = true;
                                cvar.notify_all();
                                false
                            }
                        }
                    };

                    loop {
                        while let Some(msg) = cmd_queue_worker.try_pop() {
                            if !handle_msg(msg, &mut player, &mut pub_cache) {
                                return;
                            }
                        }

                        #[cfg(target_arch = "wasm32")]
                        {
                            let now = Instant::now();
                            let seq = crate::bridge::ffi::wasm_web_audio_frames_consumed();
                            if seq != last_consumer_seq {
                                last_consumer_seq = seq;
                                last_consumer_seen = Some(now);
                            }
                            let consumer_active = last_consumer_seen
                                .map(|t| now.saturating_duration_since(t) <= Duration::from_millis(250))
                                .unwrap_or(false);

                            let wait_dur = if consumer_active
                                && crate::bridge::ffi::wasm_has_active_output_devices()
                            {
                                let target_cushion =
                                    crate::bridge::ffi::wasm_web_audio_target_cushion_frames();
                                crate::bridge::ffi::wasm_pump_web_audio_ring(true);
                                let mut rendered_any = false;
                                let mut burst = 0usize;
                                while crate::bridge::ffi::wasm_web_audio_queued_frames()
                                    < target_cushion
                                    && burst < 6
                                {
                                    while let Some(msg) = cmd_queue_worker.try_pop() {
                                        if !handle_msg(msg, &mut player, &mut pub_cache) {
                                            return;
                                        }
                                    }
                                    crate::bridge::ffi::wasm_pump_web_capture_rings();
                                    player.render_pcm(web_chunk_frames);
                                    tick_music_lifecycle(
                                        &mut player,
                                        &mut pending_notices,
                                        &hint_tx,
                                        &mut hint_state,
                                    );
                                    crate::bridge::ffi::wasm_pump_web_audio_ring(true);
                                    rendered_any = true;
                                    burst += 1;
                                }
                                if rendered_any {
                                    publish_snapshots(&player, &snap_clone, &mut pub_cache);
                                    for notice in pending_notices.drain(..) {
                                        let _ = notify_tx.try_send(notice);
                                    }
                                }
                                next_tick = Instant::now() + period_duration;

                                let queued = crate::bridge::ffi::wasm_web_audio_queued_frames();
                                if queued < target_cushion {
                                    Duration::from_millis(2)
                                } else {
                                    let low_water =
                                        target_cushion.saturating_sub(web_chunk_frames as u32);
                                    let headroom = queued.saturating_sub(low_water);
                                    let host_sr =
                                        crate::bridge::ffi::wasm_get_web_audio_host_sample_rate()
                                            .max(8000);
                                    let wait_ms = ((headroom as u64 * 1000) / host_sr as u64)
                                        .clamp(2, 12);
                                    Duration::from_millis(wait_ms)
                                }
                            } else {
                                if now >= next_tick {
                                    crate::bridge::ffi::wasm_pump_web_capture_rings();
                                    player.render_pcm(period_frames);
                                    tick_music_lifecycle(
                                        &mut player,
                                        &mut pending_notices,
                                        &hint_tx,
                                        &mut hint_state,
                                    );
                                    crate::bridge::ffi::wasm_pump_web_audio_ring(consumer_active);
                                    publish_snapshots(&player, &snap_clone, &mut pub_cache);
                                    for notice in pending_notices.drain(..) {
                                        let _ = notify_tx.try_send(notice);
                                    }
                                    next_tick += period_duration;
                                    let after = Instant::now();
                                    if next_tick + period_duration < after {
                                        next_tick = after;
                                    }
                                }
                                next_tick.saturating_duration_since(Instant::now())
                            };

                            if !wait_dur.is_zero() {
                                match cmd_queue_worker.wait_pop_timeout(wait_dur) {
                                    Ok(msg) => {
                                        if !handle_msg(msg, &mut player, &mut pub_cache) {
                                            return;
                                        }
                                    }
                                    Err(WakeRecvError::Timeout) => {}
                                    Err(WakeRecvError::Disconnected) => {
                                        player.dispose();
                                        return;
                                    }
                                }
                            }
                        }

                        #[cfg(not(target_arch = "wasm32"))]
                        {
                            let now = Instant::now();
                            if now >= next_tick {
                                player.render_pcm(period_frames);
                                tick_music_lifecycle(
                                    &mut player,
                                    &mut pending_notices,
                                    &hint_tx,
                                    &mut hint_state,
                                );
                                publish_snapshots(&player, &snap_clone, &mut pub_cache);
                                // Dispatch edge notices only after snapshot publication so monitors reading
                                // `EngineUiSnapshots` on wake never observe stale track index/metadata.
                                let had_notices = !pending_notices.is_empty();
                                for notice in pending_notices.drain(..) {
                                    let _ = notify_tx.try_send(notice);
                                }
                                if had_notices {
                                    snap_clone.notify_telemetry_waiters();
                                }
                                next_tick += period_duration;
                                let after = Instant::now();
                                if next_tick + period_duration < after {
                                    next_tick = after;
                                }
                            } else {
                                match cmd_queue_worker.wait_pop_timeout(next_tick - now) {
                                    Ok(msg) => {
                                        if !handle_msg(msg, &mut player, &mut pub_cache) {
                                            return;
                                        }
                                    }
                                    Err(WakeRecvError::Timeout) => {}
                                    Err(WakeRecvError::Disconnected) => {
                                        player.dispose();
                                        return;
                                    }
                                }
                            }
                        }
                    }
                })
                .map_err(|e| {
                    let msg = format!("Failed to spawn map-engine-clock: {}", e);
                    crate::map_log!(1, "[ENGINE_ACTOR] {}", msg);
                    msg
                })?;
            Some(jh)
        };

        Ok((
            Self {
                cmd_queue,
                snapshots,
                effects,
                reaper,
                tap_registry,
                disposed: Arc::new(AtomicBool::new(false)),
                clock_thread: Arc::new(Mutex::new(clock_jh)),
            },
            notify_rx,
            hint_rx,
        ))
    }

    /// Returns wait-free/non-blocking UI & telemetry snapshots.
    #[inline]
    pub fn snapshots(&self) -> &Arc<EngineUiSnapshots> {
        &self.snapshots
    }

    /// Returns the lock-free SFX control handle that bypasses the RT clock thread completely.
    #[inline]
    pub fn effects(&self) -> &EffectsControl {
        &self.effects
    }

    /// Returns the off-RT Reaper handle.
    #[inline]
    pub fn reaper(&self) -> &ReaperHandle {
        &self.reaper
    }

    /// Returns the lock-free Multi-Bus Audio Tap registry without touching the RT clock thread.
    #[inline]
    pub fn tap_registry(&self) -> &Arc<crate::core::tap::TapBusRegistry> {
        &self.tap_registry
    }

    /// Executes closure `f` synchronously against the single-owner engine actor, waking the clock
    /// thread immediately and publishing updated snapshots before replying.
    pub fn exec<R: Send + 'static>(
        &self,
        f: impl FnOnce(&mut MiniaudioPlayer) -> R + Send + 'static,
    ) -> Result<R, String> {
        if self.disposed.load(Ordering::Acquire) {
            return Err("AudioEngineDisposed: engine has been disposed".to_string());
        }
        let (tx, rx) = crossbeam_channel::bounded::<R>(1);
        if !self.cmd_queue.send(RtActorMsg::Call(Box::new(move |ply| {
            let res = f(ply);
            Some(Box::new(move || {
                let _ = tx.send(res);
            }))
        }))) {
            crate::map_log!(2, "[ENGINE_ACTOR] exec rejected: clock actor stopped");
            return Err("AudioEngineDisposed: clock actor stopped".to_string());
        }
        if crate::sync::can_block_current_thread() {
            rx.recv().map_err(|_| {
                crate::map_log!(2, "[ENGINE_ACTOR] exec failed: clock actor dropped reply");
                "AudioEngineDisposed: clock actor dropped reply".to_string()
            })
        } else {
            loop {
                match rx.try_recv() {
                    Ok(v) => return Ok(v),
                    Err(crossbeam_channel::TryRecvError::Empty) => std::hint::spin_loop(),
                    Err(crossbeam_channel::TryRecvError::Disconnected) => {
                        crate::map_log!(2, "[ENGINE_ACTOR] exec failed: clock actor dropped reply");
                        return Err("AudioEngineDisposed: clock actor dropped reply".to_string());
                    }
                }
            }
        }
    }

    /// Posts an asynchronous fire-and-forget mutation `f` to `map-engine-clock`.
    pub fn exec_async(
        &self,
        f: impl FnOnce(&mut MiniaudioPlayer) + Send + 'static,
    ) {
        if self.disposed.load(Ordering::Acquire) {
            return;
        }
        let _ = self.cmd_queue.send(RtActorMsg::Call(Box::new(move |ply| {
            f(ply);
            None
        })));
    }

    /// Shuts down `map-engine-clock` and `map-reaper` deterministically (idempotent).
    pub fn shutdown(&self) {
        if self.disposed.swap(true, Ordering::AcqRel) {
            return;
        }
        crate::map_log!(3, "[ENGINE_ACTOR] Shutting down map-engine-clock and map-reaper");
        self.tap_registry.shutdown();
        let ack = Arc::new((Mutex::new(false), Condvar::new()));
        if self.cmd_queue.send(RtActorMsg::Shutdown(ack.clone()))
            && crate::sync::can_block_current_thread()
        {
            let deadline = Instant::now() + Duration::from_secs(3);
            let (lock, cvar) = &*ack;
            let mut done = lock_unpoisoned(lock);
            while !*done {
                let now = Instant::now();
                if now >= deadline {
                    crate::map_log!(
                        2,
                        "[ENGINE_ACTOR] Timed out waiting for map-engine-clock shutdown ack"
                    );
                    break;
                }
                done = wait_timeout_unpoisoned(cvar, done, deadline - now).0;
            }
        }
        self.cmd_queue.close();
        if let Some(jh) = lock_unpoisoned(&self.clock_thread).take() {
            let _ = jh.join();
        }
        self.reaper.shutdown();
    }
}
