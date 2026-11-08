//! Native Miniaudio Player API exposed to Flutter/Dart via flutter_rust_bridge.
//!
//! Exposes `RustMiniaudioPlayer` orchestrating music decks, RAM sound effects,
//! multi-destination output matrix, and microphone capture sidechain.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::bridge::ffi::{
    map_device_enumerate_capture_devices, map_device_enumerate_devices, map_device_free_devices,
};
use crate::core::dual_source::AudioSourceCore;
use crate::core::miniaudio_player::MiniaudioPlayer;
use crate::core::recording::WavFormat;
use crate::core::voice_pool::{DspRouting, EffectCatalogItem, EffectConfig};
use crate::dsp::analysis::{
    analyze_file as dsp_analyze_file, analyze_media_source as dsp_analyze_media_source,
    AudioAnalysisConfig, MAP_ANALYSIS_FLAG_REPLAY_GAIN, MAP_ANALYSIS_FLAG_WAVEFORM,
};
use crate::dsp::equalizer::EqualizerParams;
use crate::dsp::reverb::ReverbConfig;
use crate::dsp::silence::SilenceConfig;
use crate::frb_generated::StreamSink;

use super::types::*;

/// Internal telemetry deduplication filter preventing flooding of the Flutter Rust Bridge channel.
pub struct TelemetryFilter {
    /// Cached playback state code.
    pub state: Option<i32>,
    /// Cached engine phase code.
    pub phase: Option<i32>,
    /// Cached track position in milliseconds.
    pub pos: i64,
    /// Cached track duration in milliseconds.
    pub dur: Option<i64>,
    /// Cached active queue index.
    pub index: Option<i32>,
    /// Cached stream bitrate in bps.
    pub bitrate: Option<u32>,
    /// Cached buffer end boundary in milliseconds.
    pub buffered_end: Option<i64>,
    /// Cached buffering status flag.
    pub is_buffering: Option<bool>,
    /// Cached crossfading status flag.
    pub is_xfading: Option<bool>,
    /// Cached recording status flag.
    pub is_recording: Option<bool>,
    /// Cached ducking active flag.
    pub is_ducking: Option<bool>,
    /// Cached playing status flag.
    pub is_playing: Option<bool>,
    /// Cached completion flag.
    pub is_completed: Option<bool>,
    /// Cached ReplayGain settings tuple (gain bits, peak bits).
    pub replay_gain: Option<(u32, u32)>,
    /// Cached raw ICY/ID3 metadata byte sequence.
    pub meta_bytes: Option<Vec<u8>>,
    /// Cached count of concurrent active sound effect voices.
    pub active_voices: Option<u32>,
}

impl Default for TelemetryFilter {
    fn default() -> Self {
        Self {
            state: Some(0),
            phase: Some(0),
            pos: 0,
            dur: None,
            index: Some(-1),
            bitrate: None,
            buffered_end: None,
            is_buffering: Some(false),
            is_xfading: Some(false),
            is_recording: Some(false),
            is_ducking: Some(false),
            is_playing: Some(false),
            is_completed: Some(false),
            replay_gain: None,
            meta_bytes: None,
            active_voices: None,
        }
    }
}

/// Dispatches engine events to the Flutter Rust Bridge stream sink with deduplication filtering.
#[derive(Clone)]
pub struct EventReporter {
    event_sink: Arc<Mutex<Option<StreamSink<RustPlayerEvent>>>>,
    pending_events: Arc<Mutex<Vec<RustPlayerEvent>>>,
    filter: Arc<Mutex<TelemetryFilter>>,
}

impl EventReporter {
    /// Creates a new empty `EventReporter` instance.
    pub fn new() -> Self {
        Self {
            event_sink: Arc::new(Mutex::new(None)),
            pending_events: Arc::new(Mutex::new(Vec::new())),
            filter: Arc::new(Mutex::new(TelemetryFilter::default())),
        }
    }

    /// Attaches an active Flutter Rust Bridge stream sink, flushing any queued events.
    pub fn set_sink(&self, sink: StreamSink<RustPlayerEvent>) {
        if let Ok(mut pending) = self.pending_events.lock() {
            for ev in pending.drain(..) {
                let _ = sink.add(ev);
            }
        }
        let mut guard = self.event_sink.lock().unwrap();
        *guard = Some(sink);
    }

    /// Detaches the active stream sink.
    pub fn clear_sink(&self) {
        if let Ok(mut guard) = self.event_sink.lock() {
            *guard = None;
        }
    }

    /// Emits an event to Dart if it passes the deduplication filter.
    pub fn emit(&self, event: RustPlayerEvent) {
        let mut filter = self.filter.lock().unwrap();
        let should_emit = match &event {
            RustPlayerEvent::State(p) => {
                if filter.phase == Some(*p) {
                    false
                } else {
                    filter.phase = Some(*p);
                    true
                }
            }
            RustPlayerEvent::PlaybackState(s) => {
                if filter.state == Some(*s) {
                    false
                } else {
                    filter.state = Some(*s);
                    true
                }
            }
            RustPlayerEvent::CurrentIndex(idx) => {
                if filter.index == Some(*idx) {
                    false
                } else {
                    filter.index = Some(*idx);
                    filter.bitrate = None;
                    filter.buffered_end = None;
                    true
                }
            }
            RustPlayerEvent::IsPlaying(b) => {
                if filter.is_playing == Some(*b) {
                    false
                } else {
                    filter.is_playing = Some(*b);
                    true
                }
            }
            RustPlayerEvent::IsCompleted(b) => {
                if filter.is_completed == Some(*b) {
                    false
                } else {
                    filter.is_completed = Some(*b);
                    true
                }
            }
            RustPlayerEvent::IsCrossfading(b) => {
                if filter.is_xfading == Some(*b) {
                    false
                } else {
                    filter.is_xfading = Some(*b);
                    true
                }
            }
            RustPlayerEvent::IsRecording(b) => {
                if filter.is_recording == Some(*b) {
                    false
                } else {
                    filter.is_recording = Some(*b);
                    true
                }
            }
            RustPlayerEvent::IsDuckingActive(b) => {
                if filter.is_ducking == Some(*b) {
                    false
                } else {
                    filter.is_ducking = Some(*b);
                    true
                }
            }
            RustPlayerEvent::ReplayGain(rg) => {
                let key = (rg.gain_db.to_bits(), rg.peak.to_bits());
                if filter.replay_gain == Some(key) {
                    false
                } else {
                    filter.replay_gain = Some(key);
                    true
                }
            }
            RustPlayerEvent::Duration(d) => {
                if filter.dur == Some(*d) {
                    false
                } else {
                    filter.dur = Some(*d);
                    true
                }
            }
            RustPlayerEvent::Bitrate(b) => {
                if filter.bitrate == Some(*b) || *b == 0 {
                    false
                } else {
                    filter.bitrate = Some(*b);
                    true
                }
            }
            RustPlayerEvent::Buffer(r) => {
                if filter.buffered_end == Some(r.end_ms) && filter.is_buffering == Some(r.is_buffering) {
                    false
                } else {
                    filter.buffered_end = Some(r.end_ms);
                    filter.is_buffering = Some(r.is_buffering);
                    true
                }
            }
            RustPlayerEvent::ActiveVoices(v) => {
                if filter.active_voices == Some(*v) {
                    false
                } else {
                    filter.active_voices = Some(*v);
                    true
                }
            }
            RustPlayerEvent::Position(p) => {
                if (*p - filter.pos).abs() < 10 && !(*p == 0 && filter.pos != 0) {
                    false
                } else {
                    filter.pos = *p;
                    true
                }
            }
            RustPlayerEvent::MetaBytes(b) => {
                if filter.meta_bytes.as_ref() == Some(b) {
                    false
                } else {
                    filter.meta_bytes = Some(b.clone());
                    true
                }
            }
            _ => true,
        };
        if !should_emit {
            return;
        }
        drop(filter);

        if let Ok(guard) = self.event_sink.lock() {
            if let Some(ref sink) = *guard {
                let _ = sink.add(event);
                return;
            }
        }
        if let Ok(mut pending) = self.pending_events.lock() {
            pending.push(event);
        }
    }
}

/// Primary native audio engine instance exposed to Dart via Flutter Rust Bridge.
pub struct RustMiniaudioPlayer {
    inner: Arc<Mutex<Box<MiniaudioPlayer>>>,
    reporter: EventReporter,
    custom_handle: Arc<Mutex<Option<crate::buffer::CustomByteSourceHandle>>>,
    monitor_running: Arc<AtomicBool>,
    _monitor_thread: Option<JoinHandle<()>>,
    device_trigger: Arc<(Mutex<bool>, Condvar)>,
    _watcher_thread: Option<JoinHandle<()>>,
    _clock_thread: Option<JoinHandle<()>>,
    metabytes_enabled: Arc<AtomicBool>,
}

