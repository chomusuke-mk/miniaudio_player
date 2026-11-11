# Auditoría Integral y Limpieza de Código en Rust / C

Este documento registra la auditoría exhaustiva, función por función y método por método, de todos los archivos dentro del directorio `rust/` (excluyendo el archivo externo `miniaudio.h` y archivos generados automáticamente por `flutter_rust_bridge` como `frb_generated.rs`).

## Criterios de Evaluación
1. **RemoveDeadCode**: Identificación y eliminación definitiva de funciones huérfanas, métodos no invocados, structs/enums sin uso y wrappers residuales del código en C/Rust anterior.
2. **Documented**: Presencia de documentación exhaustiva sobre qué es y qué hace cada componente, struct, función y método (`///` en Rust / `/** */` en C).
3. **Write in english**: Toda la documentación, comentarios explicativos, nombres de identificadores y mensajes de error internos deben estar redactados en inglés idiomático y profesional.

---

## Tabla de Estado de Archivos

| # | Archivo | RemoveDeadCode | Documented | Write in English | Estado General |
|---|---|:---:|:---:|:---:|:---:|
| 1 | `rust/.cargo/config.toml` | Limpio | Sí | Sí | Completado |
| 2 | `rust/.gitignore` | Limpio | Sí | Sí | Completado |
| 3 | `rust/Cargo.toml` | Removido (`atomic`) | Sí | Sí | Completado |
| 4 | `rust/build.rs` | Limpio | Sí | Sí | Completado |
| 5 | `rust/c_src/miniaudio_device_bridge.h` | Limpio | Sí | Sí | Completado |
| 6 | `rust/c_src/miniaudio_device_bridge.c` | Limpio | Sí | Sí | Completado |
| 7 | `rust/src/lib.rs` | Limpio | Sí | Sí | Completado |
| 8 | `rust/src/bridge/mod.rs` | Limpio | Sí | Sí | Completado |
| 9 | `rust/src/bridge/ffi.rs` | Limpio | Sí | Sí | Completado |
| 10 | `rust/src/api/mod.rs` | Limpio | Sí | Sí | Completado |
| 11 | `rust/src/api/types.rs` | Removido (`RustEngineEvent`) | Sí | Sí | Completado |
| 12 | `rust/src/api/player.rs` | Limpio | Sí | Sí | Completado |
| 13 | `rust/src/buffer/mod.rs` | Limpio | Sí | Sí | Completado |
| 14 | `rust/src/buffer/source.rs` | Limpio | Sí | Sí | Completado |
| 15 | `rust/src/buffer/stream_reader.rs` | Limpio | Sí | Sí | Completado |
| 16 | `rust/src/buffer/tripartite.rs` | Removido (`is_starving`, `is_eof_and_exhausted`, `set_buffering`, `audio_end`) | Sí | Sí | Completado |
| 17 | `rust/src/sync/mod.rs` | Limpio | Sí | Sí | Completado |
| 18 | `rust/src/sync/ring_buffer.rs` | Limpio | Sí | Sí | Completado |
| 19 | `rust/src/sync/seqlock.rs` | Limpio | Sí | Sí | Completado |
| 20 | `rust/src/sync/telemetry.rs` | Limpio | Sí | Sí | Completado |
| 21 | `rust/src/decoder/mod.rs` | Limpio | Sí | Sí | Completado |
| 22 | `rust/src/decoder/sniffer.rs` | Removido (`BoundaryInfo::reset`) | Sí | Sí | Completado |
| 23 | `rust/src/decoder/symphonia_engine.rs` | Limpio | Sí | Sí | Completado |
| 24 | `rust/src/decoder/extended_pcm.rs` | Limpio | Sí | Sí | Completado |
| 25 | `rust/src/decoder/opus_decoder.rs` | Limpio | Sí | Sí | Completado |
| 26 | `rust/src/decoder/ape.rs` | Limpio | Sí | Sí | Completado |
| 27 | `rust/src/decoder/dsf.rs` | Limpio | Sí | Sí | Completado |
| 28 | `rust/src/decoder/wavpack.rs` | Limpio | Sí | Sí | Completado |
| 29 | `rust/src/metadata/mod.rs` | Limpio | Sí | Sí | Completado |
| 30 | `rust/src/hls/mod.rs` | Limpio | Sí | Sí | Completado |
| 31 | `rust/src/hls/crypto.rs` | Limpio | Sí | Sí | Completado |
| 32 | `rust/src/hls/m3u8_parser.rs` | Limpio | Sí | Sí | Completado |
| 33 | `rust/src/hls/mpegts.rs` | Limpio | Sí | Sí | Completado |
| 34 | `rust/src/dsp/mod.rs` | Limpio | Sí | Sí | Completado |
| 35 | `rust/src/dsp/biquad.rs` | Limpio | Sí | Sí | Completado |
| 36 | `rust/src/dsp/channel_matrix.rs` | Limpio | Sí | Sí | Completado |
| 37 | `rust/src/dsp/crossfeed.rs` | Limpio | Sí | Sí | Completado |
| 38 | `rust/src/dsp/ducking.rs` | Limpio | Sí | Sí | Completado |
| 39 | `rust/src/dsp/equalizer.rs` | Limpio | Sí | Sí | Completado |
| 40 | `rust/src/dsp/limiter.rs` | Limpio | Sí | Sí | Completado |
| 41 | `rust/src/dsp/resampler.rs` | Limpio | Sí | Sí | Completado |
| 42 | `rust/src/dsp/reverb.rs` | Limpio | Sí | Sí | Completado |
| 43 | `rust/src/dsp/silence.rs` | Limpio | Sí | Sí | Completado |
| 44 | `rust/src/dsp/sonic.rs` | Limpio | Sí | Sí | Completado |
| 45 | `rust/src/dsp/spatial.rs` | Limpio | Sí | Sí | Completado |
| 46 | `rust/src/dsp/timestretch.rs` | Limpio | Sí | Sí | Completado |
| 47 | `rust/src/dsp/visualizer.rs` | Limpio (eliminado `data()`) | Sí | Sí | Completado |
| 48 | `rust/src/dsp/voice_pool.rs` | Limpio | Sí | Sí | Completado |
| 49 | `rust/src/dsp/chain.rs` | Limpio | Sí | Sí | Completado |
| 50 | `rust/src/dsp/analysis.rs` | Limpio | Sí | Sí | Completado |
| 51 | `rust/src/core/mod.rs` | Limpio | Sí | Sí | Completado |
| 52 | `rust/src/core/types.rs` | Limpio | Sí | Sí | Completado |
| 53 | `rust/src/core/typestate.rs` | Limpio | Sí | Sí | Completado |
| 54 | `rust/src/core/config.rs` | Limpio | Sí | Sí | Completado |
| 55 | `rust/src/core/simd_mixer.rs` | Limpio | Sí | Sí | Completado |
| 56 | `rust/src/core/capture.rs` | Limpio | Sí | Sí | Completado |
| 57 | `rust/src/core/recording.rs` | Limpio | Sí | Sí | Completado |
| 58 | `rust/src/core/dsp_processor.rs` | Limpio | Sí | Sí | Completado |
| 59 | `rust/src/core/voice_pool.rs` | Limpio | Sí | Sí | Completado |
| 60 | `rust/src/core/renderer.rs` | Limpio | Sí | Sí | Completado |
| 61 | `rust/src/core/dual_source.rs` | Limpio (removido `DecoderWorker::deck_id`) | Sí | Sí | Completado |
| 62 | `rust/src/core/output_manager.rs` | Limpio | Sí | Sí | Completado |
| 63 | `rust/src/core/input_manager.rs` | Limpio | Sí | Sí | Completado |
| 64 | `rust/src/core/effects_manager.rs` | Limpio | Sí | Sí | Completado |
| 65 | `rust/src/core/music_manager.rs` | Limpio | Sí | Sí | Completado |
| 66 | `rust/src/core/miniaudio_player.rs` | Limpio | Sí | Sí | Completado |

