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
#[cfg(not(target_arch = "wasm32"))]
use symphonia_adapter_libopus::OpusDecoder;

use super::ape::{ApeProbe, ApeReader};
use super::dsf::{DsfProbe, DsfReader};
use super::extended_pcm::{ExtendedPcmProbe, ExtendedPcmReader};
use super::wavpack::{WavpackProbe, WavpackReader};
use crate::metadata::SymphoniaExtractedMeta;

/// Constructs a Symphonia `CodecRegistry` preloaded with standard codecs and external Opus/AAC adapters.
pub fn create_codec_registry() -> CodecRegistry {
    let mut registry = CodecRegistry::new();
    symphonia::default::register_enabled_codecs(&mut registry);
    #[cfg(not(target_arch = "wasm32"))]
    {
        registry.register_audio_decoder::<OpusDecoder>();
        registry.register_audio_decoder::<symphonia_adapter_fdk_aac::AacDecoder>();
    }
    registry
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

        let duration_ms = Self::compute_duration_ms(time_base, duration, num_frames)
            .or_else(|| Self::extract_metadata_duration_ms(&mut *format_reader));
        let symphonia_meta = SymphoniaExtractedMeta::from_format_reader(&mut *format_reader);

        let decoder = create_codec_registry()
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
        loop {
            let packet = match self.format_reader.next_packet() {
                Ok(Some(pkt)) => pkt,
                Ok(None) => return Ok(false),
                Err(SymphoniaError::IoError(ref err))
                    if err.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
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
                    out_pcm.clear();
                    decoded.copy_to_vec_interleaved(out_pcm);
                    if out_pcm.is_empty() {
                        continue;
                    }
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

    fn seek_ms(&mut self, position_ms: u64) -> Result<(), SymphoniaError> {
        let time = Time::from_millis_u64(position_ms);
        let res = self.format_reader.seek(
            SeekMode::Coarse,
            SeekTo::Time {
                time,
                track_id: Some(self.track_id),
            },
        );

        if res.is_err() && position_ms == 0 {
            let _ = self.format_reader.seek(
                SeekMode::Coarse,
                SeekTo::Timestamp {
                    ts: Timestamp::default(),
                    track_id: self.track_id,
                },
            );
        } else {
            res?;
        }

        self.decoder.reset();
        Ok(())
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
}

impl SymphoniaEngine {
    /// Probes and instantiates the appropriate format reader and decoder for `source`.
    pub fn new<M: MediaSource + 'static>(
        source: M,
        hint_extension: Option<&str>,
    ) -> Result<Self, SymphoniaError> {
        let boxed_source: Box<dyn MediaSource> = Box::new(source);

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
                });
            }
            WavpackProbe::NotMatched(src) => src,
        };

        let adts_info = if boxed_source.is_seekable() {
            crate::decoder::classifier::StreamClassifier::scan_adts_stream(&mut boxed_source)
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

    /// Decodes the next packet or block into interleaved normalized float PCM samples.
    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        match &mut self.backend {
            EngineBackend::ExtendedPcm(pcm) => pcm.decode_next_frame(out_pcm),
            EngineBackend::Dsf(dsf) => dsf.decode_next_frame(out_pcm),
            EngineBackend::Ape(ape) => ape.decode_next_frame(out_pcm),
            EngineBackend::WavPack(wv) => wv.decode_next_frame(out_pcm),
            EngineBackend::Symphonia(session) => {
                let res = session.decode_next_frame(out_pcm)?;
                self.sample_rate = session.sample_rate;
                self.channels = session.channels;
                Ok(res)
            }
        }
    }

    /// Seeks the underlying container stream to the specified position in milliseconds.
    pub fn seek_ms(&mut self, position_ms: u64) -> Result<(), SymphoniaError> {
        match &mut self.backend {
            EngineBackend::ExtendedPcm(pcm) => pcm.seek_ms(position_ms),
            EngineBackend::Dsf(dsf) => dsf.seek_ms(position_ms),
            EngineBackend::Ape(ape) => ape.seek_ms(position_ms),
            EngineBackend::WavPack(wv) => wv.seek_ms(position_ms),
            EngineBackend::Symphonia(session) => session.seek_ms(position_ms),
        }
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
