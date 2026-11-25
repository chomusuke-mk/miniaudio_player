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
    /// Requested logical device identifier (`"AUTO"` or OS endpoint ID).
    pub device_id: String,
    /// Resolved physical OS capture device identifier.
    pub resolved_id: String,
    /// Per-input volume, ducking, and monitoring configuration.
    pub config: RustAudioInputConfig,
    /// Underlying hardware capture device node.
    pub capture_node: Box<DeviceCaptureNode>,
    /// Lock-free SPSC ring buffer consumer receiving captured PCM frames.
    pub consumer: rtrb::Consumer<f32>,
    /// Sidechain auto-ducker envelope processor for this input node.
    pub ducker: AutoDucker,
    /// Preallocated mono scratch buffer holding the drained live-edge audio frames.
    pub scratch_buffer: Vec<f32>,
}

/// Pre-opened physical capture changes staged off `map-engine-clock`.
pub struct PreparedInputs {
    /// Desired declarative input configurations from the caller.
    pub desired_inputs: Vec<RustAudioInput>,
    /// Target `(device_id, resolved_id, config)` entries to retain or update.
    pub updates: Vec<(String, String, RustAudioInputConfig)>,
    /// Newly opened capture nodes ready to be swapped into `active_inputs`.
    pub new_nodes: Vec<ActiveInputNode>,
}

/// Domain manager governing multi-input capture, RMS detection, auto-ducking, and direct monitoring.
pub struct InputManager {
    /// Active capture hardware input nodes.
    pub active_inputs: Vec<ActiveInputNode>,
    /// Declarative configurations of requested inputs.
    pub inputs: Vec<RustAudioInput>,
    /// Preallocated scratch envelope buffer for arbitrated auto-ducking.
    pub ducking_envelope: Vec<f32>,
    /// Preallocated scratch envelope buffer for per-node ducking calculations.
    pub node_envelope: Vec<f32>,
    /// Audio sample rate in Hz.
    pub sample_rate: u32,
    /// Output channel count.
    pub channels: usize,
}

impl ActiveInputNode {
    /// Drains up to `frame_count` capture audio frames into `self.scratch_buffer`, discarding stale
    /// buffered frames in O(1) when capture jitter exceeds ~3 audio periods to stay on the live edge.
    fn drain_live_edge_to_scratch(&mut self, frame_count: usize) {
        if self.scratch_buffer.len() < frame_count {
            self.scratch_buffer.resize(frame_count, 0.0);
        }
        self.scratch_buffer[..frame_count].fill(0.0);

        let node_ch = (self.capture_node.channels as usize).max(1);
        let needed_samples = frame_count * node_ch;
        let max_jitter_samples = (needed_samples * 3).max(node_ch * 256);
        let available = self.consumer.slots();
        if available > max_jitter_samples {
            let stale_raw = available - needed_samples;
            let stale = (stale_raw / node_ch) * node_ch;
            if stale > 0 {
                if let Ok(chunk) = self.consumer.read_chunk(stale) {
                    chunk.commit_all();
                }
            }
        }

        let mic_vol = self.config.volume.max(0.0);
        let current_slots = self.consumer.slots();
        let to_read = (current_slots.min(needed_samples) / node_ch) * node_ch;
        if to_read == 0 {
            return;
        }

        let Ok(chunk) = self.consumer.read_chunk(to_read) else {
            return;
        };
        let (s1, s2) = chunk.as_slices();
        if node_ch == 1 {
            let n1 = s1.len().min(frame_count);
            for (dst, &src) in self.scratch_buffer[..n1].iter_mut().zip(&s1[..n1]) {
                *dst = src * mic_vol;
            }
            let rem = (to_read - n1).min(s2.len());
            for (dst, &src) in self.scratch_buffer[n1..n1 + rem].iter_mut().zip(&s2[..rem]) {
                *dst = src * mic_vol;
            }
        } else {
            let inv_ch = mic_vol / node_ch as f32;
            let mut iter = s1.iter().chain(s2.iter());
            let frames_read = to_read / node_ch;
            for dst in &mut self.scratch_buffer[..frames_read] {
                let mut sum = 0.0f32;
                for _ in 0..node_ch {
                    if let Some(&s) = iter.next() {
                        sum += s;
                    }
                }
                *dst = sum * inv_ch;
            }
        }
        chunk.commit_all();
    }
}

/// Mixes mono frame slice `src[..frame_count]` evenly across all `channels` interleaved in `dst`
/// scaled by `gain`.
#[inline]
fn mix_mono_frames_into_interleaved(
    src: &[f32],
    dst: &mut [f32],
    frame_count: usize,
    channels: usize,
    gain: f32,
) {
    let max_samples = dst.len();
    for (f, &sample) in src.iter().take(frame_count).enumerate() {
        let val = sample * gain;
        let out_idx = f * channels;
        for c in 0..channels {
            if out_idx + c < max_samples {
                dst[out_idx + c] += val;
            }
        }
    }
}

