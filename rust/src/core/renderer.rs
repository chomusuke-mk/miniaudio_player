//! Real-time decoupled AudioRenderer executing on the OS audio callback thread.
//!
//! Enforces hard real-time safety invariants:
//! - Zero OS mutex locks (`std::sync::Mutex`, `parking_lot::Mutex`, `RwLock`).
//! - Zero dynamic heap allocations (`Box`, `Vec`, `String`, etc.).
//! - Zero blocking syscalls.
//! - Non-blocking, wait-free Single-Producer Single-Consumer (SPSC) consumption via `rtrb`.

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;

use crate::core::types::PlaybackState;
use crate::dsp::chain::DspChain;
use crate::dsp::crossfeed::CrossfeedConfig;
use crate::dsp::equalizer::{EqualizerParams, ReplayGainConfig};
use crate::dsp::reverb::ReverbConfig;
use crate::dsp::sonic::SonicStream;
use crate::dsp::visualizer::VisualizerData;
use crate::sync::ring_buffer::AudioConsumer;
use crate::sync::seqlock::CachePaddedSeqlock;

/// SPSC lock-free control commands dispatched from PlayerCoordinator to AudioRenderer.
#[derive(Clone, Copy, Debug)]
pub enum DspCommand {
    SetVolume(f32),
    SetEqualizerParams(EqualizerParams),
    SetEqualizerBand { band: usize, gain_db: f32 },
    SetPreamp(f32),
    SetReplayGain(ReplayGainConfig),
    SetBalance(f32),
    SetMono(bool),
    SetSpatializer { enabled: bool, width: f32 },
    SetCrossfeed(CrossfeedConfig),
    SetReverb(ReverbConfig),
    SetLimiter(bool),
    SetVisualizerEnabled(bool),
    SetSampleRate(u32),
}

/// C-ABI compatible renderer header containing function pointers for miniaudio callback hooks.
#[repr(C)]
pub struct PcmRendererHeader {
    /// Render callback invoked on the high-priority real-time audio thread.
    pub render_fn:
        unsafe extern "C" fn(ptr: *mut std::os::raw::c_void, output: *mut f32, count: usize),
    /// Hardware notification callback invoked when device state changes.
    pub notif_fn: unsafe extern "C" fn(ptr: *mut std::os::raw::c_void, notif: i32),
}

/// C trampoline forwarding audio frame requests to [`AudioRenderer::render_pcm`].
pub unsafe extern "C" fn audio_renderer_render_trampoline(
    ptr: *mut std::os::raw::c_void,
    output: *mut f32,
    count: usize,
) {
    let r = &mut *(ptr as *mut AudioRenderer);
    r.render_pcm(output, count);
}

/// C trampoline forwarding hardware device notifications to [`AudioRenderer::on_device_notification`].
pub unsafe extern "C" fn audio_renderer_notif_trampoline(
    ptr: *mut std::os::raw::c_void,
    notif: i32,
) {
    let r = &*(ptr as *mut AudioRenderer);
    r.on_device_notification(notif);
}

/// Anti-pop micro-fade duration (~5.3ms at 48 kHz) applied around underrun, pause, and resume transitions.
const ANTI_POP_FADE_FRAMES: usize = 256;

/// Lock-free, allocation-free smoothing state preventing step discontinuities in `AudioRenderer`.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct AntiPopState {
    pub last_samples: [f32; 16],
    pub output_silenced: bool,
    pub need_fade_in: bool,
}

impl Default for AntiPopState {
    fn default() -> Self {
        Self {
            last_samples: [0.0; 16],
            output_silenced: true,
            need_fade_in: false,
        }
    }
}

/// Decoupled, real-time safe audio renderer passed exclusively to the hardware audio callback.
#[repr(C)]
pub struct AudioRenderer {
    pub header: PcmRendererHeader,
    pub deck_id: usize,
    pub consumer: AudioConsumer,
    pub cmd_consumer: rtrb::Consumer<DspCommand>,

    pub state: Arc<AtomicI32>,
    pub sample_rate: Arc<AtomicU32>,
    pub channels: Arc<AtomicU32>,
    pub device_sample_rate: Arc<AtomicU32>,
    pub device_channels: Arc<AtomicU32>,
    pub volume: Arc<AtomicU32>,
    pub rate: Arc<AtomicU32>,
    pub pitch: Arc<AtomicU32>,
    pub position_frames: Arc<AtomicI64>,
    pub position_ms: Arc<AtomicI64>,
    pub duration_ms: Arc<AtomicI64>,

    pub decoder_eof: Arc<AtomicBool>,
    pub seek_request_ms: Arc<AtomicI64>,
    pub is_stream: Arc<AtomicBool>,
    pub at_live_edge: Arc<AtomicBool>,

