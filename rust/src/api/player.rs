//! Native Miniaudio Player API exposed to Flutter/Dart via flutter_rust_bridge.
//!
//! Exposes `RustMiniaudioPlayer` orchestrating music decks, RAM sound effects,
//! multi-destination output matrix, and microphone capture sidechain.

use std::ffi::CString;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::bridge::ffi::{
    map_device_enumerate_capture_devices, map_device_enumerate_devices, map_device_free_devices,
    map_device_set_device,
};
use crate::core::dual_source::AudioSourceCore;
use crate::core::miniaudio_player::MiniaudioPlayer;
use crate::core::output_matrix::CueSource;
use crate::core::recording::WavFormat;
use crate::core::voice_pool::{DspRouting, EffectConfig, SoundBuffer};
use crate::dsp::analysis::{
    analyze_file as dsp_analyze_file, analyze_media_source as dsp_analyze_media_source,
    AudioAnalysisConfig, MAP_ANALYSIS_FLAG_REPLAY_GAIN, MAP_ANALYSIS_FLAG_WAVEFORM,
};
use crate::dsp::equalizer::EqualizerParams;
use crate::dsp::reverb::ReverbConfig;
use crate::dsp::silence::SilenceConfig;
use crate::frb_generated::StreamSink;

use super::types::*;

pub struct TelemetryFilter {
    pub state: Option<i32>,
    pub phase: Option<i32>,
    pub pos: i64,
    pub dur: Option<i64>,
    pub index: Option<i32>,
    pub bitrate: Option<u32>,
    pub buffered_end: Option<i64>,
    pub is_buffering: Option<bool>,
    pub is_xfading: Option<bool>,
    pub is_recording: Option<bool>,
    pub is_ducking: Option<bool>,
    pub is_playing: Option<bool>,
    pub is_completed: Option<bool>,
    pub replay_gain: Option<(u32, u32, bool)>,
    pub meta_bytes: Option<Vec<u8>>,
    pub active_voices: Option<u32>,
}

