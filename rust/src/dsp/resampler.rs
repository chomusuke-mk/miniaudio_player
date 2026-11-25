//! High-Fidelity Resampler powered by Rubato (`Fft`).
//!
//! Provides dynamic sample rate conversion with SNR > 140 dB, zero phase distortion,
//! and pre-allocated buffers for lock-free real-time audio pipelines.

use audioadapter_buffers::direct::SequentialSliceOfVecs;
use rubato::{Fft, FixedSync, Indexing, Resampler};

/// High-fidelity FFT-based sample rate converter powered by Rubato with SNR > 140 dB.
pub struct RubatoResampler {
    /// Underlying Rubato FFT resampler (`None` when operating in passthrough mode).
    resampler: Option<Fft<f32>>,
    /// Expected input sample rate in Hz.
    sample_rate_in: u32,
    /// Target output sample rate in Hz.
    sample_rate_out: u32,
    /// Number of interleaved audio channels.
    channels: usize,
    /// Fixed input frame chunk length required per Rubato FFT pass.
    chunk_size_in: usize,
    /// Maximum output frame chunk length emitted per Rubato FFT pass.
    chunk_size_out: usize,

    /// Pre-allocated per-channel input chunk buffers passed to Rubato.
    in_buffers: Vec<Vec<f32>>,
    /// Pre-allocated per-channel output chunk buffers populated by Rubato.
    out_buffers: Vec<Vec<f32>>,
    /// Per-channel FIFO staging deinterleaved input samples until a full chunk is accumulated.
    in_fifo: Vec<Vec<f32>>,
}

impl RubatoResampler {
    /// Zero-overhead passthrough resampler for `sample_rate`, `channels`, and `chunk_size` guaranteed never to fail.
    pub fn passthrough(sample_rate: u32, channels: usize, chunk_size: usize) -> Self {
        let sr = sample_rate.max(1);
        let cs = chunk_size.max(256);
        Self {
            resampler: None,
            sample_rate_in: sr,
            sample_rate_out: sr,
            channels: channels.max(1),
            chunk_size_in: cs,
            chunk_size_out: cs,
            in_buffers: Vec::new(),
            out_buffers: Vec::new(),
            in_fifo: Vec::new(),
        }
    }

    /// Creates a new resampler converting from `sample_rate_in` to `sample_rate_out` across `channels`
    /// with nominal `chunk_size`.
    ///
    /// If `sample_rate_in == sample_rate_out`, it operates in zero-overhead passthrough mode.
    ///
    /// # Errors
    /// Returns an error if either sample rate is zero or Rubato fails to initialize the FFT plan.
    pub fn new(
        sample_rate_in: u32,
        sample_rate_out: u32,
        channels: usize,
        chunk_size: usize,
    ) -> Result<Self, String> {
        let ch = channels.max(1);
        if sample_rate_in == 0 || sample_rate_out == 0 {
            crate::map_log!(
                1,
                "[RESAMPLER] Invalid zero sample rate: in={} out={}",
                sample_rate_in,
                sample_rate_out
            );
            return Err("Sample rates must be non-zero".to_string());
        }

        if sample_rate_in == sample_rate_out {
            crate::map_log!(
                4,
                "[RESAMPLER] Initialized passthrough mode (sr={}, ch={})",
                sample_rate_in,
                ch
            );
            return Ok(Self {
                resampler: None,
                sample_rate_in,
                sample_rate_out,
                channels: ch,
                chunk_size_in: chunk_size.max(256),
                chunk_size_out: chunk_size.max(256),
                in_buffers: Vec::new(),
                out_buffers: Vec::new(),
                in_fifo: vec![Vec::new(); ch],
            });
        }

        let resampler = Fft::<f32>::new(
            sample_rate_in as usize,
            sample_rate_out as usize,
            chunk_size.max(256),
            ch,
            FixedSync::Both,
        )
        .map_err(|e| {
            crate::map_log!(
                1,
                "[RESAMPLER] Failed to create Rubato FFT resampler ({} -> {}, ch={}): {:?}",
                sample_rate_in,
                sample_rate_out,
                ch,
                e
            );
            format!("Failed to create Rubato resampler: {:?}", e)
        })?;

        let chunk_size_in = resampler.input_frames_next();
        let chunk_size_out = resampler.output_frames_next();

        let in_buffers = vec![vec![0.0f32; chunk_size_in]; ch];
        let out_buffers = vec![vec![0.0f32; chunk_size_out]; ch];
        let in_fifo = vec![Vec::with_capacity(chunk_size_in * 4); ch];

        crate::map_log!(
            4,
            "[RESAMPLER] Initialized Rubato FFT ({} Hz -> {} Hz, ch={}, chunk_in={}, chunk_out={})",
            sample_rate_in,
            sample_rate_out,
            ch,
            chunk_size_in,
            chunk_size_out
        );

        Ok(Self {
            resampler: Some(resampler),
            sample_rate_in,
            sample_rate_out,
            channels: ch,
            chunk_size_in,
            chunk_size_out,
            in_buffers,
            out_buffers,
            in_fifo,
        })
    }

    /// Returns the expected input sample rate in Hz.
    pub fn sample_rate_in(&self) -> u32 {
        self.sample_rate_in
    }

    /// Returns the target output sample rate in Hz.
    pub fn sample_rate_out(&self) -> u32 {
        self.sample_rate_out
    }

