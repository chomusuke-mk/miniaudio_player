//! Unified Audio Decoder Facade & Probing Pipeline.
//!
//! Orchestrates format detection across `ExtendedPcmReader`, `DsfReader`, `ApeReader`,
//! `WavpackReader`, and Symphonia container/codec readers via a clean black-box interface.

use symphonia::core::codecs::audio::{
    well_known as codec_wk, AudioCodecId, AudioCodecParameters, AudioDecoder, AudioDecoderOptions,
    CODEC_ID_NULL_AUDIO,
};
use symphonia::core::codecs::registry::CodecRegistry;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{
    well_known as format_wk, FormatId, FormatOptions, FormatReader, SeekMode, SeekTo,
};
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::{MetadataOptions, RawTag, RawValue};
use symphonia::core::units::{Duration as SymphoniaDuration, Time, TimeBase, Timestamp};
use super::aac_decoder::RustyAacDecoder;
use super::ape::{ApeProbe, ApeReader};
use super::dsf::{DsfProbe, DsfReader};
use super::extended_pcm::{ExtendedPcmProbe, ExtendedPcmReader};
use symphonia_opus::OpusDecoder;
use super::wavpack::{WavpackProbe, WavpackReader};
use crate::metadata::SymphoniaExtractedMeta;

/// Constructs a Symphonia `CodecRegistry` preloaded with standard codecs and pure-Rust Opus/AAC decoders.
pub fn create_codec_registry() -> CodecRegistry {
    let mut registry = CodecRegistry::new();
    symphonia::default::register_enabled_codecs(&mut registry);
    registry.register_audio_decoder::<OpusDecoder>();
    registry.register_audio_decoder::<RustyAacDecoder>();
    registry
}

/// Returns a process-wide cached `CodecRegistry` so repeated stream opens skip rebuilding codec lookup tables.
pub fn shared_codec_registry() -> &'static CodecRegistry {
    static REGISTRY: std::sync::OnceLock<CodecRegistry> = std::sync::OnceLock::new();
    REGISTRY.get_or_init(create_codec_registry)
}

fn classify_symphonia_codec(
    codec: AudioCodecId,
    explicit_bps: Option<u32>,
) -> (&'static str, bool, Option<u32>) {
    match codec {
        codec_wk::CODEC_ID_MP1 => ("MP1", false, explicit_bps),
        codec_wk::CODEC_ID_MP2 => ("MP2", false, explicit_bps),
        codec_wk::CODEC_ID_MP3 => ("MP3", false, explicit_bps),
        codec_wk::CODEC_ID_FLAC => ("FLAC", true, explicit_bps),
        codec_wk::CODEC_ID_AAC => ("AAC", false, explicit_bps),
        codec_wk::CODEC_ID_ALAC => ("ALAC", true, explicit_bps),
        codec_wk::CODEC_ID_VORBIS => ("Vorbis", false, explicit_bps),
        codec_wk::CODEC_ID_OPUS => ("Opus", false, explicit_bps),
        codec_wk::CODEC_ID_WAVPACK => ("WavPack", true, explicit_bps),
        codec_wk::CODEC_ID_MONKEYS_AUDIO => ("APE", true, explicit_bps),
        codec_wk::CODEC_ID_PCM_ALAW => ("ALAW", false, explicit_bps.or(Some(8))),
        codec_wk::CODEC_ID_PCM_MULAW => ("ULAW", false, explicit_bps.or(Some(8))),
        codec_wk::CODEC_ID_ADPCM_MS
        | codec_wk::CODEC_ID_ADPCM_IMA_WAV
        | codec_wk::CODEC_ID_ADPCM_IMA_QT
        | codec_wk::CODEC_ID_ADPCM_G722
        | codec_wk::CODEC_ID_ADPCM_G726
        | codec_wk::CODEC_ID_ADPCM_G726LE => ("ADPCM", false, explicit_bps.or(Some(4))),
        codec_wk::CODEC_ID_PCM_S8
        | codec_wk::CODEC_ID_PCM_S8_PLANAR
        | codec_wk::CODEC_ID_PCM_U8
        | codec_wk::CODEC_ID_PCM_U8_PLANAR => ("PCM", true, explicit_bps.or(Some(8))),
        codec_wk::CODEC_ID_PCM_S16LE
        | codec_wk::CODEC_ID_PCM_S16LE_PLANAR
        | codec_wk::CODEC_ID_PCM_S16BE
        | codec_wk::CODEC_ID_PCM_S16BE_PLANAR
        | codec_wk::CODEC_ID_PCM_U16LE
        | codec_wk::CODEC_ID_PCM_U16LE_PLANAR
        | codec_wk::CODEC_ID_PCM_U16BE
        | codec_wk::CODEC_ID_PCM_U16BE_PLANAR => ("PCM", true, explicit_bps.or(Some(16))),
        codec_wk::CODEC_ID_PCM_S24LE
        | codec_wk::CODEC_ID_PCM_S24LE_PLANAR
        | codec_wk::CODEC_ID_PCM_S24BE
        | codec_wk::CODEC_ID_PCM_S24BE_PLANAR
        | codec_wk::CODEC_ID_PCM_U24LE
        | codec_wk::CODEC_ID_PCM_U24LE_PLANAR
        | codec_wk::CODEC_ID_PCM_U24BE
        | codec_wk::CODEC_ID_PCM_U24BE_PLANAR => ("PCM", true, explicit_bps.or(Some(24))),
        codec_wk::CODEC_ID_PCM_S32LE
        | codec_wk::CODEC_ID_PCM_S32LE_PLANAR
        | codec_wk::CODEC_ID_PCM_S32BE
        | codec_wk::CODEC_ID_PCM_S32BE_PLANAR
        | codec_wk::CODEC_ID_PCM_U32LE
        | codec_wk::CODEC_ID_PCM_U32LE_PLANAR
        | codec_wk::CODEC_ID_PCM_U32BE
        | codec_wk::CODEC_ID_PCM_U32BE_PLANAR
        | codec_wk::CODEC_ID_PCM_F32LE
        | codec_wk::CODEC_ID_PCM_F32LE_PLANAR
        | codec_wk::CODEC_ID_PCM_F32BE
        | codec_wk::CODEC_ID_PCM_F32BE_PLANAR => ("PCM", true, explicit_bps.or(Some(32))),
        codec_wk::CODEC_ID_PCM_F64LE
        | codec_wk::CODEC_ID_PCM_F64LE_PLANAR
        | codec_wk::CODEC_ID_PCM_F64BE
        | codec_wk::CODEC_ID_PCM_F64BE_PLANAR => ("PCM", true, explicit_bps.or(Some(64))),
        _ => ("Unknown", false, explicit_bps),
    }
}

