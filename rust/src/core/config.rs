#[derive(Debug, Clone)]
pub struct PlayerConfig {
    pub sample_rate: u32,
    pub channels: u32,
    pub period_size: u32,
}

impl Default for PlayerConfig {
    fn default() -> Self {
        Self {
            sample_rate: 44100,
            channels: 2,
            period_size: 1024,
        }
    }
}
