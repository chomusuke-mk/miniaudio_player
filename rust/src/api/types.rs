//! Strongly-typed models for Flutter <-> Rust communication.

pub(crate) fn c_buf_to_string(buf: &[u8]) -> String {
    let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..len]).to_string()
}

/// HTTP header key-value pair for network requests.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RustHttpHeader {
    /// Header field name.
    pub key: String,
    /// Header field value.
    pub value: String,
}

/// Asynchronous read request dispatched from Rust to a Dart `CustomByteProvider`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RustDartReadRequest {
    /// Stream identifier matching the requested custom source.
    pub stream_id: u32,
    /// Unique monotonically increasing request sequence number.
    pub request_id: u64,
    /// Starting byte offset in the source.
    pub offset: u64,
    /// Number of bytes requested.
    pub length: u32,
}

impl From<crate::buffer::DartReadRequest> for RustDartReadRequest {
    fn from(req: crate::buffer::DartReadRequest) -> Self {
        Self {
            stream_id: req.stream_id,
            request_id: req.request_id,
            offset: req.offset,
            length: req.length,
        }
    }
}

/// Hardware or virtual audio endpoint detected by the operating system.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RustAudioDevice {
    /// Unique device identifier.
    pub id: String,
    /// Underlying physical endpoint identifier in the operating system.
    pub effective_id: String,
    /// Human-readable device display name.
    pub name: String,
    /// Whether this device is the system default.
    pub is_default: bool,
    /// Whether this device represents the automatic system default route.
    pub is_auto: bool,
}

impl From<&crate::bridge::ffi::MapDeviceInfo> for RustAudioDevice {
    fn from(d: &crate::bridge::ffi::MapDeviceInfo) -> Self {
        Self {
            id: c_buf_to_string(&d.id),
            effective_id: c_buf_to_string(&d.effective_id),
            name: c_buf_to_string(&d.name),
            is_default: d.is_default != 0,
            is_auto: d.is_auto != 0,
        }
    }
}

impl From<&crate::sync::telemetry::DeviceInfo> for RustAudioDevice {
    fn from(d: &crate::sync::telemetry::DeviceInfo) -> Self {
        Self {
            id: c_buf_to_string(&d.id),
            effective_id: c_buf_to_string(&d.effective_id),
            name: c_buf_to_string(&d.name),
            is_default: d.is_default != 0,
            is_auto: d.is_auto != 0,
        }
    }
}

/// Continuous prefetch buffer telemetry metrics.
#[derive(Debug, Clone, Default)]
pub struct RustBuffer {
    /// Earliest timestamp cached in RAM in milliseconds.
    pub start_ms: i64,
    /// Furthest timestamp preloaded in RAM in milliseconds.
    pub end_ms: i64,
    /// Whether the decoder is currently stalled waiting for network or I/O chunks.
    pub is_buffering: bool,
}

impl From<crate::bridge::ffi::MiniaudioBufferedRange> for RustBuffer {
    fn from(r: crate::bridge::ffi::MiniaudioBufferedRange) -> Self {
        Self {
            start_ms: r.start_ms,
            end_ms: r.end_ms,
            is_buffering: r.is_buffering != 0,
        }
    }
}

impl From<crate::sync::telemetry::BufferedRange> for RustBuffer {
    fn from(r: crate::sync::telemetry::BufferedRange) -> Self {
        Self {
            start_ms: r.start_ms,
            end_ms: r.end_ms,
            is_buffering: r.is_buffering != 0,
        }
    }
}

/// Parameters configuring the 10-band ISO peaking equalizer.
#[derive(Debug, Clone, Default)]
pub struct RustEqualizerParams {
    /// Gain adjustments in decibels across the 10 ISO standard center frequencies.
    pub gains: Vec<f32>,
    /// Whether the equalizer DSP stage is actively applied.
    pub enabled: bool,
}

impl From<RustEqualizerParams> for crate::dsp::equalizer::EqualizerParams {
    fn from(params: RustEqualizerParams) -> Self {
        Self {
            enabled: params.enabled,
            hz31: params.gains.first().copied().unwrap_or(0.0),
            hz63: params.gains.get(1).copied().unwrap_or(0.0),
            hz125: params.gains.get(2).copied().unwrap_or(0.0),
            hz250: params.gains.get(3).copied().unwrap_or(0.0),
            hz500: params.gains.get(4).copied().unwrap_or(0.0),
            hz1k: params.gains.get(5).copied().unwrap_or(0.0),
            hz2k: params.gains.get(6).copied().unwrap_or(0.0),
            hz4k: params.gains.get(7).copied().unwrap_or(0.0),
            hz8k: params.gains.get(8).copied().unwrap_or(0.0),
            hz16k: params.gains.get(9).copied().unwrap_or(0.0),
        }
    }
}

impl From<crate::dsp::equalizer::EqualizerParams> for RustEqualizerParams {
    fn from(eq: crate::dsp::equalizer::EqualizerParams) -> Self {
        Self {
            gains: eq.as_array().to_vec(),
            enabled: eq.enabled,
        }
    }
}

/// Configuration governing ReplayGain track loudness normalization.
#[derive(Debug, Clone, Default)]
pub struct RustReplayGainConfig {
    /// Gain adjustment in decibels relative to target LUFS.
    pub gain_db: f32,
    /// Absolute true peak amplitude.
    pub peak: f32,
}

impl From<crate::dsp::equalizer::ReplayGainConfig> for RustReplayGainConfig {
    fn from(rg: crate::dsp::equalizer::ReplayGainConfig) -> Self {
        Self {
            gain_db: rg.gain_db,
            peak: rg.peak,
        }
    }
}

impl From<RustReplayGainConfig> for crate::dsp::equalizer::ReplayGainConfig {
    fn from(c: RustReplayGainConfig) -> Self {
        Self {
            gain_db: c.gain_db,
            peak: c.peak,
            prevent_clipping: 1,
            enabled: 1,
        }
    }
}

