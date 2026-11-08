//! Symmetrical Multi-Output, Live Recording & Visualizer Manager (`OutputManager`).
//!
//! Orchestrates N physical audio output destinations (speakers, external DACs, headphones),
//! live disk recording with selective source capture, and FFT spectrum visualizer.

use std::ffi::CString;
use std::os::raw::c_void;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use crate::api::types::{AudioOutputSource, RustAudioOutput};
use crate::bridge::ffi::{
    map_device_create, map_device_destroy, map_device_set_device, map_device_start,
    MapDeviceContext,
};
use crate::core::recording::{LiveRecorder, WavFormat};
use crate::core::renderer::PcmRendererHeader;
use crate::dsp::visualizer::{Visualizer, VisualizerData};
use crate::sync::seqlock::CachePaddedSeqlock;

/// Real-time safe audio renderer reading from an SPSC ring buffer for a secondary device.
#[repr(C)]
pub struct OutputDeviceRenderer {
    pub header: PcmRendererHeader,
    pub consumer: rtrb::Consumer<f32>,
    pub channels: usize,
}

unsafe impl Send for OutputDeviceRenderer {}

pub unsafe extern "C" fn output_device_render_trampoline(
    ptr: *mut c_void,
    output: *mut f32,
    count: usize,
) {
    let r = &mut *(ptr as *mut OutputDeviceRenderer);
    r.render_pcm(output, count);
}

pub unsafe extern "C" fn output_device_notif_trampoline(_ptr: *mut c_void, _notif: i32) {}

impl OutputDeviceRenderer {
    #[inline]
    pub fn render_pcm(&mut self, output_frames: *mut f32, frame_count: usize) {
        if output_frames.is_null() || frame_count == 0 {
            return;
        }
        let total_samples = frame_count * self.channels;
        let out_slice = unsafe { std::slice::from_raw_parts_mut(output_frames, total_samples) };

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
    }
}

/// Symmetrical active physical audio device managed by miniaudio.
pub struct ActiveOutputDevice {
    pub device_id: Option<String>,
    pub source: AudioOutputSource,
    pub exclusive_mode: bool,
    pub device_ctx: *mut MapDeviceContext,
    pub renderer_ptr: *mut c_void,
    pub producer: rtrb::Producer<f32>,
}

unsafe impl Send for ActiveOutputDevice {}
unsafe impl Sync for ActiveOutputDevice {}

/// Domain manager governing output routing, live selective disk recording, and visualizer.
pub struct OutputManager {
    /// Declarative configurations of requested outputs.
    pub outputs: Vec<RustAudioOutput>,
    /// Active secondary physical device instances (running their own miniaudio callbacks).
    pub secondary_devices: Vec<ActiveOutputDevice>,

    // =========================================================================
    // Recording Subsystem (first-class, with source selection)
    // =========================================================================
    pub live_recorder: Option<LiveRecorder>,
    pub record_producer: Option<rtrb::Producer<f32>>,
    pub recording_source: AudioOutputSource,
    pub is_recording: Arc<AtomicBool>,
    pub recorded_frames: Arc<AtomicU64>,
    pub recording_path: Option<String>,

    // =========================================================================
    // Visualizer Subsystem (first-class)
    // =========================================================================
    pub visualizer: Visualizer,
    pub visualizer_enabled: Arc<AtomicBool>,
    pub visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,

    pub pause_on_device_change: Arc<AtomicBool>,
    pub sample_rate: u32,
    pub channels: usize,
}

impl Drop for OutputManager {
    fn drop(&mut self) {
        self.dispose();
    }
}

impl OutputManager {
    /// Creates a new `OutputManager` for the specified sample rate and channel count.
    pub fn new(sample_rate: u32, channels: usize) -> Self {
        Self {
            outputs: Vec::new(),
            secondary_devices: Vec::new(),
            live_recorder: None,
            record_producer: None,
            recording_source: AudioOutputSource::All,
            is_recording: Arc::new(AtomicBool::new(false)),
            recorded_frames: Arc::new(AtomicU64::new(0)),
            recording_path: None,
            visualizer: Visualizer::new(channels, sample_rate),
            visualizer_enabled: Arc::new(AtomicBool::new(false)),
            visualizer_seqlock: Arc::new(CachePaddedSeqlock::new(VisualizerData::default())),
            pause_on_device_change: Arc::new(AtomicBool::new(false)),
            sample_rate,
            channels,
        }
    }

    // =========================================================================
    // Symmetrical Output Hardware Management
    // =========================================================================

