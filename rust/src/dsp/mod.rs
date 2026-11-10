//! Digital Signal Processing (DSP) algorithms, filters, analysis, and spatialization.

pub mod analysis;
pub mod biquad;
pub mod chain;
pub mod channel_matrix;
pub mod crossfeed;
pub mod ducking;
pub mod equalizer;
pub mod limiter;
pub mod resampler;
pub mod reverb;
pub mod silence;
pub mod sonic;
pub mod spatial;
pub mod timestretch;
pub mod visualizer;
pub mod voice_pool;

pub use analysis::{
    analyze_audio_source, analyze_head_info, AdaptiveWaveformAccumulator, Bs1770LoudnessAnalyzer,
    HeadAnalysisInfo, ReplayGainData,
};
pub use biquad::BiquadDf2t;
pub use chain::DspChain;
pub use channel_matrix::ChannelMatrix;
pub use crossfeed::{Bs2bCrossfeed, CrossfeedConfig};
pub use ducking::AutoDucker;
pub use equalizer::{Equalizer, EqualizerParams, ReplayGainConfig};
pub use limiter::SoftLimiter;
pub use resampler::{resample_slice, RubatoResampler};
pub use reverb::{Freeverb, ReverbConfig};
pub use silence::{SilenceConfig, SilenceDetector, SilenceMode, SilenceState};
pub use sonic::SonicStream;
pub use spatial::{
    DistanceModel, SpatialEmitter, SpatialEvaluation, SpatialListener, SpatialProcessor, Vector3,
};
pub use timestretch::{timestretch_audio, TimeStretchProcessor};
pub use visualizer::{Visualizer, VisualizerData};
