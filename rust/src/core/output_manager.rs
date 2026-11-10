//! Symmetrical Multi-Output, Live Recording & Visualizer Manager (`OutputManager`).
//!
//! Orchestrates N physical audio output destinations (speakers, external DACs, headphones),
//! live disk recording with selective source capture, and FFT spectrum visualizer.

use std::ffi::CString;
use std::os::raw::c_void;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

use crate::api::types::{AudioOutputSource, RustAudioOutput};
use crate::bridge::ffi::{
    map_device_create, map_device_destroy, map_device_start,
    MapDeviceContext,
};
use crate::core::recording::{LiveRecorder, WavFormat};
use crate::core::renderer::PcmRendererHeader;
use crate::dsp::visualizer::{Visualizer, VisualizerData};
use crate::map_log;
use crate::sync::seqlock::CachePaddedSeqlock;

/// Real-time safe audio renderer reading from an SPSC ring buffer for an active output device.
#[repr(C)]
pub struct OutputDeviceRenderer {
    pub header: PcmRendererHeader,
    pub consumer: rtrb::Consumer<f32>,
    pub channels: usize,
    pub device_trigger: Option<Arc<(Mutex<bool>, Condvar)>>,
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

pub unsafe extern "C" fn output_device_notif_trampoline(ptr: *mut c_void, notif: i32) {
    if ptr.is_null() {
        return;
    }
    let r = &mut *(ptr as *mut OutputDeviceRenderer);
    if notif == 1 || notif == 2 {
        if let Some(ref trig) = r.device_trigger {
            let (lock, cvar) = &**trig;
            if let Ok(mut flag) = lock.lock() {
                *flag = true;
                cvar.notify_one();
            }
        }
    }
}

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
    pub device_id: String,
    pub resolved_id: String,
    pub source: AudioOutputSource,
    pub device_ctx: *mut MapDeviceContext,
    pub renderer_ptr: *mut c_void,
    pub producer: rtrb::Producer<f32>,
}

unsafe impl Send for ActiveOutputDevice {}
unsafe impl Sync for ActiveOutputDevice {}

impl Drop for ActiveOutputDevice {
    fn drop(&mut self) {
        if !self.device_ctx.is_null() {
            unsafe {
                map_device_destroy(self.device_ctx);
            }
            self.device_ctx = std::ptr::null_mut();
        }
        if !self.renderer_ptr.is_null() {
            unsafe {
                drop(Box::from_raw(self.renderer_ptr as *mut OutputDeviceRenderer));
            }
            self.renderer_ptr = std::ptr::null_mut();
        }
    }
}