    /// Updates the active outputs and reconfigures primary and secondary hardware audio routing.
    pub fn set_outputs(
        &mut self,
        outputs: Vec<RustAudioOutput>,
        primary_device_ctx: *mut MapDeviceContext,
    ) -> Result<(), String> {
        self.outputs = outputs;

        // 1. Primary device routing (outputs[0], if any)
        if let Some(first) = self.outputs.first() {
            if let Some(ref dev_id) = first.device_id {
                let c_dev = CString::new(dev_id.clone()).map_err(|e| e.to_string())?;
                let r = unsafe { map_device_set_device(primary_device_ctx, c_dev.as_ptr()) };
                if r != 0 {
                    return Err(format!("Setting device failed with code {}", r));
                }
            } else {
                let r = unsafe { map_device_set_device(primary_device_ctx, std::ptr::null()) };
                if r != 0 {
                    return Err(format!("Setting default device failed with code {}", r));
                }
            }
        } else {
            // outputs is empty {} -> no primary device
            let _ = unsafe { map_device_set_device(primary_device_ctx, std::ptr::null()) };
        }

        // 2. Secondary devices routing (outputs[1..])
        let secondary_configs: Vec<RustAudioOutput> = self.outputs.iter().skip(1).cloned().collect();
        self.secondary_devices.retain_mut(|dev| {
            let still_exists = secondary_configs.iter().any(|cfg| {
                cfg.device_id == dev.device_id && cfg.source == (dev.source as i32)
            });
            if !still_exists {
                unsafe {
                    map_device_destroy(dev.device_ctx);
                    drop(Box::from_raw(dev.renderer_ptr as *mut OutputDeviceRenderer));
                }
                false
            } else {
                true
            }
        });

        // Open new secondary devices requested in outputs[1..]
        for cfg in &secondary_configs {
            let already_open = self.secondary_devices.iter().any(|dev| {
                dev.device_id == cfg.device_id && (dev.source as i32) == cfg.source
            });
            if !already_open {
                let buffer_capacity = self.sample_rate as usize * self.channels * 2;
                let (prod, cons) = rtrb::RingBuffer::new(buffer_capacity);
                let renderer = Box::new(OutputDeviceRenderer {
                    header: PcmRendererHeader {
                        render_fn: output_device_render_trampoline,
                        notif_fn: output_device_notif_trampoline,
                    },
                    consumer: cons,
                    channels: self.channels,
                });
                let renderer_ptr = Box::into_raw(renderer);

                let dev_c = cfg.device_id.as_deref().and_then(|s| CString::new(s).ok());
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

                if !ctx.is_null() && dev_res == 0 {
                    unsafe {
                        map_device_start(ctx);
                    }
                    self.secondary_devices.push(ActiveOutputDevice {
                        device_id: cfg.device_id.clone(),
                        source: AudioOutputSource::from(cfg.source),
                        exclusive_mode: cfg.exclusive_mode,
                        device_ctx: ctx,
                        renderer_ptr: renderer_ptr as *mut c_void,
                        producer: prod,
                    });
                } else {
                    unsafe {
                        drop(Box::from_raw(renderer_ptr));
                    }
                }
            }
        }

        Ok(())
    }

    // =========================================================================
    // Selective Recording Subsystem
    // =========================================================================

    /// Begins recording rendered audio to a WAV file at `path` with a selective source.
    pub fn start_recording(
        &mut self,
        path: &str,
        format: WavFormat,
        source: AudioOutputSource,
    ) -> Result<(), String> {
        let (prod, cons) = rtrb::RingBuffer::new(self.sample_rate as usize * self.channels * 4);
        let mut rec = LiveRecorder::new(self.sample_rate, self.channels, format);
        rec.start(path, cons)?;
        self.live_recorder = Some(rec);
        self.record_producer = Some(prod);
        self.recording_source = source;
        self.recording_path = Some(path.to_string());
        self.recorded_frames.store(0, Ordering::Release);
        self.is_recording.store(true, Ordering::Release);
        Ok(())
    }

    /// Stops the active recording session and returns (path, duration_ms, bytes_written, sample_count).
    pub fn stop_recording(&mut self) -> Result<(String, u64, usize, u64), String> {
        self.is_recording.store(false, Ordering::Release);
        self.record_producer = None;
        let path = self.recording_path.take().ok_or_else(|| "Recording was not active".to_string())?;

        if let Some(mut rec) = self.live_recorder.take() {
            let bytes_written = rec.stop().unwrap_or(0) as usize;
            let sample_count = self.recorded_frames.load(Ordering::Relaxed) * self.channels as u64;
            let duration_ms = (sample_count * 1000)
                / (self.sample_rate as u64 * self.channels as u64).max(1);
            Ok((path, duration_ms, bytes_written, sample_count))
        } else {
            Err("Live recorder was not initialized".to_string())
        }
    }

