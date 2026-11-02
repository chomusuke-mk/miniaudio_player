//! Real-time decoupled live recording to WAV files and offline bounce rendering.
//!
//! Features:
//! - 100% Lock-Free audio callback tapping via wait-free SPSC ring buffer (`rtrb`).
//! - Support for 16-bit PCM and 32-bit Float IEEE WAV standards.
//! - Automatic RIFF header back-patching with sample count on completion.
//! - Offline bounce rendering at maximum CPU throughput.

use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WavFormat {
    #[default]
    Pcm16,
    Float32,
}

impl WavFormat {
    #[inline]
    pub const fn bits_per_sample(self) -> u16 {
        match self {
            WavFormat::Pcm16 => 16,
            WavFormat::Float32 => 32,
        }
    }

    #[inline]
    pub const fn audio_format_code(self) -> u16 {
        match self {
            WavFormat::Pcm16 => 1,   // WAVE_FORMAT_PCM
            WavFormat::Float32 => 3, // WAVE_FORMAT_IEEE_FLOAT
        }
    }
}

pub fn write_wav_header<W: Write>(
    writer: &mut W,
    sample_rate: u32,
    channels: u16,
    format: WavFormat,
) -> std::io::Result<()> {
    let bits_per_sample = format.bits_per_sample();
    let audio_format = format.audio_format_code();
    let block_align: u16 = channels * (bits_per_sample / 8);
    let byte_rate: u32 = sample_rate * block_align as u32;

    // RIFF chunk descriptor
    writer.write_all(b"RIFF")?;
    writer.write_all(&0u32.to_le_bytes())?; // Placeholder for (file size - 8)
    writer.write_all(b"WAVE")?;

    // "fmt " sub-chunk
    writer.write_all(b"fmt ")?;
    writer.write_all(&16u32.to_le_bytes())?; // Subchunk1Size for PCM (16 bytes)
    writer.write_all(&audio_format.to_le_bytes())?;
    writer.write_all(&channels.to_le_bytes())?;
    writer.write_all(&sample_rate.to_le_bytes())?;
    writer.write_all(&byte_rate.to_le_bytes())?;
    writer.write_all(&block_align.to_le_bytes())?;
    writer.write_all(&bits_per_sample.to_le_bytes())?;

    // "data" sub-chunk
    writer.write_all(b"data")?;
    writer.write_all(&0u32.to_le_bytes())?; // Placeholder for data size

    Ok(())
}

pub fn finalize_wav_header(file: &mut File, data_bytes: u32) -> std::io::Result<()> {
    let riff_size = data_bytes.saturating_add(36);
    file.seek(SeekFrom::Start(4))?;
    file.write_all(&riff_size.to_le_bytes())?;

    file.seek(SeekFrom::Start(40))?;
    file.write_all(&data_bytes.to_le_bytes())?;
    file.flush()?;
    Ok(())
}

/// Deterministic black-box WAV stream encoder encapsulating header emission,
/// sample serialization (`Pcm16` / `Float32`), and byte counting.
pub struct WavSampleWriter<W: Write> {
    writer: W,
    format: WavFormat,
    data_bytes: u32,
}

impl<W: Write> WavSampleWriter<W> {
    pub fn new(
        mut writer: W,
        sample_rate: u32,
        channels: u16,
        format: WavFormat,
    ) -> std::io::Result<Self> {
        write_wav_header(&mut writer, sample_rate, channels, format)?;
        Ok(Self {
            writer,
            format,
            data_bytes: 0,
        })
    }

    #[inline]
    pub fn write_sample(&mut self, sample: f32) -> std::io::Result<()> {
        match self.format {
            WavFormat::Pcm16 => {
                let clamped = sample.clamp(-1.0, 1.0);
                let pcm16 = (clamped * 32767.0).round() as i16;
                self.writer.write_all(&pcm16.to_le_bytes())?;
                self.data_bytes = self.data_bytes.saturating_add(2);
            }
            WavFormat::Float32 => {
                self.writer.write_all(&sample.to_le_bytes())?;
                self.data_bytes = self.data_bytes.saturating_add(4);
            }
        }
        Ok(())
    }

