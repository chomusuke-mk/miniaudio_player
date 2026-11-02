//! High-level Rust Player API exposed to Flutter/Dart via flutter_rust_bridge.

use std::ffi::CString;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use crate::bridge::ffi::{
    map_device_enumerate_capture_devices, map_device_enumerate_devices, map_device_free_devices,
    MapDeviceInfo, MiniaudioBufferedRange,
};
use crate::core::player::{MiniaudioPlayerStatus, PlayerCoordinator};
use crate::dsp::analysis::{
    analyze_file, analyze_media_source, AudioAnalysisConfig, MAP_ANALYSIS_FLAG_REPLAY_GAIN,
    MAP_ANALYSIS_FLAG_WAVEFORM,
};
use crate::dsp::equalizer::{EqualizerParams, ReplayGainConfig};
use crate::dsp::silence::SilenceConfig;
use crate::dsp::visualizer::VisualizerData;
use crate::frb_generated::StreamSink;
use crate::sync::telemetry::{TelemetryDispatcher, TelemetryEvent};
use crate::{STATE_COMPLETED, STATE_PLAYING};

use super::types::*;

#[inline]
fn check_map_result(res: i32, op_name: &str) -> Result<(), String> {
    if res == 0 {
        Ok(())
    } else {
        Err(format!("{} failed: error {}", op_name, res))
    }
}

fn map_telemetry_event(event: &TelemetryEvent) -> Option<RustPlayerEvent> {
    match event {
        TelemetryEvent::None => None,
        TelemetryEvent::State(s) => Some(RustPlayerEvent::State(*s)),
        TelemetryEvent::Position(p) => Some(RustPlayerEvent::Position(*p)),
        TelemetryEvent::Duration(d) => Some(RustPlayerEvent::Duration(*d)),
        TelemetryEvent::IsPlaying(p) => Some(RustPlayerEvent::IsPlaying(*p)),
        TelemetryEvent::IsBuffering(b) => Some(RustPlayerEvent::IsBuffering(*b)),
        TelemetryEvent::IsCompleted(c) => Some(RustPlayerEvent::IsCompleted(*c)),
        TelemetryEvent::Volume(v) => Some(RustPlayerEvent::Volume(*v)),
        TelemetryEvent::Rate(r) => Some(RustPlayerEvent::Rate(*r)),
        TelemetryEvent::Pitch(p) => Some(RustPlayerEvent::Pitch(*p)),
        TelemetryEvent::Bitrate(b) => Some(RustPlayerEvent::Bitrate(*b)),
        TelemetryEvent::BufferSize(b) => Some(RustPlayerEvent::BufferSize(*b)),
        TelemetryEvent::Device(dev) => Some(RustPlayerEvent::Device(RustAudioDevice::from(&**dev))),
        TelemetryEvent::Visualizer(vis) => {
            Some(RustPlayerEvent::Visualizer(RustVisualizerData::from(*vis)))
        }
        TelemetryEvent::VisualizerEnabled(e) => Some(RustPlayerEvent::VisualizerEnabled(*e)),
        TelemetryEvent::BufferedRange(br) => {
            Some(RustPlayerEvent::BufferedRange(RustBufferedRange::from(*br)))
        }
        TelemetryEvent::SilenceConfig(sc) => {
            Some(RustPlayerEvent::SilenceConfig(RustSilenceConfig::from(*sc)))
        }
        TelemetryEvent::SilenceSaved(s) => Some(RustPlayerEvent::SilenceSaved(*s)),
        TelemetryEvent::Equalizer(eq) => {
            Some(RustPlayerEvent::Equalizer(RustEqualizerParams::from(*eq)))
        }
        TelemetryEvent::Preamp(p) => Some(RustPlayerEvent::Preamp(*p)),
        TelemetryEvent::ReplayGain(rg) => {
            Some(RustPlayerEvent::ReplayGain(RustReplayGainConfig::from(*rg)))
        }
        TelemetryEvent::Balance(b) => Some(RustPlayerEvent::Balance(*b)),
        TelemetryEvent::Mono(m) => Some(RustPlayerEvent::Mono(*m)),
        TelemetryEvent::Crossfeed(c) => Some(RustPlayerEvent::Crossfeed(*c)),
        TelemetryEvent::Spatializer(sp) => Some(RustPlayerEvent::Spatializer {
            enabled: sp.enabled != 0,
            width: sp.width,
        }),
        TelemetryEvent::Reverb(rv) => Some(RustPlayerEvent::Reverb(RustReverbParams::from(*rv))),
        TelemetryEvent::Limiter(l) => Some(RustPlayerEvent::Limiter(*l)),
        TelemetryEvent::Error(code) => Some(RustPlayerEvent::Error {
            message: format!("Error code {}", code),
            code: *code,
        }),
    }
}