/// Domain manager governing output routing, live selective disk recording, and visualizer.
pub struct OutputManager {
    /// Declarative configurations of requested outputs.
    pub outputs: Vec<RustAudioOutput>,
    /// Active physical device instances (each running its own decoupled miniaudio callback).
    pub active_devices: Vec<ActiveOutputDevice>,
    /// Device change trigger notification primitive.
    pub device_trigger: Option<Arc<(Mutex<bool>, Condvar)>>,

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
    pub fn new(
        sample_rate: u32,
        channels: usize,
        device_trigger: Option<Arc<(Mutex<bool>, Condvar)>>,
    ) -> Self {
        Self {
            outputs: Vec::new(),
            active_devices: Vec::new(),
            device_trigger,
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

    /// Resolves a requested device ID ("AUTO" or specific ID) to a physical OS device endpoint ID.
    pub fn resolve_physical_output_id(device_id: &str) -> Option<String> {
        if device_id == "AUTO" || device_id == "auto" || device_id.is_empty() {
            if let Ok(devs) = crate::bridge::ffi::safe_enumerate_playback_devices() {
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

    /// Updates the active outputs and synchronizes physical audio devices.
    pub fn set_outputs(&mut self, outputs: Vec<RustAudioOutput>) -> Result<(), String> {
        self.set_outputs_with_resolved(outputs, None)
    }

    /// Updates active outputs with optional pre-resolved physical endpoint ID for 'AUTO'.
    pub fn set_outputs_with_resolved(
        &mut self,
        outputs: Vec<RustAudioOutput>,
        pre_resolved_auto_id: Option<String>,
    ) -> Result<(), String> {
        self.outputs = outputs;

        let current_auto_def = pre_resolved_auto_id
            .or_else(|| Self::resolve_physical_output_id("AUTO"));

        map_log!(
            3,
            "[OUTPUT_MGR:SET_OUTPUTS:START] Setting {} outputs (current active={}), auto_endpoint={:?}",
            self.outputs.len(),
            self.active_devices.len(),
            current_auto_def
        );

        // Deduplicate physical hardware targets:
        // If both AUTO and a specific device resolve to the same physical OS endpoint,
        // prioritize AUTO and its configuration over specific/explicit devices.
        // The user's declared `self.outputs` list remains completely intact.
        let mut effective_configs: Vec<(RustAudioOutput, String)> = Vec::new();

        // 1. Prioritize AUTO outputs first
        for cfg in &self.outputs {
            if cfg.device_id == "AUTO" {
                let auto_res_id = current_auto_def.clone().unwrap_or_else(|| "AUTO".to_string());
                if !effective_configs.iter().any(|(_, r)| r == &auto_res_id) {
                    effective_configs.push((cfg.clone(), auto_res_id));
                }
            }
        }

        // 2. Add specific physical devices whose endpoints are not already claimed by AUTO
        for cfg in &self.outputs {
            if cfg.device_id != "AUTO" {
                if let Some(res_id) = Self::resolve_physical_output_id(&cfg.device_id) {
                    let already_claimed = effective_configs.iter().any(|(c, r)| {
                        r == &res_id || (c.device_id == "AUTO" && current_auto_def.as_ref() == Some(&res_id))
                    });
                    if !already_claimed {
                        effective_configs.push((cfg.clone(), res_id));
                    }
                }
            }
        }

        map_log!(
            3,
            "[OUTPUT_MGR:EFFECTIVE] Resolved {} effective physical target endpoints",
            effective_configs.len()
        );

        // 3. Evict active devices no longer present in effective_configs
        self.active_devices.retain_mut(|dev| {
            let still_active = effective_configs.iter().any(|(cfg, res_id)| {
                *res_id == dev.resolved_id
                    && cfg.device_id == dev.device_id
                    && cfg.source == (dev.source as i32)
            });

            if !still_active {
                map_log!(
                    2,
                    "[OUTPUT_MGR:DESTROY] Evicting active device '{}' (resolved '{}', source={:?}) via RAII drop...",
                    dev.device_id,
                    dev.resolved_id,
                    dev.source
                );
                false
            } else {
                true
            }
        });

        // 4. Open newly requested devices
        for (cfg, target_resolved_id) in &effective_configs {
            let already_open = self.active_devices.iter().any(|dev| {
                dev.resolved_id == *target_resolved_id
                    && dev.device_id == cfg.device_id
                    && (dev.source as i32) == cfg.source
            });

            if !already_open {
                map_log!(
                    3,
                    "[OUTPUT_MGR:CREATE:START] Opening new physical output device '{}' (target resolved '{}', source={:?})...",
                    cfg.device_id,
                    target_resolved_id,
                    AudioOutputSource::from(cfg.source)
                );
                let buffer_capacity = self.sample_rate as usize * self.channels * 2;
                let (prod, cons) = rtrb::RingBuffer::new(buffer_capacity);
                let renderer = Box::new(OutputDeviceRenderer {
                    header: PcmRendererHeader {
                        render_fn: output_device_render_trampoline,
                        notif_fn: output_device_notif_trampoline,
                    },
                    consumer: cons,
                    channels: self.channels,
                    device_trigger: self.device_trigger.clone(),
                });
                let renderer_ptr = Box::into_raw(renderer);

                let dev_c = if target_resolved_id == "AUTO" {
                    None
                } else {
                    CString::new(target_resolved_id.as_str()).ok()
                };
                let dev_ptr = dev_c.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

                let mut dev_res = 0;
                let t_create = Instant::now();
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

                map_log!(
                    3,
                    "[OUTPUT_MGR:CREATE:DONE] map_device_create returned result={} (ctx={:?}) in {}ms",
                    dev_res,
                    ctx,
                    t_create.elapsed().as_millis()
                );

                if !ctx.is_null() && dev_res == 0 {
                    let t_start = Instant::now();
                    unsafe {
                        map_device_start(ctx);
                    }
                    map_log!(
                        3,
                        "[OUTPUT_MGR:START:DONE] map_device_start succeeded in {}ms",
                        t_start.elapsed().as_millis()
                    );
                    self.active_devices.push(ActiveOutputDevice {
                        device_id: cfg.device_id.clone(),
                        resolved_id: target_resolved_id.clone(),
                        source: AudioOutputSource::from(cfg.source),
                        device_ctx: ctx,
                        renderer_ptr: renderer_ptr as *mut c_void,
                        producer: prod,
                    });
                } else {
                    map_log!(
                        1,
                        "[OUTPUT_MGR:CREATE:FAIL] Failed to open physical device '{}' (code {})",
                        target_resolved_id,
                        dev_res
                    );
                    unsafe {
                        drop(Box::from_raw(renderer_ptr));
                    }
                }
            }
        }

        map_log!(
            3,
            "[OUTPUT_MGR:SET_OUTPUTS:DONE] set_outputs_with_resolved completed successfully. Active devices: {}",
            self.active_devices.len()
        );

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

        // 1. Symmetrical physical hardware outputs (each reads from its designated SPSC ring buffer)
        for dev in &mut self.active_devices {
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

        // 2. Live File Recorder (independent lock-free SPSC capture)
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

        // 3. Compute FFT Spectrum for visualizer
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
        self.active_devices.clear();
    }
}
