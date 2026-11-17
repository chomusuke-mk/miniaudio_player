//! Core audio engine subsystems, managers, rendering pipelines, and domain logic.

pub mod capture;
pub mod control_coordinator;
pub mod dsp_processor;
pub mod dual_source;
pub mod dual_source_control;
pub mod effects_manager;
pub mod engine_actor;
pub mod hw_supervisor;
pub mod input_manager;
pub mod io_pool;
pub mod miniaudio_player;
pub mod music_manager;
pub mod output_manager;
pub mod recording;
pub mod renderer;
pub mod simd_mixer;
pub mod tap;
pub mod types;
pub mod voice_pool;

pub use dsp_processor::DspProcessor;
pub use dual_source::{
    AudioSourceCore, CrossfadeAtomic, DualSource, StreamingDeck, STATE_PAUSED, STATE_PLAYING,
    STATE_STOPPED,
};
pub use effects_manager::EffectsManager;
pub use input_manager::InputManager;
pub use miniaudio_player::MiniaudioPlayer;
pub use music_manager::MusicManager;
pub use output_manager::OutputManager;
pub use recording::{LiveRecorder, RecordingEncoding, WavFormat};
pub use renderer::{AudioRenderer, DspCommand};
pub use simd_mixer::SimdMixer;
pub use types::{PlaybackState, QueueTransition};
pub use voice_pool::{
    DspRouting, EffectCatalogItem, EffectConfig, EffectSourceType, SoundBuffer,
    VoiceStealingPolicy,
};
