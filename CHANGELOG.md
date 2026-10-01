# Changelog

## 0.1.0

- Initial release of `miniaudio_player`.
- Ultra-low-resource cross-platform audio player powered by miniaudio and Sonic DSP.
- 100% pure Dart FFI with Native Assets (isolate-friendly, zero platform channel overhead in core).
- Built-in 10-band parametric equalizer with presets (_Rock_, _Pop_, _Jazz_, _Classical_, _Bass Boost_, _Flat_).
- Real-time independent pitch scaling and playback rate (time-stretching).
- Dynamic runtime audio device selection with automatic fallback and recovery.
- Multi-codec decoding support (MP3, WAV, FLAC, OGG, Opus, AAC, M4A, ALAC, AIFF, W64).
- Dual state API with synchronous getters and real-time reactive broadcast streams.
