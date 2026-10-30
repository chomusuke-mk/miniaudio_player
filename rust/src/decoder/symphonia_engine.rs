use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions, CODEC_ID_NULL_AUDIO};
use symphonia::core::codecs::registry::CodecRegistry;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::Time;
use symphonia_adapter_oporus::OpusDecoder;

use super::extended_pcm::{ExtendedPcmProbe, ExtendedPcmReader};

pub fn create_codec_registry() -> CodecRegistry {
    let mut registry = CodecRegistry::new();
    symphonia::default::register_enabled_codecs(&mut registry);
    registry.register_audio_decoder::<OpusDecoder>();
    registry
}

enum EngineBackend {
    Symphonia {
        format_reader: Box<dyn FormatReader>,
        decoder: Box<dyn AudioDecoder>,
        track_id: u32,
    },
    ExtendedPcm(ExtendedPcmReader),
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

        // Try Extended PCM first (RF64, RIFX, W64)
        match ExtendedPcmReader::try_new(boxed_source)? {
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
            ExtendedPcmProbe::NotMatched(src) => {
                let mut hint = Hint::new();
                if let Some(ext) = hint_extension {
                    hint.with_extension(ext);
                }

                let mss = MediaSourceStream::new(
                    src,
                    MediaSourceStreamOptions::default(),
                );

                let format_reader = symphonia::default::get_probe().probe(
                    &hint,
                    mss,
                    FormatOptions::default(),
                    MetadataOptions::default(),
                )?;

                // WebM and Matroska containers are not supported by miniaudio_player specification
                let short_name = format_reader.format_info().short_name;
                if short_name == "matroska" || short_name == "mkv" || short_name == "webm" {
                    return Err(SymphoniaError::Unsupported("WebM/MKV is not supported"));
                }

                // Buscar la primera pista de audio válida
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

                let track_id = track.id;
                let audio_params = track
                    .codec_params
                    .as_ref()
                    .and_then(|p| p.audio())
                    .ok_or_else(|| SymphoniaError::Unsupported("audio track parameters missing"))?;

                let sample_rate = audio_params.sample_rate.unwrap_or(44100);
                let channels = audio_params
                    .channels
                    .as_ref()
                    .map(|c| c.count() as u32)
                    .unwrap_or(2);

                // Calcular duración aproximada si está disponible
                let duration_ms = if let (Some(tb), Some(dur)) = (track.time_base, track.duration) {
                    tb.calc_duration(dur).map(|t| t.as_millis().max(0) as u64)
                } else if let (Some(tb), Some(n_frames)) = (track.time_base, track.num_frames) {
                    tb.calc_duration(symphonia::core::units::Duration::new(n_frames))
                        .map(|t| t.as_millis().max(0) as u64)
                } else {
                    None
                };

                let codec_registry = create_codec_registry();
                let decoder = codec_registry.make_audio_decoder(
                    audio_params,
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
        }
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
