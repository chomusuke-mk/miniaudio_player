//! Multi-Output Matrix router managing Master Output, DJ CUE Headphone Pre-listening (PFL),
//! and Asynchronous Lock-Free File Recording Sinks.

use std::os::raw::c_void;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;

use crate::bridge::ffi::{
    map_device_create, map_device_destroy, map_device_start,
    map_device_stop, MapDeviceContext,
};
use crate::core::recording::{LiveRecorder, WavFormat};
use crate::core::renderer::PcmRendererHeader;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CueSource {
    StandbyTrack = 0,
    ActiveTrack = 1,
    MasterMix = 2,
}

impl From<i32> for CueSource {
    fn from(val: i32) -> Self {
        match val {
            1 => CueSource::ActiveTrack,
            2 => CueSource::MasterMix,
            _ => CueSource::StandbyTrack,
        }
    }
}

#[repr(C)]
pub struct CueRenderer {
    pub header: PcmRendererHeader,
    pub consumer: rtrb::Consumer<f32>,
    pub volume: Arc<AtomicU32>,
    pub channels: usize,
    pub is_enabled: Arc<AtomicBool>,
}

unsafe impl Send for CueRenderer {}

pub unsafe extern "C" fn cue_renderer_render_trampoline(
    ptr: *mut c_void,
    output: *mut f32,
    count: usize,
) {
    let r = &mut *(ptr as *mut CueRenderer);
    r.render_pcm(output, count);
}

pub unsafe extern "C" fn cue_renderer_notif_trampoline(_ptr: *mut c_void, _notif: i32) {}

impl CueRenderer {
    #[inline]
    pub fn render_pcm(&mut self, output_frames: *mut f32, frame_count: usize) {
        if output_frames.is_null() || frame_count == 0 {
            return;
        }

        let total_samples = frame_count * self.channels;
        let out_slice = unsafe { std::slice::from_raw_parts_mut(output_frames, total_samples) };

        if !self.is_enabled.load(Ordering::Relaxed) {
            out_slice.fill(0.0);
            return;
        }

        let to_read = self.consumer.slots().min(total_samples);
        if to_read > 0 {
            if let Ok(chunk) = self.consumer.read_chunk(to_read) {
                let (s1, s2) = chunk.as_slices();
                let n1 = s1.len();
                out_slice[..n1].copy_from_slice(s1);
                if !s2.is_empty() {
                    out_slice[n1..to_read].copy_from_slice(s2);
                }
                chunk.commit_all();
            }
        }
        if to_read < total_samples {
            out_slice[to_read..].fill(0.0);
        }

        let vol = f32::from_bits(self.volume.load(Ordering::Relaxed));
        if (vol - 1.0).abs() > 0.001 {
            for sample in out_slice.iter_mut() {
                *sample *= vol;
            }
        }
    }
}

pub struct OutputMatrix {
    pub cue_device_ctx: *mut MapDeviceContext,
    pub cue_renderer_ptr: *mut CueRenderer,
    pub cue_producer: Option<rtrb::Producer<f32>>,
    pub cue_enabled: Arc<AtomicBool>,
    pub cue_volume: Arc<AtomicU32>,
    pub cue_source: Arc<AtomicI32>,

    // File Recording Sink
    pub live_recorder: Option<LiveRecorder>,
    pub record_producer: Option<rtrb::Producer<f32>>,
    pub is_recording: Arc<AtomicBool>,
    pub recording_path: Option<String>,
    pub recorded_frames: Arc<AtomicU64>,

    // Resilience
    pub pause_on_device_change: Arc<AtomicBool>,
    pub channels: usize,
    pub sample_rate: u32,
}

unsafe impl Send for OutputMatrix {}
unsafe impl Sync for OutputMatrix {}

impl Drop for OutputMatrix {
    fn drop(&mut self) {
        self.stop_cue();
        self.stop_recording();
    }
}

impl OutputMatrix {
    pub fn new(sample_rate: u32, channels: usize) -> Self {
        Self {
            cue_device_ctx: std::ptr::null_mut(),
            cue_renderer_ptr: std::ptr::null_mut(),
            cue_producer: None,
            cue_enabled: Arc::new(AtomicBool::new(false)),
            cue_volume: Arc::new(AtomicU32::new(1.0f32.to_bits())),
            cue_source: Arc::new(AtomicI32::new(CueSource::StandbyTrack as i32)),

            live_recorder: None,
            record_producer: None,
            is_recording: Arc::new(AtomicBool::new(false)),
            recording_path: None,
            recorded_frames: Arc::new(AtomicU64::new(0)),

            pause_on_device_change: Arc::new(AtomicBool::new(false)),
            channels: channels.max(1),
            sample_rate: sample_rate.max(8000),
        }
    }

    pub fn set_pause_on_device_change(&self, enabled: bool) {
        self.pause_on_device_change.store(enabled, Ordering::Release);
    }

    pub fn set_cue_source(&self, source: CueSource) {
        self.cue_source.store(source as i32, Ordering::Release);
    }

    pub fn set_cue_volume(&self, volume: f32) {
        self.cue_volume.store(volume.clamp(0.0, 2.0).to_bits(), Ordering::Release);
    }