---

## Bitácora Detallada de Auditoría y Limpieza por Archivo

Esta sección registra la revisión minuciosa elemento por elemento, indicando las funciones evaluadas, código muerto eliminado, mejoras de documentación y correcciones de idioma.

### 1. `rust/.cargo/config.toml`
- **Revisión**: Flags de compilación y enlace (`--gc-sections`, `--as-needed`, `-O1`, `force-unwind-tables=no`) y alias de cargo.
- **RemoveDeadCode**: Sin configuraciones muertas.
- **Documented**: Se agregaron comentarios explicativos en inglés para cada sección de flags.
- **Write in English**: 100% en inglés.

### 2. `rust/.gitignore`
- **Revisión**: Reglas de exclusión de artefactos locales (`/target`, `Cargo.lock`).
- **RemoveDeadCode**: Sin reglas muertas.
- **Documented**: Se agregaron comentarios explicativos en inglés.
- **Write in English**: 100% en inglés.

### 3. `rust/Cargo.toml`
- **Revisión**: Dependencias y features de decodificación, DSP, HLS, multithreading y profiles de release/test.
- **RemoveDeadCode**: Identificada y removida dependencia huérfana `atomic = "0.6"` (todas las operaciones atómicas en el codebase emplean de forma nativa y estándar `std::sync::atomic`).
- **Documented**: Cada sección y grupo de librerías cuenta con encabezados descriptivos.
- **Write in English**: Se tradujeron todos los comentarios de dependencias que estaban en español al inglés.

### 4. `rust/build.rs`
- **Revisión**: Script de compilación de C (`miniaudio_device_bridge.c`), flags de compilación de secciones `-ffunction-sections`, `-fdata-sections`, `-fvisibility=hidden` y flags de enlace según SO destino.
- **RemoveDeadCode**: Código limpio y mínimo.
- **Documented**: Se documentó el propósito del script a nivel de módulo con docstrings Rust (`//!`).
- **Write in English**: 100% en inglés.

### 5. `rust/c_src/miniaudio_device_bridge.h`
- **Revisión**: Declaraciones de contexto `map_device_context_t`, `map_device_info_t`, callbacks externos exportados por Rust (`rust_render_pcm_frames`, `rust_capture_pcm_frames`, `rust_on_device_notification`), y API C de ciclo de vida (`map_device_create`, `map_capture_device_create`, `map_device_start`, `map_device_stop`, `map_device_destroy`, `map_device_enumerate_*`, etc.).
- **RemoveDeadCode**: Todas las funciones declaradas son validadas por `test/c/device_bridge_test.c` y consumidas por `bridge/ffi.rs`.
- **Documented**: Se redactó documentación estilo Doxygen completa en inglés para cada struct, parámetro de función y código de retorno.
- **Write in English**: Se eliminaron y tradujeron todos los comentarios que se encontraban en español.

### 6. `rust/c_src/miniaudio_device_bridge.c`
- **Revisión**: Implementación de la capa C para inicialización de dispositivos `miniaudio`, hooks defensivos para backend AAudio en Android, callbacks de datos/notificaciones, y funciones de enumeración segura.
- **RemoveDeadCode**: Código limpio; las rutinas manejan defensivamente el ciclo de vida de `ma_device` y `ma_context`.
- **Documented**: Archivo completamente documentado con especificación C99/C11.
- **Write in English**: Se tradujeron todos los comentarios internos (incluyendo la cabecera, manejo de hooks y sincronización) del español al inglés.

### 7. `rust/src/lib.rs`
- **Revisión**: Raíz de la librería Rust, declaración de submódulos (`api`, `bridge`, `buffer`, `core`, `decoder`, `dsp`, `hls`, `metadata`, `sync`), re-exportaciones públicas, variable estática `LOG_LEVEL` y macro de diagnóstico `map_log!`.
- **RemoveDeadCode**: Todas las re-exportaciones corresponden a tipos públicos consumidos activamente por el reproductor, tests o la API pública.
- **Documented**: Documentación a nivel de módulo con resumen exhaustivo de capacidades y subsistemas.
- **Write in English**: 100% en inglés.

