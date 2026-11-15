//! Cross-platform HTTP client facade (`::ureq` on native targets, Web Worker
//! `fetch` + `ReadableStream` over `SharedArrayBuffer` shim on `wasm32`).

#[cfg(not(target_arch = "wasm32"))]
pub use ::ureq;

#[doc(hidden)]
pub mod wasm_ureq_protocol;

#[cfg(target_arch = "wasm32")]
pub mod wasm_ureq;

#[cfg(target_arch = "wasm32")]
pub use wasm_ureq as ureq;
