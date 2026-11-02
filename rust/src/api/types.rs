//! Strongly-typed models for Flutter <-> Rust communication.

pub(crate) fn c_buf_to_string(buf: &[u8]) -> String {
    let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..len]).to_string()
}

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

impl From<crate::buffer::DartReadRequest> for RustDartReadRequest {
    fn from(req: crate::buffer::DartReadRequest) -> Self {
        Self {
            stream_id: req.stream_id,
            request_id: req.request_id,
            offset: req.offset,
            length: req.length,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RustAudioDevice {
    pub id: String,
    pub effective_id: String,
    pub name: String,
    pub is_default: bool,
    pub is_auto: bool,
}

impl From<&crate::bridge::ffi::MapDeviceInfo> for RustAudioDevice {
    fn from(d: &crate::bridge::ffi::MapDeviceInfo) -> Self {
        Self {
            id: c_buf_to_string(&d.id),
            effective_id: c_buf_to_string(&d.effective_id),
            name: c_buf_to_string(&d.name),
            is_default: d.is_default != 0,
            is_auto: d.is_auto != 0,
        }
    }
}

impl From<&crate::sync::telemetry::DeviceInfo> for RustAudioDevice {
    fn from(d: &crate::sync::telemetry::DeviceInfo) -> Self {
        Self {
            id: c_buf_to_string(&d.id),
            effective_id: c_buf_to_string(&d.effective_id),
            name: c_buf_to_string(&d.name),
            is_default: d.is_default != 0,
            is_auto: d.is_auto != 0,
        }
    }
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

impl From<crate::bridge::ffi::MiniaudioBufferedRange> for RustBufferedRange {
    fn from(r: crate::bridge::ffi::MiniaudioBufferedRange) -> Self {
        Self {
            start_ms: r.start_ms,
            end_ms: r.end_ms,
            duration_ms: r.duration_ms,
            fill_percentage: r.fill_percentage,
            stream_percentage: r.stream_percentage,
            is_buffering: r.is_buffering != 0,
            is_eof: r.is_eof != 0,
        }
    }
}

impl From<crate::sync::telemetry::BufferedRange> for RustBufferedRange {
    fn from(r: crate::sync::telemetry::BufferedRange) -> Self {
        Self {
            start_ms: r.start_ms,
            end_ms: r.end_ms,
            duration_ms: r.duration_ms,
            fill_percentage: r.fill_percentage,
            stream_percentage: r.stream_percentage,
            is_buffering: r.is_buffering != 0,
            is_eof: r.is_eof != 0,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RustEqualizerParams {
    pub gains: Vec<f32>,
    pub enabled: bool,
}

impl From<RustEqualizerParams> for crate::dsp::equalizer::EqualizerParams {
    fn from(params: RustEqualizerParams) -> Self {
        Self {
            hz31: params.gains.first().copied().unwrap_or(0.0),
            hz63: params.gains.get(1).copied().unwrap_or(0.0),
            hz125: params.gains.get(2).copied().unwrap_or(0.0),
            hz250: params.gains.get(3).copied().unwrap_or(0.0),
            hz500: params.gains.get(4).copied().unwrap_or(0.0),
            hz1k: params.gains.get(5).copied().unwrap_or(0.0),
            hz2k: params.gains.get(6).copied().unwrap_or(0.0),
            hz4k: params.gains.get(7).copied().unwrap_or(0.0),
            hz8k: params.gains.get(8).copied().unwrap_or(0.0),
            hz16k: params.gains.get(9).copied().unwrap_or(0.0),
        }
    }
}

impl From<crate::dsp::equalizer::EqualizerParams> for RustEqualizerParams {
    fn from(eq: crate::dsp::equalizer::EqualizerParams) -> Self {
        Self {
            gains: eq.as_array().to_vec(),
            enabled: true,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RustReplayGainConfig {
    pub gain_db: f32,
    pub peak: f32,
    pub prevent_clipping: bool,
    pub enabled: bool,
}

impl From<crate::dsp::equalizer::ReplayGainConfig> for RustReplayGainConfig {
    fn from(rg: crate::dsp::equalizer::ReplayGainConfig) -> Self {
        Self {
            gain_db: rg.gain_db,
            peak: rg.peak,
            prevent_clipping: rg.prevent_clipping != 0,
            enabled: rg.enabled != 0,
        }
    }
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

impl From<crate::dsp::reverb::ReverbConfig> for RustReverbParams {
    fn from(rv: crate::dsp::reverb::ReverbConfig) -> Self {
        Self {
            room_size: rv.room_size,
            damping: rv.damping,
            wet: rv.wet,
            dry: rv.dry,
            width: rv.width,
            mode: 0.0,
            enabled: rv.enabled != 0,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RustSilenceConfig {
    pub mode: i32,
    pub threshold_db: f32,
    pub min_silence_duration_ms: u32,
    pub padding_ms: u32,
    pub enabled: bool,
}

impl From<crate::dsp::silence::SilenceConfig> for RustSilenceConfig {
    fn from(sc: crate::dsp::silence::SilenceConfig) -> Self {
        Self {
            mode: sc.mode as i32,
            threshold_db: sc.threshold_db,
            min_silence_duration_ms: sc.min_silence_duration_ms,
            padding_ms: sc.padding_ms,
            enabled: sc.mode != crate::dsp::silence::SilenceMode::Disabled,
        }
    }
}

impl From<RustSilenceConfig> for crate::dsp::silence::SilenceConfig {
    fn from(config: RustSilenceConfig) -> Self {
        let mode = match config.mode {
            1 => crate::dsp::silence::SilenceMode::TrimEdges,
            2 => crate::dsp::silence::SilenceMode::Continuous,
            3 => crate::dsp::silence::SilenceMode::All,
            _ => crate::dsp::silence::SilenceMode::Disabled,
        };
        Self {
            mode,
            threshold_db: config.threshold_db,
            min_silence_duration_ms: config.min_silence_duration_ms,
            padding_ms: config.padding_ms,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RustVisualizerData {
    pub bands: Vec<f32>,
    pub rms: f32,
    pub peak: f32,
    pub left: f32,
    pub right: f32,
}

impl From<crate::dsp::visualizer::VisualizerData> for RustVisualizerData {
    fn from(vis: crate::dsp::visualizer::VisualizerData) -> Self {
        Self {
            bands: vis.bands.to_vec(),
            rms: vis.rms,
            peak: vis.peak,
            left: vis.left,
            right: vis.right,
        }
    }
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

impl From<crate::core::player::MiniaudioPlayerStatus> for RustPlayerStatus {
    fn from(status: crate::core::player::MiniaudioPlayerStatus) -> Self {
        Self {
            position_ms: status.position_ms,
            duration_ms: status.duration_ms,
            state: status.state,
            is_playing: status.is_playing != 0,
            is_buffering: status.is_buffering != 0,
            is_completed: status.is_completed != 0,
            volume: status.volume,
            rate: status.rate,
            pitch: status.pitch,
            bitrate: status.bitrate,
            sample_rate: status.sample_rate,
            channels: status.channels,
        }
    }
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

impl From<crate::dsp::analysis::AudioAnalysisResult> for RustAudioAnalysisResult {
    fn from(result: crate::dsp::analysis::AudioAnalysisResult) -> Self {
        let waveform_peaks = if result.has_waveform != 0 {
            result.waveform.points
        } else {
            Vec::new()
        };
        Self {
            duration_ms: result.duration_ms,
            sample_rate: result.sample_rate,
            channels: result.channels,
            peak_amplitude: result.peak,
            rms_amplitude: result.peak,
            integrated_lufs: if result.has_replay_gain != 0 {
                result.replay_gain.lufs
            } else {
                0.0
            },
            replay_gain_db: if result.has_replay_gain != 0 {
                result.replay_gain.gain_db
            } else {
                0.0
            },
            spectral_centroid: 0.0,
            frequency_bands: Vec::new(),
            waveform_peaks,
        }
    }
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
pub struct RustAudioSource {
    pub id: i64,
    pub source: String,
    pub headers: Option<Vec<RustHttpHeader>>,
    pub data_bytes: Option<Vec<u8>>,
    pub replay_gain_db: Option<f32>,
    pub replay_peak: Option<f32>,
}

impl From<RustAudioSource> for crate::core::engine::AudioSourceCore {
    fn from(it: RustAudioSource) -> Self {
        Self {
            id: it.id,
            source: it.source,
            headers: it.headers,
            data_bytes: it.data_bytes,
            replay_gain_db: it.replay_gain_db,
            replay_peak: it.replay_peak,
        }
    }
}

impl From<&crate::core::engine::AudioSourceCore> for RustAudioSource {
    fn from(it: &crate::core::engine::AudioSourceCore) -> Self {
        Self {
            id: it.id,
            source: it.source.clone(),
            headers: it.headers.clone(),
            data_bytes: None,
            replay_gain_db: it.replay_gain_db,
            replay_peak: it.replay_peak,
        }
    }
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
    QueueChanged(Vec<RustAudioSource>),
    NeedMoreTracks {
        current_track_id: i64,
        remaining_tracks: usize,
    },
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
    Spatializer {
        enabled: bool,
        width: f32,
    },
    Reverb(RustReverbParams),
    Limiter(bool),
    CrossfadeConfig(RustCrossfadeConfig),
    LoopMode(i32),
    Shuffle(bool),
    MetaBytes(Vec<u8>),
    Error {
        message: String,
        code: i32,
    },
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
        Self {
            x: v.x,
            y: v.y,
            z: v.z,
        }
    }
}

impl From<crate::dsp::spatial::Vector3> for RustVector3 {
    fn from(v: crate::dsp::spatial::Vector3) -> Self {
        Self {
            x: v.x,
            y: v.y,
            z: v.z,
        }
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RustWavFormat {
    #[default]
    Pcm16,
    Float32,
}

impl From<RustWavFormat> for crate::core::recording::WavFormat {
    fn from(f: RustWavFormat) -> Self {
        match f {
            RustWavFormat::Pcm16 => Self::Pcm16,
            RustWavFormat::Float32 => Self::Float32,
        }
    }
}

impl From<crate::core::recording::WavFormat> for RustWavFormat {
    fn from(f: crate::core::recording::WavFormat) -> Self {
        match f {
            crate::core::recording::WavFormat::Pcm16 => Self::Pcm16,
            crate::core::recording::WavFormat::Float32 => Self::Float32,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RustDuckingConfig {
    pub enabled: bool,
    pub ducking_db: f32,
    pub threshold_db: f32,
    pub attack_ms: f32,
    pub hold_ms: f32,
    pub release_ms: f32,
}

impl Default for RustDuckingConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            ducking_db: -14.0,
            threshold_db: -30.0,
            attack_ms: 30.0,
            hold_ms: 250.0,
            release_ms: 400.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct RustCueConfig {
    pub enabled: bool,
    pub device_id: Option<String>,
    pub volume: f32,
    pub mode: i32, // 0: Deck A, 1: Deck B, 2: Master
}