### 8. `rust/src/bridge/mod.rs`
- **Revisión**: Submódulo puente FFI.
- **RemoveDeadCode**: Se corrigió el docstring del módulo que aún mencionaba la librería legacy `sonic` en C (la cual fue reemplazada previamente por la implementación nativa en Rust).
- **Documented**: Documentado con docstring Rust.
- **Write in English**: 100% en inglés.

### 9. `rust/src/bridge/ffi.rs`
- **Revisión**: Tipos opacos de contexto de dispositivo (`MapDeviceContext`), constantes de error canónicas (`MAP_SUCCESS`, `MAP_ERROR_*`), estructuras C de bajo nivel (`MapDeviceInfo`, `MapAllDevices`, `MiniaudioBufferedRange`), declaraciones `extern "C"`, runtime WebAudio WASM para navegador (`WasmWorkerRuntime`), trampolines C (`rust_render_pcm_frames`, `rust_capture_pcm_frames`, `rust_on_device_notification`) y wrappers seguros RAII (`safe_enumerate_*`).
- **RemoveDeadCode**: Todo el código se encuentra activo y cubre tanto plataformas nativas (Linux, macOS, Windows, Android, iOS) como WebAssembly.
- **Documented**: Se agregaron docstrings `//!` a nivel de módulo y se estandarizaron comentarios a estilo Rust doc.
- **Write in English**: 100% en inglés.

### 10. `rust/src/api/mod.rs`
- **Revisión**: Declaración de submódulos `player` y `types`, y definición de `FLUTTER_RUST_BRIDGE_HANDLER` para runtime nativo y executor para Web Workers en WebAssembly (`WasmWorkerExecutor`, `DirectWorkerPool`).
- **RemoveDeadCode**: Código activo y necesario para el bridge de Flutter.
- **Documented**: Documentado con docstrings de módulo y estructuras en inglés.
- **Write in English**: 100% en inglés.

### 11. `rust/src/api/types.rs`
- **Revisión**: Modelos de datos compartidos entre Flutter y Rust (`RustAudioSource`, `RustAudioInfo`, `RustAudioMetadata`, `RustPlayerEvent`, `RustAnalysisConfig`, `RustAudioAnalysisResult`, `RustCrossfeedConfig`, etc.).
- **RemoveDeadCode**: Se identificó y eliminó el enum huérfano `RustEngineEvent` (86 líneas de código muerto que nunca fue consumido ni conectado, ignorado por FRB debido a que todos los eventos de producción usan `RustPlayerEvent`).
- **Documented**: 100% documentado con docstrings Rust (`///`) en todas las estructuras, campos y enums.
- **Write in English**: 100% en inglés.

### 12. `rust/src/api/player.rs`
- **Revisión**: Métodos de control y orquestación del reproductor (`RustMiniaudioPlayer`), reportero de eventos y filtrado de telemetría (`TelemetryFilter`, `EventReporter`), hilos en segundo plano (watcher de dispositivos hot-plug, monitor de telemetría a 60 FPS, reloj de renderizado PCM), métodos de transporte, modulación DSP, pool de efectos SFX, matriz de múltiples salidas/entradas y funciones de análisis estático (`set_log_level`, `analyze_audio_source`, `analyze_audio_source_sync`).
- **RemoveDeadCode**: Todos los métodos y funciones son consumidos activamente por el cliente Dart/Flutter y cubiertos por los tests.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 13. `rust/src/buffer/mod.rs`
- **Revisión**: Re-exportaciones de subsistemas de buffers: `ByteSource`, `ByteSourceStream`, `CustomByteSourceHandle`, `CustomDartByteSource`, `DartReadRequest`, `FileByteSource`, `MemoryByteSource`, `SourceKind`, `TripartiteByteSource`, `BufferStreamReader`, `BufferError`, `BufferRange`, `BufferState`, `TripartiteBuffer`.
- **RemoveDeadCode**: Todos los tipos exportados son utilizados por decodificadores, dual source o la API.
- **Documented**: Documentado a nivel de módulo con docstrings Rust.
- **Write in English**: 100% en inglés.

### 14. `rust/src/buffer/source.rs`
- **Revisión**: Implementación de fuentes de bytes nativas y puente con Dart: enum `SourceKind`, trait `ByteSource` con probe no destructivo de cola (`probe_tail`), wrapper `ByteSourceStream` para `symphonia::core::io::MediaSource`, fuentes concretas `FileByteSource`, `MemoryByteSource`, `TripartiteByteSource`, y estructura `CustomDartByteSource` con prefetch asíncrono y control mediante `CustomByteSourceHandle`.
- **RemoveDeadCode**: Todos los métodos y tipos se utilizan activamente; sin código muerto.
- **Documented**: Documentado exhaustivamente con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 15. `rust/src/buffer/stream_reader.rs`
- **Revisión**: Adaptador `BufferStreamReader` que implementa `Read`, `Seek` y `MediaSource` sobre el búfer elástico `TripartiteBuffer`, manejando backpressure y detección de bloqueos.
- **RemoveDeadCode**: Todo el código se encuentra activo y consumido por el motor de decodificación.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 16. `rust/src/buffer/tripartite.rs`
- **Revisión**: Búfer elástico de 3 niveles: `HeadSegment` (bytes de cabecera anclados), `TailSegment` (bytes de cola anclados para metadatos/índices), y `RingSegment` (búfer circular deslizante con backpressure), tipos de estado `BufferState`, `BufferRange` y `BufferError`.
- **RemoveDeadCode**: Se identificaron y eliminaron 4 métodos huérfanos sin uso en ningún punto del repositorio: `is_starving`, `is_eof_and_exhausted`, `set_buffering` y el getter redundante `audio_end(&self)`.
- **Documented**: Se añadieron docstrings detallados en inglés (`///`) a todos los métodos públicos e internos (`set_head`, `set_tail`, `probe_tail`, `tail_data`, `set_audio_start`, `set_audio_end`, `set_decoding_audio`, `read_blocking`, `flush`, `seek`, `try_seek_cached`, `mark_eof`, `abort`, `clear_abort`, `get_range`, `meta_version`, `get_meta_bytes`, `copy_meta_bytes`, `set_icy_meta`, `audio_start`, `is_live`, `range_start`, `range_end`, `is_tail_locked`, `is_fully_buffered`, `is_eof`, `head_size`, `ring_capacity`, `total_size`, `create_reader`).
- **Write in English**: 100% en inglés.

