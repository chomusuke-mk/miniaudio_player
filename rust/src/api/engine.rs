//! High-level Rust Engine API exposed to Flutter/Dart via flutter_rust_bridge.

use std::ffi::CString;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::core::engine::{
    EngineCoordinator, EngineItemCore, ENGINE_PHASE_AUTO_CROSSFADING,
    ENGINE_PHASE_COMPLETED, ENGINE_PHASE_IDLE,
    ENGINE_PHASE_MANUAL_CROSSFADING, ENGINE_PHASE_PAUSED, ENGINE_PHASE_PLAYING,
};
use crate::core::player::{
    STATE_BUFFERING, STATE_COMPLETED, STATE_PAUSED, STATE_PLAYING,
};
use crate::dsp::equalizer::EqualizerParams;
use crate::frb_generated::StreamSink;

use super::types::*;

pub struct RustEngine {
    coordinator: Arc<Mutex<Box<EngineCoordinator>>>,
    event_sink: Arc<Mutex<Option<StreamSink<RustEngineEvent>>>>,
}

#[inline]
fn emit_event(sink_lock: &Arc<Mutex<Option<StreamSink<RustEngineEvent>>>>, event: RustEngineEvent) {
    if let Ok(guard) = sink_lock.lock() {
        if let Some(ref sink) = *guard {
            let _ = sink.add(event);
        }
    }
}

fn queue_to_rust_items(q: &[EngineItemCore]) -> Vec<RustEngineItem> {
    q.iter().map(|it| RustEngineItem {
        id: it.id,
        source: it.source.clone(),
        headers: it.headers.clone(),
        data_bytes: it.data_bytes.clone(),
        replay_gain_db: it.replay_gain_db,
        replay_peak: it.replay_peak,
    }).collect()
}

