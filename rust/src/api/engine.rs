//! High-level Rust Engine API exposed to Flutter/Dart via flutter_rust_bridge.

use std::ffi::CString;
use std::sync::atomic::{AtomicI32, AtomicI64, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
#[cfg(not(target_arch = "wasm32"))]
use std::thread;
#[cfg(not(target_arch = "wasm32"))]
use std::time::Duration;

use crate::core::engine::{
    EngineCoordinator, EngineItemCore, ENGINE_PHASE_AUTO_CROSSFADING, ENGINE_PHASE_COMPLETED,
    ENGINE_PHASE_IDLE, ENGINE_PHASE_MANUAL_CROSSFADING, ENGINE_PHASE_PAUSED, ENGINE_PHASE_PLAYING,
};
use crate::core::player::{
    PlayerCoordinator, STATE_BUFFERING, STATE_COMPLETED, STATE_PAUSED, STATE_PLAYING,
};
use crate::decoder::FormatSniffer;
use crate::dsp::equalizer::EqualizerParams;
use crate::frb_generated::StreamSink;

use super::types::*;

#[inline]
fn emit_event(sink_lock: &Arc<Mutex<Option<StreamSink<RustEngineEvent>>>>, event: RustEngineEvent) {
    if let Ok(guard) = sink_lock.lock() {
        if let Some(ref sink) = *guard {
            let _ = sink.add(event);
        }
    }
}

fn queue_to_rust_items(q: &[EngineItemCore]) -> Vec<RustEngineItem> {
    q.iter().map(RustEngineItem::from).collect()
}

fn open_item_on_deck(deck: &mut PlayerCoordinator, item: &EngineItemCore) -> i32 {
    if let Some(ref data) = item.data_bytes {
        let ext_hint = FormatSniffer::extract_extension_hint(&item.source);
        deck.open_memory_with_hint(data, ext_hint)
    } else {
        deck.open_source(&item.source, item.headers.as_deref())
    }
}

#[derive(Clone, Copy)]
struct ActiveDeckSnapshot {
    active_deck: i32,
    pos: i64,
    dur: i64,
    playing: bool,
    completed: bool,
    deck_state: i32,
    current_idx: i64,
    phase: i32,
    is_xfading: bool,
}

/// Flow-control worker managing background dual-deck crossfade completion,
/// auto-crossfade triggers, queue progression, telemetry diffing, and infinite mix lookahead.
struct EngineMonitorWorker {
    coordinator: Arc<Mutex<Box<EngineCoordinator>>>,
    event_sink: Arc<Mutex<Option<StreamSink<RustEngineEvent>>>>,
    last_pos: i64,
    last_dur: i64,
    last_playing: bool,
    last_phase: i32,
    last_index: i64,
    last_notified_track_id: i64,
    last_meta_version: u32,
    last_meta_deck: i32,
}

impl EngineMonitorWorker {
    fn new(
        coordinator: Arc<Mutex<Box<EngineCoordinator>>>,
        event_sink: Arc<Mutex<Option<StreamSink<RustEngineEvent>>>>,
    ) -> Self {
        Self {
            coordinator,
            event_sink,
            last_pos: -1,
            last_dur: -1,
            last_playing: false,
            last_phase: -1,
            last_index: -2,
            last_notified_track_id: -1,
            last_meta_version: 0,
            last_meta_deck: -1,
        }
    }

    fn check_crossfade_completion(&mut self, coord: &mut EngineCoordinator) {
        if coord.phase.load(Ordering::Relaxed) == ENGINE_PHASE_PAUSED {
            return;
        }
        let mut xfade_done = coord.crossfade_completed_flag.swap(false, Ordering::AcqRel);
        if !xfade_done && coord.crossfade.is_active.load(Ordering::Relaxed) {
            let cur_f = coord.crossfade.current_frame.load(Ordering::Relaxed);
            let tot_f = coord.crossfade.total_frames.load(Ordering::Relaxed);
            if cur_f >= tot_f {
                coord.crossfade.abort();
                let to_deck = coord.crossfade.to_deck.load(Ordering::Relaxed);
                coord.active_deck.store(to_deck, Ordering::Release);
                xfade_done = true;
            }
        }

        if xfade_done {
            let to_deck = coord.crossfade.to_deck.load(Ordering::Relaxed);
            coord.active_deck.store(to_deck, Ordering::Release);
            coord.standby_deck_mut().stop();

            let auto_target = coord.auto_crossfade_target_index.swap(-1, Ordering::AcqRel);
            if auto_target >= 0 {
                coord.current_index.store(auto_target, Ordering::Release);
                self.last_index = auto_target;
                emit_event(
                    &self.event_sink,
                    RustEngineEvent::CurrentIndex(auto_target as i32),
                );
                crate::map_log!(3, "Auto-crossfade completed -> track index {}", auto_target);
            }

            coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
            emit_event(
                &self.event_sink,
                RustEngineEvent::Phase(ENGINE_PHASE_PLAYING),
            );
        }
    }

    fn capture_active_deck_snapshot(&self, coord: &EngineCoordinator) -> ActiveDeckSnapshot {
        let active_deck = coord.active_deck.load(Ordering::Relaxed);
        let deck = coord.active_deck_ref();
        let deck_state = deck.state.load(Ordering::Relaxed);
        ActiveDeckSnapshot {
            active_deck,
            pos: deck.position_ms.load(Ordering::Relaxed),
            dur: deck.duration_ms.load(Ordering::Relaxed),
            playing: deck_state == STATE_PLAYING,
            completed: deck.completed_flag.swap(false, Ordering::AcqRel),
            deck_state,
            current_idx: coord.current_index.load(Ordering::Relaxed),
            phase: coord.phase.load(Ordering::Relaxed),
            is_xfading: coord.crossfade.is_active.load(Ordering::Relaxed),
        }
    }

    fn resolve_next_queue_index(
        coord: &EngineCoordinator,
        current_idx: i64,
        is_eof: bool,
        should_auto_xfade: bool,
    ) -> Option<usize> {
        let q_len = coord.queue.read().unwrap().len();
        let loop_m = coord.loop_mode.load(Ordering::Relaxed);

        if loop_m == 1 && is_eof && !should_auto_xfade {
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
        }
    }

    fn evaluate_auto_transition(
        &mut self,
        coord: &mut EngineCoordinator,
        snap: &mut ActiveDeckSnapshot,
    ) {
        let can_trigger_transition =
            !snap.is_xfading && snap.phase == ENGINE_PHASE_PLAYING && snap.playing;
        if !can_trigger_transition {
            return;
        }

        let auto_ms = coord.auto_crossfade_duration_ms.load(Ordering::Relaxed);
        let should_auto_xfade =
            auto_ms > 0 && snap.dur > (auto_ms as i64) && snap.pos + (auto_ms as i64) >= snap.dur;

        let is_eof = !should_auto_xfade
            && (snap.completed
                || snap.deck_state == STATE_COMPLETED
                || (snap.dur > 0 && snap.pos >= snap.dur));

        if !should_auto_xfade && !is_eof {
            return;
        }

        if let Some(next_idx) =
            Self::resolve_next_queue_index(coord, snap.current_idx, is_eof, should_auto_xfade)
        {
            let item_opt = coord.queue.read().unwrap().get(next_idx).cloned();
            if let Some(item) = item_opt {
                let to_deck = if snap.active_deck == 0 { 1 } else { 0 };
                let open_res = open_item_on_deck(coord.standby_deck_mut(), &item);

                if open_res == 0 {
                    coord.standby_deck_mut().play();

                    if !should_auto_xfade {
                        coord.crossfade.abort();
                        coord.active_deck.store(to_deck, Ordering::Release);
                        coord.standby_deck_mut().stop();
                        coord
                            .current_index
                            .store(next_idx as i64, Ordering::Release);
                        snap.current_idx = next_idx as i64;
                        self.last_index = next_idx as i64;
                        emit_event(
                            &self.event_sink,
                            RustEngineEvent::CurrentIndex(next_idx as i32),
                        );
                        coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
                        snap.phase = ENGINE_PHASE_PLAYING;
                        emit_event(
                            &self.event_sink,
                            RustEngineEvent::Phase(ENGINE_PHASE_PLAYING),
                        );
                        return;
                    }

                    let sr = coord.deck_a.sample_rate.load(Ordering::Relaxed).max(1);
                    let effective_ms = if snap.dur > snap.pos {
                        ((snap.dur - snap.pos) as u64).clamp(50, auto_ms)
                    } else {
                        auto_ms
                    };
                    let xfade_frames = (effective_ms * sr as u64) / 1000;
                    let curve = coord.crossfade_curve.load(Ordering::Relaxed);

                    coord
                        .crossfade
                        .begin(snap.active_deck, to_deck, xfade_frames, curve);
                    coord
                        .auto_crossfade_target_index
                        .store(next_idx as i64, Ordering::Release);

                    coord
                        .phase
                        .store(ENGINE_PHASE_AUTO_CROSSFADING, Ordering::Release);
                    snap.phase = ENGINE_PHASE_AUTO_CROSSFADING;
                    emit_event(
                        &self.event_sink,
                        RustEngineEvent::Phase(ENGINE_PHASE_AUTO_CROSSFADING),
                    );
                    crate::map_log!(
                        3,
                        "Auto-crossfade initiated from deck {} to deck {} (duration={}ms, target_index={})",
                        snap.active_deck,
                        to_deck,
                        effective_ms,
                        next_idx
                    );
                }
            }
        } else if is_eof {
            coord.phase.store(ENGINE_PHASE_COMPLETED, Ordering::Release);
            snap.phase = ENGINE_PHASE_COMPLETED;
            coord.deck_a.stop();
            coord.deck_b.stop();
            emit_event(&self.event_sink, RustEngineEvent::IsCompleted(true));
            emit_event(&self.event_sink, RustEngineEvent::IsPlaying(false));
            emit_event(
                &self.event_sink,
                RustEngineEvent::Phase(ENGINE_PHASE_COMPLETED),
            );
            crate::map_log!(3, "End of queue reached -> ENGINE_PHASE_COMPLETED");
        }
    }

    fn dispatch_telemetry_diff(&mut self, snap: &ActiveDeckSnapshot) {
        if snap.pos != self.last_pos {
            self.last_pos = snap.pos;
            emit_event(&self.event_sink, RustEngineEvent::Position(snap.pos));
        }
        if snap.dur != self.last_dur {
            self.last_dur = snap.dur;
            emit_event(&self.event_sink, RustEngineEvent::Duration(snap.dur));
        }
        if snap.playing != self.last_playing {
            self.last_playing = snap.playing;
            emit_event(&self.event_sink, RustEngineEvent::IsPlaying(snap.playing));
            emit_event(
                &self.event_sink,
                RustEngineEvent::State(if snap.playing {
                    STATE_PLAYING
                } else {
                    STATE_PAUSED
                }),
            );
        }
        if snap.phase != self.last_phase {
            self.last_phase = snap.phase;
            emit_event(&self.event_sink, RustEngineEvent::Phase(snap.phase));
        }
        if snap.current_idx != self.last_index {
            self.last_index = snap.current_idx;
            emit_event(
                &self.event_sink,
                RustEngineEvent::CurrentIndex(snap.current_idx as i32),
            );
        }
    }

    fn check_infinite_mix_lookahead(
        &mut self,
        coord: &EngineCoordinator,
        snap: &ActiveDeckSnapshot,
    ) {
        if !coord.infinite_mix_enabled.load(Ordering::Relaxed) || !snap.playing {
            return;
        }
        let q = coord.queue.read().unwrap();
        let q_len = q.len();
        if snap.current_idx >= 0 && (snap.current_idx as usize) < q_len {
            let cur_id = q[snap.current_idx as usize].id;
            let remaining = q_len.saturating_sub((snap.current_idx as usize) + 1);
            if remaining < 2 && self.last_notified_track_id != cur_id {
                self.last_notified_track_id = cur_id;
                emit_event(
                    &self.event_sink,
                    RustEngineEvent::NeedMoreTracks {
                        current_track_id: cur_id,
                        remaining_tracks: remaining,
                    },
                );
            }
        }
    }

    fn dispatch_visualizer(&self, coord: &EngineCoordinator) {
        if coord.visualizer_enabled.load(Ordering::Relaxed) {
            let vis = coord.visualizer_seqlock.read();
            emit_event(
                &self.event_sink,
                RustEngineEvent::Visualizer(RustVisualizerData::from(vis)),
            );
        }
    }

    fn dispatch_meta_bytes(&mut self, coord: &EngineCoordinator, snap: &ActiveDeckSnapshot) {
        let deck = coord.active_deck_ref();
        let ver = deck.get_meta_bytes_version();
        if ver != self.last_meta_version || snap.active_deck != self.last_meta_deck {
            self.last_meta_version = ver;
            self.last_meta_deck = snap.active_deck;
            let sz = deck.get_meta_bytes_size();
            if sz > 0 && snap.current_idx >= 0 {
                let mut buf = vec![0u8; sz];
                let copied = deck.copy_meta_bytes(&mut buf);
                buf.truncate(copied);
                if !buf.is_empty() {
                    let q = coord.queue.read().unwrap();
                    let mut q_items = queue_to_rust_items(&q);
                    if let Some(item) = q_items.get_mut(snap.current_idx as usize) {
                        item.data_bytes = Some(buf);
                        emit_event(&self.event_sink, RustEngineEvent::QueueChanged(q_items));
                    }
                }
            }
        }
    }

    fn tick(&mut self) -> bool {
        let coord_arc = self.coordinator.clone();
        let Ok(mut coord) = coord_arc.lock() else {
            return false;
        };
        if !coord.thread_running.load(Ordering::Relaxed) {
            return false;
        }

        self.check_crossfade_completion(&mut coord);
        let mut snap = self.capture_active_deck_snapshot(&coord);
        self.evaluate_auto_transition(&mut coord, &mut snap);
        self.dispatch_telemetry_diff(&snap);
        self.dispatch_meta_bytes(&coord, &snap);
        self.check_infinite_mix_lookahead(&coord, &snap);
        self.dispatch_visualizer(&coord);
        true
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn run(&mut self) {
        loop {
            thread::sleep(Duration::from_millis(30));
            if !self.tick() {
                break;
            }
        }
    }
}

pub struct RustEngine {
    coordinator: Arc<Mutex<Box<EngineCoordinator>>>,
    event_sink: Arc<Mutex<Option<StreamSink<RustEngineEvent>>>>,
    phase: Arc<AtomicI32>,
    active_deck: Arc<AtomicI32>,
    current_index: Arc<AtomicI64>,
    deck_a_position: Arc<AtomicI64>,
    deck_b_position: Arc<AtomicI64>,
    deck_a_duration: Arc<AtomicI64>,
    deck_b_duration: Arc<AtomicI64>,
    deck_a_state: Arc<AtomicI32>,
    deck_b_state: Arc<AtomicI32>,
    volume: Arc<AtomicU32>,
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
        let dev_id_ptr = dev_id_c
            .as_ref()
            .map(|c| c.as_ptr())
            .unwrap_or(std::ptr::null());

        let coordinator = EngineCoordinator::new(sample_rate, channels, period_size, dev_id_ptr)
            .map_err(|e| format!("Failed to create engine coordinator: error {}", e))?;

        let phase = coordinator.phase.clone();
        let active_deck = coordinator.active_deck.clone();
        let current_index = coordinator.current_index.clone();
        let deck_a_position = coordinator.deck_a.position_ms.clone();
        let deck_b_position = coordinator.deck_b.position_ms.clone();
        let deck_a_duration = coordinator.deck_a.duration_ms.clone();
        let deck_b_duration = coordinator.deck_b.duration_ms.clone();
        let deck_a_state = coordinator.deck_a.state.clone();
        let deck_b_state = coordinator.deck_b.state.clone();
        let volume = coordinator.deck_a.volume.clone();

        let coord_arc = Arc::new(Mutex::new(coordinator));
        let event_sink: Arc<Mutex<Option<StreamSink<RustEngineEvent>>>> =
            Arc::new(Mutex::new(None));

        let mut monitor = EngineMonitorWorker::new(coord_arc.clone(), event_sink.clone());
        #[cfg(not(target_arch = "wasm32"))]
        {
            let _ = thread::Builder::new()
                .name("miniaudio-engine-monitor".to_string())
                .spawn(move || monitor.run());
        }
        #[cfg(target_arch = "wasm32")]
        {
            crate::bridge::ffi::wasm_register_monitor_task(Box::new(move || monitor.tick()));
        }

        Ok(RustEngine {
            coordinator: coord_arc,
            event_sink,
            phase,
            active_deck,
            current_index,
            deck_a_position,
            deck_b_position,
            deck_a_duration,
            deck_b_duration,
            deck_a_state,
            deck_b_state,
            volume,
        })
    }

    fn abort_active_crossfade(&self, coord: &mut EngineCoordinator) {
        let phase = coord.phase.load(Ordering::Relaxed);
        if phase == ENGINE_PHASE_AUTO_CROSSFADING {
            coord.crossfade.abort();
            coord.standby_deck_mut().stop();
            coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
            emit_event(
                &self.event_sink,
                RustEngineEvent::Phase(ENGINE_PHASE_PLAYING),
            );
        } else if phase == ENGINE_PHASE_MANUAL_CROSSFADING {
            coord.crossfade.abort();
            let to_deck = coord.crossfade.to_deck.load(Ordering::Relaxed);
            coord.active_deck.store(to_deck, Ordering::Release);
            coord.standby_deck_mut().stop();
            coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
            emit_event(
                &self.event_sink,
                RustEngineEvent::Phase(ENGINE_PHASE_PLAYING),
            );
        }
    }

    fn emit_queue_and_index(&self, coord: &EngineCoordinator, emit_index: bool) {
        let q_items = {
            let q = coord.queue.read().unwrap();
            queue_to_rust_items(&q)
        };
        emit_event(&self.event_sink, RustEngineEvent::QueueChanged(q_items));
        if emit_index {
            let cur = coord.current_index.load(Ordering::Relaxed);
            emit_event(&self.event_sink, RustEngineEvent::CurrentIndex(cur as i32));
        }
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
            let prev_idx = coord.current_index.swap(0, Ordering::AcqRel);
            if prev_idx != 0 {
                let item_opt = coord.queue.read().unwrap().first().cloned();
                if let Some(item) = item_opt {
                    open_item_on_deck(coord.active_deck_mut(), &item);
                }
            } else {
                coord.active_deck_mut().seek(0);
            }
            emit_event(&self.event_sink, RustEngineEvent::CurrentIndex(0));
            emit_event(&self.event_sink, RustEngineEvent::Position(0));
        }
        if coord.crossfade.is_active.load(Ordering::Relaxed) {
            coord.deck_a.play();
            coord.deck_b.play();
            let resumed_phase = if coord.auto_crossfade_target_index.load(Ordering::Relaxed) >= 0 {
                ENGINE_PHASE_AUTO_CROSSFADING
            } else {
                ENGINE_PHASE_MANUAL_CROSSFADING
            };
            coord.phase.store(resumed_phase, Ordering::Release);
            emit_event(&self.event_sink, RustEngineEvent::IsPlaying(true));
            emit_event(&self.event_sink, RustEngineEvent::IsCompleted(false));
            emit_event(&self.event_sink, RustEngineEvent::State(STATE_PLAYING));
            emit_event(&self.event_sink, RustEngineEvent::Phase(resumed_phase));
            return;
        }
        coord.active_deck_mut().play();
        coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
        emit_event(&self.event_sink, RustEngineEvent::IsPlaying(true));
        emit_event(&self.event_sink, RustEngineEvent::IsCompleted(false));
        emit_event(&self.event_sink, RustEngineEvent::State(STATE_PLAYING));
        emit_event(
            &self.event_sink,
            RustEngineEvent::Phase(ENGINE_PHASE_PLAYING),
        );
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn pause(&self) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.active_deck_mut().pause();
        if coord.crossfade.is_active.load(Ordering::Relaxed) {
            coord.standby_deck_mut().pause();
        }
        coord.phase.store(ENGINE_PHASE_PAUSED, Ordering::Release);
        emit_event(&self.event_sink, RustEngineEvent::IsPlaying(false));
        emit_event(&self.event_sink, RustEngineEvent::State(STATE_PAUSED));
        emit_event(
            &self.event_sink,
            RustEngineEvent::Phase(ENGINE_PHASE_PAUSED),
        );
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stop(&self) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.deck_a.stop();
        coord.deck_b.stop();
        coord.crossfade.abort();
        coord.stop_device();
        coord.phase.store(ENGINE_PHASE_IDLE, Ordering::Release);
        emit_event(&self.event_sink, RustEngineEvent::IsPlaying(false));
        emit_event(&self.event_sink, RustEngineEvent::Phase(ENGINE_PHASE_IDLE));
        emit_event(&self.event_sink, RustEngineEvent::Position(0));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn seek(&self, position_ms: i64) {
        let mut coord = self.coordinator.lock().unwrap();
        let phase = coord.phase.load(Ordering::Relaxed);
        let auto_ms = coord.auto_crossfade_duration_ms.load(Ordering::Relaxed) as i64;
        let dur = coord.active_deck_ref().duration_ms.load(Ordering::Relaxed);
        let stay_in_auto_xfade = phase == ENGINE_PHASE_AUTO_CROSSFADING
            && auto_ms > 0
            && dur > auto_ms
            && position_ms + auto_ms >= dur
            && position_ms < dur;

        if stay_in_auto_xfade {
            let sr = coord.deck_a.sample_rate.load(Ordering::Relaxed).max(1) as u64;
            let remaining_ms = (dur - position_ms).max(50) as u64;
            let total_frames = ((auto_ms as u64) * sr) / 1000;
            let elapsed_ms = (auto_ms as u64).saturating_sub(remaining_ms);
            let cur_frame = (elapsed_ms * sr) / 1000;
            coord
                .crossfade
                .total_frames
                .store(total_frames.max(1), Ordering::Relaxed);
            coord.crossfade.current_frame.store(
                cur_frame.min(total_frames.saturating_sub(1)),
                Ordering::Relaxed,
            );
            coord.active_deck_mut().seek(position_ms);
            emit_event(&self.event_sink, RustEngineEvent::Position(position_ms));
            crate::map_log!(
                4,
                "seek within auto-crossfade -> position_ms={}",
                position_ms
            );
            return;
        }

        coord
            .auto_crossfade_target_index
            .store(-1, Ordering::Release);
        coord
            .crossfade_completed_flag
            .store(false, Ordering::Release);
        self.abort_active_crossfade(&mut coord);
        coord.active_deck_mut().seek(position_ms);
        emit_event(&self.event_sink, RustEngineEvent::Position(position_ms));
        crate::map_log!(4, "seek -> position_ms={}", position_ms);
    }

    pub fn set_queue(&self, items: Vec<RustEngineItem>, start_index: Option<usize>) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.crossfade.abort();
        coord
            .auto_crossfade_target_index
            .store(-1, Ordering::Release);
        coord
            .crossfade_completed_flag
            .store(false, Ordering::Release);
        coord.deck_a.stop();
        coord.deck_b.stop();

        let core_items: Vec<EngineItemCore> = items.into_iter().map(EngineItemCore::from).collect();

        *coord.queue.write().unwrap() = core_items.clone();
        let mut q_items = queue_to_rust_items(&core_items);

        if let Some(idx) = start_index {
            if idx < core_items.len() {
                coord.current_index.store(idx as i64, Ordering::Release);
                let item = &core_items[idx];
                open_item_on_deck(coord.active_deck_mut(), item);
                coord.phase.store(ENGINE_PHASE_PAUSED, Ordering::Release);
                let dur = coord.active_deck_ref().duration_ms.load(Ordering::Relaxed);
                if dur > 0 {
                    emit_event(&self.event_sink, RustEngineEvent::Duration(dur));
                }
                let sz = coord.active_deck_ref().get_meta_bytes_size();
                if sz > 0 {
                    let mut buf = vec![0u8; sz];
                    let copied = coord.active_deck_ref().copy_meta_bytes(&mut buf);
                    buf.truncate(copied);
                    if !buf.is_empty() {
                        if let Some(q_it) = q_items.get_mut(idx) {
                            q_it.data_bytes = Some(buf);
                        }
                    }
                }
                emit_event(&self.event_sink, RustEngineEvent::Position(0));
                emit_event(&self.event_sink, RustEngineEvent::CurrentIndex(idx as i32));
                emit_event(
                    &self.event_sink,
                    RustEngineEvent::Phase(ENGINE_PHASE_PAUSED),
                );
                emit_event(&self.event_sink, RustEngineEvent::State(STATE_PAUSED));
                emit_event(&self.event_sink, RustEngineEvent::IsPlaying(false));
            }
        }

        emit_event(&self.event_sink, RustEngineEvent::QueueChanged(q_items));
    }

    pub fn append(&self, items: Vec<RustEngineItem>) {
        let mut coord = self.coordinator.lock().unwrap();
        let core_items: Vec<EngineItemCore> = items.into_iter().map(EngineItemCore::from).collect();
        coord.append_items(core_items);
        self.emit_queue_and_index(&coord, false);
    }

    pub fn insert_next(&self, item: RustEngineItem) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.insert_next_item(EngineItemCore::from(item));
        self.emit_queue_and_index(&coord, false);
    }

    pub fn remove_at(&self, index: usize) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.remove_item_at(index);
        self.emit_queue_and_index(&coord, true);
    }

    pub fn reorder(&self, from: usize, to: usize) {
        let mut coord = self.coordinator.lock().unwrap();
        if coord.reorder_item(from, to) {
            self.emit_queue_and_index(&coord, true);
        }
    }

    pub fn clear_queue(&self, keep_current: bool) {
        let mut coord = self.coordinator.lock().unwrap();
        coord.clear_items(keep_current);
        self.emit_queue_and_index(&coord, true);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_infinite_mix(&self, enabled: bool) {
        let coord = self.coordinator.lock().unwrap();
        coord.infinite_mix_enabled.store(enabled, Ordering::Release);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_infinite_mix(&self) -> bool {
        self.coordinator
            .lock()
            .unwrap()
            .infinite_mix_enabled
            .load(Ordering::Relaxed)
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

    pub fn next(&self, crossfade_duration_ms: Option<u64>, curve: Option<i32>) {
        let mut coord = self.coordinator.lock().unwrap();
        let q_len = coord.queue.read().unwrap().len();
        if q_len == 0 {
            return;
        }

        if coord.phase.load(Ordering::Relaxed) == ENGINE_PHASE_AUTO_CROSSFADING {
            let auto_target = coord.auto_crossfade_target_index.swap(-1, Ordering::AcqRel);
            if auto_target >= 0 && (auto_target as usize) < q_len {
                let to_deck = coord.crossfade.to_deck.load(Ordering::Relaxed);
                let dur_ms = crossfade_duration_ms
                    .unwrap_or_else(|| coord.manual_crossfade_duration_ms.load(Ordering::Relaxed));
                coord.active_deck.store(to_deck, Ordering::Release);
                coord.current_index.store(auto_target, Ordering::Release);
                emit_event(
                    &self.event_sink,
                    RustEngineEvent::CurrentIndex(auto_target as i32),
                );
                if dur_ms == 0 {
                    coord.crossfade.abort();
                    coord.standby_deck_mut().stop();
                    coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
                    emit_event(
                        &self.event_sink,
                        RustEngineEvent::Phase(ENGINE_PHASE_PLAYING),
                    );
                } else {
                    let sr = coord.deck_a.sample_rate.load(Ordering::Relaxed).max(1);
                    let total_frames = ((dur_ms * sr as u64) / 1000).max(1);
                    coord.crossfade.current_frame.store(0, Ordering::Relaxed);
                    coord
                        .crossfade
                        .total_frames
                        .store(total_frames, Ordering::Relaxed);
                    if let Some(c) = curve {
                        coord.crossfade.curve.store(c, Ordering::Relaxed);
                    }
                    coord
                        .phase
                        .store(ENGINE_PHASE_MANUAL_CROSSFADING, Ordering::Release);
                    emit_event(
                        &self.event_sink,
                        RustEngineEvent::Phase(ENGINE_PHASE_MANUAL_CROSSFADING),
                    );
                }
                return;
            }
        }

        let cur = coord.current_index.load(Ordering::Relaxed);
        let next_idx = if (cur + 1) as usize >= q_len {
            if coord.loop_mode.load(Ordering::Relaxed) == 2 {
                0
            } else {
                return;
            }
        } else {
            (cur + 1) as usize
        };

        self.perform_skip(&mut coord, next_idx, crossfade_duration_ms, curve);
    }

    pub fn previous(&self, crossfade_duration_ms: Option<u64>, curve: Option<i32>) {
        let mut coord = self.coordinator.lock().unwrap();
        let q_len = coord.queue.read().unwrap().len();
        if q_len == 0 {
            return;
        }

        let cur = coord.current_index.load(Ordering::Relaxed);
        let is_live = coord.active_deck_ref().is_live_stream();
        let pos = coord.active_deck_ref().position_ms.load(Ordering::Relaxed);
        let dur = coord.active_deck_ref().duration_ms.load(Ordering::Relaxed);

        if !is_live && pos > 3000 && dur > 0 {
            coord
                .auto_crossfade_target_index
                .store(-1, Ordering::Release);
            coord
                .crossfade_completed_flag
                .store(false, Ordering::Release);
            self.abort_active_crossfade(&mut coord);
            coord.active_deck_mut().seek(0);
            emit_event(&self.event_sink, RustEngineEvent::Position(0));
            return;
        }

        let prev_idx = if cur <= 0 {
            if coord.loop_mode.load(Ordering::Relaxed) == 2 {
                q_len - 1
            } else {
                0
            }
        } else {
            (cur - 1) as usize
        };

        self.perform_skip(&mut coord, prev_idx, crossfade_duration_ms, curve);
    }

    pub fn skip_to_index(
        &self,
        index: usize,
        crossfade_duration_ms: Option<u64>,
        curve: Option<i32>,
    ) {
        let mut coord = self.coordinator.lock().unwrap();
        let q_len = coord.queue.read().unwrap().len();
        if index >= q_len {
            return;
        }
        self.perform_skip(&mut coord, index, crossfade_duration_ms, curve);
    }

    fn perform_skip(
        &self,
        coord: &mut EngineCoordinator,
        target_idx: usize,
        crossfade_duration_ms: Option<u64>,
        curve: Option<i32>,
    ) {
        let Some(item) = coord.queue.read().unwrap().get(target_idx).cloned() else {
            return;
        };

        coord
            .auto_crossfade_target_index
            .store(-1, Ordering::Release);
        coord
            .crossfade_completed_flag
            .store(false, Ordering::Release);
        coord
            .current_index
            .store(target_idx as i64, Ordering::Release);
        emit_event(
            &self.event_sink,
            RustEngineEvent::CurrentIndex(target_idx as i32),
        );

        let active_id = coord.active_deck.load(Ordering::Relaxed);
        let cur_phase = coord.phase.load(Ordering::Relaxed);
        let was_playing = cur_phase == ENGINE_PHASE_PLAYING
            || cur_phase == ENGINE_PHASE_AUTO_CROSSFADING
            || cur_phase == ENGINE_PHASE_MANUAL_CROSSFADING;

        if !was_playing {
            open_item_on_deck(coord.active_deck_mut(), &item);
            coord.phase.store(ENGINE_PHASE_PAUSED, Ordering::Release);
            emit_event(
                &self.event_sink,
                RustEngineEvent::Phase(ENGINE_PHASE_PAUSED),
            );
            return;
        }

        let standby_id = if active_id == 0 { 1 } else { 0 };
        open_item_on_deck(coord.standby_deck_mut(), &item);
        coord.standby_deck_mut().play();

        let dur_ms = crossfade_duration_ms
            .unwrap_or_else(|| coord.manual_crossfade_duration_ms.load(Ordering::Relaxed));

        if dur_ms == 0 {
            coord.crossfade.abort();
            coord.active_deck.store(standby_id, Ordering::Release);
            coord.standby_deck_mut().stop();
            coord.phase.store(ENGINE_PHASE_PLAYING, Ordering::Release);
            emit_event(
                &self.event_sink,
                RustEngineEvent::Phase(ENGINE_PHASE_PLAYING),
            );
            return;
        }

        let sr = coord.deck_a.sample_rate.load(Ordering::Relaxed).max(1);
        let total_frames = (dur_ms * sr as u64) / 1000;
        let curve_code = curve.unwrap_or_else(|| coord.crossfade_curve.load(Ordering::Relaxed));

        coord
            .crossfade
            .begin(active_id, standby_id, total_frames, curve_code);
        coord.active_deck.store(standby_id, Ordering::Release);
        coord
            .phase
            .store(ENGINE_PHASE_MANUAL_CROSSFADING, Ordering::Release);

        emit_event(
            &self.event_sink,
            RustEngineEvent::Phase(ENGINE_PHASE_MANUAL_CROSSFADING),
        );
        crate::map_log!(
            3,
            "perform_skip -> target_idx={}, duration={}ms",
            target_idx,
            dur_ms
        );
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
        let eq = EqualizerParams::from(params);
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
        let clip_flag = if prevent_clipping { 1 } else { 0 };
        coord.deck_a.set_replay_gain(gain_db, peak, clip_flag);
        coord.deck_b.set_replay_gain(gain_db, peak, clip_flag);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_reverb(&self, params: RustReverbParams) {
        let mut coord = self.coordinator.lock().unwrap();
        let en = if params.enabled { 1 } else { 0 };
        coord.deck_a.set_reverb(
            en,
            params.room_size,
            params.damping,
            params.width,
            params.wet,
            params.dry,
        );
        coord.deck_b.set_reverb(
            en,
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
        let en = if enabled { 1 } else { 0 };
        coord.deck_a.set_limiter(en);
        coord.deck_b.set_limiter(en);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatializer(&self, enabled: bool, width: f32) {
        let mut coord = self.coordinator.lock().unwrap();
        let en = if enabled { 1 } else { 0 };
        coord.deck_a.set_spatializer(en, width);
        coord.deck_b.set_spatializer(en, width);
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
        emit_event(
            &self.event_sink,
            RustEngineEvent::VisualizerEnabled(enabled),
        );
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
        coord
            .auto_crossfade_duration_ms
            .store(config.duration_ms, Ordering::Release);
        coord
            .manual_crossfade_duration_ms
            .store(config.manual_duration_ms, Ordering::Release);
        coord.crossfade_curve.store(config.curve, Ordering::Release);
        emit_event(&self.event_sink, RustEngineEvent::CrossfadeConfig(config));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_device(&self, device_id: String) {
        let mut coord = self.coordinator.lock().unwrap();
        let c_str = CString::new(device_id).unwrap_or_default();
        coord.set_device(c_str.as_ptr());
    }

    // Synchronous state snapshot getters (100% Lock-free atomics)
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_phase(&self) -> i32 {
        self.phase.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_current_index(&self) -> Option<usize> {
        let idx = self.current_index.load(Ordering::Relaxed);
        if idx >= 0 {
            Some(idx as usize)
        } else {
            None
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_position_ms(&self) -> i64 {
        if self.active_deck.load(Ordering::Relaxed) == 0 {
            self.deck_a_position.load(Ordering::Relaxed)
        } else {
            self.deck_b_position.load(Ordering::Relaxed)
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_duration_ms(&self) -> i64 {
        if self.active_deck.load(Ordering::Relaxed) == 0 {
            self.deck_a_duration.load(Ordering::Relaxed)
        } else {
            self.deck_b_duration.load(Ordering::Relaxed)
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_playing(&self) -> bool {
        let state = if self.active_deck.load(Ordering::Relaxed) == 0 {
            self.deck_a_state.load(Ordering::Relaxed)
        } else {
            self.deck_b_state.load(Ordering::Relaxed)
        };
        state == STATE_PLAYING
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_buffering(&self) -> bool {
        let state = if self.active_deck.load(Ordering::Relaxed) == 0 {
            self.deck_a_state.load(Ordering::Relaxed)
        } else {
            self.deck_b_state.load(Ordering::Relaxed)
        };
        state == STATE_BUFFERING
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_completed(&self) -> bool {
        self.phase.load(Ordering::Relaxed) == ENGINE_PHASE_COMPLETED
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_volume(&self) -> f32 {
        f32::from_bits(self.volume.load(Ordering::Relaxed))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_visualizer_data(&self) -> RustVisualizerData {
        let vis = self.coordinator.lock().unwrap().visualizer_seqlock.read();
        RustVisualizerData::from(vis)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn start_recording(&self, path: String, format: RustWavFormat) -> Result<(), String> {
        self.coordinator
            .lock()
            .unwrap()
            .start_recording(&path, format.into())
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
        self.coordinator
            .lock()
            .unwrap()
            .offline_bounce(&path, format.into(), duration_ms)
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
        self.coordinator
            .lock()
            .unwrap()
            .configure_cue_output(cue_device_id, volume, mode)
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

impl Drop for RustEngine {
    fn drop(&mut self) {
        if let Ok(mut sink) = self.event_sink.lock() {
            *sink = None;
        }
        if let Ok(mut coord) = self.coordinator.lock() {
            coord.thread_running.store(false, Ordering::SeqCst);
            let _ = coord.stop_device();
            coord.deck_a.destroy();
            coord.deck_b.destroy();
        }
    }
}
