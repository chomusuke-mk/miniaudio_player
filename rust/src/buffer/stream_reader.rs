use super::tripartite::TripartiteBuffer;

pub struct BufferStreamReader<'a> {
    pub buffer: &'a mut TripartiteBuffer,
    pub cursor: u64,
}

impl<'a> BufferStreamReader<'a> {
    pub fn new(buffer: &'a mut TripartiteBuffer) -> Self {
        Self { buffer, cursor: 0 }
    }
}