/// Parameters configuring algorithmic studio reverberation.
#[derive(Debug, Clone, Default)]
pub struct RustReverbParams {
    /// Normalized room size determining decay time (0.0 to 1.0).
    pub room_size: f32,
    /// High-frequency absorption and damping (0.0 to 1.0).
    pub damping: f32,
    /// Wet reverberant signal mix level (0.0 to 2.0).
    pub wet: f32,
    /// Dry unprocessed signal mix level (0.0 to 2.0).
    pub dry: f32,
    /// Stereo width and spread of reflections (0.0 to 1.0).
    pub width: f32,
    /// Acoustic mode selector.
    pub mode: f32,
    /// Whether the reverb effect is actively processing audio.
    pub enabled: bool,
}

impl From<crate::dsp::reverb::ReverbConfig> for RustReverbParams {
    fn from(rv: crate::dsp::reverb::ReverbConfig) -> Self {
        Self {
            room_size: rv.room_size,
            damping: rv.damping,
            wet: rv.wet,
            dry: rv.dry,
            width: rv.width,
            mode: 0.0,
            enabled: rv.enabled != 0,
        }
    }
}

/// Configuration settings for dynamic silence detection and skipping.
#[derive(Debug, Clone, Default)]
pub struct RustSilenceConfig {
    /// Operational mode (0: disabled, 1: trimEdges, 2: continuous, 3: all).
    pub mode: i32,
    /// Silence detection threshold in decibels full scale (dBFS).
    pub threshold_db: f32,
    /// Minimum continuous duration in milliseconds before silence skipping triggers.
    pub min_silence_duration_ms: u32,
    /// Margin padding in milliseconds preserved before and after non-silent audio.
    pub padding_ms: u32,
    /// Whether silence detection is enabled.
    pub enabled: bool,
}

impl From<crate::dsp::silence::SilenceConfig> for RustSilenceConfig {
    fn from(sc: crate::dsp::silence::SilenceConfig) -> Self {
        Self {
            mode: sc.mode as i32,
            threshold_db: sc.threshold_db,
            min_silence_duration_ms: sc.min_silence_duration_ms,
            padding_ms: sc.padding_ms,
            enabled: sc.enabled,
        }
    }
}

impl From<RustSilenceConfig> for crate::dsp::silence::SilenceConfig {
    fn from(config: RustSilenceConfig) -> Self {
        let mode = match config.mode {
            1 => crate::dsp::silence::SilenceMode::TrimEdges,
            2 => crate::dsp::silence::SilenceMode::Continuous,
            3 => crate::dsp::silence::SilenceMode::All,
            _ => crate::dsp::silence::SilenceMode::Disabled,
        };
        Self {
            enabled: config.enabled,
            mode,
            threshold_db: config.threshold_db,
            min_silence_duration_ms: config.min_silence_duration_ms,
            padding_ms: config.padding_ms,
        }
    }
}

/// Configuration settings for the Bauer Stereophonic-to-Binaural (BS2B) crossfeed filter.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct RustCrossfeedConfig {
    /// Whether crossfeed processing is actively applied.
    pub enabled: bool,
    /// Lowpass cutoff frequency in Hertz (typically 300 to 2000 Hz, default 700 Hz).
    pub cutoff_hz: f32,
    /// Crossfeed attenuation / feed level in decibels (typically 1.0 to 15.0 dB, default 4.5 dB).
    pub feed_db: f32,
}

impl From<crate::dsp::crossfeed::CrossfeedConfig> for RustCrossfeedConfig {
    fn from(c: crate::dsp::crossfeed::CrossfeedConfig) -> Self {
        Self {
            enabled: c.enabled,
            cutoff_hz: c.cutoff_hz,
            feed_db: c.feed_db,
        }
    }
}

impl From<RustCrossfeedConfig> for crate::dsp::crossfeed::CrossfeedConfig {
    fn from(c: RustCrossfeedConfig) -> Self {
        Self {
            enabled: c.enabled,
            cutoff_hz: c.cutoff_hz,
            feed_db: c.feed_db,
        }
    }
}

/// Configuration settings for continuous auto-refill Infinite Mix queue replenishment.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RustInfiniteMixConfig {
    /// Whether continuous auto-refill infinite mix mode is enabled.
    pub enabled: bool,
    /// Threshold of remaining tracks ahead in queue before requesting replenishment.
    pub remaining_tracks_threshold: u32,
}

/// Instantaneous FFT spectrum and stereo amplitude metrics for UI visualizers.
#[derive(Debug, Clone, Default)]
pub struct RustVisualizerData {
    /// Normalized frequency band intensities (0.0 to 1.0).
    pub bands: Vec<f32>,
    /// Global root-mean-square (RMS) energy level (0.0 to 1.0).
    pub rms: f32,
    /// Instantaneous peak sample amplitude (0.0 to 1.0).
    pub peak: f32,
    /// Left channel energy level (0.0 to 1.0).
    pub left: f32,
    /// Right channel energy level (0.0 to 1.0).
    pub right: f32,
}

impl PartialEq for RustVisualizerData {
    fn eq(&self, other: &Self) -> bool {
        const EPSILON: f32 = 0.0005;
        if (self.rms - other.rms).abs() > EPSILON
            || (self.peak - other.peak).abs() > EPSILON
            || (self.left - other.left).abs() > EPSILON
            || (self.right - other.right).abs() > EPSILON
            || self.bands.len() != other.bands.len()
        {
            return false;
        }
        for (a, b) in self.bands.iter().zip(other.bands.iter()) {
            if (a - b).abs() > EPSILON {
                return false;
            }
        }
        true
    }
}

impl From<crate::dsp::visualizer::VisualizerData> for RustVisualizerData {
    fn from(vis: crate::dsp::visualizer::VisualizerData) -> Self {
        Self {
            bands: vis.bands.to_vec(),
            rms: vis.rms,
            peak: vis.peak,
            left: vis.left,
            right: vis.right,
        }
    }
}

