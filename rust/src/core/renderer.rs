//! Real-time decoupled AudioRenderer executing on the OS audio callback thread.
//!
//! Enforces hard real-time safety invariants:
//! - Zero OS mutex locks (`std::sync::Mutex`, `parking_lot::Mutex`, `RwLock`).
//! - Zero dynamic heap allocations (`Box`, `Vec`, `String`, etc.).
//! - Zero blocking syscalls.
//! - Non-blocking, wait-free Single-Producer Single-Consumer (SPSC) consumption via `rtrb`.

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;

use crate::core::player::{STATE_BUFFERING, STATE_COMPLETED, STATE_PLAYING};
use crate::dsp::chain::DspChain;
use crate::dsp::crossfeed::CrossfeedMode;
use crate::dsp::equalizer::{EqualizerParams, ReplayGainConfig};
use crate::dsp::reverb::ReverbConfig;
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
    SetCrossfeed(CrossfeedMode),
    SetReverb(ReverbConfig),
    SetLimiter(bool),
    SetVisualizerEnabled(bool),
    SetSampleRate(u32),
}

/// Decoupled, real-time safe audio renderer passed exclusively to the hardware audio callback.
pub struct AudioRenderer {
    pub consumer: AudioConsumer,
    pub cmd_consumer: rtrb::Consumer<DspCommand>,

    pub state: Arc<AtomicI32>,
    pub sample_rate: Arc<AtomicU32>,
    pub channels: Arc<AtomicU32>,
    pub volume: Arc<AtomicU32>,
    pub rate: Arc<AtomicU32>,
    pub position_frames: Arc<AtomicI64>,
    pub position_ms: Arc<AtomicI64>,
    pub duration_ms: Arc<AtomicI64>,

    pub decoder_eof: Arc<AtomicBool>,
    pub seek_request_ms: Arc<AtomicI64>,
    pub is_stream: Arc<AtomicBool>,

    pub flush_generation: Arc<AtomicU64>,
    pub flush_acknowledged: Arc<AtomicU64>,
    pub local_flush_gen: u64,

    pub completed_flag: Arc<AtomicBool>,
    pub buffering_flag: Arc<AtomicBool>,

    pub dsp: DspChain,
    pub visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,
    pub visualizer_enabled: Arc<AtomicBool>,

    pub notification_callback: Option<Arc<dyn Fn(i32) + Send + Sync>>,
}

// AudioRenderer is strictly Send across threads (created on main thread, sent to OS audio thread)
unsafe impl Send for AudioRenderer {}

