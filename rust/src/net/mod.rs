//! Cross-platform HTTP client facade (`::ureq` on native targets, Web Worker
//! `fetch` + `ReadableStream` over `SharedArrayBuffer` shim on `wasm32`).

#[cfg(not(target_arch = "wasm32"))]
pub use ::ureq;

/// Shared-memory SPSC protocol and header wire codec for `wasm32` HTTP streaming.
#[doc(hidden)]
pub mod wasm_ureq_protocol;

/// `wasm32` Web Worker `fetch` + `ReadableStream` HTTP client shim compatible with `ureq`.
#[cfg(target_arch = "wasm32")]
pub mod wasm_ureq;

#[cfg(target_arch = "wasm32")]
pub use wasm_ureq as ureq;