    pub flush_generation: Arc<AtomicU64>,
    pub flush_acknowledged: Arc<AtomicU64>,
    pub local_flush_gen: u64,

    pub track_exhausted: Arc<AtomicBool>,
    pub is_buffering: Arc<AtomicBool>,

    pub dsp: DspChain,
    pub sonic: SonicStream,
    pub sonic_in_buf: Vec<f32>,
    pub visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,
    pub visualizer_enabled: Arc<AtomicBool>,

    pub notification_callback: Option<Arc<dyn Fn(i32) + Send + Sync>>,
    pub anti_pop: AntiPopState,
}

// AudioRenderer is strictly Send across threads (created on main thread, sent to OS audio thread)
unsafe impl Send for AudioRenderer {}

impl AudioRenderer {
    #[inline]
    fn drain_dsp_commands(&mut self) {
        while let Ok(cmd) = self.cmd_consumer.pop() {
            self.apply_dsp_command(cmd);
        }
    }

    #[inline]
    fn apply_dsp_command(&mut self, cmd: DspCommand) {
        match cmd {
            DspCommand::SetVolume(v) => self.dsp.set_volume(v),
            DspCommand::SetEqualizerParams(p) => self.dsp.set_equalizer_params(&p),
            DspCommand::SetEqualizerBand { band, gain_db } => {
                self.dsp.set_equalizer_band(band, gain_db)
            }
            DspCommand::SetPreamp(db) => self.dsp.set_preamp_db(db),
            DspCommand::SetReplayGain(rg) => self.dsp.set_replay_gain(rg),
            DspCommand::SetBalance(b) => self.dsp.set_balance(b),
            DspCommand::SetMono(m) => self.dsp.set_mono(m),
            DspCommand::SetSpatializer { enabled, width } => {
                self.dsp.set_spatializer(enabled, width)
            }
            DspCommand::SetCrossfeed(cfg) => self.dsp.set_crossfeed(cfg),
            DspCommand::SetReverb(cfg) => self.dsp.set_reverb(cfg),
            DspCommand::SetLimiter(en) => self.dsp.set_limiter_enabled(en),
            DspCommand::SetVisualizerEnabled(en) => self.dsp.set_visualizer_enabled(en),
            DspCommand::SetSampleRate(sr) => {
                self.dsp.set_sample_rate(sr);
                let ch = self.device_channels.load(Ordering::Relaxed) as usize;
                self.sonic = SonicStream::new(sr, ch.clamp(1, 8));
            }
        }
    }

    #[inline]
    fn smoothstep(u: f32) -> f32 {
        u * u * (3.0 - 2.0 * u)
    }

    #[inline]
    fn emit_silence_or_fade_out(
        &mut self,
        out_slice: &mut [f32],
        frame_count: usize,
        ch: usize,
    ) {
        if self.anti_pop.output_silenced {
            out_slice.fill(0.0);
            return;
        }
        let c = ch.min(16);
        let fade_frames = frame_count.min(ANTI_POP_FADE_FRAMES);
        if fade_frames == 0 || c == 0 {
            out_slice.fill(0.0);
        } else {
            let denom = fade_frames as f32;
            for f in 0..fade_frames {
                let u = (f + 1) as f32 / denom;
                let gain = 1.0 - Self::smoothstep(u);
                let base = f * ch;
                for chan in 0..c {
                    out_slice[base + chan] = self.anti_pop.last_samples[chan] * gain;
                }
                for chan in c..ch {
                    out_slice[base + chan] = 0.0;
                }
            }
            out_slice[fade_frames * ch..].fill(0.0);
        }
        self.anti_pop.last_samples[..c].fill(0.0);
        self.anti_pop.output_silenced = true;
        self.anti_pop.need_fade_in = true;
    }

    #[inline]
    fn smooth_partial_tail(
        &mut self,
        out_slice: &mut [f32],
        read_frames: usize,
        ch: usize,
    ) {
        if read_frames == 0 {
            out_slice.fill(0.0);
            self.anti_pop.last_samples[..ch.min(16)].fill(0.0);
            self.anti_pop.output_silenced = true;
            self.anti_pop.need_fade_in = true;
            return;
        }
        let fade_frames = read_frames.min(ANTI_POP_FADE_FRAMES);
        let start_f = read_frames - fade_frames;
        let denom = fade_frames as f32;
        for idx in 0..fade_frames {
            let u = (idx + 1) as f32 / denom;
            let gain = 1.0 - Self::smoothstep(u);
            let base = (start_f + idx) * ch;
            for chan in 0..ch {
                out_slice[base + chan] *= gain;
            }
        }
        out_slice[read_frames * ch..].fill(0.0);
        self.anti_pop.last_samples[..ch.min(16)].fill(0.0);
        self.anti_pop.output_silenced = true;
        self.anti_pop.need_fade_in = true;
    }

