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
use crate::core::recording::{LiveRecorder, RecordingEncoding};
use crate::map_log;
use crate::sync::{lock_unpoisoned, ReaperHandle};

/// Matches a queried OS device descriptor `d` against a `configured_id` or device name alias.
#[inline]
pub fn device_id_matches(d: &RustAudioDevice, configured_id: &str) -> bool {
    d.id == configured_id || d.effective_id == configured_id || d.name == configured_id
}

/// Serializes physical hardware/recording setup and teardown off `map-engine-clock`.
#[derive(Clone)]
pub struct HardwareDeviceSupervisor {
    /// Handle to the single-owner real-time engine actor.
    engine: EngineActorHandle,
    /// Off-RT reaper handle used to drop displaced hardware and recorder handles.
    reaper: ReaperHandle,
    /// Shared condvar trigger notified when output devices change or are attached.
    device_trigger: Arc<(Mutex<bool>, Condvar)>,
    /// Mutex serializing hardware output/input and recording lifecycle transactions.
    tx_guard: Arc<Mutex<()>>,
}

impl HardwareDeviceSupervisor {
    /// Creates a new supervisor sharing `engine`, `reaper`, and `device_trigger`.
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

    /// Prepares the `desired` output endpoints off-RT (using `resolved_auto` for `"AUTO"`)
    /// and atomically swaps them onto `OutputManager` before sending evicted handles to `map-reaper`.
    fn apply_outputs_locked(
        &self,
        desired: Vec<RustAudioOutput>,
        resolved_auto: Option<String>,
    ) -> Result<(), String> {
        map_log!(
            3,
            "[HW_SUP] Applying {} output endpoint(s) (resolved_auto={:?})",
            desired.len(),
            resolved_auto
        );
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

    /// Replaces active output destinations with `outputs` off the RT thread.
    pub fn set_outputs(&self, outputs: Vec<RustAudioOutput>) -> Result<(), String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        self.apply_outputs_locked(outputs, None)
    }

