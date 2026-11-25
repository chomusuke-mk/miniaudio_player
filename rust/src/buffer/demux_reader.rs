//! Virtual Stream Readers (`DemuxedStreamReader` and `MetadataStreamReader`).
//!
//! - [`DemuxedStreamReader`]: Bridges `Head` (`Linear`) and `Body` (`Circular`) [`StreamBuffer`]s
//!   into a single seamless `Read + Seek + MediaSource` view for audio decoders without merging
//!   their physical memory.
//! - [`MetadataStreamReader`]: Provides a `Read + Seek` cursor over a `Sparse` [`StreamBuffer`]
//!   for [`crate::metadata::UniversalMetadataExtractor`].

use std::io::{Error as IoError, ErrorKind, Read, Result as IoResult, Seek, SeekFrom};
use std::sync::Arc;
use std::time::Duration;
use symphonia::core::io::MediaSource;

use super::stream_buffer::{BufferError, StreamBuffer, StreamSession};

/// Virtual composite `Read + Seek + MediaSource` reader over a [`StreamSession`] (`Head` + `Body`).
pub struct DemuxedStreamReader {
    /// Underlying dual-region stream session backing reads and seeks.
    session: StreamSession,
    /// Logical read cursor relative to `base_offset`.
    cursor: u64,
    /// Physical stream byte offset mapped to virtual offset `0`.
    base_offset: u64,
}

impl DemuxedStreamReader {
    /// Read timeout duration when waiting for asynchronous stream chunk delivery.
    pub const READ_WAIT_TIMEOUT: Duration = Duration::from_millis(5000);

    /// Creates a new [`DemuxedStreamReader`] over the given `session` starting at physical offset `0`.
    pub fn new(session: StreamSession) -> Self {
        Self::new_at(session, 0)
    }

    /// Creates a [`DemuxedStreamReader`] over `session` whose virtual offset `0` maps to physical `base_offset`.
    pub fn new_at(session: StreamSession, base_offset: u64) -> Self {
        crate::map_log!(
            4,
            "[BUFFER] DemuxedStreamReader::new_at base_offset={}",
            base_offset
        );
        Self {
            session,
            cursor: 0,
            base_offset,
        }
    }

    /// Updates either the probe read high-water mark or the settled decode read cursor up to `new_phys` depending on `probe_mode`.
    #[inline]
    fn record_read_progress(&self, probe_mode: bool, new_phys: u64) {
        if probe_mode {
            self.session.note_probe_read_end(new_phys);
            if !self.session.supports_range() {
                self.session.advance_read_cursor(new_phys);
            }
        } else {
            self.session.advance_read_cursor(new_phys);
        }
    }

    /// Resolves a relative or absolute [`SeekFrom`] `pos` into a virtual cursor offset relative to `base_offset`.
    ///
    /// # Errors
    /// Returns [`ErrorKind::InvalidInput`] if the resolved target is negative, or
    /// [`ErrorKind::Unsupported`] when seeking from the end on a live stream without a known length.
    fn resolve_seek_target(&self, pos: SeekFrom) -> IoResult<u64> {
        match pos {
            SeekFrom::Start(offset) => Ok(offset),
            SeekFrom::Current(offset) => {
                let target = (self.cursor as i64) + offset;
                if target < 0 {
                    return Err(IoError::new(
                        ErrorKind::InvalidInput,
                        "negative seek cursor",
                    ));
                }
                Ok(target as u64)
            }
            SeekFrom::End(offset) => {
                let Some(tot) = self
                    .session
                    .logical_end_offset()
                    .or_else(|| self.session.total_size())
                else {
                    return Err(IoError::new(
                        ErrorKind::Unsupported,
                        "cannot seek from end on live stream",
                    ));
                };
                let rel_tot = tot.saturating_sub(self.base_offset) as i64;
                let target = rel_tot + offset;
                if target < 0 {
                    return Err(IoError::new(
                        ErrorKind::InvalidInput,
                        "negative seek cursor",
                    ));
                }
                Ok(target as u64)
            }
        }
    }
}

impl Read for DemuxedStreamReader {
    /// Reads buffered or asynchronously fetched stream bytes into `buf` and advances the virtual cursor.
    ///
    /// # Errors
    /// Propagates stream abortion, seek preemption, read timeout, or underlying buffer errors as `std::io::Error`.
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        if buf.is_empty() {
            return Ok(0);
        }