/// Synchronous snapshot of playback telemetry metrics.
#[derive(Debug, Clone, Default)]
pub struct RustPlayerStatus {
    /// Playback elapsed position in milliseconds.
    pub position_ms: i64,
    /// Total duration in milliseconds, or -1 if live or unbounded.
    pub duration_ms: i64,
    /// Playback state integer code.
    pub state: i32,
    /// Whether audio is actively rendering.
    pub is_playing: bool,
    /// Whether the engine is buffering.
    pub is_buffering: bool,
    /// Master volume level.
    pub volume: f32,
    /// Playback speed rate multiplier.
    pub rate: f32,
    /// Pitch shift multiplier.
    pub pitch: f32,
    /// Stream nominal bitrate in bits per second.
    pub bitrate: u32,
    /// Stream sample rate in Hz.
    pub sample_rate: u32,
    /// Number of output channels.
    pub channels: u32,
}

impl From<crate::core::dual_source::MiniaudioPlayerStatus> for RustPlayerStatus {
    fn from(status: crate::core::dual_source::MiniaudioPlayerStatus) -> Self {
        Self {
            position_ms: status.position_ms,
            duration_ms: status.duration_ms,
            state: status.state,
            is_playing: status.is_playing != 0,
            is_buffering: status.is_buffering != 0,
            volume: status.volume,
            rate: status.rate,
            pitch: status.pitch,
            bitrate: status.bitrate,
            sample_rate: status.sample_rate,
            channels: status.channels,
        }
    }
}

/// Bitrate encoding mode of an audio stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RustBitrateMode {
    /// Bitrate mode could not be determined or is not applicable.
    #[default]
    Unknown,
    /// Constant Bitrate (CBR).
    Cbr,
    /// Variable Bitrate (VBR).
    Vbr,
}

/// Technical format and stream characteristics of an audio asset.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RustAudioInfo {
    /// Total duration in milliseconds, or None if unknown / infinite livestream.
    pub duration_ms: Option<i64>,
    /// Decoded output PCM sample rate in Hz.
    pub sample_rate: u32,
    /// Native stream sample rate in Hz before decimation (e.g., 2822400 Hz for DSD64).
    pub raw_sample_rate: Option<u32>,
    /// Channel count.
    pub channels: u32,
    /// Nominal bitrate in bps.
    pub bitrate: u32,
    /// Bit depth per sample (e.g. 16, 24, 32, or 1 for DSD).
    pub bits_per_sample: Option<u32>,
    /// Canonical codec name (e.g. "MP3", "FLAC", "AAC", "ALAC", "Opus", "Vorbis", "PCM", "DSD", "APE", "WavPack").
    pub codec: String,
    /// Canonical container format (e.g. "MP3", "FLAC", "MP4", "Ogg", "WAV", "RF64", "W64", "RIFX", "AIFF", "CAF", "Matroska", "DSF", "APE", "WavPack", "ADTS", "HLS").
    pub container_format: String,
    /// Whether the audio codec is lossless.
    pub lossless: bool,
    /// Bitrate encoding mode (Unknown, Cbr, Vbr).
    pub bitrate_mode: RustBitrateMode,
    /// Total file or stream byte size when known.
    pub file_size: Option<u64>,
    /// Short container/codec format hint string (e.g. "mp3", "flac", "wav").
    pub format: Option<String>,
}

/// Type of embedded picture according to ID3v2 APIC / FLAC Picture standards.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RustPictureType {
    #[default]
    Other,
    Icon,
    OtherIcon,
    CoverFront,
    CoverBack,
    Leaflet,
    Media,
    LeadArtist,
    Artist,
    Conductor,
    Band,
    Composer,
    Lyricist,
    RecordingLocation,
    DuringRecording,
    DuringPerformance,
    ScreenCapture,
    BrightFish,
    Illustration,
    BandLogo,
    PublisherLogo,
}

/// MIME type of an embedded picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RustMimeType {
    Png,
    Jpeg,
    Tiff,
    Bmp,
    Gif,
    Webp,
    #[default]
    Unknown,
}

/// Embedded artwork/picture extracted from an audio container.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RustAudioPicture {
    /// Picture category (e.g. CoverFront, CoverBack, Artist).
    pub picture_type: RustPictureType,
    /// Detected or declared image MIME type.
    pub mime_type: Option<RustMimeType>,
    /// Optional textual description attached to the picture frame.
    pub description: Option<String>,
    /// Raw encoded image bytes (PNG, JPEG, WebP, etc.).
    pub bytes: Vec<u8>,
}

/// Chapter marker embedded in the audio file.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RustAudioChapter {
    /// Chapter title.
    pub title: String,
    /// Chapter start timestamp in milliseconds.
    pub start_ms: u64,
    /// Chapter end timestamp in milliseconds.
    pub end_ms: u64,
}

/// Major version of an ID3v2 tag header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RustId3v2Version {
    /// ID3v2.2 (3-character frame IDs).
    V2,
    /// ID3v2.3 (4-character frame IDs).
    V3,
    /// ID3v2.4 (4-character frame IDs, UTF-8 support).
    V4,
}

/// Shoutcast / Icecast (ICY) live stream metadata and station headers.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RustIcyMetadata {
    /// Raw ICY `StreamTitle` value.
    pub stream_title: Option<String>,
    /// Optional ICY `StreamUrl` value.
    pub stream_url: Option<String>,
    /// Optional `icy-name` station name header.
    pub station_name: Option<String>,
    /// Optional `icy-genre` station genre header.
    pub station_genre: Option<String>,
    /// Optional `icy-url` station URL header.
    pub station_url: Option<String>,
    /// Optional `icy-br` station nominal bitrate in kbps.
    pub bitrate_kbps: Option<u32>,
}

/// Key-value pair representing a custom/user-defined metadata tag field.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RustCustomTagField {
    /// Tag field key/identifier.
    pub key: String,
    /// Tag field text value.
    pub value: String,
}

