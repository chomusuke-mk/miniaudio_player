//! Sequential & Random-Access `Read + Seek + MediaSource` adapter over `TripartiteBuffer`.

use std::io::{Error as IoError, ErrorKind, Read, Result as IoResult, Seek, SeekFrom};
use std::time::Duration;
use symphonia::core::io::MediaSource;

use super::tripartite::{BufferError, TripartiteBuffer};

pub struct BufferStreamReader {
    buffer: TripartiteBuffer,
    cursor: u64,
}

impl BufferStreamReader {
    pub const READ_WAIT_TIMEOUT: Duration = Duration::from_millis(50);

    pub fn new(buffer: TripartiteBuffer) -> Self {
        Self { buffer, cursor: 0 }
    }

    #[inline]
    pub fn cursor(&self) -> u64 {
        self.cursor
    }

    #[inline]
    pub fn buffer(&self) -> &TripartiteBuffer {
        &self.buffer
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
                let Some(tot) = self.buffer.total_size() else {
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

impl Read for BufferStreamReader {
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        match self
            .buffer
            .read_blocking(self.cursor, buf, Some(Self::READ_WAIT_TIMEOUT))
        {
            Ok(bytes_read) => {
                self.cursor += bytes_read as u64;
                self.buffer.advance_read_cursor(self.cursor);
                Ok(bytes_read)
            }
            Err(BufferError::Eof) => Ok(0),
            Err(BufferError::Aborted) => {
                Err(IoError::new(ErrorKind::Interrupted, "stream aborted"))
            }
            Err(BufferError::WouldBlock) => {
                Err(IoError::new(ErrorKind::WouldBlock, "buffer starving"))
            }
            Err(_) => Err(IoError::new(ErrorKind::Other, "buffer read error")),
        }
    }
}

impl Seek for BufferStreamReader {
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        let new_cursor = self.resolve_seek_target(pos)?;
        self.cursor = new_cursor;
        let _ = self.buffer.seek(new_cursor);
        Ok(new_cursor)
    }
}

impl MediaSource for BufferStreamReader {
    fn is_seekable(&self) -> bool {
        !self.buffer.is_live() && (self.buffer.is_tail_locked() || self.buffer.is_fully_buffered())
    }

    fn byte_len(&self) -> Option<u64> {
        if self.buffer.is_tail_locked() || self.buffer.is_fully_buffered() {
            self.buffer.total_size()
        } else {
            None
        }
    }
}
