//! Pure-Rust SIMD-accelerated AAC / HE-AAC v1 (SBR) / HE-AAC v2 (SBR+PS) Symphonia decoder adapter
//! powered by `rusty_aac`.

use rusty_aac::{config as aac_config, AacDecoder as InnerAacDecoder, Error as AacError};
use symphonia::core::audio::{
    AsGenericAudioBufferRef, Audio, AudioBuffer, AudioMut, AudioSpec, Channels,
    GenericAudioBufferRef, Position,
};
use symphonia::core::codecs::audio::{
    well_known::{
        profiles::{
            CODEC_PROFILE_AAC_HE, CODEC_PROFILE_AAC_HE_V2, CODEC_PROFILE_AAC_LC,
            CODEC_PROFILE_AAC_LTP, CODEC_PROFILE_AAC_MAIN,
        },
        CODEC_ID_AAC,
    },
    AudioCodecParameters, AudioDecoder, AudioDecoderOptions, FinalizeResult,
};
use symphonia::core::codecs::registry::{RegisterableAudioDecoder, SupportedAudioCodec};
use symphonia::core::codecs::{CodecInfo, CodecProfileInfo};
use symphonia::core::errors::{decode_error, unsupported_error, Error, Result};
use symphonia::core::packet::PacketRef;

const AAC_PROFILES: &[CodecProfileInfo] = &[
    CodecProfileInfo {
        profile: CODEC_PROFILE_AAC_LC,
        short_name: "aac-lc",
        long_name: "AAC Low Complexity",
    },
    CodecProfileInfo {
        profile: CODEC_PROFILE_AAC_HE,
        short_name: "he-aac-v1",
        long_name: "High-Efficiency AAC v1 (SBR)",
    },
    CodecProfileInfo {
        profile: CODEC_PROFILE_AAC_HE_V2,
        short_name: "he-aac-v2",
        long_name: "High-Efficiency AAC v2 (SBR + PS)",
    },
    CodecProfileInfo {
        profile: CODEC_PROFILE_AAC_MAIN,
        short_name: "aac-main",
        long_name: "AAC Main",
    },
    CodecProfileInfo {
        profile: CODEC_PROFILE_AAC_LTP,
        short_name: "aac-ltp",
        long_name: "AAC Long Term Prediction",
    },
];

const AAC_CODEC_INFO: CodecInfo = CodecInfo {
    short_name: "aac",
    long_name: "Advanced Audio Coding (Pure-Rust AAC-LC / HE-AAC v1 / HE-AAC v2)",
    profiles: AAC_PROFILES,
};

const SUPPORTED_AAC_CODECS: [SupportedAudioCodec; 1] = [SupportedAudioCodec {
    id: CODEC_ID_AAC,
    info: AAC_CODEC_INFO,
}];

fn map_aac_channels(num_channels: usize) -> Option<Channels> {
    let mask = match num_channels {
        1 => Position::FRONT_CENTER,
        2 => Position::FRONT_LEFT | Position::FRONT_RIGHT,
        3 => Position::FRONT_CENTER | Position::FRONT_LEFT | Position::FRONT_RIGHT,
        4 => {
            Position::FRONT_CENTER
                | Position::FRONT_LEFT
                | Position::FRONT_RIGHT
                | Position::REAR_CENTER
        }
        5 => {
            Position::FRONT_CENTER
                | Position::FRONT_LEFT
                | Position::FRONT_RIGHT
                | Position::REAR_LEFT
                | Position::REAR_RIGHT
        }
        6 => {
            Position::FRONT_CENTER
                | Position::FRONT_LEFT
                | Position::FRONT_RIGHT
                | Position::REAR_LEFT
                | Position::REAR_RIGHT
                | Position::LFE1
        }
        7 => {
            Position::FRONT_CENTER
                | Position::FRONT_LEFT
                | Position::FRONT_RIGHT
                | Position::SIDE_LEFT
                | Position::SIDE_RIGHT
                | Position::REAR_CENTER
                | Position::LFE1
        }
        8 => {
            Position::FRONT_CENTER
                | Position::FRONT_LEFT
                | Position::FRONT_RIGHT
                | Position::SIDE_LEFT
                | Position::SIDE_RIGHT
                | Position::REAR_LEFT
                | Position::REAR_RIGHT
                | Position::LFE1
        }
        _ => return None,
    };
    Some(Channels::Positioned(mask))
}

fn build_inner_decoder(
    extra_data: Option<&[u8]>,
    fallback_sr: Option<u32>,
    fallback_ch: Option<&Channels>,
) -> Result<(InnerAacDecoder, u32, usize)> {
    if let Some(asc) = extra_data.filter(|b| !b.is_empty()) {
        if let Ok(stream) = aac_config::parse(asc) {
            let dec = InnerAacDecoder::with_stream_config(stream.clone());
            let out_sr = dec
                .output_sample_rate()
                .filter(|&r| r > 0)
                .unwrap_or_else(|| fallback_sr.unwrap_or(44100));
            let base_ch = stream.channels();
            let out_ch = if stream.ps && base_ch == 1 {
                2
            } else if base_ch > 0 {
                base_ch
            } else {
                fallback_ch.map(|c| c.count()).unwrap_or(2)
            };
            return Ok((dec, out_sr, out_ch));
        }
        return Err(Error::DecodeError("aac: invalid AudioSpecificConfig"));
    }

    let init_sr = fallback_sr.unwrap_or(44100);
    let init_ch = fallback_ch.map(|c| c.count()).unwrap_or(2);
    let dec = if fallback_sr.is_some() || fallback_ch.is_some() {
        InnerAacDecoder::with_config(rusty_aac::AudioSpecificConfig {
            object_type: 2,
            sample_rate: init_sr,
            channels: init_ch as u16,
        })
    } else {
        InnerAacDecoder::new()
    };
    Ok((dec, init_sr, init_ch))
}