    pub fn write_samples(&mut self, samples: &[f32]) -> std::io::Result<()> {
        for &sample in samples {
            self.write_sample(sample)?;
        }
        Ok(())
    }

    /// Drains all currently available samples from an SPSC ring buffer consumer into the WAV writer.
    /// Returns `true` if at least one sample was drained.
    pub fn drain_consumer(&mut self, consumer: &mut rtrb::Consumer<f32>) -> bool {
        let slots = consumer.slots();
        if slots == 0 {
            return false;
        }
        if let Ok(chunk) = consumer.read_chunk(slots) {
            let (s1, s2) = chunk.as_slices();
            for &sample in s1.iter().chain(s2.iter()) {
                if self.write_sample(sample).is_err() {
                    break;
                }
            }
            chunk.commit_all();
            true
        } else {
            false
        }
    }

    pub fn flush_and_into_parts(mut self) -> std::io::Result<(W, u32)> {
        self.writer.flush()?;
        Ok((self.writer, self.data_bytes))
    }
}

/// Offline bounce renderer exporting raw or generated float PCM frames directly to a WAV file.
pub fn offline_bounce_to_wav(
    path: &str,
    pcm_samples: &[f32],
    sample_rate: u32,
    channels: usize,
    format: WavFormat,
) -> Result<u64, String> {
    if pcm_samples.is_empty() {
        return Err("Cannot bounce empty PCM audio".to_string());
    }

    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(path)
        .map_err(|e| format!("Failed to create bounce file '{}': {}", path, e))?;

    let buf_writer = BufWriter::new(&mut file);
    let mut wav_writer = WavSampleWriter::new(buf_writer, sample_rate, channels as u16, format)
        .map_err(|e| format!("Failed to write WAV header: {}", e))?;

    wav_writer
        .write_samples(pcm_samples)
        .map_err(|e| format!("Write error: {}", e))?;

    let (_, data_bytes) = wav_writer
        .flush_and_into_parts()
        .map_err(|e| format!("Flush error: {}", e))?;

    finalize_wav_header(&mut file, data_bytes)
        .map_err(|e| format!("Finalize header error: {}", e))?;

    Ok(data_bytes as u64)
}

/// Real-time live audio recording manager running on a dedicated disk writer thread.
pub struct LiveRecorder {
    is_recording: Arc<AtomicBool>,
    stop_signal: Arc<AtomicBool>,
    writer_thread: Option<JoinHandle<Result<u64, String>>>,
    sample_rate: u32,
    channels: usize,
    format: WavFormat,
}

impl LiveRecorder {
    pub fn new(sample_rate: u32, channels: usize, format: WavFormat) -> Self {
        Self {
            is_recording: Arc::new(AtomicBool::new(false)),
            stop_signal: Arc::new(AtomicBool::new(false)),
            writer_thread: None,
            sample_rate: sample_rate.max(8000),
            channels: channels.max(1),
            format,
        }
    }

    pub fn is_recording(&self) -> bool {
        self.is_recording.load(Ordering::Acquire)
    }

    pub fn set_format(&mut self, format: WavFormat) {
        self.format = format;
    }