impl InputManager {
    /// Default preallocated scratch buffer size in frames to avoid RT heap reallocations.
    const DEFAULT_SCRATCH_FRAMES: usize = 8192;

    /// Creates a new `InputManager` with the specified `sample_rate` and `channels` count.
    pub fn new(sample_rate: u32, channels: usize) -> Self {
        crate::map_log!(4, "[INPUT] Initialized InputManager (sr={}, ch={})", sample_rate, channels);
        Self {
            active_inputs: Vec::new(),
            inputs: Vec::new(),
            ducking_envelope: vec![1.0; Self::DEFAULT_SCRATCH_FRAMES],
            node_envelope: vec![1.0; Self::DEFAULT_SCRATCH_FRAMES],
            sample_rate,
            channels,
        }
    }

    // =========================================================================
    // Multi-Input Management Commands
    // =========================================================================

    /// Resolves a requested `device_id` (`"AUTO"` or specific ID) to a physical OS capture device endpoint ID.
    pub fn resolve_physical_input_id(device_id: &str) -> Option<String> {
        if device_id == "AUTO" || device_id == "auto" || device_id.is_empty() {
            match crate::bridge::ffi::safe_enumerate_capture_devices() {
                Ok(devs) => {
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
                    if found.is_none() {
                        crate::map_log!(
                            2,
                            "[INPUT] No physical capture device found while resolving '{}'",
                            device_id
                        );
                    }
                    found
                }
                Err(code) => {
                    crate::map_log!(
                        2,
                        "[INPUT] Failed to enumerate capture devices for '{}' (code={})",
                        device_id,
                        code
                    );
                    None
                }
            }
        } else {
            Some(device_id.to_string())
        }
    }

    /// Returns `(device_id, resolved_id)` keys for all currently active capture nodes.
    pub fn current_device_keys(&self) -> Vec<(String, String)> {
        self.active_inputs
            .iter()
            .map(|n| (n.device_id.clone(), n.resolved_id.clone()))
            .collect()
    }

    /// Applies the ducking configuration from `config` (or disabled defaults) to `ducker`.
    fn apply_ducker_params(ducker: &mut AutoDucker, config: &RustAudioInputConfig) {
        if let Some(ref d) = config.ducking {
            ducker.set_params(
                d.enabled,
                d.ducking_db,
                d.threshold_db,
                d.attack_ms,
                d.hold_ms,
                d.release_ms,
            );
        } else {
            ducker.set_params(false, -14.0, -30.0, 30.0, 250.0, 400.0);
        }
    }

    /// Deduplicates and resolves requested `inputs` to physical endpoint IDs, optionally using
    /// `pre_resolved_auto_id` to avoid redundant device enumeration.
    fn resolve_effective_configs(
        inputs: &[RustAudioInput],
        pre_resolved_auto_id: Option<String>,
    ) -> Vec<(RustAudioInput, String)> {
        let current_auto_def =
            pre_resolved_auto_id.or_else(|| Self::resolve_physical_input_id("AUTO"));
        let mut effective_configs: Vec<(RustAudioInput, String)> = Vec::new();

        // 1. Prioritize AUTO inputs first
        for inp in inputs {
            if inp.device_id == "AUTO" {
                let auto_res_id = current_auto_def
                    .clone()
                    .unwrap_or_else(|| "AUTO".to_string());
                if !effective_configs.iter().any(|(_, r)| r == &auto_res_id) {
                    effective_configs.push((inp.clone(), auto_res_id));
                }
            }
        }

        // 2. Add specific physical devices whose endpoints are not already claimed by AUTO
        for inp in inputs {
            if inp.device_id != "AUTO" {
                if let Some(res_id) = Self::resolve_physical_input_id(&inp.device_id) {
                    let already_claimed = effective_configs.iter().any(|(c, r)| {
                        r == &res_id
                            || (c.device_id == "AUTO" && current_auto_def.as_ref() == Some(&res_id))
                    });
                    if !already_claimed {
                        effective_configs.push((inp.clone(), res_id));
                    }
                }
            }
        }

        effective_configs
    }