/// Extended metadata fields (63 fields matching haudiotagger::ExtendedTag).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RustExtendedMetadata {
    // MusicBrainz Identifiers
    pub music_brainz_recording_id: Option<String>,
    pub music_brainz_track_id: Option<String>,
    pub music_brainz_release_id: Option<String>,
    pub music_brainz_release_group_id: Option<String>,
    pub music_brainz_artist_id: Option<String>,
    pub music_brainz_release_artist_id: Option<String>,
    pub music_brainz_work_id: Option<String>,
    pub music_brainz_release_type: Option<String>,

    // AcoustID
    pub acoust_id: Option<String>,
    pub acoust_id_fingerprint: Option<String>,

    // Standard Identifiers
    pub isrc: Option<String>,
    pub barcode: Option<String>,
    pub catalog_number: Option<String>,

    // Credits & People
    pub arranger: Option<String>,
    pub conductor: Option<String>,
    pub director: Option<String>,
    pub engineer: Option<String>,
    pub lyricist: Option<String>,
    pub mix_dj: Option<String>,
    pub mix_engineer: Option<String>,
    pub performer: Option<String>,
    pub producer: Option<String>,
    pub publisher: Option<String>,
    pub label: Option<String>,
    pub remixer: Option<String>,
    pub writer: Option<String>,
    pub composer: Option<String>,
    pub original_lyricist: Option<String>,

    // Detailed Dates
    pub recording_date: Option<String>,
    pub release_date: Option<String>,
    pub original_release_date: Option<String>,

    // Style & Classification
    pub initial_key: Option<String>,
    pub color: Option<String>,
    pub mood: Option<String>,

    // URLs
    pub audio_file_url: Option<String>,
    pub audio_source_url: Option<String>,
    pub commercial_information_url: Option<String>,
    pub copyright_url: Option<String>,
    pub track_artist_url: Option<String>,
    pub radio_station_url: Option<String>,
    pub payment_url: Option<String>,
    pub publisher_url: Option<String>,

    // Legal & Copyright
    pub copyright_message: Option<String>,
    pub license: Option<String>,

    // Podcast
    pub podcast_description: Option<String>,
    pub podcast_series_category: Option<String>,
    pub podcast_url: Option<String>,
    pub podcast_global_unique_id: Option<String>,
    pub podcast_keywords: Option<String>,

    // Grouping, Sorting & Encoding
    pub set_subtitle: Option<String>,
    pub show_name: Option<String>,
    pub content_group: Option<String>,
    pub track_subtitle: Option<String>,
    pub language: Option<String>,
    pub script: Option<String>,
    pub parental_advisory: Option<String>,
    pub file_owner: Option<String>,
    pub original_file_name: Option<String>,
    pub original_media_type: Option<String>,
    pub encoded_by: Option<String>,
    pub encoder_software: Option<String>,
    pub encoder_settings: Option<String>,
}

/// Complete parsed audio metadata and raw synthesized container bytes.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct RustAudioMetadata {
    /// Track title.
    pub title: Option<String>,
    /// Primary track artist.
    pub track_artist: Option<String>,
    /// Album title.
    pub album: Option<String>,
    /// Album artist.
    pub album_artist: Option<String>,
    /// Release or recording year.
    pub year: Option<u32>,
    /// Genre name.
    pub genre: Option<String>,
    /// Track number within the album/disc.
    pub track_number: Option<u32>,
    /// Total tracks on the album/disc.
    pub track_total: Option<u32>,
    /// Disc number.
    pub disc_number: Option<u32>,
    /// Total discs in the release.
    pub disc_total: Option<u32>,
    /// Synchronized or unsynchronized lyrics.
    pub lyrics: Option<String>,
    /// General comment tag.
    pub comment: Option<String>,
    /// Tempo in beats per minute (BPM).
    pub bpm: Option<f32>,
    /// ReplayGain track gain string (e.g. "-6.50 dB").
    pub replay_gain_track_gain: Option<String>,
    /// ReplayGain track peak string (e.g. "0.988553").
    pub replay_gain_track_peak: Option<String>,
    /// ReplayGain album gain string.
    pub replay_gain_album_gain: Option<String>,
    /// ReplayGain album peak string.
    pub replay_gain_album_peak: Option<String>,
    /// Embedded pictures / cover art.
    pub pictures: Vec<RustAudioPicture>,
    /// Extended 63-field metadata set.
    pub extended: RustExtendedMetadata,
    /// Embedded chapter markers.
    pub chapters: Vec<RustAudioChapter>,
    /// Custom user-defined key-value tag fields.
    pub custom_tags: Vec<RustCustomTagField>,
    /// Detected tag container formats (e.g. "ID3v2", "ID3v1", "VorbisComments", "iTunes", "APE", "RiffInfo", "AiffText", "Matroska", "ICY").
    pub tag_formats: Vec<String>,
    /// Specific ID3v2 version if an ID3v2 tag is present.
    pub id3v2_version: Option<RustId3v2Version>,
    /// Live Shoutcast/Icecast ICY metadata when streaming from an ICY server.
    pub icy: Option<RustIcyMetadata>,
    /// Raw synthesized metadata container bytes (ID3v2, Vorbis Comments, moov atom, etc.).
    pub bytes: Vec<u8>,
}

/// Configuration parameters for offline acoustic and metadata analysis.
#[derive(Debug, Clone)]
pub struct RustAnalysisConfig {
    /// Whether to calculate ITU-R BS.1770-4 loudness and ReplayGain.
    pub replay_gain: bool,
    /// Whether to extract a normalized peak waveform envelope.
    pub waveform: bool,
    /// Whether to extract raw metadata bytes.
    pub metadata: bool,
    /// Whether to compute a Chromaprint / AcoustID audio fingerprint.
    pub chromaprint: bool,
    /// Number of normalized waveform buckets to compute.
    pub waveform_points: u32,
    /// Reference target loudness in LUFS (defaults to -18.0).
    pub target_lufs: f32,
    /// Optional maximum duration in milliseconds to analyze (used for live/infinite streams).
    pub max_duration_ms: Option<i64>,
}

impl Default for RustAnalysisConfig {
    fn default() -> Self {
        Self {
            replay_gain: true,
            waveform: true,
            metadata: false,
            chromaprint: false,
            waveform_points: 100,
            target_lufs: -18.0,
            max_duration_ms: None,
        }
    }
}