    #[inline]
    fn apply_fade_in_and_track(
        &mut self,
        out_slice: &mut [f32],
        valid_frames: usize,
        ch: usize,
    ) {
        if valid_frames == 0 {
            return;
        }
        if self.anti_pop.need_fade_in {
            let fade_frames = valid_frames.min(ANTI_POP_FADE_FRAMES);
            let denom = fade_frames.max(1) as f32;
            for f in 0..fade_frames {
                let u = f as f32 / denom;
                let gain = Self::smoothstep(u);
                let base = f * ch;
                for chan in 0..ch {
                    out_slice[base + chan] *= gain;
                }
            }
            self.anti_pop.need_fade_in = false;
        }
        let c = ch.min(16);
        let last_base = (valid_frames - 1) * ch;
        self.anti_pop.last_samples[..c].copy_from_slice(&out_slice[last_base..last_base + c]);
        self.anti_pop.output_silenced = false;
    }

    /// Acknowledges and applies pending buffer flushes requested across threads.
    #[inline]
    pub fn acknowledge_flush_if_needed(&mut self) {
        let current_flush = self.flush_generation.load(Ordering::Acquire);
        if current_flush != self.local_flush_gen {
            self.local_flush_gen = current_flush;
            self.consumer.clear();
            self.sonic.flush();
            if !self.anti_pop.output_silenced {
                self.anti_pop.last_samples.fill(0.0);
                self.anti_pop.output_silenced = true;
                self.anti_pop.need_fade_in = true;
            }
            self.flush_acknowledged
                .store(current_flush, Ordering::Release);
        }
    }

    #[inline]
    fn resolved_stretch_params(&self) -> (f32, f32, bool) {
        let mut requested_rate = f32::from_bits(self.rate.load(Ordering::Relaxed));
        if requested_rate > 1.0 && self.at_live_edge.load(Ordering::Relaxed) {
            requested_rate = 1.0;
        }
        let cur_rate = requested_rate.max(0.001);
        let cur_pitch = f32::from_bits(self.pitch.load(Ordering::Relaxed)).max(0.001);
        let is_stretched = (cur_rate - 1.0).abs() > 0.001 || (cur_pitch - 1.0).abs() > 0.001;
        (cur_rate, cur_pitch, is_stretched)
    }

    #[inline]
    fn pull_audio_frames(
        &mut self,
        out_slice: &mut [f32],
        frame_count: usize,
        ch: usize,
    ) -> (usize, i64) {
        let (cur_rate, cur_pitch, is_stretched) = self.resolved_stretch_params();

        if !is_stretched {
            let read = self.consumer.read_chunk(out_slice);
            return (read, (read / ch) as i64);
        }

        self.sonic.set_speed(cur_rate);
        self.sonic.set_pitch(cur_pitch);
        let mut frames_out = 0;
        while frames_out < frame_count {
            let got = self.sonic.read_float(&mut out_slice[frames_out * ch..]);
            frames_out += got;
            if frames_out >= frame_count {
                break;
            }
            let needed = ((frame_count - frames_out) * ch).max(512);
            let to_read = needed.min(self.sonic_in_buf.len());
            let read = self.consumer.read_chunk(&mut self.sonic_in_buf[..to_read]);
            if read == 0 {
                break;
            }
            self.sonic.write_float(&self.sonic_in_buf[..read]);
        }
        let un_stretched = (frames_out as f64 * cur_rate as f64).round() as i64;
        (frames_out * ch, un_stretched)
    }