    /// Adds `output` to the active output matrix off-RT, returning the updated list if changed.
    pub fn add_output(&self, output: RustAudioOutput) -> Result<Option<Vec<RustAudioOutput>>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let mut current = self.engine.exec(|ply| ply.output_manager.outputs.clone())?;
        if current.contains(&output) {
            return Ok(None);
        }
        map_log!(3, "[HW_SUP] Adding output device_id={}", output.device_id);
        current.push(output);
        self.apply_outputs_locked(current.clone(), None)?;
        Ok(Some(current))
    }

    /// Removes `output` from the active output matrix off-RT, returning the updated list if changed.
    pub fn remove_output(
        &self,
        output: RustAudioOutput,
    ) -> Result<Option<Vec<RustAudioOutput>>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let mut current = self.engine.exec(|ply| ply.output_manager.outputs.clone())?;
        let Some(pos) = current.iter().position(|x| *x == output) else {
            return Ok(None);
        };
        map_log!(3, "[HW_SUP] Removing output device_id={}", output.device_id);
        current.remove(pos);
        self.apply_outputs_locked(current.clone(), None)?;
        Ok(Some(current))
    }

    /// Evaluates hot-swap / default output changes using `prev_devs_opt`, `out_devs`,
    /// `cur_def_opt`, `default_out_changed`, and `initial_or_dormant_attach`, auto-pausing via
    /// `coordinator` when configured and re-opening devices off-clock.
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
            map_log!(
                3,
                "[HW_SUP] Watcher reconciling {} output(s) (default_changed={}, initial_attach={})",
                cur_outputs.len(),
                default_out_changed,
                initial_or_dormant_attach
            );
            if let Err(e) = self.apply_outputs_locked(cur_outputs.clone(), cur_def_opt) {
                map_log!(1, "[HW_SUP] Failed to reconcile outputs from watcher: {}", e);
            }
            Some(cur_outputs)
        } else {
            None
        };

        (paused_now, emitted_outs)
    }

    /// Prepares the `desired` capture inputs off-RT (using `resolved_auto` for `"AUTO"`)
    /// and atomically swaps them onto `InputManager` before reaping evicted handles.
    fn apply_inputs_locked(
        &self,
        desired: Vec<RustAudioInput>,
        resolved_auto: Option<String>,
    ) -> Result<Vec<RustAudioInput>, String> {
        map_log!(
            3,
            "[HW_SUP] Applying {} input endpoint(s) (resolved_auto={:?})",
            desired.len(),
            resolved_auto
        );
        let (sr, existing) = self.engine.exec(|ply| {
            (
                ply.input_manager.sample_rate,
                ply.input_manager.current_device_keys(),
            )
        })?;

        let batch = InputManager::prepare_inputs_off_rt(sr, &existing, desired, resolved_auto)
            .map_err(|e| {
                map_log!(1, "[HW_SUP] Failed to prepare input devices: {}", e);
                e
            })?;
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

    /// Replaces active capture nodes with `inputs` off the RT thread.
    pub fn set_inputs(&self, inputs: Vec<RustAudioInput>) -> Result<Vec<RustAudioInput>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        self.apply_inputs_locked(inputs, None)
    }

    /// Adds capture node `input` off the RT thread, rejecting duplicates by `device_id`.
    pub fn add_input(&self, input: RustAudioInput) -> Result<Vec<RustAudioInput>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let mut current = self.engine.exec(|ply| ply.input_manager.current_inputs())?;
        if current.iter().any(|n| n.device_id == input.device_id) {
            map_log!(
                2,
                "[HW_SUP] Rejected duplicate input device_id={}",
                input.device_id
            );
            return Err(format!(
                "Input with device_id {} is already active",
                input.device_id
            ));
        }
        map_log!(3, "[HW_SUP] Adding input device_id={}", input.device_id);
        current.push(input);
        self.apply_inputs_locked(current, None)
    }

    /// Removes the capture node matching `device_id` off the RT thread.
    pub fn remove_input(&self, device_id: String) -> Result<Vec<RustAudioInput>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let mut current = self.engine.exec(|ply| ply.input_manager.current_inputs())?;
        let Some(pos) = current.iter().position(|n| n.device_id == device_id) else {
            return Ok(current);
        };
        map_log!(3, "[HW_SUP] Removing input device_id={}", device_id);
        current.remove(pos);
        self.apply_inputs_locked(current, None)
    }

    /// Updates runtime input `config` (gain, monitoring, ducking) for `device_id` without touching hardware handles.
    pub fn configure_input(
        &self,
        device_id: String,
        config: RustAudioInputConfig,
    ) -> Result<Vec<RustAudioInput>, String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        map_log!(4, "[HW_SUP] Configuring input device_id={}", device_id);
        let snap = self.engine.snapshots().clone();
        self.engine.exec(move |ply| {
            ply.input_manager.configure_input(device_id, config)?;
            let current = ply.input_manager.current_inputs();
            snap.set_inputs_snapshot(current.clone());
            Ok::<_, String>(current)
        })?
    }

    /// Evaluates hot-swap / default input changes using `prev_devs_opt`, `in_devs`,
    /// `cur_def_opt`, `default_in_changed`, and `initial_or_dormant_attach_in`,
    /// reconciling capture hardware off-clock.
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
            cur_inputs.retain(|inp| {
                let is_failed = ply
                    .input_manager
                    .active_inputs
                    .iter()
                    .find(|n| n.device_id == inp.device_id)
                    .is_some_and(|n| n.capture_node.is_failed());
                if is_failed {
                    cur_mutated = true;
                    return false;
                }
                if inp.device_id != "AUTO" {
                    if let Some(ref prev_devs) = prev_devs_opt {
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
                }
                true
            });
            let cur_has_auto = cur_inputs.iter().any(|i| i.device_id == "AUTO");
            let cur_reconcile = cur_mutated
                || (cur_has_auto && (default_in_changed || initial_or_dormant_attach_in));
            (cur_inputs, cur_reconcile)
        }) else {
            return None;
        };

        if cur_reconcile {
            map_log!(
                3,
                "[HW_SUP] Watcher reconciling {} input(s) (default_changed={}, initial_attach={})",
                cur_inputs.len(),
                default_in_changed,
                initial_or_dormant_attach_in
            );
            match self.apply_inputs_locked(cur_inputs, cur_def_opt) {
                Ok(updated) => Some(updated),
                Err(e) => {
                    map_log!(1, "[HW_SUP] Failed to reconcile inputs from watcher: {}", e);
                    None
                }
            }
        } else {
            None
        }
    }

    /// Prepares and attaches a live recording session to `path` with `format` from `source`
    /// safely off the RT clock thread, spawning the writer and installing the producer in <1us.
    pub fn start_recording(
        &self,
        path: String,
        format: impl Into<RecordingEncoding>,
        source: AudioOutputSource,
    ) -> Result<(), String> {
        let encoding = format.into();
        let _guard = lock_unpoisoned(&self.tx_guard);
        let (sr, ch, already_active) = self.engine.exec(|ply| {
            (
                ply.output_manager.sample_rate,
                ply.output_manager.channels,
                ply.output_manager.live_recorder.is_some(),
            )
        })?;
        if already_active {
            map_log!(2, "[HW_SUP] start_recording rejected: recording already in progress");
            return Err(
                "Recording is already in progress. Call stopRecording() before starting a new session. (code: -6)"
                    .to_string(),
            );
        }
        let normalized = crate::core::recording::normalize_recording_path(&path).map_err(|e| {
            map_log!(1, "[HW_SUP] Invalid recording path '{}': {}", path, e);
            e
        })?;
        map_log!(
            3,
            "[HW_SUP] Starting recording to '{}' (sr={}, ch={}, source={:?})",
            normalized,
            sr,
            ch,
            source
        );
        #[cfg(target_arch = "wasm32")]
        let (rec, prod) =
            LiveRecorder::prepare_start_opfs(sr, ch, encoding, &normalized).map_err(|e| {
                map_log!(
                    1,
                    "[HW_SUP] Failed to start OPFS recording at '{}': {}",
                    normalized,
                    e
                );
                e
            })?;
        #[cfg(not(target_arch = "wasm32"))]
        let (rec, prod) =
            LiveRecorder::prepare_start(sr, ch, encoding, &normalized).map_err(|e| {
                map_log!(
                    1,
                    "[HW_SUP] Failed to start recording at '{}': {}",
                    normalized,
                    e
                );
                e
            })?;
        let (prev_rec, prev_prod) = self.engine.exec(move |ply| {
            ply.output_manager
                .attach_prepared_recording(normalized, source, rec, prod)
        })?;
        self.reaper.reap_value(prev_prod);
        if let Some(mut old) = prev_rec {
            let _ = old.stop();
        }
        Ok(())
    }

    /// Validates a detached POSIX file descriptor `fd` (Android `content://`) labeled
    /// `display_path` and attaches a live recorder with `format` from `source`.
    #[cfg(unix)]
    pub fn start_recording_fd(
        &self,
        display_path: String,
        fd: i32,
        format: impl Into<RecordingEncoding>,
        source: AudioOutputSource,
    ) -> Result<(), String> {
        use std::os::unix::io::FromRawFd;
        let encoding = format.into();
        let _guard = lock_unpoisoned(&self.tx_guard);
        let (sr, ch, already_active) = self.engine.exec(|ply| {
            (
                ply.output_manager.sample_rate,
                ply.output_manager.channels,
                ply.output_manager.live_recorder.is_some(),
            )
        })?;
        if already_active {
            map_log!(
                2,
                "[HW_SUP] start_recording_fd rejected: recording already in progress (fd={})",
                fd
            );
            if fd >= 0 {
                unsafe {
                    drop(std::fs::File::from_raw_fd(fd));
                }
            }
            return Err(
                "Recording is already in progress. Call stopRecording() before starting a new session. (code: -6)"
                    .to_string(),
            );
        }
        map_log!(
            3,
            "[HW_SUP] Starting FD recording '{}' (fd={}, sr={}, ch={}, source={:?})",
            display_path,
            fd,
            sr,
            ch,
            source
        );
        let (rec, prod) = LiveRecorder::prepare_start_fd(sr, ch, encoding, fd).map_err(|e| {
            map_log!(
                1,
                "[HW_SUP] Failed to start FD recording '{}' (fd={}): {}",
                display_path,
                fd,
                e
            );
            e
        })?;
        let (prev_rec, prev_prod) = self.engine.exec(move |ply| {
            ply.output_manager
                .attach_prepared_recording(display_path, source, rec, prod)
        })?;
        self.reaper.reap_value(prev_prod);
        if let Some(mut old) = prev_rec {
            let _ = old.stop();
        }
        Ok(())
    }

    /// Returns an unsupported error on non-POSIX platforms for raw file descriptor `fd` recording
    /// (`display_path`, `format`, `source` are ignored).
    #[cfg(not(unix))]
    pub fn start_recording_fd(
        &self,
        display_path: String,
        fd: i32,
        format: impl Into<RecordingEncoding>,
        source: AudioOutputSource,
    ) -> Result<(), String> {
        let _ = (display_path, fd, format.into(), source);
        map_log!(
            2,
            "[HW_SUP] start_recording_fd unsupported on non-POSIX platform"
        );
        Err("File descriptor recording is only supported on POSIX/Android platforms (code: -9)".to_string())
    }

    /// Detaches recording atomically from the RT engine, then joins the writer and flushes output off-clock.
    pub fn stop_recording(&self) -> Result<(String, u64, usize, u64, u64), String> {
        let _guard = lock_unpoisoned(&self.tx_guard);
        let mut detached = self
            .engine
            .exec(|ply| ply.output_manager.detach_recording_for_stop())?
            .map_err(|e| {
                map_log!(2, "[HW_SUP] stop_recording failed to detach: {}", e);
                e
            })?;
        drop(detached.producer);
        let bytes_written = detached.recorder.stop().map_err(|e| {
            map_log!(
                1,
                "[HW_SUP] Failed to finalize recording '{}': {}",
                detached.path,
                e
            );
            e
        })? as usize;
        map_log!(
            3,
            "[HW_SUP] Stopped recording '{}' (duration_ms={}, bytes={}, samples={}, dropped={})",
            detached.path,
            detached.duration_ms,
            bytes_written,
            detached.sample_count,
            detached.dropped_frames
        );
        Ok((
            detached.path,
            detached.duration_ms,
            bytes_written,
            detached.sample_count,
            detached.dropped_frames,
        ))
    }
}