    pub fn enable_cue(&mut self, device_id: Option<&str>) -> Result<(), String> {
        self.stop_cue();

        let buffer_capacity = self.sample_rate as usize * self.channels * 2;
        let (prod, cons) = rtrb::RingBuffer::new(buffer_capacity);

        self.cue_producer = Some(prod);
        self.cue_enabled.store(true, Ordering::Release);

        let cue_renderer = Box::new(CueRenderer {
            header: PcmRendererHeader {
                render_fn: cue_renderer_render_trampoline,
                notif_fn: cue_renderer_notif_trampoline,
            },
            consumer: cons,
            volume: self.cue_volume.clone(),
            channels: self.channels,
            is_enabled: self.cue_enabled.clone(),
        });
        let renderer_ptr = Box::into_raw(cue_renderer);
        self.cue_renderer_ptr = renderer_ptr;

        let dev_c = device_id.and_then(|s| std::ffi::CString::new(s).ok());
        let dev_ptr = dev_c.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

        let mut dev_res = 0;
        let ctx = unsafe {
            map_device_create(
                self.sample_rate,
                self.channels as u32,
                1024,
                dev_ptr,
                renderer_ptr as *mut c_void,
                &mut dev_res,
            )
        };

        if ctx.is_null() || dev_res != 0 {
            unsafe {
                drop(Box::from_raw(renderer_ptr));
            }
            self.cue_renderer_ptr = std::ptr::null_mut();
            self.cue_producer = None;
            self.cue_enabled.store(false, Ordering::Release);
            return Err(format!("Failed to create CUE audio device: error {}", dev_res));
        }

        self.cue_device_ctx = ctx;
        unsafe {
            map_device_start(ctx);
        }
        Ok(())
    }

    pub fn stop_cue(&mut self) {
        self.cue_enabled.store(false, Ordering::Release);
        if !self.cue_device_ctx.is_null() {
            unsafe {
                map_device_stop(self.cue_device_ctx);
                map_device_destroy(self.cue_device_ctx);
            }
            self.cue_device_ctx = std::ptr::null_mut();
        }
        if !self.cue_renderer_ptr.is_null() {
            unsafe {
                drop(Box::from_raw(self.cue_renderer_ptr));
            }
            self.cue_renderer_ptr = std::ptr::null_mut();
        }
        self.cue_producer = None;
    }

    pub fn start_recording(&mut self, path: String, format: WavFormat) -> Result<(), String> {
        self.stop_recording();

        let (prod, cons) = rtrb::RingBuffer::new(self.sample_rate as usize * self.channels * 4);
        let mut rec = LiveRecorder::new(self.sample_rate, self.channels, format);
        rec.start(&path, cons)?;

        self.live_recorder = Some(rec);
        self.record_producer = Some(prod);
        self.recording_path = Some(path);
        self.recorded_frames.store(0, Ordering::Release);
        self.is_recording.store(true, Ordering::Release);
        Ok(())
    }

    pub fn stop_recording(&mut self) -> Option<(String, u64, usize, u64)> {
        self.is_recording.store(false, Ordering::Release);
        self.record_producer = None;
        let path = self.recording_path.take()?;

        if let Some(mut rec) = self.live_recorder.take() {
            let bytes_written = rec.stop().unwrap_or(0) as usize;
            let sample_count = self.recorded_frames.load(Ordering::Relaxed) * self.channels as u64;
            let duration_ms = (sample_count * 1000)
                / (self.sample_rate as u64 * self.channels as u64).max(1);
            Some((path, duration_ms, bytes_written, sample_count))
        } else {
            None
        }
    }

    /// Real-time routing from audio callback: pushes slices to CUE and Recording sinks.
    #[inline]
    pub fn dispatch_outputs(
        &mut self,
        standby_slice: &[f32],
        active_slice: &[f32],
        master_slice: &[f32],
        frame_count: usize,
    ) {
        let total_samples = frame_count * self.channels;

        // Route CUE
        if self.cue_enabled.load(Ordering::Relaxed) {
            if let Some(ref mut prod) = self.cue_producer {
                let to_write = prod.slots().min(total_samples);
                if to_write > 0 {
                    let src = match self.cue_source.load(Ordering::Relaxed) {
                        0 if standby_slice.len() >= to_write => &standby_slice[..to_write],
                        1 if active_slice.len() >= to_write => &active_slice[..to_write],
                        _ if master_slice.len() >= to_write => &master_slice[..to_write],
                        _ => &master_slice[..to_write.min(master_slice.len())],
                    };
                    if let Ok(mut chunk) = prod.write_chunk(to_write) {
                        let (s1, s2) = chunk.as_mut_slices();
                        let n1 = s1.len();
                        s1.copy_from_slice(&src[..n1]);
                        if !s2.is_empty() {
                            s2.copy_from_slice(&src[n1..to_write]);
                        }
                        chunk.commit_all();
                    }
                }
            }
        }

        // Route Recording
        if self.is_recording.load(Ordering::Relaxed) {
            if let Some(ref mut prod) = self.record_producer {
                let to_write = prod.slots().min(total_samples);
                if to_write > 0 {
                    if let Ok(mut chunk) = prod.write_chunk(to_write) {
                        let (s1, s2) = chunk.as_mut_slices();
                        let n1 = s1.len();
                        s1.copy_from_slice(&master_slice[..n1]);
                        if !s2.is_empty() {
                            s2.copy_from_slice(&master_slice[n1..to_write]);
                        }
                        chunk.commit_all();
                    }
                    self.recorded_frames.fetch_add(frame_count as u64, Ordering::Relaxed);
                }
            }
        }
    }
}