        let probe_mode = self.session.in_probe_mode();
        let phys_cursor = self.base_offset.saturating_add(self.cursor);
        match self.session.read_at(phys_cursor, buf) {
            Ok(bytes_read) => {
                self.cursor += bytes_read as u64;
                if bytes_read > 0 {
                    self.record_read_progress(probe_mode, phys_cursor + bytes_read as u64);
                }
                Ok(bytes_read)
            }
            Err(BufferError::Aborted) => {
                crate::map_log!(
                    2,
                    "[BUFFER] DemuxedStreamReader::read aborted at cursor={} (phys={})",
                    self.cursor,
                    phys_cursor
                );
                Err(IoError::new(ErrorKind::ConnectionAborted, "stream aborted"))
            }
            Err(BufferError::WouldBlock) => {
                if probe_mode {
                    if let Some(probe_res) = self.session.read_via_probe_cache(phys_cursor, buf) {
                        return match probe_res {
                            Ok(n) => {
                                self.cursor += n as u64;
                                if n > 0 {
                                    self.session.note_probe_read_end(phys_cursor + n as u64);
                                }
                                Ok(n)
                            }
                            Err(BufferError::Aborted) => {
                                crate::map_log!(
                                    2,
                                    "[BUFFER] DemuxedStreamReader::read probe aborted at cursor={} (phys={})",
                                    self.cursor,
                                    phys_cursor
                                );
                                Err(IoError::new(ErrorKind::ConnectionAborted, "stream aborted"))
                            }
                            Err(BufferError::SeekInterrupted) => {
                                crate::map_log!(
                                    4,
                                    "[BUFFER] DemuxedStreamReader::read probe seek-preempted at cursor={} (phys={})",
                                    self.cursor,
                                    phys_cursor
                                );
                                Err(IoError::new(ErrorKind::TimedOut, "seek preempted"))
                            }
                            Err(_) => {
                                crate::map_log!(
                                    1,
                                    "[BUFFER] DemuxedStreamReader::read probe error at cursor={} (phys={})",
                                    self.cursor,
                                    phys_cursor
                                );
                                Err(IoError::new(ErrorKind::Other, "probe read error"))
                            }
                        };
                    }
                }

                // Settled decode read (or fallback without probe range fetcher): re-anchor circular window.
                let _ = self.session.seek(phys_cursor);
                match self
                    .session
                    .read_blocking(phys_cursor, buf, Some(Self::READ_WAIT_TIMEOUT))
                {
                    Ok(bytes_read) => {
                        self.cursor += bytes_read as u64;
                        if bytes_read > 0 {
                            self.record_read_progress(probe_mode, phys_cursor + bytes_read as u64);
                        }
                        Ok(bytes_read)
                    }
                    Err(BufferError::Eof) => Ok(0),
                    Err(BufferError::Aborted) => {
                        crate::map_log!(
                            2,
                            "[BUFFER] DemuxedStreamReader::read blocking aborted at cursor={} (phys={})",
                            self.cursor,
                            phys_cursor
                        );
                        Err(IoError::new(ErrorKind::ConnectionAborted, "stream aborted"))
                    }
                    Err(BufferError::SeekInterrupted) => {
                        crate::map_log!(
                            4,
                            "[BUFFER] DemuxedStreamReader::read blocking seek-preempted at cursor={} (phys={})",
                            self.cursor,
                            phys_cursor
                        );
                        Err(IoError::new(ErrorKind::TimedOut, "seek preempted"))
                    }
                    Err(BufferError::WouldBlock) => {
                        crate::map_log!(
                            1,
                            "[BUFFER] DemuxedStreamReader::read WOULD_BLOCK at cursor={} (phys={}, buf_len={})",
                            self.cursor,
                            phys_cursor,
                            buf.len()
                        );
                        Err(IoError::new(ErrorKind::WouldBlock, "buffer starving"))
                    }
                    Err(_) => {
                        crate::map_log!(
                            1,
                            "[BUFFER] DemuxedStreamReader::read blocking error at cursor={} (phys={})",
                            self.cursor,
                            phys_cursor
                        );
                        Err(IoError::new(ErrorKind::Other, "buffer read error"))
                    }
                }
            }
            Err(BufferError::Eof) => Ok(0),
            Err(BufferError::SeekInterrupted) => {
                crate::map_log!(
                    4,
                    "[BUFFER] DemuxedStreamReader::read seek-preempted at cursor={} (phys={})",
                    self.cursor,
                    phys_cursor
                );
                Err(IoError::new(ErrorKind::TimedOut, "seek preempted"))
            }
            Err(_) => {
                crate::map_log!(
                    1,
                    "[BUFFER] DemuxedStreamReader::read error at cursor={} (phys={})",
                    self.cursor,
                    phys_cursor
                );
                Err(IoError::new(ErrorKind::Other, "buffer read error"))
            }
        }
    }
}

