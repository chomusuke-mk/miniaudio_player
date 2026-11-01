//! VoicePool Coordinator managing polyphonic hardware mixing, wait-free command dispatch,
//! sound buffer registry, and 3D spatial audio for game audio engines.

use std::collections::HashMap;
use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};

use crate::bridge::ffi::{
    map_device_create, map_device_destroy, map_device_start, map_device_stop, MapDeviceContext,
};
use crate::core::renderer::PcmRendererHeader;
use crate::dsp::spatial::{SpatialEmitter, SpatialListener};
use crate::dsp::voice_pool::{
    pseudo_random_jitter, SoundBuffer, VoicePool, VoiceStealingPolicy,
};

#[derive(Clone, Debug)]
pub enum VoicePoolCommand {
    PlaySound {
        voice_id: u32,
        buffer: SoundBuffer,
        volume: f32,
        pitch: f32,
        priority: u8,
        looping: bool,
        emitter: Option<SpatialEmitter>,
    },
    StopVoice(u32),
    StopAll,
    SetMasterVolume(f32),
    SetTimeScale(f32),
    SetPolicy(VoiceStealingPolicy),
    SetListener(SpatialListener),
    SetVoiceVolume {
        voice_id: u32,
        volume: f32,
    },
    SetVoicePitch {
        voice_id: u32,
        pitch: f32,
    },
    SetVoiceEmitter {
        voice_id: u32,
        emitter: Option<SpatialEmitter>,
    },
}

#[repr(C)]
pub struct VoicePoolRenderer {
    pub header: PcmRendererHeader,
    pub voice_pool: VoicePool,
    pub cmd_consumer: rtrb::Consumer<VoicePoolCommand>,
    pub active_voices: Arc<AtomicU32>,
    pub channels: usize,
    pub sample_rate: u32,
    pub listener: SpatialListener,
}

unsafe impl Send for VoicePoolRenderer {}

pub unsafe extern "C" fn voice_pool_renderer_render_trampoline(
    ptr: *mut c_void,
    output: *mut f32,
    count: usize,
) {
    let r = &mut *(ptr as *mut VoicePoolRenderer);
    r.render_pcm(output, count);
}

pub unsafe extern "C" fn voice_pool_renderer_notif_trampoline(
    _ptr: *mut c_void,
    _notif: i32,
) {}

impl VoicePoolRenderer {
    #[inline]
    pub fn render_pcm(&mut self, output_frames: *mut f32, frame_count: usize) {
        if output_frames.is_null() || frame_count == 0 {
            return;
        }

        let total_samples = frame_count * self.channels;
        let out_slice = unsafe { std::slice::from_raw_parts_mut(output_frames, total_samples) };

        // 1. Drain pending wait-free commands
        let available = self.cmd_consumer.slots();
        if available > 0 {
            if let Ok(chunk) = self.cmd_consumer.read_chunk(available) {
                let (s1, s2) = chunk.as_slices();
                for cmd in s1.iter().chain(s2.iter()) {
                    match cmd {
                        VoicePoolCommand::PlaySound {
                            voice_id,
                            buffer,
                            volume,
                            pitch,
                            priority,
                            looping,
                            emitter,
                        } => {
                            self.voice_pool.play_sound_with_id(
                                *voice_id,
                                buffer.clone(),
                                *volume,
                                *pitch,
                                *priority,
                                *looping,
                                *emitter,
                            );
                        }
                        VoicePoolCommand::StopVoice(id) => {
                            self.voice_pool.stop_voice(*id, self.sample_rate);
                        }
                        VoicePoolCommand::StopAll => {
                            self.voice_pool.stop_all();
                        }
                        VoicePoolCommand::SetMasterVolume(v) => {
                            self.voice_pool.set_master_volume(*v);
                        }
                        VoicePoolCommand::SetTimeScale(s) => {
                            self.voice_pool.set_time_scale(*s);
                        }
                        VoicePoolCommand::SetPolicy(p) => {
                            self.voice_pool.set_policy(*p);
                        }
                        VoicePoolCommand::SetListener(l) => {
                            self.listener = *l;
                        }
                        VoicePoolCommand::SetVoiceVolume { voice_id, volume } => {
                            self.voice_pool.set_voice_volume(*voice_id, *volume);
                        }
                        VoicePoolCommand::SetVoicePitch { voice_id, pitch } => {
                            self.voice_pool.set_voice_pitch(*voice_id, *pitch);
                        }
                        VoicePoolCommand::SetVoiceEmitter { voice_id, emitter } => {
                            self.voice_pool.set_voice_emitter(*voice_id, *emitter);
                        }
                    }
                }
                chunk.commit_all();
            }
        }

        // 2. Clear output buffer to zero
        out_slice.fill(0.0);

        // 3. Render and mix voices
        self.voice_pool.render_pcm(
            out_slice,
            self.channels,
            self.sample_rate,
            &self.listener,
        );

        // 4. Update atomic active voice count
        self.active_voices.store(
            self.voice_pool.active_voice_count() as u32,
            Ordering::Relaxed,
        );
    }
}

