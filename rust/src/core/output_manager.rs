//! Audio Outputs & Recording Domain Manager (`OutputManager`).
//!
//! Encapsulates multi-destination matrix routing to Master speakers/DAC,
//! DJ CUE headphone pre-listening (PFL), lock-free disk recording (LiveRecorder),
//! and FFT spectrum visualizer.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::core::output_matrix::{CueSource, OutputMatrix};
use crate::core::recording::WavFormat;
use crate::dsp::visualizer::{Visualizer, VisualizerData};
use crate::sync::seqlock::CachePaddedSeqlock;

pub struct OutputManager {
    pub matrix: OutputMatrix,
    pub visualizer: Visualizer,
    pub visualizer_enabled: Arc<AtomicBool>,
    pub visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,
    pub sample_rate: u32,
    pub channels: usize,
}

impl OutputManager {
    pub fn new(sample_rate: u32, channels: usize) -> Self {
        Self {
            matrix: OutputMatrix::new(sample_rate, channels),
            visualizer: Visualizer::new(channels, sample_rate),
            visualizer_enabled: Arc::new(AtomicBool::new(false)),
            visualizer_seqlock: Arc::new(CachePaddedSeqlock::new(VisualizerData::default())),
            sample_rate,
            channels,
        }
    }

    // =========================================================================
    // Direct Output & Recording Commands
    // =========================================================================

    #[inline]
    pub fn set_cue_source(&self, source: CueSource) {
        self.matrix.set_cue_source(source);
    }

    #[inline]
    pub fn set_cue_volume(&self, volume: f32) {
        self.matrix.set_cue_volume(volume);
    }

    #[inline]
    pub fn enable_cue(&mut self, device_id: Option<&str>) -> Result<(), String> {
        self.matrix.enable_cue(device_id)
    }

    #[inline]
    pub fn disable_cue(&mut self) {
        self.matrix.stop_cue();
    }

    #[inline]
    pub fn cue_volume(&self) -> f32 {
        f32::from_bits(self.matrix.cue_volume.load(Ordering::Relaxed))
    }

    #[inline]
    pub fn cue_source(&self) -> i32 {
        self.matrix.cue_source.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn is_cue_enabled(&self) -> bool {
        self.matrix.cue_enabled.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn start_recording(&mut self, path: &str, format: WavFormat) -> Result<(), String> {
        self.matrix.start_recording(path.to_string(), format)
    }

    #[inline]
    pub fn stop_recording(&mut self) -> Result<(String, u64, usize, u64), String> {
        self.matrix
            .stop_recording()
            .ok_or_else(|| "Recording was not active".to_string())
    }

    #[inline]
    pub fn set_visualizer_enabled(&mut self, enabled: bool) {
        self.visualizer_enabled.store(enabled, Ordering::Release);
        self.visualizer.set_enabled(enabled);
        if !enabled {
            self.visualizer_seqlock.write(|d| *d = VisualizerData::default());
        }
    }

    #[inline]
    pub fn set_pause_on_device_change(&self, enabled: bool) {
        self.matrix.set_pause_on_device_change(enabled);
    }

    // =========================================================================
    // Real-Time Audio Dispatch
    // =========================================================================

    /// Dispatches the finished `master_buffer` to:
    /// - Hardware audio device (`hardware_out`)
    /// - CUE headphone pre-listening device
    /// - Live disk recorder (WAV/MP3)
    /// - FFT Spectrum Visualizer
    pub fn dispatch(
        &mut self,
        master_buffer: &[f32],
        standby_buffer: &[f32],
        hardware_out: *mut f32,
        frame_count: usize,
    ) {
        let sample_count = frame_count * self.channels;
        let valid_samples = master_buffer.len().min(sample_count);

        // 1. Copy to miniaudio hardware output buffer
        if !hardware_out.is_null() && valid_samples > 0 {
            unsafe {
                std::ptr::copy_nonoverlapping(master_buffer.as_ptr(), hardware_out, valid_samples);
            }
        }

        // 2 & 3. Route CUE and Recording through matrix
        self.matrix.dispatch_outputs(
            standby_buffer,
            master_buffer,
            master_buffer,
            frame_count,
        );

        // 4. Compute FFT Spectrum for visualizer
        if self.visualizer_enabled.load(Ordering::Relaxed) {
            self.visualizer.set_enabled(true);
            self.visualizer.process_frames(&master_buffer[..valid_samples]);
            let vis_data = self.visualizer.get_data();
            self.visualizer_seqlock.write(|d| *d = vis_data);
        }
    }

    #[inline]
    pub fn is_recording(&self) -> bool {
        self.matrix.is_recording.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn recorded_frames(&self) -> u64 {
        self.matrix.recorded_frames.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn get_visualizer_data(&self) -> VisualizerData {
        self.visualizer_seqlock.read()
    }

    pub fn dispose(&mut self) {
        let _ = self.stop_recording();
    }
}