impl Default for TelemetryFilter {
    fn default() -> Self {
        Self {
            state: Some(0),
            phase: Some(0),
            pos: 0,
            dur: None,
            index: None,
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

#[derive(Clone)]
pub struct EventReporter {
    event_sink: Arc<Mutex<Option<StreamSink<RustPlayerEvent>>>>,
    pending_events: Arc<Mutex<Vec<RustPlayerEvent>>>,
    filter: Arc<Mutex<TelemetryFilter>>,
}

impl EventReporter {
    pub fn new() -> Self {
        Self {
            event_sink: Arc::new(Mutex::new(None)),
            pending_events: Arc::new(Mutex::new(Vec::new())),
            filter: Arc::new(Mutex::new(TelemetryFilter::default())),
        }
    }

    pub fn set_sink(&self, sink: StreamSink<RustPlayerEvent>) {
        if let Ok(mut pending) = self.pending_events.lock() {
            for ev in pending.drain(..) {
                let _ = sink.add(ev);
            }
        }
        let mut guard = self.event_sink.lock().unwrap();
        *guard = Some(sink);
    }

    pub fn clear_sink(&self) {
        if let Ok(mut guard) = self.event_sink.lock() {
            *guard = None;
        }
    }

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
                let key = (rg.gain_db.to_bits(), rg.peak.to_bits(), rg.enabled);
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

pub struct RustMiniaudioPlayer {
    inner: Arc<Mutex<Box<MiniaudioPlayer>>>,
    reporter: EventReporter,
    custom_handle: Arc<Mutex<Option<crate::buffer::CustomByteSourceHandle>>>,
    monitor_running: Arc<AtomicBool>,
    _monitor_thread: Option<JoinHandle<()>>,
    device_trigger: Arc<(Mutex<bool>, Condvar)>,
    _watcher_thread: Option<JoinHandle<()>>,
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
    #[flutter_rust_bridge::frb(sync)]
    pub fn new(
        config: RustPlayerConfig,
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        playback_device_id: Option<String>,
    ) -> Result<RustMiniaudioPlayer, String> {
        let device_trigger = Arc::new((Mutex::new(true), Condvar::new()));
        let player = MiniaudioPlayer::new(
            sample_rate,
            channels,
            period_size,
            playback_device_id,
            config.max_voices as usize,
            config.max_ram_bytes as usize,
            Some(device_trigger.clone()),
        )?;
        player.output_manager.set_pause_on_device_change(config.pause_on_device_change);

        let inner = Arc::new(Mutex::new(player));
        let reporter = EventReporter::new();
        let custom_handle = Arc::new(Mutex::new(None));
        let monitor_running = Arc::new(AtomicBool::new(true));
        let metabytes_enabled = Arc::new(AtomicBool::new(false));

        let watcher_trigger = device_trigger.clone();
        let watcher_running = monitor_running.clone();
        let watcher_reporter = reporter.clone();

        // Background device watcher: reacts to hardware changes without polling every X seconds
        // and runs asynchronously to never block real-time audio, telemetry, or UI threads.
        let watcher_thread = thread::Builder::new()
            .name("map-device-watcher".to_string())
            .spawn(move || {
                let (lock, cvar) = &*watcher_trigger;
                let mut last_out_devices: Vec<RustAudioDevice> = Vec::new();
                let mut last_in_devices: Vec<RustAudioDevice> = Vec::new();

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
                            watcher_reporter.emit(RustPlayerEvent::OutputDevices(out_devs));
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

                        let auto_target = ply.music_manager.inner.auto_crossfade_target_index.swap(-1, Ordering::AcqRel);
                        if auto_target >= 0 {
                            ply.music_manager.inner.current_index.store(auto_target, Ordering::Release);
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
                                            ply.music_manager.inner.auto_crossfade_target_index.store(next_idx as i64, Ordering::Release);
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

                    // Check completed voice pool effects
                    if let Ok(mut vp) = ply.effects_manager.pool.try_lock() {
                        while let Ok(v_id) = vp.completed_voices_consumer.pop() {
                            worker_reporter.emit(RustPlayerEvent::VoiceCompleted(v_id));
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
                        prevent_clipping: rg.prevent_clipping != 0,
                        enabled: rg.enabled != 0,
                    }));
                    if let Some(vis) = vis_data {
                        worker_reporter.emit(RustPlayerEvent::Visualizer(
                            RustVisualizerData::from(vis),
                        ));
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
            metabytes_enabled,
        })
    }

    pub fn subscribe_events(
        &self,
        sink: StreamSink<RustPlayerEvent>,
    ) -> Result<(), String> {
        self.reporter.set_sink(sink);

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
            let q: Vec<RustAudioSource> = ply.music_manager.inner.queue.read().unwrap()
                .iter().map(RustAudioSource::from).collect();
            self.emit_event(RustPlayerEvent::Queue(q));
        }
    }

    // =========================================================================
    // Transport & Playback Methods
    // =========================================================================

    #[flutter_rust_bridge::frb(sync)]
    pub fn play(&self) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        let res = ply.music_manager.play()?;
        let cur_idx = ply.music_manager.current_index();
        let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
        let state = ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed);
        let is_playing = state == crate::core::dual_source::STATE_PLAYING;
        drop(ply);
        self.emit_event(RustPlayerEvent::CurrentIndex(cur_idx as i32));
        self.emit_event(RustPlayerEvent::IsCompleted(false));
        self.emit_event(RustPlayerEvent::PlaybackState(state));
        self.emit_event(RustPlayerEvent::State(phase));
        self.emit_event(RustPlayerEvent::IsPlaying(is_playing));
        Ok(res)
    }

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

    #[flutter_rust_bridge::frb(sync)]
    pub fn stop(&self) {
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.stop();
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

fn sync_deck_replay_gain(ply: &mut crate::core::miniaudio_player::MiniaudioPlayer, idx: usize) {
    let rg_to_set = {
        let q = ply.music_manager.inner.queue.read().unwrap();
        if idx < q.len() {
            if let Some(gain) = q[idx].replay_gain_db {
                let peak = q[idx].replay_peak.unwrap_or(1.0);
                Some((gain, peak))
            } else {
                None
            }
        } else {
            None
        }
    };
    if let Some((gain, peak)) = rg_to_set {
        ply.music_dsp.set_replay_gain(crate::dsp::equalizer::ReplayGainConfig {
            enabled: 1,
            gain_db: gain,
            peak,
            prevent_clipping: 1,
        });
    } else {
        ply.music_dsp.set_replay_gain(crate::dsp::equalizer::ReplayGainConfig::default());
    }
}

    // =========================================================================
    // Queue Management Methods
    // =========================================================================

    pub fn open(
        &self,
        queue: Vec<RustAudioSource>,
        start_index: usize,
        auto_play: bool,
    ) -> Result<(), String> {
        let core_queue: Vec<AudioSourceCore> = queue.into_iter().map(Into::into).collect();
        let reporter_clone = self.reporter.clone();
        let handle_arc = self.custom_handle.clone();
        let custom_factory = Arc::new(move |stream_id: u32, total_size: Option<u64>, initial_bytes: Vec<u8>| {
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
        });
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.set_custom_source_factory(custom_factory);
        let res = ply.music_manager.open(core_queue, start_index, auto_play);
        let active_deck = ply.music_manager.active_deck_ref();
        let initial_state = active_deck.state.load(std::sync::atomic::Ordering::Relaxed);
        let initial_phase = ply.music_manager.inner.phase.load(std::sync::atomic::Ordering::Relaxed);
        let initial_pos = active_deck.position_ms.load(std::sync::atomic::Ordering::Relaxed);
        let initial_dur = active_deck.duration_ms.load(std::sync::atomic::Ordering::Relaxed);
        let initial_bitrate = active_deck.bitrate.load(std::sync::atomic::Ordering::Relaxed);
        let initial_meta = active_deck.get_meta_bytes();
        let mut initial_br = crate::bridge::ffi::MiniaudioBufferedRange::default();
        let has_br = active_deck.get_buffered_range(&mut initial_br) == 0;
        if let Ok(mut f) = self.reporter.filter.lock() {
            *f = TelemetryFilter::default();
        }
        Self::sync_deck_replay_gain(&mut ply, start_index);
        drop(ply);
        self.emit_queue();
        self.emit_event(RustPlayerEvent::CurrentIndex(start_index as i32));
        self.emit_event(RustPlayerEvent::IsCompleted(false));
        if self.metabytes_enabled.load(std::sync::atomic::Ordering::Relaxed) {
            self.emit_event(RustPlayerEvent::MetaBytes(Vec::new()));
            if let Some(mb) = initial_meta {
                self.emit_event(RustPlayerEvent::MetaBytes(mb));
            }
        }
        if initial_pos > 0 {
            self.emit_event(RustPlayerEvent::Position(initial_pos));
        }
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
        if initial_state != 0 {
            self.emit_event(RustPlayerEvent::PlaybackState(initial_state));
        }
        if initial_phase != 0 {
            self.emit_event(RustPlayerEvent::State(initial_phase));
        }
        res
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn append(&self, sources: Vec<RustAudioSource>) {
        let core_sources: Vec<AudioSourceCore> = sources.into_iter().map(Into::into).collect();
        self.inner.lock().unwrap().music_manager.append(core_sources);
        self.emit_queue();
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn insert_next(&self, source: RustAudioSource) {
        self.inner.lock().unwrap().music_manager.insert_next(source.into());
        self.emit_queue();
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn remove_at(&self, index: usize) -> bool {
        let res = self.inner.lock().unwrap().music_manager.remove_at(index).is_some();
        if res {
            self.emit_queue();
        }
        res
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn reorder(&self, old_index: usize, new_index: usize) -> bool {
        let res = self.inner.lock().unwrap().music_manager.reorder(old_index, new_index);
        if res {
            self.emit_queue();
        }
        res
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn reorder_by_ids(&self, ids: Vec<i64>) -> bool {
        let res = self.inner.lock().unwrap().music_manager.reorder_by_ids(&ids);
        if res {
            self.emit_queue();
        }
        res
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn clear_queue(&self, keep_current: bool) {
        self.inner.lock().unwrap().music_manager.clear_queue(keep_current);
        self.emit_queue();
    }

    pub fn next(&self, crossfade_duration_ms: Option<u64>) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.next(crossfade_duration_ms)?;
        let idx = ply.music_manager.current_index();
        let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
        let state = ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed);
        let is_playing = state == crate::core::dual_source::STATE_PLAYING;
        if idx >= 0 {
            Self::sync_deck_replay_gain(&mut ply, idx as usize);
        }
        drop(ply);
        self.emit_event(RustPlayerEvent::CurrentIndex(idx as i32));
        self.emit_event(RustPlayerEvent::State(phase));
        self.emit_event(RustPlayerEvent::IsPlaying(is_playing));
        self.emit_event(RustPlayerEvent::PlaybackState(state));
        self.emit_event(RustPlayerEvent::IsCompleted(false));
        Ok(())
    }

    pub fn previous(&self) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.previous()?;
        let idx = ply.music_manager.current_index();
        let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
        let pos = ply.music_manager.active_deck_ref().position_ms.load(Ordering::Relaxed);
        let state = ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed);
        let is_playing = state == crate::core::dual_source::STATE_PLAYING;
        if idx >= 0 {
            Self::sync_deck_replay_gain(&mut ply, idx as usize);
        }
        drop(ply);
        self.emit_event(RustPlayerEvent::CurrentIndex(idx as i32));
        self.emit_event(RustPlayerEvent::Position(pos));
        self.emit_event(RustPlayerEvent::State(phase));
        self.emit_event(RustPlayerEvent::IsPlaying(is_playing));
        self.emit_event(RustPlayerEvent::PlaybackState(state));
        self.emit_event(RustPlayerEvent::IsCompleted(false));
        Ok(())
    }

    pub fn skip_to_index(
        &self,
        index: usize,
        crossfade_duration_ms: Option<u64>,
    ) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        ply.music_manager.skip_to_index(index, crossfade_duration_ms)?;
        let idx = ply.music_manager.current_index();
        let phase = ply.music_manager.inner.phase.load(Ordering::Relaxed);
        let state = ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed);
        let is_playing = state == crate::core::dual_source::STATE_PLAYING;
        if idx >= 0 {
            Self::sync_deck_replay_gain(&mut ply, idx as usize);
        }
        drop(ply);
        self.emit_event(RustPlayerEvent::CurrentIndex(idx as i32));
        self.emit_event(RustPlayerEvent::State(phase));
        self.emit_event(RustPlayerEvent::IsPlaying(is_playing));
        self.emit_event(RustPlayerEvent::PlaybackState(state));
        self.emit_event(RustPlayerEvent::IsCompleted(false));
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_loop_mode(&self, mode: i32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_manager.inner.loop_mode.load(std::sync::atomic::Ordering::Relaxed);
        if prev != mode {
            ply.music_manager.set_loop_mode(mode);
            self.emit_event(RustPlayerEvent::LoopMode(mode));
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_shuffle(&self, enabled: bool) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_manager.is_shuffled();
        if prev != enabled {
            ply.music_manager.set_shuffle(enabled);
            self.emit_event(RustPlayerEvent::IsShuffled(enabled));
        }
    }

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

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_volume(&self, volume: f32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_dsp.volume;
        if (prev - volume).abs() > 1e-5 {
            ply.set_volume(volume);
            self.emit_event(RustPlayerEvent::Volume(volume));
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_rate(&self, rate: f32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_manager.rate();
        if (prev - rate).abs() > 1e-5 {
            ply.music_manager.set_rate(rate);
            self.emit_event(RustPlayerEvent::Rate(rate));
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_pitch(&self, pitch: f32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_manager.pitch();
        if (prev - pitch).abs() > 1e-5 {
            ply.music_manager.set_pitch(pitch);
            self.emit_event(RustPlayerEvent::Pitch(pitch));
        }
    }

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

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_mono(&self, enabled: bool) {
        let mut ply = self.inner.lock().unwrap();
        if ply.music_dsp.mono != enabled {
            ply.music_dsp.set_mono(enabled);
            self.emit_event(RustPlayerEvent::Mono(enabled));
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_preamp(&self, preamp_db: f32) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.music_dsp.equalizer.preamp_db();
        if (prev - preamp_db).abs() > 1e-5 {
            ply.music_dsp.set_preamp(preamp_db);
            self.emit_event(RustPlayerEvent::Preamp(preamp_db));
        }
    }

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

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_replay_gain(&self, config: RustReplayGainConfig) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        let clipping = if config.prevent_clipping { 1 } else { 0 };
        let rg = crate::dsp::equalizer::ReplayGainConfig {
            enabled: if config.enabled { 1 } else { 0 },
            gain_db: config.gain_db,
            peak: config.peak,
            prevent_clipping: clipping,
        };
        ply.music_dsp.set_replay_gain(rg);
        self.emit_event(RustPlayerEvent::ReplayGain(config));
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_skip_silence(&self, config: RustSilenceConfig) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        let sc = SilenceConfig::from(config.clone());
        ply.music_manager.inner.deck_a.set_silence_config(&sc);
        ply.music_manager.inner.deck_b.set_silence_config(&sc);
        self.emit_event(RustPlayerEvent::SilenceConfig(config));
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_equalizer(&self, params: RustEqualizerParams) -> Result<(), String> {
        let eq = EqualizerParams::from(params.clone());
        let mut ply = self.inner.lock().unwrap();
        ply.music_dsp.set_equalizer(&eq);
        self.emit_event(RustPlayerEvent::Equalizer(params));
        Ok(())
    }

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

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_limiter(&self, enabled: bool) {
        let mut ply = self.inner.lock().unwrap();
        let prev = ply.master_limiter.is_enabled();
        if prev != enabled {
            ply.master_limiter.set_enabled(enabled);
            self.emit_event(RustPlayerEvent::Limiter(enabled));
        }
    }

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

    pub fn load_effect(
        &self,
        id: String,
        source: RustAudioSource,
        max_polyphony: usize,
        pinned: bool,
    ) -> Result<(), String> {
        let sound_buffer = match source.data_bytes {
            Some(bytes) if !bytes.is_empty() => SoundBuffer::decode_from_bytes(&bytes)
                .map_err(|e| format!("Decoding effect '{}' failed: {}", id, e))?,
            _ => {
                let path = crate::core::dual_source::strip_file_prefix(&source.source);
                let path = crate::core::dual_source::resolve_local_source_path(&path);
                let bytes = std::fs::read(&path)
                    .map_err(|e| format!("Failed to read effect file '{}': {}", path, e))?;
                SoundBuffer::decode_from_bytes(&bytes)
                    .map_err(|e| format!("Decoding effect '{}' failed: {}", id, e))?
            }
        };
        let ply = self.inner.lock().unwrap();
        ply.effects_manager.load_effect(
            id,
            sound_buffer,
            max_polyphony,
            pinned,
        )?;
        let loaded_ids = ply.effects_manager.loaded_effect_ids();
        let ram_bytes = ply.effects_manager.allocated_ram_bytes();
        drop(ply);
        self.emit_event(RustPlayerEvent::LoadedEffects {
            ids: loaded_ids,
            allocated_bytes: ram_bytes,
        });
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn unload_effect(&self, id: String) -> bool {
        let ply = self.inner.lock().unwrap();
        let res = ply.effects_manager.unload_effect(&id);
        if res {
            let loaded_ids = ply.effects_manager.loaded_effect_ids();
            let ram_bytes = ply.effects_manager.allocated_ram_bytes();
            drop(ply);
            self.emit_event(RustPlayerEvent::LoadedEffects {
                ids: loaded_ids,
                allocated_bytes: ram_bytes,
            });
        }
        res
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_loaded_effect_ids(&self) -> Vec<String> {
        self.inner.lock().unwrap().effects_manager.loaded_effect_ids()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_allocated_ram_bytes(&self) -> usize {
        self.inner.lock().unwrap().effects_manager.allocated_ram_bytes()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_active_voices_count(&self) -> u32 {
        self.inner.lock().unwrap().effects_manager.active_voices_count()
    }

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
        self.inner.lock().unwrap().effects_manager.play_effect(&id, routing, core_config)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stop_effect(&self, voice_id: u32, fade_out_ms: u64) {
        let sr = self.inner.lock().unwrap().sample_rate;
        let fade_samples = (fade_out_ms as f64 * (sr as f64 / 1000.0)) as usize;
        self.inner.lock().unwrap().effects_manager.stop_effect(voice_id, fade_samples);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stop_all_effects(&self, fade_out_ms: u64) {
        let sr = self.inner.lock().unwrap().sample_rate;
        let fade_samples = (fade_out_ms as f64 * (sr as f64 / 1000.0)) as usize;
        self.inner.lock().unwrap().effects_manager.stop_all_effects(fade_samples);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_effect_volume(&self, voice_id: u32, volume: f32) {
        self.inner.lock().unwrap().effects_manager.set_voice_volume(voice_id, volume);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_effect_pitch(&self, voice_id: u32, pitch: f32) {
        self.inner.lock().unwrap().effects_manager.set_voice_pitch(voice_id, pitch);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_effect_balance(&self, voice_id: u32, balance: f32) {
        self.inner.lock().unwrap().effects_manager.set_voice_balance(voice_id, balance);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_effect_emitter(&self, voice_id: u32, emitter: Option<RustSpatialEmitter>) {
        self.inner.lock().unwrap().effects_manager.set_voice_emitter(
            voice_id,
            emitter.map(Into::into),
        );
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_listener(&self, listener: RustSpatialListener) {
        self.inner.lock().unwrap().effects_manager.set_listener(listener.into());
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_doppler_parameters(&self, factor: f32, speed_of_sound: f32) {
        self.inner.lock().unwrap().effects_manager.set_doppler_parameters(factor, speed_of_sound);
    }

    // =========================================================================
    // Multiple Outputs & Live Recording Methods
    // =========================================================================

    #[flutter_rust_bridge::frb(sync)]
    pub fn add_output(&self, output: RustAudioOutput) -> Result<(), String> {
        let mut ply = self.inner.lock().unwrap();
        let res = match output {
            RustAudioOutput::Speaker { .. } => Ok(()),
            RustAudioOutput::Device { device_id, .. } => {
                let c_dev = CString::new(device_id).map_err(|e| e.to_string())?;
                let r = unsafe { map_device_set_device(ply.device_ctx, c_dev.as_ptr()) };
                if r != 0 {
                    Err(format!("Setting device failed with code {}", r))
                } else {
                    Ok(())
                }
            }
            RustAudioOutput::Cue { device_id, source } => {
                ply.output_manager.enable_cue(Some(&device_id))?;
                ply.output_manager.set_cue_source(CueSource::from(source));
                Ok(())
            }
            RustAudioOutput::File { path, format } => {
                let fmt = match format {
                    1 => WavFormat::Float32,
                    _ => WavFormat::Pcm16,
                };
                let r = ply.output_manager.start_recording(&path, fmt);
                if r.is_ok() {
                    self.emit_event(RustPlayerEvent::IsRecording(true));
                }
                r
            }
        };
        drop(ply);
        let (lock, cvar) = &*self.device_trigger;
        if let Ok(mut flag) = lock.lock() {
            *flag = true;
            cvar.notify_one();
        }
        res
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn remove_output(&self, output: RustAudioOutput) {
        let mut ply = self.inner.lock().unwrap();
        match output {
            RustAudioOutput::Speaker { .. } => {}
            RustAudioOutput::Device { .. } => {
                let _ = unsafe { map_device_set_device(ply.device_ctx, std::ptr::null()) };
            }
            RustAudioOutput::Cue { .. } => {
                ply.output_manager.disable_cue();
            }
            RustAudioOutput::File { .. } => {
                let _ = ply.output_manager.stop_recording();
                self.emit_event(RustPlayerEvent::IsRecording(false));
            }
        }
        drop(ply);
        let (lock, cvar) = &*self.device_trigger;
        if let Ok(mut flag) = lock.lock() {
            *flag = true;
            cvar.notify_one();
        }
    }

    pub fn configure_outputs(&self, outputs: Vec<RustAudioOutput>) -> Result<(), String> {
        for out in outputs {
            self.add_output(out)?;
        }
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_cue_source(&self, source: i32) {
        self.inner.lock().unwrap().output_manager.set_cue_source(CueSource::from(source));
        self.emit_event(RustPlayerEvent::CueSource(source));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_cue_volume(&self, volume: f32) {
        self.inner.lock().unwrap().output_manager.set_cue_volume(volume);
        self.emit_event(RustPlayerEvent::CueVolume(volume));
    }

    pub fn start_recording(&self, path: String, format: i32) -> Result<(), String> {
        let fmt = match format {
            1 => WavFormat::Float32,
            _ => WavFormat::Pcm16,
        };
        self.inner.lock().unwrap().output_manager.start_recording(&path, fmt)?;
        self.emit_event(RustPlayerEvent::IsRecording(true));
        Ok(())
    }

    pub fn stop_recording(&self) -> Result<RustRecordingResult, String> {
        let mut ply = self.inner.lock().unwrap();
        let (path, dur_ms, bytes_written, sample_count) = ply.output_manager.stop_recording()?;
        drop(ply);
        self.emit_event(RustPlayerEvent::IsRecording(false));

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

    #[flutter_rust_bridge::frb(sync)]
    pub fn disable_microphone(&self) {
        self.inner.lock().unwrap().input_manager.disable_microphone();
        self.emit_event(RustPlayerEvent::MicrophoneEnabled(false));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_microphone_volume(&self, volume: f32) {
        self.inner.lock().unwrap().input_manager.set_volume(volume);
        self.emit_event(RustPlayerEvent::MicVolume(volume));
    }

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

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_direct_monitoring(&self, enabled: bool, volume: f32) {
        self.inner.lock().unwrap().input_manager.set_direct_monitoring(enabled, volume);
        self.emit_event(RustPlayerEvent::DirectMonitoringEnabled(enabled));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_pause_on_device_change(&self, enabled: bool) {
        let ply = self.inner.lock().unwrap();
        let prev = ply.output_manager.matrix.pause_on_device_change.load(std::sync::atomic::Ordering::Relaxed);
        if prev != enabled {
            ply.output_manager.set_pause_on_device_change(enabled);
            self.emit_event(RustPlayerEvent::PauseOnDeviceChange(enabled));
        }
    }

    // =========================================================================
    // Device Enumeration Methods
    // =========================================================================

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

    pub fn get_output_devices() -> Result<Vec<RustAudioDevice>, String> {
        Self::get_output_devices_sync()
    }

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

    pub fn get_input_devices() -> Result<Vec<RustAudioDevice>, String> {
        Self::get_input_devices_sync()
    }

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

#[flutter_rust_bridge::frb(sync)]
pub fn set_log_level(level: i32) {
    crate::LOG_LEVEL.store(level, Ordering::Relaxed);
}

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
