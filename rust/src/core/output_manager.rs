//! Symmetrical Multi-Output, Live Recording & Visualizer Manager (`OutputManager`).
//!
//! Orchestrates N physical audio output destinations (speakers, external DACs, headphones),
//! live disk recording with selective source capture, and FFT spectrum visualizer.

use std::ffi::CString;
use std::os::raw::c_void;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use crate::sync::MonotonicInstant as Instant;

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

/// Pre-opened physical output changes staged off `map-engine-clock`.
pub struct PreparedOutputs {
    pub desired_outputs: Vec<RustAudioOutput>,
    pub keep_keys: Vec<(String, String, i32)>,
    pub new_devices: Vec<ActiveOutputDevice>,
}

/// Active recording handles extracted atomically from `OutputManager` for off-clock finalization.
pub struct DetachedRecording {
    pub path: String,
    pub recorder: LiveRecorder,
    pub producer: Option<rtrb::Producer<f32>>,
    pub sample_count: u64,
    pub duration_ms: u64,
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
    pub visualizer_source: Arc<AtomicU8>,
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
            visualizer_source: Arc::new(AtomicU8::new(AudioOutputSource::All as u8)),
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

    /// Returns lightweight descriptors `(device_id, resolved_id, source)` for all open devices.
    pub fn current_device_keys(&self) -> Vec<(String, String, i32)> {
        self.active_devices
            .iter()
            .map(|dev| (dev.device_id.clone(), dev.resolved_id.clone(), dev.source as i32))
            .collect()
    }

    fn resolve_effective_configs(
        outputs: &[RustAudioOutput],
        pre_resolved_auto_id: Option<String>,
    ) -> Vec<(RustAudioOutput, String)> {
        let current_auto_def =
            pre_resolved_auto_id.or_else(|| Self::resolve_physical_output_id("AUTO"));
        let mut effective_configs: Vec<(RustAudioOutput, String)> = Vec::new();

        // 1. Prioritize AUTO outputs first
        for cfg in outputs {
            if cfg.device_id == "AUTO" {
                let auto_res_id = current_auto_def
                    .clone()
                    .unwrap_or_else(|| "AUTO".to_string());
                if !effective_configs.iter().any(|(_, r)| r == &auto_res_id) {
                    effective_configs.push((cfg.clone(), auto_res_id));
                }
            }
        }

        // 2. Add specific physical devices whose endpoints are not already claimed by AUTO
        for cfg in outputs {
            if cfg.device_id != "AUTO" {
                if let Some(res_id) = Self::resolve_physical_output_id(&cfg.device_id) {
                    let already_claimed = effective_configs.iter().any(|(c, r)| {
                        r == &res_id
                            || (c.device_id == "AUTO" && current_auto_def.as_ref() == Some(&res_id))
                    });
                    if !already_claimed {
                        effective_configs.push((cfg.clone(), res_id));
                    }
                }
            }
        }

        effective_configs
    }

