//! Foreign function interface (FFI) bindings and bridge structures to native audio hardware (miniaudio).

/// Raw FFI declarations, WebAssembly audio bridges, and safe device enumeration wrappers.
pub mod ffi;
pub use ffi::*;
