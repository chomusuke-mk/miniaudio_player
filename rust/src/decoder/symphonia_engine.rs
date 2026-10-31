use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions, CODEC_ID_NULL_AUDIO};
use symphonia::core::codecs::registry::CodecRegistry;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::Time;
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

enum EngineBackend {
    Symphonia {
        format_reader: Box<dyn FormatReader>,
        decoder: Box<dyn AudioDecoder>,
        track_id: u32,
    },
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

        // 1. Try Extended PCM first (RF64, RIFX, W64)
        let boxed_source = match ExtendedPcmReader::try_new(boxed_source)? {
            ExtendedPcmProbe::Matched(pcm) => {
                let sample_rate = pcm.sample_rate();
                let channels = pcm.channels();
                let duration_ms = pcm.duration_ms();
                return Ok(Self {
                    backend: EngineBackend::ExtendedPcm(pcm),
                    sample_rate,
                    channels,
                    duration_ms,
                });
            }
            ExtendedPcmProbe::NotMatched(src) => src,
        };

        // 2. Try DSD (.dsf)
        let boxed_source = match DsfReader::try_new(boxed_source)? {
            DsfProbe::Matched(dsf) => {
                let sample_rate = dsf.sample_rate();
                let channels = dsf.channels();
                let duration_ms = dsf.duration_ms();
                return Ok(Self {
                    backend: EngineBackend::Dsf(dsf),
                    sample_rate,
                    channels,
                    duration_ms,
                });
            }
            DsfProbe::NotMatched(src) => src,
        };

        // 3. Try Monkey's Audio (.ape)
        let boxed_source = match ApeReader::try_new(boxed_source)? {
            ApeProbe::Matched(ape) => {
                let sample_rate = ape.sample_rate();
                let channels = ape.channels();
                let duration_ms = ape.duration_ms();
                return Ok(Self {
                    backend: EngineBackend::Ape(ape),
                    sample_rate,
                    channels,
                    duration_ms,
                });
            }
            ApeProbe::NotMatched(src) => src,
        };

        // 4. Try WavPack (.wv)
        let boxed_source = match WavpackReader::try_new(boxed_source)? {
            WavpackProbe::Matched(wv) => {
                let sample_rate = wv.sample_rate();
                let channels = wv.channels();
                let duration_ms = wv.duration_ms();
                return Ok(Self {
                    backend: EngineBackend::WavPack(wv),
                    sample_rate,
                    channels,
                    duration_ms,
                });
            }
            WavpackProbe::NotMatched(src) => src,
        };

        // 5. Symphonia default probe (MP3, AAC, FLAC, Ogg, WAV, MP4, WebM/MKV)
        let mut hint = Hint::new();
        if let Some(ext) = hint_extension {
            hint.with_extension(ext);
        }

        let mss = MediaSourceStream::new(
            boxed_source,
            MediaSourceStreamOptions::default(),
        );

                let mut format_reader = symphonia::default::get_probe().probe(
                    &hint,
                    mss,
                    FormatOptions::default(),
                    MetadataOptions::default(),
                )?;

                // Buscar la primera pista de audio válida
                let (track_id, audio_params, track_time_base, track_duration, track_num_frames) = {
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
                        .ok_or_else(|| SymphoniaError::Unsupported("no supported audio track found"))?;

                    let params = track
                        .codec_params
                        .as_ref()
                        .and_then(|p| p.audio())
                        .ok_or_else(|| SymphoniaError::Unsupported("audio track parameters missing"))?
                        .clone();

                    (track.id, params, track.time_base, track.duration, track.num_frames)
                };

                let sample_rate = audio_params.sample_rate.unwrap_or(0);
                if sample_rate == 0 {
                    return Err(SymphoniaError::Unsupported("invalid sample rate: 0"));
                }
                let channels = audio_params
                    .channels
                    .as_ref()
                    .map(|c| c.count() as u32)
                    .unwrap_or(0);
                if channels == 0 || channels > 32 {
                    return Err(SymphoniaError::Unsupported("invalid channel count"));
                }
                if let Some(bps) = audio_params.bits_per_sample {
                    if bps == 0 {
                        return Err(SymphoniaError::Unsupported("invalid bits per sample: 0"));
                    }
                }

                // Calcular duración aproximada si está disponible
                let mut duration_ms = if let (Some(tb), Some(dur)) = (track_time_base, track_duration) {
                    tb.calc_duration(dur).map(|t| t.as_millis().max(0) as u64)
                } else if let (Some(tb), Some(n_frames)) = (track_time_base, track_num_frames) {
                    tb.calc_duration(symphonia::core::units::Duration::new(n_frames))
                        .map(|t| t.as_millis().max(0) as u64)
                } else {
                    None
                };