### 17. `rust/src/sync/mod.rs`
- **Revisión**: Submódulo de sincronización lock-free y telemetría (`ring_buffer`, `seqlock`, `telemetry`).
- **RemoveDeadCode**: Todas las re-exportaciones son consumidas por el motor de audio, renderers y tests.
- **Documented**: Documentado a nivel de módulo con docstrings Rust en inglés.
- **Write in English**: 100% en inglés.

### 18. `rust/src/sync/ring_buffer.rs`
- **Revisión**: Búfer circular Single-Producer Single-Consumer (SPSC) lock-free para muestras de audio `f32` basado en `rtrb` (`AudioProducer`, `AudioConsumer`, `AudioRingBuffer`).
- **RemoveDeadCode**: Métodos de lectura/escritura por bloques `write_chunk`, `read_chunk`, consulta de slots disponibles y vaciado `clear` 100% activos en renderers y capture.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 19. `rust/src/sync/seqlock.rs`
- **Revisión**: Seqlock con alineación y padding de línea de caché (`CachePaddedSeqlock<T>`) para lecturas libres de bloqueos y sin contención en el hilo de audio en tiempo real.
- **RemoveDeadCode**: Todo el código se encuentra activo y protegido con barreras de memoria atómicas (`Acquire`/`Release`).
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 20. `rust/src/sync/telemetry.rs`
- **Revisión**: Canal y despachador de telemetría reactiva en tiempo real (`TelemetryDispatcher`, `TelemetryEvent`, `MapEvent`, `MapEventData`, `MonotonicInstant`, `monotonic_now_ns`, `EventType`, `BufferedRange`, `DeviceInfo`, `SpatializerData`).
- **RemoveDeadCode**: Todos los tipos de evento, unión de datos FFI y métodos de publicación (`post`, `post_event`, `dispatch`, `stop`) son consumidos activamente por `dual_source.rs`, `output_manager.rs`, `miniaudio_player.rs` y el frontend Flutter.
- **Documented**: 100% documentado con docstrings Rust (`///`) en todas las estructuras, campos y variantes.
- **Write in English**: 100% en inglés.

### 21. `rust/src/decoder/mod.rs`
- **Revisión**: Submódulo raíz de decodificación multiformato (`ape`, `dsf`, `extended_pcm`, `opus_decoder`, `sniffer`, `symphonia_engine`, `wavpack`).
- **RemoveDeadCode**: Todas las exportaciones son consumidas por el motor central o tests.
- **Documented**: Documentado a nivel de módulo con docstrings Rust en inglés.
- **Write in English**: 100% en inglés.

### 22. `rust/src/decoder/sniffer.rs`
- **Revisión**: Sniffer determinista de formatos de audio (`ContainerFormat`, `BoundaryStatus`, `BoundaryInfo`, `FormatSniffer`), detección de límites de cabecera (`detect_head_boundary`), extracción y poda de metadatos de cola ID3v1/APE/Lyrics3 (`detect_tail_boundary`), parser de frames ADTS para archivos buscables (`scan_adts_stream`), y clasificador heurístico de modo de bitrate CBR/VBR (`detect_bitrate_mode`).
- **RemoveDeadCode**: Se identificó y removió el método huérfano `BoundaryInfo::reset` sin invocaciones en el proyecto.
- **Documented**: Se añadieron docstrings en inglés (`///`) a todas las funciones públicas y campos faltantes (`head_has_mpeg_frame`, `bytes_per_frame`, `needed_bytes`, `container_needs_tail_scan`, `detect_head_boundary`, `detect_tail_boundary`, `extract_tail_duration_ms`, `sniff_mp3_stream_info`, `sniff_ogg_vorbis_stream_info`, `sniff_ogg_opus_stream_info`, `sniff_adts_stream_info`, `sniff_stream_info`).
- **Write in English**: 100% en inglés.

### 23. `rust/src/decoder/symphonia_engine.rs`
- **Revisión**: Fachada universal de decodificación basada en Symphonia (`SymphoniaEngine`, `SymphoniaTrackSession`, `EngineBackend`), preconfiguración del registro de códecs con soporte para Opus y AAC (`create_codec_registry`), clasificación de códecs y contenedores, decodificación por paquetes y posicionamiento en milisegundos (`seek_ms`).
- **RemoveDeadCode**: Todo el código se encuentra activo y cubierto por tests de integración.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 24. `rust/src/decoder/extended_pcm.rs`
- **Revisión**: Lector y normalizador de formatos extendidos PCM (`ExtendedPcmReader`, `PcmSampleNormalizer`, `ExtendedPcmProbe`, `WaveFmtSpec`) para contenedores WAV de 64 bits y big-endian (`RF64`, `RIFX`, `W64`), con soporte de 8/16/24/32 bits enteros y 32 bits coma flotante.
- **RemoveDeadCode**: Todo el código se encuentra activo y validado contra fixtures de audio.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 25. `rust/src/decoder/opus_decoder.rs`
- **Revisión**: Re-exportación condicional del adaptador `symphonia_adapter_libopus::OpusDecoder` para plataformas no-WASM.
- **RemoveDeadCode**: Código conciso y activo.
- **Documented**: Documentado a nivel de módulo con docstrings Rust en inglés.
- **Write in English**: 100% en inglés.