fn classify_symphonia_container(
    format_id: FormatId,
    short_name: &str,
    hint_extension: Option<&str>,
    codec: &'static str,
) -> &'static str {
    match format_id {
        format_wk::FORMAT_ID_WAVE => "WAV",
        format_wk::FORMAT_ID_AIFF => "AIFF",
        format_wk::FORMAT_ID_CAF => "CAF",
        format_wk::FORMAT_ID_MP1 => "MP1",
        format_wk::FORMAT_ID_MP2 => "MP2",
        format_wk::FORMAT_ID_MP3 => "MP3",
        format_wk::FORMAT_ID_ADTS => "ADTS",
        format_wk::FORMAT_ID_OGG => "Ogg",
        format_wk::FORMAT_ID_FLAC => "FLAC",
        format_wk::FORMAT_ID_WAVPACK => "WavPack",
        format_wk::FORMAT_ID_ISOMP4 => "MP4",
        format_wk::FORMAT_ID_MKV => {
            if hint_extension == Some("webm") || short_name.eq_ignore_ascii_case("webm") {
                "WebM"
            } else {
                "Matroska"
            }
        }
        _ => match short_name.to_ascii_lowercase().as_str() {
            "wav" | "wave" => "WAV",
            "aiff" | "aif" => "AIFF",
            "caf" => "CAF",
            "mp3" => "MP3",
            "aac" | "adts" => "ADTS",
            "ogg" | "oga" => "Ogg",
            "flac" => "FLAC",
            "isomp4" | "mp4" | "m4a" => "MP4",
            "mkv" | "matroska" | "mka" => "Matroska",
            "webm" => "WebM",
            _ => codec,
        },
    }
}

/// Encapsulates Symphonia container reading, packet filtering, and audio frame decoding.
struct SymphoniaTrackSession {
    format_reader: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
    track_id: u32,
    sample_rate: u32,
    raw_sample_rate: Option<u32>,
    channels: u32,
    bits_per_sample: Option<u32>,
    codec: &'static str,
    container_format: &'static str,
    lossless: bool,
    duration_ms: Option<u64>,
    symphonia_meta: SymphoniaExtractedMeta,
    last_io_unexpected_eof: bool,
    reached_eof: bool,
}

impl SymphoniaTrackSession {
    fn open(
        source: Box<dyn MediaSource>,
        hint_extension: Option<&str>,
    ) -> Result<Self, SymphoniaError> {
        let mut hint = Hint::new();
        if let Some(ext) = hint_extension {
            hint.with_extension(ext);
        }

        let mss = MediaSourceStream::new(source, MediaSourceStreamOptions::default());
        let mut format_reader = symphonia::default::get_probe().probe(
            &hint,
            mss,
            FormatOptions::default(),
            MetadataOptions::default(),
        )?;

        let (track_id, audio_params, time_base, duration, num_frames) =
            Self::select_primary_audio_track(&*format_reader)?;

        let (raw_sr, channels) = Self::validate_audio_params(&audio_params)?;
        let (codec, lossless, bits_per_sample) =
            classify_symphonia_codec(audio_params.codec, audio_params.bits_per_sample);
        let fmt_info = *format_reader.format_info();
        let container_format = classify_symphonia_container(
            fmt_info.format,
            fmt_info.short_name,
            hint_extension,
            codec,
        );
        let sample_rate = if codec == "Opus" { 48000 } else { raw_sr };
        let raw_sample_rate = Some(raw_sr);

        let media_info = *format_reader.media_info();
        let duration_ms = Self::compute_duration_ms(time_base, duration, num_frames)
            .or_else(|| Self::compute_duration_ms(media_info.time_base, media_info.duration, None))
            .or_else(|| Self::extract_metadata_duration_ms(&mut *format_reader));
        let symphonia_meta = SymphoniaExtractedMeta::from_format_reader(&mut *format_reader);

        let decoder = shared_codec_registry()
            .make_audio_decoder(&audio_params, &AudioDecoderOptions::default())?;

        Ok(Self {
            format_reader,
            decoder,
            track_id,
            sample_rate,
            raw_sample_rate,
            channels,
            bits_per_sample,
            codec,
            container_format,
            lossless,
            duration_ms,
            symphonia_meta,
            last_io_unexpected_eof: false,
            reached_eof: false,
        })
    }

