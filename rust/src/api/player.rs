//! High-level Rust Player API exposed to Flutter/Dart via flutter_rust_bridge.

use std::ffi::CString;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use crate::{STATE_COMPLETED, STATE_ERROR, STATE_PLAYING};
use crate::bridge::ffi::{
    map_device_enumerate_devices, map_device_free_devices, MapDeviceInfo, MiniaudioBufferedRange,
};
use crate::core::player::{MiniaudioPlayerStatus, MiniaudioStreamStatus, PlayerCoordinator};
use crate::dsp::equalizer::{EqualizerParams, ReplayGainConfig};
use crate::dsp::silence::SilenceConfig;
use crate::dsp::visualizer::VisualizerData;
use crate::frb_generated::StreamSink;
use crate::sync::telemetry::{EventType, MapEventData, TelemetryDispatcher};

use super::types::*;

fn c_buf_to_string(buf: &[u8]) -> String {
    let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..len]).to_string()
}

fn map_telemetry_event(event_type: EventType, data: &MapEventData) -> Option<RustPlayerEvent> {
    unsafe {
        match event_type {
            EventType::None => None,
            EventType::State => Some(RustPlayerEvent::State(data.state)),
            EventType::Position => Some(RustPlayerEvent::Position(data.position_ms)),
            EventType::Duration => Some(RustPlayerEvent::Duration(data.duration_ms)),
            EventType::IsPlaying => Some(RustPlayerEvent::IsPlaying(data.is_playing != 0)),
            EventType::IsBuffering => Some(RustPlayerEvent::IsBuffering(data.is_buffering != 0)),
            EventType::IsCompleted => Some(RustPlayerEvent::IsCompleted(data.is_completed != 0)),
            EventType::Volume => Some(RustPlayerEvent::Volume(data.volume)),
            EventType::Rate => Some(RustPlayerEvent::Rate(data.rate)),
            EventType::Pitch => Some(RustPlayerEvent::Pitch(data.pitch)),
            EventType::Bitrate => Some(RustPlayerEvent::Bitrate(data.bitrate)),
            EventType::BufferSize => Some(RustPlayerEvent::BufferSize(data.buffer_size)),
            EventType::Device => {
                let dev = &data.device;
                Some(RustPlayerEvent::Device(RustAudioDevice {
                    id: c_buf_to_string(&dev.id),
                    effective_id: c_buf_to_string(&dev.effective_id),
                    name: c_buf_to_string(&dev.name),
                    is_default: dev.is_default != 0,
                    is_auto: dev.is_auto != 0,
                }))
            }
            EventType::Visualizer => {
                let vis = &data.visualizer;
                Some(RustPlayerEvent::Visualizer(RustVisualizerData {
                    bands: vis.bands.to_vec(),
                    rms: vis.rms,
                    peak: vis.peak,
                    left: vis.left,
                    right: vis.right,
                }))
            }
            EventType::VisualizerEnabled => {
                Some(RustPlayerEvent::VisualizerEnabled(data.visualizer_enabled != 0))
            }
            EventType::BufferedRange => {
                let br = &data.buffered_range;
                Some(RustPlayerEvent::BufferedRange(RustBufferedRange {
                    start_ms: br.start_ms,
                    end_ms: br.end_ms,
                    duration_ms: br.duration_ms,
                    fill_percentage: br.fill_percentage,
                    stream_percentage: br.stream_percentage,
                    is_buffering: br.is_buffering != 0,
                    is_eof: br.is_eof != 0,
                }))
            }
            EventType::SilenceConfig => {
                let sc = &data.silence_config;
                Some(RustPlayerEvent::SilenceConfig(RustSilenceConfig {
                    mode: sc.mode as i32,
                    threshold_db: sc.threshold_db,
                    min_silence_duration_ms: sc.min_silence_duration_ms,
                    padding_ms: sc.padding_ms,
                    enabled: sc.mode != crate::dsp::silence::SilenceMode::Disabled,
                }))
            }
            EventType::SilenceSaved => Some(RustPlayerEvent::SilenceSaved(data.silence_saved_ms)),
            EventType::Equalizer => {
                let eq = &data.equalizer;
                Some(RustPlayerEvent::Equalizer(RustEqualizerParams {
                    gains: vec![
                        eq.hz31, eq.hz63, eq.hz125, eq.hz250, eq.hz500, eq.hz1k, eq.hz2k, eq.hz4k,
                        eq.hz8k, eq.hz16k,
                    ],
                    enabled: true,
                }))
            }
            EventType::Preamp => Some(RustPlayerEvent::Preamp(data.preamp_db)),
            EventType::ReplayGain => {
                let rg = &data.replay_gain;
                Some(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                    gain_db: rg.gain_db,
                    peak: rg.peak,
                    prevent_clipping: rg.prevent_clipping != 0,
                    enabled: rg.enabled != 0,
                }))
            }
            EventType::Balance => Some(RustPlayerEvent::Balance(data.balance)),
            EventType::Mono => Some(RustPlayerEvent::Mono(data.mono_enabled != 0)),
            EventType::Crossfeed => Some(RustPlayerEvent::Crossfeed(data.crossfeed_mode)),
            EventType::Spatializer => {
                let sp = &data.spatializer;
                Some(RustPlayerEvent::Spatializer {
                    enabled: sp.enabled != 0,
                    width: sp.width,
                })
            }
            EventType::Reverb => {
                let rv = &data.reverb;
                Some(RustPlayerEvent::Reverb(RustReverbParams {
                    room_size: rv.room_size,
                    damping: rv.damping,
                    wet: rv.wet,
                    dry: rv.dry,
                    width: rv.width,
                    mode: 0.0,
                    enabled: rv.enabled != 0,
                }))
            }
            EventType::Limiter => Some(RustPlayerEvent::Limiter(data.limiter_enabled != 0)),
            EventType::Error => Some(RustPlayerEvent::Error {
                message: format!("Error code {}", data.error_code),
                code: data.error_code,
            }),
        }
    }
}