    #[inline]
    fn update_playback_state_and_position(
        &mut self,
        read_samples: usize,
        total_samples: usize,
        frame_count: usize,
        ch: usize,
        un_stretched_frames_consumed: i64,
        out_slice: &mut [f32],
    ) {
        let is_stream = self.is_stream.load(Ordering::Acquire);
        let decoder_at_eof = self.decoder_eof.load(Ordering::Acquire);
        let seek_pending = self.seek_request_ms.load(Ordering::Acquire) >= 0;

        if read_samples > 0 {
            let read_frames = read_samples / ch.max(1);
            if read_samples < total_samples {
                if is_stream && !decoder_at_eof && !seek_pending {
                    self.is_buffering.store(true, Ordering::Release);
                }
                if self.anti_pop.need_fade_in {
                    self.apply_fade_in_and_track(out_slice, read_frames, ch);
                }
                self.smooth_partial_tail(out_slice, read_frames, ch);
            } else {
                if !is_stream {
                    self.is_buffering.store(false, Ordering::Release);
                }
                self.apply_fade_in_and_track(out_slice, read_frames, ch);
            }

            let sr = self.device_sample_rate.load(Ordering::Relaxed) as i64;
            let track_subframes = un_stretched_frames_consumed * 1024;
            let total_subframes = self
                .position_frames
                .fetch_add(track_subframes, Ordering::Relaxed)
                + track_subframes;
            let total_frames = total_subframes / 1024;
            let new_pos = if sr > 0 {
                (total_frames * 1000) / sr
            } else {
                0
            };
            self.position_ms.store(new_pos, Ordering::Relaxed);
        } else {
            self.emit_silence_or_fade_out(out_slice, frame_count, ch);
            let dur = self.duration_ms.load(Ordering::Acquire);
            let pos = self.position_ms.load(Ordering::Acquire);
            if decoder_at_eof && !seek_pending {
                if dur <= 0 || pos > 0 || dur <= 100 {
                    self.is_buffering.store(false, Ordering::Release);
                    self.track_exhausted.store(true, Ordering::Release);
                }
            } else if is_stream && !seek_pending {
                self.is_buffering.store(true, Ordering::Release);
            }
        }
    }

    #[inline]
    fn apply_realtime_dsp_and_visualizer(&mut self, out_slice: &mut [f32]) {
        let vol = f32::from_bits(self.volume.load(Ordering::Relaxed)).max(0.0);
        self.dsp.set_volume(vol);
        self.dsp.process_frames(out_slice);

        if self.visualizer_enabled.load(Ordering::Relaxed) {
            let vis = self.dsp.visualizer_data();
            self.visualizer_seqlock.write(|v| *v = vis);
        }
    }

    /// Render interleaved 32-bit floating point PCM audio frames into the output buffer provided by miniaudio.
    ///
    /// GUARANTEES:
    /// - 100% Lock-Free: Acquires zero OS Mutexes or RwLocks.
    /// - 100% Allocation-Free: Never allocates on the heap.
    /// - Wait-Free: Returns in bounded $\mathcal{O}(frame\_count \times channels)$ execution time.
    #[inline]
    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    pub fn render_pcm(&mut self, output_frames: *mut f32, frame_count: usize) {
        self.drain_dsp_commands();
        self.acknowledge_flush_if_needed();

        let ch = (self.device_channels.load(Ordering::Relaxed) as usize).clamp(1, 16);
        let total_samples = frame_count * ch;
        let out_slice = unsafe { std::slice::from_raw_parts_mut(output_frames, total_samples) };

        let cur_state = PlaybackState::from_i32(self.state.load(Ordering::Relaxed));
        if cur_state != PlaybackState::Playing {
            self.emit_silence_or_fade_out(out_slice, frame_count, ch);
            return;
        }

        let is_stream = self.is_stream.load(Ordering::Acquire);
        let decoder_at_eof = self.decoder_eof.load(Ordering::Acquire);
        let seek_pending = self.seek_request_ms.load(Ordering::Acquire) >= 0;

        if seek_pending {
            self.emit_silence_or_fade_out(out_slice, frame_count, ch);
            self.apply_realtime_dsp_and_visualizer(out_slice);
            return;
        }

        if is_stream && self.is_buffering.load(Ordering::Acquire) && !decoder_at_eof && !seek_pending {
            self.emit_silence_or_fade_out(out_slice, frame_count, ch);
            self.apply_realtime_dsp_and_visualizer(out_slice);
            return;
        }

        let (_, _, is_stretched) = self.resolved_stretch_params();
        if is_stream
            && !decoder_at_eof
            && !seek_pending
            && !is_stretched
            && self.consumer.samples_available() < total_samples
        {
            self.is_buffering.store(true, Ordering::Release);
            self.emit_silence_or_fade_out(out_slice, frame_count, ch);
            self.apply_realtime_dsp_and_visualizer(out_slice);
            return;
        }

        let (read_samples, un_stretched_frames_consumed) =
            self.pull_audio_frames(out_slice, frame_count, ch);

        self.update_playback_state_and_position(
            read_samples,
            total_samples,
            frame_count,
            ch,
            un_stretched_frames_consumed,
            out_slice,
        );
        self.apply_realtime_dsp_and_visualizer(out_slice);
    }

    /// Dispatches hardware device state change notifications to registered listener callbacks.
    #[inline]
    pub fn on_device_notification(&self, notification_type: i32) {
        if let Some(ref cb) = self.notification_callback {
            cb(notification_type);
        }
    }
}