    fn select_primary_audio_track(
        format_reader: &dyn FormatReader,
    ) -> Result<
        (
            u32,
            AudioCodecParameters,
            Option<TimeBase>,
            Option<SymphoniaDuration>,
            Option<u64>,
        ),
        SymphoniaError,
    > {
        let track = format_reader
            .tracks()
            .iter()
            .find(|t| {
                t.codec_params
                    .as_ref()
                    .and_then(|p| p.audio())
                    .map(|a| a.codec != CODEC_ID_NULL_AUDIO)
                    .unwrap_or(false)
            })
            .ok_or(SymphoniaError::Unsupported(
                "no supported audio track found",
            ))?;

        let params = track
            .codec_params
            .as_ref()
            .and_then(|p| p.audio())
            .ok_or(SymphoniaError::Unsupported(
                "audio track parameters missing",
            ))?
            .clone();

        Ok((
            track.id,
            params,
            track.time_base,
            track.duration,
            track.num_frames,
        ))
    }

    fn validate_audio_params(params: &AudioCodecParameters) -> Result<(u32, u32), SymphoniaError> {
        let sample_rate = params.sample_rate.unwrap_or(0);
        if sample_rate == 0 {
            return Err(SymphoniaError::Unsupported("invalid sample rate: 0"));
        }
        let channels = params
            .channels
            .as_ref()
            .map(|c| c.count() as u32)
            .unwrap_or(0);
        if channels == 0 || channels > 32 {
            return Err(SymphoniaError::Unsupported("invalid channel count"));
        }
        if params.bits_per_sample == Some(0) {
            return Err(SymphoniaError::Unsupported("invalid bits per sample: 0"));
        }
        Ok((sample_rate, channels))
    }

    fn compute_duration_ms(
        time_base: Option<TimeBase>,
        duration: Option<SymphoniaDuration>,
        num_frames: Option<u64>,
    ) -> Option<u64> {
        let tb = time_base?;
        if let Some(dur) = duration {
            tb.calc_duration(dur).map(|t| t.as_millis().max(0) as u64)
        } else if let Some(n_frames) = num_frames {
            tb.calc_duration(SymphoniaDuration::new(n_frames))
                .map(|t| t.as_millis().max(0) as u64)
        } else {
            None
        }
    }

    fn extract_metadata_duration_ms(format_reader: &mut dyn FormatReader) -> Option<u64> {
        let metadata = format_reader.metadata();
        let rev = metadata.current()?;
        for track in &rev.per_track {
            if let Some(ms) = Self::find_duration_in_tags(&track.metadata.tags) {
                return Some(ms);
            }
        }
        Self::find_duration_in_tags(&rev.media.tags)
    }

    fn find_duration_in_tags(tags: &[symphonia::core::meta::Tag]) -> Option<u64> {
        for tag in tags {
            if let Some(ms) = Self::parse_raw_duration_tag(&tag.raw) {
                return Some(ms);
            }
        }
        None
    }

    fn parse_raw_duration_tag(raw: &RawTag) -> Option<u64> {
        if !raw.key.to_ascii_uppercase().contains("DURATION") {
            return None;
        }
        if let RawValue::String(ref s) = raw.value {
            parse_duration_string(s)
        } else {
            None
        }
    }

    fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        out_pcm.clear();
        self.decode_next_frame_append(out_pcm)
    }

    fn decode_next_frame_append(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        self.last_io_unexpected_eof = false;
        loop {
            let packet = match self.format_reader.next_packet() {
                Ok(Some(pkt)) => {
                    self.reached_eof = false;
                    pkt
                }
                Ok(None) => {
                    self.reached_eof = true;
                    return Ok(false);
                }
                Err(SymphoniaError::IoError(ref err))
                    if err.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    self.last_io_unexpected_eof = true;
                    return Ok(false);
                }
                Err(err) => return Err(err),
            };

            if packet.track_id != self.track_id {
                continue;
            }

            match self.decoder.decode(&packet) {
                Ok(decoded) => {
                    let rate = decoded.spec().rate();
                    let ch = decoded.spec().channels().count() as u32;
                    if rate > 0 {
                        self.sample_rate = rate;
                    }
                    if ch > 0 {
                        self.channels = ch;
                    }
                    let samples = decoded.frames() * decoded.spec().channels().count();
                    if samples == 0 {
                        continue;
                    }
                    let base = out_pcm.len();
                    out_pcm.resize(base + samples, 0.0);
                    decoded.copy_to_slice_interleaved(&mut out_pcm[base..]);
                    return Ok(true);
                }
                Err(SymphoniaError::DecodeError(err)) => {
                    log::warn!("Symphonia decode frame error skipped: {}", err);
                    continue;
                }
                Err(err) => return Err(err),
            }
        }
    }

    fn advance_to_ms_cancellable<F: Fn() -> bool>(
        &mut self,
        target_stop_ms: u64,
        is_cancelled: &F,
    ) -> Option<u64> {
        let tb = self
            .format_reader
            .tracks()
            .iter()
            .find(|t| t.id == self.track_id)
            .and_then(|t| t.time_base)?;
        let mut last_ms = None;
        loop {
            if is_cancelled() {
                break;
            }
            let pkt = match self.format_reader.next_packet() {
                Ok(Some(pkt)) => pkt,
                Ok(None) => {
                    self.reached_eof = true;
                    break;
                }
                Err(_) => break,
            };
            if pkt.track_id != self.track_id {
                continue;
            }
            if let Some(t) = tb.calc_time(pkt.pts) {
                let pkt_ms = (t.as_nanos() / 1_000_000).max(0) as u64;
                last_ms = Some(pkt_ms);
                if pkt_ms >= target_stop_ms {
                    break;
                }
            }
        }
        last_ms
    }

    fn seek_ms(&mut self, position_ms: u64) -> Result<u64, SymphoniaError> {
        let tb = self
            .format_reader
            .tracks()
            .iter()
            .find(|t| t.id == self.track_id)
            .and_then(|t| t.time_base);
        let time = Time::from_millis_u64(position_ms);
        let res = self.format_reader.seek(
            SeekMode::Coarse,
            SeekTo::Time {
                time,
                track_id: Some(self.track_id),
            },
        );
        let time_to_ms = |t: Time| -> u64 { (t.as_nanos() / 1_000_000).max(0) as u64 };
        let mut actual_ms = position_ms;

        if let Ok(seeked) = res {
            if let Some(t) = tb.and_then(|time_base| time_base.calc_time(seeked.actual_ts)) {
                actual_ms = time_to_ms(t);
            }
        } else if res.is_err() && position_ms == 0 {
            if let Ok(seeked) = self.format_reader.seek(
                SeekMode::Coarse,
                SeekTo::Timestamp {
                    ts: Timestamp::default(),
                    track_id: self.track_id,
                },
            ) {
                if let Some(t) = tb.and_then(|time_base| time_base.calc_time(seeked.actual_ts)) {
                    actual_ms = time_to_ms(t);
                } else {
                    actual_ms = 0;
                }
            }
        } else if let Err(SymphoniaError::SeekError(symphonia::core::errors::SeekErrorKind::OutOfRange)) = &res {
            let within_known_dur = self.duration_ms.map(|d| position_ms < d).unwrap_or(true);
            if matches!(self.container_format, "Matroska" | "WebM")
                && position_ms > 0
                && within_known_dur
            {
                let mut recovered = false;
                for backoff in [1_500u64, 5_000, 10_000] {
                    let fallback_ms = position_ms.saturating_sub(backoff);
                    if self
                        .format_reader
                        .seek(
                            SeekMode::Coarse,
                            SeekTo::Time {
                                time: Time::from_millis_u64(fallback_ms),
                                track_id: Some(self.track_id),
                            },
                        )
                        .is_ok()
                    {
                        if let Some(pkt_ms) = self
                            .advance_to_ms_cancellable(position_ms.saturating_sub(150), &|| false)
                        {
                            actual_ms = pkt_ms;
                        }
                        recovered = true;
                        break;
                    }
                }
                if !recovered {
                    res?;
                }
            } else {
                res?;
            }
        } else {
            res?;
        }

        self.last_io_unexpected_eof = false;
        self.reached_eof = false;
        self.decoder.reset();
        Ok(actual_ms)
    }
}