pub struct RustPlayer {
    inner: Arc<Mutex<Box<PlayerCoordinator>>>,
    telemetry: Arc<TelemetryDispatcher>,
    event_sink: Arc<Mutex<Option<StreamSink<RustPlayerEvent>>>>,
    custom_handle: Arc<Mutex<Option<crate::buffer::CustomByteSourceHandle>>>,
}

impl RustPlayer {
    #[flutter_rust_bridge::frb(sync)]
    pub fn new(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        playback_device_id: Option<String>,
    ) -> Result<RustPlayer, String> {
        crate::map_log!(
            3,
            "RustPlayer::new (sample_rate={}, channels={}, period_size={}, device={:?})",
            sample_rate,
            channels,
            period_size,
            playback_device_id
        );
        let dev_id_c = playback_device_id.map(|s| CString::new(s).unwrap_or_default());
        let dev_id_ptr = dev_id_c
            .as_ref()
            .map(|c| c.as_ptr())
            .unwrap_or(std::ptr::null());

        let boxed = PlayerCoordinator::new(
            sample_rate,
            channels,
            period_size,
            dev_id_ptr,
            None,
            std::ptr::null_mut(),
        )
        .map_err(|e| format!("Failed to create player coordinator: error {}", e))?;

        let telemetry = boxed.telemetry.clone();

        Ok(RustPlayer {
            inner: Arc::new(Mutex::new(boxed)),
            telemetry,
            event_sink: Arc::new(Mutex::new(None)),
            custom_handle: Arc::new(Mutex::new(None)),
        })
    }

