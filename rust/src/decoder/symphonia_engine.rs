//! Unified Audio Decoder Facade & Probing Pipeline.
//!
//! Orchestrates format detection across `ExtendedPcmReader`, `DsfReader`, `ApeReader`,
//! `WavpackReader`, and Symphonia container/codec readers via a clean black-box interface.

use symphonia::core::codecs::audio::{
    AudioCodecParameters, AudioDecoder, AudioDecoderOptions, CODEC_ID_NULL_AUDIO,
};
use symphonia::core::codecs::registry::CodecRegistry;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::{MetadataOptions, RawTag, RawValue};
use symphonia::core::units::{Duration as SymphoniaDuration, Time, TimeBase, Timestamp};
use symphonia_adapter_libopus::OpusDecoder;

use super::ape::{ApeProbe, ApeReader};
use super::dsf::{DsfProbe, DsfReader};
use super::extended_pcm::{ExtendedPcmProbe, ExtendedPcmReader};
use super::wavpack::{WavpackProbe, WavpackReader};

pub fn create_codec_registry() -> CodecRegistry {
    let mut registry = CodecRegistry::new();
    symphonia::default::register_enabled_codecs(&mut registry);
    registry.register_audio_decoder::<OpusDecoder>();
    registry.register_audio_decoder::<symphonia_adapter_fdk_aac::AacDecoder>();
    registry
}

/// Encapsulates Symphonia container reading, packet filtering, and audio frame decoding.
struct SymphoniaTrackSession {
    format_reader: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
    track_id: u32,
    sample_rate: u32,
    channels: u32,
    duration_ms: Option<u64>,
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

        let (sample_rate, channels) = Self::validate_audio_params(&audio_params)?;
        let duration_ms = Self::compute_duration_ms(time_base, duration, num_frames)
            .or_else(|| Self::extract_metadata_duration_ms(&mut *format_reader));

        let decoder = create_codec_registry()
            .make_audio_decoder(&audio_params, &AudioDecoderOptions::default())?;

        Ok(Self {
            format_reader,
            decoder,
            track_id,
            sample_rate,
            channels,
            duration_ms,
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
            .ok_or(SymphoniaError::Unsupported("no supported audio track found"))?;

        let params = track
            .codec_params
            .as_ref()
            .and_then(|p| p.audio())
            .ok_or(SymphoniaError::Unsupported("audio track parameters missing"))?
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

pub struct SymphoniaEngine {
    backend: EngineBackend,
    sample_rate: u32,
    channels: u32,
    duration_ms: Option<u64>,
}

impl SymphoniaEngine {
    pub fn new<M: MediaSource + 'static>(
        source: M,
        hint_extension: Option<&str>,
    ) -> Result<Self, SymphoniaError> {
        let boxed_source: Box<dyn MediaSource> = Box::new(source);

        let boxed_source = match ExtendedPcmReader::try_new(boxed_source)? {
            ExtendedPcmProbe::Matched(pcm) => {
                return Ok(Self {
                    sample_rate: pcm.sample_rate(),
                    channels: pcm.channels(),
                    duration_ms: pcm.duration_ms(),
                    backend: EngineBackend::ExtendedPcm(pcm),
                });
            }
            ExtendedPcmProbe::NotMatched(src) => src,
        };

        let boxed_source = match DsfReader::try_new(boxed_source)? {
            DsfProbe::Matched(dsf) => {
                return Ok(Self {
                    sample_rate: dsf.sample_rate(),
                    channels: dsf.channels(),
                    duration_ms: dsf.duration_ms(),
                    backend: EngineBackend::Dsf(dsf),
                });
            }
            DsfProbe::NotMatched(src) => src,
        };

        let boxed_source = match ApeReader::try_new(boxed_source)? {
            ApeProbe::Matched(ape) => {
                return Ok(Self {
                    sample_rate: ape.sample_rate(),
                    channels: ape.channels(),
                    duration_ms: ape.duration_ms(),
                    backend: EngineBackend::Ape(ape),
                });
            }
            ApeProbe::NotMatched(src) => src,
        };

        let boxed_source = match WavpackReader::try_new(boxed_source)? {
            WavpackProbe::Matched(wv) => {
                return Ok(Self {
                    sample_rate: wv.sample_rate(),
                    channels: wv.channels(),
                    duration_ms: wv.duration_ms(),
                    backend: EngineBackend::WavPack(wv),
                });
            }
            WavpackProbe::NotMatched(src) => src,
        };

        let session = SymphoniaTrackSession::open(boxed_source, hint_extension)?;
        Ok(Self {
            sample_rate: session.sample_rate,
            channels: session.channels,
            duration_ms: session.duration_ms,
            backend: EngineBackend::Symphonia(session),
        })
    }

    #[inline]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    #[inline]
    pub fn channels(&self) -> u32 {
        self.channels
    }

    #[inline]
    pub fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

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
