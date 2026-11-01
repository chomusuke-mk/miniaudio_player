//! Strongly-typed models for Flutter <-> Rust communication.

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RustHttpHeader {
    pub key: String,
    pub value: String,
}

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

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RustCrossfadeConfig {
    pub duration_ms: u64,
    pub manual_duration_ms: u64,
    pub curve: i32, // 0: equalPower, 1: linear
}

impl Default for RustCrossfadeConfig {
    fn default() -> Self {
        Self {
            duration_ms: 5000,
            manual_duration_ms: 100,
            curve: 0,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RustEngineItem {
    pub id: i64,
    pub source: String,
    pub headers: Option<Vec<RustHttpHeader>>,
    pub data_bytes: Option<Vec<u8>>,
    pub replay_gain_db: Option<f32>,
    pub replay_peak: Option<f32>,
}

#[derive(Debug, Clone)]
pub enum RustEngineEvent {
    Phase(i32),
    State(i32),
    Position(i64),
    Duration(i64),
    IsPlaying(bool),
    IsBuffering(bool),
    IsCompleted(bool),
    CurrentIndex(i32),
    QueueChanged(Vec<RustEngineItem>),
    NeedMoreTracks { current_track_id: i64, remaining_tracks: usize },
    Volume(f32),
    Rate(f32),
    Pitch(f32),
    Bitrate(u32),
    BufferSize(u32),
    Device(RustAudioDevice),
    Visualizer(RustVisualizerData),
    VisualizerEnabled(bool),
    BufferedRange(RustBufferedRange),
    Equalizer(RustEqualizerParams),
    Preamp(f32),
    ReplayGain(RustReplayGainConfig),
    Balance(f32),
    Mono(bool),
    Crossfeed(i32),
    Spatializer { enabled: bool, width: f32 },
    Reverb(RustReverbParams),
    Limiter(bool),
    CrossfadeConfig(RustCrossfadeConfig),
    LoopMode(i32),
    Shuffle(bool),
    Error { message: String, code: i32 },
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct RustVector3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RustDistanceModel {
    #[default]
    Inverse,
    Linear,
    Exponential,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct RustSpatialListener {
    pub position: RustVector3,
    pub velocity: RustVector3,
    pub forward: RustVector3,
    pub up: RustVector3,
}

#[derive(Debug, Clone, Copy)]
pub struct RustSpatialEmitter {
    pub position: RustVector3,
    pub velocity: RustVector3,
    pub direction: Option<RustVector3>,
    pub min_distance: f32,
    pub max_distance: f32,
    pub rolloff_factor: f32,
    pub doppler_factor: f32,
    pub inner_angle_rad: f32,
    pub outer_angle_rad: f32,
    pub outer_gain: f32,
    pub distance_model: RustDistanceModel,
}

impl Default for RustSpatialEmitter {
    fn default() -> Self {
        Self {
            position: RustVector3::default(),
            velocity: RustVector3::default(),
            direction: None,
            min_distance: 1.0,
            max_distance: 1000.0,
            rolloff_factor: 1.0,
            doppler_factor: 1.0,
            inner_angle_rad: std::f32::consts::PI * 2.0,
            outer_angle_rad: std::f32::consts::PI * 2.0,
            outer_gain: 0.0,
            distance_model: RustDistanceModel::Inverse,
        }
    }
}

impl From<RustVector3> for crate::dsp::spatial::Vector3 {
    fn from(v: RustVector3) -> Self {
        Self { x: v.x, y: v.y, z: v.z }
    }
}

impl From<crate::dsp::spatial::Vector3> for RustVector3 {
    fn from(v: crate::dsp::spatial::Vector3) -> Self {
        Self { x: v.x, y: v.y, z: v.z }
    }
}

impl From<RustDistanceModel> for crate::dsp::spatial::DistanceModel {
    fn from(m: RustDistanceModel) -> Self {
        match m {
            RustDistanceModel::Inverse => Self::Inverse,
            RustDistanceModel::Linear => Self::Linear,
            RustDistanceModel::Exponential => Self::Exponential,
        }
    }
}

impl From<RustSpatialListener> for crate::dsp::spatial::SpatialListener {
    fn from(l: RustSpatialListener) -> Self {
        Self {
            position: l.position.into(),
            velocity: l.velocity.into(),
            forward: l.forward.into(),
            up: l.up.into(),
        }
    }
}

impl From<RustSpatialEmitter> for crate::dsp::spatial::SpatialEmitter {
    fn from(e: RustSpatialEmitter) -> Self {
        Self {
            position: e.position.into(),
            velocity: e.velocity.into(),
            direction: e.direction.map(Into::into),
            min_distance: e.min_distance,
            max_distance: e.max_distance,
            rolloff_factor: e.rolloff_factor,
            doppler_factor: e.doppler_factor,
            inner_angle_rad: e.inner_angle_rad,
            outer_angle_rad: e.outer_angle_rad,
            outer_gain: e.outer_gain,
            distance_model: e.distance_model.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RustVoiceStealingPolicy {
    #[default]
    LowestPriority,
    Oldest,
    Quietest,
    Farthest,
}

impl From<RustVoiceStealingPolicy> for crate::dsp::voice_pool::VoiceStealingPolicy {
    fn from(p: RustVoiceStealingPolicy) -> Self {
        match p {
            RustVoiceStealingPolicy::LowestPriority => Self::LowestPriority,
            RustVoiceStealingPolicy::Oldest => Self::Oldest,
            RustVoiceStealingPolicy::Quietest => Self::Quietest,
            RustVoiceStealingPolicy::Farthest => Self::Farthest,
        }
    }
}

impl From<crate::dsp::voice_pool::VoiceStealingPolicy> for RustVoiceStealingPolicy {
    fn from(p: crate::dsp::voice_pool::VoiceStealingPolicy) -> Self {
        match p {
            crate::dsp::voice_pool::VoiceStealingPolicy::LowestPriority => Self::LowestPriority,
            crate::dsp::voice_pool::VoiceStealingPolicy::Oldest => Self::Oldest,
            crate::dsp::voice_pool::VoiceStealingPolicy::Quietest => Self::Quietest,
            crate::dsp::voice_pool::VoiceStealingPolicy::Farthest => Self::Farthest,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RustSoundBufferInfo {
    pub id: u64,
    pub sample_rate: u32,
    pub channels: u32,
    pub duration_ms: i64,
    pub frame_count: usize,
}
