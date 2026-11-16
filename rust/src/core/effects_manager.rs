//! RAM Sound Effects Domain Manager (`EffectsManager`).
//!
//! Decouples cold catalog/decoding/LRU management ([`EffectsControl`] / [`EffectCatalog`])
//! from the lock-free real-time voice renderer ([`VoicePoolRt`]) so heavy disk/network/memory
//! decodes, catalog reloads, and buffer teardown never block RT rendering or UI getters.

use std::sync::{Arc, Mutex, RwLock};

use crate::buffer::DartResolveRegistry;
use crate::core::voice_pool::{
    decode_effect_source, prepare_catalog_items, EffectCatalog, EffectCatalogItem, EffectConfig,
    RtVoiceCmd, RtVoiceDone, SharedVoiceMetrics, SoundBuffer, VoicePoolRt,
};
use crate::dsp::spatial::{SpatialEmitter, SpatialListener};
use crate::sync::{lock_unpoisoned, read_unpoisoned, write_unpoisoned, ReaperHandle};

const RT_VOICE_CMD_QUEUE_CAP: usize = 2048;
const RT_VOICE_DONE_QUEUE_CAP: usize = 256;

/// Cloneable control-plane handle for polyphonic SFX catalog, triggering, and wait-free telemetry.
#[derive(Clone)]
pub struct EffectsControl {
    catalog: Arc<Mutex<EffectCatalog>>,
    cmd_tx: crossbeam_channel::Sender<RtVoiceCmd>,
    metrics: Arc<SharedVoiceMetrics>,
    loaded_ids_snapshot: Arc<RwLock<Vec<String>>>,
    reaper: Arc<RwLock<Option<ReaperHandle>>>,
    dart_resolver: Arc<RwLock<Option<Arc<DartResolveRegistry>>>>,
}

impl EffectsControl {
    /// Attaches the shared Dart resolution bridge used by deferred SFX sources.
    pub fn attach_dart_resolver(&self, resolver: Arc<DartResolveRegistry>) {
        *write_unpoisoned(&self.dart_resolver) = Some(resolver);
    }

    #[inline]
    fn refresh_loaded_ids(&self, ids: Vec<String>) {
        *write_unpoisoned(&self.loaded_ids_snapshot) = ids;
    }

    #[inline]
    fn drop_buffers_off_lock(&self, buffers: Vec<SoundBuffer>) {
        if buffers.is_empty() {
            return;
        }
        let reaper_opt = read_unpoisoned(&self.reaper).clone();
        if let Some(reaper) = reaper_opt {
            reaper.reap_sound_buffers(buffers);
        } else {
            drop(buffers);
        }
    }

    /// Declaratively registers the sound effect catalog.
    ///
    /// Memory-backed effects are decoded BEFORE acquiring the catalog mutex so heavy
    /// decoding never stalls live playback, telemetry getters, or active voices.
    pub fn set_effects(&self, effects: Vec<EffectCatalogItem>) -> Result<(), String> {
        let resolver = read_unpoisoned(&self.dart_resolver).clone();
        let prepared = prepare_catalog_items(effects, resolver.as_ref())?;
        let (displaced, loaded_ids) = {
            let mut cat = lock_unpoisoned(&self.catalog);
            let displaced = cat.apply_prepared_effects(prepared);
            let ids = cat.loaded_effect_ids();
            (displaced, ids)
        };
        self.refresh_loaded_ids(loaded_ids);
        self.drop_buffers_off_lock(displaced);
        Ok(())
    }

