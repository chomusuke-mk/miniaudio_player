//! Multi-format audio decoding and stream classification subsystem.

pub mod aac_decoder;
pub mod ape;
pub mod classifier;
pub mod dsf;
pub mod extended_pcm;
pub mod symphonia_engine;
pub mod wavpack;

pub use aac_decoder::RustyAacDecoder;
pub use ape::ApeReader;
pub use classifier::{BoundaryInfo, BoundaryStatus, ClassifiedSlice, ContainerFormat, StreamClassifier};
pub use dsf::DsfReader;
pub use extended_pcm::ExtendedPcmReader;
pub use symphonia_engine::SymphoniaEngine;
pub use wavpack::WavpackReader;

/// Reads the exact byte count required to fill `dst`, retrying on `ErrorKind::Interrupted`
/// while propagating `UnexpectedEof`, `WouldBlock`, or `TimedOut` cleanly.
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
