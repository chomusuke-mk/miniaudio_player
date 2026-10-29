use super::config::PlayerConfig;

pub struct PlayerCoordinator {
    pub config: PlayerConfig,
}

impl PlayerCoordinator {
    pub fn new(config: PlayerConfig) -> Self {
        Self { config }
    }
}