    #[inline]
    pub fn is_recording(&self) -> bool {
        self.is_recording.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn recorded_frames(&self) -> u64 {
        self.recorded_frames.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn recorded_duration_ms(&self) -> u64 {
        let frames = self.recorded_frames.load(Ordering::Relaxed);
        (frames * 1000) / self.sample_rate.max(1) as u64
    }

    // =========================================================================
    // Visualizer & Configuration
    // =========================================================================

    #[inline]
    pub fn set_visualizer_enabled(&mut self, enabled: bool) {
        self.visualizer_enabled.store(enabled, Ordering::Release);
        self.visualizer.set_enabled(enabled);
        if !enabled {
            self.visualizer_seqlock.write(|d| *d = VisualizerData::default());
        }
    }

    #[inline]
    pub fn get_visualizer_data(&self) -> VisualizerData {
        self.visualizer_seqlock.read()
    }

    #[inline]
    pub fn set_pause_on_device_change(&self, enabled: bool) {
        self.pause_on_device_change.store(enabled, Ordering::Release);
    }

    // =========================================================================
    // Real-Time Audio Dispatch
    // =========================================================================

    /// Dispatches the finished audio buffers to all active physical devices, disk recording, and visualizer.
    pub fn dispatch(
        &mut self,
        all_buffer: &[f32],
        music_mix_buffer: &[f32],
        active_buffer: &[f32],
        standby_buffer: &[f32],
        primary_hardware_out: *mut f32,
        frame_count: usize,
    ) {
        let sample_count = frame_count * self.channels;

        let select_source = |src: AudioOutputSource| -> &[f32] {
            match src {
                AudioOutputSource::All => all_buffer,
                AudioOutputSource::MusicMix => music_mix_buffer,
                AudioOutputSource::ActiveTrack => active_buffer,
                AudioOutputSource::StandbyTrack => standby_buffer,
            }
        };

        // 1. Primary physical hardware output
        if !primary_hardware_out.is_null() && sample_count > 0 {
            if let Some(first) = self.outputs.first() {
                let src_slice = select_source(AudioOutputSource::from(first.source));
                let valid = src_slice.len().min(sample_count);
                if valid > 0 {
                    unsafe {
                        std::ptr::copy_nonoverlapping(src_slice.as_ptr(), primary_hardware_out, valid);
                        if valid < sample_count {
                            std::slice::from_raw_parts_mut(
                                primary_hardware_out.add(valid),
                                sample_count - valid,
                            )
                            .fill(0.0);
                        }
                    }
                } else {
                    unsafe {
                        std::slice::from_raw_parts_mut(primary_hardware_out, sample_count).fill(0.0);
                    }
                }
            } else {
                // outputs is empty {} -> fill with silence 0.0
                unsafe {
                    std::slice::from_raw_parts_mut(primary_hardware_out, sample_count).fill(0.0);
                }
            }
        }

        // 2. Secondary physical hardware outputs (each reads from its designated SPSC ring buffer)
        for dev in &mut self.secondary_devices {
            let src_slice = select_source(dev.source);
            let valid = src_slice.len().min(sample_count);
            let to_write = dev.producer.slots().min(valid);
            if to_write > 0 {
                if let Ok(mut chunk) = dev.producer.write_chunk(to_write) {
                    let (s1, s2) = chunk.as_mut_slices();
                    let n1 = s1.len();
                    s1.copy_from_slice(&src_slice[..n1]);
                    if !s2.is_empty() {
                        s2.copy_from_slice(&src_slice[n1..to_write]);
                    }
                    chunk.commit_all();
                }
            }
        }

        // 3. Live File Recorder (independent lock-free SPSC capture)
        if self.is_recording.load(Ordering::Relaxed) {
            if let Some(ref mut prod) = self.record_producer {
                let rec_slice = select_source(self.recording_source);
                let valid = rec_slice.len().min(sample_count);
                let to_write = prod.slots().min(valid);
                if to_write > 0 {
                    if let Ok(mut chunk) = prod.write_chunk(to_write) {
                        let (s1, s2) = chunk.as_mut_slices();
                        let n1 = s1.len();
                        s1.copy_from_slice(&rec_slice[..n1]);
                        if !s2.is_empty() {
                            s2.copy_from_slice(&rec_slice[n1..to_write]);
                        }
                        chunk.commit_all();
                    }
                    self.recorded_frames.fetch_add(frame_count as u64, Ordering::Relaxed);
                }
            }
        }

        // 4. Compute FFT Spectrum for visualizer
        if self.visualizer_enabled.load(Ordering::Relaxed) {
            let valid = all_buffer.len().min(sample_count);
            self.visualizer.set_enabled(true);
            self.visualizer.process_frames(&all_buffer[..valid]);
            let vis_data = self.visualizer.get_data();
            self.visualizer_seqlock.write(|d| *d = vis_data);
        }
    }

    pub fn dispose(&mut self) {
        let _ = self.stop_recording();
        for dev in self.secondary_devices.drain(..) {
            unsafe {
                map_device_destroy(dev.device_ctx);
                drop(Box::from_raw(dev.renderer_ptr as *mut OutputDeviceRenderer));
            }
        }
    }
}