impl Seek for DemuxedStreamReader {
    /// Updates the virtual read cursor to `pos` and notifies probe mode when jumping non-sequentially.
    ///
    /// # Errors
    /// Returns an `std::io::Error` if `pos` resolves to a negative offset or seeks from end on a live stream.
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        let prev_cursor = self.cursor;
        let new_cursor = match self.resolve_seek_target(pos) {
            Ok(target) => target,
            Err(err) => {
                crate::map_log!(
                    2,
                    "[BUFFER] DemuxedStreamReader::seek failed for {:?}: {}",
                    pos,
                    err
                );
                return Err(err);
            }
        };
        if self.session.in_probe_mode()
            && (matches!(pos, SeekFrom::Start(_)) || new_cursor.abs_diff(prev_cursor) > 1024)
        {
            self.session
                .note_probe_seek_target(self.base_offset.saturating_add(new_cursor));
        }
        self.cursor = new_cursor;
        Ok(new_cursor)
    }
}

impl MediaSource for DemuxedStreamReader {
    /// Returns `true` when the underlying stream supports random-access seeking.
    fn is_seekable(&self) -> bool {
        if self.session.is_live() {
            return false;
        }
        if self.session.is_decoding_audio() {
            return true;
        }
        self.session.total_size().is_some()
            && (self.session.supports_range()
                || !self.session.tail_data().is_empty()
                || self.session.is_fully_buffered())
    }

    /// Returns the remaining seekable byte length relative to `base_offset`, or `None` for unseekable/live streams.
    fn byte_len(&self) -> Option<u64> {
        if self.session.is_live() || !self.is_seekable() {
            None
        } else {
            self.session
                .logical_end_offset()
                .or_else(|| self.session.total_size())
                .map(|tot| tot.saturating_sub(self.base_offset))
        }
    }
}

/// Seekable reader adapter over a `Sparse` [`StreamBuffer`] for universal metadata extraction.
pub struct MetadataStreamReader {
    /// Sparse [`StreamBuffer`] storing metadata header/tail byte ranges.
    buffer: Arc<StreamBuffer>,
    /// Current logical byte cursor within `buffer`.
    cursor: u64,
}

impl MetadataStreamReader {
    /// Creates a new [`MetadataStreamReader`] backed by `buffer` and positioned at byte `0`.
    pub fn new(buffer: Arc<StreamBuffer>) -> Self {
        Self { buffer, cursor: 0 }
    }
}

impl Read for MetadataStreamReader {
    /// Reads sparse-buffered metadata bytes into `buf` and advances the cursor.
    ///
    /// # Errors
    /// Returns [`ErrorKind::UnexpectedEof`] when the requested offset is unbuffered,
    /// [`ErrorKind::ConnectionAborted`] if aborted, or [`ErrorKind::Other`] on other buffer errors.
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        match self.buffer.read_at(self.cursor, buf) {
            Ok(n) => {
                self.cursor += n as u64;
                Ok(n)
            }
            Err(BufferError::Eof) => Ok(0),
            Err(BufferError::WouldBlock) => {
                crate::map_log!(
                    4,
                    "[BUFFER] MetadataStreamReader::read unbuffered offset={} len={}",
                    self.cursor,
                    buf.len()
                );
                Err(IoError::new(
                    ErrorKind::UnexpectedEof,
                    "requested metadata offset is not buffered",
                ))
            }
            Err(BufferError::Aborted) => {
                crate::map_log!(
                    2,
                    "[BUFFER] MetadataStreamReader::read aborted at offset={}",
                    self.cursor
                );
                Err(IoError::new(
                    ErrorKind::ConnectionAborted,
                    "metadata read aborted",
                ))
            }
            Err(_) => {
                crate::map_log!(
                    1,
                    "[BUFFER] MetadataStreamReader::read error at offset={}",
                    self.cursor
                );
                Err(IoError::new(ErrorKind::Other, "metadata buffer read error"))
            }
        }
    }
}

impl Seek for MetadataStreamReader {
    /// Seeks the metadata cursor to `pos` and updates the sparse buffer cursor hint.
    ///
    /// # Errors
    /// Returns [`ErrorKind::Unsupported`] when seeking from end without a known virtual size, or
    /// [`ErrorKind::InvalidInput`] if the resulting offset is negative.
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        let target = match pos {
            SeekFrom::Start(offset) => offset as i64,
            SeekFrom::Current(delta) => (self.cursor as i64) + delta,
            SeekFrom::End(delta) => {
                let Some(vsize) = self.buffer.virtual_size() else {
                    crate::map_log!(
                        2,
                        "[BUFFER] MetadataStreamReader::seek SeekFrom::End unsupported without virtual_size"
                    );
                    return Err(IoError::new(
                        ErrorKind::Unsupported,
                        "virtual size unknown for metadata buffer",
                    ));
                };
                (vsize as i64) + delta
            }
        };
        if target < 0 {
            crate::map_log!(
                2,
                "[BUFFER] MetadataStreamReader::seek negative target={}",
                target
            );
            return Err(IoError::new(
                ErrorKind::InvalidInput,
                "negative metadata seek offset",
            ));
        }
        self.cursor = target as u64;
        self.buffer.set_cursor(self.cursor);
        Ok(self.cursor)
    }
}