### 26. `rust/src/decoder/ape.rs`
- **Revisión**: Decodificador nativo de Monkey's Audio `.ape` (`ApeReader`, `ApeProbe`) basado en la crate `ape-decoder` y normalización a PCM `f32` con `PcmSampleNormalizer`.
- **RemoveDeadCode**: Todo el código está en uso activo.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 27. `rust/src/decoder/dsf.rs`
- **Revisión**: Decodificador y filtro diezmador FIR Blackman-Harris (`DsfReader`, `DsdFirDecimator`, `DsfHeader`, `DsfProbe`) para streams DSD de 1 bit (DSD64: 2.8224 MHz, DSD128: 5.6448 MHz) hacia PCM `f32`.
- **RemoveDeadCode**: Todo el código se encuentra activo y verificado en tests.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 28. `rust/src/decoder/wavpack.rs`
- **Revisión**: Decodificador nativo de WavPack `.wv` (`WavpackReader`, `WavpackStreamParser`, `WavpackProbe`) basado en `wavicle`, con poda determinista de etiquetas de metadatos de cola y normalización flotante `f32`.
- **RemoveDeadCode**: Todo el código está en uso activo.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 29. `rust/src/metadata/mod.rs`
- **Revisión**: Parser y normalizador multiformato de metadatos (`SymphoniaExtractedMeta`, `parse_full_metadata`, `sniff_image_mime`, `parse_icy_stream_block`). Integra parsing de `lofty` (ID3v1, ID3v2, Vorbis Comments, MP4 `ilst`, APEv2, RIFF INFO), parsing binario de capítulos ID3v2 `CHAP`, extractores de metadatos embebidos DSF/RF64/RIFX/W64/BWF, bridging de revisiones de metadatos de Symphonia y metadatos dinámicos ICY de transmisiones Shoutcast/Icecast.
- **RemoveDeadCode**: Todos los métodos y funciones auxiliares son requeridos para la extracción integral de metadatos.
- **Documented**: 100% documentado con docstrings Rust (`///`) en las funciones públicas, estructuras y métodos asociados.
- **Write in English**: 100% en inglés (sin comentarios en español).

### 30. `rust/src/hls/mod.rs`
- **Revisión**: Submódulo raíz del protocolo HTTP Live Streaming (HLS) (`crypto`, `m3u8_parser`, `mpegts`).
- **RemoveDeadCode**: Todas las exportaciones son consumidas por el subsistema dual source y tests.
- **Documented**: Documentado a nivel de módulo con docstrings Rust en inglés.
- **Write in English**: 100% en inglés.

### 31. `rust/src/hls/crypto.rs`
- **Revisión**: Desencriptador AES-128-CBC para segmentos HLS según RFC 8216 (`Aes128SegmentDecryptor`), con derivación de IV mediante secuencia (`iv_from_sequence`), parseo de IV en hexadecimal (`parse_iv_hex`) y soporte tanto para relleno PKCS#7 (`decrypt_segment`) como segmentos no rellenados (`decrypt_segment_no_padding`).
- **RemoveDeadCode**: Todo el código se encuentra activo y cubierto por tests de descifrado criptográfico.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 32. `rust/src/hls/m3u8_parser.rs`
- **Revisión**: Parser determinista de listas de reproducción M3U8 maestras y de medios (`M3u8Parser`, `ParsedHlsPlaylist`, `VariantStreamInfo`, `SegmentInfo`, `EncryptionKeyInfo`) basado en `m3u8_rs`.
- **RemoveDeadCode**: Todas las estructuras y funciones se encuentran activas en el reproductor HLS.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 33. `rust/src/hls/mpegts.rs`
- **Revisión**: Demuxer nativo de MPEG-2 Transport Stream (.ts) para HLS (`MpegTsDemuxer`, `TsDemuxSession`, `TsPacketIterator`, `TsPacket`, `TsAudioCodec`, `MpegTsDemuxResult`), con extracción de streams elementales de audio AAC ADTS/MP3/AC3 y metadatos ID3 sincronizados.
- **RemoveDeadCode**: Todo el pipeline de demuxing está en uso activo.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 34. `rust/src/dsp/mod.rs`
- **Revisión**: Re-exportaciones públicas del pipeline y módulos DSP (`biquad`, `channel_matrix`, `crossfeed`, `ducking`, `equalizer`, `limiter`, `resampler`, `reverb`, `silence`, `sonic`, `spatial`, `timestretch`, `visualizer`, `voice_pool`, `chain`, `analysis`).
- **RemoveDeadCode**: Todas las exportaciones son consumidas por el motor de audio o la API de Flutter.
- **Documented**: Módulo documentado con docstrings Rust a nivel de subsistema.
- **Write in English**: 100% en inglés.

### 35. `rust/src/dsp/biquad.rs`
- **Revisión**: Filtro digital Biquad en Forma Directa II Transpuesta (`BiquadDf2t`) y generador de coeficientes Robert Bristow-Johnson (RBJ Audio EQ Cookbook) para peaking, notch, bandpass, lowpass, highpass, low-shelf y high-shelf.
- **RemoveDeadCode**: Todos los métodos y constructores de filtros están activos y verificados en tests.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 36. `rust/src/dsp/channel_matrix.rs`
- **Revisión**: Procesador matricial estandarizado de canales de audio (`ChannelMatrix`, `SurroundChannelType`) con remezcla y conversión mono, estéreo, quad, 5.1 y 7.1 según norma ITU-R BS.775 con atenuación LFE y surround.
- **RemoveDeadCode**: Todos los conversores matriciales están en uso y verificados en suite de pruebas.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 37. `rust/src/dsp/crossfeed.rs`
- **Revisión**: Filtro de crossfeed estéreo-a-binaural Bauer (`Bs2bCrossfeed`, `CrossfeedConfig`, `Bs2bPreset`) con ecualización de retardo interaural de cabeza (ITD) y atenuación cruzada de frecuencias bajas.
- **RemoveDeadCode**: Todo el código se encuentra activo.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 38. `rust/src/dsp/ducking.rs`
- **Revisión**: Procesador dinámico de auto-ducking con envolvente de seguimiento RMS sidechain (`AutoDucker`, `DuckingParams`).
- **RemoveDeadCode**: Todo el código se encuentra en uso activo.
- **Documented**: Se completaron docstrings en métodos de control e inspección (`set_sample_rate`, `set_params`, `is_ducking`, `current_gain`, `last_rms_db`).
- **Write in English**: 100% en inglés.

### 39. `rust/src/dsp/equalizer.rs`
- **Revisión**: Ecualizador paramétrico gráfico de 10 bandas ISO (`Equalizer`, `PreampStage`, `Iso10BandStage`, `StereoImagingStage`, `EqualizerParams`, `ReplayGainConfig`) con pre-amplificador, ReplayGain, control de balance estereofónico y ensanchador espacial Hafta/stereo-widening.
- **RemoveDeadCode**: Todo el pipeline está en uso.
- **Documented**: Se agregaron docstrings faltantes en las etapas internas (`PreampStage`, `Iso10BandStage`, `StereoImagingStage`).
- **Write in English**: 100% en inglés.