/// Digital acoustic fingerprint generated via Chromaprint / AcoustID.
#[derive(Debug, Clone, Default)]
pub struct RustChromaprintResult {
    /// Compressed Base64-encoded fingerprint string compatible with AcoustID API and fpcalc.
    pub fingerprint: String,
    /// Raw 32-bit unsigned integer array representing the acoustic fingerprint.
    pub raw: Vec<u32>,
    /// Algorithm version code used.
    pub algorithm: i32,
}

/// Offline acoustic analysis results containing format, loudness, waveform, and metadata.
#[derive(Debug, Clone, Default)]
pub struct RustAudioAnalysisResult {
    /// Format and audio technical characteristics (cost: 0).
    pub audio_info: RustAudioInfo,
    /// Whether ReplayGain analysis was performed and populated.
    pub has_replay_gain: bool,
    /// Integrated loudness in LUFS according to ITU-R BS.1770-4.
    pub integrated_lufs: f32,
    /// Recommended volume normalization adjustment in decibels.
    pub replay_gain_db: f32,
    /// Peak amplitude measured for ReplayGain.
    pub replay_gain_peak: f32,
    /// Whether waveform points were computed.
    pub has_waveform: bool,
    /// Spectral centroid metric in Hz.
    pub spectral_centroid: f32,
    /// Spectral energy band values.
    pub frequency_bands: Vec<f32>,
    /// Normalized amplitude envelope points for waveform display.
    pub waveform_peaks: Vec<f32>,
    /// Whether metadata bytes were extracted.
    pub has_metadata: bool,
    /// Encapsulated metadata bytes.
    pub metadata: Option<RustAudioMetadata>,
    /// Whether Chromaprint analysis was performed and populated.
    pub has_chromaprint: bool,
    /// Digital acoustic fingerprint generated via Chromaprint.
    pub chromaprint: Option<RustChromaprintResult>,
}

/// Configuration governing crossfade transition durations and gain curves.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RustCrossfadeConfig {
    /// Overlap duration for automatic end-of-track transitions in milliseconds.
    pub auto_duration_ms: u64,
    /// Overlap duration for manual track skips in milliseconds.
    pub manual_duration_ms: u64,
    /// Gain curve interpolation formula (0: equal power, 1: linear).
    pub curve: i32,
}

impl Default for RustCrossfadeConfig {
    fn default() -> Self {
        Self {
            auto_duration_ms: 5000,
            manual_duration_ms: 500,
            curve: 0,
        }
    }
}

/// Representation of an audio track queued for playback.
#[derive(Debug, Clone, Default)]
pub struct RustAudioSource {
    /// Monotonically increasing queue entry identifier.
    pub id: i64,
    /// File path, HTTP URL, or stream URI.
    pub source: String,
    /// Optional HTTP headers for network requests.
    pub headers: Option<Vec<RustHttpHeader>>,
    /// Optional in-memory raw audio bytes.
    pub data_bytes: Option<Vec<u8>>,
    /// Track-specific ReplayGain adjustment in dB.
    pub replay_gain_db: Option<f32>,
    /// Track-specific true peak amplitude.
    pub replay_peak: Option<f32>,
}

impl From<RustAudioSource> for crate::core::dual_source::AudioSourceCore {
    fn from(it: RustAudioSource) -> Self {
        Self {
            id: it.id,
            source: it.source,
            headers: it.headers,
            data_bytes: it.data_bytes,
            replay_gain_db: it.replay_gain_db,
            replay_peak: it.replay_peak,
        }
    }
}

impl From<&crate::core::dual_source::AudioSourceCore> for RustAudioSource {
    fn from(it: &crate::core::dual_source::AudioSourceCore) -> Self {
        Self {
            id: it.id,
            source: it.source.clone(),
            headers: it.headers.clone(),
            data_bytes: None,
            replay_gain_db: it.replay_gain_db,
            replay_peak: it.replay_peak,
        }
    }
}

/// Three-dimensional Cartesian coordinate vector used in 3D spatial audio calculations.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct RustVector3 {
    /// X axis position (left / right).
    pub x: f32,
    /// Y axis position (up / down).
    pub y: f32,
    /// Z axis position (forward / backward).
    pub z: f32,
}

/// Distance attenuation model for 3D positional audio emitters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RustDistanceModel {
    /// Realistic inverse distance rolloff according to the inverse-square law.
    #[default]
    Inverse,
    /// Linear distance attenuation down to silence at maximum distance.
    Linear,
    /// Exponential distance attenuation for rapid volume falloff.
    Exponential,
}

/// Listener orientation and position in 3D virtual acoustic space.
#[derive(Debug, Clone, Copy, Default)]
pub struct RustSpatialListener {
    /// World position coordinates of the listener.
    pub position: RustVector3,
    /// Linear velocity vector for Doppler effect calculation.
    pub velocity: RustVector3,
    /// Forward orientation direction vector.
    pub forward: RustVector3,
    /// Upward orientation direction vector.
    pub up: RustVector3,
}

/// Emitter parameters for 3D positional audio sources.
#[derive(Debug, Clone, Copy)]
pub struct RustSpatialEmitter {
    /// World position coordinates of the emitter.
    pub position: RustVector3,
    /// Velocity vector for Doppler pitch shift calculations.
    pub velocity: RustVector3,
    /// Directional vector if emitting sound in a directional cone.
    pub direction: Option<RustVector3>,
    /// Minimum distance where volume attenuation begins.
    pub min_distance: f32,
    /// Maximum distance beyond which sound ceases or stays constant.
    pub max_distance: f32,
    /// Attenuation rolloff rate multiplier.
    pub rolloff_factor: f32,
    /// Doppler pitch frequency shift multiplier.
    pub doppler_factor: f32,
    /// Inner cone angle in radians where sound plays at full gain.
    pub inner_angle_rad: f32,
    /// Outer cone angle in radians where sound drops to outer gain.
    pub outer_angle_rad: f32,
    /// Attenuation gain applied outside the outer directional cone.
    pub outer_gain: f32,
    /// Mathematical distance attenuation curve model.
    pub distance_model: RustDistanceModel,
}

