//! Real-time decoupled Microphone / Line-in audio capture node.
//!
//! Feeds captured microphone audio into a lock-free SPSC queue for auto-ducking sidechain
//! evaluation and composite master mixing.

use std::ffi::CStr;
use std::os::raw::c_void;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::bridge::ffi::{
    map_capture_device_create, map_device_destroy, map_device_start, map_device_stop,
    MapDeviceContext, PcmCaptureHeader,
};

/// Real-time capture receiver receiving raw PCM frames from miniaudio and pushing to an SPSC queue.
#[repr(C)]
pub struct CaptureReceiver {
    /// C-compatible function pointer header.
    pub header: PcmCaptureHeader,
    /// Ring buffer producer pushing captured audio to the engine thread.
    pub producer: rtrb::Producer<f32>,
    /// Atomic flag indicating whether capture is active.
    pub is_active: Arc<AtomicBool>,
    /// Number of channels in the captured stream.
    pub channels: usize,
}

unsafe impl Send for CaptureReceiver {}

/// C trampoline forwarding captured PCM frames to [`CaptureReceiver::on_captured_pcm`].
///
/// # Safety
/// `ptr` must point to a valid [`CaptureReceiver`] and `input` must point to at least
/// `count * (*ptr).channels` readable `f32` samples.
pub unsafe extern "C" fn capture_receiver_capture_trampoline(
    ptr: *mut c_void,
    input: *const f32,
    count: usize,
) {
    if ptr.is_null() || input.is_null() || count == 0 {
        return;
    }
    let r = &mut *(ptr as *mut CaptureReceiver);
    let total_samples = count * r.channels;
    let in_slice = std::slice::from_raw_parts(input, total_samples);
    r.on_captured_pcm(in_slice);
}

/// C trampoline for capture notifications (no-op).
///
/// # Safety
/// Invoked by C audio device notification callbacks; `_ptr` and `_notif` are unused.
pub unsafe extern "C" fn capture_receiver_notif_trampoline(_ptr: *mut c_void, _notif: i32) {}

impl CaptureReceiver {
    /// Processes incoming captured PCM frames from `in_slice` and enqueues them into the SPSC buffer.
    #[inline]
    pub fn on_captured_pcm(&mut self, in_slice: &[f32]) {
        if in_slice.is_empty() || !self.is_active.load(Ordering::Relaxed) {
            return;
        }

        let slots = self.producer.slots();
        let to_write = slots.min(in_slice.len());
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

/// Hardware capture node encapsulating device creation, start, stop, and lifecycle.
pub struct DeviceCaptureNode {
    /// Raw pointer to the native miniaudio device context.
    pub device_ctx: *mut MapDeviceContext,
    /// Raw pointer to the heap-allocated [`CaptureReceiver`].
    pub receiver_ptr: *mut CaptureReceiver,
    /// Flag indicating if capture is running.
    pub is_active: Arc<AtomicBool>,
    /// Audio sample rate in Hz.
    pub sample_rate: u32,
    /// Audio channel count.
    pub channels: u32,
}

unsafe impl Send for DeviceCaptureNode {}
unsafe impl Sync for DeviceCaptureNode {}

impl Drop for DeviceCaptureNode {
    /// Stops capture and destroys the native capture device and receiver resources.
    fn drop(&mut self) {
        self.stop();

        if !self.device_ctx.is_null() {
            crate::map_log!(
                4,
                "[CAPTURE] Destroying capture device (sr={}, ch={})",
                self.sample_rate,
                self.channels
            );
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
    /// Initializes a hardware audio capture device with an asynchronous lock-free SPSC queue.
    ///
    /// Uses `sample_rate` (defaulting to 44100 Hz if 0), `channels` (defaulting to 1 if 0),
    /// `period_size` (defaulting to 512 frames if 0), and optional OS `capture_device_id`.
    ///
    /// # Errors
    /// Returns the native miniaudio error code if the capture device cannot be created.
    pub fn new(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        capture_device_id: Option<&CStr>,
    ) -> Result<(Box<Self>, rtrb::Consumer<f32>), i32> {
        let sr = if sample_rate > 0 { sample_rate } else { 44100 };
        let ch = if channels > 0 { channels } else { 1 };
        let period = if period_size > 0 { period_size } else { 512 };

        let dev_label = capture_device_id
            .map(|c| c.to_string_lossy().into_owned())
            .unwrap_or_else(|| "AUTO".to_string());
        crate::map_log!(
            4,
            "[CAPTURE] Creating capture device '{}' (sr={}, ch={}, period={})",
            dev_label,
            sr,
            ch,
            period
        );

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
        let capture_device_ptr = capture_device_id
            .map(|c| c.as_ptr())
            .unwrap_or(std::ptr::null());

        let mut dev_res = 0;
        let device_ctx = unsafe {
            map_capture_device_create(
                sr,
                ch,
                period,
                capture_device_ptr,
                receiver_ptr as *mut c_void,
                &mut dev_res,
            )
        };

        if device_ctx.is_null() || dev_res != 0 {
            crate::map_log!(
                1,
                "[CAPTURE] Failed to create capture device '{}' (sr={}, ch={}, period={}, code={})",
                dev_label,
                sr,
                ch,
                period,
                dev_res
            );
            unsafe {
                drop(Box::from_raw(receiver_ptr));
            }
            return Err(dev_res);
        }

        crate::map_log!(
            3,
            "[CAPTURE] Created capture device '{}' (sr={}, ch={}, period={})",
            dev_label,
            sr,
            ch,
            period
        );

        let node = Box::new(Self {
            device_ctx,
            receiver_ptr,
            is_active,
            sample_rate: sr,
            channels: ch,
        });

        Ok((node, consumer))
    }

    /// Starts capturing audio frames from the hardware device.
    ///
    /// # Errors
    /// Returns the native miniaudio error code if starting the capture device fails.
    pub fn start(&self) -> Result<(), i32> {
        self.is_active.store(true, Ordering::Release);
        if !self.device_ctx.is_null() {
            let res = unsafe { map_device_start(self.device_ctx) };
            if res != 0 {
                self.is_active.store(false, Ordering::Release);
                crate::map_log!(
                    1,
                    "[CAPTURE] Failed to start capture device (sr={}, ch={}, code={})",
                    self.sample_rate,
                    self.channels,
                    res
                );
                return Err(res);
            }
            crate::map_log!(
                3,
                "[CAPTURE] Started capture device (sr={}, ch={})",
                self.sample_rate,
                self.channels
            );
        }
        Ok(())
    }

    /// Stops audio capture and pauses hardware delivery.
    pub fn stop(&self) {
        let was_active = self.is_active.swap(false, Ordering::AcqRel);
        if !self.device_ctx.is_null() {
            let res = unsafe { map_device_stop(self.device_ctx) };
            if res != 0 {
                crate::map_log!(
                    2,
                    "[CAPTURE] map_device_stop returned non-zero code={} (sr={}, ch={})",
                    res,
                    self.sample_rate,
                    self.channels
                );
            } else if was_active {
                crate::map_log!(
                    3,
                    "[CAPTURE] Stopped capture device (sr={}, ch={})",
                    self.sample_rate,
                    self.channels
                );
            }
        }
    }

    /// Returns whether an asynchronous capture session (e.g. Web `getUserMedia`) failed or was denied.
    #[inline]
    pub fn is_failed(&self) -> bool {
        #[cfg(target_arch = "wasm32")]
        {
            crate::bridge::ffi::wasm_is_capture_device_failed(self.device_ctx)
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            false
        }
    }
}