unsafe impl Send for RustMiniaudioPlayer {}
unsafe impl Sync for RustMiniaudioPlayer {}

impl Drop for RustMiniaudioPlayer {
    fn drop(&mut self) {
        self.dispose();
    }
}

impl RustMiniaudioPlayer {
    /// Initializes and boots the native miniaudio engine, DSP pipeline, and mixer.
    #[flutter_rust_bridge::frb(sync)]
    pub fn new(
        config: RustPlayerConfig,
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        initial_outputs: Vec<RustAudioOutput>,
    ) -> Result<RustMiniaudioPlayer, String> {
        let device_trigger = Arc::new((Mutex::new(true), Condvar::new()));
        let mut player = MiniaudioPlayer::new(
            sample_rate,
            channels,
            period_size,
            config.max_voices as usize,
            config.max_ram_bytes,
            Some(device_trigger.clone()),
        )?;
        player.output_manager.set_pause_on_device_change(config.pause_on_device_change);
        let _ = player.output_manager.set_outputs(initial_outputs.clone());

        let inner = Arc::new(Mutex::new(player));
        let reporter = EventReporter::new();
        reporter.emit(RustPlayerEvent::Outputs(initial_outputs));
        let custom_handle = Arc::new(Mutex::new(None));
        let monitor_running = Arc::new(AtomicBool::new(true));
        let metabytes_enabled = Arc::new(AtomicBool::new(false));

        let watcher_trigger = device_trigger.clone();
        let watcher_running = monitor_running.clone();
        let watcher_reporter = reporter.clone();
        let watcher_inner = inner.clone();

        // Background device watcher: reacts to hardware changes without polling every X seconds
        // and runs asynchronously to never block real-time audio, telemetry, or UI threads.
        let watcher_thread = thread::Builder::new()
            .name("map-device-watcher".to_string())
            .spawn(move || {
                let (lock, cvar) = &*watcher_trigger;
                let mut last_out_devices: Vec<RustAudioDevice> = Vec::new();
                let mut last_in_devices: Vec<RustAudioDevice> = Vec::new();
                let mut last_default_effective_id: Option<String> = None;

                while watcher_running.load(Ordering::Relaxed) {
                    let mut triggered = lock.lock().unwrap();
                    while !*triggered && watcher_running.load(Ordering::Relaxed) {
                        triggered = cvar.wait(triggered).unwrap();
                    }
                    if !watcher_running.load(Ordering::Relaxed) {
                        break;
                    }
                    *triggered = false;
                    drop(triggered);

                    // Debounce slightly (100ms) for USB/Bluetooth hardware negotiation to settle
                    thread::sleep(Duration::from_millis(100));

                    if let Ok(out_devs) = Self::get_output_devices_sync() {
                        if out_devs != last_out_devices {
                            last_out_devices = out_devs.clone();
                            watcher_reporter.emit(RustPlayerEvent::OutputDevices(out_devs.clone()));

                            // 1. Detect default device physical ID change
                            let current_default = out_devs.iter().find(|d| d.is_default && !d.is_auto);
                            let current_default_effective_id = current_default.map(|d| d.effective_id.clone());
                            let default_changed = last_default_effective_id.is_some()
                                && current_default_effective_id.is_some()
                                && last_default_effective_id != current_default_effective_id;
                            last_default_effective_id = current_default_effective_id;

                            // 2. Check active outputs against current OS device list
                            let mut ply = watcher_inner.lock().unwrap();
                            let mut outputs = ply.output_manager.outputs.clone();
                            let mut outputs_mutated = false;
                            let mut device_disconnected = false;

                            outputs.retain(|out| {
                                if let Some(ref dev_id) = out.device_id {
                                    let exists = out_devs.iter().any(|d| {
                                        d.id == *dev_id || d.effective_id == *dev_id || d.name == *dev_id
                                    });
                                    if !exists {
                                        device_disconnected = true;
                                        outputs_mutated = true;
                                        return false; // Evict disconnected device
                                    }
                                }
                                true
                            });

                            let has_auto_output = outputs.iter().any(|o| o.device_id.is_none());

                            // 3. If outputs mutated due to disconnection, update hardware and broadcast event
                            if outputs_mutated {
                                let _ = ply.output_manager.set_outputs(outputs.clone());
                                watcher_reporter.emit(RustPlayerEvent::Outputs(outputs));
                            }

                            // 4. Handle pause_on_device_change:
                            let should_pause = device_disconnected || (has_auto_output && default_changed);
                            if should_pause {
                                if ply.output_manager.pause_on_device_change.load(Ordering::Relaxed) {
                                    let deck = ply.music_manager.active_deck_ref();
                                    if deck.state.load(Ordering::Relaxed) == crate::core::dual_source::STATE_PLAYING {
                                        let _ = ply.music_manager.pause();
                                        ply.music_manager.inner.phase.store(
                                            crate::core::dual_source::ENGINE_PHASE_PAUSED,
                                            Ordering::Release,
                                        );
                                        watcher_reporter.emit(RustPlayerEvent::PlaybackState(2)); // Paused
                                    }
                                }
                            }
                            drop(ply);
                        }
                    }
                    if let Ok(in_devs) = Self::get_input_devices_sync() {
                        if in_devs != last_in_devices {
                            last_in_devices = in_devs.clone();
                            watcher_reporter.emit(RustPlayerEvent::InputDevices(in_devs));
                        }
                    }
                }
            })
            .ok();

        let worker_inner = inner.clone();
        let worker_reporter = reporter.clone();
        let worker_running = monitor_running.clone();
        let meta_enabled = metabytes_enabled.clone();

        let monitor_thread = thread::Builder::new()
            .name("map-telemetry-monitor".to_string())
            .spawn(move || {
                while worker_running.load(Ordering::Relaxed) {
                    thread::sleep(Duration::from_millis(16));

                    let Ok(mut ply) = worker_inner.try_lock() else {
                        continue;
                    };

                    // Check crossfade completion (auto and manual)
                    let cur_phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
                    let is_xfade_phase = cur_phase == crate::core::dual_source::ENGINE_PHASE_AUTO_CROSSFADING
                        || cur_phase == crate::core::dual_source::ENGINE_PHASE_MANUAL_CROSSFADING;
                    let mut xfade_done = ply.music_manager.inner.crossfade_completed_flag.swap(false, Ordering::AcqRel);
                    let is_active = ply.music_manager.inner.crossfade.is_active.load(Ordering::Relaxed);
                    let cur_f = ply.music_manager.inner.crossfade.current_frame.load(Ordering::Relaxed);
                    let tot_f = ply.music_manager.inner.crossfade.total_frames.load(Ordering::Relaxed);

                    if !xfade_done && is_xfade_phase && (!is_active || (tot_f > 0 && cur_f >= tot_f)) {
                        ply.music_manager.inner.crossfade.is_active.store(false, Ordering::Release);
                        xfade_done = true;
                    }

                    if xfade_done {
                        let to_deck = ply.music_manager.inner.crossfade.to_deck.load(Ordering::Relaxed);
                        ply.music_manager.inner.active_deck.store(to_deck, Ordering::Release);
                        let from_slot = if to_deck == 0 {
                            &mut ply.music_manager.inner.deck_b
                        } else {
                            &mut ply.music_manager.inner.deck_a
                        };
                        from_slot.stop();

                        let target_id = ply.music_manager.inner.crossfade_target_id.swap(-1, Ordering::AcqRel);
                        if target_id >= 0 {
                            let new_idx_opt = ply
                                .music_manager
                                .inner
                                .queue
                                .read()
                                .unwrap()
                                .iter()
                                .position(|it| it.id == target_id);
                            if let Some(new_idx) = new_idx_opt {
                                ply.music_manager.inner.current_index.store(new_idx as i64, Ordering::Release);
                                let (g, p) = ply.recalculate_and_apply_replay_gain();
                                worker_reporter.emit(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                                    gain_db: g,
                                    peak: p,
                                }));
                            }
                        }

                        ply.music_manager.inner.phase.store(crate::core::dual_source::ENGINE_PHASE_PLAYING, Ordering::Release);
                        ply.music_manager.inner.preload_standby_deck();
                    }

                    // Auto-crossfade & queue advance evaluation
                    let cur_phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
                    let is_xfading = ply.music_manager.inner.crossfade.is_active.load(Ordering::Relaxed);
                    let active_deck = ply.music_manager.active_deck_ref();
                    let deck_state = active_deck.state.load(Ordering::Relaxed);
                    let pos = active_deck.position_ms.load(Ordering::Relaxed);
                    let dur = active_deck.duration_ms.load(Ordering::Relaxed);
                    let current_idx = ply.music_manager.inner.current_index.load(Ordering::Relaxed);

                    let can_trigger = !is_xfading
                        && current_idx >= 0
                        && cur_phase != crate::core::dual_source::ENGINE_PHASE_COMPLETED
                        && cur_phase != crate::core::dual_source::ENGINE_PHASE_IDLE
                        && cur_phase != crate::core::dual_source::ENGINE_PHASE_DISPOSED;

                    if can_trigger {
                        let auto_ms = ply.music_manager.inner.auto_crossfade_duration_ms.load(Ordering::Relaxed);
                        let should_auto_xfade = deck_state == crate::core::dual_source::STATE_PLAYING
                            && auto_ms > 0
                            && dur > (auto_ms as i64)
                            && (pos + (auto_ms as i64) >= dur);
                        let is_eof = !should_auto_xfade && (
                            active_deck.completed_flag.swap(false, Ordering::AcqRel)
                            || deck_state == crate::core::dual_source::STATE_COMPLETED
                            || (dur > 0 && pos >= dur && pos > 0)
                        );

                        if should_auto_xfade || is_eof {
                            let q_len = ply.music_manager.inner.queue.read().unwrap().len();
                            let loop_m = ply.music_manager.inner.loop_mode.load(Ordering::Relaxed);
                            let next_idx_opt = if loop_m == 1 && is_eof && !should_auto_xfade {
                                Some(current_idx as usize)
                            } else if q_len > 0 {
                                let n = current_idx + 1;
                                if (n as usize) < q_len {
                                    Some(n as usize)
                                } else if loop_m == 2 {
                                    Some(0)
                                } else {
                                    None
                                }
                            } else {
                                None
                            };

                            if let Some(next_idx) = next_idx_opt {
                                let item_opt = ply.music_manager.inner.queue.read().unwrap().get(next_idx).cloned();
                                if let Some(item) = item_opt {
                                    let custom_factory = ply.music_manager.inner.custom_source_factory.clone();
                                    let active_id = ply.music_manager.inner.active_deck.load(Ordering::Relaxed);
                                    let to_deck = if active_id == 0 { 1 } else { 0 };
                                    let to_slot = if to_deck == 0 {
                                        &mut ply.music_manager.inner.deck_a
                                    } else {
                                        &mut ply.music_manager.inner.deck_b
                                    };
                                    let open_res = crate::core::dual_source::DualSource::open_deck_source(to_slot, &item, custom_factory.as_ref());
                                    if open_res == 0 {
                                        to_slot.play();
                                        if should_auto_xfade {
                                            let sr = ply.music_manager.sample_rate.max(1);
                                            let eff_ms = if dur > pos {
                                                ((dur - pos) as u64).clamp(50, auto_ms)
                                            } else {
                                                auto_ms
                                            };
                                            let xfade_frames = (eff_ms * sr as u64) / 1000;
                                            let curve = ply.music_manager.inner.crossfade_curve.load(Ordering::Relaxed);
                                            ply.music_manager.inner.crossfade.begin(active_id, to_deck, xfade_frames, curve);
                                            ply.music_manager.inner.crossfade_target_id.store(item.id, Ordering::Release);
                                            ply.music_manager.inner.phase.store(crate::core::dual_source::ENGINE_PHASE_AUTO_CROSSFADING, Ordering::Release);
                                        } else {
                                            let from_slot = if active_id == 0 {
                                                &mut ply.music_manager.inner.deck_a
                                            } else {
                                                &mut ply.music_manager.inner.deck_b
                                            };
                                            from_slot.stop();
                                            ply.music_manager.inner.active_deck.store(to_deck, Ordering::Release);
                                            ply.music_manager.inner.current_index.store(next_idx as i64, Ordering::Release);
                                            let (g, p) = ply.recalculate_and_apply_replay_gain();
                                            worker_reporter.emit(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                                                gain_db: g,
                                                peak: p,
                                            }));
                                            ply.music_manager.inner.phase.store(crate::core::dual_source::ENGINE_PHASE_PLAYING, Ordering::Release);
                                        }
                                    }
                                }
                            } else if is_eof {
                                ply.music_manager.inner.phase.store(crate::core::dual_source::ENGINE_PHASE_COMPLETED, Ordering::Release);
                                let active_deck = ply.music_manager.active_deck_mut();
                                active_deck.state.store(crate::core::dual_source::STATE_COMPLETED, Ordering::Release);
                                active_deck.pause();
                            }
                        }
                    }

