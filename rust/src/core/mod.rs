pub mod capture;
pub mod config;
pub mod dsp_processor;
pub mod dual_source;
pub mod effects_manager;
pub mod input_manager;
pub mod miniaudio_player;
pub mod music_manager;
pub mod output_matrix;
pub mod output_manager;
pub mod recording;
pub mod renderer;
pub mod simd_mixer;
pub mod types;
pub mod typestate;
pub mod voice_pool;

pub use config::PlayerConfig;
pub use dsp_processor::DspProcessor;
pub use dual_source::{
    AudioSourceCore, CompletionCallback, CrossfadeAtomic, DualSource, MiniaudioPlayerStatus,
    MiniaudioStreamStatus, StreamingDeck, MAP_STREAM_SEEK_CACHE_HIT,
    MAP_STREAM_SEEK_CACHE_HIT_PREFETCH, MAP_STREAM_SEEK_CACHE_MISS, STATE_BUFFERING,
    STATE_COMPLETED, STATE_ERROR, STATE_OPENING, STATE_PAUSED, STATE_PLAYING, STATE_STOPPED,
};
pub use effects_manager::EffectsManager;
pub use input_manager::InputManager;
pub use miniaudio_player::{MiniaudioPlayer, MiniaudioPlayerRenderer};
pub use music_manager::MusicManager;
pub use output_matrix::{CueSource, OutputMatrix};
pub use output_manager::OutputManager;
pub use recording::{LiveRecorder, WavFormat};
pub use renderer::{AudioRenderer, DspCommand};
pub use simd_mixer::SimdMixer;
pub use types::{Decibels, PlayerError, SampleRate, Volume};
pub use typestate::{Active, Open, Paused, Player, Stopped, Uninitialized};
pub use voice_pool::{DspRouting, EffectConfig, SoundBuffer, VoicePool, VoiceStealingPolicy};
