//! Multi-format audio decoding and stream classification subsystem.

pub mod ape;
pub mod classifier;
pub mod dsf;
pub mod extended_pcm;
#[cfg(not(target_arch = "wasm32"))]
pub mod opus_decoder;
pub mod symphonia_engine;
pub mod wavpack;

pub use ape::ApeReader;
pub use classifier::{BoundaryInfo, BoundaryStatus, ClassifiedSlice, ContainerFormat, StreamClassifier};
pub use dsf::DsfReader;
pub use extended_pcm::ExtendedPcmReader;
#[cfg(not(target_arch = "wasm32"))]
pub use opus_decoder::OpusDecoder;
pub use symphonia_engine::SymphoniaEngine;
pub use wavpack::WavpackReader;
