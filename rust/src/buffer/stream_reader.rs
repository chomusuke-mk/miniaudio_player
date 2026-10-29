use std::io::{Error as IoError, ErrorKind, Read, Result as IoResult, Seek, SeekFrom};
use symphonia::core::io::MediaSource;

use super::tripartite::{BufferError, TripartiteBuffer};

pub struct BufferStreamReader {
    buffer: TripartiteBuffer,
    cursor: u64,
}

impl BufferStreamReader {
    pub fn new(buffer: TripartiteBuffer) -> Self {
        Self { buffer, cursor: 0 }
    }

    pub fn cursor(&self) -> u64 {
        self.cursor
    }

    pub fn buffer(&self) -> &TripartiteBuffer {
        &self.buffer
    }
}

impl Read for BufferStreamReader {
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        match self.buffer.read_blocking(self.cursor, buf, Some(std::time::Duration::from_millis(50))) {
            Ok(bytes_read) => {
                self.cursor += bytes_read as u64;
                let _ = self.buffer.seek(self.cursor);
                Ok(bytes_read)
            }
            Err(BufferError::Eof) => Ok(0),
            Err(BufferError::Aborted) => Err(IoError::new(ErrorKind::Interrupted, "stream aborted")),
            Err(BufferError::WouldBlock) => Err(IoError::new(ErrorKind::WouldBlock, "buffer starving")),
            Err(_) => Err(IoError::new(ErrorKind::Other, "buffer read error")),
        }
    }
}

impl Seek for BufferStreamReader {
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        let total_size = self.buffer.total_size();
        let new_cursor = match pos {
            SeekFrom::Start(offset) => offset,
            SeekFrom::Current(offset) => {
                let target = (self.cursor as i64) + offset;
                if target < 0 {
                    return Err(IoError::new(ErrorKind::InvalidInput, "negative seek cursor"));
                }
                target as u64
            }
            SeekFrom::End(offset) => {
                let Some(tot) = total_size else {
                    return Err(IoError::new(ErrorKind::Unsupported, "cannot seek from end on live stream"));
                };
                let target = (tot as i64) + offset;
                if target < 0 {
                    return Err(IoError::new(ErrorKind::InvalidInput, "negative seek cursor"));
                }
                target as u64
            }
        };

        self.cursor = new_cursor;
        let _ = self.buffer.seek(new_cursor);
        Ok(new_cursor)
    }
}

impl MediaSource for BufferStreamReader {
    fn is_seekable(&self) -> bool {
        !self.buffer.is_live()
    }

    fn byte_len(&self) -> Option<u64> {
        self.buffer.total_size()
    }
}