    /// Triggers playback of a registered sound effect by ID, decoding file/network sources
    /// strictly outside all locks before atomically installing and spawning in the RT pool.
    pub fn play_effect(&self, id: &str, config: EffectConfig) -> Result<(u32, bool), String> {
        let mut ram_changed = false;

        for retried in [false, true] {
            let decode_target = {
                let mut cat = lock_unpoisoned(&self.catalog);
                match cat.lookup_decode_target(id)? {
                    None => {
                        let voice_id = cat.play_cached_effect(id, config)?;
                        return Ok((voice_id, ram_changed));
                    }
                    Some(target) => target,
                }
            };

            let (expected_key, src) = decode_target;
            let resolver = read_unpoisoned(&self.dart_resolver).clone();
            let decoded = decode_effect_source(id, &src, resolver.as_ref())?;

            let mut cat = lock_unpoisoned(&self.catalog);
            let (inserted, displaced) = cat.install_decoded_buffer(id, expected_key, decoded);
            ram_changed |= inserted;
            let ids = inserted.then(|| cat.loaded_effect_ids());
            let play_res = cat.play_cached_effect(id, config.clone());
            drop(cat);

            if let Some(ids) = ids {
                self.refresh_loaded_ids(ids);
            }
            self.drop_buffers_off_lock(displaced);

            match play_res {
                Ok(voice_id) => return Ok((voice_id, ram_changed)),
                Err(e) if !retried && e == "Effect buffer is not loaded" => continue,
                Err(e) => return Err(e),
            }
        }

        Err("Effect buffer is not loaded".to_string())
    }

    /// Returns `true` when RT has posted voice completions needing cold reconciliation.
    #[inline]
    pub fn has_pending_completions(&self) -> bool {
        self.metrics.has_pending_done()
    }

    /// Non-blocking completion reconciliation returning finished `voice_id`s and optional
    /// updated `(loaded_effect_ids, allocated_ram_bytes)` if LRU eviction occurred.
    pub fn drain_completed_and_evict(&self) -> (Vec<u32>, Option<(Vec<String>, usize)>) {
        if !self.metrics.has_pending_done() {
            return (Vec::new(), None);
        }
        let Ok(mut cat) = self.catalog.try_lock() else {
            return (Vec::new(), None);
        };
        let (completed_ids, evicted) = cat.drain_completed();
        let eviction_info = if evicted {
            let ids = cat.loaded_effect_ids();
            let ram = cat.allocated_ram_bytes;
            Some((ids, ram))
        } else {
            None
        };
        drop(cat);
        if let Some((ref ids, _)) = eviction_info {
            self.refresh_loaded_ids(ids.clone());
        }
        (completed_ids, eviction_info)
    }

    /// Stops playback of an active voice slot.
    #[inline]
    pub fn stop_effect(&self, voice_id: u32, fade_out_samples: usize) {
        let evicted_ids = {
            let mut cat = lock_unpoisoned(&self.catalog);
            if cat.stop_voice(voice_id, fade_out_samples) {
                Some(cat.loaded_effect_ids())
            } else {
                None
            }
        };
        if let Some(ids) = evicted_ids {
            self.refresh_loaded_ids(ids);
        }
    }

    /// Stops all currently active sound effect voices.
    #[inline]
    pub fn stop_all_effects(&self, fade_out_samples: usize) {
        let evicted_ids = {
            let mut cat = lock_unpoisoned(&self.catalog);
            if cat.stop_all(fade_out_samples) {
                Some(cat.loaded_effect_ids())
            } else {
                None
            }
        };
        if let Some(ids) = evicted_ids {
            self.refresh_loaded_ids(ids);
        }
    }

    /// Sets playback volume of an active voice lock-free without acquiring catalog locks.
    #[inline]
    pub fn set_voice_volume(&self, voice_id: u32, volume: f32) {
        let _ = self
            .cmd_tx
            .try_send(RtVoiceCmd::SetVolume { voice_id, volume });
    }

    /// Sets playback pitch multiplier of an active voice lock-free.
    #[inline]
    pub fn set_voice_pitch(&self, voice_id: u32, pitch: f32) {
        let _ = self
            .cmd_tx
            .try_send(RtVoiceCmd::SetPitch { voice_id, pitch });
    }

    /// Sets stereo pan balance of an active voice lock-free.
    #[inline]
    pub fn set_voice_balance(&self, voice_id: u32, balance: f32) {
        let _ = self
            .cmd_tx
            .try_send(RtVoiceCmd::SetBalance { voice_id, balance });
    }

    /// Sets 3D spatial emitter parameters of an active voice lock-free.
    #[inline]
    pub fn set_voice_emitter(&self, voice_id: u32, emitter: Option<SpatialEmitter>) {
        let _ = self
            .cmd_tx
            .try_send(RtVoiceCmd::SetEmitter { voice_id, emitter });
    }

