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
    session: StreamSession,
    cursor: u64,
}

impl DemuxedStreamReader {
    /// Read timeout duration when waiting for asynchronous stream chunk delivery.
    pub const READ_WAIT_TIMEOUT: Duration = Duration::from_millis(5000);

    /// Creates a new `DemuxedStreamReader` over the given `StreamSession`.
    pub fn new(session: StreamSession) -> Self {
        Self { session, cursor: 0 }
    }

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
                let target = (tot as i64) + offset;
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
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        if buf.is_empty() {
            return Ok(0);
        }

        let probe_mode = self.session.in_probe_mode();
        match self.session.read_at(self.cursor, buf) {
            Ok(bytes_read) => {
                self.cursor += bytes_read as u64;
                if bytes_read > 0 && !probe_mode {
                    self.session.advance_read_cursor(self.cursor);
                }
                Ok(bytes_read)
            }
            Err(BufferError::Aborted) => {
                Err(IoError::new(ErrorKind::ConnectionAborted, "stream aborted"))
            }
            Err(BufferError::WouldBlock) => {
                if probe_mode {
                    if let Some(probe_res) = self.session.read_via_probe_cache(self.cursor, buf) {
                        return match probe_res {
                            Ok(n) => {
                                self.cursor += n as u64;
                                Ok(n)
                            }
                            Err(BufferError::Aborted) => {
                                Err(IoError::new(ErrorKind::ConnectionAborted, "stream aborted"))
                            }
                            Err(_) => Err(IoError::new(ErrorKind::Other, "probe read error")),
                        };
                    }
                }

                // Settled decode read (or fallback without probe range fetcher): re-anchor circular window.
                let _ = self.session.seek(self.cursor);
                match self
                    .session
                    .read_blocking(self.cursor, buf, Some(Self::READ_WAIT_TIMEOUT))
                {
                    Ok(bytes_read) => {
                        self.cursor += bytes_read as u64;
                        if bytes_read > 0 && !probe_mode {
                            self.session.advance_read_cursor(self.cursor);
                        }
                        Ok(bytes_read)
                    }
                    Err(BufferError::Eof) => Ok(0),
                    Err(BufferError::Aborted) => {
                        Err(IoError::new(ErrorKind::ConnectionAborted, "stream aborted"))
                    }
                    Err(BufferError::WouldBlock) => {
                        crate::map_log!(
                            1,
                            "DemuxedStreamReader::read WOULD_BLOCK at cursor={} (buf_len={})",
                            self.cursor,
                            buf.len()
                        );
                        Err(IoError::new(ErrorKind::WouldBlock, "buffer starving"))
                    }
                    Err(_) => Err(IoError::new(ErrorKind::Other, "buffer read error")),
                }
            }
            Err(BufferError::Eof) => Ok(0),
            Err(_) => Err(IoError::new(ErrorKind::Other, "buffer read error")),
        }
    }
}

impl Seek for DemuxedStreamReader {
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        let new_cursor = self.resolve_seek_target(pos)?;
        // Never flush the circular buffer on seek() alone; demuxer probes jump speculatively and
        // read() isolates probes or settles the circular window only when audio decoding commits.
        self.cursor = new_cursor;
        Ok(new_cursor)
    }
}

impl MediaSource for DemuxedStreamReader {
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

    fn byte_len(&self) -> Option<u64> {
        if self.session.is_live() || !self.is_seekable() {
            None
        } else {
            self.session
                .logical_end_offset()
                .or_else(|| self.session.total_size())
        }
    }
}

/// Seekable reader adapter over a `Sparse` [`StreamBuffer`] for universal metadata extraction.
pub struct MetadataStreamReader {
    buffer: Arc<StreamBuffer>,
    cursor: u64,
}

impl MetadataStreamReader {
    /// Creates a new `MetadataStreamReader` positioned at byte `0`.
    pub fn new(buffer: Arc<StreamBuffer>) -> Self {
        Self { buffer, cursor: 0 }
    }
}

impl Read for MetadataStreamReader {
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
            Err(BufferError::WouldBlock) => Err(IoError::new(
                ErrorKind::UnexpectedEof,
                "requested metadata offset is not buffered",
            )),
            Err(BufferError::Aborted) => Err(IoError::new(
                ErrorKind::ConnectionAborted,
                "metadata read aborted",
            )),
            Err(_) => Err(IoError::new(ErrorKind::Other, "metadata buffer read error")),
        }
    }
}

impl Seek for MetadataStreamReader {
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        let target = match pos {
            SeekFrom::Start(offset) => offset as i64,
            SeekFrom::Current(delta) => (self.cursor as i64) + delta,
            SeekFrom::End(delta) => {
                let Some(vsize) = self.buffer.virtual_size() else {
                    return Err(IoError::new(
                        ErrorKind::Unsupported,
                        "virtual size unknown for metadata buffer",
                    ));
                };
                (vsize as i64) + delta
            }
        };
        if target < 0 {
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