impl RustEngine {
    #[flutter_rust_bridge::frb(sync)]
    pub fn new(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        playback_device_id: Option<String>,
    ) -> Result<RustEngine, String> {
        let dev_id_c = playback_device_id.map(|s| CString::new(s).unwrap_or_default());
        let dev_id_ptr = dev_id_c.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

        let coordinator = EngineCoordinator::new(
            sample_rate,
            channels,
            period_size,
            dev_id_ptr,
        ).map_err(|e| format!("Failed to create engine coordinator: error {}", e))?;

        let coord_arc = Arc::new(Mutex::new(coordinator));
        let event_sink: Arc<Mutex<Option<StreamSink<RustEngineEvent>>>> = Arc::new(Mutex::new(None));

        // Start telemetry & background crossfade monitor thread
        let coord_clone = coord_arc.clone();
        let sink_clone = event_sink.clone();

        thread::Builder::new()
            .name("miniaudio-engine-monitor".to_string())
            .spawn(move || {
                let mut last_pos: i64 = -1;
                let mut last_dur: i64 = -1;
                let mut last_playing = false;
                let mut last_phase: i32 = -1;
                let mut last_index: i64 = -2;
                let mut last_notified_track_id: i64 = -1;

                loop {
                    thread::sleep(Duration::from_millis(30));

                    let mut coord = match coord_clone.lock() {
                        Ok(g) => g,
                        Err(_) => break,
                    };

                    if !coord.thread_running.load(Ordering::Relaxed) {
                        break;
                    }

                    // 1. Check crossfade completion or tick progress
                    let mut xfade_done = coord.crossfade_completed_flag.swap(false, Ordering::AcqRel);
                    if !xfade_done && coord.crossfade.is_active.load(Ordering::Relaxed) {
                        let sr = coord.deck_a.sample_rate.load(Ordering::Relaxed).max(44100);
                        let frames_per_tick = (30 * sr as u64) / 1000;
                        let cur_f = coord.crossfade.current_frame.fetch_add(frames_per_tick, Ordering::Relaxed);
                        let tot_f = coord.crossfade.total_frames.load(Ordering::Relaxed);
                        if cur_f + frames_per_tick >= tot_f {
                            coord.crossfade.is_active.store(false, Ordering::Release);
                            let to_deck = coord.crossfade.to_deck.load(Ordering::Relaxed);
                            coord.active_deck.store(to_deck, Ordering::Release);
                            xfade_done = true;
                        }
                    }

                    if xfade_done {
                        // The old deck is now stopped and muted
                        let active = coord.active_deck.load(Ordering::Acquire);
                        if active == 0 {
                            coord.deck_b.stop();
                        } else {
                            coord.deck_a.stop();
                        }

                        coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
                        emit_event(&sink_clone, RustEngineEvent::Phase(ENGINE_PHASE_PLAYING));
                    }

                    // 2. Active deck telemetry
                    let active_deck = coord.active_deck.load(Ordering::Relaxed);
                    let (pos, dur, playing, _buffering, completed) = {
                        let deck = if active_deck == 0 { &coord.deck_a } else { &coord.deck_b };
                        (
                            deck.position_ms.load(Ordering::Relaxed),
                            deck.duration_ms.load(Ordering::Relaxed),
                            deck.state.load(Ordering::Relaxed) == STATE_PLAYING,
                            deck.state.load(Ordering::Relaxed) == STATE_BUFFERING,
                            deck.completed_flag.swap(false, Ordering::AcqRel),
                        )
                    };

                    let current_idx = coord.current_index.load(Ordering::Relaxed);
                    let phase = coord.phase.load(Ordering::Relaxed);
                    let is_xfading = coord.crossfade.is_active.load(Ordering::Relaxed);

                    let deck_state = {
                        let deck = if active_deck == 0 { &coord.deck_a } else { &coord.deck_b };
                        deck.state.load(Ordering::Relaxed)
                    };
                    let is_eof = completed || deck_state == STATE_COMPLETED || (dur > 0 && pos >= dur && !is_xfading);

                    // Auto-crossfade or completion trigger
                    let auto_ms = coord.auto_crossfade_duration_ms.load(Ordering::Relaxed);
                    let should_auto_xfade = auto_ms > 0
                        && dur > (auto_ms as i64 * 2)
                        && pos + (auto_ms as i64) >= dur
                        && playing
                        && !is_xfading
                        && phase == ENGINE_PHASE_PLAYING;

                    if should_auto_xfade || is_eof {
                        let q_len = coord.queue.read().unwrap().len();
                        let loop_m = coord.loop_mode.load(Ordering::Relaxed);

                        let next_idx_opt = if loop_m == 1 && is_eof && !should_auto_xfade {
                            Some(current_idx as usize)
                        } else if q_len > 0 {
                            let next = current_idx + 1;
                            if (next as usize) < q_len {
                                Some(next as usize)
                            } else if loop_m == 2 {
                                Some(0)
                            } else {
                                None
                            }
                        } else {
                            None
                        };

                        if let Some(next_idx) = next_idx_opt {
                            let item_opt = coord.queue.read().unwrap().get(next_idx).cloned();
                            if let Some(item) = item_opt {
                                let standby_is_b = active_deck == 0;
                                let standby = if standby_is_b { &mut coord.deck_b } else { &mut coord.deck_a };

                                let open_res = if let Some(ref data) = item.data_bytes {
                                    standby.open_memory(data, false)
                                } else {
                                    standby.open_source(&item.source, item.headers.as_deref())
                                };

                                if open_res == 0 {
                                    standby.play();

                                    let sr = coord.deck_a.sample_rate.load(Ordering::Relaxed).max(1);
                                    let xfade_frames = (auto_ms * sr as u64) / 1000;

                                    coord.crossfade.from_deck.store(active_deck, Ordering::Relaxed);
                                    coord.crossfade.to_deck.store(if standby_is_b { 1 } else { 0 }, Ordering::Relaxed);
                                    coord.crossfade.current_frame.store(0, Ordering::Relaxed);
                                    coord.crossfade.total_frames.store(xfade_frames.max(1), Ordering::Relaxed);
                                    coord.crossfade.curve.store(coord.crossfade_curve.load(Ordering::Relaxed), Ordering::Relaxed);
                                    coord.crossfade.is_active.store(true, Ordering::Release);

                                    coord.phase.store(ENGINE_PHASE_AUTO_CROSSFADING, Ordering::Release);
                                    emit_event(&sink_clone, RustEngineEvent::Phase(ENGINE_PHASE_AUTO_CROSSFADING));
                                }
                            }
                        } else if is_eof {
                            coord.phase.store(ENGINE_PHASE_COMPLETED, Ordering::Release);
                            coord.deck_a.stop();
                            coord.deck_b.stop();
                            emit_event(&sink_clone, RustEngineEvent::IsCompleted(true));
                            emit_event(&sink_clone, RustEngineEvent::IsPlaying(false));
                            emit_event(&sink_clone, RustEngineEvent::Phase(ENGINE_PHASE_COMPLETED));
                        }
                    }

                    // Dispatch telemetry updates
                    if pos != last_pos {
                        last_pos = pos;
                        emit_event(&sink_clone, RustEngineEvent::Position(pos));
                    }
                    if dur != last_dur {
                        last_dur = dur;
                        emit_event(&sink_clone, RustEngineEvent::Duration(dur));
                    }
                    if playing != last_playing {
                        last_playing = playing;
                        emit_event(&sink_clone, RustEngineEvent::IsPlaying(playing));
                        emit_event(&sink_clone, RustEngineEvent::State(if playing { STATE_PLAYING } else { STATE_PAUSED }));
                    }
                    if phase != last_phase {
                        last_phase = phase;
                        emit_event(&sink_clone, RustEngineEvent::Phase(phase));
                    }
                    if current_idx != last_index {
                        last_index = current_idx;
                        emit_event(&sink_clone, RustEngineEvent::CurrentIndex(current_idx as i32));
                    }

                    // 3. Infinite mix lookahead check
                    let is_infinite_mix = coord.infinite_mix_enabled.load(Ordering::Relaxed);
                    if is_infinite_mix && playing {
                        let q = coord.queue.read().unwrap();
                        let q_len = q.len();
                        if current_idx >= 0 && (current_idx as usize) < q_len {
                            let cur_id = q[current_idx as usize].id;
                            let remaining = q_len.saturating_sub((current_idx as usize) + 1);
                            if remaining < 2 && last_notified_track_id != cur_id {
                                last_notified_track_id = cur_id;
                                emit_event(&sink_clone, RustEngineEvent::NeedMoreTracks {
                                    current_track_id: cur_id,
                                    remaining_tracks: remaining,
                                });
                            }
                        }
                    }

                    if coord.visualizer_enabled.load(Ordering::Relaxed) {
                        let vis = coord.visualizer_seqlock.read();
                        emit_event(&sink_clone, RustEngineEvent::Visualizer(RustVisualizerData {
                            bands: vis.bands.to_vec(),
                            rms: vis.rms,
                            peak: vis.peak,
                            left: vis.left,
                            right: vis.right,
                        }));
                    }
                }
            })
            .ok();

        Ok(RustEngine {
            coordinator: coord_arc,
            event_sink,
        })
    }