impl Default for RustSpatialEmitter {
    fn default() -> Self {
        Self {
            position: RustVector3::default(),
            velocity: RustVector3::default(),
            direction: None,
            min_distance: 1.0,
            max_distance: 1000.0,
            rolloff_factor: 1.0,
            doppler_factor: 1.0,
            inner_angle_rad: std::f32::consts::PI * 2.0,
            outer_angle_rad: std::f32::consts::PI * 2.0,
            outer_gain: 0.0,
            distance_model: RustDistanceModel::Inverse,
        }
    }
}

impl From<RustVector3> for crate::dsp::spatial::Vector3 {
    fn from(v: RustVector3) -> Self {
        Self {
            x: v.x,
            y: v.y,
            z: v.z,
        }
    }
}

impl From<crate::dsp::spatial::Vector3> for RustVector3 {
    fn from(v: crate::dsp::spatial::Vector3) -> Self {
        Self {
            x: v.x,
            y: v.y,
            z: v.z,
        }
    }
}

impl From<RustDistanceModel> for crate::dsp::spatial::DistanceModel {
    fn from(m: RustDistanceModel) -> Self {
        match m {
            RustDistanceModel::Inverse => Self::Inverse,
            RustDistanceModel::Linear => Self::Linear,
            RustDistanceModel::Exponential => Self::Exponential,
        }
    }
}

impl From<RustSpatialListener> for crate::dsp::spatial::SpatialListener {
    fn from(l: RustSpatialListener) -> Self {
        Self {
            position: l.position.into(),
            velocity: l.velocity.into(),
            forward: l.forward.into(),
            up: l.up.into(),
        }
    }
}

impl From<RustSpatialEmitter> for crate::dsp::spatial::SpatialEmitter {
    fn from(e: RustSpatialEmitter) -> Self {
        Self {
            position: e.position.into(),
            velocity: e.velocity.into(),
            direction: e.direction.map(Into::into),
            min_distance: e.min_distance,
            max_distance: e.max_distance,
            rolloff_factor: e.rolloff_factor,
            doppler_factor: e.doppler_factor,
            inner_angle_rad: e.inner_angle_rad,
            outer_angle_rad: e.outer_angle_rad,
            outer_gain: e.outer_gain,
            distance_model: e.distance_model.into(),
        }
    }
}

/// Policy governing which active voice to terminate when polyphony limits are reached.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RustVoiceStealingPolicy {
    /// Steal voice with the lowest numerical priority level.
    #[default]
    LowestPriority,
    /// Steal voice that has been playing the longest.
    Oldest,
    /// Steal voice with the lowest computed audible amplitude.
    Quietest,
    /// Steal voice located farthest from the 3D listener.
    Farthest,
}

impl From<RustVoiceStealingPolicy> for crate::core::voice_pool::VoiceStealingPolicy {
    fn from(p: RustVoiceStealingPolicy) -> Self {
        match p {
            RustVoiceStealingPolicy::LowestPriority => Self::LowestPriority,
            RustVoiceStealingPolicy::Oldest => Self::Oldest,
            RustVoiceStealingPolicy::Quietest => Self::Quietest,
            RustVoiceStealingPolicy::Farthest => Self::Farthest,
        }
    }
}

impl From<crate::core::voice_pool::VoiceStealingPolicy> for RustVoiceStealingPolicy {
    fn from(p: crate::core::voice_pool::VoiceStealingPolicy) -> Self {
        match p {
            crate::core::voice_pool::VoiceStealingPolicy::LowestPriority => Self::LowestPriority,
            crate::core::voice_pool::VoiceStealingPolicy::Oldest => Self::Oldest,
            crate::core::voice_pool::VoiceStealingPolicy::Quietest => Self::Quietest,
            crate::core::voice_pool::VoiceStealingPolicy::Farthest => Self::Farthest,
        }
    }
}

/// Metadata and specifications of a decoded audio sample held in memory.
#[derive(Debug, Clone, Default)]
pub struct RustSoundBufferInfo {
    /// Unique integer buffer identifier.
    pub id: u64,
    /// Audio sample rate in Hz.
    pub sample_rate: u32,
    /// Number of audio channels.
    pub channels: u32,
    /// Duration of audio in milliseconds.
    pub duration_ms: i64,
    /// Total audio frame count.
    pub frame_count: usize,
}

/// Format and sample bit depth for captured audio recordings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RustWavFormat {
    /// 16-bit signed integer linear PCM.
    #[default]
    Pcm16,
    /// 32-bit floating point linear PCM.
    Float32,
}

impl From<RustWavFormat> for crate::core::recording::WavFormat {
    fn from(f: RustWavFormat) -> Self {
        match f {
            RustWavFormat::Pcm16 => Self::Pcm16,
            RustWavFormat::Float32 => Self::Float32,
        }
    }
}

impl From<crate::core::recording::WavFormat> for RustWavFormat {
    fn from(f: crate::core::recording::WavFormat) -> Self {
        match f {
            crate::core::recording::WavFormat::Pcm16 => Self::Pcm16,
            crate::core::recording::WavFormat::Float32 => Self::Float32,
        }
    }
}

/// Dynamic sidechain ducking configuration parameters.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RustDuckingConfig {
    /// Whether automatic ducking is enabled.
    pub enabled: bool,
    /// Attenuation gain in decibels applied to background music when ducking triggers.
    pub ducking_db: f32,
    /// Threshold in decibels above which input signal triggers ducking.
    pub threshold_db: f32,
    /// Attack ramp time in milliseconds.
    pub attack_ms: f32,
    /// Hold time in milliseconds before release commences.
    pub hold_ms: f32,
    /// Release ramp time in milliseconds back to unity gain.
    pub release_ms: f32,
}

impl Default for RustDuckingConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            ducking_db: -14.0,
            threshold_db: -30.0,
            attack_ms: 30.0,
            hold_ms: 250.0,
            release_ms: 400.0,
        }
    }
}

/// Cue channel preview configuration for DJ workflows.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct RustCueConfig {
    /// Whether cue monitoring is active.
    pub enabled: bool,
    /// Target audio output device ID for the cue feed.
    pub device_id: Option<String>,
    /// Cue monitoring volume level.
    pub volume: f32,
    /// Cue source selection (0: Deck A, 1: Deck B, 2: Master).
    pub mode: i32,
}