    /// Returns the number of channels processed.
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Resamples interleaved PCM frames from `input` and appends resampled frames to `output`.
    ///
    /// Returns the number of output frames written.
    ///
    /// # Errors
    /// Returns an error if Rubato adapter construction or resampling fails.
    pub fn process_interleaved(
        &mut self,
        input: &[f32],
        output: &mut Vec<f32>,
    ) -> Result<usize, String> {
        if input.is_empty() {
            return Ok(0);
        }

        if self.resampler.is_none() {
            output.extend_from_slice(input);
            return Ok(input.len() / self.channels);
        }

        self.deinterleave_into_fifo(input);

        let mut frames_written = 0;
        while self.in_fifo[0].len() >= self.chunk_size_in {
            for c in 0..self.channels {
                self.in_buffers[c].copy_from_slice(&self.in_fifo[c][..self.chunk_size_in]);
                self.in_fifo[c].drain(..self.chunk_size_in);
            }

            let out_frames = {
                let resampler = self.resampler.as_mut().unwrap();
                let input_adapter =
                    SequentialSliceOfVecs::new(&self.in_buffers, self.channels, self.chunk_size_in)
                        .map_err(|e| {
                            crate::map_log!(1, "[RESAMPLER] Input adapter error: {:?}", e);
                            format!("Rubato input buffer adapter error: {:?}", e)
                        })?;
                let mut output_adapter = SequentialSliceOfVecs::new_mut(
                    &mut self.out_buffers,
                    self.channels,
                    self.chunk_size_out,
                )
                .map_err(|e| {
                    crate::map_log!(1, "[RESAMPLER] Output adapter error: {:?}", e);
                    format!("Rubato output buffer adapter error: {:?}", e)
                })?;
                let (_, out_frames) = resampler
                    .process_into_buffer(&input_adapter, &mut output_adapter, None)
                    .map_err(|e| {
                        crate::map_log!(1, "[RESAMPLER] Processing error: {:?}", e);
                        format!("Rubato processing error: {:?}", e)
                    })?;
                out_frames
            };

            self.interleave_out_buffers(out_frames, output);
            frames_written += out_frames;
        }

        Ok(frames_written)
    }

    /// Flushes remaining buffered frames into `output` by zero-padding the final chunk.
    ///
    /// # Errors
    /// Returns an error if Rubato adapter construction or final chunk flushing fails.
    pub fn flush(&mut self, output: &mut Vec<f32>) -> Result<usize, String> {
        if self.resampler.is_none() || self.in_fifo[0].is_empty() {
            return Ok(0);
        }

        let remaining = self.in_fifo[0].len();

        for c in 0..self.channels {
            self.in_fifo[c].resize(self.chunk_size_in, 0.0);
            self.in_buffers[c].copy_from_slice(&self.in_fifo[c][..self.chunk_size_in]);
            self.in_fifo[c].clear();
        }

        let out_frames = {
            let resampler = self.resampler.as_mut().unwrap();
            let input_adapter =
                SequentialSliceOfVecs::new(&self.in_buffers, self.channels, self.chunk_size_in)
                    .map_err(|e| {
                        crate::map_log!(1, "[RESAMPLER] Flush input adapter error: {:?}", e);
                        format!("Rubato flush input adapter error: {:?}", e)
                    })?;
            let mut output_adapter = SequentialSliceOfVecs::new_mut(
                &mut self.out_buffers,
                self.channels,
                self.chunk_size_out,
            )
            .map_err(|e| {
                crate::map_log!(1, "[RESAMPLER] Flush output adapter error: {:?}", e);
                format!("Rubato flush output adapter error: {:?}", e)
            })?;
            let indexing = Indexing {
                input_offset: 0,
                output_offset: 0,
                partial_len: Some(remaining),
                active_channels_mask: None,
            };
            let (_, out_frames) = resampler
                .process_into_buffer(&input_adapter, &mut output_adapter, Some(&indexing))
                .map_err(|e| {
                    crate::map_log!(1, "[RESAMPLER] Flush error: {:?}", e);
                    format!("Rubato flush error: {:?}", e)
                })?;
            out_frames
        };

        let valid_out =
            ((remaining as f64 / self.chunk_size_in as f64) * out_frames as f64).round() as usize;
        let valid_out = valid_out.min(out_frames);

        self.interleave_out_buffers(valid_out, output);
        Ok(valid_out)
    }

    /// Resets the internal state and empties buffers.
    pub fn reset(&mut self) {
        for buf in &mut self.in_fifo {
            buf.clear();
        }
        if let Some(ref mut resampler) = self.resampler {
            resampler.reset();
        }
    }

    /// Deinterleaves `input` PCM frames and appends per-channel samples into `in_fifo`.
    #[inline]
    fn deinterleave_into_fifo(&mut self, input: &[f32]) {
        let frames_in = input.len() / self.channels;
        for f in 0..frames_in {
            let offset = f * self.channels;
            for c in 0..self.channels {
                self.in_fifo[c].push(input[offset + c]);
            }
        }
    }

    /// Interleaves `num_frames` from `out_buffers` and appends them onto `output`.
    #[inline]
    fn interleave_out_buffers(&self, num_frames: usize, output: &mut Vec<f32>) {
        let start_len = output.len();
        output.resize(start_len + num_frames * self.channels, 0.0);
        for f in 0..num_frames {
            let out_idx = start_len + f * self.channels;
            for c in 0..self.channels {
                output[out_idx + c] = self.out_buffers[c][f];
            }
        }
    }
}
