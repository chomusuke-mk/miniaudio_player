mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
pub mod api;
pub mod bridge;
pub mod buffer;
pub mod core;
pub mod decoder;
pub mod dsp;
pub mod sync;

pub use bridge::ffi::*;
pub use buffer::{BufferError, BufferRange, BufferState, TripartiteBuffer};
pub use core::*;
pub use dsp::analysis::*;

use std::sync::atomic::AtomicI32;

/// Global log level filter (0: none, 1: error, 2: warn, 3: info, 4: debug, 5: verbose)
pub static LOG_LEVEL: AtomicI32 = AtomicI32::new(3);
