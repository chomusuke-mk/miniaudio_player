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
    pub device_id: Option<String>,
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
            sample_rate,
            channels,
        }
    }

    // =========================================================================
    // Multi-Input Management Commands
    // =========================================================================

    /// Reconciles active capture nodes with the requested inputs set.
    pub fn set_inputs(&mut self, inputs: Vec<RustAudioInput>) -> Result<(), String> {
        // 1. Evict nodes not present in requested inputs
        self.active_inputs.retain_mut(|node| {
            let keep = inputs.iter().any(|inp| inp.device_id == node.device_id);
            if !keep {
                let _ = node.capture_node.stop();
            }
            keep
        });

        // 2. Update existing nodes and open new ones
        for inp in inputs {
            if let Some(node) = self
                .active_inputs
                .iter_mut()
                .find(|n| n.device_id == inp.device_id)
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
                // Add new hardware capture node
                let c_dev = match inp.device_id.as_deref() {
                    Some(s) if !s.is_empty() && s != "auto" => {
                        Some(CString::new(s).map_err(|e| e.to_string())?)
                    }
                    _ => None,
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
            .active_inputs
            .iter()
            .any(|n| n.device_id == input.device_id)
        {
            return Err(format!(
                "Input with device_id {:?} is already active",
                input.device_id
            ));
        }

        let c_dev = match input.device_id.as_deref() {
            Some(s) if !s.is_empty() && s != "auto" => {
                Some(CString::new(s).map_err(|e| e.to_string())?)
            }
            _ => None,
        };
        let c_ptr = c_dev.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

        let (capture_node, consumer) = DeviceCaptureNode::new(self.sample_rate, 1, 512, c_ptr)
            .map_err(|e| format!("Failed to create capture device: code {}", e))?;

        let _ = capture_node.start();

        let mut ducker = AutoDucker::new(self.sample_rate);
        if let Some(ref d) = input.config.ducking {
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
            device_id: input.device_id,
            config: input.config,
            capture_node,
            consumer,
            ducker,
            scratch_buffer: vec![0.0; 2048],
        });

        Ok(())
    }

    /// Removes an audio input capture node by device identifier.
    pub fn remove_input(&mut self, device_id: Option<String>) -> Result<(), String> {
        if let Some(pos) = self
            .active_inputs
            .iter()
            .position(|n| n.device_id == device_id)
        {
            let node = self.active_inputs.remove(pos);
            let _ = node.capture_node.stop();
        }
        Ok(())
    }

    /// Configures runtime parameters for an active capture node without reopening hardware.
    pub fn configure_input(
        &mut self,
        device_id: Option<String>,
        config: RustAudioInputConfig,
    ) -> Result<(), String> {
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
        } else {
            Err(format!(
                "Input with device_id {:?} not found",
                device_id
            ))
        }
    }

    /// Returns a snapshot of the currently active inputs.
    pub fn current_inputs(&self) -> Vec<RustAudioInput> {
        self.active_inputs
            .iter()
            .map(|n| RustAudioInput {
                device_id: n.device_id.clone(),
                config: n.config.clone(),
            })
            .collect()
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