                    // Check completed voice pool effects & reactive eviction (Trigger 2)
                    if let Ok(mut vp) = ply.effects_manager.pool.try_lock() {
                        let mut any_completed = false;
                        while let Ok(v_id) = vp.completed_voices_consumer.pop() {
                            any_completed = true;
                            worker_reporter.emit(RustPlayerEvent::VoiceCompleted(v_id));
                        }
                        if any_completed && vp.on_voice_completed() {
                            let ids = vp.loaded_effect_ids();
                            let allocated_bytes = vp.allocated_ram_bytes;
                            worker_reporter.emit(RustPlayerEvent::LoadedEffects {
                                ids,
                                allocated_bytes,
                            });
                        }
                    }

                    // Query active deck
                    let active_deck = ply.music_manager.active_deck_ref();
                    let state = active_deck.state.load(Ordering::Relaxed);
                    let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
                    let pos = active_deck.position_ms.load(Ordering::Relaxed);
                    let dur = active_deck.duration_ms.load(Ordering::Relaxed);
                    let bitrate = active_deck.bitrate.load(Ordering::Relaxed);
                    let mut br = crate::bridge::ffi::MiniaudioBufferedRange::default();
                    let has_br = active_deck.get_buffered_range(&mut br) == 0;
                    let idx = ply.music_manager.current_index();
                    let is_xfading = ply.music_manager.is_crossfading();
                    let is_rec = ply.output_manager.is_recording();
                    let is_ducking = ply.input_manager.is_ducking_active();
                    let mic_rms = ply.input_manager.last_rms_db();
                    let meta_to_send = if meta_enabled.load(Ordering::Relaxed) {
                        active_deck.get_meta_bytes()
                    } else {
                        None
                    };
                    let rg = ply.music_dsp.equalizer.replay_gain();
                    let active_voices = ply.effects_manager.active_voices_count();

                    let vis_data = if ply.output_manager.visualizer_enabled.load(Ordering::Relaxed) {
                        Some(ply.output_manager.visualizer_seqlock.read())
                    } else {
                        None
                    };

                    drop(ply);

                    let is_completed = state == crate::core::dual_source::STATE_COMPLETED
                        || phase == crate::core::dual_source::ENGINE_PHASE_COMPLETED;
                    let is_playing = !is_completed && state == crate::core::dual_source::STATE_PLAYING;
                    let effective_state = if is_completed {
                        crate::core::dual_source::STATE_COMPLETED
                    } else {
                        state
                    };