    /// Sets 3D spatial listener position and orientation for all sound effects.
    #[inline]
    pub fn set_listener(&self, listener: SpatialListener) {
        let _ = self.cmd_tx.try_send(RtVoiceCmd::SetListener { listener });
        if let Ok(mut cat) = self.catalog.try_lock() {
            cat.listener = listener;
        }
    }

    /// Updates Doppler effect physics parameters.
    #[inline]
    pub fn set_doppler_parameters(&self, factor: f32, speed_of_sound: f32) {
        let _ = self.cmd_tx.try_send(RtVoiceCmd::SetDoppler {
            factor,
            speed_of_sound,
        });
        if let Ok(mut cat) = self.catalog.try_lock() {
            cat.speed_of_sound = speed_of_sound;
        }
    }

    /// Returns the number of currently active non-stopping voices (wait-free).
    #[inline]
    pub fn active_voices_count(&self) -> u32 {
        self.metrics.active_voices_count()
    }

    /// Returns the total bytes of decoded sound effect PCM currently allocated in RAM (wait-free).
    #[inline]
    pub fn allocated_ram_bytes(&self) -> usize {
        self.metrics.allocated_ram_bytes()
    }

    /// Returns the identifiers of all sound effects currently resident in RAM without blocking on decode I/O.
    #[inline]
    pub fn loaded_effect_ids(&self) -> Vec<String> {
        read_unpoisoned(&self.loaded_ids_snapshot).clone()
    }
}

/// Domain manager coordinating lock-free RT SFX synthesis and off-RT catalog management.
pub struct EffectsManager {
    /// Lock-free real-time voice pool rendered exclusively by the audio clock thread.
    rt_pool: VoicePoolRt,
    /// Shared cold catalog, command sender, and wait-free metrics handle.
    ctrl: EffectsControl,
    /// Preallocated scratch buffer for rendering isolated DSP effect voices.
    pub effects_work_buffer: Vec<f32>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Channel count.
    pub channels: usize,
}

impl EffectsManager {
    /// Creates a new `EffectsManager` with voice capacity and optional memory budget limits.
    pub fn new(
        max_voices: usize,
        max_ram_bytes: Option<usize>,
        sample_rate: u32,
        channels: usize,
    ) -> Self {
        let (cmd_tx, cmd_rx) = crossbeam_channel::bounded(RT_VOICE_CMD_QUEUE_CAP);
        let (done_tx, done_rx) = rtrb::RingBuffer::<RtVoiceDone>::new(RT_VOICE_DONE_QUEUE_CAP);
        let metrics = Arc::new(SharedVoiceMetrics::new());

        let rt_pool = VoicePoolRt::new(
            max_voices,
            sample_rate,
            channels,
            cmd_rx,
            done_tx,
            metrics.clone(),
        );
        let catalog = Arc::new(Mutex::new(EffectCatalog::new(
            max_voices,
            max_ram_bytes,
            cmd_tx.clone(),
            done_rx,
            metrics.clone(),
        )));

        let ctrl = EffectsControl {
            catalog,
            cmd_tx,
            metrics,
            loaded_ids_snapshot: Arc::new(RwLock::new(Vec::new())),
            reaper: Arc::new(RwLock::new(None)),
            dart_resolver: Arc::new(RwLock::new(None)),
        };

        Self {
            rt_pool,
            ctrl,
            effects_work_buffer: vec![0.0; 2048 * channels],
            sample_rate,
            channels,
        }
    }

    /// Returns a cloneable control-plane handle usable outside the real-time engine thread.
    #[inline]
    pub fn control(&self) -> EffectsControl {
        self.ctrl.clone()
    }

    /// Attaches a background [`ReaperHandle`] so retired and displaced SFX buffers are destroyed off-RT.
    pub fn attach_reaper(&mut self, reaper: &ReaperHandle) {
        self.rt_pool.set_reaper(reaper.sound_buffer_reaper_fn());
        *write_unpoisoned(&self.ctrl.reaper) = Some(reaper.clone());
    }

    /// Declaratively registers the sound effect catalog.
    #[inline]
    pub fn set_effects(&self, effects: Vec<EffectCatalogItem>) -> Result<(), String> {
        self.ctrl.set_effects(effects)
    }

