//! Multi-Input Capture & Auto-Ducking Domain Manager (`InputManager`).
//!
//! Encapsulates an N-channel multi-capture matrix (symmetric to `OutputManager`).
//! Governs hardware capture nodes, real-time voice RMS detector,
//! sidechain auto-ducking dynamics processors, and low-latency direct monitoring summation.

use std::ffi::CString;

use crate::api::types::{RustAudioInput, RustAudioInputConfig};
use crate::core::capture::DeviceCaptureNode;
use crate::dsp::ducking::AutoDucker;

/// Concrete active capture hardware node instance.
pub struct ActiveInputNode {
    pub device_id: String,
    pub resolved_id: String,
    pub config: RustAudioInputConfig,
    pub capture_node: Box<DeviceCaptureNode>,
    pub consumer: rtrb::Consumer<f32>,
    pub ducker: AutoDucker,
    pub scratch_buffer: Vec<f32>,
}

/// Domain manager governing multi-input capture, RMS detection, auto-ducking, and direct monitoring.
pub struct InputManager {
    /// Active capture hardware input nodes.
    pub active_inputs: Vec<ActiveInputNode>,
    /// Declarative configurations of requested inputs.
    pub inputs: Vec<RustAudioInput>,
    /// Audio sample rate in Hz.
    pub sample_rate: u32,
    /// Output channel count.
    pub channels: usize,
}

impl InputManager {
    /// Creates a new `InputManager` with the specified sample rate and channel count.
    pub fn new(sample_rate: u32, channels: usize) -> Self {
        Self {
            active_inputs: Vec::new(),
            inputs: Vec::new(),
            sample_rate,
            channels,
        }
    }

    // =========================================================================
    // Multi-Input Management Commands
    // =========================================================================

    /// Resolves a requested device ID ("AUTO" or specific ID) to a physical OS capture device endpoint ID.
    pub fn resolve_physical_input_id(device_id: &str) -> Option<String> {
        if device_id == "AUTO" || device_id == "auto" || device_id.is_empty() {
            if let Ok(devs) = crate::bridge::ffi::safe_enumerate_capture_devices() {
                let mut found = None;
                for d in &devs {
                    if d.is_default != 0 && d.is_auto == 0 {
                        found = Some(crate::api::types::c_buf_to_string(&d.effective_id));
                        break;
                    }
                }
                if found.is_none() {
                    for d in &devs {
                        if d.is_auto == 0 {
                            found = Some(crate::api::types::c_buf_to_string(&d.effective_id));
                            break;
                        }
                    }
                }
                return found;
            }
            None
        } else {
            Some(device_id.to_string())
        }
    }

    /// Reconciles active capture nodes with the requested inputs set.
    pub fn set_inputs(&mut self, inputs: Vec<RustAudioInput>) -> Result<(), String> {
        self.set_inputs_with_resolved(inputs, None)
    }

    /// Reconciles active capture nodes with the requested inputs set, using optional pre-resolved AUTO endpoint.
    pub fn set_inputs_with_resolved(
        &mut self,
        inputs: Vec<RustAudioInput>,
        pre_resolved_auto_id: Option<String>,
    ) -> Result<(), String> {
        self.inputs = inputs;
        let current_auto_def = pre_resolved_auto_id
            .or_else(|| Self::resolve_physical_input_id("AUTO"));

        // Deduplicate physical hardware capture targets:
        // Prioritize AUTO and its configuration over specific/explicit devices.
        // `self.inputs` remains completely intact.
        let mut effective_configs: Vec<(RustAudioInput, String)> = Vec::new();

        // 1. Prioritize AUTO inputs first
        for inp in &self.inputs {
            if inp.device_id == "AUTO" {
                let auto_res_id = current_auto_def.clone().unwrap_or_else(|| "AUTO".to_string());
                if !effective_configs.iter().any(|(_, r)| r == &auto_res_id) {
                    effective_configs.push((inp.clone(), auto_res_id));
                }
            }
        }

        // 2. Add specific physical devices whose endpoints are not already claimed by AUTO
        for inp in &self.inputs {
            if inp.device_id != "AUTO" {
                if let Some(res_id) = Self::resolve_physical_input_id(&inp.device_id) {
                    let already_claimed = effective_configs.iter().any(|(c, r)| {
                        r == &res_id || (c.device_id == "AUTO" && current_auto_def.as_ref() == Some(&res_id))
                    });
                    if !already_claimed {
                        effective_configs.push((inp.clone(), res_id));
                    }
                }
            }
        }

        // 3. Evict active capture nodes not present in effective_configs
        self.active_inputs.retain_mut(|node| {
            let keep = effective_configs.iter().any(|(inp, res_id)| {
                *res_id == node.resolved_id && inp.device_id == node.device_id
            });
            if !keep {
                let _ = node.capture_node.stop();
            }
            keep
        });

        // 4. Update existing nodes and open new ones from effective_configs
        for (inp, target_resolved_id) in effective_configs {
            if let Some(node) = self
                .active_inputs
                .iter_mut()
                .find(|n| n.device_id == inp.device_id && n.resolved_id == target_resolved_id)
            {
                // Modulate runtime config without reopening hardware
                node.config = inp.config.clone();
                if let Some(ref d) = inp.config.ducking {
                    node.ducker.set_params(
                        d.enabled,
                        d.ducking_db,
                        d.threshold_db,
                        d.attack_ms,
                        d.hold_ms,
                        d.release_ms,
                    );
                } else {
                    node.ducker.set_params(false, -14.0, -30.0, 30.0, 250.0, 400.0);
                }
            } else {
                // Add new hardware capture node bound to resolved physical endpoint
                let c_dev = if target_resolved_id == "AUTO" {
                    None
                } else {
                    CString::new(target_resolved_id.as_str()).ok()
                };
                let c_ptr = c_dev.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

                let (capture_node, consumer) =
                    DeviceCaptureNode::new(self.sample_rate, 1, 512, c_ptr)
                        .map_err(|e| format!("Failed to create capture device: code {}", e))?;

                let _ = capture_node.start();

                let mut ducker = AutoDucker::new(self.sample_rate);
                if let Some(ref d) = inp.config.ducking {
                    ducker.set_params(
                        d.enabled,
                        d.ducking_db,
                        d.threshold_db,
                        d.attack_ms,
                        d.hold_ms,
                        d.release_ms,
                    );
                }

                self.active_inputs.push(ActiveInputNode {
                    device_id: inp.device_id,
                    resolved_id: target_resolved_id,
                    config: inp.config,
                    capture_node,
                    consumer,
                    ducker,
                    scratch_buffer: vec![0.0; 2048],
                });
            }
        }

        Ok(())
    }