                    worker_reporter.emit(RustPlayerEvent::PlaybackState(effective_state));
                    worker_reporter.emit(RustPlayerEvent::State(phase));
                    worker_reporter.emit(RustPlayerEvent::IsPlaying(is_playing));
                    worker_reporter.emit(RustPlayerEvent::IsCompleted(is_completed));
                    worker_reporter.emit(RustPlayerEvent::Position(pos));
                    worker_reporter.emit(RustPlayerEvent::Duration(dur));
                    worker_reporter.emit(RustPlayerEvent::CurrentIndex(idx as i32));
                    if bitrate > 0 {
                        worker_reporter.emit(RustPlayerEvent::Bitrate(bitrate));
                    }
                    worker_reporter.emit(RustPlayerEvent::ActiveVoices(active_voices));
                    if has_br {
                        worker_reporter.emit(RustPlayerEvent::Buffer(RustBuffer {
                            start_ms: br.start_ms,
                            end_ms: br.end_ms,
                            is_buffering: br.is_buffering != 0,
                        }));
                    }
                    worker_reporter.emit(RustPlayerEvent::IsCrossfading(is_xfading));
                    worker_reporter.emit(RustPlayerEvent::IsRecording(is_rec));
                    worker_reporter.emit(RustPlayerEvent::IsDuckingActive(is_ducking));
                    if mic_rms > -90.0 {
                        worker_reporter.emit(RustPlayerEvent::MicRmsLevel(mic_rms));
                    }
                    if let Some(mb) = meta_to_send {
                        worker_reporter.emit(RustPlayerEvent::MetaBytes(mb));
                    }
                    worker_reporter.emit(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                        gain_db: rg.gain_db,
                        peak: rg.peak,
                    }));
                    if let Some(vis) = vis_data {
                        worker_reporter.emit(RustPlayerEvent::Visualizer(
                            RustVisualizerData::from(vis),
                        ));
                    }
                }
            })
            .ok();

        let clock_inner = inner.clone();
        let clock_running = monitor_running.clone();
        let clock_period = period_size;
        let clock_sr = sample_rate;

        let clock_thread = thread::Builder::new()
            .name("map-engine-clock".to_string())
            .spawn(move || {
                let period_duration = Duration::from_nanos(
                    (clock_period as u64 * 1_000_000_000) / clock_sr.max(1) as u64,
                );
                let mut next_tick = Instant::now();

                while clock_running.load(Ordering::Relaxed) {
                    if let Ok(mut ply) = clock_inner.lock() {
                        let deck_state = ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed);
                        let is_rec = ply.output_manager.is_recording.load(Ordering::Relaxed);
                        let has_voices = ply.effects_manager.active_voices_count() > 0;
                        let is_active = deck_state == crate::core::dual_source::STATE_PLAYING || is_rec || has_voices;
                        if is_active {
                            ply.render_pcm(clock_period as usize);
                        }
                    }

                    next_tick += period_duration;
                    let now = Instant::now();
                    if now < next_tick {
                        thread::sleep(next_tick - now);
                    } else {
                        next_tick = now;
                    }
                }
            })
            .ok();

        Ok(RustMiniaudioPlayer {
            inner,
            reporter,
            custom_handle,
            monitor_running,
            _monitor_thread: monitor_thread,
            device_trigger,
            _watcher_thread: watcher_thread,
            _clock_thread: clock_thread,
            metabytes_enabled,
        })
    }

    /// Subscribes a Dart StreamSink to real-time engine events and telemetry updates.
    pub fn subscribe_events(
        &self,
        sink: StreamSink<RustPlayerEvent>,
    ) -> Result<(), String> {
        self.reporter.set_sink(sink);

        let current_outputs = self.inner.lock().unwrap().output_manager.outputs.clone();
        self.reporter.emit(RustPlayerEvent::Outputs(current_outputs));

        // Asynchronously notify background device watcher to deliver initial device snapshot
        let (lock, cvar) = &*self.device_trigger;
        if let Ok(mut flag) = lock.lock() {
            *flag = true;
            cvar.notify_one();
        }
        Ok(())
    }

    fn emit_event(&self, event: RustPlayerEvent) {
        self.reporter.emit(event);
    }

    fn emit_queue(&self) {
        if let Ok(ply) = self.inner.lock() {
            let q: Vec<i64> = ply
                .music_manager
                .inner
                .queue
                .read()
                .unwrap()
                .iter()
                .map(|it| it.id)
                .collect();
            let cur_idx = ply.music_manager.inner.current_index.load(Ordering::Relaxed) as i32;
            self.emit_event(RustPlayerEvent::Queue {
                queue: q,
                current_index: cur_idx,
            });
        }
    }

    // =========================================================================
    // Transport & Playback Methods
    // =========================================================================

    /// Universal playback command: starts, resumes, or switches tracks by ID or position,
    /// optionally applying shuffle and/or seeking to an initial offset.
    pub fn play(
        &self,
        id: Option<i64>,
        position: Option<usize>,
        shuffled: Option<bool>,
        seek_ms: Option<i64>,
    ) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        let prev_ids: Vec<i64> = ply
            .music_manager
            .inner
            .queue
            .read()
            .unwrap()
            .iter()
            .map(|i| i.id)
            .collect();
        ply.music_manager.play(id, position, shuffled, seek_ms)?;
        let new_ids: Vec<i64> = ply
            .music_manager
            .inner
            .queue
            .read()
            .unwrap()
            .iter()
            .map(|i| i.id)
            .collect();
        let queue_changed = prev_ids != new_ids;
        let cur_idx = ply.music_manager.current_index();
        let is_shuffled = ply.music_manager.is_shuffled();
        let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
        let active_deck = ply.music_manager.active_deck_ref();
        let state = active_deck.state.load(Ordering::Relaxed);
        let is_playing = state == crate::core::dual_source::STATE_PLAYING;
        let initial_pos = active_deck.position_ms.load(Ordering::Relaxed);
        let initial_dur = active_deck.duration_ms.load(Ordering::Relaxed);
        let initial_bitrate = active_deck.bitrate.load(Ordering::Relaxed);
        let initial_meta = active_deck.get_meta_bytes();
        let mut initial_br = crate::bridge::ffi::MiniaudioBufferedRange::default();
        let has_br = active_deck.get_buffered_range(&mut initial_br) == 0;
        let rg = if cur_idx >= 0 {
            Some(Self::sync_deck_replay_gain(&mut ply, cur_idx as usize))
        } else {
            None
        };
        drop(ply);
        if let Some((g, p)) = rg {
            self.emit_event(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                gain_db: g,
                peak: p,
            }));
        }
        if queue_changed {
            self.emit_queue();
        }
        self.emit_event(RustPlayerEvent::IsShuffled(is_shuffled));
        self.emit_event(RustPlayerEvent::CurrentIndex(cur_idx as i32));
        self.emit_event(RustPlayerEvent::IsCompleted(false));
        if self.metabytes_enabled.load(Ordering::Relaxed) {
            self.emit_event(RustPlayerEvent::MetaBytes(Vec::new()));
            if let Some(mb) = initial_meta {
                self.emit_event(RustPlayerEvent::MetaBytes(mb));
            }
        }
        self.emit_event(RustPlayerEvent::Position(initial_pos));
        self.emit_event(RustPlayerEvent::Duration(initial_dur));
        if initial_bitrate > 0 {
            self.emit_event(RustPlayerEvent::Bitrate(initial_bitrate));
        }
        if has_br {
            self.emit_event(RustPlayerEvent::Buffer(RustBuffer {
                start_ms: initial_br.start_ms,
                end_ms: initial_br.end_ms,
                is_buffering: initial_br.is_buffering != 0,
            }));
        }
        self.emit_event(RustPlayerEvent::PlaybackState(state));
        self.emit_event(RustPlayerEvent::State(phase));
        self.emit_event(RustPlayerEvent::IsPlaying(is_playing));
        Ok(())
    }

    /// Pauses playback on the active audio deck without releasing resources.
    #[flutter_rust_bridge::frb(sync)]
    pub fn pause(&self) {
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.pause();
        let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
        let state = ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed);
        drop(ply);
        self.emit_event(RustPlayerEvent::PlaybackState(state));
        self.emit_event(RustPlayerEvent::State(phase));
        self.emit_event(RustPlayerEvent::IsPlaying(false));
    }

    /// Stops playback and resets elapsed position to the beginning.
    #[flutter_rust_bridge::frb(sync)]
    pub fn stop(&self) {
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.stop();
        ply.output_manager
            .visualizer_seqlock
            .write(|d| *d = crate::dsp::visualizer::VisualizerData::default());
        let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
        let state = ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed);
        drop(ply);
        self.emit_event(RustPlayerEvent::PlaybackState(state));
        self.emit_event(RustPlayerEvent::State(phase));
        self.emit_event(RustPlayerEvent::Position(0));
        self.emit_event(RustPlayerEvent::IsPlaying(false));
        self.emit_event(RustPlayerEvent::IsCompleted(false));
        self.emit_event(RustPlayerEvent::Visualizer(RustVisualizerData::default()));
    }

    /// Seeks to the specified position in milliseconds within the current track.
    #[flutter_rust_bridge::frb(sync)]
    pub fn seek(&self, position_ms: i64) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        let res = ply.music_manager.seek(position_ms)?;
        let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
        let cur_idx = ply.music_manager.current_index();
        let state = ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed);
        let is_playing = state == crate::core::dual_source::STATE_PLAYING;
        let is_completed = state == crate::core::dual_source::STATE_COMPLETED;
        drop(ply);
        self.emit_event(RustPlayerEvent::Position(position_ms));
        self.emit_event(RustPlayerEvent::State(phase));
        self.emit_event(RustPlayerEvent::CurrentIndex(cur_idx as i32));
        self.emit_event(RustPlayerEvent::IsPlaying(is_playing));
        self.emit_event(RustPlayerEvent::PlaybackState(state));
        self.emit_event(RustPlayerEvent::IsCompleted(is_completed));
        Ok(res)
    }

