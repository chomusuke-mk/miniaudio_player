//! Unified Stream Buffering (`StreamBuffer`, `StreamSession`), Virtual Demux Readers,
//! and Byte Source Abstraction.

pub mod byte_time_map;
pub mod demux_reader;
pub mod resolve;
pub mod source;
pub mod stream_buffer;

pub use byte_time_map::ByteTimeMap;
pub use demux_reader::{DemuxedStreamReader, MetadataStreamReader};
pub use resolve::{
    DartResolveRegistry, DartResolveRequest, FdOpenOutcome, ResolveFailure, ResolvedCoreSource,
};
pub use source::{
    CustomByteSourceHandle, CustomDartByteSource, CustomSourceRegistry, DartReadRequest,
    FileByteSource,
};
pub use stream_buffer::{
    BlockFetchOrder, BlockFetchPhase, BufferBackend, BufferError, BufferRange, ByteFetchTask,
    ProbeFetcherFn, ProbeGuard, SlidingWindowConfig, SlidingWindowState, StreamBuffer,
    StreamSession,
};
