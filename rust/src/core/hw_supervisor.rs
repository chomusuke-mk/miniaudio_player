//! Off-RT hardware device and live recording supervisor.
//!
//! Coordinates physical output/input OS endpoint resolution, `ma_device` creation,
//! WAV file open/header flush, and `ControlCoordinator` auto-pause completely outside
//! `map-engine-clock`, swapping only pre-opened handles in sub-microsecond closures and
//! delegating displaced hardware/recorder drops to `map-reaper`.

use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex};

use crate::api::types::{
    AudioOutputSource, RustAudioDevice, RustAudioInput, RustAudioInputConfig, RustAudioOutput,
};
use crate::core::control_coordinator::ControlCoordinator;
use crate::core::dual_source::STATE_PLAYING;
use crate::core::engine_actor::EngineActorHandle;
use crate::core::input_manager::InputManager;
use crate::core::output_manager::OutputManager;
use crate::core::recording::{LiveRecorder, WavFormat};
use crate::map_log;
use crate::sync::{lock_unpoisoned, ReaperHandle};

/// Matches a queried OS device descriptor against a configured user ID or alias.
#[inline]
pub fn device_id_matches(d: &RustAudioDevice, configured_id: &str) -> bool {
    d.id == configured_id || d.effective_id == configured_id || d.name == configured_id
}

/// Serializes physical hardware/recording setup and teardown off `map-engine-clock`.
#[derive(Clone)]
pub struct HardwareDeviceSupervisor {
    engine: EngineActorHandle,
    reaper: ReaperHandle,
    device_trigger: Arc<(Mutex<bool>, Condvar)>,
    tx_guard: Arc<Mutex<()>>,
}

impl HardwareDeviceSupervisor {
    /// Creates a new supervisor sharing the engine actor, reaper, and device-change trigger.
    pub fn new(
        engine: EngineActorHandle,
        reaper: ReaperHandle,
        device_trigger: Arc<(Mutex<bool>, Condvar)>,
    ) -> Self {
        Self {
            engine,
            reaper,
            device_trigger,
            tx_guard: Arc::new(Mutex::new(())),
        }
    }

    fn apply_outputs_locked(
        &self,
        desired: Vec<RustAudioOutput>,
        resolved_auto: Option<String>,
    ) -> Result<(), String> {
        let (sr, ch, existing) = self.engine.exec(|ply| {
            (
                ply.output_manager.sample_rate,
                ply.output_manager.channels,
                ply.output_manager.current_device_keys(),
            )
        })?;

        let batch = OutputManager::prepare_outputs_off_rt(
            sr,
            ch,
            Some(self.device_trigger.clone()),
            &existing,
            desired,
            resolved_auto,
        );

        let snap = self.engine.snapshots().clone();
        let evicted = self.engine.exec(move |ply| {
            let evicted = ply.output_manager.apply_prepared_outputs(batch);
            snap.set_outputs_snapshot(ply.output_manager.outputs.clone());
            evicted
        })?;

        self.reaper.reap_value(evicted);
        Ok(())
    }