/// Pure-Rust AAC / HE-AAC v1 / HE-AAC v2 decoder implementing Symphonia's [`AudioDecoder`].
pub struct RustyAacDecoder {
    params: AudioCodecParameters,
    inner: InnerAacDecoder,
    buf: AudioBuffer<f32>,
    extra_data: Option<Box<[u8]>>,
}

impl RustyAacDecoder {
    /// Instantiates a new [`RustyAacDecoder`] from the given [`AudioCodecParameters`].
    pub fn try_new(params: &AudioCodecParameters, _options: &AudioDecoderOptions) -> Result<Self> {
        if params.codec != CODEC_ID_AAC {
            return unsupported_error("aac: invalid codec id");
        }

        let extra_data = params.extra_data.clone();
        let (inner, init_sr, init_ch) = build_inner_decoder(
            extra_data.as_deref(),
            params.sample_rate,
            params.channels.as_ref(),
        )?;

        let channels = map_aac_channels(init_ch)
            .ok_or(Error::Unsupported("aac: unsupported channel count"))?;

        let mut updated_params = params.clone();
        updated_params
            .with_sample_rate(init_sr)
            .with_channels(channels.clone());

        let spec = AudioSpec::new(init_sr, channels);
        let buf = AudioBuffer::new(spec, 4096);

        Ok(Self {
            params: updated_params,
            inner,
            buf,
            extra_data,
        })
    }

    fn decode_inner(&mut self, packet: &PacketRef<'_>) -> Result<()> {
        let decoded = match self.inner.decode(packet.data, None) {
            Ok(d) => d,
            Err(AacError::Again) => {
                self.buf.clear();
                return Ok(());
            }
            Err(_) => return decode_error("aac: frame decode failed"),
        };

        let actual_sr = decoded.sample_rate;
        let actual_ch = decoded.channels as usize;
        if actual_sr == 0 || actual_ch == 0 {
            self.buf.clear();
            return Ok(());
        }

        let frames = decoded.frames();

        if self.buf.spec().rate() != actual_sr
            || self.buf.spec().channels().count() != actual_ch
            || self.buf.capacity() < frames
        {
            let ch_map = map_aac_channels(actual_ch)
                .ok_or(Error::Unsupported("aac: unsupported decoded channel count"))?;
            self.params
                .with_sample_rate(actual_sr)
                .with_channels(ch_map.clone());
            let new_spec = AudioSpec::new(actual_sr, ch_map);
            self.buf = AudioBuffer::new(new_spec, frames.max(4096));
        }

        self.buf.clear();
        if frames > 0 {
            self.buf.render_uninit(Some(frames));
            let slice = &decoded.samples[..frames * actual_ch];
            self.buf.copy_from_slice_interleaved(&slice);
            let trim_start = (packet.trim_start.get() as usize).min(frames);
            let trim_end = (packet.trim_end.get() as usize).min(frames.saturating_sub(trim_start));
            if trim_start > 0 || trim_end > 0 {
                self.buf.trim(trim_start, trim_end);
            }
        }
        Ok(())
    }
}

impl AudioDecoder for RustyAacDecoder {
    fn reset(&mut self) {
        if let Ok((inner, _, _)) = build_inner_decoder(
            self.extra_data.as_deref(),
            self.params.sample_rate,
            self.params.channels.as_ref(),
        ) {
            self.inner = inner;
        } else {
            self.inner = InnerAacDecoder::new();
        }
        self.buf.clear();
    }

    fn codec_info(&self) -> &CodecInfo {
        &AAC_CODEC_INFO
    }

    fn codec_params(&self) -> &AudioCodecParameters {
        &self.params
    }

    fn decode_ref(&mut self, packet: &PacketRef<'_>) -> Result<GenericAudioBufferRef<'_>> {
        if let Err(e) = self.decode_inner(packet) {
            self.buf.clear();
            return Err(e);
        }
        Ok(self.buf.as_generic_audio_buffer_ref())
    }

    fn finalize(&mut self) -> FinalizeResult {
        Default::default()
    }

    fn last_decoded(&self) -> GenericAudioBufferRef<'_> {
        self.buf.as_generic_audio_buffer_ref()
    }
}

impl RegisterableAudioDecoder for RustyAacDecoder {
    fn try_registry_new(
        params: &AudioCodecParameters,
        opts: &AudioDecoderOptions,
    ) -> Result<Box<dyn AudioDecoder>>
    where
        Self: Sized,
    {
        Ok(Box::new(RustyAacDecoder::try_new(params, opts)?))
    }

    fn supported_codecs() -> &'static [SupportedAudioCodec] {
        &SUPPORTED_AAC_CODECS
    }
}