impl AudioRenderer {
    /// Render interleaved 32-bit floating point PCM audio frames into the output buffer provided by miniaudio.
    ///
    /// GUARANTEES:
    /// - 100% Lock-Free: Acquires zero OS Mutexes or RwLocks.
    /// - 100% Allocation-Free: Never allocates on the heap.
    /// - Wait-Free: Returns in bounded $\mathcal{O}(frame\_count \times channels)$ execution time.
    #[inline]
    pub fn render_pcm(&mut self, output_frames: *mut f32, frame_count: usize) {
        // 1. Drain pending DSP commands (wait-free SPSC from PlayerCoordinator)
        let available_cmds = self.cmd_consumer.slots();
        if available_cmds > 0 {
            if let Ok(chunk) = self.cmd_consumer.read_chunk(available_cmds) {
                let (first, second) = chunk.as_slices();
                for cmd in first.iter().chain(second.iter()) {
                    match cmd {
                        DspCommand::SetVolume(v) => self.dsp.set_volume(*v),
                        DspCommand::SetEqualizerParams(p) => self.dsp.set_equalizer_params(p),
                        DspCommand::SetEqualizerBand { band, gain_db } => {
                            self.dsp.set_equalizer_band(*band, *gain_db)
                        }
                        DspCommand::SetPreamp(db) => self.dsp.set_preamp_db(*db),
                        DspCommand::SetReplayGain(rg) => self.dsp.set_replay_gain(*rg),
                        DspCommand::SetBalance(b) => self.dsp.set_balance(*b),
                        DspCommand::SetMono(m) => self.dsp.set_mono(*m),
                        DspCommand::SetSpatializer { enabled, width } => {
                            self.dsp.set_spatializer(*enabled, *width)
                        }
                        DspCommand::SetCrossfeed(mode) => self.dsp.set_crossfeed(*mode),
                        DspCommand::SetReverb(cfg) => self.dsp.set_reverb(*cfg),
                        DspCommand::SetLimiter(en) => self.dsp.set_limiter_enabled(*en),
                        DspCommand::SetVisualizerEnabled(en) => {
                            self.dsp.set_visualizer_enabled(*en)
                        }
                        DspCommand::SetSampleRate(sr) => self.dsp.set_sample_rate(*sr),
                    }
                }
                chunk.commit_all();
            }
        }

        // 2. Check flush generation (for lock-free buffer discard on seek or stop)
        let current_flush = self.flush_generation.load(Ordering::Acquire);
        if current_flush != self.local_flush_gen {
            self.local_flush_gen = current_flush;
            self.consumer.clear();
            self.flush_acknowledged.store(current_flush, Ordering::Release);
        }

        let ch = self.channels.load(Ordering::Relaxed) as usize;
        let total_samples = frame_count * ch;
        let out_slice = unsafe { std::slice::from_raw_parts_mut(output_frames, total_samples) };

        let cur_state = self.state.load(Ordering::Relaxed);
        if cur_state != STATE_PLAYING && cur_state != STATE_BUFFERING {
            out_slice.fill(0.0);
            return;
        }

        // 3. Read chunk from audio consumer (wait-free, zero locks)
        let read_samples = self.consumer.read_chunk(out_slice);

        if read_samples < total_samples {
            out_slice[read_samples..].fill(0.0);

            let decoder_at_eof = self.decoder_eof.load(Ordering::Acquire);
            let seek_pending = self.seek_request_ms.load(Ordering::Acquire) >= 0;
            if decoder_at_eof && !seek_pending && read_samples == 0 {
                self.state.store(STATE_COMPLETED, Ordering::Release);
                self.completed_flag.store(true, Ordering::Release);
            } else if read_samples == 0 && self.is_stream.load(Ordering::Acquire) {
                self.state.store(STATE_BUFFERING, Ordering::Release);
                self.buffering_flag.store(true, Ordering::Release);
            }
        }

        if read_samples > 0 {
            let frames_played = (read_samples / ch) as i64;
            let sr = self.sample_rate.load(Ordering::Relaxed) as i64;
            let rate = f32::from_bits(self.rate.load(Ordering::Relaxed)).max(0.01);
            let track_subframes = ((frames_played as f64) * (rate as f64) * 1024.0) as i64;
            let total_subframes =
                self.position_frames.fetch_add(track_subframes, Ordering::Relaxed) + track_subframes;
            let total_frames = total_subframes / 1024;
            let new_pos = if sr > 0 { (total_frames * 1000) / sr } else { 0 };
            self.position_ms.store(new_pos, Ordering::Relaxed);
        }

        // 4. In-place real-time DSP
        let vol = f32::from_bits(self.volume.load(Ordering::Relaxed));
        self.dsp.set_volume(vol);
        self.dsp.process_frames(out_slice);

        // 5. Update lock-free visualizer snapshot for non-blocking telemetry query
        if self.visualizer_enabled.load(Ordering::Relaxed) {
            let vis = self.dsp.visualizer_data();
            self.visualizer_seqlock.write(|v| *v = vis);
        }
    }

    #[inline]
    pub fn on_device_notification(&self, notification_type: i32) {
        if let Some(ref cb) = self.notification_callback {
            cb(notification_type);
        }
    }
}
