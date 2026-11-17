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
use crate::sync::lock_unpoisoned;
use crate::sync::thread::{self, JoinHandle};

/// Maximum WAV data chunk payload allowed by 32-bit RIFF (`u32::MAX - 36`).
pub const MAX_RIFF_DATA_BYTES: u64 = (u32::MAX as u64) - 36;

/// Decodes a `file://` URI into a local OS filesystem path.
pub fn resolve_file_uri_to_local_path(uri: &str) -> Result<String, String> {
    let rest = uri
        .strip_prefix("file://")
        .or_else(|| uri.strip_prefix("FILE://"))
        .ok_or_else(|| format!("Invalid file:// URI '{}' (code: -2)", uri))?;

    let raw_path = if rest.starts_with('/') {
        rest
    } else if let Some(after_host) = rest.strip_prefix("localhost/") {
        let _ = after_host;
        &rest["localhost".len()..]
    } else if rest.len() >= 2 && rest.as_bytes()[1] == b':' {
        rest
    } else {
        return Err(format!(
            "Unsupported non-local file:// host in recording path '{}' (code: -9)",
            uri
        ));
    };

    let without_qf = raw_path.split(['?', '#']).next().unwrap_or(raw_path);
    let decoded = percent_decode_utf8(without_qf)?;

    #[cfg(windows)]
    let normalized = {
        let b = decoded.as_bytes();
        if b.len() >= 3 && b[0] == b'/' && b[2] == b':' {
            decoded[1..].to_string()
        } else {
            decoded
        }
    };
    #[cfg(not(windows))]
    let normalized = decoded;

    if normalized.trim().is_empty() {
        return Err(format!("Empty local path in file:// URI '{}' (code: -2)", uri));
    }
    Ok(normalized)
}

fn percent_decode_utf8(input: &str) -> Result<String, String> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return Err(format!("Invalid percent-encoding in URI '{}' (code: -2)", input));
            }
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3])
                .map_err(|_| format!("Invalid UTF-8 percent-encoding in '{}' (code: -2)", input))?;
            let val = u8::from_str_radix(hex, 16)
                .map_err(|_| format!("Invalid hex escape '%{}' in '{}' (code: -2)", hex, input))?;
            out.push(val);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out)
        .map_err(|_| format!("Non-UTF-8 characters in file:// URI '{}' (code: -2)", input))
}

/// Validates and normalizes a filesystem path or `file://` URI for native disk recording.
pub fn normalize_recording_path(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("Recording path cannot be empty (code: -2)".to_string());
    }

    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("file://") {
        return resolve_file_uri_to_local_path(trimmed);
    }

    if let Some(colon_idx) = trimmed.find("://") {
        let scheme = &trimmed[..colon_idx];
        if !scheme.is_empty()
            && scheme
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.')
        {
            return Err(format!(
                "Unsupported URI scheme '{}://' for recording path '{}' (code: -9)",
                scheme, raw
            ));
        }
    }
    if lower.starts_with("package:") {
        return Err(format!(
            "Unsupported URI scheme 'package:' for recording path '{}' (code: -9)",
            raw
        ));
    }

    Ok(raw.to_string())
}

fn map_open_io_error(path: &str, err: std::io::Error) -> String {
    let code = match err.kind() {
        std::io::ErrorKind::PermissionDenied => -10,
        std::io::ErrorKind::NotFound => -5,
        std::io::ErrorKind::InvalidInput => -2,
        _ => -1,
    };
    format!(
        "Failed to open recording destination '{}': {} (code: {})",
        path, err, code
    )
}

/// Supported WAV PCM encoding formats for live recording and offline bouncing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WavFormat {
    /// 16-bit signed integer linear PCM.
    #[default]
    Pcm16,
    /// 32-bit floating point linear PCM.
    Float32,
}

impl WavFormat {
    /// Returns the bit depth per sample for this encoding.
    #[inline]
    pub const fn bits_per_sample(self) -> u16 {
        match self {
            WavFormat::Pcm16 => 16,
            WavFormat::Float32 => 32,
        }
    }

    /// Returns the RIFF `wFormatTag` code.
    #[inline]
    pub const fn audio_format_code(self) -> u16 {
        match self {
            WavFormat::Pcm16 => 1,   // WAVE_FORMAT_PCM
            WavFormat::Float32 => 3, // WAVE_FORMAT_IEEE_FLOAT
        }
    }
}

/// Writes initial 44-byte RIFF/WAVE header with placeholder size fields.
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