    /// Triggers playback of a registered sound effect by ID.
    #[inline]
    pub fn play_effect(&self, id: &str, config: EffectConfig) -> Result<(u32, bool), String> {
        self.ctrl.play_effect(id, config)
    }


    /// Returns `true` when RT has posted voice completions needing cold reconciliation.
    #[inline]
    pub fn has_pending_completions(&self) -> bool {
        self.ctrl.has_pending_completions()
    }

    /// Non-blocking completion reconciliation returning finished `voice_id`s and optional eviction snapshot.
    #[inline]
    pub fn drain_completed_and_evict(&self) -> (Vec<u32>, Option<(Vec<String>, usize)>) {
        self.ctrl.drain_completed_and_evict()
    }

    /// Stops playback of an active voice slot.
    #[inline]
    pub fn stop_effect(&self, voice_id: u32, fade_out_samples: usize) {
        self.ctrl.stop_effect(voice_id, fade_out_samples);
    }

    /// Stops all currently active sound effect voices.
    #[inline]
    pub fn stop_all_effects(&self, fade_out_samples: usize) {
        self.ctrl.stop_all_effects(fade_out_samples);
    }

    /// Sets playback volume of an active voice lock-free.
    #[inline]
    pub fn set_voice_volume(&self, voice_id: u32, volume: f32) {
        self.ctrl.set_voice_volume(voice_id, volume);
    }

    /// Sets playback pitch multiplier of an active voice lock-free.
    #[inline]
    pub fn set_voice_pitch(&self, voice_id: u32, pitch: f32) {
        self.ctrl.set_voice_pitch(voice_id, pitch);
    }

    /// Sets stereo pan balance of an active voice lock-free.
    #[inline]
    pub fn set_voice_balance(&self, voice_id: u32, balance: f32) {
        self.ctrl.set_voice_balance(voice_id, balance);
    }

    /// Sets 3D spatial emitter parameters of an active voice lock-free.
    #[inline]
    pub fn set_voice_emitter(&self, voice_id: u32, emitter: Option<SpatialEmitter>) {
        self.ctrl.set_voice_emitter(voice_id, emitter);
    }

    /// Sets 3D spatial listener position and orientation for all sound effects.
    #[inline]
    pub fn set_listener(&self, listener: SpatialListener) {
        self.ctrl.set_listener(listener);
    }

    /// Updates Doppler effect physics parameters.
    #[inline]
    pub fn set_doppler_parameters(&self, factor: f32, speed_of_sound: f32) {
        self.ctrl.set_doppler_parameters(factor, speed_of_sound);
    }

    /// Renders active polyphonic voices unconditionally with zero mutex locking or dropouts.
    pub fn render_with_reuse(
        &mut self,
        inherit_buffer: &mut [f32],
        super_flow: &mut [f32],
        frame_count: usize,
    ) {
        let sample_count = frame_count * self.channels;
        if self.effects_work_buffer.len() < sample_count {
            self.effects_work_buffer.resize(sample_count, 0.0);
        }
        self.effects_work_buffer[..sample_count].fill(0.0);

        self.rt_pool.render(
            &mut inherit_buffer[..sample_count],
            &mut self.effects_work_buffer[..sample_count],
            &mut super_flow[..sample_count],
            frame_count,
        );
    }

    /// Returns a mutable slice to the isolated scratch work buffer.
    #[inline]
    pub fn work_buffer(&mut self, sample_count: usize) -> &mut [f32] {
        &mut self.effects_work_buffer[..sample_count]
    }

    /// Returns the number of currently active non-stopping voices (wait-free).
    #[inline]
    pub fn active_voices_count(&self) -> u32 {
        self.ctrl.active_voices_count()
    }

    /// Returns the total bytes of decoded sound effect PCM currently allocated in RAM (wait-free).
    #[inline]
    pub fn allocated_ram_bytes(&self) -> usize {
        self.ctrl.allocated_ram_bytes()
    }

    /// Returns the identifiers of all sound effects currently resident in RAM.
    #[inline]
    pub fn loaded_effect_ids(&self) -> Vec<String> {
        self.ctrl.loaded_effect_ids()
    }
}