pub struct VoicePoolCoordinator {
    pub device_ctx: *mut MapDeviceContext,
    pub renderer_ptr: *mut VoicePoolRenderer,
    pub cmd_producer: Arc<RwLock<rtrb::Producer<VoicePoolCommand>>>,
    pub buffer_registry: Arc<RwLock<HashMap<u64, SoundBuffer>>>,
    pub next_buffer_id: AtomicU64,
    pub next_voice_id: AtomicU32,
    pub active_voices: Arc<AtomicU32>,
    pub sample_rate: u32,
    pub channels: u32,
}

unsafe impl Send for VoicePoolCoordinator {}
unsafe impl Sync for VoicePoolCoordinator {}

impl Drop for VoicePoolCoordinator {
    fn drop(&mut self) {
        if !self.device_ctx.is_null() {
            unsafe {
                map_device_stop(self.device_ctx);
                map_device_destroy(self.device_ctx);
            }
            self.device_ctx = std::ptr::null_mut();
        }

        if !self.renderer_ptr.is_null() {
            unsafe {
                drop(Box::from_raw(self.renderer_ptr));
            }
            self.renderer_ptr = std::ptr::null_mut();
        }
    }
}

impl VoicePoolCoordinator {
    pub fn new(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        playback_device_id: *const c_char,
        max_voices: usize,
    ) -> Result<Box<Self>, i32> {
        let sr = if sample_rate > 0 { sample_rate } else { 44100 };
        let ch = if channels > 0 { channels } else { 2 };
        let period = if period_size > 0 { period_size } else { 1024 };

        let (producer, consumer) = rtrb::RingBuffer::new(512);
        let active_voices = Arc::new(AtomicU32::new(0));

        let renderer = VoicePoolRenderer {
            header: PcmRendererHeader {
                render_fn: voice_pool_renderer_render_trampoline,
                notif_fn: voice_pool_renderer_notif_trampoline,
            },
            voice_pool: VoicePool::new(max_voices, VoiceStealingPolicy::default()),
            cmd_consumer: consumer,
            active_voices: active_voices.clone(),
            channels: ch as usize,
            sample_rate: sr,
            listener: SpatialListener::default(),
        };

        let renderer_ptr = Box::into_raw(Box::new(renderer));

        let mut dev_res = 0;
        let device_ctx = unsafe {
            map_device_create(
                sr,
                ch,
                period,
                playback_device_id,
                renderer_ptr as *mut c_void,
                &mut dev_res,
            )
        };

        if device_ctx.is_null() || dev_res != 0 {
            unsafe {
                drop(Box::from_raw(renderer_ptr));
            }
            return Err(dev_res);
        }

        let start_res = unsafe { map_device_start(device_ctx) };
        if start_res != 0 {
            unsafe {
                map_device_destroy(device_ctx);
                drop(Box::from_raw(renderer_ptr));
            }
            return Err(start_res);
        }

        Ok(Box::new(Self {
            device_ctx,
            renderer_ptr,
            cmd_producer: Arc::new(RwLock::new(producer)),
            buffer_registry: Arc::new(RwLock::new(HashMap::new())),
            next_buffer_id: AtomicU64::new(1),
            next_voice_id: AtomicU32::new(1),
            active_voices,
            sample_rate: sr,
            channels: ch,
        }))
    }

    /// Loads an encoded audio file/bytes into pre-decoded PCM RAM and stores it in the buffer registry.
    pub fn load_sound(&self, bytes: &[u8]) -> Result<(u64, SoundBuffer), String> {
        let buffer = SoundBuffer::decode_from_bytes(bytes)?;
        let id = self.next_buffer_id.fetch_add(1, Ordering::Relaxed);
        let mut reg = self.buffer_registry.write().unwrap();
        reg.insert(id, buffer.clone());
        Ok((id, buffer))
    }

    /// Unloads a pre-decoded buffer from RAM.
    pub fn unload_sound(&self, buffer_id: u64) -> bool {
        let mut reg = self.buffer_registry.write().unwrap();
        reg.remove(&buffer_id).is_some()
    }