/// Back-patches RIFF header sizes in `file` using the finalized `data_bytes` count.
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
    /// Constructs a `WavSampleWriter` writing an initial header to `writer`.
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

    /// Encodes and writes a single audio sample into the WAV payload, enforcing RIFF 4 GiB limits.
    #[inline]
    pub fn write_sample(&mut self, sample: f32) -> std::io::Result<()> {
        let sample_bytes = (self.format.bits_per_sample() / 8) as u64;
        if (self.data_bytes as u64) + sample_bytes > MAX_RIFF_DATA_BYTES {
            return Err(std::io::Error::other(
                "WAV RIFF 4 GiB maximum file size limit reached (code: -1)",
            ));
        }
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

    /// Drains all currently available samples from an SPSC ring buffer consumer into the WAV writer.
    /// Returns `Ok(true)` if samples were drained, `Ok(false)` if empty, or `Err` on write failure.
    pub fn drain_consumer_checked(
        &mut self,
        consumer: &mut rtrb::Consumer<f32>,
    ) -> std::io::Result<bool> {
        let slots = consumer.slots();
        if slots == 0 {
            return Ok(false);
        }
        let Ok(chunk) = consumer.read_chunk(slots) else {
            return Ok(false);
        };
        let (s1, s2) = chunk.as_slices();
        let mut write_err: Option<std::io::Error> = None;
        for &sample in s1.iter().chain(s2.iter()) {
            if let Err(e) = self.write_sample(sample) {
                write_err = Some(e);
                break;
            }
        }
        chunk.commit_all();
        if let Some(e) = write_err {
            return Err(e);
        }
        Ok(true)
    }

    /// Backwards-compatible infallible wrapper draining consumer samples.
    pub fn drain_consumer(&mut self, consumer: &mut rtrb::Consumer<f32>) -> bool {
        self.drain_consumer_checked(consumer).unwrap_or(false)
    }

    /// Flushes writer buffer and decomposes self into the underlying writer and total payload bytes written.
    pub fn flush_and_into_parts(mut self) -> std::io::Result<(W, u32)> {
        self.writer.flush()?;
        Ok((self.writer, self.data_bytes))
    }
}

/// Real-time live audio recording manager running on a dedicated disk writer thread.
pub struct LiveRecorder {
    is_recording: Arc<AtomicBool>,
    stop_signal: Arc<AtomicBool>,
    has_error: Arc<AtomicBool>,
    async_error: Arc<Mutex<Option<String>>>,
    writer_thread: Option<JoinHandle<Result<u64, String>>>,
    sample_rate: u32,
    channels: usize,
    format: WavFormat,
}

impl Drop for LiveRecorder {
    fn drop(&mut self) {
        if self.writer_thread.is_some() {
            let _ = self.stop();
        }
    }
}

impl LiveRecorder {
    /// Creates a new `LiveRecorder` configured with target sample rate, channels, and encoding format.
    pub fn new(sample_rate: u32, channels: usize, format: WavFormat) -> Self {
        Self {
            is_recording: Arc::new(AtomicBool::new(false)),
            stop_signal: Arc::new(AtomicBool::new(false)),
            has_error: Arc::new(AtomicBool::new(false)),
            async_error: Arc::new(Mutex::new(None)),
            writer_thread: None,
            sample_rate: sample_rate.max(8000),
            channels: channels.max(1),
            format,
        }
    }

    /// Returns whether a background disk recording session is active.
    pub fn is_recording(&self) -> bool {
        self.is_recording.load(Ordering::Acquire)
    }

    /// Wait-free poll for any asynchronous background disk/finalize error during recording.
    #[inline]
    pub fn poll_async_error(&self) -> Option<String> {
        if !self.has_error.load(Ordering::Acquire) {
            return None;
        }
        lock_unpoisoned(&self.async_error).clone()
    }

