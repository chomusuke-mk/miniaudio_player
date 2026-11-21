//! Browser Origin Private File System (OPFS) path rules, shared-memory protocol,
//! and direct `wasm32` VFD I/O primitives.

pub mod protocol;
#[cfg(target_arch = "wasm32")]
pub mod wasm_opfs;

pub use protocol::*;
#[cfg(target_arch = "wasm32")]
pub use wasm_opfs::*;