enum EngineBackend {
    Symphonia(SymphoniaTrackSession),
    ExtendedPcm(ExtendedPcmReader),
    Dsf(DsfReader),
    Ape(ApeReader),
    WavPack(WavpackReader),
}

/// Universal audio decoding engine probing and decoding audio streams into interleaved float PCM.
pub struct SymphoniaEngine {
    backend: EngineBackend,
    sample_rate: u32,
    raw_sample_rate: Option<u32>,
    channels: u32,
    bits_per_sample: Option<u32>,
    codec: &'static str,
    container_format: &'static str,
    lossless: bool,
    duration_ms: Option<u64>,
    symphonia_meta: SymphoniaExtractedMeta,
    anchor_ms: u64,
    frames_from_anchor: u64,
    append_scratch: Vec<f32>,
    is_windowed: bool,
}

impl SymphoniaEngine {
    /// Probes and instantiates the appropriate format reader and decoder for `source`.
    pub fn new<M: MediaSource + 'static>(
        source: M,
        hint_extension: Option<&str>,
    ) -> Result<Self, SymphoniaError> {
        Self::new_with_options(source, hint_extension, true)
    }

    /// Probes and instantiates the appropriate format reader and decoder for `source`.
    /// When `allow_full_stream_scan` is `false`, skips synchronous full-stream ADTS scans
    /// that would stall or truncate over partially buffered network readers.
    pub fn new_with_options<M: MediaSource + 'static>(
        source: M,
        hint_extension: Option<&str>,
        allow_full_stream_scan: bool,
    ) -> Result<Self, SymphoniaError> {
        Self::from_boxed_with_options(Box::new(source), hint_extension, allow_full_stream_scan)
    }

    /// Probes and instantiates from a pre-boxed `MediaSource` (used by dynamic reopen paths).
    pub fn from_boxed_with_options(
        boxed_source: Box<dyn MediaSource>,
        hint_extension: Option<&str>,
        allow_full_stream_scan: bool,
    ) -> Result<Self, SymphoniaError> {
        let boxed_source = match ExtendedPcmReader::try_new(boxed_source)? {
            ExtendedPcmProbe::Matched(pcm) => {
                let sr = pcm.sample_rate();
                return Ok(Self {
                    sample_rate: sr,
                    raw_sample_rate: Some(sr),
                    channels: pcm.channels(),
                    bits_per_sample: Some(pcm.bits_per_sample()),
                    codec: "PCM",
                    container_format: pcm.container_format(),
                    lossless: true,
                    duration_ms: pcm.duration_ms(),
                    symphonia_meta: SymphoniaExtractedMeta::default(),
                    backend: EngineBackend::ExtendedPcm(pcm),
                    anchor_ms: 0,
                    frames_from_anchor: 0,
                    append_scratch: Vec::new(),
                    is_windowed: false,
                });
            }
            ExtendedPcmProbe::NotMatched(src) => src,
        };

        let boxed_source = match DsfReader::try_new(boxed_source)? {
            DsfProbe::Matched(dsf) => {
                return Ok(Self {
                    sample_rate: dsf.sample_rate(),
                    raw_sample_rate: Some(dsf.raw_sample_rate()),
                    channels: dsf.channels(),
                    bits_per_sample: Some(dsf.bits_per_sample()),
                    codec: "DSD",
                    container_format: "DSF",
                    lossless: true,
                    duration_ms: dsf.duration_ms(),
                    symphonia_meta: SymphoniaExtractedMeta::default(),
                    backend: EngineBackend::Dsf(dsf),
                    anchor_ms: 0,
                    frames_from_anchor: 0,
                    append_scratch: Vec::new(),
                    is_windowed: false,
                });
            }
            DsfProbe::NotMatched(src) => src,
        };

        let boxed_source = match ApeReader::try_new(boxed_source)? {
            ApeProbe::Matched(ape) => {
                let sr = ape.sample_rate();
                return Ok(Self {
                    sample_rate: sr,
                    raw_sample_rate: Some(sr),
                    channels: ape.channels(),
                    bits_per_sample: Some(ape.bits_per_sample()),
                    codec: "APE",
                    container_format: "APE",
                    lossless: true,
                    duration_ms: ape.duration_ms(),
                    symphonia_meta: SymphoniaExtractedMeta::default(),
                    backend: EngineBackend::Ape(ape),
                    anchor_ms: 0,
                    frames_from_anchor: 0,
                    append_scratch: Vec::new(),
                    is_windowed: false,
                });
            }
            ApeProbe::NotMatched(src) => src,
        };

        let mut boxed_source = match WavpackReader::try_new(boxed_source)? {
            WavpackProbe::Matched(wv) => {
                let sr = wv.sample_rate();
                return Ok(Self {
                    sample_rate: sr,
                    raw_sample_rate: Some(sr),
                    channels: wv.channels(),
                    bits_per_sample: Some(wv.bits_per_sample()),
                    codec: "WavPack",
                    container_format: "WavPack",
                    lossless: true,
                    duration_ms: wv.duration_ms(),
                    symphonia_meta: SymphoniaExtractedMeta::default(),
                    backend: EngineBackend::WavPack(wv),
                    anchor_ms: 0,
                    frames_from_anchor: 0,
                    append_scratch: Vec::new(),
                    is_windowed: false,
                });
            }
            WavpackProbe::NotMatched(src) => src,
        };

        let adts_info = if boxed_source.is_seekable() {
            if allow_full_stream_scan {
                crate::decoder::classifier::StreamClassifier::scan_adts_stream(&mut boxed_source)
            } else if hint_extension == Some("aac") {
                boxed_source.byte_len().and_then(|tot| {
                    crate::decoder::classifier::StreamClassifier::sample_adts_duration_ms(
                        &mut boxed_source,
                        tot,
                    )
                })
            } else {
                None
            }
        } else {
            None
        };

        let mut session = SymphoniaTrackSession::open(boxed_source, hint_extension)?;
        if let Some((_sr, _ch, exact_dur)) = adts_info {
            session.duration_ms = Some(exact_dur);
        }

        let symphonia_meta = session.symphonia_meta.clone();

        Ok(Self {
            sample_rate: session.sample_rate,
            raw_sample_rate: session.raw_sample_rate,
            channels: session.channels,
            bits_per_sample: session.bits_per_sample,
            codec: session.codec,
            container_format: session.container_format,
            lossless: session.lossless,
            duration_ms: session.duration_ms,
            symphonia_meta,
            backend: EngineBackend::Symphonia(session),
            anchor_ms: 0,
            frames_from_anchor: 0,
            append_scratch: Vec::new(),
            is_windowed: false,
        })
    }

    /// Returns the decoded stream sample rate in Hz.
    #[inline]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Returns the raw codec sample rate in Hz (e.g., 2.8224 MHz for DSD64 or input rate for Opus).
    #[inline]
    pub fn raw_sample_rate(&self) -> Option<u32> {
        self.raw_sample_rate
    }

    /// Returns the decoded stream channel count.
    #[inline]
    pub fn channels(&self) -> u32 {
        self.channels
    }

    /// Returns the bit depth per sample if defined by the codec/container.
    #[inline]
    pub fn bits_per_sample(&self) -> Option<u32> {
        self.bits_per_sample
    }

    /// Returns the canonical codec identifier (`"MP3"`, `"FLAC"`, `"AAC"`, `"ALAC"`, `"Vorbis"`, `"Opus"`, `"PCM"`, `"DSD"`, `"APE"`, `"WavPack"`).
    #[inline]
    pub fn codec(&self) -> &'static str {
        self.codec
    }

    /// Returns the canonical container format identifier (`"MP3"`, `"FLAC"`, `"Ogg"`, `"MP4"`, `"WAV"`, `"RF64"`, `"RIFX"`, `"W64"`, `"AIFF"`, `"CAF"`, `"Matroska"`, `"WebM"`, `"ADTS"`, `"DSF"`, `"APE"`, `"WavPack"`).
    #[inline]
    pub fn container_format(&self) -> &'static str {
        self.container_format
    }

    /// Maps the detected container/codec format to an extension hint suitable for fast re-probing.
    #[inline]
    pub fn container_hint_ext(&self) -> Option<&'static str> {
        match self.container_format {
            "Matroska" | "WebM" => Some("mkv"),
            "Ogg" => Some("ogg"),
            "FLAC" => Some("flac"),
            "ADTS" => Some("aac"),
            "MP4" => Some("mp4"),
            "MP3" => Some("mp3"),
            "WAV" | "RF64" | "W64" | "BWF" | "RIFX" => Some("wav"),
            "AIFF" => Some("aiff"),
            "CAF" => Some("caf"),
            "APE" => Some("ape"),
            "WavPack" => Some("wv"),
            "DSF" => Some("dsf"),
            _ => match self.codec {
                "MP2" => Some("mp2"),
                "MP3" => Some("mp3"),
                "AAC" => Some("aac"),
                "Opus" | "Vorbis" => Some("ogg"),
                "FLAC" => Some("flac"),
                _ => None,
            },
        }
    }

    /// Returns `true` if the codec is lossless.
    #[inline]
    pub fn lossless(&self) -> bool {
        self.lossless
    }

    /// Returns the total stream duration in milliseconds if known.
    #[inline]
    pub fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

    /// Returns a reference to the metadata/visuals/chapters captured by Symphonia during probing.
    #[inline]
    pub fn symphonia_meta(&self) -> &SymphoniaExtractedMeta {
        &self.symphonia_meta
    }

    /// Returns `true` when the latest `decode_next_frame` EOF resulted from a truncated I/O read
    /// (`UnexpectedEof`) rather than clean logical container/frame termination (`Ok(None)`).
    #[inline]
    pub fn last_eof_was_io_truncation(&self) -> bool {
        match &self.backend {
            EngineBackend::Symphonia(session) => session.last_io_unexpected_eof,
            _ => false,
        }
    }

    /// Returns `true` after the Symphonia demuxer yielded `Ok(None)` (logical EOF).
    #[inline]
    pub fn has_reached_eof(&self) -> bool {
        matches!(&self.backend, EngineBackend::Symphonia(session) if session.reached_eof)
    }

    /// Returns true if the active decoder is a Symphonia ISO-BMFF/MP4/M4A container session.
    #[inline]
    pub fn is_mp4_stream(&self) -> bool {
        matches!(&self.backend, EngineBackend::Symphonia(s) if s.container_format == "MP4")
    }

    /// Decodes the next packet or block into interleaved normalized float PCM samples.
    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        let ok = match &mut self.backend {
            EngineBackend::ExtendedPcm(pcm) => pcm.decode_next_frame(out_pcm)?,
            EngineBackend::Dsf(dsf) => dsf.decode_next_frame(out_pcm)?,
            EngineBackend::Ape(ape) => ape.decode_next_frame(out_pcm)?,
            EngineBackend::WavPack(wv) => wv.decode_next_frame(out_pcm)?,
            EngineBackend::Symphonia(session) => {
                let res = session.decode_next_frame(out_pcm)?;
                self.sample_rate = session.sample_rate;
                self.channels = session.channels;
                res
            }
        };
        if ok && !out_pcm.is_empty() {
            let ch = self.channels.max(1) as usize;
            self.frames_from_anchor += (out_pcm.len() / ch) as u64;
        }
        Ok(ok)
    }

    /// Decodes the next packet or block and appends interleaved normalized float PCM samples to `out_pcm`.
    pub fn decode_next_frame_append(
        &mut self,
        out_pcm: &mut Vec<f32>,
    ) -> Result<bool, SymphoniaError> {
        let before = out_pcm.len();
        let ok = match &mut self.backend {
            EngineBackend::ExtendedPcm(pcm) => pcm.decode_next_frame_append(out_pcm)?,
            EngineBackend::Dsf(dsf) => dsf.decode_next_frame_append(out_pcm)?,
            EngineBackend::Ape(ape) => {
                let res = ape.decode_next_frame(&mut self.append_scratch)?;
                if res {
                    out_pcm.extend_from_slice(&self.append_scratch);
                }
                res
            }
            EngineBackend::WavPack(wv) => {
                let res = wv.decode_next_frame(&mut self.append_scratch)?;
                if res {
                    out_pcm.extend_from_slice(&self.append_scratch);
                }
                res
            }
            EngineBackend::Symphonia(session) => {
                let res = session.decode_next_frame_append(out_pcm)?;
                self.sample_rate = session.sample_rate;
                self.channels = session.channels;
                res
            }
        };
        if ok && out_pcm.len() > before {
            let ch = self.channels.max(1) as usize;
            self.frames_from_anchor += ((out_pcm.len() - before) / ch) as u64;
        }
        Ok(ok)
    }

    /// Returns the estimated decoded playback position in milliseconds based on seeks and decoded PCM frames.
    #[inline]
    pub fn position_ms(&self) -> u64 {
        let sr = self.sample_rate.max(1) as u128;
        self.anchor_ms.saturating_add(
            ((self.frames_from_anchor as u128 * 1000) / sr) as u64,
        )
    }

    /// Seeks the underlying container stream to the specified position in milliseconds.
    pub fn seek_ms(&mut self, position_ms: u64) -> Result<(), SymphoniaError> {
        self.seek_ms_with_actual(position_ms).map(|_| ())
    }

    /// Seeks to `position_ms` and returns the actual keyframe/block start timestamp landed on.
    pub fn seek_ms_with_actual(&mut self, position_ms: u64) -> Result<u64, SymphoniaError> {
        let actual_ms = match &mut self.backend {
            EngineBackend::ExtendedPcm(pcm) => {
                pcm.seek_ms(position_ms)?;
                position_ms
            }
            EngineBackend::Dsf(dsf) => {
                dsf.seek_ms(position_ms)?;
                position_ms
            }
            EngineBackend::Ape(ape) => {
                ape.seek_ms(position_ms)?;
                position_ms
            }
            EngineBackend::WavPack(wv) => {
                wv.seek_ms(position_ms)?;
                wv.current_block_start_ms()
            }
            EngineBackend::Symphonia(session) => session.seek_ms(position_ms)?,
        };
        self.anchor_ms = position_ms;
        self.frames_from_anchor = 0;
        Ok(actual_ms)
    }

    /// Returns true if the active decoder is a Symphonia FLAC container session.
    #[inline]
    pub fn is_flac_stream(&self) -> bool {
        matches!(&self.backend, EngineBackend::Symphonia(s) if s.container_format == "FLAC")
    }

    /// Returns true if the active decoder is a Symphonia Matroska/WebM session.
    #[inline]
    pub fn is_mkv_or_webm(&self) -> bool {
        matches!(
            &self.backend,
            EngineBackend::Symphonia(s) if matches!(s.container_format, "Matroska" | "WebM")
        )
    }

    /// Returns true if the active decoder is a Symphonia Ogg session.
    #[inline]
    pub fn is_ogg_stream(&self) -> bool {
        matches!(&self.backend, EngineBackend::Symphonia(s) if s.container_format == "Ogg")
    }

    /// Returns true if the active decoder is a Symphonia raw ADTS AAC session.
    #[inline]
    pub fn is_adts_stream(&self) -> bool {
        matches!(&self.backend, EngineBackend::Symphonia(s) if s.container_format == "ADTS")
    }

    /// Returns `true` when this engine was opened over a windowed non-seekable mid-stream source.
    #[inline]
    pub fn is_windowed(&self) -> bool {
        self.is_windowed
    }

    /// Returns `true` if the active decoder is a Symphonia MPEG/MP3 session.
    #[inline]
    pub fn is_mp3_stream(&self) -> bool {
        matches!(
            &self.backend,
            EngineBackend::Symphonia(s)
                if s.container_format == "MP3" || matches!(s.codec, "MP3" | "MP2" | "MP1")
        )
    }

    /// Returns true if the active decoder is the native WavPack backend.
    #[inline]
    pub fn is_wavpack_stream(&self) -> bool {
        matches!(&self.backend, EngineBackend::WavPack(_))
    }

    /// Exports APE header seektable anchors when active backend is Monkey's Audio.
    pub fn ape_frame_anchors(&self) -> Option<Vec<(u64, i64)>> {
        match &self.backend {
            EngineBackend::Ape(ape) => Some(ape.frame_anchors()),
            _ => None,
        }
    }

    /// Returns the required byte range `(start, end)` for reading the current APE frame.
    pub fn ape_current_frame_byte_range(&self) -> Option<(u64, u64)> {
        match &self.backend {
            EngineBackend::Ape(ape) => ape.current_frame_byte_range(),
            _ => None,
        }
    }

    /// Injects cached RAM `(sample_index, byte_offset)` checkpoints into `WavpackReader`.
    pub fn inject_wavpack_checkpoints(&mut self, pts: &[(u64, u64)]) {
        if let EngineBackend::WavPack(ref mut wv) = self.backend {
            wv.inject_checkpoints(pts);
        }
    }

    /// Advances demuxed packets without decoding up to `target_stop_ms` (returns last seen ms).
    pub fn advance_to_ms(&mut self, target_stop_ms: u64) -> Option<u64> {
        self.advance_to_ms_cancellable(target_stop_ms, &|| false)
    }

    /// Advances demuxed packets without decoding up to `target_stop_ms`, polling `is_cancelled`
    /// between packets so superseded seeks abort promptly.
    pub fn advance_to_ms_cancellable<F: Fn() -> bool>(
        &mut self,
        target_stop_ms: u64,
        is_cancelled: &F,
    ) -> Option<u64> {
        match &mut self.backend {
            EngineBackend::Symphonia(s) => s.advance_to_ms_cancellable(target_stop_ms, is_cancelled),
            _ => None,
        }
    }

    /// Updates the decoder playback timestamp anchor after external seek adjustments.
    #[inline]
    pub fn set_anchor_ms(&mut self, anchor_ms: u64) {
        self.anchor_ms = anchor_ms;
        self.frames_from_anchor = 0;
    }

    /// Initializes a Symphonia FLAC decoder backed by a memory-resident synthetic `SEEKTABLE`
    /// header (`virtual_head`) followed by `inner` starting past `actual_first_frame`.
    pub fn new_patched_flac<S: MediaSource + 'static>(
        virtual_head: Vec<u8>,
        virtual_delta: u64,
        inner: S,
    ) -> Result<Self, SymphoniaError> {
        let inner_len = inner.byte_len();
        let src = PatchedFlacSource::new(virtual_head, virtual_delta, Box::new(inner), inner_len);
        Self::new_with_options(src, Some("flac"), false)
    }

    fn new_windowed_with_head<S: MediaSource + 'static>(
        virtual_head: Vec<u8>,
        offset: u64,
        inner: S,
        ext_hint: &'static str,
    ) -> Result<Self, SymphoniaError> {
        let src = HeadTailWindowSource::new(virtual_head, offset, Box::new(inner));
        let mut eng = Self::new_with_options(src, Some(ext_hint), false)?;
        eng.is_windowed = true;
        Ok(eng)
    }

    /// Initializes a non-seekable Ogg decoder combining memory-resident Ogg identification/setup
    /// header pages (`header_pages`) directly with `inner` positioned at `page_offset`.
    pub fn new_windowed_ogg<S: MediaSource + 'static>(
        header_pages: Vec<u8>,
        page_offset: u64,
        inner: S,
    ) -> Result<Self, SymphoniaError> {
        Self::new_windowed_with_head(header_pages, page_offset, inner, "ogg")
    }

    /// Initializes a non-seekable Matroska/WebM decoder combining an unknown-size `Segment` header
    /// prefix (`patched_head`) directly with `inner` positioned at `cluster_offset`.
    pub fn new_windowed_mkv<S: MediaSource + 'static>(
        patched_head: Vec<u8>,
        cluster_offset: u64,
        inner: S,
        ext_hint: &'static str,
    ) -> Result<Self, SymphoniaError> {
        Self::new_windowed_with_head(patched_head, cluster_offset, inner, ext_hint)
    }

    /// Initializes a non-seekable raw ADTS AAC decoder directly at verified frame offset `frame_offset`.
    pub fn new_windowed_adts<S: MediaSource + 'static>(
        frame_offset: u64,
        inner: S,
    ) -> Result<Self, SymphoniaError> {
        Self::new_windowed_with_head(Vec::new(), frame_offset, inner, "aac")
    }

    /// Initializes a non-seekable FLAC decoder combining fixed metadata header blocks
    /// (`header_bytes`) directly with `inner` positioned at verified frame offset `frame_offset`.
    pub fn new_windowed_flac<S: MediaSource + 'static>(
        header_bytes: Vec<u8>,
        frame_offset: u64,
        inner: S,
    ) -> Result<Self, SymphoniaError> {
        Self::new_windowed_with_head(header_bytes, frame_offset, inner, "flac")
    }

    /// Initializes a non-seekable MPEG/MP3 decoder directly at verified frame offset `frame_offset`.
    pub fn new_windowed_mp3<S: MediaSource + 'static>(
        frame_offset: u64,
        inner: S,
    ) -> Result<Self, SymphoniaError> {
        Self::new_windowed_with_head(Vec::new(), frame_offset, inner, "mp3")
    }
}

