pub struct TripartiteBuffer {
    pub pinned_head: Vec<u8>,
    pub ring_capacity: usize,
    pub tail_buffer: Vec<u8>,
}

impl TripartiteBuffer {
    pub fn new(ring_capacity: usize) -> Self {
        Self {
            pinned_head: Vec::new(),
            ring_capacity,
            tail_buffer: Vec::new(),
        }
    }
}
