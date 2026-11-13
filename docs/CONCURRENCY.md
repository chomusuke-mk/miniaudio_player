# Concurrency Validation, Sleep Elimination & Chaos Stress Report (`CONCURRENCY.md`)

> **Status:** Complete — Sleep Audit, Production Fixes & Massive Concurrency Stress Validation Verified.
> **Scope:** Cross-boundary verification across Dart (`lib/src/` + `test/`), Flutter Rust Bridge (FRB), and native Rust Tri-Plane architecture (`rust/src/` + `test/rust/`).
> **Core Principle:** Blind `Future.delayed(...)` and `thread::sleep(...)` calls mask race conditions, state-sync lag, and lock contention. Removing unnecessary sleeps forces tests to validate genuine causality and atomic state-visibility guarantees.

---

## 1. Objectives

1. **Audit & Eliminate Artificial Sleeps:** Inventory all `Future.delayed` / `Future<void>.delayed` (`171` occurrences across `22` Dart test files) and `sleep(` (`15` occurrences across `5` Rust test files) calls, classify each by necessity, and replace blind sync sleeps and polling loops with direct post-`await` assertions or deterministic reactive/condition-variable waiters.
2. **Surface & Fix Exposed Races:** Any test failure revealed after removing a blind sleep is treated as a real synchronization defect in Rust (`rust/src/api/player.rs`, `ControlCoordinator`, `EventReporter`, `EngineUiSnapshots`, `DecoderWorker`, `AudioSourceCore`, `SoundBuffer`) or Dart (`PlayerAction`, `PlayerState`, `MiniaudioPlayer`) and fixed cleanly—never masked by restoring the sleep.
3. **Massive Concurrency & Chaos Stress Matrices:** Add comprehensive Rust ([massive_concurrency_stress_test.rs](file:///mnt/Proyectos/miniaudio_player/test/rust/massive_concurrency_stress_test.rs)) and Dart ([massive_concurrency_stress_test.dart](file:///mnt/Proyectos/miniaudio_player/test/massive_concurrency_stress_test.dart)) test suites covering high-thread contention, chaotic state transitions, mid-open interruptions, error injection, event ordering, DSP/SFX/recording storms, and lifecycle churn.

---

## 2. Baseline Inventory (Pre-Refactor)

Verified baseline before concurrency audit edits:
- **Rust unit/integration suite:** `72/72` passed across `9` test binaries (`0` failures, `0` ignored, `0` warnings).
- **Static analysis:** `dart analyze` (`No issues found!`).
- **Flutter suite:** `285/285` passed (`flutter test -j 1`).

### 2.1 Classification Taxonomy

| Category | Meaning | Action |
| :--- | :--- | :--- |
| **A — Blind Post-Action Sleep** | `Future.delayed` / `thread::sleep` right after an awaited call before asserting `state` or `stream` effects. | **Remove completely**; assert state directly (or `drainBroadcastStreams` strictly for async Dart `StreamController` delivery). |
| **B — Polling Sleep Loop** | `while/for` loop calling `Future.delayed(10..50ms)` or `thread::sleep(2..10ms)` waiting for a reactive signal. | **Replace** with `awaitStateOrStream` / `performAndAwaitStream` in Dart or `Condvar`/atomic event waiters in Rust. |
| **C — Arbitrary Time-Progression Wait** | Fixed `Future.delayed(150..2200ms)` waiting for playback position, EOF, recording capture, or FFT energy. | **Replace** with reactive stream gates (`waitForAudioProgress`, `waitForRecordingProgress`, `playbackState.isStopped`, `visualizer.rms > 0`). |
| **D — Intentional Physical/Network Simulation** | Intentional HTTP tarpit server stall, external OS/hardware capture stall simulation, or intentional steady-state window where no completion event can exist. | **Audit & minimize**; retain only where strictly necessary and document rationale inline. |

### 2.2 Dart Test Sleep Inventory (`171` baseline -> `1` Category D across `26` Dart test files)

| Test File | Baseline `Future.delayed` Count | Remaining | Notes |
| :--- | :---: | :---: | :--- |
| `test/engine/miniaudio_engine_fsm_test.dart` | 28 | **0** | Removed 6 `tearDown` sleeps; replaced polls & fixed waits with `awaitStateOrStream`, `waitForAudioProgress`, and `drainBroadcastStreams`. |
| `test/uri_playback_test.dart` | 27 | **0** | Replaced with direct post-`await` assertions & `waitForAudioProgress`. |
| `test/engine/miniaudio_engine_queue_and_infinite_mix_test.dart` | 18 | **0** | Replaced post-mutation waits with `awaitStateOrStream`, `performAndAwaitStream`, and direct post-`await` assertions. |
| `test/engine/phase4_sinks_recording_and_ducking_test.dart` | 18 | **0** | Replaced post-action waits with direct assertions & `waitForRecordingProgress` (surfaced real missing `RecordedDuration` Rust telemetry bug). |
| `test/local_formats_test.dart` | 18 | **0** | Surfaced `PlaybackState` vs `IsPlaying` cross-port tearing race; replaced all sleeps with `awaitStateOrStream` & direct assertions. |
| `test/pause_on_device_change_test.dart` | 13 | **0** | Replaced polls & config sleeps with `performAndAwaitStream`, `drainBroadcastStreams`, and `waitForAudioProgress`. |
| `test/engine/miniaudio_engine_network_and_dsp_test.dart` | 8 | **0** | Replaced with `awaitStateOrStream`, `waitForAudioProgress`, and direct assertions. |
| `test/tripartite_buffer_metabytes_test.dart` | 8 | **0** | Replaced with `waitForAudioProgress`, `awaitStateOrStream`, and reactive ICY metadata stream `Completer`s. |
| `test/visualizer_test.dart` | 7 | **0** | Replaced with `awaitStateOrStream` & `drainBroadcastStreams`. |
| `test/dsp_chain_test.dart` | 5 | **0** | Replaced with `waitForAudioProgress`, `awaitStateOrStream`, `performAndAwaitStream`, and `drainBroadcastStreams`. |
| `test/buffer_and_codec_test.dart` | 4 | **0** | Removed all 4 post-`play()` sleeps; verified immediate snapshot state. |
| `test/skip_silence_test.dart` | 4 | **0** | Replaced with `drainBroadcastStreams` & `waitForAudioProgress`. |
| `test/miniaudio_player_test.dart` | 3 | **0** | Replaced with `drainBroadcastStreams` & `waitForAudioProgress`. |
| `test/replay_gain_test.dart` | 2 | **0** | Replaced both 10ms poll loops with `awaitStateOrStream`. |
| `test/hls_test.dart` | 2 | **0** | Replaced 600ms waits with `awaitStateOrStream` & `waitForAudioProgress`. |
| `test/custom_byte_provider_test.dart` | 2 | **0** | Removed 50ms sleep; replaced 150ms sleep with `waitForAudioProgress`. |
| `test/device_diagnostics_logging_test.dart` | 2 | **0** | Removed both 50ms post-action sleeps. |
| `test/engine/tri_plane_isolation_stress_test.dart` | 2 | **1 (Cat D)** | Line 325 120ms wait replaced with `waitForRecordingProgress`; line 100 retains 6s intentional upstream tarpit stall for abort validation. |
| `test/engine/miniaudio_engine_buffer_parity_test.dart` | 1 | **0** | Replaced 50ms sleep with `drainBroadcastStreams()`. |
| `test/game_audio_voice_pool_test.dart` | 1 | **0** | Removed 20ms sleep after `targetVoice.stop()`. |
| `test/monotonic_queue_buffer_effects_test.dart` | 1 | **0** | Removed 20ms sleep after `reorderByIds`. |
| `test/metadata_and_audio_info_test.dart` | 1 | **0** | Replaced 20ms poll loop with `awaitStateOrStream`. |
| Other `4` Dart suites (`logging_test.dart`, `rapid_queue_400_tracks_and_seek_preemption_test.dart`, `spatial_doppler_test.dart`, `massive_concurrency_stress_test.dart`) | 0 | **0** | Verified `0` `.delayed` calls; [massive_concurrency_stress_test.dart](file:///mnt/Proyectos/miniaudio_player/test/massive_concurrency_stress_test.dart) uses `Completer`-based HTTP/stream gates and reactive `awaitStateOrStream` waiters only. |

### 2.3 Rust Test Sleep Inventory (`15` baseline -> `4` Category D across `5` files)

| Test File | Baseline `sleep(` Count | Remaining | Notes |
| :--- | :---: | :---: | :--- |
| `test/rust/tri_plane_stress_test.rs` | 7 | **3 (Cat D)** | Removed blind 120ms recording, 30ms abort, 220ms crossfade settles (`wait_until` on snapshots/atomics) & 2ms render spin (`yield_now`). Retained Cat D: 2ms non-blocking TCP accept backoff (L149), 10ms tarpit slice (L200), 5ms bounded `wait_until` backoff (L264). |
| `test/rust/telemetry_event_deduplication_test.rs` | 5 | **0** | Removed all 5 blind sleeps; added `Condvar`-synchronized `TelemetryDispatcher` position deduplication test. |
| `test/rust/sync_concurrency_test.rs` | 1 | **0** | Removed 50ms thread sleep. |
| `test/rust/buffer_and_source_test.rs` | 1 | **1 (Cat D)** | Reduced 20ms -> 5ms `Condvar` park slack in backpressure test. |
| `test/rust/core_and_lifecycle_test.rs` | 1 | **0** | Removed 50ms sleep before `recorder.stop()` (`LiveRecorder::stop` drains `rtrb` deterministically). |

---

## 3. Implemented Massive Concurrency & Chaos Stress Suites (Zero Blind Sleeps)

### 3.1 Native Rust Stress Suite ([massive_concurrency_stress_test.rs](file:///mnt/Proyectos/miniaudio_player/test/rust/massive_concurrency_stress_test.rs) — `7/7` passing, `0` `sleep(` calls)
1. `scenario_1_16_thread_control_queue_navigation_chaos_matrix`: 16 concurrent worker threads executing `500+` mixed queue mutations, navigation ops, seeks, and loop/shuffle flips across valid local WAV/MP3/FLAC/Opus/AAC fixtures, missing paths, HTTP `404`/`500`/tarpit endpoints via `ChaosHttpServer`, and `CustomDartByteSource`, verifying bounds invariants and zero deadlocks.
2. `scenario_2_high_frequency_dsp_storm_during_decode_seek_crossfade`: `1000+` rapid concurrent DSP updates (`volume`, `rate`, `pitch`, `balance`, `mono`, 10-band `equalizer`, `crossfeed`, `spatializer`, `doppler`, `reverb`, `limiter`, `replay_gain`, `silence_config`) while tracks decode, seek, and crossfade (`0` NaNs/Infs, bounded latency).
3. `scenario_3_massive_sfx_polyphony_and_lru_eviction_storm`: `64`-voice polyphonic triggering under tight RAM LRU eviction budget, mixed catalog hot-swaps, looping SFX wraparound boundary regression checks (`SoundBuffer::resolve_lerp_indices` / `sample_stereo_lerp`), per-voice modulation, and `stop_all_effects`.
4. `scenario_4_adversarial_custom_source_stream_session_and_offline_analysis`: Out-of-order byte chunks, overlapping seek offsets, mid-read `abort_all()`, and concurrent drop inversions across `CustomDartByteSource`, `StreamSession`, and offline analysis.
5. `scenario_5_hardware_routing_capture_ducking_and_mid_crossfade_recording`: Concurrent output/input topology changes (`set_outputs`, `add_output`, `remove_output`, `set_inputs`, `configure_input`) paired with live mid-crossfade WAV `start_recording`/`stop_recording`.
6. `scenario_6_event_reporter_and_ui_snapshots_ordering_coherence`: Multi-publisher contention stress verifying `EventReporter` atomic track-transition ordering and `EngineUiSnapshots` coherence.
7. `scenario_7_rapid_lifecycle_churn_25_cycles`: `25` consecutive player creation -> multi-plane chaos -> immediate `dispose()` cycles verifying deterministic thread shutdown without leaks or panics.

### 3.2 Dart <-> FRB <-> Rust Stress Suite ([massive_concurrency_stress_test.dart](file:///mnt/Proyectos/miniaudio_player/test/massive_concurrency_stress_test.dart) — `5/5` passing, `0` `.delayed` calls)
1. **Matrix 1 (Multi-Format Instant State Consistency & Error Matrix):** `WAV`, `MP3`, `FLAC`, `Opus`, `AAC`, HTTP, `CustomByteProvider`, missing files, and HTTP error sources verified immediately post-`await`.
2. **Matrix 2 (Multi-Lane `Future.wait` Storm):** Concurrent queue edits, transport/DSP mutations, SFX triggers, active stream listeners, and continuous invariant checks (`assertPlayerInvariants`) while playing and switching sources.
3. **Matrix 3 (Adversarial Network & CustomByteProvider Cancellation / Recovery):** Tarpits, HTTP `404`/`500`, truncated transfers, initial and mid-stream stalled `_ChaosCustomByteProvider` preempted by `pause`, `stop`, `setQueue`, `next`, `removeAt`, and `clearQueue` (`< 50ms` RT lane `stop` latency), followed by clean playback recovery.
4. **Matrix 4 (Seeded 250-Step Chaotic Markov Fuzz Matrix):** Deterministic PRNG stepping across queue edits, navigation, seeks, crossfades, shuffle, loop modes, SFX, DSP, and periodic WAV recording with structural invariants verified after every step and on reactive listeners.
5. **Matrix 5 (Concurrent Lifecycle `dispose()` Under Active Multi-Lane Load):** `5` rapid cycles of `dispose()` while HTTP tarpits, stalled `CustomByteProvider` reads, looping SFX, and active WAV recording are running simultaneously.

---

## 4. Production Concurrency & State-Sync Bugs Uncovered & Fixed

Every sleep-elimination failure and stress-suite panic/hang was traced to a real production defect and resolved in Rust or Dart:

1. **Cross-Thread `EventReporter` Event Reordering ([player.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/api/player.rs)):**
   Unified deduplication and sink delivery under `EventReporter::sink_state` via `emit_batch` and `reset_and_emit_batch` so multi-threaded emitters cannot reorder track-transition batches against background telemetry.
2. **`PlaybackState` vs `IsPlaying` Cross-Port Tearing ([player.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/api/player.rs), [miniaudio_player.dart](file:///mnt/Proyectos/miniaudio_player/lib/src/api/miniaudio_player.dart)):**
   Synchronized `state._playbackState` / `state._isPlaying` derivation and atomic Rust event batch emission so pausing/stopping/playing never leaves transient contradictory booleans in Dart state or streams.
3. **Missing `RecordedDuration` Live Telemetry ([recording.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/core/recording.rs), [engine_actor.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/core/engine_actor.rs), [player.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/api/player.rs)):**
   Exposed wait-free `recorded_duration_ms` through `EngineUiSnapshots` and emitted `RustPlayerEvent::RecordedDuration` during active recording so callers do not need fixed sleeps to observe capture progress.
4. **Looping SFX Wraparound Panic (`SIGABRT`) in `map-engine-clock` ([dsp/voice_pool.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/dsp/voice_pool.rs), [core/voice_pool.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/core/voice_pool.rs)):**
   `core/voice_pool.rs` wrapped `cursor_frame` before recomputing interpolation indices (`f0`/`f1`/`frac`) and `dsp/voice_pool.rs` dropped a sample per wrap. Unified both renderers on shared `SoundBuffer::resolve_lerp_indices` and bounds-clamped `SoundBuffer::sample_stereo_lerp` (surfaced by Dart Matrix 5).
5. **10-Second `map-engine-clock` Freeze in `AudioSourceCore::stop()` Behind Stalled `CustomDartByteSource` ([dual_source.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/core/dual_source.rs), [control_coordinator.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/core/control_coordinator.rs)):**
   `DecoderWorker` held `self.engine` mutex during blocking `CustomDartByteSource::read`, while `AudioSourceCore::stop()` failed to abort `custom_source_handle` and locked `&self.engine`. Added lock-free `engine_loaded: Arc<AtomicBool>`, aborted `custom_source_handle` inside `AudioSourceCore::stop()`, and added `custom_registry.abort_all()` to `ControlCoordinator::stop()` / `clear_queue(false)` (surfaced by Dart Matrix 3; mid-stream `stop()` dropped from `10000ms` timeout to `< 50ms`).
6. **Queue / `currentIndex` / `currentItem` Tearing Across Dart & Rust ([player_state.dart](file:///mnt/Proyectos/miniaudio_player/lib/src/api/player_state.dart), [miniaudio_player.dart](file:///mnt/Proyectos/miniaudio_player/lib/src/api/miniaudio_player.dart), [player_action.dart](file:///mnt/Proyectos/miniaudio_player/lib/src/api/player_action.dart), [player.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/api/player.rs)):**
   Derived `PlayerState.currentItem` / `currentData` directly from `_queue` and `_currentIndex`, bounds-checked `CurrentIndex` events against `state.queue.length`, updated `_currentIndex` coherently on optimistic mutations, and batched queue + index emissions (`emit_queue_and_index`) in Rust (surfaced by Dart Matrix 2).
7. **`DecoderWorker::handle_pending_seek` Stale-Seek Position Overwrite ([dual_source.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/core/dual_source.rs)):**
   During rapid sequential seeks (e.g., `seek(2000)` -> `seek(4000)` -> `seek(0)` on `cbr_noxing.mp3`), an in-flight linear MP3 seek for `2000ms` finished after newer seeks and overwrote `pos_ms`/`pos_frames` back to `2000`. Replaced single-value `seek_req` pop with atomic `seek_packed` generation tagging and `seek_counter` / `open_generation` superseding checks before and after `eng.seek_ms(...)`.
8. **`map-telemetry-monitor` TOCTOU Overwrite & Initial Constructor `setQueue`/`ReplayGain` Race ([engine_actor.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/core/engine_actor.rs), [player.rs](file:///mnt/Proyectos/miniaudio_player/rust/src/api/player.rs), [player_action.dart](file:///mnt/Proyectos/miniaudio_player/lib/src/api/player_action.dart), [miniaudio_player.dart](file:///mnt/Proyectos/miniaudio_player/lib/src/api/miniaudio_player.dart)):**
   Added `EngineUiSnapshots::pub_seq` even/odd publish sequence fencing (`begin_consistent_read` / `is_consistent_since`) and `EventReporter::emit_snapshot_tick` so `map-telemetry-monitor` cannot commit stale snapshots after a newer synchronous action has run `engine.exec()`, and synchronized `setReplayGain` / `setDefaultReplayGain` / `setReplayGainMode` with constructor `_initialQueueFuture` so fire-and-forget initial `setQueue` cannot race or reset immediately configured `ReplayGain` state.

---

## 5. Final Verification Ledger

All checks below ran after the final code edit with zero compiler/analyzer warnings and zero test failures:

- **Rust Test Suite (`cargo test --manifest-path rust/Cargo.toml`):** **`80/80` passed** (`0` failed, `0` ignored, `0` warnings across `10` integration test binaries; `0` lib unit tests):
  - `benchmark_test`: `6/6`
  - `buffer_and_source_test`: `14/14`
  - `core_and_lifecycle_test`: `12/12`
  - `decoder_and_formats_test`: `8/8`
  - `dsp_and_spatial_test`: `10/10`
  - `hls_and_crypto_test`: `5/5`
  - `massive_concurrency_stress_test`: `7/7`
  - `sync_concurrency_test`: `6/6`
  - `telemetry_event_deduplication_test`: `4/4`
  - `tri_plane_stress_test`: `8/8`
- **Static Analysis (`dart analyze`):** `No issues found!`
- **Full Flutter Suite (`flutter test -j 1`):** **`290/290` passed** (`0` failed, `0` skipped, including `5/5` Dart massive stress matrices and zero blind `.delayed` waits outside the single documented Category D tarpit hold).
- **Repeated Anti-Flake Verification:**
  - `test/rust/massive_concurrency_stress_test.rs`: `7/7` passed x `3` consecutive runs.
  - `test/massive_concurrency_stress_test.dart`: `5/5` passed x `3` consecutive runs.
  - `test/dsp_chain_test.dart` + `test/miniaudio_player_test.dart`: `31/31` passed x `3` consecutive sequential runs (`0` flakes after Step 2 fixes).
