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
use std::sync::Arc;
use std::thread::JoinHandle;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WavFormat {
    #[default]
    Pcm16,
    Float32,
}

pub fn write_wav_header<W: Write>(
    writer: &mut W,
    sample_rate: u32,
    channels: u16,
    format: WavFormat,
) -> std::io::Result<()> {
    let bits_per_sample: u16 = match format {
        WavFormat::Pcm16 => 16,
        WavFormat::Float32 => 32,
    };
    let audio_format: u16 = match format {
        WavFormat::Pcm16 => 1,      // WAVE_FORMAT_PCM
        WavFormat::Float32 => 3,    // WAVE_FORMAT_IEEE_FLOAT
    };
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
    let riff_size = data_bytes + 36;
    file.seek(SeekFrom::Start(4))?;
    file.write_all(&riff_size.to_le_bytes())?;

    file.seek(SeekFrom::Start(40))?;
    file.write_all(&data_bytes.to_le_bytes())?;
    file.flush()?;
    Ok(())
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

    let mut writer = BufWriter::new(&mut file);
    write_wav_header(&mut writer, sample_rate, channels as u16, format)
        .map_err(|e| format!("Failed to write WAV header: {}", e))?;

    let mut data_bytes = 0u32;
    match format {
        WavFormat::Pcm16 => {
            for &sample in pcm_samples {
                let clamped = sample.clamp(-1.0, 1.0);
                let pcm16 = (clamped * 32767.0).round() as i16;
                writer.write_all(&pcm16.to_le_bytes())
                    .map_err(|e| format!("Write error: {}", e))?;
                data_bytes += 2;
            }
        }
        WavFormat::Float32 => {
            for &sample in pcm_samples {
                writer.write_all(&sample.to_le_bytes())
                    .map_err(|e| format!("Write error: {}", e))?;
                data_bytes += 4;
            }
        }
    }

    writer.flush().map_err(|e| format!("Flush error: {}", e))?;
    drop(writer);

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

    /// Starts writing audio to `path` using the consumer end of an SPSC ring buffer.
    pub fn start(
        &mut self,
        path: &str,
        mut consumer: rtrb::Consumer<f32>,
    ) -> Result<(), String> {
        if self.is_recording() {
            return Err("Recording session is already active".to_string());
        }

        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)
            .map_err(|e| format!("Failed to create recording file '{}': {}", path, e))?;

        let sr = self.sample_rate;
        let ch = self.channels;
        let fmt = self.format;

        self.stop_signal.store(false, Ordering::Release);
        self.is_recording.store(true, Ordering::Release);

        let is_rec = self.is_recording.clone();
        let stop_sig = self.stop_signal.clone();

        let handle = std::thread::Builder::new()
            .name("miniaudio-wav-writer".to_string())
            .spawn(move || {
                let mut writer = BufWriter::with_capacity(65536, &mut file);
                if let Err(e) = write_wav_header(&mut writer, sr, ch as u16, fmt) {
                    is_rec.store(false, Ordering::Release);
                    return Err(format!("Failed to write initial WAV header: {}", e));
                }

                let mut total_bytes = 0u32;

                while !stop_sig.load(Ordering::Acquire) || consumer.slots() > 0 {
                    let slots = consumer.slots();
                    if slots > 0 {
                        if let Ok(chunk) = consumer.read_chunk(slots) {
                            let (s1, s2) = chunk.as_slices();
                            for &sample in s1.iter().chain(s2.iter()) {
                                match fmt {
                                    WavFormat::Pcm16 => {
                                        let clamped = sample.clamp(-1.0, 1.0);
                                        let pcm16 = (clamped * 32767.0).round() as i16;
                                        if writer.write_all(&pcm16.to_le_bytes()).is_err() {
                                            break;
                                        }
                                        total_bytes = total_bytes.saturating_add(2);
                                    }
                                    WavFormat::Float32 => {
                                        if writer.write_all(&sample.to_le_bytes()).is_err() {
                                            break;
                                        }
                                        total_bytes = total_bytes.saturating_add(4);
                                    }
                                }
                            }
                            chunk.commit_all();
                        }
                    } else {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                }

                let _ = writer.flush();
                drop(writer);

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
        consumer_arc: Arc<std::sync::Mutex<rtrb::Consumer<f32>>>,
    ) -> Result<(), String> {
        if self.is_recording() {
            return Err("Recording session is already active".to_string());
        }

        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)
            .map_err(|e| format!("Failed to create recording file '{}': {}", path, e))?;

        let sr = self.sample_rate;
        let ch = self.channels;
        let fmt = self.format;

        self.stop_signal.store(false, Ordering::Release);
        self.is_recording.store(true, Ordering::Release);

        let is_rec = self.is_recording.clone();
        let stop_sig = self.stop_signal.clone();

        let handle = std::thread::Builder::new()
            .name("miniaudio-wav-writer-shared".to_string())
            .spawn(move || {
                let mut writer = BufWriter::with_capacity(65536, &mut file);
                if let Err(e) = write_wav_header(&mut writer, sr, ch as u16, fmt) {
                    is_rec.store(false, Ordering::Release);
                    return Err(format!("Failed to write initial WAV header: {}", e));
                }

                let mut total_bytes = 0u32;

                while !stop_sig.load(Ordering::Acquire) {
                    let mut has_drained = false;
                    if let Ok(mut consumer) = consumer_arc.lock() {
                        let slots = consumer.slots();
                        if slots > 0 {
                            if let Ok(chunk) = consumer.read_chunk(slots) {
                                let (s1, s2) = chunk.as_slices();
                                for &sample in s1.iter().chain(s2.iter()) {
                                    match fmt {
                                        WavFormat::Pcm16 => {
                                            let clamped = sample.clamp(-1.0, 1.0);
                                            let pcm16 = (clamped * 32767.0).round() as i16;
                                            if writer.write_all(&pcm16.to_le_bytes()).is_err() {
                                                break;
                                            }
                                            total_bytes = total_bytes.saturating_add(2);
                                        }
                                        WavFormat::Float32 => {
                                            if writer.write_all(&sample.to_le_bytes()).is_err() {
                                                break;
                                            }
                                            total_bytes = total_bytes.saturating_add(4);
                                        }
                                    }
                                }
                                chunk.commit_all();
                                has_drained = true;
                            }
                        }
                    }

                    if !has_drained {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                }

                // Final drain
                if let Ok(mut consumer) = consumer_arc.lock() {
                    let slots = consumer.slots();
                    if slots > 0 {
                        if let Ok(chunk) = consumer.read_chunk(slots) {
                            let (s1, s2) = chunk.as_slices();
                            for &sample in s1.iter().chain(s2.iter()) {
                                match fmt {
                                    WavFormat::Pcm16 => {
                                        let clamped = sample.clamp(-1.0, 1.0);
                                        let pcm16 = (clamped * 32767.0).round() as i16;
                                        let _ = writer.write_all(&pcm16.to_le_bytes());
                                        total_bytes = total_bytes.saturating_add(2);
                                    }
                                    WavFormat::Float32 => {
                                        let _ = writer.write_all(&sample.to_le_bytes());
                                        total_bytes = total_bytes.saturating_add(4);
                                    }
                                }
                            }
                            chunk.commit_all();
                        }
                    }
                }

                let _ = writer.flush();
                drop(writer);

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_offline_bounce_creates_valid_wav_file() {
        let temp_dir = std::env::temp_dir();
        let path = temp_dir.join("test_bounce.wav");
        let path_str = path.to_str().unwrap();

        let samples = vec![0.5f32, -0.5f32, 0.25f32, -0.25f32]; // 2 frames stereo
        let bytes_written = offline_bounce_to_wav(path_str, &samples, 48000, 2, WavFormat::Pcm16)
            .expect("Bounce failed");

        assert_eq!(bytes_written, 8); // 4 samples * 2 bytes (16-bit) = 8 bytes

        // Verify file size is 44 (header) + 8 = 52 bytes
        let metadata = std::fs::metadata(&path).unwrap();
        assert_eq!(metadata.len(), 52);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_live_recorder_lifecycle_and_drain() {
        let temp_dir = std::env::temp_dir();
        let path = temp_dir.join("test_live_rec.wav");
        let path_str = path.to_str().unwrap();

        let (mut producer, consumer) = rtrb::RingBuffer::new(1024);
        let mut recorder = LiveRecorder::new(44100, 2, WavFormat::Pcm16);

        recorder.start(path_str, consumer).expect("Start failed");
        assert!(recorder.is_recording());

        // Feed some frames through producer
        let frames = [0.1f32, -0.1f32, 0.2f32, -0.2f32];
        if let Ok(mut chunk) = producer.write_chunk(frames.len()) {
            let (s1, s2) = chunk.as_mut_slices();
            s1.copy_from_slice(&frames[..s1.len()]);
            if !s2.is_empty() {
                s2.copy_from_slice(&frames[s1.len()..]);
            }
            chunk.commit_all();
        }

        std::thread::sleep(std::time::Duration::from_millis(50));

        let recorded_bytes = recorder.stop().expect("Stop failed");
        assert_eq!(recorded_bytes, 8);
        assert!(!recorder.is_recording());

        let metadata = std::fs::metadata(&path).unwrap();
        assert_eq!(metadata.len(), 52);

        let _ = std::fs::remove_file(&path);
    }
}