fn sync_deck_replay_gain(ply: &mut crate::core::miniaudio_player::MiniaudioPlayer, _idx: usize) -> (f32, f32) {
    ply.recalculate_and_apply_replay_gain()
}

    // =========================================================================
    // Queue Management Methods
    // =========================================================================

    /// Replaces the entire playback queue with `queue` without starting playback.
    pub fn set_queue(&self, queue: Vec<RustAudioSource>) -> Result<(), String> {
        let core_queue: Vec<AudioSourceCore> = queue.into_iter().map(Into::into).collect();
        let reporter_clone = self.reporter.clone();
        let handle_arc = self.custom_handle.clone();
        let custom_factory = Arc::new(
            move |stream_id: u32, total_size: Option<u64>, initial_bytes: Vec<u8>| {
                let rc = reporter_clone.clone();
                let req_sender = Arc::new(move |req: crate::buffer::DartReadRequest| {
                    rc.emit(RustPlayerEvent::DartReadRequest(req.into()));
                });
                let (src, h) = crate::buffer::CustomDartByteSource::new(
                    stream_id,
                    total_size,
                    true,
                    initial_bytes,
                    req_sender,
                );
                if let Ok(mut g) = handle_arc.lock() {
                    *g = Some(h.clone());
                }
                (src, h)
            },
        );
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.set_custom_source_factory(custom_factory);
        ply.music_manager.set_queue(core_queue);
        let (g, p) = ply.recalculate_and_apply_replay_gain();
        if let Ok(mut f) = self.reporter.filter.lock() {
            *f = TelemetryFilter::default();
        }
        drop(ply);
        self.emit_queue();
        self.emit_event(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
            gain_db: g,
            peak: p,
        }));
        self.emit_event(RustPlayerEvent::CurrentIndex(-1));
        self.emit_event(RustPlayerEvent::IsPlaying(false));
        self.emit_event(RustPlayerEvent::IsCompleted(false));
        self.emit_event(RustPlayerEvent::Position(0));
        self.emit_event(RustPlayerEvent::Duration(0));
        self.emit_event(RustPlayerEvent::PlaybackState(0));
        self.emit_event(RustPlayerEvent::State(0));
        Ok(())
    }

    /// Appends a batch of audio sources to the end of the playlist queue.
    #[flutter_rust_bridge::frb(sync)]
    pub fn append(&self, sources: Vec<RustAudioSource>) {
        let core_sources: Vec<AudioSourceCore> = sources.into_iter().map(Into::into).collect();
        self.inner.lock().unwrap().music_manager.append(core_sources);
        self.emit_queue();
    }

    /// Inserts an audio source directly after the currently playing track.
    #[flutter_rust_bridge::frb(sync)]
    pub fn insert_next(&self, source: RustAudioSource) {
        self.inner.lock().unwrap().music_manager.insert_next(source.into());
        self.emit_queue();
    }

    /// Removes an audio source at the specified index from the playlist queue.
    #[flutter_rust_bridge::frb(sync)]
    pub fn remove_at(&self, index: usize) -> bool {
        let (res, idx) = {
            let mut ply = self.inner.lock().unwrap();
            let r = ply.music_manager.remove_at(index).is_some();
            let i = ply.music_manager.current_index();
            (r, i)
        };
        if res {
            self.emit_queue();
            self.emit_event(RustPlayerEvent::CurrentIndex(idx as i32));
        }
        res
    }

    /// Reorders a track within the queue from `old_index` to `new_index`.
    #[flutter_rust_bridge::frb(sync)]
    pub fn reorder(&self, old_index: usize, new_index: usize) -> bool {
        let (res, idx) = {
            let mut ply = self.inner.lock().unwrap();
            let r = ply.music_manager.reorder(old_index, new_index);
            let i = ply.music_manager.current_index();
            (r, i)
        };
        if res {
            self.emit_queue();
            self.emit_event(RustPlayerEvent::CurrentIndex(idx as i32));
        }
        res
    }

    /// Reorders the playlist queue to match the specified list of track IDs.
    #[flutter_rust_bridge::frb(sync)]
    pub fn reorder_by_ids(&self, ids: Vec<i64>) -> bool {
        let (res, idx) = {
            let mut ply = self.inner.lock().unwrap();
            let r = ply.music_manager.reorder_by_ids(&ids);
            let i = ply.music_manager.current_index();
            (r, i)
        };
        if res {
            self.emit_queue();
            self.emit_event(RustPlayerEvent::CurrentIndex(idx as i32));
        }
        res
    }

    /// Clears pending tracks from the queue, optionally preserving the currently active track.
    #[flutter_rust_bridge::frb(sync)]
    pub fn clear_queue(&self, keep_current: bool) {
        let idx = {
            let mut ply = self.inner.lock().unwrap();
            ply.music_manager.clear_queue(keep_current);
            ply.music_manager.current_index()
        };
        self.emit_queue();
        self.emit_event(RustPlayerEvent::CurrentIndex(idx as i32));
    }

    /// Skips to the next track in the queue, optionally overriding crossfade duration.
    pub fn next(&self, crossfade_duration_ms: Option<u64>) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.next(crossfade_duration_ms)?;
        let idx = ply.music_manager.current_index();
        let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
        let state = ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed);
        let is_playing = state == crate::core::dual_source::STATE_PLAYING;
        let rg = if idx >= 0 {
            Some(Self::sync_deck_replay_gain(&mut ply, idx as usize))
        } else {
            None
        };
        drop(ply);
        if let Some((g, p)) = rg {
            self.emit_event(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                gain_db: g,
                peak: p,
            }));
        }
        self.emit_event(RustPlayerEvent::CurrentIndex(idx as i32));
        self.emit_event(RustPlayerEvent::State(phase));
        self.emit_event(RustPlayerEvent::IsPlaying(is_playing));
        self.emit_event(RustPlayerEvent::PlaybackState(state));
        self.emit_event(RustPlayerEvent::IsCompleted(false));
        Ok(())
    }

    /// Rewinds or skips to the previous track in the queue.
    pub fn previous(&self) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.previous()?;
        let idx = ply.music_manager.current_index();
        let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
        let pos = ply.music_manager.active_deck_ref().position_ms.load(Ordering::Relaxed);
        let state = ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed);
        let is_playing = state == crate::core::dual_source::STATE_PLAYING;
        let rg = if idx >= 0 {
            Some(Self::sync_deck_replay_gain(&mut ply, idx as usize))
        } else {
            None
        };
        drop(ply);
        if let Some((g, p)) = rg {
            self.emit_event(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                gain_db: g,
                peak: p,
            }));
        }
        self.emit_event(RustPlayerEvent::CurrentIndex(idx as i32));
        self.emit_event(RustPlayerEvent::Position(pos));
        self.emit_event(RustPlayerEvent::State(phase));
        self.emit_event(RustPlayerEvent::IsPlaying(is_playing));
        self.emit_event(RustPlayerEvent::PlaybackState(state));
        self.emit_event(RustPlayerEvent::IsCompleted(false));
        Ok(())
    }

    /// Sets the queue loop policy (0: off, 1: one, 2: all).
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_loop_mode(&self, mode: i32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_manager.inner.loop_mode.load(std::sync::atomic::Ordering::Relaxed);
        if prev != mode {
            ply.music_manager.set_loop_mode(mode);
            self.emit_event(RustPlayerEvent::LoopMode(mode));
        }
    }

    /// Enables or disables playlist shuffle mode.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_shuffle(&self, enabled: bool) {
        let changed_idx = {
            let mut ply = self.inner.lock().unwrap();
            let prev = ply.music_manager.is_shuffled();
            if prev != enabled {
                ply.music_manager.set_shuffle(enabled);
                Some(ply.music_manager.current_index())
            } else {
                None
            }
        };
        if let Some(idx) = changed_idx {
            self.emit_queue();
            self.emit_event(RustPlayerEvent::IsShuffled(enabled));
            self.emit_event(RustPlayerEvent::CurrentIndex(idx as i32));
        }
    }

    /// Configures automatic and manual crossfade durations and curve formulas.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_crossfade(&self, config: RustCrossfadeConfig) {
        self.inner.lock().unwrap().music_manager.set_crossfade(
            config.auto_duration_ms,
            config.manual_duration_ms,
            config.curve,
        );
        self.emit_event(RustPlayerEvent::CrossfadeConfig(config));
    }

    // =========================================================================
    // DSP & Audio Modulation Methods
    // =========================================================================

    /// Sets the master output volume level (0.0 to 1.0+).
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_volume(&self, volume: f32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_dsp.volume;
        if (prev - volume).abs() > 1e-5 {
            ply.set_volume(volume);
            self.emit_event(RustPlayerEvent::Volume(volume));
        }
    }

    /// Sets the playback speed multiplier with automatic pitch compensation.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_rate(&self, rate: f32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_manager.rate();
        if (prev - rate).abs() > 1e-5 {
            ply.music_manager.set_rate(rate);
            self.emit_event(RustPlayerEvent::Rate(rate));
        }
    }

    /// Sets the pitch shift frequency multiplier independently of playback speed.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_pitch(&self, pitch: f32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_manager.pitch();
        if (prev - pitch).abs() > 1e-5 {
            ply.music_manager.set_pitch(pitch);
            self.emit_event(RustPlayerEvent::Pitch(pitch));
        }
    }

    /// Sets the stereo pan balance from -1.0 (hard left) to +1.0 (hard right).
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_balance(&self, balance: f32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_dsp.balance;
        ply.music_dsp.set_balance(balance);
        let actual = ply.music_dsp.balance;
        if (prev - actual).abs() > 1e-5 {
            self.emit_event(RustPlayerEvent::Balance(actual));
        }
    }

    /// Toggles mono downmixing of multi-channel audio.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_mono(&self, enabled: bool) {
        let mut ply = self.inner.lock().unwrap();
        if ply.music_dsp.mono != enabled {
            ply.music_dsp.set_mono(enabled);
            self.emit_event(RustPlayerEvent::Mono(enabled));
        }
    }

    /// Sets the equalizer pre-amplification gain in decibels.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_preamp(&self, preamp_db: f32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_dsp.equalizer.preamp_db();
        if (prev - preamp_db).abs() > 1e-5 {
            ply.music_dsp.set_preamp(preamp_db);
            self.emit_event(RustPlayerEvent::Preamp(preamp_db));
        }
    }

    /// Sets the Bauer binaural headphone crossfeed mode (0: off, 1: 44.1kHz, 2: 48kHz, 3: high).
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_crossfeed(&self, mode: i32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_manager.inner.deck_a.crossfeed_mode.load(std::sync::atomic::Ordering::Relaxed);
        if prev != mode {
            ply.music_manager.inner.deck_a.set_crossfeed(mode);
            ply.music_manager.inner.deck_b.set_crossfeed(mode);
            self.emit_event(RustPlayerEvent::Crossfeed(mode));
        }
    }

    /// Enables or disables 3D stereo widening spatializer with width multiplier.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatializer(&self, enabled: bool, width: f32) {
        let mut ply = self.inner.lock().unwrap();
        let w = width.clamp(0.0, 2.0);
        let prev_en = ply.music_dsp.equalizer.spatializer_enabled();
        let prev_w = ply.music_dsp.equalizer.spatializer_width();
        if prev_en != enabled || (prev_w - w).abs() > 1e-5 {
            ply.music_dsp.equalizer.set_spatializer(enabled, w);
            self.emit_event(RustPlayerEvent::Spatializer { enabled, width: w });
        }
    }

    /// Applies ReplayGain loudness normalization settings.
    #[flutter_rust_bridge::frb(sync)]
    /// Sets, updates, or clears ReplayGain normalization settings for a queue item or current track.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_replay_gain(
        &self,
        config: Option<RustReplayGainConfig>,
        id: Option<i64>,
        position: Option<usize>,
    ) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        let target_idx = {
            let q = ply.music_manager.inner.queue.read().unwrap();
            if let Some(target_id) = id {
                q.iter().position(|it| it.id == target_id)
            } else if let Some(pos) = position {
                if pos < q.len() {
                    Some(pos)
                } else {
                    None
                }
            } else {
                let cur = ply
                    .music_manager
                    .inner
                    .current_index
                    .load(std::sync::atomic::Ordering::Relaxed);
                if cur >= 0 && (cur as usize) < q.len() {
                    Some(cur as usize)
                } else if !q.is_empty() {
                    Some(0)
                } else {
                    None
                }
            }
        };

        if let Some(idx) = target_idx {
            let (new_gain, new_peak) = match config {
                Some(ref c) => (Some(c.gain_db), Some(c.peak)),
                None => (None, None),
            };
            {
                let mut q = ply.music_manager.inner.queue.write().unwrap();
                if idx < q.len() {
                    q[idx].replay_gain_db = new_gain;
                    q[idx].replay_peak = new_peak;
                }
            }
            {
                let mut cq = ply.music_manager.inner.canonical_queue.write().unwrap();
                if idx < cq.len() {
                    cq[idx].replay_gain_db = new_gain;
                    cq[idx].replay_peak = new_peak;
                }
            }
            let cur = ply
                .music_manager
                .inner
                .current_index
                .load(std::sync::atomic::Ordering::Relaxed);
            let is_target_active = if cur >= 0 {
                cur as usize == idx
            } else {
                idx == 0
            };
            if is_target_active {
                let (g, p) = ply.recalculate_and_apply_replay_gain();
                self.emit_event(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                    gain_db: g,
                    peak: p,
                }));
            }
        }
        Ok(())
    }

    /// Sets the global ReplayGain operating mode (0: disabled, 1: track, 2: forced).
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_replay_gain_mode(&self, mode: u32) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        ply.replay_gain_mode = mode;
        let (g, p) = ply.recalculate_and_apply_replay_gain();
        self.emit_event(RustPlayerEvent::ReplayGainMode(mode));
        self.emit_event(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
            gain_db: g,
            peak: p,
        }));
        Ok(())
    }

    /// Sets the fallback or forced ReplayGain adjustment in dB and peak.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_default_replay_gain(&self, gain_db: f32, peak: f32) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        ply.default_replay_gain = (gain_db, peak);
        let (g, p) = ply.recalculate_and_apply_replay_gain();
        self.emit_event(RustPlayerEvent::DefaultReplayGain(gain_db));
        self.emit_event(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
            gain_db: g,
            peak: p,
        }));
        Ok(())
    }

    /// Configures automatic silence skipping and trimming parameters.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_silence_config(&self, config: RustSilenceConfig) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        let sc = SilenceConfig::from(config.clone());
        ply.music_manager.inner.deck_a.set_silence_config(&sc);
        ply.music_manager.inner.deck_b.set_silence_config(&sc);
        self.emit_event(RustPlayerEvent::SilenceConfig(config));
        Ok(())
    }

    /// Updates 10-band graphic equalizer band gain levels.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_equalizer(&self, params: RustEqualizerParams) -> Result<(), String> {
        let eq = EqualizerParams::from(params.clone());
        let mut ply = self.inner.lock().unwrap();
        ply.music_dsp.set_equalizer(&eq);
        self.emit_event(RustPlayerEvent::Equalizer(params));
        Ok(())
    }

    /// Updates studio reverberation acoustic parameters.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_reverb(&self, params: RustReverbParams) -> Result<(), String> {
        let conf = ReverbConfig {
            enabled: if params.enabled { 1 } else { 0 },
            room_size: params.room_size,
            damping: params.damping,
            width: params.width,
            wet: params.wet,
            dry: params.dry,
        };
        let mut ply = self.inner.lock().unwrap();
        ply.music_dsp.set_reverb(conf);
        self.emit_event(RustPlayerEvent::Reverb(params));
        Ok(())
    }

    /// Enables or disables the output brickwall peak limiter.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_limiter(&self, enabled: bool) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.master_limiter.is_enabled();
        if prev != enabled {
            ply.master_limiter.set_enabled(enabled);
            self.emit_event(RustPlayerEvent::Limiter(enabled));
        }
    }

    /// Enables or disables the FFT audio visualizer and spectrum analysis stream.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_visualizer_enabled(&self, enabled: bool) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.output_manager.visualizer_enabled.load(std::sync::atomic::Ordering::Relaxed);
        if prev != enabled {
            ply.output_manager.set_visualizer_enabled(enabled);
            self.emit_event(RustPlayerEvent::VisualizerEnabled(enabled));
            if !enabled {
                self.emit_event(RustPlayerEvent::Visualizer(RustVisualizerData::default()));
            }
        }
    }

    /// Enables or disables forwarding of raw ICY/ID3 metadata byte payloads.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_metabytes_enabled(&self, enabled: bool) {
        let prev = self.metabytes_enabled.swap(enabled, std::sync::atomic::Ordering::Relaxed);
        if prev != enabled {
            self.emit_event(RustPlayerEvent::MetaBytesEnabled(enabled));
            if enabled {
                let ply = self.inner.lock().unwrap();
                if let Some(mb) = ply.music_manager.active_deck_ref().get_meta_bytes() {
                    self.emit_event(RustPlayerEvent::MetaBytes(mb));
                }
            } else {
                self.emit_event(RustPlayerEvent::MetaBytes(Vec::new()));
            }
        }
    }

    /// Adjusts the audio stream buffer frame size.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_buffer_size(&self, buffer_size_frames: u32) {
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.inner.deck_a.set_buffer_size(buffer_size_frames);
        ply.music_manager.inner.deck_b.set_buffer_size(buffer_size_frames);
        drop(ply);
        self.emit_event(RustPlayerEvent::BufferSize(buffer_size_frames));
    }

    // =========================================================================
    // RAM Sound Effects Methods
    // =========================================================================

    /// Declaratively registers the catalog of sound effects with the autonomous RAM engine.
    pub fn set_effects(&self, effects: Vec<RustAudioEffect>) -> Result<(), String> {
        let catalog: Vec<EffectCatalogItem> = effects.into_iter().map(Into::into).collect();
        let ply = self.inner.lock().unwrap();
        ply.effects_manager.set_effects(catalog)?;
        let loaded_ids = ply.effects_manager.loaded_effect_ids();
        let ram_bytes = ply.effects_manager.allocated_ram_bytes();
        drop(ply);
        self.emit_event(RustPlayerEvent::LoadedEffects {
            ids: loaded_ids,
            allocated_bytes: ram_bytes,
        });
        Ok(())
    }

    /// Returns the list of currently loaded sound effect IDs in RAM.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_loaded_effect_ids(&self) -> Vec<String> {
        self.inner.lock().unwrap().effects_manager.loaded_effect_ids()
    }

    /// Returns the total RAM bytes occupied by decoded sound effect buffers.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_allocated_ram_bytes(&self) -> usize {
        self.inner.lock().unwrap().effects_manager.allocated_ram_bytes()
    }

    /// Returns the current number of concurrently playing sound effect voices.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_active_voices_count(&self) -> u32 {
        self.inner.lock().unwrap().effects_manager.active_voices_count()
    }

    /// Triggers playback of a registered sound effect (decoding on demand if not in RAM),
    /// returning the assigned voice ID.
    #[flutter_rust_bridge::frb(sync)]
    pub fn play_effect(
        &self,
        id: String,
        dsp_routing: i32,
        config: RustEffectConfig,
    ) -> Result<u32, String> {
        let routing = match dsp_routing {
            1 => DspRouting::Isolate,
            2 => DspRouting::Bypass,
            _ => DspRouting::Inherit,
        };
        let core_config = EffectConfig::from(config);
        let (voice_id, ram_changed, loaded_ids, ram_bytes) = {
            let ply = self.inner.lock().unwrap();
            let (vid, changed) = ply.effects_manager.play_effect(&id, routing, core_config)?;
            let ids = if changed {
                ply.effects_manager.loaded_effect_ids()
            } else {
                Vec::new()
            };
            let bytes = if changed {
                ply.effects_manager.allocated_ram_bytes()
            } else {
                0
            };
            (vid, changed, ids, bytes)
        };
        if ram_changed {
            self.emit_event(RustPlayerEvent::LoadedEffects {
                ids: loaded_ids,
                allocated_bytes: ram_bytes,
            });
        }
        Ok(voice_id)
    }

    /// Stops an active sound effect voice with an optional fade-out ramp in milliseconds.
    #[flutter_rust_bridge::frb(sync)]
    pub fn stop_effect(&self, voice_id: u32, fade_out_ms: u64) {
        let sr = self.inner.lock().unwrap().sample_rate;
        let fade_samples = (fade_out_ms as f64 * (sr as f64 / 1000.0)) as usize;
        self.inner.lock().unwrap().effects_manager.stop_effect(voice_id, fade_samples);
    }

    /// Stops all actively playing sound effect voices with an optional fade-out ramp in milliseconds.
    #[flutter_rust_bridge::frb(sync)]
    pub fn stop_all_effects(&self, fade_out_ms: u64) {
        let sr = self.inner.lock().unwrap().sample_rate;
        let fade_samples = (fade_out_ms as f64 * (sr as f64 / 1000.0)) as usize;
        self.inner.lock().unwrap().effects_manager.stop_all_effects(fade_samples);
    }

    /// Modulates the volume of an active sound effect voice.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_effect_volume(&self, voice_id: u32, volume: f32) {
        self.inner.lock().unwrap().effects_manager.set_voice_volume(voice_id, volume);
    }

    /// Modulates the pitch multiplier of an active sound effect voice.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_effect_pitch(&self, voice_id: u32, pitch: f32) {
        self.inner.lock().unwrap().effects_manager.set_voice_pitch(voice_id, pitch);
    }

    /// Adjusts stereo pan balance of an active sound effect voice.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_effect_balance(&self, voice_id: u32, balance: f32) {
        self.inner.lock().unwrap().effects_manager.set_voice_balance(voice_id, balance);
    }

    /// Updates the 3D spatial emitter parameters for an active sound effect voice.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_effect_emitter(&self, voice_id: u32, emitter: Option<RustSpatialEmitter>) {
        self.inner.lock().unwrap().effects_manager.set_voice_emitter(
            voice_id,
            emitter.map(Into::into),
        );
    }

    /// Updates the global 3D audio listener position, velocity, and orientation vectors.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_listener(&self, listener: RustSpatialListener) {
        self.inner.lock().unwrap().effects_manager.set_listener(listener.into());
    }

    /// Configures global Doppler factor and medium speed of sound in meters per second.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_doppler_parameters(&self, factor: f32, speed_of_sound: f32) {
        self.inner.lock().unwrap().effects_manager.set_doppler_parameters(factor, speed_of_sound);
    }

    // =========================================================================
    // Multiple Outputs & Live Recording Methods
    // =========================================================================

    /// Replaces the active audio output destinations in the multi-sink matrix.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_outputs(&self, outputs: Vec<RustAudioOutput>) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        ply.output_manager.set_outputs(outputs.clone())?;
        drop(ply);

        self.emit_event(RustPlayerEvent::Outputs(outputs));

        let (lock, cvar) = &*self.device_trigger;
        if let Ok(mut flag) = lock.lock() {
            *flag = true;
            cvar.notify_one();
        }
        Ok(())
    }

    /// Adds or routes an audio output destination to the output matrix.
    #[flutter_rust_bridge::frb(sync)]
    pub fn add_output(&self, output: RustAudioOutput) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        let mut current = ply.output_manager.outputs.clone();
        if !current.contains(&output) {
            current.push(output);
            ply.output_manager.set_outputs(current.clone())?;
            drop(ply);

            self.emit_event(RustPlayerEvent::Outputs(current));

            let (lock, cvar) = &*self.device_trigger;
            if let Ok(mut flag) = lock.lock() {
                *flag = true;
                cvar.notify_one();
            }
        }
        Ok(())
    }

    /// Removes an audio output destination from the output matrix.
    #[flutter_rust_bridge::frb(sync)]
    pub fn remove_output(&self, output: RustAudioOutput) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        let mut current = ply.output_manager.outputs.clone();
        if let Some(pos) = current.iter().position(|x| *x == output) {
            current.remove(pos);
            ply.output_manager.set_outputs(current.clone())?;
            drop(ply);

            self.emit_event(RustPlayerEvent::Outputs(current));

            let (lock, cvar) = &*self.device_trigger;
            if let Ok(mut flag) = lock.lock() {
                *flag = true;
                cvar.notify_one();
            }
        }
        Ok(())
    }

    /// Begins recording rendered audio to a WAV file at `path` with a selective source.
    pub fn start_recording(&self, path: String, format: i32, source: i32) -> Result<(), String> {
        let fmt = match format {
            1 => WavFormat::Float32,
            _ => WavFormat::Pcm16,
        };
        let src = AudioOutputSource::from(source);
        self.inner.lock().unwrap().output_manager.start_recording(&path, fmt, src)?;
        self.emit_event(RustPlayerEvent::IsRecording(true));
        self.emit_event(RustPlayerEvent::RecordingState {
            is_recording: true,
            source,
        });
        Ok(())
    }

    /// Stops active file recording and returns the finalization metrics.
    pub fn stop_recording(&self) -> Result<RustRecordingResult, String> {
        let mut ply = self.inner.lock().unwrap();
        let (path, dur_ms, bytes_written, sample_count) = ply.output_manager.stop_recording()?;
        drop(ply);
        self.emit_event(RustPlayerEvent::IsRecording(false));
        self.emit_event(RustPlayerEvent::RecordingState {
            is_recording: false,
            source: 0,
        });

        Ok(RustRecordingResult {
            path,
            duration_ms: dur_ms,
            bytes_written,
            sample_count,
        })
    }

    // =========================================================================
    // Capture & Microphone Methods
    // =========================================================================

    /// Initializes and opens the microphone capture stream with ducking and monitoring options.
    pub fn enable_microphone(
        &self,
        device_id: Option<String>,
        volume: f32,
        ducking: Option<RustDuckingConfig>,
        monitor_direct: bool,
        monitor_volume: f32,
    ) -> Result<(), String> {
        let (d_en, d_db, t_db, att_ms, hold_ms, rel_ms) = match ducking {
            Some(d) => (d.enabled, d.ducking_db, d.threshold_db, d.attack_ms, d.hold_ms, d.release_ms),
            None => (false, -14.0, -30.0, 30.0, 250.0, 400.0),
        };

        let res = self.inner.lock().unwrap().input_manager.enable_microphone(
            device_id,
            volume,
            d_en,
            d_db,
            t_db,
            att_ms,
            hold_ms,
            rel_ms,
            monitor_direct,
            monitor_volume,
        );
        if res.is_ok() {
            self.emit_event(RustPlayerEvent::MicrophoneEnabled(true));
            self.emit_event(RustPlayerEvent::MicVolume(volume));
            self.emit_event(RustPlayerEvent::DirectMonitoringEnabled(monitor_direct));
        }
        res
    }

    /// Stops and closes the active microphone capture device.
    #[flutter_rust_bridge::frb(sync)]
    pub fn disable_microphone(&self) {
        self.inner.lock().unwrap().input_manager.disable_microphone();
        self.emit_event(RustPlayerEvent::MicrophoneEnabled(false));
    }

    /// Sets the microphone input gain volume multiplier.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_microphone_volume(&self, volume: f32) {
        self.inner.lock().unwrap().input_manager.set_volume(volume);
        self.emit_event(RustPlayerEvent::MicVolume(volume));
    }

    /// Updates dynamic ducking parameters for attenuating music during microphone speech.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_ducking(&self, config: RustDuckingConfig) {
        self.inner.lock().unwrap().input_manager.set_ducking(
            config.enabled,
            config.ducking_db,
            config.threshold_db,
            config.attack_ms,
            config.hold_ms,
            config.release_ms,
        );
    }

    /// Enables or disables direct microphone monitoring to the main speaker output.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_direct_monitoring(&self, enabled: bool, volume: f32) {
        self.inner.lock().unwrap().input_manager.set_direct_monitoring(enabled, volume);
        self.emit_event(RustPlayerEvent::DirectMonitoringEnabled(enabled));
    }

    /// Toggles whether playback automatically pauses when an output audio device changes or disconnects.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_pause_on_device_change(&self, enabled: bool) {
        let ply = self.inner.lock().unwrap();
        let prev = ply.output_manager.pause_on_device_change.load(std::sync::atomic::Ordering::Relaxed);
        if prev != enabled {
            ply.output_manager.set_pause_on_device_change(enabled);
            self.emit_event(RustPlayerEvent::PauseOnDeviceChange(enabled));
        }
    }

    // =========================================================================
    // Device Enumeration Methods
    // =========================================================================

    /// Synchronously scans and enumerates connected playback output audio devices.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_output_devices_sync() -> Result<Vec<RustAudioDevice>, String> {
        let mut count = 0;
        let mut ptr = std::ptr::null_mut();
        let res = unsafe { map_device_enumerate_devices(&mut ptr, &mut count) };
        if res != 0 {
            return Err(format!("Device enumeration failed with code {}", res));
        }
        let mut out = Vec::with_capacity(count as usize);
        if !ptr.is_null() {
            let slice = unsafe { std::slice::from_raw_parts(ptr, count as usize) };
            for d in slice {
                out.push(RustAudioDevice::from(d));
            }
            unsafe { map_device_free_devices(ptr) };
        }
        Ok(out)
    }

    /// Asynchronously enumerates connected playback output audio devices.
    pub fn get_output_devices() -> Result<Vec<RustAudioDevice>, String> {
        Self::get_output_devices_sync()
    }

    /// Synchronously scans and enumerates connected microphone capture devices.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_input_devices_sync() -> Result<Vec<RustAudioDevice>, String> {
        let mut count = 0;
        let mut ptr = std::ptr::null_mut();
        let res = unsafe { map_device_enumerate_capture_devices(&mut ptr, &mut count) };
        if res != 0 {
            return Err(format!("Capture device enumeration failed with code {}", res));
        }
        let mut out = Vec::with_capacity(count as usize);
        if !ptr.is_null() {
            let slice = unsafe { std::slice::from_raw_parts(ptr, count as usize) };
            for d in slice {
                out.push(RustAudioDevice::from(d));
            }
            unsafe { map_device_free_devices(ptr) };
        }
        Ok(out)
    }

    /// Asynchronously enumerates connected microphone capture devices.
    pub fn get_input_devices() -> Result<Vec<RustAudioDevice>, String> {
        Self::get_input_devices_sync()
    }

    /// Responds to a pending custom stream byte read request from Dart.
    #[flutter_rust_bridge::frb(sync)]
    pub fn respond_dart_read_request(
        &self,
        request_id: u64,
        bytes: Vec<u8>,
        is_eof: bool,
    ) -> Result<(), String> {
        if let Ok(guard) = self.custom_handle.lock() {
            if let Some(ref handle) = *guard {
                handle.supply_bytes(request_id, bytes, is_eof);
                return Ok(());
            }
        }
        if let Ok(ply) = self.inner.try_lock() {
            let active = ply.music_manager.active_deck_ref();
            if let Some(ref handle) = *active.custom_source_handle.read().unwrap() {
                handle.supply_bytes(request_id, bytes, is_eof);
            }
        }
        Ok(())
    }

    // =========================================================================
    // Lifecycle Disposal
    // =========================================================================

    /// Releases all native audio devices, worker threads, DSP chains, and memory.
    #[flutter_rust_bridge::frb(sync)]
    pub fn dispose(&self) {
        self.monitor_running.store(false, Ordering::Release);
        let (lock, cvar) = &*self.device_trigger;
        if let Ok(mut flag) = lock.lock() {
            *flag = true;
            cvar.notify_all();
        }
        self.reporter.clear_sink();
        if let Ok(mut guard) = self.custom_handle.lock() {
            *guard = None;
        }
        if let Ok(mut ply) = self.inner.lock() {
            ply.dispose();
        }
    }
}

