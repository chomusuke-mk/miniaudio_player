//! Real-time decoupled Microphone / Line-in audio capture node.
//!
//! Feeds captured microphone audio into a lock-free SPSC queue for auto-ducking sidechain
//! evaluation and composite master mixing.

use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;

use crate::bridge::ffi::{
    map_capture_device_create, map_device_destroy, map_device_start, map_device_stop,
    MapDeviceContext, PcmCaptureHeader,
};

#[repr(C)]
pub struct CaptureReceiver {
    pub header: PcmCaptureHeader,
    pub producer: rtrb::Producer<f32>,
    pub is_active: Arc<AtomicBool>,
    pub channels: usize,
}

unsafe impl Send for CaptureReceiver {}

pub unsafe extern "C" fn capture_receiver_capture_trampoline(
    ptr: *mut c_void,
    input: *const f32,
    count: usize,
) {
    let r = &mut *(ptr as *mut CaptureReceiver);
    r.on_captured_pcm(input, count);
}

pub unsafe extern "C" fn capture_receiver_notif_trampoline(_ptr: *mut c_void, _notif: i32) {}

impl CaptureReceiver {
    #[inline]
    pub fn on_captured_pcm(&mut self, input_frames: *const f32, frame_count: usize) {
        if input_frames.is_null() || frame_count == 0 || !self.is_active.load(Ordering::Relaxed) {
            return;
        }

        let total_samples = frame_count * self.channels;
        let in_slice = unsafe { std::slice::from_raw_parts(input_frames, total_samples) };

        let slots = self.producer.slots();
        let to_write = slots.min(total_samples);
        if to_write > 0 {
            if let Ok(mut chunk) = self.producer.write_chunk(to_write) {
                let (s1, s2) = chunk.as_mut_slices();
                let n1 = s1.len();
                s1.copy_from_slice(&in_slice[..n1]);
                if !s2.is_empty() {
                    s2.copy_from_slice(&in_slice[n1..to_write]);
                }
                chunk.commit_all();
            }
        }
    }
}

pub struct DeviceCaptureNode {
    pub device_ctx: *mut MapDeviceContext,
    pub receiver_ptr: *mut CaptureReceiver,
    pub is_active: Arc<AtomicBool>,
    pub mic_volume: Arc<AtomicU32>,
    pub sample_rate: u32,
    pub channels: u32,
}

unsafe impl Send for DeviceCaptureNode {}
unsafe impl Sync for DeviceCaptureNode {}

impl Drop for DeviceCaptureNode {
    fn drop(&mut self) {
        self.stop();

        if !self.device_ctx.is_null() {
            unsafe {
                map_device_destroy(self.device_ctx);
            }
            self.device_ctx = std::ptr::null_mut();
        }

        if !self.receiver_ptr.is_null() {
            unsafe {
                drop(Box::from_raw(self.receiver_ptr));
            }
            self.receiver_ptr = std::ptr::null_mut();
        }
    }
}

impl DeviceCaptureNode {
    pub fn new(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        capture_device_id: *const c_char,
    ) -> Result<(Box<Self>, rtrb::Consumer<f32>), i32> {
        let sr = if sample_rate > 0 { sample_rate } else { 44100 };
        let ch = if channels > 0 { channels } else { 1 };
        let period = if period_size > 0 { period_size } else { 512 };

        let (producer, consumer) = rtrb::RingBuffer::new(65536);
        let is_active = Arc::new(AtomicBool::new(false));

        let receiver = CaptureReceiver {
            header: PcmCaptureHeader {
                capture_fn: capture_receiver_capture_trampoline,
                notif_fn: capture_receiver_notif_trampoline,
            },
            producer,
            is_active: is_active.clone(),
            channels: ch as usize,
        };

        let receiver_ptr = Box::into_raw(Box::new(receiver));

        let mut dev_res = 0;
        let device_ctx = unsafe {
            map_capture_device_create(
                sr,
                ch,
                period,
                capture_device_id,
                receiver_ptr as *mut c_void,
                &mut dev_res,
            )
        };

        if device_ctx.is_null() || dev_res != 0 {
            unsafe {
                drop(Box::from_raw(receiver_ptr));
            }
            return Err(dev_res);
        }

        let node = Box::new(Self {
            device_ctx,
            receiver_ptr,
            is_active,
            mic_volume: Arc::new(AtomicU32::new(1.0f32.to_bits())),
            sample_rate: sr,
            channels: ch,
        });

        Ok((node, consumer))
    }

    pub fn start(&self) -> Result<(), i32> {
        self.is_active.store(true, Ordering::Release);
        if !self.device_ctx.is_null() {
            let res = unsafe { map_device_start(self.device_ctx) };
            if res != 0 {
                self.is_active.store(false, Ordering::Release);
                return Err(res);
            }
        }
        Ok(())
    }

    pub fn stop(&self) {
        self.is_active.store(false, Ordering::Release);
        if !self.device_ctx.is_null() {
            unsafe {
                let _ = map_device_stop(self.device_ctx);
            }
        }
    }

    pub fn is_capturing(&self) -> bool {
        self.is_active.load(Ordering::Acquire)
    }

    pub fn set_mic_volume(&self, volume: f32) {
        let clamped = volume.clamp(0.0, 2.0);
        self.mic_volume.store(clamped.to_bits(), Ordering::Relaxed);
    }

    pub fn mic_volume(&self) -> f32 {
        f32::from_bits(self.mic_volume.load(Ordering::Relaxed))
    }

    /// Feeds simulated PCM frames for testing in headless / CI environments without audio inputs.
    pub fn supply_mock_input(&self, frames: &[f32]) {
        if !self.receiver_ptr.is_null() {
            unsafe {
                let r = &mut *self.receiver_ptr;
                r.on_captured_pcm(frames.as_ptr(), frames.len() / r.channels.max(1));
            }
        }
    }
}
