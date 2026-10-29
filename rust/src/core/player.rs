use super::config::PlayerConfig;
use crate::buffer::TripartiteBuffer;

pub struct PlayerCoordinator {
    pub config: PlayerConfig,
    pub buffer: TripartiteBuffer,
}

impl PlayerCoordinator {
    pub fn new(config: PlayerConfig) -> Self {
        let buffer = TripartiteBuffer::new(
            TripartiteBuffer::DEFAULT_RING_CAPACITY,
            None,
            false,
        );
        Self { config, buffer }
    }

    pub fn with_buffer(config: PlayerConfig, buffer: TripartiteBuffer) -> Self {
        Self { config, buffer }
    }
}