    fn open_physical_device(
        sample_rate: u32,
        channels: usize,
        device_trigger: Option<Arc<(Mutex<bool>, Condvar)>>,
        cfg: &RustAudioOutput,
        target_resolved_id: &str,
    ) -> Option<ActiveOutputDevice> {
        map_log!(
            3,
            "[OUTPUT_MGR:CREATE:START] Opening new physical output device '{}' (target resolved '{}', source={:?})...",
            cfg.device_id,
            target_resolved_id,
            AudioOutputSource::from(cfg.source)
        );
        let buffer_capacity = sample_rate as usize * channels * 2;
        let (prod, cons) = rtrb::RingBuffer::new(buffer_capacity);
        let renderer = Box::new(OutputDeviceRenderer {
            header: PcmRendererHeader {
                render_fn: output_device_render_trampoline,
                notif_fn: output_device_notif_trampoline,
            },
            consumer: cons,
            channels,
            device_trigger,
        });
        let renderer_ptr = Box::into_raw(renderer);

        let dev_c = if target_resolved_id == "AUTO" {
            None
        } else {
            CString::new(target_resolved_id).ok()
        };
        let dev_ptr = dev_c
            .as_ref()
            .map(|c| c.as_ptr())
            .unwrap_or(std::ptr::null());

        let mut dev_res = 0;
        let t_create = Instant::now();
        let ctx = unsafe {
            map_device_create(
                sample_rate,
                channels as u32,
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
            Some(ActiveOutputDevice {
                device_id: cfg.device_id.clone(),
                resolved_id: target_resolved_id.to_string(),
                source: AudioOutputSource::from(cfg.source),
                device_ctx: ctx,
                renderer_ptr: renderer_ptr as *mut c_void,
                producer: prod,
            })
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
            None
        }
    }

    /// Resolves and opens any newly needed physical output devices completely outside
    /// `map-engine-clock`.
    pub fn prepare_outputs_off_rt(
        sample_rate: u32,
        channels: usize,
        device_trigger: Option<Arc<(Mutex<bool>, Condvar)>>,
        existing_open: &[(String, String, i32)],
        outputs: Vec<RustAudioOutput>,
        pre_resolved_auto_id: Option<String>,
    ) -> PreparedOutputs {
        let effective_configs = Self::resolve_effective_configs(&outputs, pre_resolved_auto_id);
        let keep_keys: Vec<(String, String, i32)> = effective_configs
            .iter()
            .map(|(c, r)| (c.device_id.clone(), r.clone(), c.source))
            .collect();

        let mut new_devices = Vec::new();
        for (cfg, target_resolved_id) in &effective_configs {
            let already_open = existing_open.iter().any(|(dev_id, res_id, src)| {
                res_id == target_resolved_id && dev_id == &cfg.device_id && *src == cfg.source
            });
            if !already_open {
                if let Some(dev) = Self::open_physical_device(
                    sample_rate,
                    channels,
                    device_trigger.clone(),
                    cfg,
                    target_resolved_id,
                ) {
                    new_devices.push(dev);
                }
            }
        }

        PreparedOutputs {
            desired_outputs: outputs,
            keep_keys,
            new_devices,
        }
    }

    /// Swaps pre-opened devices into `active_devices` in O(N) without touching OS APIs,
    /// returning displaced devices so the caller / `map-reaper` can drop them off-RT.
    pub fn apply_prepared_outputs(&mut self, batch: PreparedOutputs) -> Vec<ActiveOutputDevice> {
        self.outputs = batch.desired_outputs;
        let mut kept = Vec::with_capacity(self.active_devices.len() + batch.new_devices.len());
        let mut evicted = Vec::new();

        for dev in self.active_devices.drain(..) {
            let keep = batch.keep_keys.iter().any(|(dev_id, res_id, src)| {
                *res_id == dev.resolved_id
                    && *dev_id == dev.device_id
                    && *src == (dev.source as i32)
            });
            if keep {
                kept.push(dev);
            } else {
                evicted.push(dev);
            }
        }

        for new_dev in batch.new_devices {
            let dup = kept.iter().any(|d| {
                d.resolved_id == new_dev.resolved_id
                    && d.device_id == new_dev.device_id
                    && d.source == new_dev.source
            });
            if dup {
                evicted.push(new_dev);
            } else {
                kept.push(new_dev);
            }
        }
        self.active_devices = kept;
        evicted
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
        let existing = self.current_device_keys();
        let batch = Self::prepare_outputs_off_rt(
            self.sample_rate,
            self.channels,
            self.device_trigger.clone(),
            &existing,
            outputs,
            pre_resolved_auto_id,
        );
        let evicted = self.apply_prepared_outputs(batch);
        drop(evicted);
        Ok(())
    }

    // =========================================================================
    // Selective Recording Subsystem
    // =========================================================================

    /// Installs a pre-opened `LiveRecorder` and ring-buffer producer without touching disk/threads.
    pub fn attach_prepared_recording(
        &mut self,
        path: String,
        source: AudioOutputSource,
        recorder: LiveRecorder,
        producer: rtrb::Producer<f32>,
    ) -> (Option<LiveRecorder>, Option<rtrb::Producer<f32>>) {
        let prev_prod = self.record_producer.take();
        let prev_rec = self.live_recorder.take();
        self.live_recorder = Some(recorder);
        self.record_producer = Some(producer);
        self.recording_source = source;
        self.recording_path = Some(path);
        self.recorded_frames.store(0, Ordering::Release);
        self.is_recording.store(true, Ordering::Release);
        (prev_rec, prev_prod)
    }

    /// Extracts the active recording handles atomically without joining the writer thread.
    pub fn detach_recording_for_stop(&mut self) -> Result<DetachedRecording, String> {
        self.is_recording.store(false, Ordering::Release);
        let producer = self.record_producer.take();
        let path = self
            .recording_path
            .take()
            .ok_or_else(|| "Recording was not active".to_string())?;
        let recorder = self
            .live_recorder
            .take()
            .ok_or_else(|| "Live recorder was not initialized".to_string())?;
        let sample_count = self.recorded_frames.load(Ordering::Relaxed) * self.channels as u64;
        let duration_ms = (sample_count * 1000)
            / (self.sample_rate as u64 * self.channels as u64).max(1);
        Ok(DetachedRecording {
            path,
            recorder,
            producer,
            sample_count,
            duration_ms,
        })
    }

    /// Begins recording rendered audio to a WAV file at `path` with a selective source.
    pub fn start_recording(
        &mut self,
        path: &str,
        format: WavFormat,
        source: AudioOutputSource,
    ) -> Result<(), String> {
        let (rec, prod) =
            LiveRecorder::prepare_start(self.sample_rate, self.channels, format, path)?;
        let (prev_rec, prev_prod) =
            self.attach_prepared_recording(path.to_string(), source, rec, prod);
        drop(prev_prod);
        if let Some(mut old) = prev_rec {
            let _ = old.stop();
        }
        Ok(())
    }

    /// Stops the active recording session and returns (path, duration_ms, bytes_written, sample_count).
    pub fn stop_recording(&mut self) -> Result<(String, u64, usize, u64), String> {
        let mut detached = self.detach_recording_for_stop()?;
        drop(detached.producer);
        let bytes_written = detached.recorder.stop().unwrap_or(0) as usize;
        Ok((
            detached.path,
            detached.duration_ms,
            bytes_written,
            detached.sample_count,
        ))
    }

    /// Returns whether live recording is actively capturing audio frames.
    #[inline]
    pub fn is_recording(&self) -> bool {
        self.is_recording.load(Ordering::Relaxed)
    }

    /// Returns the total audio frames captured during the current recording session.
    #[inline]
    pub fn recorded_frames(&self) -> u64 {
        self.recorded_frames.load(Ordering::Relaxed)
    }

    /// Returns the duration of the current recording session in milliseconds.
    #[inline]
    pub fn recorded_duration_ms(&self) -> u64 {
        let frames = self.recorded_frames.load(Ordering::Relaxed);
        (frames * 1000) / self.sample_rate.max(1) as u64
    }

    // =========================================================================
    // Visualizer & Configuration
    // =========================================================================

    /// Enables or disables real-time FFT spectrum visualizer computation.
    #[inline]
    pub fn set_visualizer_enabled(&mut self, enabled: bool) {
        self.visualizer_enabled.store(enabled, Ordering::Release);
        self.visualizer.set_enabled(enabled);
        if !enabled {
            self.visualizer_seqlock.write(|d| *d = VisualizerData::default());
        }
    }

    /// Sets the audio source bus that feeds the real-time FFT spectrum visualizer.
    #[inline]
    pub fn set_visualizer_source(&mut self, source: AudioOutputSource) {
        self.visualizer_source.store(source as u8, Ordering::Release);
        self.visualizer.reset();
        self.visualizer_seqlock.write(|d| *d = VisualizerData::default());
    }

    /// Gets the current audio source bus feeding the visualizer.
    #[inline]
    pub fn visualizer_source(&self) -> AudioOutputSource {
        AudioOutputSource::from(self.visualizer_source.load(Ordering::Acquire) as i32)
    }

    /// Retrieves instantaneous visualizer metrics via lock-free seqlock reader.
    #[inline]
    pub fn get_visualizer_data(&self) -> VisualizerData {
        self.visualizer_seqlock.read()
    }

    /// Sets whether playback automatically pauses when the OS default audio output changes.
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
        voice_buffer: &[f32],
        frame_count: usize,
    ) {
        let sample_count = frame_count * self.channels;

        let select_source = |src: AudioOutputSource| -> &[f32] {
            match src {
                AudioOutputSource::All => all_buffer,
                AudioOutputSource::MusicMix => music_mix_buffer,
                AudioOutputSource::ActiveTrack => active_buffer,
                AudioOutputSource::StandbyTrack => standby_buffer,
                AudioOutputSource::VoiceOnly => voice_buffer,
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
            let vis_source = AudioOutputSource::from(
                self.visualizer_source.load(Ordering::Relaxed) as i32,
            );
            let vis_slice = select_source(vis_source);
            let valid = vis_slice.len().min(sample_count);
            self.visualizer.set_enabled(true);
            self.visualizer.process_frames(&vis_slice[..valid]);
            let vis_data = self.visualizer.get_data();
            self.visualizer_seqlock.write(|d| *d = vis_data);
        }
    }

    /// Stops all live recording sessions and releases all physical output audio devices.
    pub fn dispose(&mut self) {
        let _ = self.stop_recording();
        self.active_devices.clear();
    }
}