/// Initialization configuration for the audio player and backend engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RustPlayerConfig {
    /// Render buffer chunk size in frames.
    pub buffer_size_frames: u32,
    /// Maximum concurrent sound effect voices allowed.
    pub max_voices: u32,
    /// Optional maximum RAM budget in bytes allocated for decoded sound effect samples (`None` = unlimited).
    pub max_ram_bytes: Option<usize>,
    /// Whether playback pauses automatically on audio device change or disconnection.
    pub pause_on_device_change: bool,
    /// Ring buffer capacity for local file streaming in milliseconds.
    pub buffer_local_duration_ms: u64,
    /// Ring buffer capacity for network HTTP streaming in milliseconds.
    pub buffer_network_duration_ms: u64,
    /// Audio bus feeding the real-time visualizer (0: All, 1: MusicMix, 2: ActiveTrack, 3: StandbyTrack, 4: VoiceOnly).
    pub visualizer_source: i32,
}

impl Default for RustPlayerConfig {
    fn default() -> Self {
        Self {
            buffer_size_frames: 1024,
            max_voices: 64,
            max_ram_bytes: Some(50 * 1024 * 1024),
            pause_on_device_change: true,
            buffer_local_duration_ms: 30000,
            buffer_network_duration_ms: 30000,
            visualizer_source: 0,
        }
    }
}

/// Audio signal source routed to an output device or live file recording session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioOutputSource {
    /// Complete master mix (music + SFX voices + microphone + ducking + master limiter).
    All = 0,
    /// Pure music mix from decks with music DSP (EQ, Reverb), excluding SFX and microphone.
    MusicMix = 1,
    /// Isolated active deck track only.
    ActiveTrack = 2,
    /// Isolated standby deck track only (ideal for DJ pre-listening).
    StandbyTrack = 3,
    /// Isolated microphone capture voice signal only, excluding music and sound effects.
    VoiceOnly = 4,
}

impl From<i32> for AudioOutputSource {
    fn from(v: i32) -> Self {
        match v {
            1 => AudioOutputSource::MusicMix,
            2 => AudioOutputSource::ActiveTrack,
            3 => AudioOutputSource::StandbyTrack,
            4 => AudioOutputSource::VoiceOnly,
            _ => AudioOutputSource::All,
        }
    }
}

/// Audio hardware output endpoint configuration.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RustAudioOutput {
    /// Hardware device identifier, or "AUTO" for the system default route.
    pub device_id: String,
    /// Channel routing source (0: All, 1: MusicMix, 2: ActiveTrack, 3: StandbyTrack).
    pub source: i32,
}

/// Real-time capture configuration parameters for an audio input node.
#[derive(Debug, Clone, PartialEq)]
pub struct RustAudioInputConfig {
    /// Linear capture input gain multiplier (>= 0.0). Defaults to 1.0.
    pub volume: f32,
    /// Optional sidechain ducking configuration.
    pub ducking: Option<RustDuckingConfig>,
    /// Whether low-latency direct pass-through monitoring to the master output is enabled.
    pub monitor_direct: bool,
    /// Linear volume multiplier for direct voice monitoring (>= 0.0).
    pub monitor_volume: f32,
}

impl Default for RustAudioInputConfig {
    fn default() -> Self {
        Self {
            volume: 1.0,
            ducking: None,
            monitor_direct: false,
            monitor_volume: 1.0,
        }
    }
}

/// Audio input hardware endpoint configuration.
#[derive(Debug, Clone, PartialEq)]
pub struct RustAudioInput {
    /// Hardware device identifier, or "AUTO" for the system default capture route.
    pub device_id: String,
    /// Real-time capture configuration parameters.
    pub config: RustAudioInputConfig,
}

/// Sound effect asset registration descriptor.
#[derive(Debug, Clone)]
pub struct RustAudioEffect {
    /// Unique identifier for the sound effect.
    pub id: String,
    /// Audio source holding URI or raw decoded data.
    pub source: RustAudioSource,
    /// Maximum polyphony instances for this specific effect.
    pub max_polyphony: u32,
    /// Whether the decoded sample buffer is pinned in RAM.
    pub pinned: bool,
}

impl From<RustAudioEffect> for crate::core::voice_pool::EffectCatalogItem {
    fn from(e: RustAudioEffect) -> Self {
        Self {
            id: e.id,
            source: e.source.into(),
            max_polyphony: e.max_polyphony as usize,
            pinned: e.pinned,
        }
    }
}

/// Playback properties when triggering an individual sound effect instance.
#[derive(Debug, Clone, Default)]
pub struct RustEffectConfig {
    /// Instance playback volume.
    pub volume: f32,
    /// Stereo panning balance (-1.0 to +1.0).
    pub balance: f32,
    /// Pitch shift multiplier.
    pub pitch: f32,
    /// Playback rate multiplier.
    pub rate: f32,
    /// Whether the sound effect loops seamlessly until explicitly stopped.
    pub looping: bool,
    /// Voice priority level for voice-stealing arbitration.
    pub priority: u8,
    /// Random pitch jitter variance.
    pub pitch_jitter: f32,
    /// Random volume jitter variance.
    pub volume_jitter: f32,
    /// Optional 3D spatial emitter parameters.
    pub spatial: Option<RustSpatialEmitter>,
    /// DSP routing mode (0 = Inherit, 1 = Isolate, 2 = Bypass).
    pub dsp_routing: i32,
}

impl From<RustEffectConfig> for crate::core::voice_pool::EffectConfig {
    fn from(c: RustEffectConfig) -> Self {
        Self {
            volume: c.volume,
            balance: c.balance,
            pitch: c.pitch,
            rate: c.rate,
            looping: c.looping,
            priority: c.priority,
            pitch_jitter: c.pitch_jitter,
            volume_jitter: c.volume_jitter,
            spatial: c.spatial.map(Into::into),
            dsp_routing: c.dsp_routing.into(),
        }
    }
}