    /// Replaces active output destinations off the RT thread.
    pub fn set_outputs(&self, outputs: Vec<RustAudioOutput>) -> Result<(), String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        self.apply_outputs_locked(outputs, None)
    }

    /// Adds a destination to the active output matrix, returning the updated list if changed.
    pub fn add_output(&self, output: RustAudioOutput) -> Result<Option<Vec<RustAudioOutput>>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let mut current = self.engine.exec(|ply| ply.output_manager.outputs.clone())?;
        if current.contains(&output) {
            return Ok(None);
        }
        current.push(output);
        self.apply_outputs_locked(current.clone(), None)?;
        Ok(Some(current))
    }

    /// Removes a destination from the active output matrix, returning the updated list if changed.
    pub fn remove_output(
        &self,
        output: RustAudioOutput,
    ) -> Result<Option<Vec<RustAudioOutput>>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let mut current = self.engine.exec(|ply| ply.output_manager.outputs.clone())?;
        let Some(pos) = current.iter().position(|x| *x == output) else {
            return Ok(None);
        };
        current.remove(pos);
        self.apply_outputs_locked(current.clone(), None)?;
        Ok(Some(current))
    }

    /// Evaluates hot-swap / default output changes, auto-pausing and re-opening devices off-clock.
    #[allow(clippy::too_many_arguments)]
    pub fn reconcile_outputs_from_watcher(
        &self,
        coordinator: &ControlCoordinator,
        prev_devs_opt: Option<Vec<RustAudioDevice>>,
        out_devs: Vec<RustAudioDevice>,
        cur_def_opt: Option<String>,
        default_out_changed: bool,
        initial_or_dormant_attach: bool,
    ) -> (bool, Option<Vec<RustAudioOutput>>) {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let Ok((cur_outputs, cur_reconcile, should_pause)) = self.engine.exec(move |ply| {
            let mut cur_outputs = ply.output_manager.outputs.clone();
            let mut cur_mutated = false;
            let mut cur_disconnected = false;
            if let Some(ref prev_devs) = prev_devs_opt {
                cur_outputs.retain(|out| {
                    if out.device_id != "AUTO" {
                        let was_in_prev = prev_devs
                            .iter()
                            .any(|d| device_id_matches(d, &out.device_id));
                        let is_in_cur = out_devs
                            .iter()
                            .any(|d| device_id_matches(d, &out.device_id));
                        if was_in_prev && !is_in_cur {
                            cur_disconnected = true;
                            cur_mutated = true;
                            return false;
                        }
                    }
                    true
                });
            }
            let cur_has_auto = cur_outputs.iter().any(|o| o.device_id == "AUTO");
            let cur_should_pause = cur_disconnected || (cur_has_auto && default_out_changed);
            let pause_active = cur_should_pause
                && ply
                    .output_manager
                    .pause_on_device_change
                    .load(Ordering::Relaxed)
                && ply.music_manager.active_deck_ref().state.load(Ordering::Relaxed)
                    == STATE_PLAYING;
            let cur_reconcile = cur_mutated
                || (cur_has_auto && (default_out_changed || initial_or_dormant_attach));
            (cur_outputs, cur_reconcile, pause_active)
        }) else {
            return (false, None);
        };

        let mut paused_now = false;
        if should_pause {
            map_log!(
                2,
                "[WATCHER:PAUSE] Auto-pausing playback deck due to output device change/disconnect!"
            );
            if coordinator.pause().is_ok() {
                paused_now = true;
            }
        }

        let emitted_outs = if cur_reconcile {
            let _ = self.apply_outputs_locked(cur_outputs.clone(), cur_def_opt);
            Some(cur_outputs)
        } else {
            None
        };

        (paused_now, emitted_outs)
    }

    fn apply_inputs_locked(
        &self,
        desired: Vec<RustAudioInput>,
        resolved_auto: Option<String>,
    ) -> Result<Vec<RustAudioInput>, String> {
        let (sr, existing) = self.engine.exec(|ply| {
            (
                ply.input_manager.sample_rate,
                ply.input_manager.current_device_keys(),
            )
        })?;

        let batch = InputManager::prepare_inputs_off_rt(sr, &existing, desired, resolved_auto)?;
        let snap = self.engine.snapshots().clone();
        let (evicted, current) = self.engine.exec(move |ply| {
            let evicted = ply.input_manager.apply_prepared_inputs(batch);
            let current = ply.input_manager.current_inputs();
            snap.set_inputs_snapshot(current.clone());
            (evicted, current)
        })?;

        self.reaper.reap_value(evicted);
        Ok(current)
    }

    /// Replaces active capture nodes off the RT thread.
    pub fn set_inputs(&self, inputs: Vec<RustAudioInput>) -> Result<Vec<RustAudioInput>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        self.apply_inputs_locked(inputs, None)
    }

    /// Adds a capture node off the RT thread, rejecting duplicates by `device_id`.
    pub fn add_input(&self, input: RustAudioInput) -> Result<Vec<RustAudioInput>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let mut current = self.engine.exec(|ply| ply.input_manager.current_inputs())?;
        if current.iter().any(|n| n.device_id == input.device_id) {
            return Err(format!(
                "Input with device_id {} is already active",
                input.device_id
            ));
        }
        current.push(input);
        self.apply_inputs_locked(current, None)
    }

    /// Removes a capture node matching `device_id` off the RT thread.
    pub fn remove_input(&self, device_id: String) -> Result<Vec<RustAudioInput>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let mut current = self.engine.exec(|ply| ply.input_manager.current_inputs())?;
        let Some(pos) = current.iter().position(|n| n.device_id == device_id) else {
            return Ok(current);
        };
        current.remove(pos);
        self.apply_inputs_locked(current, None)
    }

    /// Updates runtime input gain/monitoring/ducking without touching hardware handles.
    pub fn configure_input(
        &self,
        device_id: String,
        config: RustAudioInputConfig,
    ) -> Result<Vec<RustAudioInput>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let snap = self.engine.snapshots().clone();
        self.engine.exec(move |ply| {
            ply.input_manager.configure_input(device_id, config)?;
            let current = ply.input_manager.current_inputs();
            snap.set_inputs_snapshot(current.clone());
            Ok::<_, String>(current)
        })?
    }

    /// Evaluates hot-swap / default input changes and reconciles capture hardware off-clock.
    pub fn reconcile_inputs_from_watcher(
        &self,
        prev_devs_opt: Option<Vec<RustAudioDevice>>,
        in_devs: Vec<RustAudioDevice>,
        cur_def_opt: Option<String>,
        default_in_changed: bool,
        initial_or_dormant_attach_in: bool,
    ) -> Option<Vec<RustAudioInput>> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let Ok((cur_inputs, cur_reconcile)) = self.engine.exec(move |ply| {
            let mut cur_inputs = ply.input_manager.current_inputs();
            let mut cur_mutated = false;
            if let Some(ref prev_devs) = prev_devs_opt {
                cur_inputs.retain(|inp| {
                    if inp.device_id != "AUTO" {
                        let was_in_prev = prev_devs
                            .iter()
                            .any(|d| device_id_matches(d, &inp.device_id));
                        let is_in_cur = in_devs
                            .iter()
                            .any(|d| device_id_matches(d, &inp.device_id));
                        if was_in_prev && !is_in_cur {
                            cur_mutated = true;
                            return false;
                        }
                    }
                    true
                });
            }
            let cur_has_auto = cur_inputs.iter().any(|i| i.device_id == "AUTO");
            let cur_reconcile = cur_mutated
                || (cur_has_auto && (default_in_changed || initial_or_dormant_attach_in));
            (cur_inputs, cur_reconcile)
        }) else {
            return None;
        };

        if cur_reconcile {
            self.apply_inputs_locked(cur_inputs, cur_def_opt).ok()
        } else {
            None
        }
    }

    /// Opens WAV file and spawns `miniaudio-wav-writer` off-clock, then installs producer in <1us.
    pub fn start_recording(
        &self,
        path: String,
        format: WavFormat,
        source: AudioOutputSource,
    ) -> Result<(), String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let (sr, ch) = self
            .engine
            .exec(|ply| (ply.output_manager.sample_rate, ply.output_manager.channels))?;
        let (rec, prod) = LiveRecorder::prepare_start(sr, ch, format, &path)?;
        let (prev_rec, prev_prod) = self
            .engine
            .exec(move |ply| ply.output_manager.attach_prepared_recording(path, source, rec, prod))?;
        self.reaper.reap_value(prev_prod);
        if let Some(mut old) = prev_rec {
            let _ = old.stop();
        }
        Ok(())
    }

    /// Detaches recording atomically from RT engine, then joins writer and flushes WAV off-clock.
    pub fn stop_recording(&self) -> Result<(String, u64, usize, u64), String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let mut detached = self
            .engine
            .exec(|ply| ply.output_manager.detach_recording_for_stop())??;
        drop(detached.producer);
        let bytes_written = detached.recorder.stop().unwrap_or(0) as usize;
        Ok((
            detached.path,
            detached.duration_ms,
            bytes_written,
            detached.sample_count,
        ))
    }
}