### 40. `rust/src/dsp/limiter.rs`
- **Revisión**: Limitador suave con rodilla paramétrica (`SoftLimiter`) y saturación hiperbólica para prevenir distorsión digital o clipping en picos dinámicos.
- **RemoveDeadCode**: Código activo y verificado.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 41. `rust/src/dsp/resampler.rs`
- **Revisión**: Resampler síncrono/asíncrono de alta fidelidad (`RubatoResampler`, `resample_slice`) basado en la crate `rubato`.
- **RemoveDeadCode**: Todos los métodos y funciones auxiliares se encuentran activos.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 42. `rust/src/dsp/reverb.rs`
- **Revisión**: Emulador de reverberación acústica digital Freeverb (`Freeverb`, `ReverbConfig`, `CombFilter`, `AllpassFilter`) con 8 filtros comb en paralelo y 4 filtros all-pass en cascada por canal estéreo.
- **RemoveDeadCode**: Todo el código se encuentra en uso activo.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 43. `rust/src/dsp/silence.rs`
- **Revisión**: Detector inteligente de silencios en tiempo real (`SilenceDetector`, `SilenceState`) con máquina de estados finitos (Leading, Sound, InSilence, Trailing), umbrales RMS en dB y crossfade de supresión de chasquidos.
- **RemoveDeadCode**: Todos los estados y transiciones FSM están activos.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 44. `rust/src/dsp/sonic.rs`
- **Revisión**: Motor nativo de time-stretching y pitch-shifting en Rust (`SonicStream`) basado en algoritmo PICOLA/WSOLA, permitiendo variación independiente de tasa de reproducción (speed), tono (pitch) y tasa de muestreo.
- **RemoveDeadCode**: Todo el código se encuentra en uso activo.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 45. `rust/src/dsp/spatial.rs`
- **Revisión**: Procesador acústico espacial 3D (`SpatialProcessor`, `SpatialListener`, `SpatialEmitter`, `Vector3`, `DistanceAttenuationModel`, `SoundConeParams`, `SpatialEvaluationResult`) con modelos de atenuación de distancia (Linear, Inverse, Exponential), direccionalidad de conos y cálculo cinemático de efecto Doppler.
- **RemoveDeadCode**: Todos los modelos de atenuación, vectores y evaluadores están activos y verificados en suite de pruebas.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 46. `rust/src/dsp/timestretch.rs`
- **Revisión**: Wrapper de alto nivel `TimeStretchProcessor` y función libre `timestretch_audio` sobre `SonicStream` para ajuste de tempo con conservación de tono original.
- **RemoveDeadCode**: Ambos componentes se encuentran activos.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 47. `rust/src/dsp/visualizer.rs`
- **Revisión**: Analizador visual de espectro de 10 bandas y medidor de energía RMS/Peak (`Visualizer`, `VisualizerData`, `BAND_WEIGHTS`) con ponderación perceptual y envolvente de caída suave de 100 ms.
- **RemoveDeadCode**: Se identificó el método redundante `Visualizer::data(&self)` (con 0 usos, dado que se utiliza exclusivamente `Visualizer::get_data(&self)`). Se procedió a su eliminación completa.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 48. `rust/src/dsp/voice_pool.rs`
- **Revisión**: Pool de 64 voces polifónicas sin asignaciones en tiempo de renderizado (`VoicePool`, `Voice`, `SoundBuffer`, `VoiceStealingPolicy`), con soporte para políticas de Voice Stealing (LowestPriority, Oldest, Quietest, Farthest), rampa anti-click de 5 ms, jitter pseudoaleatorio para disparos únicos y mezcla espacial 3D.
- **RemoveDeadCode**: Todo el código se encuentra en uso activo y verificado en tests unitarios.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 49. `rust/src/dsp/chain.rs`
- **Revisión**: Pipeline integrado de procesamiento de audio en cascada (`DspChain`, `MasterVolumeStage`) enlazando ecualizador de 10 bandas, crossfeed BS2B, reverberación Freeverb, volumen con atenuación de cremallera suave, limitador de picos y analizador visualizador.
- **RemoveDeadCode**: Todo el pipeline se encuentra en uso activo.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 50. `rust/src/dsp/analysis.rs`
- **Revisión**: Pipeline de análisis acústico offline y en streaming de memoria acotada ($O(1)$ RAM) (`Bs1770LoudnessAnalyzer`, `AdaptiveWaveformAccumulator`, `HeadAnalysisInfo`, `analyze_head_info`, `analyze_audio_source`), cálculo de sonoridad integrada LUFS BS.1770-4 con puertas absoluta y relativa, acumulador adaptativo de picos con diezmado dinámico 2:1 y extracción de encabezados.
- **RemoveDeadCode**: Métodos de análisis previamente redundantes unificados y verificados.
- **Documented**: Se completaron docstrings en todas las funciones y métodos públicos (`Bs1770LoudnessAnalyzer::new`, `push_stereo_frame`, `finalize`, `AdaptiveWaveformAccumulator::new`, `push_frame_peak`, `finalize`, y campos de `HeadAnalysisInfo`).
- **Write in English**: 100% en inglés.

### 51. `rust/src/core/mod.rs`
- **Revisión**: Submódulo raíz del subsistema `core` con re-exportaciones de subsistemas, managers y tipos de dominio (`capture`, `config`, `dsp_processor`, `dual_source`, `effects_manager`, `input_manager`, `miniaudio_player`, `music_manager`, `output_manager`, `recording`, `renderer`, `simd_mixer`, `types`, `typestate`, `voice_pool`).
- **RemoveDeadCode**: Todas las re-exportaciones están activas y utilizadas por los puentes FFI y Flutter.
- **Documented**: Documentado con docstrings Rust a nivel de módulo.
- **Write in English**: 100% en inglés.