impl From<crate::core::dual_source::AudioSourceCore> for RustAudioSource {
    fn from(s: crate::core::dual_source::AudioSourceCore) -> Self {
        Self {
            id: s.id,
            source: s.source,
            headers: s.headers,
            data_bytes: s.data_bytes,
            replay_gain_db: s.replay_gain_db,
            replay_peak: s.replay_peak,
        }
    }
}

/// Finalized summary metrics of a completed audio recording.
#[derive(Debug, Clone)]
pub struct RustRecordingResult {
    /// File path where recorded audio was stored.
    pub path: String,
    /// Total duration of recorded audio in milliseconds.
    pub duration_ms: u64,
    /// Total bytes written to disk.
    pub bytes_written: usize,
    /// Total PCM audio samples captured.
    pub sample_count: u64,
}

/// High-level event emitted over the Flutter Rust Bridge stream to Dart listeners.
#[derive(Debug, Clone)]
pub enum RustPlayerEvent {
    /// Technical format characteristics of the active audio track.
    AudioInfo(RustAudioInfo),
    /// Playback state transition code (`PlaybackState`).
    PlaybackState(i32),
    /// Elapsed track position in milliseconds.
    Position(i64),
    /// Whether audio is actively playing.
    IsPlaying(bool),
    /// Whether player is buffering data.
    IsBuffering(bool),
    /// Tripartite ring buffer telemetry metrics.
    Buffer(RustBuffer),
    /// Playlist queue track IDs in active playback order and current queue index.
    Queue {
        /// Active queue track IDs.
        queue: Vec<i64>,
        /// Active queue index (-1 if none or uninitialized).
        current_index: i32,
    },
    /// Active playlist queue index (-1 when none/uninitialized).
    CurrentIndex(i32),
    /// Whether an overlap crossfade transition is active.
    IsCrossfading(bool),
    /// Crossfade durations and interpolation curve configuration.
    CrossfadeConfig(RustCrossfadeConfig),
    /// Instantaneous visualizer FFT and loudness data.
    Visualizer(RustVisualizerData),
    /// Whether visualizer analysis is active.
    VisualizerEnabled(bool),
    /// Audio bus feeding the real-time visualizer (0: All, 1: MusicMix, 2: ActiveTrack, 3: StandbyTrack, 4: VoiceOnly).
    VisualizerSource(i32),
    /// Master volume level.
    Volume(f32),
    /// Playback speed rate multiplier.
    Rate(f32),
    /// Playback pitch shift multiplier.
    Pitch(f32),
    /// Stereo balance pan (-1.0 to +1.0).
    Balance(f32),
    /// Downmix stereo to mono.
    Mono(bool),
    /// Audio buffer frame size.
    BufferSize(u32),
    /// Silence detection configuration.
    SilenceConfig(RustSilenceConfig),
    /// Cumulative silence skipped in milliseconds.
    SilenceSaved(i64),
    /// Equalizer 10-band gain parameters.
    Equalizer(RustEqualizerParams),
    /// Equalizer preamp gain in dB.
    Preamp(f32),
    /// Active ReplayGain loudness normalization settings.
    ReplayGain(RustReplayGainConfig),
    /// Active ReplayGain operating mode (0: disabled, 1: track, 2: forced).
    ReplayGainMode(u32),
    /// Default ReplayGain fallback adjustment in dB.
    DefaultReplayGain(f32),
    /// Bauer binaural crossfeed configuration.
    Crossfeed(RustCrossfeedConfig),
    /// 3D stereo widening spatializer state.
    Spatializer {
        /// Whether spatializer is enabled.
        enabled: bool,
        /// Stereo widening factor.
        width: f32,
    },
    /// Algorithmic studio reverberation settings.
    Reverb(RustReverbParams),
    /// Brickwall peak limiter state.
    Limiter(bool),
    /// Whether file recording is currently running.
    IsRecording(bool),
    /// Cumulative recorded duration in milliseconds.
    RecordedDuration(u64),
    /// Whether dynamic ducking is attenuating background music.
    IsDuckingActive(bool),
    /// Live microphone input RMS loudness level.
    MicRmsLevel(f32),
    /// Voice completion notification with voice ID.
    VoiceCompleted(u32),
    /// Notification of registered sound effect assets and total RAM bytes allocated.
    LoadedEffects {
        /// Identifiers of loaded sound effects.
        ids: Vec<String>,
        /// Total RAM bytes occupied by decoded effect samples.
        allocated_bytes: usize,
    },
    /// Number of concurrent active sound effect voices.
    ActiveVoices(u32),
    /// Audio metadata stream payload.
    AudioMetadata(RustAudioMetadata),
    /// Whether metadata stream reception is enabled.
    MetadataEnabled(bool),
    /// Live audio recording status and active source.
    RecordingState {
        /// Whether file recording is currently running.
        is_recording: bool,
        /// Audio signal source captured (0: All, 1: MusicMix, 2: ActiveTrack, 3: StandbyTrack).
        source: i32,
    },
    /// Active loop mode policy (0: off, 1: one, 2: all).
    LoopMode(i32),
    /// Whether playlist shuffle is enabled.
    IsShuffled(bool),
    /// Continuous auto-refill Infinite Mix configuration.
    InfiniteMix(RustInfiniteMixConfig),
    /// Whether auto-pause on device change is enabled.
    PauseOnDeviceChange(bool),
    /// Active audio input sources in the multi-capture matrix.
    Inputs(Vec<RustAudioInput>),
    /// List of available audio output devices.
    OutputDevices(Vec<RustAudioDevice>),
    /// List of available audio input devices.
    InputDevices(Vec<RustAudioDevice>),
    /// Request for Dart to read custom stream bytes.
    DartReadRequest(RustDartReadRequest),
    /// Request for Dart to replenish queue for infinite mix.
    NeedMoreTracks {
        /// ID of the current playing track.
        current_track_id: i64,
        /// Remaining number of tracks ahead in the playlist queue.
        remaining_tracks: u32,
    },
    /// Active audio output destinations in the multi-sink matrix.
    Outputs(Vec<RustAudioOutput>),
    /// Error notification with message and code.
    Error {
        /// Detailed human-readable error description.
        message: String,
        /// Numeric error categorization code.
        code: i32,
    },
}