    /// Plays a sound by buffer ID.
    pub fn play_sound(
        &self,
        buffer_id: u64,
        volume: f32,
        pitch: f32,
        priority: u8,
        looping: bool,
        emitter: Option<SpatialEmitter>,
    ) -> Result<u32, String> {
        let buffer = {
            let reg = self.buffer_registry.read().unwrap();
            reg.get(&buffer_id)
                .cloned()
                .ok_or_else(|| format!("SoundBuffer ID {} not found", buffer_id))?
        };

        let voice_id = self.next_voice_id.fetch_add(1, Ordering::Relaxed);
        let cmd = VoicePoolCommand::PlaySound {
            voice_id,
            buffer,
            volume: volume.clamp(0.0, 2.0),
            pitch: pitch.clamp(0.1, 4.0),
            priority,
            looping,
            emitter,
        };

        if let Ok(mut prod) = self.cmd_producer.write() {
            let _ = prod.push(cmd);
        }

        Ok(voice_id)
    }

    /// Plays a one-shot sound with optional random pitch and volume jitter to prevent repetitive fatigue.
    pub fn play_one_shot(
        &self,
        buffer_id: u64,
        volume: f32,
        pitch: f32,
        pitch_jitter: f32,
        volume_jitter: f32,
        priority: u8,
        emitter: Option<SpatialEmitter>,
    ) -> Result<u32, String> {
        let seed = self.next_voice_id.load(Ordering::Relaxed);
        let eff_pitch = if pitch_jitter > 0.0 {
            let rnd = pseudo_random_jitter(seed, 1);
            pitch * (1.0 + rnd * pitch_jitter.abs())
        } else {
            pitch
        };

        let eff_vol = if volume_jitter > 0.0 {
            let rnd = pseudo_random_jitter(seed, 2);
            volume * (1.0 + rnd * volume_jitter.abs())
        } else {
            volume
        };

        self.play_sound(
            buffer_id,
            eff_vol.clamp(0.0, 2.0),
            eff_pitch.clamp(0.1, 4.0),
            priority,
            false,
            emitter,
        )
    }

    /// Triggers synchronized stem layers starting simultaneously at frame cursor 0.0.
    pub fn play_stems(
        &self,
        buffer_ids: &[u64],
        volumes: &[f32],
        looping: bool,
    ) -> Result<Vec<u32>, String> {
        if buffer_ids.is_empty() {
            return Ok(Vec::new());
        }

        let mut voice_ids = Vec::with_capacity(buffer_ids.len());
        for (i, &buf_id) in buffer_ids.iter().enumerate() {
            let vol = volumes.get(i).copied().unwrap_or(1.0);
            let vid = self.play_sound(buf_id, vol, 1.0, 128, looping, None)?;
            voice_ids.push(vid);
        }

        Ok(voice_ids)
    }

    pub fn stop_voice(&self, voice_id: u32) {
        if let Ok(mut prod) = self.cmd_producer.write() {
            let _ = prod.push(VoicePoolCommand::StopVoice(voice_id));
        }
    }

    pub fn stop_all(&self) {
        if let Ok(mut prod) = self.cmd_producer.write() {
            let _ = prod.push(VoicePoolCommand::StopAll);
        }
    }

    pub fn set_voice_volume(&self, voice_id: u32, volume: f32) {
        if let Ok(mut prod) = self.cmd_producer.write() {
            let _ = prod.push(VoicePoolCommand::SetVoiceVolume {
                voice_id,
                volume: volume.clamp(0.0, 2.0),
            });
        }
    }

    pub fn set_voice_pitch(&self, voice_id: u32, pitch: f32) {
        if let Ok(mut prod) = self.cmd_producer.write() {
            let _ = prod.push(VoicePoolCommand::SetVoicePitch {
                voice_id,
                pitch: pitch.clamp(0.1, 4.0),
            });
        }
    }

    pub fn set_voice_emitter(&self, voice_id: u32, emitter: Option<SpatialEmitter>) {
        if let Ok(mut prod) = self.cmd_producer.write() {
            let _ = prod.push(VoicePoolCommand::SetVoiceEmitter { voice_id, emitter });
        }
    }

    pub fn set_master_volume(&self, volume: f32) {
        if let Ok(mut prod) = self.cmd_producer.write() {
            let _ = prod.push(VoicePoolCommand::SetMasterVolume(volume.clamp(0.0, 2.0)));
        }
    }

    pub fn set_time_scale(&self, scale: f32) {
        if let Ok(mut prod) = self.cmd_producer.write() {
            let _ = prod.push(VoicePoolCommand::SetTimeScale(scale.clamp(0.01, 10.0)));
        }
    }

    pub fn set_policy(&self, policy: VoiceStealingPolicy) {
        if let Ok(mut prod) = self.cmd_producer.write() {
            let _ = prod.push(VoicePoolCommand::SetPolicy(policy));
        }
    }

    pub fn set_listener(&self, listener: SpatialListener) {
        if let Ok(mut prod) = self.cmd_producer.write() {
            let _ = prod.push(VoicePoolCommand::SetListener(listener));
        }
    }

    pub fn active_voices_count(&self) -> u32 {
        self.active_voices.load(Ordering::Relaxed)
    }
}