pub struct RustPlayer {
    inner: Arc<Mutex<Box<PlayerCoordinator>>>,
    telemetry: Arc<TelemetryDispatcher>,
    raw_ptr: usize,
}

impl RustPlayer {
    #[flutter_rust_bridge::frb(sync)]
    pub fn new(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        playback_device_id: Option<String>,
    ) -> Result<RustPlayer, String> {
        let dev_id_c = playback_device_id.map(|s| CString::new(s).unwrap_or_default());
        let dev_id_ptr = dev_id_c.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

        let coordinator = PlayerCoordinator::new(
            sample_rate,
            channels,
            period_size,
            dev_id_ptr,
            None,
            std::ptr::null_mut(),
        ).map_err(|e| format!("Failed to create player coordinator: error {}", e))?;

        let boxed = coordinator;
        let raw_ref: &PlayerCoordinator = &boxed;
        let raw_ptr = raw_ref as *const PlayerCoordinator as usize;
        let telemetry = boxed.telemetry.clone();

        Ok(RustPlayer {
            inner: Arc::new(Mutex::new(boxed)),
            telemetry,
            raw_ptr,
        })
    }

    pub fn subscribe_events(&self, sink: StreamSink<RustPlayerEvent>) -> Result<(), String> {
        let sink_clone = sink;
        self.telemetry.set_rust_callback(Some(Box::new(move |event_type, data| {
            if let Some(event) = map_telemetry_event(event_type, data) {
                let _ = sink_clone.add(event);
            }
        })));
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_raw_handle(&self) -> usize {
        self.raw_ptr
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_sample_rate(&self) -> u32 {
        let lock = self.inner.lock().unwrap();
        lock.sample_rate.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_channels(&self) -> u32 {
        let lock = self.inner.lock().unwrap();
        lock.channels.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_duration_ms(&self) -> i64 {
        let lock = self.inner.lock().unwrap();
        lock.duration_ms.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_bitrate(&self) -> u32 {
        let lock = self.inner.lock().unwrap();
        lock.bitrate.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_completed(&self) -> bool {
        let lock = self.inner.lock().unwrap();
        lock.state.load(Ordering::Relaxed) == STATE_COMPLETED
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_playing(&self) -> bool {
        let lock = self.inner.lock().unwrap();
        lock.state.load(Ordering::Relaxed) == STATE_PLAYING
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_audio_data_offset(&self) -> i64 {
        let lock = self.inner.lock().unwrap();
        lock.get_audio_data_offset()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_icy_meta(&self, data: Vec<u8>) {
        let mut lock = self.inner.lock().unwrap();
        lock.set_icy_meta(&data);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn probe_tail(&self, tail_bytes: Vec<u8>, tail_offset: i64) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.probe_tail(&tail_bytes, tail_offset);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("probe_tail failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn notify_open_error(&self, error_code: i32) {
        let lock = self.inner.lock().unwrap();
        lock.state.store(STATE_ERROR, Ordering::Relaxed);
        lock.telemetry.post_event(
            EventType::State,
            MapEventData { state: STATE_ERROR },
        );
        lock.telemetry.post_event(
            EventType::Error,
            MapEventData { error_code },
        );
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_pinned_head_size(&self) -> i64 {
        let lock = self.inner.lock().unwrap();
        lock.stream_get_pinned_head_size()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_meta_bytes(&self) -> Option<Vec<u8>> {
        let lock = self.inner.lock().unwrap();
        let size = lock.get_meta_bytes_size();
        if size == 0 {
            return None;
        }
        let mut out = vec![0u8; size];
        let copied = lock.copy_meta_bytes(&mut out);
        if copied > 0 {
            out.truncate(copied);
            Some(out)
        } else {
            None
        }
    }

    pub fn begin_open(&self) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.begin_open();
        if res == 0 {
            Ok(())
        } else {
            Err(format!("begin_open failed: error {}", res))
        }
    }

    pub fn open_file(&self, path: String) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.open_file(&path);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("open_file failed: error {}", res))
        }
    }

    pub fn open_memory(&self, data: Vec<u8>) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.open_memory(&data, false);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("open_memory failed: error {}", res))
        }
    }

    pub fn open_stream_ex(
        &self,
        initial_bytes: Vec<u8>,
        tail_bytes: Option<Vec<u8>>,
        total_bytes: i64,
        is_live: bool,
        buffer_capacity_bytes: usize,
        encoding_format: i32,
    ) -> i32 {
        let mut lock = self.inner.lock().unwrap();
        let tail_slice = tail_bytes.as_deref();
        lock.open_stream_ex(
            &initial_bytes,
            tail_slice,
            total_bytes,
            is_live,
            buffer_capacity_bytes,
            encoding_format,
        )
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stream_feed(&self, data: Vec<u8>) -> i32 {
        let mut lock = self.inner.lock().unwrap();
        lock.stream_feed(&data)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stream_flush(&self, new_stream_offset: i64) -> i32 {
        let mut lock = self.inner.lock().unwrap();
        lock.stream_flush(new_stream_offset)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stream_seek(&self, position_ms: i64, new_stream_offset: i64) -> i32 {
        let mut lock = self.inner.lock().unwrap();
        lock.stream_seek(position_ms, new_stream_offset)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stream_end(&self) -> i32 {
        let mut lock = self.inner.lock().unwrap();
        lock.stream_end()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_stream_status(&self) -> Result<RustStreamStatus, String> {
        let lock = self.inner.lock().unwrap();
        let mut status = MiniaudioStreamStatus::default();
        let res = lock.stream_get_status(&mut status);
        if res == 0 {
            Ok(RustStreamStatus {
                buffer_capacity: status.buffer_capacity,
                buffer_fill: status.buffer_fill,
                fill_percentage: status.fill_percentage,
                is_buffering: status.is_buffering != 0,
                is_eof: status.is_eof != 0,
                read_cursor_byte: status.read_cursor_byte,
                range_start: status.range_start,
                range_end: status.range_end,
            })
        } else {
            Err(format!("stream_get_status failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_buffered_range(&self) -> Result<RustBufferedRange, String> {
        let lock = self.inner.lock().unwrap();
        let mut range = MiniaudioBufferedRange::default();
        let res = lock.get_buffered_range(&mut range);
        if res == 0 {
            Ok(RustBufferedRange {
                start_ms: range.start_ms,
                end_ms: range.end_ms,
                duration_ms: range.duration_ms,
                fill_percentage: range.fill_percentage,
                stream_percentage: range.stream_percentage,
                is_buffering: range.is_buffering != 0,
                is_eof: range.is_eof != 0,
            })
        } else {
            Err(format!("get_buffered_range failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stream_get_seek_byte(&self, position_ms: i64) -> i64 {
        let lock = self.inner.lock().unwrap();
        lock.stream_get_seek_byte(position_ms)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_stream_tail(&self, tail_bytes: Vec<u8>, tail_offset: i64) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.probe_tail(&tail_bytes, tail_offset);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_stream_tail failed: error {}", res))
        }
    }

    pub fn play(&self) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let _ = lock.play();
        Ok(())
    }

    pub fn pause(&self) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let _ = lock.pause();
        Ok(())
    }

    pub fn stop(&self) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let _ = lock.stop();
        Ok(())
    }

    pub fn seek(&self, position_ms: i64) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let _ = lock.seek(position_ms);
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_volume(&self, volume: f32) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_volume(volume);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_volume failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_rate(&self, rate: f32) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_rate(rate);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_rate failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_pitch(&self, pitch: f32) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_pitch(pitch);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_pitch failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_buffer_size(&self, frames: u32) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_buffer_size(frames);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_buffer_size failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_buffer_size(&self) -> u32 {
        let lock = self.inner.lock().unwrap();
        lock.get_buffer_size()
    }

    pub fn set_device(&self, device_id: String) -> Result<(), String> {
        let c_id = CString::new(device_id).unwrap_or_default();
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_device(c_id.as_ptr());
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_device failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_current_device(&self) -> Result<RustAudioDevice, String> {
        let lock = self.inner.lock().unwrap();
        let mut info = MapDeviceInfo::default();
        let res = lock.get_current_device(&mut info);
        if res == 0 {
            Ok(RustAudioDevice {
                id: c_buf_to_string(&info.id),
                effective_id: c_buf_to_string(&info.effective_id),
                name: c_buf_to_string(&info.name),
                is_default: info.is_default != 0,
                is_auto: info.is_auto != 0,
            })
        } else {
            Err(format!("get_current_device failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_pause_on_device_change(&self, enabled: bool) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        lock.set_pause_on_device_change(if enabled { 1 } else { 0 });
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_pause_on_device_change(&self) -> bool {
        let lock = self.inner.lock().unwrap();
        lock.get_pause_on_device_change() != 0
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_equalizer(&self, params: RustEqualizerParams) -> Result<(), String> {
        let eq = EqualizerParams {
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
        };
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_equalizer(&eq);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_equalizer failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_equalizer_band(&self, band: u32, gain_db: f32) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_equalizer_band(band, gain_db);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_equalizer_band failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_equalizer(&self) -> Result<RustEqualizerParams, String> {
        let lock = self.inner.lock().unwrap();
        let mut eq = EqualizerParams::default();
        let res = lock.get_equalizer(&mut eq);
        if res == 0 {
            Ok(RustEqualizerParams {
                gains: vec![
                    eq.hz31, eq.hz63, eq.hz125, eq.hz250, eq.hz500, eq.hz1k, eq.hz2k, eq.hz4k,
                    eq.hz8k, eq.hz16k,
                ],
                enabled: true,
            })
        } else {
            Err(format!("get_equalizer failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_replay_gain(&self, gain_db: f32, peak: f32, prevent_clipping: bool) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_replay_gain(gain_db, peak, if prevent_clipping { 1 } else { 0 });
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_replay_gain failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn clear_replay_gain(&self) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.clear_replay_gain();
        if res == 0 {
            Ok(())
        } else {
            Err(format!("clear_replay_gain failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_preamp(&self, preamp_db: f32) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_preamp(preamp_db);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_preamp failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_balance(&self, pan: f32) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_balance(pan);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_balance failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_mono(&self, enabled: bool) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_mono(if enabled { 1 } else { 0 });
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_mono failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_crossfeed(&self, mode: i32) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_crossfeed(mode);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_crossfeed failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatializer(&self, enabled: bool, width: f32) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_spatializer(if enabled { 1 } else { 0 }, width);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_spatializer failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_reverb(&self, params: RustReverbParams) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_reverb(
            if params.enabled { 1 } else { 0 },
            params.room_size,
            params.damping,
            params.width,
            params.wet,
            params.dry,
        );
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_reverb failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_limiter(&self, enabled: bool) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_limiter(if enabled { 1 } else { 0 });
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_limiter failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_silence_config(&self, config: RustSilenceConfig) -> Result<(), String> {
        let mode = match config.mode {
            1 => crate::dsp::silence::SilenceMode::TrimEdges,
            2 => crate::dsp::silence::SilenceMode::Continuous,
            3 => crate::dsp::silence::SilenceMode::All,
            _ => crate::dsp::silence::SilenceMode::Disabled,
        };
        let sc = SilenceConfig {
            mode,
            threshold_db: config.threshold_db,
            min_silence_duration_ms: config.min_silence_duration_ms,
            padding_ms: config.padding_ms,
        };
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_silence_config(&sc);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_silence_config failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_silence_config(&self) -> Result<RustSilenceConfig, String> {
        let lock = self.inner.lock().unwrap();
        let mut sc = SilenceConfig::default();
        let res = lock.get_silence_config(&mut sc);
        if res == 0 {
            Ok(RustSilenceConfig {
                mode: sc.mode as i32,
                threshold_db: sc.threshold_db,
                min_silence_duration_ms: sc.min_silence_duration_ms,
                padding_ms: sc.padding_ms,
                enabled: sc.mode != crate::dsp::silence::SilenceMode::Disabled,
            })
        } else {
            Err(format!("get_silence_config failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_silence_saved_ms(&self) -> i64 {
        let lock = self.inner.lock().unwrap();
        lock.get_silence_saved_ms()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_visualizer_enabled(&self, enabled: bool) -> Result<(), String> {
        let mut lock = self.inner.lock().unwrap();
        let res = lock.set_visualizer_enabled(if enabled { 1 } else { 0 });
        if res == 0 {
            Ok(())
        } else {
            Err(format!("set_visualizer_enabled failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_visualizer_enabled(&self) -> bool {
        let lock = self.inner.lock().unwrap();
        lock.is_visualizer_enabled() != 0
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_visualizer_data(&self) -> Result<RustVisualizerData, String> {
        let lock = self.inner.lock().unwrap();
        let mut data = VisualizerData::default();
        let res = lock.get_visualizer_data(&mut data);
        if res == 0 {
            Ok(RustVisualizerData {
                bands: data.bands.to_vec(),
                rms: data.rms,
                peak: data.peak,
                left: data.left,
                right: data.right,
            })
        } else {
            Err(format!("get_visualizer_data failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_player_status(&self) -> Result<RustPlayerStatus, String> {
        let lock = self.inner.lock().unwrap();
        let mut status = MiniaudioPlayerStatus {
            position_ms: 0,
            duration_ms: 0,
            state: 0,
            is_playing: 0,
            is_buffering: 0,
            is_completed: 0,
            volume: 1.0,
            rate: 1.0,
            pitch: 1.0,
            bitrate: 0,
            sample_rate: 0,
            channels: 0,
            equalizer: EqualizerParams::default(),
            device: MapDeviceInfo::default(),
            silence: SilenceConfig::default(),
            silence_saved_ms: 0,
            visualizer_enabled: 0,
            visualizer: VisualizerData::default(),
            preamp_db: 0.0,
            replay_gain: ReplayGainConfig::default(),
            balance: 0.0,
            mono_enabled: 0,
            crossfeed_mode: 0,
            spatializer_enabled: 0,
            spatializer_width: 1.0,
            reverb: crate::dsp::reverb::ReverbConfig::default(),
            limiter_enabled: 0,
        };
        let res = lock.get_status(&mut status);
        if res == 0 {
            Ok(RustPlayerStatus {
                position_ms: status.position_ms,
                duration_ms: status.duration_ms,
                state: status.state,
                is_playing: status.is_playing != 0,
                is_buffering: status.is_buffering != 0,
                is_completed: status.is_completed != 0,
                volume: status.volume,
                rate: status.rate,
                pitch: status.pitch,
                bitrate: status.bitrate,
                sample_rate: status.sample_rate,
                channels: status.channels,
            })
        } else {
            Err(format!("get_status failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn dispose(&self) {
        self.telemetry.set_rust_callback(None);
        let mut lock = self.inner.lock().unwrap();
        let _ = lock.stop();
    }
}

// Global helper functions

pub fn get_audio_devices() -> Vec<RustAudioDevice> {
    let mut dev_ptr = std::ptr::null_mut();
    let mut count = 0u32;
    let res = unsafe { map_device_enumerate_devices(&mut dev_ptr, &mut count) };
    if res != 0 || dev_ptr.is_null() || count == 0 {
        return Vec::new();
    }
    let slice = unsafe { std::slice::from_raw_parts(dev_ptr, count as usize) };
    let devices: Vec<RustAudioDevice> = slice
        .iter()
        .map(|d| RustAudioDevice {
            id: c_buf_to_string(&d.id),
            effective_id: c_buf_to_string(&d.effective_id),
            name: c_buf_to_string(&d.name),
            is_default: d.is_default != 0,
            is_auto: d.is_auto != 0,
        })
        .collect();
    unsafe {
        map_device_free_devices(dev_ptr);
    }
    devices
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_audio_devices_sync() -> Vec<RustAudioDevice> {
    get_audio_devices()
}

pub fn get_default_device() -> RustAudioDevice {
    let devices = get_audio_devices();
    if let Some(def) = devices.iter().find(|d| d.is_default) {
        def.clone()
    } else if let Some(first) = devices.first() {
        first.clone()
    } else {
        RustAudioDevice {
            id: "auto".to_string(),
            effective_id: "auto".to_string(),
            name: "Default Playback Device".to_string(),
            is_default: true,
            is_auto: true,
        }
    }
}

pub fn analyze_audio_file(
    path: String,
    replay_gain: bool,
    waveform: bool,
    waveform_points: u32,
    target_lufs: f32,
) -> Result<RustAudioAnalysisResult, String> {
    let mut flags = 0u32;
    if replay_gain {
        flags |= crate::dsp::analysis::MAP_ANALYSIS_FLAG_REPLAY_GAIN;
    }
    if waveform {
        flags |= crate::dsp::analysis::MAP_ANALYSIS_FLAG_WAVEFORM;
    }
    let config = crate::dsp::analysis::AudioAnalysisConfig {
        flags,
        target_lufs,
        waveform_points,
    };

    let mut result = crate::dsp::analysis::analyze_file(&path, &config)
        .map_err(|e| format!("Analysis failed with error {}", e))?;

    let waveform_points_vec = if result.has_waveform != 0 && !result.waveform.points.is_null() {
        let count = result.waveform.point_count as usize;
        let slice = unsafe { std::slice::from_raw_parts(result.waveform.points, count) };
        slice.to_vec()
    } else {
        Vec::new()
    };
    crate::dsp::analysis::free_analysis_result(&mut result);

    Ok(RustAudioAnalysisResult {
        duration_ms: result.duration_ms,
        sample_rate: result.sample_rate,
        channels: result.channels,
        peak_amplitude: result.peak,
        rms_amplitude: result.peak,
        integrated_lufs: if result.has_replay_gain != 0 { result.replay_gain.lufs } else { 0.0 },
        replay_gain_db: if result.has_replay_gain != 0 { result.replay_gain.gain_db } else { 0.0 },
        spectral_centroid: 0.0,
        frequency_bands: Vec::new(),
        waveform_peaks: waveform_points_vec,
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn analyze_audio_file_sync(
    path: String,
    replay_gain: bool,
    waveform: bool,
    waveform_points: u32,
    target_lufs: f32,
) -> Result<RustAudioAnalysisResult, String> {
    analyze_audio_file(path, replay_gain, waveform, waveform_points, target_lufs)
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_log_level(level: i32) {
    crate::LOG_LEVEL.store(level, Ordering::Relaxed);
}

pub fn analyze_audio_memory(
    data: Vec<u8>,
    hint_extension: Option<String>,
    replay_gain: bool,
    waveform: bool,
    waveform_points: u32,
    target_lufs: f32,
) -> Result<RustAudioAnalysisResult, String> {
    let mut flags = 0u32;
    if replay_gain {
        flags |= crate::dsp::analysis::MAP_ANALYSIS_FLAG_REPLAY_GAIN;
    }
    if waveform {
        flags |= crate::dsp::analysis::MAP_ANALYSIS_FLAG_WAVEFORM;
    }
    let config = crate::dsp::analysis::AudioAnalysisConfig {
        flags,
        target_lufs,
        waveform_points,
    };

    let byte_size = data.len() as u64;
    let cursor = std::io::Cursor::new(data);
    let result = crate::dsp::analysis::analyze_media_source(
        cursor,
        hint_extension.as_deref(),
        &config,
        byte_size,
    ).map_err(|e| format!("Analysis failed with error {}", e))?;

    let waveform_points_vec = if result.has_waveform != 0 && !result.waveform.points.is_null() {
        let count = result.waveform.point_count as usize;
        let slice = unsafe { std::slice::from_raw_parts(result.waveform.points, count) };
        let vec = slice.to_vec();
        unsafe {
            let _ = Box::from_raw(std::slice::from_raw_parts_mut(result.waveform.points, count));
        }
        vec
    } else {
        Vec::new()
    };

    Ok(RustAudioAnalysisResult {
        duration_ms: result.duration_ms,
        sample_rate: result.sample_rate,
        channels: result.channels,
        peak_amplitude: result.peak,
        rms_amplitude: result.peak,
        integrated_lufs: if result.has_replay_gain != 0 { result.replay_gain.lufs } else { 0.0 },
        replay_gain_db: if result.has_replay_gain != 0 { result.replay_gain.gain_db } else { 0.0 },
        spectral_centroid: 0.0,
        frequency_bands: Vec::new(),
        waveform_peaks: waveform_points_vec,
    })
}

#[flutter_rust_bridge::frb(init)]
pub fn init_player_system() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[flutter_rust_bridge::frb(sync)]
pub fn saludar(nombre: String) -> String {
    format!("¡Hola desde Rust, {}!", nombre)
}

pub fn calculo_pesado(a: i32, b: i32) -> i32 {
    // Por defecto se expone como asíncrono en Dart para no bloquear la UI
    a + b
}