/// Non-seekable composite `MediaSource` sewing a fixed container header prefix directly to
/// a stream offset so Symphonia starts demuxing mid-stream with zero bisection probes.
struct HeadTailWindowSource {
    virtual_head: Vec<u8>,
    pos: u64,
    inner: Box<dyn MediaSource>,
    inner_base: u64,
    inner_synced: bool,
}

impl HeadTailWindowSource {
    fn new(virtual_head: Vec<u8>, inner_base: u64, inner: Box<dyn MediaSource>) -> Self {
        Self {
            virtual_head,
            pos: 0,
            inner,
            inner_base,
            inner_synced: false,
        }
    }
}

impl std::io::Read for HeadTailWindowSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let head_len = self.virtual_head.len() as u64;
        if self.pos < head_len {
            let off = self.pos as usize;
            let avail = self.virtual_head.len() - off;
            let n = avail.min(buf.len());
            buf[..n].copy_from_slice(&self.virtual_head[off..off + n]);
            self.pos += n as u64;
            return Ok(n);
        }
        if !self.inner_synced {
            let rel = self.pos.saturating_sub(head_len);
            self.inner
                .seek(std::io::SeekFrom::Start(self.inner_base.saturating_add(rel)))?;
            self.inner_synced = true;
        }
        let n = self.inner.read(buf)?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl std::io::Seek for HeadTailWindowSource {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        if matches!(pos, std::io::SeekFrom::Current(0)) {
            return Ok(self.pos);
        }
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "HeadTailWindowSource is non-seekable",
        ))
    }
}