    /// Opens and starts a physical capture device node for `inp` at `sample_rate` using `target_resolved_id`.
    ///
    /// # Errors
    /// Returns an error string if creating the underlying [`DeviceCaptureNode`] fails.
    fn open_physical_input_node(
        sample_rate: u32,
        inp: &RustAudioInput,
        target_resolved_id: &str,
    ) -> Result<ActiveInputNode, String> {
        crate::map_log!(
            3,
            "[INPUT] Opening physical capture node '{}' (resolved='{}', sr={})",
            inp.device_id,
            target_resolved_id,
            sample_rate
        );
        let c_dev = if target_resolved_id == "AUTO" {
            None
        } else {
            CString::new(target_resolved_id).ok()
        };

        let (capture_node, consumer) =
            DeviceCaptureNode::new(sample_rate, 1, 512, c_dev.as_deref()).map_err(|e| {
                crate::map_log!(
                    1,
                    "[INPUT] Failed to create capture device '{}' (resolved='{}', code={})",
                    inp.device_id,
                    target_resolved_id,
                    e
                );
                format!("Failed to create capture device: code {}", e)
            })?;

        if let Err(code) = capture_node.start() {
            crate::map_log!(
                2,
                "[INPUT] Failed to start capture node '{}' (resolved='{}', code={})",
                inp.device_id,
                target_resolved_id,
                code
            );
        }

        let mut ducker = AutoDucker::new(sample_rate);
        Self::apply_ducker_params(&mut ducker, &inp.config);

        Ok(ActiveInputNode {
            device_id: inp.device_id.clone(),
            resolved_id: target_resolved_id.to_string(),
            config: inp.config.clone(),
            capture_node,
            consumer,
            ducker,
            scratch_buffer: vec![0.0; Self::DEFAULT_SCRATCH_FRAMES],
        })
    }

    /// Resolves and opens newly requested capture hardware devices in `inputs` off `map-engine-clock`,
    /// reusing any endpoints already present in `existing_open` at `sample_rate` with optional `pre_resolved_auto_id`.
    ///
    /// # Errors
    /// Returns an error string if opening any newly required capture device fails.
    pub fn prepare_inputs_off_rt(
        sample_rate: u32,
        existing_open: &[(String, String)],
        inputs: Vec<RustAudioInput>,
        pre_resolved_auto_id: Option<String>,
    ) -> Result<PreparedInputs, String> {
        crate::map_log!(
            3,
            "[INPUT] Preparing {} requested inputs off-RT (existing_open={})",
            inputs.len(),
            existing_open.len()
        );
        let effective_configs = Self::resolve_effective_configs(&inputs, pre_resolved_auto_id);
        let mut updates = Vec::with_capacity(effective_configs.len());
        let mut new_nodes = Vec::new();

        for (inp, target_resolved_id) in effective_configs {
            let already_open = existing_open.iter().any(|(dev_id, res_id)| {
                dev_id == &inp.device_id
                    && (res_id == &target_resolved_id
                        || (cfg!(target_arch = "wasm32")
                            && dev_id == "AUTO"
                            && res_id == "AUTO"
                            && target_resolved_id == "default"))
            });
            updates.push((
                inp.device_id.clone(),
                target_resolved_id.clone(),
                inp.config.clone(),
            ));
            if !already_open {
                new_nodes.push(Self::open_physical_input_node(
                    sample_rate,
                    &inp,
                    &target_resolved_id,
                )?);
            }
        }

        crate::map_log!(
            4,
            "[INPUT] Prepared inputs batch (updates={}, new_nodes={})",
            updates.len(),
            new_nodes.len()
        );

        Ok(PreparedInputs {
            desired_inputs: inputs,
            updates,
            new_nodes,
        })
    }

    /// Swaps pre-opened capture nodes from `batch` into `active_inputs` in O(N), returning evicted nodes
    /// so OS device teardown runs on caller / `map-reaper`.
    pub fn apply_prepared_inputs(&mut self, batch: PreparedInputs) -> Vec<ActiveInputNode> {
        self.inputs = batch.desired_inputs;
        let mut kept = Vec::with_capacity(self.active_inputs.len() + batch.new_nodes.len());
        let mut evicted = Vec::new();

        for mut node in self.active_inputs.drain(..) {
            if let Some((_, target_res_id, cfg)) = batch.updates.iter().find(|(dev_id, res_id, _)| {
                *dev_id == node.device_id
                    && (*res_id == node.resolved_id
                        || (cfg!(target_arch = "wasm32")
                            && *dev_id == "AUTO"
                            && node.resolved_id == "AUTO"
                            && *res_id == "default"))
            }) {
                node.resolved_id = target_res_id.clone();
                node.config = cfg.clone();
                Self::apply_ducker_params(&mut node.ducker, cfg);
                kept.push(node);
            } else {
                node.capture_node.is_active.store(false, std::sync::atomic::Ordering::Release);
                evicted.push(node);
            }
        }

        for new_node in batch.new_nodes {
            let dup = kept
                .iter()
                .any(|n| n.resolved_id == new_node.resolved_id && n.device_id == new_node.device_id);
            if dup {
                evicted.push(new_node);
            } else {
                kept.push(new_node);
            }
        }

        self.active_inputs = kept;
        crate::map_log!(
            3,
            "[INPUT] Applied prepared inputs (active={}, evicted={})",
            self.active_inputs.len(),
            evicted.len()
        );
        evicted
    }