### 52. `rust/src/core/types.rs`
- **Revisión**: Nuevos tipos fuertemente tipados (`SampleRate`, `Volume`, `Decibels`, `PlayerError`) para eliminar primitive obsession y garantizar invariantes aritméticos.
- **RemoveDeadCode**: Se validó el uso de todos los tipos y métodos constructores/conversores.
- **Documented**: Se agregaron docstrings faltantes en todos los métodos públicos (`get`, `clamp`, `to_decibels`, `from_linear`, `to_linear`).
- **Write in English**: 100% en inglés.

### 53. `rust/src/core/typestate.rs`
- **Revisión**: Arquitectura de ciclo de vida Typestate a nivel de compilador (`Player<Uninitialized>`, `Player<Open<S>>`, `Player<Active<S>>`, `Player<Paused<S>>`, `Player<Stopped<S>>`).
- **RemoveDeadCode**: Todos los estados y transiciones son válidos.
- **Documented**: Se agregaron docstrings faltantes en los métodos accesores de estado (`config`, `is_seekable`, `total_bytes`, `set_volume`, `volume`, `position_ms`, `paused_position_ms`).
- **Write in English**: 100% en inglés.

### 54. `rust/src/core/config.rs`
- **Revisión**: Configuración del hardware de audio (`PlayerConfig`: `sample_rate`, `channels`, `period_size`) con implementación de `Default`.
- **RemoveDeadCode**: Sin código muerto.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 55. `rust/src/core/simd_mixer.rs`
- **Revisión**: Mezclador SIMD vectorizado (`SimdMixer`) con optimizaciones de hardware AVX2/FMA en x86_64, NEON en aarch64 y fallback escalar, junto con saturación soft-knee de techo dinámico. Se derivaron traits estándar (`Clone`, `Copy`, `Default`).
- **RemoveDeadCode**: Todos los paths de aceleración vectorizada y fallback están activos y verificados.
- **Documented**: 100% documentado con docstrings Rust (`///`).
- **Write in English**: 100% en inglés.

### 56. `rust/src/core/capture.rs`
- **Revisión**: Nodo de captura de audio en tiempo real (`DeviceCaptureNode`, `CaptureReceiver`) con cola SPSC libre de bloqueos (`rtrb`), volumen de micrófono y monitoreo directo.
- **RemoveDeadCode**: Todo el código se encuentra en uso activo.
- **Documented**: Se completaron docstrings en todos los métodos de `DeviceCaptureNode` (`new`, `start`, `stop`, `is_capturing`, `set_mic_volume`, `mic_volume`, `set_direct_monitoring`, `is_direct_monitoring`, `monitor_volume`).
- **Write in English**: 100% en inglés.

### 57. `rust/src/core/recording.rs`
- **Revisión**: Grabador en vivo a disco en hilo desacoplado (`LiveRecorder`, `WavSampleWriter`, `WavFormat`, `write_wav_header`, `finalize_wav_header`, `offline_bounce_to_wav`) con soporte para PCM de 16 bits y Float IEEE de 32 bits y retroparcheo de cabeceras RIFF.
- **RemoveDeadCode**: Todo el pipeline de codificación y streaming WAV se encuentra activo.
- **Documented**: Se agregaron docstrings en `finalize_wav_header`, `WavSampleWriter` y métodos de `LiveRecorder`.
- **Write in English**: 100% en inglés.

### 58. `rust/src/core/dsp_processor.rs`
- **Revisión**: Procesador modular reutilizable de efectos DSP (`DspProcessor`) integrando ecualizador de 10 bandas, reverberación Freeverb, ganancia local, balance y conversión mono.
- **RemoveDeadCode**: Todos los métodos y rutas de procesamiento están activos.
- **Documented**: Se completaron docstrings en todos los métodos de modulación de parámetros (`set_sample_rate`, `set_equalizer`, `set_reverb`, `set_preamp`, `set_replay_gain`, `set_balance`, `set_mono`, `set_volume`).
- **Write in English**: 100% en inglés.

### 59. `rust/src/core/voice_pool.rs`
- **Revisión**: Gestor de pool de voces polifónicas en RAM (`VoicePool`, `RegisteredEffect`, `EffectCatalogItem`, `EffectConfig`, `DspRouting`, `EffectSourceType`) con desalojo reactivo LRU ponderado, inmunidad para fuentes de memoria (`SourceWeight = inf`) y efectos fijados (pinned), jitter pseudoaleatorio y enrutamiento DSP dinámico (Inherit, Isolate, Bypass).
- **RemoveDeadCode**: Todo el código se encuentra activo y verificado en pruebas unitarias.
- **Documented**: Se completaron docstrings en todos los métodos públicos de `VoicePool` (`active_voices_count`, `set_listener`, `set_doppler_parameters`, `play_loaded_effect`, `play_effect`, `stop_voice`, `stop_all`, `set_voice_volume`, `set_voice_pitch`, `set_voice_balance`, `set_voice_emitter`).
- **Write in English**: 100% en inglés.

### 60. `rust/src/core/renderer.rs`
- **Revisión**: Renderizador de audio desacoplado en tiempo real (`AudioRenderer`, `DspCommand`, `PcmRendererHeader`) ejecutándose en el hilo de callback del sistema operativo, con procesamiento lock-free, estiramiento temporal/tono Sonic, atenuación espacial 3D y notificación C.
- **RemoveDeadCode**: Todos los comandos y ramas del pipeline están en uso activo.
- **Documented**: Se documentaron métodos y campos de sincronización (`acknowledge_flush_if_needed`, `on_device_notification`).
- **Write in English**: 100% en inglés.

### 61. `rust/src/core/dual_source.rs`
- **Revisión**: Motor central y coordinador de doble deck (`DualSource`, `StreamingDeck`, `CrossfadeAtomic`, `MiniaudioPlayerStatus`, `MiniaudioStreamStatus`, `DecoderWorker`, `PcmAdaptationPipeline`) gestionando decodificación multiformato en segundo plano con Symphonia, búfer tripartito progresivo, reinit de streams, crossfading atómico, demuxer ICY y HLS TS.
- **RemoveDeadCode**: Se identificó el campo huérfano `deck_id` en `DecoderWorker` (con 0 usos, únicamente inicializado y con directivas `#[allow(dead_code)]`), procediéndose a su remoción completa y limpieza de anotaciones redundantes en `wake`, `flush_generation` y `flush_acknowledged`.
- **Documented**: Se documentaron completamente los métodos de control espacial de `StreamingDeck` y los accesores de decks de `DualSource`.
- **Write in English**: 100% en inglés.

