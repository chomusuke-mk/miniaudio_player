//! Unified Stream Buffering (`StreamBuffer`, `StreamSession`), Virtual Demux Readers,
//! and Byte Source Abstraction.

pub mod demux_reader;
pub mod source;
pub mod stream_buffer;

pub use demux_reader::{DemuxedStreamReader, MetadataStreamReader};
pub use source::{
    ByteSource, ByteSourceStream, CustomByteSourceHandle, CustomDartByteSource,
    CustomSourceRegistry, DartReadRequest, FileByteSource, MemoryByteSource, SourceKind,
    StreamByteSource,
};
pub use stream_buffer::{
    BlockFetchOrder, BlockFetchPhase, BufferBackend, BufferError, BufferRange, BufferState,
    ByteFetchTask, SlidingWindowConfig, SlidingWindowState, StreamBuffer, StreamSession,
};