    pub fn subscribe_events(&self, sink: StreamSink<RustPlayerEvent>) -> Result<(), String> {
        let sink_clone = sink.clone();
        *self.event_sink.lock().unwrap() = Some(sink);
        self.telemetry
            .set_typed_callback(Some(Box::new(move |event| {
                if let Some(mapped) = map_telemetry_event(event) {
                    let _ = sink_clone.add(mapped);
                }
            })));
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_sample_rate(&self) -> u32 {
        self.inner
            .lock()
            .unwrap()
            .sample_rate
            .load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_channels(&self) -> u32 {
        self.inner.lock().unwrap().channels.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_duration_ms(&self) -> i64 {
        self.inner
            .lock()
            .unwrap()
            .duration_ms
            .load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_bitrate(&self) -> u32 {
        self.inner.lock().unwrap().bitrate.load(Ordering::Relaxed)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_completed(&self) -> bool {
        self.inner.lock().unwrap().state.load(Ordering::Relaxed) == STATE_COMPLETED
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_playing(&self) -> bool {
        self.inner.lock().unwrap().state.load(Ordering::Relaxed) == STATE_PLAYING
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_live_stream(&self) -> bool {
        self.inner.lock().unwrap().is_live_stream()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_audio_data_offset(&self) -> i64 {
        self.inner.lock().unwrap().get_audio_data_offset()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_pinned_head_size(&self) -> i64 {
        self.inner.lock().unwrap().stream_get_pinned_head_size()
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

    pub fn open_source(
        &self,
        source: String,
        headers: Option<Vec<RustHttpHeader>>,
    ) -> Result<(), String> {
        crate::map_log!(3, "RustPlayer::open_source: {}", source);
        let res = self
            .inner
            .lock()
            .unwrap()
            .open_source(&source, headers.as_deref());
        check_map_result(res, "open_source")
    }

    pub fn open_memory(&self, data: Vec<u8>) -> Result<(), String> {
        crate::map_log!(3, "RustPlayer::open_memory: {} bytes", data.len());
        let res = self.inner.lock().unwrap().open_memory(&data, false);
        check_map_result(res, "open_memory")
    }

    pub fn open_custom_stream(
        &self,
        stream_id: u32,
        total_size: Option<u64>,
        is_seekable: bool,
        initial_bytes: Vec<u8>,
    ) -> Result<(), String> {
        let sink_clone = self.event_sink.clone();
        let request_sender = Arc::new(move |req: crate::buffer::DartReadRequest| {
            if let Some(ref sink) = *sink_clone.lock().unwrap() {
                let _ = sink.add(RustPlayerEvent::DartReadRequest(RustDartReadRequest::from(
                    req,
                )));
            }
        });

        let (source, handle) = crate::buffer::CustomDartByteSource::new(
            stream_id,
            total_size,
            is_seekable,
            initial_bytes.clone(),
            request_sender,
        );

        *self.custom_handle.lock().unwrap() = Some(handle.clone());

        let res = self.inner.lock().unwrap().open_custom_source(
            source,
            handle,
            total_size,
            is_seekable,
            &initial_bytes,
        );
        if res == 0 {
            Ok(())
        } else {
            *self.custom_handle.lock().unwrap() = None;
            Err(format!("open_custom_stream failed: error {}", res))
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn supply_custom_bytes(
        &self,
        _stream_id: u32,
        request_id: u64,
        data: Vec<u8>,
        is_eof: bool,
    ) -> Result<(), String> {
        if let Some(ref handle) = *self.custom_handle.lock().unwrap() {
            handle.supply_bytes(request_id, data, is_eof);
            Ok(())
        } else {
            Err("No active custom byte source".to_string())
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn notify_custom_error(&self, _stream_id: u32, request_id: u64, error_message: String) {
        if let Some(ref handle) = *self.custom_handle.lock().unwrap() {
            handle.notify_error(request_id, error_message);
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_buffered_range(&self) -> Result<RustBufferedRange, String> {
        let lock = self.inner.lock().unwrap();
        let mut range = MiniaudioBufferedRange::default();
        let res = lock.get_buffered_range(&mut range);
        check_map_result(res, "get_buffered_range")?;
        Ok(RustBufferedRange::from(range))
    }

    pub fn play(&self) -> Result<(), String> {
        let _ = self.inner.lock().unwrap().play();
        Ok(())
    }

    pub fn pause(&self) -> Result<(), String> {
        let _ = self.inner.lock().unwrap().pause();
        Ok(())
    }

    pub fn stop(&self) -> Result<(), String> {
        let _ = self.inner.lock().unwrap().stop();
        Ok(())
    }

    pub fn seek(&self, position_ms: i64) -> Result<(), String> {
        let _ = self.inner.lock().unwrap().seek(position_ms);
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_volume(&self, volume: f32) -> Result<(), String> {
        let res = self.inner.lock().unwrap().set_volume(volume);
        check_map_result(res, "set_volume")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_rate(&self, rate: f32) -> Result<(), String> {
        let res = self.inner.lock().unwrap().set_rate(rate);
        check_map_result(res, "set_rate")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_pitch(&self, pitch: f32) -> Result<(), String> {
        let res = self.inner.lock().unwrap().set_pitch(pitch);
        check_map_result(res, "set_pitch")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_buffer_size(&self, frames: u32) -> Result<(), String> {
        let res = self.inner.lock().unwrap().set_buffer_size(frames);
        check_map_result(res, "set_buffer_size")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_buffer_size(&self) -> u32 {
        self.inner.lock().unwrap().get_buffer_size()
    }

    pub fn set_device(&self, device_id: String) -> Result<(), String> {
        let c_id = CString::new(device_id).unwrap_or_default();
        let res = self.inner.lock().unwrap().set_device(c_id.as_ptr());
        check_map_result(res, "set_device")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_current_device(&self) -> Result<RustAudioDevice, String> {
        let lock = self.inner.lock().unwrap();
        let mut info = MapDeviceInfo::default();
        let res = lock.get_current_device(&mut info);
        check_map_result(res, "get_current_device")?;
        Ok(RustAudioDevice::from(&info))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_pause_on_device_change(&self, enabled: bool) -> Result<(), String> {
        self.inner
            .lock()
            .unwrap()
            .set_pause_on_device_change(if enabled { 1 } else { 0 });
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_pause_on_device_change(&self) -> bool {
        self.inner.lock().unwrap().get_pause_on_device_change() != 0
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_equalizer(&self, params: RustEqualizerParams) -> Result<(), String> {
        let eq = EqualizerParams::from(params);
        let res = self.inner.lock().unwrap().set_equalizer(&eq);
        check_map_result(res, "set_equalizer")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_equalizer_band(&self, band: u32, gain_db: f32) -> Result<(), String> {
        let res = self.inner.lock().unwrap().set_equalizer_band(band, gain_db);
        check_map_result(res, "set_equalizer_band")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_equalizer(&self) -> Result<RustEqualizerParams, String> {
        let lock = self.inner.lock().unwrap();
        let mut eq = EqualizerParams::default();
        let res = lock.get_equalizer(&mut eq);
        check_map_result(res, "get_equalizer")?;
        Ok(RustEqualizerParams::from(eq))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_replay_gain(
        &self,
        gain_db: f32,
        peak: f32,
        prevent_clipping: bool,
    ) -> Result<(), String> {
        let res = self.inner.lock().unwrap().set_replay_gain(
            gain_db,
            peak,
            if prevent_clipping { 1 } else { 0 },
        );
        check_map_result(res, "set_replay_gain")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn clear_replay_gain(&self) -> Result<(), String> {
        let res = self.inner.lock().unwrap().clear_replay_gain();
        check_map_result(res, "clear_replay_gain")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_preamp(&self, preamp_db: f32) -> Result<(), String> {
        let res = self.inner.lock().unwrap().set_preamp(preamp_db);
        check_map_result(res, "set_preamp")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_balance(&self, pan: f32) -> Result<(), String> {
        let res = self.inner.lock().unwrap().set_balance(pan);
        check_map_result(res, "set_balance")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_mono(&self, enabled: bool) -> Result<(), String> {
        let res = self
            .inner
            .lock()
            .unwrap()
            .set_mono(if enabled { 1 } else { 0 });
        check_map_result(res, "set_mono")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_crossfeed(&self, mode: i32) -> Result<(), String> {
        let res = self.inner.lock().unwrap().set_crossfeed(mode);
        check_map_result(res, "set_crossfeed")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatializer(&self, enabled: bool, width: f32) -> Result<(), String> {
        let res = self
            .inner
            .lock()
            .unwrap()
            .set_spatializer(if enabled { 1 } else { 0 }, width);
        check_map_result(res, "set_spatializer")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatial_enabled(&self, enabled: bool) -> Result<(), String> {
        self.inner.lock().unwrap().set_spatial_enabled(enabled);
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatial_listener(&self, listener: RustSpatialListener) -> Result<(), String> {
        self.inner
            .lock()
            .unwrap()
            .set_spatial_listener(listener.into());
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatial_emitter(&self, emitter: RustSpatialEmitter) -> Result<(), String> {
        self.inner
            .lock()
            .unwrap()
            .set_spatial_emitter(emitter.into());
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatial_doppler_factor(&self, factor: f32) -> Result<(), String> {
        self.inner
            .lock()
            .unwrap()
            .set_spatial_doppler_factor(factor);
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_spatial_speed_of_sound(&self, speed: f32) -> Result<(), String> {
        self.inner.lock().unwrap().set_spatial_speed_of_sound(speed);
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_reverb(&self, params: RustReverbParams) -> Result<(), String> {
        let res = self.inner.lock().unwrap().set_reverb(
            if params.enabled { 1 } else { 0 },
            params.room_size,
            params.damping,
            params.width,
            params.wet,
            params.dry,
        );
        check_map_result(res, "set_reverb")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_limiter(&self, enabled: bool) -> Result<(), String> {
        let res = self
            .inner
            .lock()
            .unwrap()
            .set_limiter(if enabled { 1 } else { 0 });
        check_map_result(res, "set_limiter")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_silence_config(&self, config: RustSilenceConfig) -> Result<(), String> {
        let sc = SilenceConfig::from(config);
        let res = self.inner.lock().unwrap().set_silence_config(&sc);
        check_map_result(res, "set_silence_config")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_silence_config(&self) -> Result<RustSilenceConfig, String> {
        let lock = self.inner.lock().unwrap();
        let mut sc = SilenceConfig::default();
        let res = lock.get_silence_config(&mut sc);
        check_map_result(res, "get_silence_config")?;
        Ok(RustSilenceConfig::from(sc))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_silence_saved_ms(&self) -> i64 {
        self.inner.lock().unwrap().get_silence_saved_ms()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_visualizer_enabled(&self, enabled: bool) -> Result<(), String> {
        let res = self
            .inner
            .lock()
            .unwrap()
            .set_visualizer_enabled(if enabled { 1 } else { 0 });
        check_map_result(res, "set_visualizer_enabled")
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_visualizer_enabled(&self) -> bool {
        self.inner.lock().unwrap().is_visualizer_enabled() != 0
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_visualizer_data(&self) -> Result<RustVisualizerData, String> {
        let lock = self.inner.lock().unwrap();
        let mut data = VisualizerData::default();
        let res = lock.get_visualizer_data(&mut data);
        check_map_result(res, "get_visualizer_data")?;
        Ok(RustVisualizerData::from(data))
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
        check_map_result(res, "get_status")?;
        Ok(RustPlayerStatus::from(status))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn dispose(&self) {
        crate::map_log!(3, "RustPlayer::dispose called");
        self.telemetry.set_rust_callback(None);
        self.telemetry.set_typed_callback(None);
        if let Ok(mut sink) = self.event_sink.lock() {
            *sink = None;
        }
        if let Ok(mut handle) = self.custom_handle.lock() {
            *handle = None;
        }
        if let Ok(mut inner) = self.inner.lock() {
            inner.destroy();
        }
    }
}

impl Drop for RustPlayer {
    fn drop(&mut self) {
        self.dispose();
    }
}

// Global helper functions

fn enumerate_ffi_devices(
    enum_fn: unsafe extern "C" fn(*mut *mut MapDeviceInfo, *mut u32) -> i32,
) -> Vec<RustAudioDevice> {
    let mut dev_ptr = std::ptr::null_mut();
    let mut count = 0u32;
    let res = unsafe { enum_fn(&mut dev_ptr, &mut count) };
    if res != 0 || dev_ptr.is_null() || count == 0 {
        return Vec::new();
    }
    let slice = unsafe { std::slice::from_raw_parts(dev_ptr, count as usize) };
    let devices: Vec<RustAudioDevice> = slice.iter().map(RustAudioDevice::from).collect();
    unsafe {
        map_device_free_devices(dev_ptr);
    }
    devices
}

pub fn get_audio_devices() -> Vec<RustAudioDevice> {
    enumerate_ffi_devices(map_device_enumerate_devices)
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_audio_devices_sync() -> Vec<RustAudioDevice> {
    get_audio_devices()
}

pub fn get_capture_devices() -> Vec<RustAudioDevice> {
    enumerate_ffi_devices(map_device_enumerate_capture_devices)
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_capture_devices_sync() -> Vec<RustAudioDevice> {
    get_capture_devices()
}

fn build_analysis_config(
    replay_gain: bool,
    waveform: bool,
    waveform_points: u32,
    target_lufs: f32,
) -> AudioAnalysisConfig {
    let mut flags = 0u32;
    if replay_gain {
        flags |= MAP_ANALYSIS_FLAG_REPLAY_GAIN;
    }
    if waveform {
        flags |= MAP_ANALYSIS_FLAG_WAVEFORM;
    }
    AudioAnalysisConfig {
        flags,
        target_lufs,
        waveform_points,
    }
}

pub fn analyze_audio_file(
    path: String,
    replay_gain: bool,
    waveform: bool,
    waveform_points: u32,
    target_lufs: f32,
) -> Result<RustAudioAnalysisResult, String> {
    let config = build_analysis_config(replay_gain, waveform, waveform_points, target_lufs);
    let result =
        analyze_file(&path, &config).map_err(|e| format!("Analysis failed with error {}", e))?;
    Ok(RustAudioAnalysisResult::from(result))
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
    let config = build_analysis_config(replay_gain, waveform, waveform_points, target_lufs);
    let byte_size = data.len() as u64;

    let sniffer_hint = if hint_extension.is_none() {
        let (_status, boundary) =
            crate::decoder::sniffer::FormatSniffer::detect_head_boundary(&data, byte_size as i64);
        boundary.container.hint_extension().map(str::to_string)
    } else {
        None
    };

    let effective_hint = hint_extension.or(sniffer_hint);
    let cursor = std::io::Cursor::new(data);
    let result = analyze_media_source(cursor, effective_hint.as_deref(), &config, byte_size)
        .map_err(|e| format!("Analysis failed with error {}", e))?;

    Ok(RustAudioAnalysisResult::from(result))
}

#[flutter_rust_bridge::frb(init)]
pub fn init_player_system() {
    flutter_rust_bridge::setup_default_user_utils();
}
