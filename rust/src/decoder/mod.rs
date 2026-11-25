//! Multi-format audio decoding and stream classification subsystem.

/// Pure-Rust AAC / HE-AAC Symphonia decoder adapter.
pub mod aac_decoder;
/// Monkey's Audio (`.ape`) frame decoder wrapper.
pub mod ape;
/// Deterministic container classification, boundary detection, and bitrate/duration sniffing.
pub mod classifier;
/// Direct Stream Digital (`.dsf`) 1-bit PDM decoder and Kaiser FIR decimator.
pub mod dsf;
/// Extended PCM container (`RF64`, `RIFX`, `W64`, `CAF`) reader and sample normalizer.
pub mod extended_pcm;
/// Unified decoding engine facade probing native readers and Symphonia codecs.
pub mod symphonia_engine;
/// Streaming block-by-block WavPack (`.wv`) decoder wrapper.
pub mod wavpack;

pub use aac_decoder::RustyAacDecoder;
pub use ape::ApeReader;
pub use classifier::{BoundaryInfo, BoundaryStatus, ClassifiedSlice, ContainerFormat, StreamClassifier};
pub use dsf::DsfReader;
pub use extended_pcm::ExtendedPcmReader;
pub use symphonia_engine::SymphoniaEngine;
pub use wavpack::WavpackReader;

/// Reads the exact byte count from `source` required to fill `dst`, retrying on
/// `ErrorKind::Interrupted` while propagating `UnexpectedEof`, `WouldBlock`, or `TimedOut`.
///
/// # Errors
///
/// Returns `UnexpectedEof` if `source` reaches EOF before `dst` is filled, or any other
/// non-`Interrupted` `std::io::Error` encountered while reading.
pub(crate) fn read_exact_resilient<R: std::io::Read + ?Sized>(
    source: &mut R,
    mut dst: &mut [u8],
) -> std::io::Result<()> {
    while !dst.is_empty() {
        match source.read(dst) {
            Ok(0) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "unexpected EOF while reading audio block",
                ));
            }
            Ok(n) => {
                let (_, rest) = dst.split_at_mut(n);
                dst = rest;
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