    pub fn subscribe_events(&self, sink: StreamSink<RustEngineEvent>) -> Result<(), String> {
        *self.event_sink.lock().unwrap() = Some(sink);
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn play(&self) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.start_device();
        let cur_phase = coord.phase.load(Ordering::Relaxed);
        if cur_phase == ENGINE_PHASE_COMPLETED {
            coord.current_index.store(0, Ordering::Release);
            coord.active_deck_mut().seek(0);
            emit_event(&self.event_sink, RustEngineEvent::Position(0));
        }
        coord.active_deck_mut().play();
        coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
        emit_event(&self.event_sink, RustEngineEvent::IsPlaying(true));
        emit_event(&self.event_sink, RustEngineEvent::IsCompleted(false));
        emit_event(&self.event_sink, RustEngineEvent::State(STATE_PLAYING));
        emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_PLAYING));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn pause(&self) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.active_deck_mut().pause();
        coord.phase.store(ENGINE_PHASE_PAUSED, Ordering::Release);
        emit_event(&self.event_sink, RustEngineEvent::IsPlaying(false));
        emit_event(&self.event_sink, RustEngineEvent::State(STATE_PAUSED));
        emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_PAUSED));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stop(&self) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.stop();
        coord.deck_b.stop();
        coord.crossfade.is_active.store(false, Ordering::Release);
        coord.stop_device();
        coord.phase.store(ENGINE_PHASE_IDLE, Ordering::Release);
        emit_event(&self.event_sink, RustEngineEvent::IsPlaying(false));
        emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_IDLE));
        emit_event(&self.event_sink, RustEngineEvent::Position(0));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn seek(&self, position_ms: i64) {
        let mut coord = self.coordinator.lock().unwrap();
        if coord.phase.load(Ordering::Relaxed) == ENGINE_PHASE_AUTO_CROSSFADING {
            coord.crossfade.is_active.store(false, Ordering::Release);
            let active_id = coord.active_deck.load(Ordering::Relaxed);
            if active_id == 0 {
                coord.deck_b.stop();
            } else {
                coord.deck_a.stop();
            }
            coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
            emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_PLAYING));
        } else if coord.phase.load(Ordering::Relaxed) == ENGINE_PHASE_MANUAL_CROSSFADING {
            coord.crossfade.is_active.store(false, Ordering::Release);
            let to_deck = coord.crossfade.to_deck.load(Ordering::Relaxed);
            coord.active_deck.store(to_deck, Ordering::Release);
            if to_deck == 0 {
                coord.deck_b.stop();
            } else {
                coord.deck_a.stop();
            }
            coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
            emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_PLAYING));
        }
        coord.active_deck_mut().seek(position_ms);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_queue(&self, items: Vec<RustEngineItem>, start_index: Option<usize>) {
        let mut coord = self.coordinator.lock().unwrap();
        let core_items: Vec<EngineItemCore> = items.into_iter().map(|it| EngineItemCore {
            id: it.id,
            source: it.source,
            headers: it.headers,
            data_bytes: it.data_bytes,
            replay_gain_db: it.replay_gain_db,
            replay_peak: it.replay_peak,
        }).collect();

        *coord.queue.write().unwrap() = core_items.clone();

        if let Some(idx) = start_index {
            if idx < core_items.len() {
                coord.current_index.store(idx as i64, Ordering::Release);
                let item = &core_items[idx];
                if let Some(ref data) = item.data_bytes {
                    coord.active_deck_mut().open_memory(data, false);
                } else {
                    coord.active_deck_mut().open_source(&item.source, item.headers.as_deref());
                }
                coord.phase.store(ENGINE_PHASE_PAUSED, Ordering::Release);
                let dur = coord.active_deck_ref().duration_ms.load(Ordering::Relaxed);
                if dur > 0 {
                    emit_event(&self.event_sink, RustEngineEvent::Duration(dur));
                }
                emit_event(&self.event_sink, RustEngineEvent::Position(0));
                emit_event(&self.event_sink, RustEngineEvent::CurrentIndex(idx as i32));
                emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_PAUSED));
                emit_event(&self.event_sink, RustEngineEvent::State(STATE_PAUSED));
                emit_event(&self.event_sink, RustEngineEvent::IsPlaying(false));
            }
        }

        let q_items = queue_to_rust_items(&core_items);
        emit_event(&self.event_sink, RustEngineEvent::QueueChanged(q_items));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn append(&self, items: Vec<RustEngineItem>) {
        let mut coord = self.coordinator.lock().unwrap();
        let core_items: Vec<EngineItemCore> = items.into_iter().map(|it| EngineItemCore {
            id: it.id,
            source: it.source,
            headers: it.headers,
            data_bytes: it.data_bytes,
            replay_gain_db: it.replay_gain_db,
            replay_peak: it.replay_peak,
        }).collect();
        coord.append_items(core_items);
        let q_items = {
            let q = coord.queue.read().unwrap();
            queue_to_rust_items(&q)
        };
        emit_event(&self.event_sink, RustEngineEvent::QueueChanged(q_items));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn insert_next(&self, item: RustEngineItem) {
        let mut coord = self.coordinator.lock().unwrap();
        let core_item = EngineItemCore {
            id: item.id,
            source: item.source,
            headers: item.headers,
            data_bytes: item.data_bytes,
            replay_gain_db: item.replay_gain_db,
            replay_peak: item.replay_peak,
        };
        coord.insert_next_item(core_item);
        let q_items = {
            let q = coord.queue.read().unwrap();
            queue_to_rust_items(&q)
        };
        emit_event(&self.event_sink, RustEngineEvent::QueueChanged(q_items));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn remove_at(&self, index: usize) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.remove_item_at(index);
        let q_items = {
            let q = coord.queue.read().unwrap();
            queue_to_rust_items(&q)
        };
        emit_event(&self.event_sink, RustEngineEvent::QueueChanged(q_items));
        let cur = coord.current_index.load(Ordering::Relaxed);
        emit_event(&self.event_sink, RustEngineEvent::CurrentIndex(cur as i32));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn reorder(&self, from: usize, to: usize) {
        let mut coord = self.coordinator.lock().unwrap();
        if coord.reorder_item(from, to) {
            let q_items = {
                let q = coord.queue.read().unwrap();
                queue_to_rust_items(&q)
            };
            emit_event(&self.event_sink, RustEngineEvent::QueueChanged(q_items));
            let cur = coord.current_index.load(Ordering::Relaxed);
            emit_event(&self.event_sink, RustEngineEvent::CurrentIndex(cur as i32));
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn clear_queue(&self, keep_current: bool) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.clear_items(keep_current);
        let q_items = {
            let q = coord.queue.read().unwrap();
            queue_to_rust_items(&q)
        };
        emit_event(&self.event_sink, RustEngineEvent::QueueChanged(q_items));
        let cur = coord.current_index.load(Ordering::Relaxed);
        emit_event(&self.event_sink, RustEngineEvent::CurrentIndex(cur as i32));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_infinite_mix(&self, enabled: bool) {
        let coord = self.coordinator.lock().unwrap();
        coord.infinite_mix_enabled.store(enabled, Ordering::Release);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_infinite_mix(&self) -> bool {
        self.coordinator.lock().unwrap().infinite_mix_enabled.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_queue(&self) -> Vec<RustEngineItem> {
        let coord = self.coordinator.lock().unwrap();
        let q = coord.queue.read().unwrap();
        queue_to_rust_items(&q)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_queue_len(&self) -> usize {
        self.coordinator.lock().unwrap().queue.read().unwrap().len()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_current_track_id(&self) -> Option<i64> {
        let coord = self.coordinator.lock().unwrap();
        let cur = coord.current_index.load(Ordering::Relaxed);
        if cur >= 0 {
            let q = coord.queue.read().unwrap();
            q.get(cur as usize).map(|it| it.id)
        } else {
            None
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn next(&self, crossfade_duration_ms: Option<u64>, curve: Option<i32>) {
        let mut coord = self.coordinator.lock().unwrap();
        let q_len = coord.queue.read().unwrap().len();
        if q_len == 0 { return; }

        let cur = coord.current_index.load(Ordering::Relaxed);
        let next_idx = if (cur + 1) as usize >= q_len {
            if coord.loop_mode.load(Ordering::Relaxed) == 2 { 0 } else { return; }
        } else {
            (cur + 1) as usize
        };

        if coord.phase.load(Ordering::Relaxed) == ENGINE_PHASE_AUTO_CROSSFADING {
            let dur_ms = crossfade_duration_ms.unwrap_or(coord.manual_crossfade_duration_ms.load(Ordering::Relaxed));
            let sr = coord.deck_a.sample_rate.load(Ordering::Relaxed).max(1);
            let total_frames = (dur_ms * sr as u64) / 1000;
            coord.crossfade.current_frame.store(0, Ordering::Relaxed);
            coord.crossfade.total_frames.store(total_frames.max(1), Ordering::Relaxed);
            coord.current_index.store(next_idx as i64, Ordering::Release);
            coord.phase.store(ENGINE_PHASE_MANUAL_CROSSFADING, Ordering::Release);
            emit_event(&self.event_sink, RustEngineEvent::CurrentIndex(next_idx as i32));
            emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_MANUAL_CROSSFADING));
            return;
        }

        self.perform_skip(&mut coord, next_idx, crossfade_duration_ms, curve);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn previous(&self, crossfade_duration_ms: Option<u64>, curve: Option<i32>) {
        let mut coord = self.coordinator.lock().unwrap();
        let q_len = coord.queue.read().unwrap().len();
        if q_len == 0 { return; }

        let cur = coord.current_index.load(Ordering::Relaxed);
        let pos = coord.active_deck_ref().position_ms.load(Ordering::Relaxed);
        let dur = coord.active_deck_ref().duration_ms.load(Ordering::Relaxed);

        if pos > 3000 && dur > 0 {
            if coord.phase.load(Ordering::Relaxed) == ENGINE_PHASE_AUTO_CROSSFADING {
                coord.crossfade.is_active.store(false, Ordering::Release);
                let active_id = coord.active_deck.load(Ordering::Relaxed);
                if active_id == 0 {
                    coord.deck_b.stop();
                } else {
                    coord.deck_a.stop();
                }
                coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
                emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_PLAYING));
            }
            coord.active_deck_mut().seek(0);
            emit_event(&self.event_sink, RustEngineEvent::Position(0));
            return;
        }

        let prev_idx = if cur <= 0 {
            if coord.loop_mode.load(Ordering::Relaxed) == 2 { q_len - 1 } else { 0 }
        } else {
            (cur - 1) as usize
        };

        self.perform_skip(&mut coord, prev_idx, crossfade_duration_ms, curve);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn skip_to_index(&self, index: usize, crossfade_duration_ms: Option<u64>, curve: Option<i32>) {
        let mut coord = self.coordinator.lock().unwrap();
        let q_len = coord.queue.read().unwrap().len();
        if index >= q_len { return; }
        self.perform_skip(&mut coord, index, crossfade_duration_ms, curve);
    }

    fn perform_skip(
        &self,
        coord: &mut EngineCoordinator,
        target_idx: usize,
        crossfade_duration_ms: Option<u64>,
        curve: Option<i32>,
    ) {
        let item_opt = coord.queue.read().unwrap().get(target_idx).cloned();
        let item = match item_opt {
            Some(it) => it,
            None => return,
        };

        let active_id = coord.active_deck.load(Ordering::Relaxed);
        let cur_phase = coord.phase.load(Ordering::Relaxed);
        let was_playing = cur_phase == ENGINE_PHASE_PLAYING
            || cur_phase == ENGINE_PHASE_AUTO_CROSSFADING
            || cur_phase == ENGINE_PHASE_MANUAL_CROSSFADING;

        if !was_playing {
            let active = if active_id == 0 { &mut coord.deck_a } else { &mut coord.deck_b };
            if let Some(ref data) = item.data_bytes {
                active.open_memory(data, false);
            } else {
                active.open_source(&item.source, item.headers.as_deref());
            }
            coord.current_index.store(target_idx as i64, Ordering::Release);
            coord.phase.store(ENGINE_PHASE_PAUSED, Ordering::Release);
            emit_event(&self.event_sink, RustEngineEvent::CurrentIndex(target_idx as i32));
            emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_PAUSED));
            return;
        }

        let standby_id = if active_id == 0 { 1 } else { 0 };

        let standby = if standby_id == 1 { &mut coord.deck_b } else { &mut coord.deck_a };
        if let Some(ref data) = item.data_bytes {
            standby.open_memory(data, false);
        } else {
            standby.open_source(&item.source, item.headers.as_deref());
        }
        standby.play();

        let dur_ms = crossfade_duration_ms.unwrap_or(coord.manual_crossfade_duration_ms.load(Ordering::Relaxed));
        let sr = coord.deck_a.sample_rate.load(Ordering::Relaxed).max(1);
        let total_frames = (dur_ms * sr as u64) / 1000;

        coord.crossfade.from_deck.store(active_id, Ordering::Relaxed);
        coord.crossfade.to_deck.store(standby_id, Ordering::Relaxed);
        coord.crossfade.current_frame.store(0, Ordering::Relaxed);
        coord.crossfade.total_frames.store(total_frames.max(1), Ordering::Relaxed);
        coord.crossfade.curve.store(curve.unwrap_or(coord.crossfade_curve.load(Ordering::Relaxed)), Ordering::Relaxed);
        coord.crossfade.is_active.store(true, Ordering::Release);

        coord.current_index.store(target_idx as i64, Ordering::Release);
        coord.phase.store(ENGINE_PHASE_MANUAL_CROSSFADING, Ordering::Release);

        emit_event(&self.event_sink, RustEngineEvent::CurrentIndex(target_idx as i32));
        emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_MANUAL_CROSSFADING));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_volume(&self, volume: f32) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_volume(volume);
        coord.deck_b.set_volume(volume);
        emit_event(&self.event_sink, RustEngineEvent::Volume(volume));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_rate(&self, rate: f32) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_rate(rate);
        coord.deck_b.set_rate(rate);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_pitch(&self, pitch: f32) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_pitch(pitch);
        coord.deck_b.set_pitch(pitch);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_balance(&self, balance: f32) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_balance(balance);
        coord.deck_b.set_balance(balance);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_mono(&self, enabled: bool) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_mono(if enabled { 1 } else { 0 });
        coord.deck_b.set_mono(if enabled { 1 } else { 0 });
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_crossfeed(&self, mode: i32) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_crossfeed(mode);
        coord.deck_b.set_crossfeed(mode);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_equalizer(&self, params: RustEqualizerParams) {
        let mut coord = self.coordinator.lock().unwrap();
        let eq = EqualizerParams {
            hz31: params.gains.first().copied().unwrap_or(0.0),
            hz63: params.gains.get(1).copied().unwrap_or(0.0),
            hz125: params.gains.get(2).copied().unwrap_or(0.0),
            hz250: params.gains.get(3).copied().unwrap_or(0.0),
            hz500: params.gains.get(4).copied().unwrap_or(0.0),
            hz1k: params.gains.get(5).copied().unwrap_or(0.0),
            hz2k: params.gains.get(6).copied().unwrap_or(0.0),
            hz4k: params.gains.get(7).copied().unwrap_or(0.0),
            hz8k: params.gains.get(8).copied().unwrap_or(0.0),
            hz16k: params.gains.get(9).copied().unwrap_or(0.0),
        };
        coord.deck_a.set_equalizer(&eq);
        coord.deck_b.set_equalizer(&eq);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_equalizer_band(&self, band: u32, gain_db: f32) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_equalizer_band(band, gain_db);
        coord.deck_b.set_equalizer_band(band, gain_db);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_preamp(&self, preamp_db: f32) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_preamp(preamp_db);
        coord.deck_b.set_preamp(preamp_db);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_replay_gain(&self, gain_db: f32, peak: f32, prevent_clipping: bool) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_replay_gain(gain_db, peak, if prevent_clipping { 1 } else { 0 });
        coord.deck_b.set_replay_gain(gain_db, peak, if prevent_clipping { 1 } else { 0 });
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_reverb(&self, params: RustReverbParams) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_reverb(
            if params.enabled { 1 } else { 0 },
            params.room_size,
            params.damping,
            params.width,
            params.wet,
            params.dry,
        );
        coord.deck_b.set_reverb(
            if params.enabled { 1 } else { 0 },
            params.room_size,
            params.damping,
            params.width,
            params.wet,
            params.dry,
        );
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_limiter(&self, enabled: bool) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_limiter(if enabled { 1 } else { 0 });
        coord.deck_b.set_limiter(if enabled { 1 } else { 0 });
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatializer(&self, enabled: bool, width: f32) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.set_spatializer(if enabled { 1 } else { 0 }, width);
        coord.deck_b.set_spatializer(if enabled { 1 } else { 0 }, width);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatial_enabled(&self, enabled: bool) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.set_spatial_enabled(enabled);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatial_listener(&self, listener: RustSpatialListener) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.set_spatial_listener(listener.into());
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatial_emitter(&self, emitter: RustSpatialEmitter) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.set_spatial_emitter(emitter.into());
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatial_doppler_factor(&self, factor: f32) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.set_spatial_doppler_factor(factor);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatial_speed_of_sound(&self, speed: f32) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.set_spatial_speed_of_sound(speed);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_visualizer_enabled(&self, enabled: bool) {
        let coord = self.coordinator.lock().unwrap();
        coord.visualizer_enabled.store(enabled, Ordering::Relaxed);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_loop_mode(&self, mode: i32) {
        let coord = self.coordinator.lock().unwrap();
        coord.loop_mode.store(mode, Ordering::Release);
        emit_event(&self.event_sink, RustEngineEvent::LoopMode(mode));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_shuffle(&self, enabled: bool) {
        let coord = self.coordinator.lock().unwrap();
        coord.shuffle_enabled.store(enabled, Ordering::Release);
        emit_event(&self.event_sink, RustEngineEvent::Shuffle(enabled));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_crossfade_config(&self, config: RustCrossfadeConfig) {
        let coord = self.coordinator.lock().unwrap();
        coord.auto_crossfade_duration_ms.store(config.duration_ms, Ordering::Release);
        coord.manual_crossfade_duration_ms.store(config.manual_duration_ms, Ordering::Release);
        coord.crossfade_curve.store(config.curve, Ordering::Release);
        emit_event(&self.event_sink, RustEngineEvent::CrossfadeConfig(config));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_device(&self, device_id: String) {
        let mut coord = self.coordinator.lock().unwrap();
        let c_str = CString::new(device_id).unwrap_or_default();
        coord.set_device(c_str.as_ptr());
    }

    // Synchronous state snapshot getters
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_phase(&self) -> i32 {
        self.coordinator.lock().unwrap().phase.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_current_index(&self) -> Option<usize> {
        let idx = self.coordinator.lock().unwrap().current_index.load(Ordering::Relaxed);
        if idx >= 0 { Some(idx as usize) } else { None }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_position_ms(&self) -> i64 {
        self.coordinator.lock().unwrap().active_deck_ref().position_ms.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_duration_ms(&self) -> i64 {
        self.coordinator.lock().unwrap().active_deck_ref().duration_ms.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_playing(&self) -> bool {
        self.coordinator.lock().unwrap().active_deck_ref().state.load(Ordering::Relaxed) == STATE_PLAYING
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_buffering(&self) -> bool {
        self.coordinator.lock().unwrap().active_deck_ref().state.load(Ordering::Relaxed) == STATE_BUFFERING
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_completed(&self) -> bool {
        self.coordinator.lock().unwrap().phase.load(Ordering::Relaxed) == ENGINE_PHASE_COMPLETED
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_volume(&self) -> f32 {
        f32::from_bits(self.coordinator.lock().unwrap().deck_a.volume.load(Ordering::Relaxed))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_visualizer_data(&self) -> RustVisualizerData {
        let vis = self.coordinator.lock().unwrap().visualizer_seqlock.read();
        RustVisualizerData {
            bands: vis.bands.to_vec(),
            rms: vis.rms,
            peak: vis.peak,
            left: vis.left,
            right: vis.right,
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn start_recording(&self, path: String, format: RustWavFormat) -> Result<(), String> {
        self.coordinator.lock().unwrap().start_recording(&path, format.into())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stop_recording(&self) -> Result<u64, String> {
        self.coordinator.lock().unwrap().stop_recording()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_recording(&self) -> bool {
        self.coordinator.lock().unwrap().is_recording()
    }

    pub fn offline_bounce(
        &self,
        path: String,
        format: RustWavFormat,
        duration_ms: i64,
    ) -> Result<u64, String> {
        self.coordinator.lock().unwrap().offline_bounce(&path, format.into(), duration_ms)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn enable_microphone(
        &self,
        capture_device_id: Option<String>,
        auto_ducking: bool,
        ducking_db: f32,
        threshold_db: f32,
    ) -> Result<(), String> {
        self.coordinator.lock().unwrap().enable_microphone(
            capture_device_id,
            auto_ducking,
            ducking_db,
            threshold_db,
        )
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn disable_microphone(&self) {
        self.coordinator.lock().unwrap().disable_microphone();
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_mic_volume(&self, volume: f32) {
        self.coordinator.lock().unwrap().set_mic_volume(volume);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn configure_cue_output(
        &self,
        cue_device_id: Option<String>,
        volume: f32,
        mode: i32,
    ) -> Result<(), String> {
        self.coordinator.lock().unwrap().configure_cue_output(cue_device_id, volume, mode)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_cue_volume(&self, volume: f32) {
        self.coordinator.lock().unwrap().set_cue_volume(volume);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_cue_mode(&self, mode: i32) {
        self.coordinator.lock().unwrap().set_cue_mode(mode);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn disable_cue_output(&self) {
        self.coordinator.lock().unwrap().disable_cue_output();
    }
}