                if duration_ms.is_none() {
                    if let Some(rev) = format_reader.metadata().current() {
                        for track in &rev.per_track {
                            for tag in &track.metadata.tags {
                                if tag.raw.key.to_uppercase().contains("DURATION") {
                                    if let symphonia::core::meta::RawValue::String(ref s) = tag.raw.value {
                                        if let Some(ms) = parse_duration_string(s) {
                                            duration_ms = Some(ms);
                                            break;
                                        }
                                    }
                                }
                            }
                            if duration_ms.is_some() {
                                break;
                            }
                        }
                        if duration_ms.is_none() {
                            for tag in &rev.media.tags {
                                if tag.raw.key.to_uppercase().contains("DURATION") {
                                    if let symphonia::core::meta::RawValue::String(ref s) = tag.raw.value {
                                        if let Some(ms) = parse_duration_string(s) {
                                            duration_ms = Some(ms);
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                let codec_registry = create_codec_registry();
                let decoder = codec_registry.make_audio_decoder(
                    &audio_params,
                    &AudioDecoderOptions::default(),
                )?;

                Ok(Self {
                    backend: EngineBackend::Symphonia {
                        format_reader,
                        decoder,
                        track_id,
                    },
                    sample_rate,
                    channels,
                    duration_ms,
                })
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> u32 {
        self.channels
    }

    pub fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

    /// Lee el siguiente paquete del contenedor y decodifica a muestras f32 entrelazadas.
    /// Retorna `Ok(true)` si se decodificaron muestras, `Ok(false)` si se alcanzó EOF.
    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        match &mut self.backend {
            EngineBackend::ExtendedPcm(pcm) => pcm.decode_next_frame(out_pcm),
            EngineBackend::Dsf(dsf) => dsf.decode_next_frame(out_pcm),
            EngineBackend::Ape(ape) => ape.decode_next_frame(out_pcm),
            EngineBackend::WavPack(wv) => wv.decode_next_frame(out_pcm),
            EngineBackend::Symphonia {
                format_reader,
                decoder,
                track_id,
            } => {
                loop {
                    let packet = match format_reader.next_packet() {
                        Ok(Some(packet)) => packet,
                        Ok(None) => return Ok(false), // Fin de archivo / contenedor (EOF)
                        Err(SymphoniaError::IoError(ref err))
                            if err.kind() == std::io::ErrorKind::UnexpectedEof =>
                        {
                            return Ok(false);
                        }
                        Err(err) => return Err(err),
                    };

                    // Descartar paquetes de otras pistas
                    if packet.track_id != *track_id {
                        continue;
                    }

                    match decoder.decode(&packet) {
                        Ok(decoded) => {
                            let rate = decoded.spec().rate();
                            let channels = decoded.spec().channels().count() as u32;
                            if rate > 0 && rate != self.sample_rate {
                                self.sample_rate = rate;
                            }
                            if channels > 0 && channels != self.channels {
                                self.channels = channels;
                            }
                            out_pcm.clear();
                            decoded.copy_to_vec_interleaved(out_pcm);
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
        }
    }

    /// Realiza un seek a la posición en milisegundos especificada
    pub fn seek_ms(&mut self, position_ms: u64) -> Result<(), SymphoniaError> {
        match &mut self.backend {
            EngineBackend::ExtendedPcm(pcm) => pcm.seek_ms(position_ms),
            EngineBackend::Dsf(dsf) => dsf.seek_ms(position_ms),
            EngineBackend::Ape(ape) => ape.seek_ms(position_ms),
            EngineBackend::WavPack(wv) => wv.seek_ms(position_ms),
            EngineBackend::Symphonia {
                format_reader,
                decoder,
                track_id,
            } => {
                let time = Time::from_millis_u64(position_ms);

                let res = format_reader.seek(
                    SeekMode::Coarse,
                    SeekTo::Time {
                        time,
                        track_id: Some(*track_id),
                    },
                );

                if res.is_err() && position_ms == 0 {
                    let _ = format_reader.seek(
                        SeekMode::Coarse,
                        SeekTo::Timestamp {
                            ts: symphonia::core::units::Timestamp::default(),
                            track_id: *track_id,
                        },
                    );
                } else {
                    res?;
                }

                decoder.reset();
                Ok(())
            }
        }
    }
}

fn parse_duration_string(s: &str) -> Option<u64> {
    let parts: Vec<&str> = s.split(':').collect();
    if parts.len() == 3 {
        let hours: f64 = parts[0].trim().parse().ok()?;
        let mins: f64 = parts[1].trim().parse().ok()?;
        let secs: f64 = parts[2].trim().parse().ok()?;
        let total_ms = (hours * 3600.0 + mins * 60.0 + secs) * 1000.0;
        Some(total_ms.max(0.0) as u64)
    } else if parts.len() == 2 {
        let mins: f64 = parts[0].trim().parse().ok()?;
        let secs: f64 = parts[1].trim().parse().ok()?;
        let total_ms = (mins * 60.0 + secs) * 1000.0;
        Some(total_ms.max(0.0) as u64)
    } else if parts.len() == 1 {
        let secs: f64 = parts[0].trim().parse().ok()?;
        Some((secs * 1000.0).max(0.0) as u64)
    } else {
        None
    }
}