    fn open_recording_file(path: &str) -> Result<File, String> {
        OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)
            .map_err(|e| format!("Failed to create recording file '{}': {}", path, e))
    }

    /// Starts writing audio to `path` using the consumer end of an SPSC ring buffer.
    pub fn start(&mut self, path: &str, mut consumer: rtrb::Consumer<f32>) -> Result<(), String> {
        if self.is_recording() {
            return Err("Recording session is already active".to_string());
        }

        let mut file = Self::open_recording_file(path)?;
        let sr = self.sample_rate;
        let ch = self.channels as u16;
        let fmt = self.format;

        self.stop_signal.store(false, Ordering::Release);
        self.is_recording.store(true, Ordering::Release);

        let is_rec = self.is_recording.clone();
        let stop_sig = self.stop_signal.clone();

        let handle = std::thread::Builder::new()
            .name("miniaudio-wav-writer".to_string())
            .spawn(move || {
                let buf_writer = BufWriter::with_capacity(65536, &mut file);
                let mut wav_writer = match WavSampleWriter::new(buf_writer, sr, ch, fmt) {
                    Ok(w) => w,
                    Err(e) => {
                        is_rec.store(false, Ordering::Release);
                        return Err(format!("Failed to write initial WAV header: {}", e));
                    }
                };

                while !stop_sig.load(Ordering::Acquire) || consumer.slots() > 0 {
                    if !wav_writer.drain_consumer(&mut consumer) {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                }

                let total_bytes = wav_writer
                    .flush_and_into_parts()
                    .map(|(_, bytes)| bytes)
                    .unwrap_or(0);

                let _ = finalize_wav_header(&mut file, total_bytes);
                is_rec.store(false, Ordering::Release);
                Ok(total_bytes as u64)
            })
            .map_err(|e| format!("Failed to spawn disk writer thread: {}", e))?;

        self.writer_thread = Some(handle);
        Ok(())
    }

    /// Starts writing audio using a shared thread-safe SPSC consumer for multi-session recording.
    pub fn start_shared(
        &mut self,
        path: &str,
        consumer_arc: Arc<Mutex<rtrb::Consumer<f32>>>,
    ) -> Result<(), String> {
        if self.is_recording() {
            return Err("Recording session is already active".to_string());
        }

        let mut file = Self::open_recording_file(path)?;
        let sr = self.sample_rate;
        let ch = self.channels as u16;
        let fmt = self.format;

        self.stop_signal.store(false, Ordering::Release);
        self.is_recording.store(true, Ordering::Release);

        let is_rec = self.is_recording.clone();
        let stop_sig = self.stop_signal.clone();

        let handle = std::thread::Builder::new()
            .name("miniaudio-wav-writer-shared".to_string())
            .spawn(move || {
                let buf_writer = BufWriter::with_capacity(65536, &mut file);
                let mut wav_writer = match WavSampleWriter::new(buf_writer, sr, ch, fmt) {
                    Ok(w) => w,
                    Err(e) => {
                        is_rec.store(false, Ordering::Release);
                        return Err(format!("Failed to write initial WAV header: {}", e));
                    }
                };

                while !stop_sig.load(Ordering::Acquire) {
                    let has_drained = consumer_arc
                        .lock()
                        .map(|mut c| wav_writer.drain_consumer(&mut c))
                        .unwrap_or(false);

                    if !has_drained {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                }

                if let Ok(mut consumer) = consumer_arc.lock() {
                    let _ = wav_writer.drain_consumer(&mut consumer);
                }

                let total_bytes = wav_writer
                    .flush_and_into_parts()
                    .map(|(_, bytes)| bytes)
                    .unwrap_or(0);

                let _ = finalize_wav_header(&mut file, total_bytes);
                is_rec.store(false, Ordering::Release);
                Ok(total_bytes as u64)
            })
            .map_err(|e| format!("Failed to spawn shared disk writer thread: {}", e))?;

        self.writer_thread = Some(handle);
        Ok(())
    }

    /// Stops the live recording session, flushes all remaining samples, and updates the WAV header.
    pub fn stop(&mut self) -> Result<u64, String> {
        if !self.is_recording() && self.writer_thread.is_none() {
            return Err("No active recording session to stop".to_string());
        }

        self.stop_signal.store(true, Ordering::Release);

        if let Some(handle) = self.writer_thread.take() {
            match handle.join() {
                Ok(res) => res,
                Err(_) => Err("Disk writer thread panicked".to_string()),
            }
        } else {
            Ok(0)
        }
    }
}