### 62. `rust/src/core/output_manager.rs`
- **Revisión**: Gestor simétrico de salidas físicas múltiples (`OutputManager`, `ActiveOutputDevice`, `OutputDeviceRenderer`), captura de grabación selectiva a disco por fuente y cálculo de espectro FFT para visualizador.
- **RemoveDeadCode**: Todos los métodos y rutas de dispatch están activos.
- **Documented**: Se completaron docstrings en todos los métodos de consulta y ciclo de vida (`is_recording`, `recorded_frames`, `recorded_duration_ms`, `set_visualizer_enabled`, `get_visualizer_data`, `set_pause_on_device_change`, `dispose`).
- **Write in English**: 100% en inglés.

### 63. `rust/src/core/input_manager.rs`
- **Revisión**: Gestor de captura multicanal y ducking dinámico (`InputManager`, `ActiveInputNode`), con nodos de hardware independientes, sidechain auto-ducking RMS sobre el bus de música y monitoreo directo en tiempo real.
- **RemoveDeadCode**: Todo el código se encuentra activo.
- **Documented**: Se agregaron docstrings en `is_ducking_active`, `last_rms_db`, `has_active_inputs`.
- **Write in English**: 100% en inglés.

### 64. `rust/src/core/effects_manager.rs`
- **Revisión**: Gestor de dominio de efectos polifónicos en RAM (`EffectsManager`), reutilización de búfer en memoria (In-Place Buffer Reuse), audio espacial 3D y evaluación Doppler.
- **RemoveDeadCode**: Todos los métodos delegados y accesores están en uso.
- **Documented**: Se completaron docstrings en todos los métodos de control y estado (`set_effects`, `play_effect`, `on_voice_completed`, `stop_effect`, `stop_all_effects`, `set_voice_volume`, `set_voice_pitch`, `set_voice_balance`, `set_voice_emitter`, `set_listener`, `set_doppler_parameters`, `work_buffer`, `active_voices_count`, `allocated_ram_bytes`, `loaded_effect_ids`).
- **Write in English**: Se corrigió término no inglés en comentarios ("Doppler cinemática" -> "Doppler kinematics"). 100% en inglés.

### 65. `rust/src/core/music_manager.rs`
- **Revisión**: Gestor de reproducción de pistas musicales y colas (`MusicManager`), control de doble deck Deck A / Deck B, crossfade atómico y monitor CUE standby.
- **RemoveDeadCode**: Todo el código se encuentra activo.
- **Documented**: Se agregaron docstrings en todos los métodos de gestión de cola (`set_queue`, `append`, `insert_next`, `remove_at`, `reorder`, `reorder_by_ids`, `clear_queue`), transporte (`play`, `pause`, `stop`, `seek`, `next`, `previous`) y modulación (`set_loop_mode`, `set_shuffle`, `set_crossfade`, `set_rate`, `set_pitch`, `set_volume`, `standby_buffer`, `active_deck_buffer`, `queue_items`, `dispose`).
- **Write in English**: 100% en inglés.

### 66. `rust/src/core/miniaudio_player.rs`
- **Revisión**: Orquestador principal del motor de audio (`MiniaudioPlayer`), coordinando simétricamente `MusicManager`, `DspProcessor`, `EffectsManager`, `InputManager`, `SimdMixer`, `SoftLimiter` y `OutputManager` en un único render pass libre de asignaciones y bloqueos.
- **RemoveDeadCode**: Todas las etapas del pipeline están activas.
- **Documented**: Se agregaron docstrings a nivel de estructura, campos de estado y métodos de ciclo de vida (`dispose`, `new`, `set_volume`, `stop_all`).
- **Write in English**: 100% en inglés.

---

## 5. Auditoría y Correcciones de `flutter_rust_bridge_codegen generate`

Se ejecutó `flutter_rust_bridge_codegen generate` y se analizaron las advertencias y diagnósticos del generador:

1. **Unit Struct en FRB (`SimdMixer`)**:
   - *Diagnóstico*: `Skip parsing enum_or_struct SimdMixer because of error (struct with unit fields are not supported yet, what about using struct SimdMixer {} or #[frb(opaque)] struct SimdMixer;)`.
   - *Corrección*: Se actualizó [`SimdMixer`](rust/src/core/simd_mixer.rs) de struct unitario `pub struct SimdMixer;` a struct con cuerpo vacío `#[derive(Debug, Clone, Copy, Default)] pub struct SimdMixer {}`, satisfaciendo la gramática del AST de FRB sin alterar el rendimiento ni la ABI.

2. **Desambiguación de Claves Duplicadas (`Voice` / `VoicePool`)**:
   - *Diagnóstico*: `There are still multiple objects with same key after merging, thus randomly pick one... key="VoicePool" and key="Voice" in crate::core::voice_pool and crate::dsp::voice_pool`.
   - *Corrección*: Se renombraron las estructuras de bajo nivel en [`rust/src/dsp/voice_pool.rs`](rust/src/dsp/voice_pool.rs) a `DspVoice` y `DspVoicePool`, manteniendo type aliases para compatibilidad interna. Se eliminó la ambigüedad con el pool de alto nivel [`crate::core::voice_pool::VoicePool`](rust/src/core/voice_pool.rs), resolviendo la colisión en la tabla de símbolos de FRB.

3. **Verificación de Pipelines y Suites de Pruebas**:
   - `flutter_rust_bridge_codegen generate`: Código generado y sincronizado sin advertencias de colisión.
   - `cargo check --manifest-path rust/Cargo.toml`: 0 warnings, 0 errors.
   - `cargo test --manifest-path rust/Cargo.toml`: 50/50 tests pasaron exitosamente.
   - `flutter analyze`: `No issues found!`.
   - `flutter test --concurrency=1`: 271/271 tests pasaron exitosamente (100% OK).









