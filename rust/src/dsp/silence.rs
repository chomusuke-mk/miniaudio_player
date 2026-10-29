#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SilenceDetectorState {
    Voice,
    Holding { frames_left: usize },
    Skipping { crossfade_idx: usize },
}

pub struct SilenceDetector {
    pub state: SilenceDetectorState,
    pub threshold_db: f32,
    pub min_silence_duration_ms: u32,
}