    /// Adds a new audio input capture node. Rejects if deviceId is already active.
    pub fn add_input(&mut self, input: RustAudioInput) -> Result<(), String> {
        if self
            .inputs
            .iter()
            .any(|n| n.device_id == input.device_id)
        {
            return Err(format!(
                "Input with device_id {} is already active",
                input.device_id
            ));
        }

        self.inputs.push(input);
        self.set_inputs(self.inputs.clone())
    }

    /// Removes an audio input capture node by device identifier.
    pub fn remove_input(&mut self, device_id: String) -> Result<(), String> {
        if let Some(pos) = self
            .inputs
            .iter()
            .position(|n| n.device_id == device_id)
        {
            self.inputs.remove(pos);
            self.set_inputs(self.inputs.clone())
        } else {
            Ok(())
        }
    }

    /// Configures runtime parameters for an active capture node without reopening hardware.
    pub fn configure_input(
        &mut self,
        device_id: String,
        config: RustAudioInputConfig,
    ) -> Result<(), String> {
        if let Some(inp) = self.inputs.iter_mut().find(|n| n.device_id == device_id) {
            inp.config = config.clone();
        }

        if let Some(node) = self
            .active_inputs
            .iter_mut()
            .find(|n| n.device_id == device_id)
        {
            node.config = config.clone();
            if let Some(ref d) = config.ducking {
                node.ducker.set_params(
                    d.enabled,
                    d.ducking_db,
                    d.threshold_db,
                    d.attack_ms,
                    d.hold_ms,
                    d.release_ms,
                );
            } else {
                node.ducker.set_params(false, -14.0, -30.0, 30.0, 250.0, 400.0);
            }
            Ok(())
        } else if self.inputs.iter().any(|n| n.device_id == device_id) {
            Ok(())
        } else {
            Err(format!(
                "Input with device_id {} not found",
                device_id
            ))
        }
    }

    /// Returns a snapshot of the currently active inputs.
    pub fn current_inputs(&self) -> Vec<RustAudioInput> {
        self.inputs.clone()
    }

    // =========================================================================
    // Real-Time Audio Processing
    // =========================================================================

    /// Processes multi-input capture:
    /// - Drains lock-free SPSC consumer queues.
    /// - Scales by per-input volume.
    /// - Applies sidechain Auto-Ducking per active ducker on `music_buffer`.
    /// - Sums direct monitoring into `scratch_voice_out` with zero latency.
    pub fn process(&mut self, music_buffer: &mut [f32], scratch_voice_out: &mut [f32]) {
        let frame_count = music_buffer.len() / self.channels;
        let sample_count = music_buffer.len();

        scratch_voice_out.fill(0.0);

        if self.active_inputs.is_empty() {
            return;
        }

        for node in &mut self.active_inputs {
            if node.scratch_buffer.len() < frame_count {
                node.scratch_buffer.resize(frame_count, 0.0);
            }
            node.scratch_buffer[..frame_count].fill(0.0);

            let mic_vol = node.config.volume.max(0.0);
            let mut read_idx = 0;
            while read_idx < frame_count {
                if let Ok(sample) = node.consumer.pop() {
                    node.scratch_buffer[read_idx] = sample * mic_vol;
                    read_idx += 1;
                } else {
                    break;
                }
            }

            // Sidechain auto-ducking
            if let Some(ref ducking) = node.config.ducking {
                if ducking.enabled {
                    node.ducker.process_sidechain(
                        &node.scratch_buffer[..frame_count],
                        music_buffer,
                        self.channels,
                    );
                }
            }

            // Direct pass-through monitoring
            if node.config.monitor_direct {
                let mon_vol = node.config.monitor_volume.max(0.0);
                let out_len = scratch_voice_out.len().min(sample_count);

                for f in 0..frame_count {
                    let val = node.scratch_buffer[f] * mon_vol;
                    let out_idx = f * self.channels;
                    if out_idx + 1 < out_len {
                        scratch_voice_out[out_idx] += val;
                        scratch_voice_out[out_idx + 1] += val;
                    }
                }
            }
        }
    }

    #[inline]
    pub fn is_ducking_active(&self) -> bool {
        self.active_inputs.iter().any(|n| n.ducker.is_ducking())
    }

    #[inline]
    pub fn last_rms_db(&self) -> f32 {
        self.active_inputs
            .iter()
            .map(|n| n.ducker.last_rms_db())
            .fold(-100.0f32, |acc, val| acc.max(val))
    }

    #[inline]
    pub fn has_active_inputs(&self) -> bool {
        !self.active_inputs.is_empty()
    }
}
