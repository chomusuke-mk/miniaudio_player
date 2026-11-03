//! Microphone Capture & Auto-Ducking Domain Manager (`InputManager`).
//!
//! Encapsulates hardware capture node, real-time voice RMS detector,
//! sidechain auto-ducking dynamics processor, and low-latency direct monitoring.

use std::ffi::CString;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use crate::core::capture::DeviceCaptureNode;
use crate::dsp::ducking::AutoDucker;

pub struct InputManager {
    pub capture_node: Arc<RwLock<Option<Box<DeviceCaptureNode>>>>,
    pub mic_consumer: Arc<Mutex<Option<rtrb::Consumer<f32>>>>,
    pub ducker: AutoDucker,
    pub mic_enabled: Arc<AtomicBool>,
    pub mic_volume: Arc<AtomicU32>,
    pub mic_monitor_direct: Arc<AtomicBool>,
    pub mic_monitor_volume: Arc<AtomicU32>,
    pub scratch_mic: Vec<f32>,
    pub sample_rate: u32,
    pub channels: usize,
}

impl InputManager {
    pub fn new(sample_rate: u32, channels: usize) -> Self {
        Self {
            capture_node: Arc::new(RwLock::new(None)),
            mic_consumer: Arc::new(Mutex::new(None)),
            ducker: AutoDucker::new(sample_rate),
            mic_enabled: Arc::new(AtomicBool::new(false)),
            mic_volume: Arc::new(AtomicU32::new(1.0f32.to_bits())),
            mic_monitor_direct: Arc::new(AtomicBool::new(false)),
            mic_monitor_volume: Arc::new(AtomicU32::new(1.0f32.to_bits())),
            scratch_mic: vec![0.0; 2048 * channels],
            sample_rate,
            channels,
        }
    }

    // =========================================================================
    // Direct Input Commands
    // =========================================================================

    pub fn enable_microphone(
        &mut self,
        device_id: Option<String>,
        volume: f32,
        ducking_enabled: bool,
        ducking_db: f32,
        threshold_db: f32,
        attack_ms: f32,
        hold_ms: f32,
        release_ms: f32,
        monitor_direct: bool,
        monitor_volume: f32,
    ) -> Result<(), String> {
        self.disable_microphone();

        let c_dev = match device_id {
            Some(s) if !s.is_empty() => Some(CString::new(s).map_err(|e| e.to_string())?),
            _ => None,
        };
        let c_ptr = c_dev.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

        let (node, consumer) = DeviceCaptureNode::new(self.sample_rate, 1, 512, c_ptr)
            .map_err(|e| format!("Failed to create capture device: code {}", e))?;

        let _ = node.start();
        *self.capture_node.write().unwrap() = Some(node);
        *self.mic_consumer.lock().unwrap() = Some(consumer);

        self.mic_enabled.store(true, Ordering::Release);
        self.mic_volume.store(volume.to_bits(), Ordering::Relaxed);
        self.mic_monitor_direct.store(monitor_direct, Ordering::Relaxed);
        self.mic_monitor_volume.store(monitor_volume.to_bits(), Ordering::Relaxed);

        self.ducker.set_params(
            ducking_enabled,
            ducking_db,
            threshold_db,
            attack_ms,
            hold_ms,
            release_ms,
        );

        Ok(())
    }

    pub fn disable_microphone(&mut self) {
        self.mic_enabled.store(false, Ordering::Release);
        if let Some(node) = self.capture_node.write().unwrap().take() {
            let _ = node.stop();
        }
        *self.mic_consumer.lock().unwrap() = None;
    }

    #[inline]
    pub fn set_volume(&mut self, volume: f32) {
        self.mic_volume.store(volume.max(0.0).to_bits(), Ordering::Relaxed);
    }

    #[inline]
    pub fn set_ducking(
        &mut self,
        enabled: bool,
        ducking_db: f32,
        threshold_db: f32,
        attack_ms: f32,
        hold_ms: f32,
        release_ms: f32,
    ) {
        self.ducker.set_params(
            enabled,
            ducking_db,
            threshold_db,
            attack_ms,
            hold_ms,
            release_ms,
        );
    }

    #[inline]
    pub fn set_direct_monitoring(&mut self, enabled: bool, volume: f32) {
        self.mic_monitor_direct.store(enabled, Ordering::Relaxed);
        self.mic_monitor_volume.store(volume.max(0.0).to_bits(), Ordering::Relaxed);
    }

    // =========================================================================
    // Real-Time Audio Processing
    // =========================================================================

    /// Processes microphone capture:
    /// - Drains lock-free SPSC microphone queue.
    /// - Applies sidechain Auto-Ducking on `music_buffer`.
    /// - If direct monitoring is enabled, fills `scratch_voice_out` with microphone audio.
    pub fn process(&mut self, music_buffer: &mut [f32], scratch_voice_out: &mut [f32]) {
        let frame_count = music_buffer.len() / self.channels;
        let sample_count = music_buffer.len();

        scratch_voice_out.fill(0.0);

        if !self.mic_enabled.load(Ordering::Relaxed) {
            return;
        }

        if self.scratch_mic.len() < frame_count {
            self.scratch_mic.resize(frame_count, 0.0);
        }
        self.scratch_mic[..frame_count].fill(0.0);

        let mic_vol = f32::from_bits(self.mic_volume.load(Ordering::Relaxed));

        if let Ok(mut guard) = self.mic_consumer.try_lock() {
            if let Some(ref mut consumer) = *guard {
                let mut read_idx = 0;
                while read_idx < frame_count {
                    if let Ok(sample) = consumer.pop() {
                        self.scratch_mic[read_idx] = sample * mic_vol;
                        read_idx += 1;
                    } else {
                        break;
                    }
                }
            }
        }

        // Apply Auto-Ducking on music_buffer using scratch_mic as sidechain
        self.ducker.process_sidechain(&self.scratch_mic[..frame_count], music_buffer, self.channels);

        // Direct monitoring output
        if self.mic_monitor_direct.load(Ordering::Relaxed) {
            let mon_vol = f32::from_bits(self.mic_monitor_volume.load(Ordering::Relaxed));
            let out_len = scratch_voice_out.len().min(sample_count);

            for f in 0..frame_count {
                let val = self.scratch_mic[f] * mon_vol;
                let out_idx = f * self.channels;
                if out_idx + 1 < out_len {
                    scratch_voice_out[out_idx] = val;
                    scratch_voice_out[out_idx + 1] = val;
                }
            }
        }
    }

    #[inline]
    pub fn is_ducking_active(&self) -> bool {
        self.ducker.is_ducking()
    }

    #[inline]
    pub fn last_rms_db(&self) -> f32 {
        self.ducker.last_rms_db()
    }
}
