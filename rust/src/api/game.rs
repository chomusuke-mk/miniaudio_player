//! High-level Game Audio API exposed to Flutter/Dart via flutter_rust_bridge.
//!
//! Provides polyphonic voice pooling (up to 64 concurrent voices),
//! voice stealing, pre-decoded PCM in RAM, one-shots with pitch/volume jitter,
//! synchronous stem playback, dynamic 3D spatial audio with Doppler, and bullet-time TimeScale.

use std::ffi::CString;
use std::sync::Arc;

use crate::core::voice_pool_coordinator::VoicePoolCoordinator;

use super::types::*;

pub struct RustVoicePool {
    coordinator: Arc<VoicePoolCoordinator>,
}

impl RustVoicePool {
    #[flutter_rust_bridge::frb(sync)]
    pub fn new(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        playback_device_id: Option<String>,
        max_voices: usize,
    ) -> Result<RustVoicePool, String> {
        let dev_id_c = playback_device_id.map(|s| CString::new(s).unwrap_or_default());
        let dev_id_ptr = dev_id_c.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

        let coord = VoicePoolCoordinator::new(
            sample_rate,
            channels,
            period_size,
            dev_id_ptr,
            max_voices,
        ).map_err(|e| format!("Failed to create voice pool coordinator: error {}", e))?;

        Ok(RustVoicePool {
            coordinator: Arc::new(*coord),
        })
    }

    pub fn load_sound(&self, bytes: Vec<u8>) -> Result<RustSoundBufferInfo, String> {
        let (id, buf) = self.coordinator.load_sound(&bytes)?;
        Ok(RustSoundBufferInfo {
            id,
            sample_rate: buf.sample_rate,
            channels: buf.channels as u32,
            duration_ms: buf.duration_ms as i64,
            frame_count: buf.frame_count(),
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn unload_sound(&self, buffer_id: u64) -> bool {
        self.coordinator.unload_sound(buffer_id)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn play_sound(
        &self,
        buffer_id: u64,
        volume: f32,
        pitch: f32,
        priority: u8,
        looping: bool,
        emitter: Option<RustSpatialEmitter>,
    ) -> Result<u32, String> {
        self.coordinator.play_sound(
            buffer_id,
            volume,
            pitch,
            priority,
            looping,
            emitter.map(Into::into),
        )
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn play_one_shot(
        &self,
        buffer_id: u64,
        volume: f32,
        pitch: f32,
        pitch_jitter: f32,
        volume_jitter: f32,
        priority: u8,
        emitter: Option<RustSpatialEmitter>,
    ) -> Result<u32, String> {
        self.coordinator.play_one_shot(
            buffer_id,
            volume,
            pitch,
            pitch_jitter,
            volume_jitter,
            priority,
            emitter.map(Into::into),
        )
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn play_stems(
        &self,
        buffer_ids: Vec<u64>,
        volumes: Vec<f32>,
        looping: bool,
    ) -> Result<Vec<u32>, String> {
        self.coordinator.play_stems(&buffer_ids, &volumes, looping)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stop_voice(&self, voice_id: u32) {
        self.coordinator.stop_voice(voice_id);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stop_all(&self) {
        self.coordinator.stop_all();
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_voice_volume(&self, voice_id: u32, volume: f32) {
        self.coordinator.set_voice_volume(voice_id, volume);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_voice_pitch(&self, voice_id: u32, pitch: f32) {
        self.coordinator.set_voice_pitch(voice_id, pitch);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_voice_emitter(&self, voice_id: u32, emitter: Option<RustSpatialEmitter>) {
        self.coordinator.set_voice_emitter(voice_id, emitter.map(Into::into));
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_master_volume(&self, volume: f32) {
        self.coordinator.set_master_volume(volume);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_time_scale(&self, scale: f32) {
        self.coordinator.set_time_scale(scale);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_policy(&self, policy: RustVoiceStealingPolicy) {
        self.coordinator.set_policy(policy.into());
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_listener(&self, listener: RustSpatialListener) {
        self.coordinator.set_listener(listener.into());
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn active_voices_count(&self) -> u32 {
        self.coordinator.active_voices_count()
    }
}