    fn open_recording_file(raw_path: &str) -> Result<File, String> {
        let local_path = normalize_recording_path(raw_path)?;
        OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&local_path)
            .map_err(|e| map_open_io_error(&local_path, e))
    }

    /// Opens the output file, allocates the SPSC ring buffer, and spawns the background
    /// disk writer thread outside any real-time or engine-clock critical section.
    pub fn prepare_start(
        sample_rate: u32,
        channels: usize,
        format: WavFormat,
        path: &str,
    ) -> Result<(Self, rtrb::Producer<f32>), String> {
        let sr = sample_rate.max(8000);
        let ch = channels.max(1);
        let (prod, cons) = rtrb::RingBuffer::new(sr as usize * ch * 4);
        let mut rec = Self::new(sr, ch, format);
        rec.start(path, cons)?;
        Ok((rec, prod))
    }

    /// Validates a caller-supplied POSIX file descriptor (`content://` SAF / MediaStore on Android),
    /// writes the initial WAV header, and spawns the background disk writer thread.
    #[cfg(unix)]
    pub fn prepare_start_fd(
        sample_rate: u32,
        channels: usize,
        format: WavFormat,
        raw_fd: std::os::unix::io::RawFd,
    ) -> Result<(Self, rtrb::Producer<f32>), String> {
        use std::os::unix::io::FromRawFd;
        if raw_fd < 0 {
            return Err("Invalid native file descriptor for recording (code: -2)".to_string());
        }
        // Take ownership immediately so any subsequent error closes `raw_fd` cleanly (RAII).
        let mut file = unsafe { File::from_raw_fd(raw_fd) };
        file.seek(SeekFrom::Start(0)).map_err(|e| {
            format!(
                "Recording descriptor must support seeking to finalize WAV header: {} (code: -9)",
                e
            )
        })?;
        let _ = file.set_len(0);
        file.seek(SeekFrom::Start(0)).map_err(|e| {
            format!(
                "Failed to rewind recording descriptor after truncation: {} (code: -1)",
                e
            )
        })?;

        let sr = sample_rate.max(8000);
        let ch = channels.max(1);
        let (prod, cons) = rtrb::RingBuffer::new(sr as usize * ch * 4);
        let mut rec = Self::new(sr, ch, format);
        rec.start_with_file(file, cons)?;
        Ok((rec, prod))
    }

    /// Starts writing audio to `path` using the consumer end of an SPSC ring buffer.
    pub fn start(&mut self, path: &str, consumer: rtrb::Consumer<f32>) -> Result<(), String> {
        if self.is_recording() || self.writer_thread.is_some() {
            return Err("Recording session is already active (code: -6)".to_string());
        }
        let file = Self::open_recording_file(path)?;
        self.start_with_file(file, consumer)
    }

    fn start_with_file(
        &mut self,
        file: File,
        mut consumer: rtrb::Consumer<f32>,
    ) -> Result<(), String> {
        if self.is_recording() || self.writer_thread.is_some() {
            return Err("Recording session is already active (code: -6)".to_string());
        }

        let sr = self.sample_rate;
        let ch = self.channels as u16;
        let fmt = self.format;

        // Validate and emit initial 44-byte WAV header before spawning so non-writable targets fail fast.
        let buf_writer = BufWriter::with_capacity(65536, file);
        let mut wav_writer = WavSampleWriter::new(buf_writer, sr, ch, fmt)
            .map_err(|e| format!("Failed to write initial WAV header: {} (code: -1)", e))?;
        wav_writer
            .writer
            .flush()
            .map_err(|e| format!("Failed to flush initial WAV header: {} (code: -1)", e))?;

        self.stop_signal.store(false, Ordering::Release);
        self.has_error.store(false, Ordering::Release);
        *lock_unpoisoned(&self.async_error) = None;
        self.is_recording.store(true, Ordering::Release);

        let is_rec = self.is_recording.clone();
        let stop_sig = self.stop_signal.clone();
        let has_err = self.has_error.clone();
        let err_slot = self.async_error.clone();

        let handle = thread::Builder::new()
            .name("miniaudio-wav-writer".to_string())
            .spawn(move || {
                let mut write_failure: Option<String> = None;

                while !stop_sig.load(Ordering::Acquire) || consumer.slots() > 0 {
                    match wav_writer.drain_consumer_checked(&mut consumer) {
                        Ok(true) => {}
                        Ok(false) => thread::sleep(std::time::Duration::from_millis(10)),
                        Err(e) => {
                            let msg = format!("Recording write failed: {} (code: -1)", e);
                            *lock_unpoisoned(&err_slot) = Some(msg.clone());
                            has_err.store(true, Ordering::Release);
                            write_failure = Some(msg);
                            break;
                        }
                    }
                }

                let finalize_res = (|| -> Result<u64, String> {
                    let (buf_writer_done, total_bytes) = wav_writer
                        .flush_and_into_parts()
                        .map_err(|e| format!("Failed to flush recording audio data: {} (code: -1)", e))?;
                    let mut raw_file = buf_writer_done
                        .into_inner()
                        .map_err(|e| format!("Failed to unwrap recording writer: {} (code: -1)", e.error()))?;
                    finalize_wav_header(&mut raw_file, total_bytes)
                        .map_err(|e| format!("Failed to finalize WAV header: {} (code: -1)", e))?;
                    Ok(total_bytes as u64)
                })();

                is_rec.store(false, Ordering::Release);

                if let Some(err_msg) = write_failure {
                    return Err(err_msg);
                }
                match finalize_res {
                    Ok(bytes) => Ok(bytes),
                    Err(e) => {
                        *lock_unpoisoned(&err_slot) = Some(e.clone());
                        has_err.store(true, Ordering::Release);
                        Err(e)
                    }
                }
            })
            .map_err(|e| {
                self.is_recording.store(false, Ordering::Release);
                format!("Failed to spawn disk writer thread: {} (code: -1)", e)
            })?;

        self.writer_thread = Some(handle);
        Ok(())
    }

    /// Stops the live recording session, flushes all remaining samples, and updates the WAV header.
    pub fn stop(&mut self) -> Result<u64, String> {
        if !self.is_recording() && self.writer_thread.is_none() {
            return Err("No active recording session to stop (code: -6)".to_string());
        }

        self.stop_signal.store(true, Ordering::Release);

        if let Some(handle) = self.writer_thread.take() {
            match handle.join() {
                Ok(res) => res,
                Err(_) => Err("Disk writer thread panicked (code: -1)".to_string()),
            }
        } else if let Some(err) = self.poll_async_error() {
            Err(err)
        } else {
            Ok(0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_file_uris_and_rejects_invalid_schemes() {
        assert_eq!(
            normalize_recording_path("file:///tmp/my%20mix.wav").unwrap(),
            if cfg!(windows) { "/tmp/my mix.wav" } else { "/tmp/my mix.wav" }
        );
        assert_eq!(
            normalize_recording_path("file://localhost/tmp/test.wav").unwrap(),
            "/tmp/test.wav"
        );
        assert!(normalize_recording_path("").is_err());
        assert!(normalize_recording_path("   ").is_err());
        assert!(normalize_recording_path("https://example.com/out.wav").is_err());
        assert!(normalize_recording_path("asset://audio/a.wav").is_err());
        assert!(normalize_recording_path("package:app/a.wav").is_err());
        assert!(normalize_recording_path("content://media/external/1").is_err());
    }

    #[test]
    fn wav_writer_float32_header_and_riff_limit_guard() {
        let mut cursor = std::io::Cursor::new(Vec::<u8>::new());
        let mut writer = WavSampleWriter::new(&mut cursor, 48_000, 2, WavFormat::Float32).unwrap();
        writer.write_sample(0.5).unwrap();
        writer.data_bytes = (MAX_RIFF_DATA_BYTES - 2) as u32;
        assert!(writer.write_sample(0.25).is_err());

        let (done_cursor, _) = writer.flush_and_into_parts().unwrap();
        let bytes = done_cursor.get_ref();
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(u16::from_le_bytes(bytes[20..22].try_into().unwrap()), 3); // IEEE float
        assert_eq!(u16::from_le_bytes(bytes[34..36].try_into().unwrap()), 32); // bits/sample
    }

    #[test]
    fn drop_finalizes_wav_header_even_without_explicit_stop() {
        let path = std::env::temp_dir().join(format!(
            "miniaudio_drop_finalize_{}.wav",
            std::process::id()
        ));
        let path_str = path.to_string_lossy().into_owned();
        let _ = std::fs::remove_file(&path);

        let (mut prod, cons) = rtrb::RingBuffer::new(1024);
        {
            let mut rec = LiveRecorder::new(48_000, 2, WavFormat::Float32);
            rec.start(&path_str, cons).unwrap();
            let samples = [0.25f32, -0.25f32, 0.5f32, -0.5f32];
            if let Ok(mut chunk) = prod.write_chunk(samples.len()) {
                chunk.as_mut_slices().0.copy_from_slice(&samples);
                chunk.commit_all();
            }
            std::thread::sleep(std::time::Duration::from_millis(30));
            drop(prod);
            // `rec` dropped here without calling stop() -> Drop must finalize RIFF header!
        }

        let bytes = std::fs::read(&path).expect("output wav exists");
        assert_eq!(bytes.len(), 44 + 16);
        let riff_size = u32::from_le_bytes(bytes[4..8].try_into().unwrap());
        let data_size = u32::from_le_bytes(bytes[40..44].try_into().unwrap());
        assert_eq!(data_size, 16);
        assert_eq!(riff_size, 16 + 36);
        let _ = std::fs::remove_file(&path);
    }

    #[cfg(unix)]
    #[test]
    fn prepare_start_fd_writes_valid_wav_on_seekable_file() {
        use std::os::unix::io::IntoRawFd;
        let path = std::env::temp_dir().join(format!(
            "miniaudio_fd_rec_{}.wav",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .unwrap();
        let raw_fd = file.into_raw_fd();

        let (mut rec, mut prod) =
            LiveRecorder::prepare_start_fd(48_000, 2, WavFormat::Pcm16, raw_fd).unwrap();
        let samples = [0.5f32, -0.5f32, 0.25f32, -0.25f32];
        if let Ok(mut chunk) = prod.write_chunk(samples.len()) {
            chunk.as_mut_slices().0.copy_from_slice(&samples);
            chunk.commit_all();
        }
        std::thread::sleep(std::time::Duration::from_millis(30));
        let data_bytes = rec.stop().unwrap();
        assert_eq!(data_bytes, 8);

        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(bytes.len(), 52);
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 8);
        let _ = std::fs::remove_file(&path);
    }
}