// =========================================================================
// Top-Level Static Analysis & Utility Functions
// =========================================================================

/// Sets the global native diagnostic logging verbosity level.
#[flutter_rust_bridge::frb(sync)]
pub fn set_log_level(level: i32) {
    crate::LOG_LEVEL.store(level, Ordering::Relaxed);
}

/// Asynchronously analyzes acoustic and loudness properties of an audio file on disk.
pub fn analyze_audio_file(
    path: String,
    replay_gain: bool,
    waveform: bool,
    waveform_points: usize,
    target_lufs: f64,
) -> Result<RustAudioAnalysisResult, String> {
    let mut flags = 0;
    if replay_gain {
        flags |= MAP_ANALYSIS_FLAG_REPLAY_GAIN;
    }
    if waveform {
        flags |= MAP_ANALYSIS_FLAG_WAVEFORM;
    }

    let config = AudioAnalysisConfig {
        flags,
        target_lufs: target_lufs as f32,
        waveform_points: waveform_points as u32,
    };

    let res = dsp_analyze_file(&path, &config).map_err(|e| format!("Audio analysis failed: {}", e))?;
    Ok(res.into())
}

/// Synchronously analyzes acoustic and loudness properties of an audio file on disk.
#[flutter_rust_bridge::frb(sync)]
pub fn analyze_audio_file_sync(
    path: String,
    replay_gain: bool,
    waveform: bool,
    waveform_points: usize,
    target_lufs: f64,
) -> Result<RustAudioAnalysisResult, String> {
    analyze_audio_file(path, replay_gain, waveform, waveform_points, target_lufs)
}

/// Asynchronously analyzes acoustic and loudness properties of an in-memory audio buffer.
pub fn analyze_audio_memory(
    data: Vec<u8>,
    hint_extension: Option<String>,
    replay_gain: bool,
    waveform: bool,
    waveform_points: usize,
    target_lufs: f64,
) -> Result<RustAudioAnalysisResult, String> {
    let mut flags = 0;
    if replay_gain {
        flags |= MAP_ANALYSIS_FLAG_REPLAY_GAIN;
    }
    if waveform {
        flags |= MAP_ANALYSIS_FLAG_WAVEFORM;
    }

    let config = AudioAnalysisConfig {
        flags,
        target_lufs: target_lufs as f32,
        waveform_points: waveform_points as u32,
    };

    let data_len = data.len() as u64;
    let source = crate::buffer::MemoryByteSource::new(data);
    let res = dsp_analyze_media_source(source, hint_extension.as_deref(), &config, data_len)
        .map_err(|e| format!("Audio analysis failed: {}", e))?;
    Ok(res.into())
}
