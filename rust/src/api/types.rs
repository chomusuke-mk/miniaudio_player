//! Strongly-typed models for Flutter <-> Rust communication.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RustDartReadRequest {
    pub stream_id: u32,
    pub request_id: u64,
    pub offset: u64,
    pub length: u32,
}

#[derive(Debug, Clone, Default)]
pub struct RustAudioDevice {
    pub id: String,
    pub effective_id: String,
    pub name: String,
    pub is_default: bool,
    pub is_auto: bool,
}

#[derive(Debug, Clone, Default)]
pub struct RustStreamStatus {
    pub buffer_capacity: usize,
    pub buffer_fill: usize,
    pub fill_percentage: f32,
    pub is_buffering: bool,
    pub is_eof: bool,
    pub read_cursor_byte: i64,
    pub range_start: i64,
    pub range_end: i64,
}

#[derive(Debug, Clone, Default)]
pub struct RustBufferedRange {
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_ms: i64,
    pub fill_percentage: f32,
    pub stream_percentage: f32,
    pub is_buffering: bool,
    pub is_eof: bool,
}

#[derive(Debug, Clone, Default)]
pub struct RustEqualizerParams {
    pub gains: Vec<f32>,
    pub enabled: bool,
}

#[derive(Debug, Clone, Default)]
pub struct RustReplayGainConfig {
    pub gain_db: f32,
    pub peak: f32,
    pub prevent_clipping: bool,
    pub enabled: bool,
}

#[derive(Debug, Clone, Default)]
pub struct RustReverbParams {
    pub room_size: f32,
    pub damping: f32,
    pub wet: f32,
    pub dry: f32,
    pub width: f32,
    pub mode: f32,
    pub enabled: bool,
}

#[derive(Debug, Clone, Default)]
pub struct RustSilenceConfig {
    pub mode: i32,
    pub threshold_db: f32,
    pub min_silence_duration_ms: u32,
    pub padding_ms: u32,
    pub enabled: bool,
}

#[derive(Debug, Clone, Default)]
pub struct RustVisualizerData {
    pub bands: Vec<f32>,
    pub rms: f32,
    pub peak: f32,
    pub left: f32,
    pub right: f32,
}

#[derive(Debug, Clone, Default)]
pub struct RustPlayerStatus {
    pub position_ms: i64,
    pub duration_ms: i64,
    pub state: i32,
    pub is_playing: bool,
    pub is_buffering: bool,
    pub is_completed: bool,
    pub volume: f32,
    pub rate: f32,
    pub pitch: f32,
    pub bitrate: u32,
    pub sample_rate: u32,
    pub channels: u32,
}

#[derive(Debug, Clone, Default)]
pub struct RustAudioAnalysisResult {
    pub duration_ms: i64,
    pub sample_rate: u32,
    pub channels: u32,
    pub peak_amplitude: f32,
    pub rms_amplitude: f32,
    pub integrated_lufs: f32,
    pub replay_gain_db: f32,
    pub spectral_centroid: f32,
    pub frequency_bands: Vec<f32>,
    pub waveform_peaks: Vec<f32>,
}

#[derive(Debug, Clone)]
pub enum RustPlayerEvent {
    State(i32),
    Position(i64),
    Duration(i64),
    IsPlaying(bool),
    IsBuffering(bool),
    IsCompleted(bool),
    Volume(f32),
    Rate(f32),
    Pitch(f32),
    Bitrate(u32),
    BufferSize(u32),
    Device(RustAudioDevice),
    Visualizer(RustVisualizerData),
    VisualizerEnabled(bool),
    BufferedRange(RustBufferedRange),
    SilenceConfig(RustSilenceConfig),
    SilenceSaved(i64),
    Equalizer(RustEqualizerParams),
    Preamp(f32),
    ReplayGain(RustReplayGainConfig),
    Balance(f32),
    Mono(bool),
    Crossfeed(i32),
    Spatializer { enabled: bool, width: f32 },
    Reverb(RustReverbParams),
    Limiter(bool),
    DartReadRequest(RustDartReadRequest),
    Error { message: String, code: i32 },
}