    /// Configures runtime parameters (`config`) for an active capture node identified by `device_id`
    /// without reopening hardware.
    ///
    /// # Errors
    /// Returns an error string if no configured or active input matches `device_id`.
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
            Self::apply_ducker_params(&mut node.ducker, &config);
            crate::map_log!(
                3,
                "[INPUT] Configured active input '{}' (vol={}, monitor_direct={}, ducking={})",
                device_id,
                config.volume,
                config.monitor_direct,
                config.ducking.as_ref().is_some_and(|d| d.enabled)
            );
            Ok(())
        } else if self.inputs.iter().any(|n| n.device_id == device_id) {
            crate::map_log!(
                3,
                "[INPUT] Updated desired config for pending input '{}'",
                device_id
            );
            Ok(())
        } else {
            crate::map_log!(2, "[INPUT] configure_input: device_id '{}' not found", device_id);
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
    /// - Drains lock-free SPSC consumer queues into per-node scratch buffers.
    /// - Scales by per-input capture volume.
    /// - Computes sidechain Auto-Ducking with multi-microphone max-attenuation (min-gain) arbitration.
    /// - Accumulates pure voice into `scratch_voice_out` unconditionally (for `AudioOutputSource::VoiceOnly`).
    /// - Applies arbitrated ducking envelope to `music_buffer` without compounding across mics.
    /// - Injects direct monitoring voice audio into `music_buffer` for nodes with `monitor_direct == true`.
    pub fn process(&mut self, music_buffer: &mut [f32], scratch_voice_out: &mut [f32]) {
        let frame_count = music_buffer.len() / self.channels;
        let sample_count = music_buffer.len();

        scratch_voice_out.fill(0.0);

        if self.active_inputs.is_empty() {
            return;
        }

        if self.ducking_envelope.len() < frame_count {
            self.ducking_envelope.resize(frame_count, 1.0);
            self.node_envelope.resize(frame_count, 1.0);
        }
        self.ducking_envelope[..frame_count].fill(1.0);
        let mut any_ducking = false;

        for node in &mut self.active_inputs {
            node.drain_live_edge_to_scratch(frame_count);

            // Sidechain auto-ducking with multi-microphone arbitration (taking maximum attenuation / minimum gain)
            if let Some(ref ducking) = node.config.ducking {
                if ducking.enabled {
                    any_ducking = true;
                    node.ducker.compute_gain_envelope(
                        &node.scratch_buffer[..frame_count],
                        &mut self.node_envelope[..frame_count],
                    );
                    for k in 0..frame_count {
                        self.ducking_envelope[k] = self.ducking_envelope[k].min(self.node_envelope[k]);
                    }
                }
            }

            // Unconditional Voice Only bus accumulation (pure voice audio at capture volume)
            let voice_out_len = scratch_voice_out.len().min(sample_count);
            mix_mono_frames_into_interleaved(
                &node.scratch_buffer,
                &mut scratch_voice_out[..voice_out_len],
                frame_count,
                self.channels,
                1.0,
            );
        }

        // Apply arbitrated ducking envelope to music bus ONLY (maximum attenuation, never cascading across mics)
        if any_ducking {
            for k in 0..frame_count {
                let g = self.ducking_envelope[k];
                if (g - 1.0).abs() > 1e-4 {
                    for c in 0..self.channels {
                        music_buffer[k * self.channels + c] *= g;
                    }
                }
            }
        }

        // Direct pass-through monitoring: inject voice into master mix (music_buffer / super_flow) AFTER music ducking
        for node in &self.active_inputs {
            if node.config.monitor_direct {
                let mon_vol = node.config.monitor_volume.max(0.0);
                let music_out_len = music_buffer.len().min(sample_count);
                mix_mono_frames_into_interleaved(
                    &node.scratch_buffer,
                    &mut music_buffer[..music_out_len],
                    frame_count,
                    self.channels,
                    mon_vol,
                );
            }
        }
    }

    /// Returns whether any active input ducker is currently attenuating the music bus.
    #[inline]
    pub fn is_ducking_active(&self) -> bool {
        self.active_inputs.iter().any(|n| n.ducker.is_ducking())
    }

    /// Returns the highest instantaneous RMS signal level in dB across all active microphone inputs.
    #[inline]
    pub fn last_rms_db(&self) -> f32 {
        self.active_inputs
            .iter()
            .map(|n| n.ducker.last_rms_db())
            .fold(-100.0f32, |acc, val| acc.max(val))
    }
}
