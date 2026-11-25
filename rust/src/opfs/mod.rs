//! Browser Origin Private File System (OPFS) path rules, shared-memory protocol,
//! and direct `wasm32` VFD I/O primitives.

/// Cross-platform OPFS path validation, sanitization, and shared-memory RPC protocol.
pub mod protocol;
/// `wasm32` OPFS I/O backend backed by a pure-JS Web Worker and `SharedArrayBuffer` slots.
#[cfg(target_arch = "wasm32")]
pub mod wasm_opfs;

pub use protocol::*;
#[cfg(target_arch = "wasm32")]
pub use wasm_opfs::*;