impl MediaSource for HeadTailWindowSource {
    fn is_seekable(&self) -> bool {
        false
    }

    fn byte_len(&self) -> Option<u64> {
        None
    }
}

struct PatchedFlacSource {
    virtual_head: Vec<u8>,
    delta: u64,
    pos: u64,
    inner: Box<dyn MediaSource>,
    inner_synced: bool,
    total_virtual_len: Option<u64>,
}

impl PatchedFlacSource {
    fn new(
        virtual_head: Vec<u8>,
        delta: u64,
        inner: Box<dyn MediaSource>,
        inner_len: Option<u64>,
    ) -> Self {
        Self {
            virtual_head,
            delta,
            pos: 0,
            inner,
            inner_synced: false,
            total_virtual_len: inner_len.map(|n| n.saturating_add(delta)),
        }
    }

    #[inline]
    fn effective_total_len(&self) -> Option<u64> {
        self.total_virtual_len
            .or_else(|| self.inner.byte_len().map(|n| n.saturating_add(self.delta)))
    }
}

impl std::io::Read for PatchedFlacSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let head_len = self.virtual_head.len() as u64;
        if self.pos < head_len {
            let off = self.pos as usize;
            let avail = self.virtual_head.len() - off;
            let n = avail.min(buf.len());
            buf[..n].copy_from_slice(&self.virtual_head[off..off + n]);
            self.pos += n as u64;
            return Ok(n);
        }
        let real_pos = self.pos.saturating_sub(self.delta);
        if !self.inner_synced {
            self.inner.seek(std::io::SeekFrom::Start(real_pos))?;
            self.inner_synced = true;
        }
        let n = self.inner.read(buf)?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl std::io::Seek for PatchedFlacSource {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        let next = match pos {
            std::io::SeekFrom::Start(p) => p,
            std::io::SeekFrom::Current(d) => (self.pos as i64).saturating_add(d).max(0) as u64,
            std::io::SeekFrom::End(d) => {
                let len = self.effective_total_len().ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::Unsupported,
                        "PatchedFlacSource missing byte_len for SeekFrom::End",
                    )
                })?;
                (len as i64).saturating_add(d).max(0) as u64
            }
        };
        self.pos = next;
        let head_len = self.virtual_head.len() as u64;
        if next >= head_len {
            let real_pos = next.saturating_sub(self.delta);
            self.inner.seek(std::io::SeekFrom::Start(real_pos))?;
            self.inner_synced = true;
        } else {
            self.inner_synced = false;
        }
        Ok(next)
    }
}

impl MediaSource for PatchedFlacSource {
    fn is_seekable(&self) -> bool {
        self.inner.is_seekable()
    }

    fn byte_len(&self) -> Option<u64> {
        self.effective_total_len()
    }
}

fn parse_duration_string(s: &str) -> Option<u64> {
    let parts: Vec<&str> = s.split(':').collect();
    let total_secs = match parts.as_slice() {
        [h, m, sec] => {
            let hours: f64 = h.trim().parse().ok()?;
            let mins: f64 = m.trim().parse().ok()?;
            let secs: f64 = sec.trim().parse().ok()?;
            hours * 3600.0 + mins * 60.0 + secs
        }
        [m, sec] => {
            let mins: f64 = m.trim().parse().ok()?;
            let secs: f64 = sec.trim().parse().ok()?;
            mins * 60.0 + secs
        }
        [sec] => sec.trim().parse().ok()?,
        _ => return None,
    };
    Some((total_secs * 1000.0).max(0.0) as u64)
}
