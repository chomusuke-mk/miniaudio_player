# Registro Maestro de Problemas Detectados y Plan de Corrección (`docs/PROBLEMS.md`)

Este documento registra todos los fallos detectados tras desactivar los assets empaquetados de escritorio en `example/pubspec.yaml` para ejercitar todos los formatos mediante **streaming HTTP remoto** (así como problemas compartidos con **archivos locales** y **concurrencia**).

Cada problema incluye síntomas observados, reproducción verificada en laboratorio HTTP/local, causa raíz exacta en el código Rust/Dart, arquitectura de corrección y requisitos de validación automatizada.

---

## Tabla Resumen de Estado

| ID | Formato / Área | Alcance | Severidad | Estado |
| :--- | :--- | :--- | :--- | :--- |
| **P0** | Buffer `start_ms` + Renderizado UI | Remoto / Web / UI Local | Alta | **Corregido y verificado** |
| **E1** | `opus`, `flac`, `ogg`, `oga` | Remoto (HTTP 206) | Alta | **Corregido y verificado** |
| **E2** | `m4a` (AAC VBR) | Remoto (HTTP 206) | Alta | **Corregido y verificado** |
| **E3** | `m4a` (ALAC) | Remoto (HTTP 206) | Alta | **Corregido y verificado** |
| **E4** | `09_Flesh_and_Chrome.wv` | Remoto (HTTP 206) | Crítica | **Corregido y verificado** |
| **E5** | Concurrencia Seek EOF + Seek + Pause | Remoto y Local | Crítica | **Corregido y verificado** |
| **E6a** | `10_La_cicatriz_del_andén.aac` (ADTS) | Remoto (HTTP 206) | Alta | **Corregido y verificado** |
| **E6b** | `11_Mar_de_cristal.mka` (Matroska FLAC) | Remoto (HTTP 206) | Crítica | **Corregido y verificado** |
| **E7** | `12_Mi_más_bonita_coincidencia_24bit_stereo.wav` | Remoto y Local | Crítica | **Corregido y verificado** |
| **E8** | `13_Overture_for_the_Floor.webm`, `14_Painting_the_Sky.mkv` | Remoto (HTTP 206) | Crítica | **Corregido y verificado** |
| **E9** | `15_Resting_At_Your_Feet.mp2` | Remoto (HTTP 206) | Alta | **Corregido y verificado** |
| **E10** | `25_Velocity_of_One.ape` (Seek, ReplayGain, Waveform) | Remoto (HTTP 206) | Crítica | **Corregido y verificado** |
| **E11** | `27_¡Yo_me_opongo_.caf` | Remoto (HTTP 206) | Crítica | **Corregido y verificado** |
| **E12** | `hls/28_Разводят_мосты.m3u8` | Remoto (HLS VOD) | Media | **Corregido y verificado** |
| **E13** | `29_駆け抜けて、この空を.dsf` | Remoto y Local | Alta | **Corregido y verificado** |

### Resumen de Soluciones y Cobertura de Pruebas

* **P0, E1, E2, E3 ([`stream_buffer.rs`](../rust/src/buffer/stream_buffer.rs), [`byte_time_map.rs`](../rust/src/buffer/byte_time_map.rs), [`demux_reader.rs`](../rust/src/buffer/demux_reader.rs), [`player.rs`](../rust/src/api/player.rs), [`waveform_painter.dart`](../example/lib/widgets/painters/waveform_painter.dart), [`playback_engine_card.dart`](../example/lib/widgets/cards/playback_engine_card.dart))**:
  * Cálculo real de `[start_ms, end_ms]` sobre el ring deslizante (`mapped_buffered_range`, `ByteTimeMap` con tablas MP4 `moov` y puntos VBR para Ogg/FLAC), detección en `AtomicTelemetryFilter::buffered_start` y renderizado `[bufferStartProgress, bufferEndProgress]` en UI; modo de sonda aislada (`ProbeMode`) + reintentos/descarga puntual (`fetch_range`) para que bisecciones del demuxer no ejecuten `flush_circular` destructivo.
  * Validado en `p0_tests::atomic_telemetry_filter_emits_on_start_ms_change_and_resets_on_track_change`, `test_p0_byte_time_map_and_isolated_probe_cache` y `test_http_206_in_buffer_seeks_p0_e1_e2_e3`.
* **E12 ([`m3u8_parser.rs`](../rust/src/hls/m3u8_parser.rs), [`stream_buffer.rs`](../rust/src/buffer/stream_buffer.rs), [`dual_source.rs`](../rust/src/core/dual_source.rs))**:
  * Mapeo progresivo byte-offset <-> ms de segmentos VOD descargados/desalojados incluso con `total_bytes = -1`. Validado en `test_e12_hls_vod_progressive_buffered_range`.
* **E4 y E11 ([`wavpack.rs`](../rust/src/decoder/wavpack.rs), [`classifier.rs`](../rust/src/decoder/classifier.rs), [`metadata/mod.rs`](../rust/src/metadata/mod.rs), [`dual_source.rs`](../rust/src/core/dual_source.rs))**:
  * `WavpackReader` reescrito para streaming bloque por bloque `wvpk` con búsqueda/checkpoints sin `read_to_end`; soporte `ContainerFormat::Caf` + extracción de chunk `info` en `metadata/mod.rs`; lector/productor de red activo antes de `SymphoniaEngine::new_with_options`. Validado en `test_http_206_wv_and_caf_streaming_open_seek_and_metadata`.
* **E6a, E6b, E8 y E9 ([`symphonia_engine.rs`](../rust/src/decoder/symphonia_engine.rs), [`classifier.rs`](../rust/src/decoder/classifier.rs), [`dual_source.rs`](../rust/src/core/dual_source.rs), [`stream_buffer.rs`](../rust/src/buffer/stream_buffer.rs))**:
  * Muestreo VBR multipunto ADTS con salto `ID3v2` en `sample_adts_duration_ms`, manejo de `OutOfRange` restaurando `pre_seek_ms`, recuperación post-EOF en Matroska/WebM (local y HTTP 206) ante `NotAnAncestor` y backoff ante `OutOfRange` en clusters finales de `MkvReader`, distinción entre `UnexpectedEof` real y EOF lógico tras `ProbeMode`, y fallback CBR para `MP2`/`MP3`. Validado en `test_e6a_http_206_adts_vbr_duration_and_overshoot_seek` y `test_http_206_near_eof_and_unseekable_regression_e6b_e8_e9`.
* **E7 y E10 ([`dual_source.rs`](../rust/src/core/dual_source.rs), [`ape.rs`](../rust/src/decoder/ape.rs), [`demux_reader.rs`](../rust/src/buffer/demux_reader.rs), [`extended_pcm.rs`](../rust/src/decoder/extended_pcm.rs))**:
  * Alineación estricta a `block_align` y handshake `in_rtrb_push` / `wait_rtrb_push_idle` en `DecoderWorker` para impedir fuga de paquetes pre-seek durante ráfagas de seek en PCM 24-bit; `FullReadSource` + uso de `audio_end_offset` en `DemuxedStreamReader::byte_len`/`SeekFrom::End` para evitar lecturas cortas o errores espurios al final de `.ape` en streaming y análisis. Validado en `test_e7_wav_24bit_stereo_rapid_seek_stress_no_white_noise` y `test_e10_http_206_ape_seek_and_analysis_parity`.
* **E5 ([`io_pool.rs`](../rust/src/core/io_pool.rs), [`dual_source.rs`](../rust/src/core/dual_source.rs), [`dual_source_control.rs`](../rust/src/core/dual_source_control.rs), [`music_manager.rs`](../rust/src/core/music_manager.rs), [`engine_actor.rs`](../rust/src/core/engine_actor.rs), [`control_coordinator.rs`](../rust/src/core/control_coordinator.rs), [`player.rs`](../rust/src/api/player.rs))**:
  * Serialización de `seek` a través de `ControlCoordinator::seek`, cancelación selectiva `IoWorkerPool::cancel_auto_advance`, validación estricta por `seek_epoch` + `auto_advance_epoch` + `PlaybackState::Playing` + `is_auto_advance_due` antes de commitear `AutoAdvance`, y pausa/reanudación coordinada de `standby_deck` + congelamiento de `CrossfadeState` en `MusicManager::render` si `pause()` ocurre durante un crossfade. Validado en `scenario_9_e5_seek_near_end_then_away_and_pause_concurrency_matrix`.
* **E13 ([`dsf.rs`](../rust/src/decoder/dsf.rs))**:
  * Sustitución del filtro FIR de 64 taps por un decimador Kaiser (`beta = 10.0`, `32 * M` taps = `1024` taps en DSD64, `fc = 0.28 / M`) con tabla de consulta de 8 bits (`byte_lut`), estado inicial/reset con patrón DSF silencioso `0x69`, acotación estricta al límite `data_end` y recorte exacto a `total_samples_per_channel` (validado con `-101 dB` a `-126 dB` en banda ultrasónica sin aliasing audible). Validado en `decoder::dsf::tests::test_dsd64_kaiser_decimator_frequency_response_and_lut_bit_parity`, `test_e13_dsd64_decimator_stopband_rejection_and_audible_fidelity` y `test_e13_dsf_real_track_local_and_http_206_no_ultrasonic_aliasing`.

---

## Problema 0 (Transversal): `buffer.start` siempre es `0` en lugar del inicio real de la ventana

* **Alcance**: Remoto / Web (HTTP con ring buffer circular deslizante) y capa de UI/telemetría.
* **Síntoma reportado**: El rango de buffer reportado siempre comienza en `00:00` incluso después de que el buffer deslizante avanza y desaloja el inicio o salta a otra posición de la pista; al retroceder cierta distancia dentro de `[0..end]`, en realidad cae fuera del buffer real y dispara precarga.
* **Reproducción verificada**: En todas las pruebas HTTP 206 (`02_Bailando`, `06_Calculated_Motion`, `11_Mar_de_cristal`, etc.), `player.state.buffer` reporta invariablemente `Buffer(start: 0:00:00.000000, end: ..., isBuffering: ...)`.
* **Causa raíz confirmada**:
  1. En [`rust/src/core/dual_source.rs`](../rust/src/core/dual_source.rs), `DualSource::get_buffered_range` asigna literalmente `out_range.start_ms = 0;` tanto en la rama de streaming (`if self.is_stream`) como en la rama no-stream, ignorando `r.start_byte` devuelto por `StreamSession::get_range()`.
  2. En [`rust/src/api/player.rs`](../rust/src/api/player.rs), `AtomicTelemetryFilter::should_emit` para `RustPlayerEvent::Buffer(r)` solo compara `self.buffered_end` y `self.is_buffering`, descartando por completo cambios en `r.start_ms` si `r.end_ms` no cambia.
  3. En la UI del ejemplo ([`example/lib/widgets/painters/waveform_painter.dart`](../example/lib/widgets/painters/waveform_painter.dart) y [`example/lib/widgets/cards/playback_engine_card.dart`](../example/lib/widgets/cards/playback_engine_card.dart)), el halo de buffer recorta siempre desde `x = 0` (`Rect.fromLTWH(0, 0, size.width * clampedBuffer, ...)`), ignorando `buffer.start`.
* **Corrección planeada**:
  * Calcular `start_ms` y `end_ms` reales a partir de la ventana `[r.start_byte, r.end_byte]` (mapeada al rango de audio o seektable real, ver E2/E3/E12).
  * Incluir `buffered_start` en `AtomicTelemetryFilter` para emitir eventos cada vez que cambie el inicio o el fin del buffer.
  * Actualizar `WaveformPainter` y `PlaybackEngineCard` para dibujar el intervalo `[bufferStartProgress, bufferEndProgress]`.
* **Pruebas requeridas**:
  * Test unitario Rust en `StreamSession` / `DualSource::get_buffered_range` verificando que cuando `range_start > audio_start` (ring wrap o seek adelante), `start_ms > 0` y coincide con los bytes reales cacheados.
  * Test de `AtomicTelemetryFilter` verificando emisión al cambiar únicamente `start_ms`.

---

## Error 1: In-buffer seeks disparan buffering y saltos erráticos en `opus`, `flac`, `ogg`, `oga`

* **Archivos afectados**: `02_Bailando_con_tu_recuerdo.opus`, `04_Belaya_Tishina.flac`, `05_Burning_in_the_Electric_Light.ogg`, `16_Ribbons_on_Anchors.oga`.
* **Síntoma reportado**: Al hacer seek incluso dentro del rango mostrado como buffered, el reproductor actúa como si no hubiese buffer en esa zona y el límite del buffer muestra saltos erráticos (p. ej. `0` -> `30s` -> `2m` -> `1m` hasta regularizarse).
* **Reproducción verificada** (HTTP 206 sobre `02_Bailando_con_tu_recuerdo.opus`, dur `2:59.264`):
  * `open(800ms)` -> `buf.end = 0:00:35.772`
  * `seek(10000ms)` (dentro de `0..35.7s`!) -> `[BUF EVENT] end=0:00:27.199, isBuffering: true` -> `0:00:47.682`
  * `seek(30000ms)` (aún cerca del rango) -> `[BUF EVENT] end=0:02:59.264` -> `0:00:27.199 (isBuffering: true)` -> `0:01:06.814`
* **Causa raíz confirmada**:
  1. `DemuxedStreamReader::seek` ([`rust/src/buffer/demux_reader.rs`](../rust/src/buffer/demux_reader.rs)) delega cualquier `SeekFrom` directamente a `StreamSession::seek(new_cursor)`.
  2. `StreamSession::seek` ([`rust/src/buffer/stream_buffer.rs`](../rust/src/buffer/stream_buffer.rs)) llama inmediatamente a `flush_circular(target_offset)` cada vez que `target_offset` cae fuera de `[r_start, r_end)` durante decodificación.
  3. Demuxers como `OggReader` (`opus`/`ogg`/`oga`) y `FlacReader` ejecutan **seeks de bisección binaria / verificación al final del stream** durante `seek_ms` antes de fijar la posición definitiva: una sonda al punto medio o al final provoca que `flush_circular` borre los bytes ya cacheados, reposiciona el cursor a ~`2:59` (`end=2:59`) y vuelve atrás a ~`27s` con `isBuffering = true`, destruyendo el caché útil incluso cuando el destino estaba originalmente en el buffer!
  4. Sumado a **P0**, `start_ms = 0` impide ver cuándo el buffer real sí fue desplazado.
* **Corrección planeada**:
  * Evitar que lecturas/seeks especulativos o fuera de ventana del demuxer (como sondas de bisección o lectura de índices/tails) destruyan el buffer circular principal (`flush_circular`): proveer soporte de lectura/sonda por rango puntual bajo demanda (`ByteFetchTask` / pequeño caché auxiliar de sondas) y reservar el re-anclaje destructivo del stream principal únicamente cuando la lectura secuencial real del decodificador se asienta en un nuevo rango fuera de `[r_start, r_end)` (o ante cambio confirmado de posición tras `seek_ms`), preservando la ventana existente siempre que el destino ya resida en `[r_start, r_end)`.
* **Pruebas requeridas**:
  * Test Rust e integración HTTP 206 para `.opus`, `.flac`, `.ogg`, `.oga` verificando que hacer seek dentro de `[start_ms, end_ms]` real **no** dispara `isBuffering = true`, **no** genera saltos no monotónicos hasta `duration`, y conserva los datos en caché.

---

## Error 2: Rango buffered sobrestimado (~70–75%) y degradación tras out-of-range en `m4a` (AAC)

* **Archivo afectado**: `06_Calculated_Motion_aac.m4a`.
* **Síntoma reportado**: Antes de salir del buffer, el seek sin recarga solo funciona hasta el `70–75%` del rango precargado mostrado; tras cualquier seek fuera de rango, los seeks posteriores muestran el comportamiento errático del Error 1.
* **Reproducción verificada**:
  * Archivo `4,580,560 B`, duración `179.908s`. Contenedor MP4: `ftyp(0..28)` + `moov(28..179028)` (`179 KB` de metadatos/tablas iniciales) + `mdat(179036..4580560)`.
  * Inicio VBR con paquetes pequeños (`23, 6, 209 B` frente a promedio `~500 B`): el `10%` de duración (`18s`) se encuentra al `13.7%` de bytes del archivo (`627 KB`), de modo que la interpolación lineal sobre el tamaño total reporta `13.7% * 180s = 24.7s`, haciendo que `18s / 24.7s ≈ 73%` sea el límite real reproducible!
* **Causa raíz confirmada**:
  1. `DualSource::get_buffered_range` calcula `((r.end_byte as f64 / r.total_bytes as f64) * duration as f64)` linealmente sobre **todo el archivo**, sin descontar `audio_start` (ni cabeceras/portadas/tablas `moov`) y sin usar la tabla real de muestras/tiempos del demuxer (MP4 `stco`/`stsz`/`stts` o timestamps por byte).
  2. Después de hacer un seek fuera de rango, `flush_circular` mueve `r.start_byte` hacia adelante mientras `start_ms` se queda en `0`, y las consultas de tabla/bisección disparan saltos tipo Error 1.
* **Corrección planeada**:
  * Descontar el offset real de audio (`audio_start`..`audio_end`) y usar un mapa tiempo<->byte real derivado de las tablas de índice del contenedor cuando estén disponibles (p. ej. tabla de seeks / paquetes MP4 o `StreamClassifier`/índice del demuxer) o marca temporal real observada en el flujo, en lugar de asumir bitrate constante desde el byte 0.
  * Combinar con el fix de P0 (`start_ms` real) y E1 (sin `flush_circular` destructivo en sondas).
* **Pruebas requeridas**:
  * Test HTTP 206 en `06_Calculated_Motion_aac.m4a` verificando que el tiempo `end_ms` reportado coincide dentro de tolerancia mínima con el timestamp real decodificable en `r.end_byte`, permitiendo hacer seek a ≥95% del rango `[start_ms, end_ms]` reportado sin activar re-buffering, y sin degradar tras un seek fuera de rango.

---

## Error 3: Encogimiento progresivo del rango seekable dentro del buffer en `m4a` (ALAC)

* **Archivo afectado**: `07_Fevered_Strings_alac.m4a`.
* **Síntoma reportado**: Mismo síntoma que E2, pero el porcentaje utilizable del rango mostrado como buffered disminuye a medida que avanza la pista (`70% -> 60% -> 50%` hasta que casi cualquier seek provoca precarga).
* **Reproducción y datos verificados**:
  * Archivo `20,682,453 B` (`dur = 175.52s`), `moov` `28..77406`, `mdat` `77414..`. Paquetes ALAC al inicio son casi silencio comprimido (`~32 B`) frente a `~12,000 B` en secciones densas.
  * El ring circular (`4 MiB`) representa ~`35s` de audio denso, por lo que al avanzar la pista va desalojando los primeros minutos (`range_start` sube continuamente a `4 MiB`, `8 MiB`, etc.).
* **Causa raíz confirmada**:
  1. Por **P0**, `start_ms` siempre se reporta como `0`, haciendo creer que todo `[0 .. end_ms]` está cacheado cuando en realidad el inicio ya fue desalojado (`r.start_byte >> audio_start`).
  2. La relación bytes->ms de `get_buffered_range` es lineal sobre bytes brutos ignorando la enorme variabilidad VBR entre silencio inicial (`32 B`) y música (`12 KB`), causando una deriva creciente de `[start_ms, end_ms]` conforme avanza `r.end_byte`.
* **Corrección planeada**:
  * Reportar `[start_ms, end_ms]` real usando el mapeo tiempo<->byte exacto del contenedor/índice para `r.start_byte` y `r.end_byte`.
* **Pruebas requeridas**:
  * Test HTTP 206 sobre `07_Fevered_Strings_alac.m4a` avanzando/buscando en distintas zonas (20s, 70s, 130s): verificar que `[start_ms, end_ms]` avanza deslizando tanto `start_ms` como `end_ms` y que todo seek dentro de `[start_ms + margen, end_ms - margen]` completa con 0 re-buffering.

---

## Error 4: `09_Flesh_and_Chrome.wv` falla al abrir por HTTP (`code: -6`, `WOULD_BLOCK`)

* **Archivo afectado**: `09_Flesh_and_Chrome.wv` (`23,553,625 B`, duración `182.69s`).
* **Síntoma reportado**:
  ```text
  Error selecting track in engine: MiniaudioPlayerException(code: -6): Operation failed (code -6): Failed to open track: error -6
  [miniaudio_player][ERROR] DemuxedStreamReader::read WOULD_BLOCK at cursor=80966 (buf_len=50106)
  ```
* **Reproducción verificada** (test HTTP 206):
  ```text
  [ERROR] DemuxedStreamReader::read WOULD_BLOCK at cursor=65536 (buf_len=65536)
  [ERROR] open_stream_ex failed: SymphoniaEngine::new failed for hint=Some("wv"): Unsupported("failed to read WavPack stream")
  OPEN FAILED 09_Flesh_and_Chrome.wv: MiniaudioPlayerException(code: -6)
  ```
* **Causa raíz confirmada**:
  1. En [`rust/src/decoder/wavpack.rs`](../rust/src/decoder/wavpack.rs), `WavpackReader::try_new` llama a `source.read_to_end(&mut raw_bytes)` para leer todo el archivo de `23.5 MB` en memoria durante la apertura (además excede completamente `ring_cap = 4 MiB` y destruye el modelo de streaming!).
  2. En [`rust/src/core/dual_source.rs`](../rust/src/core/dual_source.rs), `open_network_with_cancel` invoca `open_stream_ex` (y por tanto `SymphoniaEngine::new_with_options`) **antes** de arrancar `spawn_network_streamer_thread` (`línea 2762`), por lo que cualquier lectura más allá de `initial_bytes` (`65536 B`) bloquea 5 segundos sin ningún productor en marcha y muere con `WOULD_BLOCK`.
* **Corrección planeada**:
  * Reescribir `WavpackReader` para hacer **streaming real bloque por bloque (`wvpk`)**: leer cabeceras WavPack de 32 bytes incrementalmente desde `MediaSource`, detectar índice/duración sin `read_to_end`, mantener buffer acotado por paquete y soportar `seek` mediante `StreamSession`/offset real de bloques `wvpk` (saltando metadatos ID3v2/APEv2/portadas iniciales si aplica).
  * Arrancar el hilo productor de red (o soporte de fetch síncrono bajo demanda durante probe/open) antes de invocar `SymphoniaEngine::new_with_options`, evitando inanición en la apertura de cualquier formato.
* **Pruebas requeridas**:
  * Test unitario + integración HTTP 206 abriendo `09_Flesh_and_Chrome.wv` (incluso con `latencyMs > 0`), validando metadatos, duración, reproducción, seeks adelante/atrás dentro y fuera del ring buffer, y `analyzeAudio`.

---

## Error 5: Concurrencia al hacer seek cerca del final + seek lejos + `pause()` inicia la siguiente pista en estado pausado

* **Alcance**: Remoto y Local (reproducible con prewarm/auto-advance/crossfade activo).
* **Síntoma reportado**: Al hacer seek muy cerca del final de la pista actual, luego seek hacia una posición anterior y llamar a `pause()`, la siguiente pista de la cola llega a abrirse y comenzar a sonar aunque el reproductor reporte estado pausado.
* **Reproducción y evidencia en logs**:
  * En los logs del usuario y pruebas locales: al hacer `seek(cerca_del_fin)`, `DecoderWorker` decodifica el pequeño resto hasta EOF, marca `decoder_eof = true`, y/o `engine_actor` dispara `AutoCrossfade` / `RtControlHint::AutoAdvanceNeeded` que invoca `open_source(siguiente_pista)` en segundo plano o `commit_transition_internal(..., AutoAdvanceGapless / AutoCrossfade)` llamando a `to_slot.play()` (`play() called (current_state=2)`).
* **Causa raíz confirmada**:
  1. `DualSource::seek` no incrementa un epoch/generación de transporte ni cancela `ActiveOpenJob { kind: ActiveOpenKind::AutoAdvance }` en `ControlCoordinator`, tampoco aborta un `AutoCrossfade` en curso ni resetea `hint_state.last_auto_advance_key` en `engine_actor.rs`.
  2. `DecoderWorker::handle_eof` / `handle_pending_seek` no invalidan limpiamente un EOF previo al encolar o ejecutar un `seek` hacia atrás, permitiendo que `tick_music_lifecycle` emita `AutoAdvanceNeeded` con base en un `track_exhausted`/`decoder_eof` obsoleto.
  3. `commit_transition_internal` en [`rust/src/core/dual_source_control.rs`](../rust/src/core/dual_source_control.rs) ejecuta `to_slot.play()` sin verificar si un `seek` posterior ya sacó la pista activa de EOF o si el estado objetivo ya pasó a `Paused`/`Stopped` antes de completar la transición.
* **Corrección planeada**:
  * Unificar cancelación por generación/época entre `seek`, `pause`, `stop`, `AutoAdvanceNeeded` y `AutoCrossfade`: cualquier `seek()` debe limpiar inmediatamente `decoder_eof`/`track_exhausted`, abortar `ActiveOpenJob` de tipo `AutoAdvance` o `AutoCrossfade` activo, invalidar `last_auto_advance_key` mediante contador atómico comprobado al commitear la transición, y garantizar que ninguna transición automática llame a `play()` si `playback_state != Playing` o si cambió la generación de seek.
* **Pruebas requeridas**:
  * Test de estrés/concurrencia determinista (remoto HTTP y local) encadenando `seek(near_end)` -> `seek(mid)` -> `pause()` con y sin pista prewarmed y con `crossfade > 0` y `= 0`, verificando tras espera prolongada que `currentIndex` permanece en 0 (o en pausa estricta con 0 audio sonando en la pista siguiente).

---

## Error 6a: `10_La_cicatriz_del_andén.aac` sobrestima duración y salta de pista al buscar cerca del final reportado

* **Archivo afectado**: `10_La_cicatriz_del_andén.aac` (`4,114,966 B`).
* **Síntoma reportado**: Al hacer seek hacia el final fuera del buffer (p. ej. `2:55`), precarga y salta inmediatamente a la pista siguiente.
* **Reproducción verificada** (test HTTP 206):
  * `AAC opened dur=0:03:10.043000` (`190.043s`!), pero la duración real decodificada (`8000` paquetes ADTS) es **`170.645s` (`2:50.645`)**.
  * Al ejecutar `seek(175000ms)`: `DecoderWorker seek_ms(175000) failed: SeekError(OutOfRange)` -> `DecoderWorker reached EOF` -> salto inmediato a pista siguiente (`idx=1, pos=464`).
* **Causa raíz confirmada**:
  1. `10_La_cicatriz_del_andén.aac` comienza con una etiqueta `ID3v2` de `2,678 B` (incluye portada PNG), antes del primer frame sync ADTS (`0xFFFx`).
  2. `sniff_adts_stream_info` en [`rust/src/decoder/classifier.rs`](../rust/src/decoder/classifier.rs) escanea `0..4096` **sin saltar `initial_id3v2_skip`**, leyendo frames tras el ID3 y extrapolando bitrate sobre la cola/intro VBR hacia `4,114,966 B`, sobreestimando `dur=190.04s` (+19.4s inexistentes!).
  3. Symphonia `AdtsReader` rechaza `175000ms` con `SeekError(OutOfRange)` al superar los frames reales (`170.645s`), lo cual es interpretado por `DecoderWorker` como error seguido de EOF inmediato si el cursor quedó al fin.
* **Corrección planeada**:
  * En `sniff_adts_stream_info`, aplicar siempre `initial_id3v2_skip` antes de escanear frames ADTS, escanear múltiples puntos de muestreo cuando hay acceso aleatorio o HTTP Range (inicio tras ID3, ~25%, ~50%, ~75%, cola antes de APE/ID3v1) o contar frames reales cuando esté disponible para obtener bitrate medio VBR preciso, y propagar `duration` real cuando `AdtsReader` actualiza `n_frames`.
  * Manejar `SeekError(OutOfRange)` en `DecoderWorker` acotando de forma segura cerca del final sin corromper la posición ni emitir `track_exhausted` espurio cuando el usuario retrocede, o si excede el final real tras ajustar duración exacta, que el último fragmento nunca desborde el rango de la barra UI.
* **Pruebas requeridas**:
  * Test unitario en `classifier.rs` validando que `10_La_cicatriz_del_andén.aac` salta `ID3v2` (`2678 B`) y estima duración cercana a `170.6s` (no `190s`).
  * Test HTTP 206 buscando a `dur - 2s` y de vuelta a `30s` sin saltos espurios.

---

## Error 6b y Error 8: Seek cerca del final seguido de seek atrás en Matroska / WebM (`mka`, `webm`, `mkv`) falla con `UnexpectedEof` y cambia/desincroniza la pista

* **Archivos afectados**:
  * **Error 6b**: `11_Mar_de_cristal.mka` (`20,274,223 B`, FLAC en Matroska).
  * **Error 8**: `13_Overture_for_the_Floor.webm` (`2,233,169 B`, Opus en WebM) y `14_Painting_the_Sky.mkv` (`2,395,840 B`, H.264+Opus+MJPEG en Matroska).
* **Síntoma reportado**: Al hacer seek cerca del final y luego seek atrás, la UI actualiza la posición nueva, pero el audio sigue sonando en el final o salta de pista inmediatamente.
* **Reproducción verificada** (test HTTP 206 con throttle en todos los tres contenedores `.mka`, `.webm`, `.mkv`):
  ```text
  DecoderWorker executing seek to 179730ms (gen=1)
  Network streamer completed audio payload up to audio_end
  DecoderWorker seek_ms(179730) succeeded
  DecoderWorker reached EOF
  [NATIVE:SEEK:START] seek(30000ms) requested.
  DecoderWorker executing seek to 30000ms (gen=2)
  DecoderWorker seek_ms(30000) failed: IoError(Kind(UnexpectedEof))
  DecoderWorker reached EOF
  -> salta inmediatamente a la siguiente pista (idx=1, pos=208)!
  ```
* **Causa raíz confirmada**:
  1. Cuando `NetworkStreamer` termina de descargar hasta `audio_end` y marca `session.mark_eof()` (o cuando el hilo streamer ya salió al completar `audio_end`), cualquier seek posterior en `StreamSession::seek` fuera de `[r_start, r_end)` ejecuta `flush_circular(target_offset)` dejando `range_start == range_end == target_offset`. Como `is_eof` ya estaba marcado (y/o el productor ya finalizó), la siguiente lectura devuelve `0 bytes` -> `UnexpectedEof` dentro de Symphonia `MkvReader::seek`!
  2. Además, en contenedores `.mkv`/`.mka`/`.webm` las tablas `Cues` o elementos al final hacen que `MkvReader` busque alrededor del final o por clusters; al recibir `UnexpectedEof`, `DecoderWorker::handle_pending_seek` ([`rust/src/core/dual_source.rs`](../rust/src/core/dual_source.rs)) registra el error pero **aun así sobrescribe `self.pos_ms.store(target_seek)`** y emite `EventType::Position`, mientras deja `decoder_eof = true` provocando transición/desincronización!
* **Corrección planeada**:
  * No permitir que `session.mark_eof()` mate futuros seeks en streams con `Accept-Ranges: bytes` (streams seekables HTTP): si `flush_circular` reposiciona o una sonda lee tras haber completado el extremo `audio_end`, `is_eof` debe limpiarse en `StreamSession::seek` / despertar o relanzar la descarga HTTP Range desde el offset solicitado (o mejor aún, cuando todo el archivo ya cupo en `ring_cap` no descartar innecesariamente ni depender de `mark_eof` irreversible!).
  * En `DecoderWorker::handle_pending_seek`, **no** actualizar `pos_ms` ni emitir `EventType::Position` con `target_seek` si `eng.seek_ms` devolvió error, ni dejar `decoder_eof = true` tras un error recuperable de I/O.
* **Pruebas requeridas**:
  * Test HTTP 206 con throttle para `.mka`, `.webm` y `.mkv` reproduciendo `seek(dur - 1200ms)` -> esperar cerca/durante EOF -> `seek(30000ms)`: verificar `seek_ms(30000)` exitoso sin `UnexpectedEof`, `idx == 0` mantenido, y paquetes reales decodificados cerca de `30s`.

---

## Error 7: Ráfagas muy rápidas de seek en WAV de 24-bit estéreo pueden generar ruido blanco/estática pura

* **Archivo afectado**: `12_Mi_más_bonita_coincidencia_24bit_stereo.wav` (`48,045,812 B`, `pcm_s24le`, `44100 Hz`, `2 ch`, `block_align = 6 B/frame`, posible tanto en remoto como en local).
* **Síntoma reportado**: Hacer seeks repetidos sumamente rápido (`gen=1..187`) ocasionalmente hace que la pista pase a sonar únicamente con estática / ruido blanco puro.
* **Causa raíz confirmada**:
  1. `pcm_s24le` estéreo tiene muestras de `3 bytes` y frames de `6 bytes` (`block_align = 6`, no alineado a 4 bytes).
  2. Si cualquier seek, reposición de `DemuxedStreamReader` / `WaveReader` / `ExtendedPcmReader`, o lectura parcial/descartada bajo contención durante ráfagas de seek (`seek gen=1..187`) deja el cursor de lectura o el buffer interno desalineado por 1, 2 o 3 bytes respecto al inicio real del chunk `data` (`audio_start`), los bytes `[LSB, MID, MSB]` de cada muestra de 24 bits se permutan en orden circular (`[MID, MSB, LSB']` o `[MSB, LSB', MID']`), convirtiendo el byte más significativo aleatorio del canal contiguo en ruido blanco de amplitud completa!
  3. También hay que garantizar el vaciado completo y realineación atómica del buffer de decodificación (`frame_buf`, resampler / `PcmAdaptationPipeline`) ante ráfagas de `seek_request_ms` sobrescritos consecutivamente antes de consumir un paquete parcial.
* **Corrección planeada**:
  * Asegurar en `ExtendedPcmReader` y `Wave`/PCM streaming que todo `seek` de byte alinee estrictamente `offset = audio_start + ((offset - audio_start) / block_align) * block_align`, que toda lectura de paquete PCM lea un número entero de frames (`read_exact` / acumulador de frame alineado sin avanzar el decodificador con medios frames), y verificar/limpiar estados parciales en `Symphonia` `WaveReader` / `ExtendedPcmReader` durante ráfagas rápidas de seek (`gen` incrementándose en vuelo).
* **Pruebas requeridas**:
  * Test de estrés ejecutando 200 seeks aleatorios rápidos (`0..dur`) sobre `12_Mi_más_bonita_coincidencia_24bit_stereo.wav` (HTTP y local) validando invariante de muestras decodificadas: sin picos anómalos de ruido de alta frecuencia / crest factor normal y coherencia espectral/RMS respecto a referencia `ffmpeg`.

---

## Error 9: `15_Resting_At_Your_Feet.mp2` congela el indicador de buffer aunque permite avanzar/reproducir

* **Archivo afectado**: `15_Resting_At_Your_Feet.mp2` (`4,000,814 B`, ID3v2 `33,326 B` con portada MJPEG, MP2 CBR `192 kbps`, `165.312s`).
* **Síntoma reportado**: Al hacer seek hacia adelante el audio avanza sin mostrar precarga, pero el límite superior del buffer nunca cambia.
* **Reproducción verificada** (test HTTP 206):
  ```text
  open_stream_ex: initial_bytes=98304, total_size=4000814, hint=Some("mp3")
  open(500ms): pos=510 buf=Buffer(start: 0:00:00.000000, end: 0:00:32.415000)
  DecoderWorker executing seek to 80000ms (gen=1)
  DecoderWorker seek_ms(80000) failed: SeekError(Unseekable)
  seek(80s): pos=80394 buf=Buffer(start: 0:00:00.000000, end: 0:00:32.415000)
  ```
* **Causa raíz confirmada**:
  1. Symphonia `MpaReader::seek` rechaza el seek en `15_Resting_At_Your_Feet.mp2` con **`SeekError(Unseekable)`** (pista MP2 sin cabecera Xing/VBRI y/o `n_frames` ausente / modo unseekable en `MpaReader` cuando abre vía stream).
  2. `DecoderWorker::handle_pending_seek` ignora el error `SeekError(Unseekable)` y aun así actualiza `pos_ms = 80000` (desincronizando `pos` de lo que realmente sigue sonando dentro de `[0..32.4s]`), mientras el cursor real de bytes permanece en ~`32s`, manteniendo la ventana `SlidingWindow` congelada en `32.415s`!
  3. Además `"mp2"` falta en `StreamClassifier::extract_extension_hint` / manejo explícito para streams CBR con `ID3v2` grande.
* **Corrección planeada**:
  * Asegurar que `SymphoniaTrackSession` para streams CBR (`MP2` / `MP3` sin tabla Xing) tenga información de `n_frames` (p. ej. vía `EnableGapless`/total frames o wrapper/fallback de seek CBR alineado a frames MP1/MP2/MP3 cuando `MpaReader` devuelva `Unseekable` pero la fuente sí sea seekable con `total_size` conocido y bitrate fijo/estimado).
  * Corregir `DecoderWorker::handle_pending_seek` para **no** falsificar `pos_ms` ante fallo de `seek_ms`, asegurando además que el `NetworkStreamer` avance el rango buffered tras el seek real.
* **Pruebas requeridas**:
  * Test HTTP 206 y local para `15_Resting_At_Your_Feet.mp2`: hacer seek a `40s`, `80s`, `120s`, verificar `seek_ms` sin `Unseekable`, audio decodificado real distinto del principio (`0s`) y actualización real de `[buffer.start, buffer.end]`.

---

## Error 10: `25_Velocity_of_One.ape` — Seek fuera de buffer detiene el reproductor + ReplayGain y Waveform rotos sobre HTTP

* **Archivo afectado**: `25_Velocity_of_One.ape` (`20,651,750 B`, `44100 Hz`, `2ch`, `16-bit`, `109` frames de `~189 KB/frame`, portadas MJPEG+PNG).
* **Síntoma reportado**:
  1. Hacer seek a una zona fuera del buffer o cerca del final cierra la pista y pasa a `PlaybackState.stopped`.
  2. ReplayGain calcula mal y la gráfica de forma de onda muestra una barra plana del lado izquierdo hasta ~70% de la canción y espectro musical solo después.
* **Reproducción verificada**:
  * Seek HTTP a `150,000ms` (de `181,278ms` totales):
    ```text
    DecoderWorker seek_ms(150000) succeeded
    DecoderWorker reached EOF
    DecoderWorker is_buffering changed: false -> true
    finish_at_end() called
    APE after seek(150s): state=PlaybackState.stopped pos=150000
    ```
  * `analyzeAudio` sobre HTTP: `rg=0.0, peak=0.0, lufs=-70.0, wf=null` frente al archivo local correcto (`rg=-5.35 dB, peak=1.0, lufs=-11.92 LUFS, wf=100 puntos válidos`).
* **Causa raíz confirmada**:
  1. En [`rust/src/decoder/ape.rs`](../rust/src/decoder/ape.rs), `ApeReader::next_packet` atrapa **todo `Err(_)`** de `decode_frame` (incluyendo `WouldBlock`, lecturas cortas de HTTP en frames de `~189 KB`, o transición durante un seek fuera del ring) y lo convierte silenciosamente en **`Ok(false)` (falso EOF)**. Esto dispara inmediatamente `DecoderWorker reached EOF` -> `finish_at_end()` -> `PlaybackState.stopped` tanto en playback como en análisis HTTP!
  2. Para `analyze_audio_source` HTTP (donde el lector necesita todo el archivo secuencialmente y con lecturas completas sin inanición de `initial_bytes = 65536` < tamaño del frame `189 KB`), un fallo de lectura parcial o saturación/error en frames tempranos rompe tanto `ReplayGainScanner` como `AdaptiveWaveformAccumulator` (normalizado respecto a un pico anómalo o muestras truncadas).
  3. Investigar y asegurar también la lectura completa/reintentos en `ApeReader` (`read_exact` / espera ante `WouldBlock` mientras `!session.is_eof()`) y verificar `seek` por seektable de APE con espera de buffer.
* **Corrección planeada**:
  * En `ApeReader`, nunca mapear `ErrorKind::WouldBlock` o errores recuperables/lecturas cortas mientras el stream no esté en EOF real a `Ok(false)`: esperar datos del `StreamSession` / propagar error de red real.
  * Asegurar en `open_stream_ex` / `NetworkStreamer` para análisis y reproducción que el streamer esté activo antes de decodificar el primer frame `189 KB` de APE, y validar el espectro de `waveform` (100 bloques) y `ReplayGain` por HTTP igual que en archivo local.
* **Pruebas requeridas**:
  * Test HTTP 206 en `25_Velocity_of_One.ape`: (a) `seek(150000ms)` y `seek(10000ms)` bajo latencia simulada verificando estado `Playing` (nunca `Stopped` prematuro); (b) `analyze_audio_source` sobre HTTP con throttle comparando `gainDb`, `peak`, `lufs` y los 100 puntos de `waveform` exactamente contra la referencia local (sin barra plana al 70% ni `-70 LUFS`).

---

## Error 11: `27_¡Yo_me_opongo_.caf` falla al abrir por HTTP (`code: -6`, `WOULD_BLOCK`)

* **Archivo afectado**: `27_¡Yo_me_opongo_.caf` (`34,003,479 B`, `pcm_s16be`, `48000 Hz`, `2ch`, payload `data` desde offset `543`).
* **Síntoma reportado**:
  ```text
  [ERROR] DemuxedStreamReader::read WOULD_BLOCK at cursor=81920 (buf_len=32768)
  SymphoniaEngine::new failed for hint=None: IoError(Custom { kind: WouldBlock, error: "buffer starving" })
  MiniaudioPlayerException(code: -6)
  ```
* **Reproducción verificada** (test HTTP 206):
  ```text
  open_stream_ex: initial_bytes=98304, total_size=34003479, is_live=false, ring_cap=4194304
  [ERROR] DemuxedStreamReader::read WOULD_BLOCK at cursor=98304 (buf_len=32768)
  [ERROR] open_stream_ex failed: SymphoniaEngine::new failed for hint=None: IoError(Custom { kind: WouldBlock, error: "buffer starving" })
  ```
* **Causa raíz confirmada**:
  1. `StreamClassifier` ([`rust/src/decoder/classifier.rs`](../rust/src/decoder/classifier.rs)) no define `ContainerFormat::Caf`, ni la extensión `"caf"` en `extract_extension_hint`, ni parser de chunks `caff` para ubicar `audio_start` (`data` + 8 bytes) y duración/PCM big-endian. Por eso queda `hint=None`.
  2. Como Symphonia recibe `hint=None`, intenta sondear múltiples formatos leyendo más allá de `initial_bytes = 98304` **antes** de que `open_network_with_cancel` lance `spawn_network_streamer_thread` (`dual_source.rs:2762`), bloqueándose 5 segundos en `WOULD_BLOCK`.
* **Corrección planeada**:
  * Agregar `ContainerFormat::Caf` y `"caf"` en `StreamClassifier` con parser de cabecera `caff` (`desc`, `data` -> `audio_start`, sample rate, canales, `pcm_s16be` / codecs CAF).
  * Arrancar `spawn_network_streamer_thread` (o fetch por rango bajo demanda) antes de `SymphoniaEngine::new_with_options`, igual que en E4.
* **Pruebas requeridas**:
  * Test unitario en `classifier.rs` para `.caf` (`caff` + PCM BE) + test HTTP 206 abriendo, reproduciendo y haciendo seek en `27_¡Yo_me_opongo_.caf`.

---

## Error 12: HLS VOD siempre reporta el buffer en `0 - 0`

* **Archivo afectado**: `hls/28_Разводят_мосты.m3u8` (19 segmentos, VOD `is_live = false`, duración `180.533s`).
* **Síntoma reportado**: El buffer de la pista HLS VOD permanece siempre en `00:00 - 00:00`.
* **Reproducción verificada** (test HTTP):
  ```text
  open_hls_playlist: Media playlist parsed (segments=19, is_live=false, duration=180.53s)
  open_stream_ex: initial_bytes=204756, total_size=-1, is_live=false, ring_cap=4194304
  HLS opened dur=0:03:00.533000 pos=789 buf=Buffer(start: 0:00:00.000000, end: 0:00:00.000000, isBuffering: false)
  ```
* **Causa raíz confirmada**:
  1. `open_hls_playlist_bytes` ([`rust/src/core/dual_source.rs`](../rust/src/core/dual_source.rs)) pasa `total_size = -1` a `open_stream_ex`.
  2. `DualSource::get_buffered_range` solo calcula `end_ms` si `r.total_bytes > 0`, forzando `start_ms = 0` y `end_ms = 0` para cualquier fuente con `total_bytes = -1`.
  3. Tampoco se registra en la sesión la correspondencia entre offsets de flujo demuxado / segmentos HLS VOD entregados y duración temporal acumulada de los segmentos descargados.
* **Corrección planeada**:
  * Para HLS VOD (donde la playlist aporta duración total y duración de cada segmento `.ts`/`.aac`), rastrear en `StreamSession` o en el tracker HLS el mapeo byte-offset <-> ms acumulado de los segmentos introducidos en la sesión (o la estimación proporcional respecto a los segmentos VOD totales descargados/desalojados en `[r.start_byte, r.end_byte]`), reportando `[start_ms, end_ms]` real incluso con `total_bytes = -1` (o actualizando progreso temporal de segmentos).
* **Pruebas requeridas**:
  * Test HLS VOD (Rust + integración HTTP) verificando `buffer.start` y `buffer.end > 0` avanzando conforme llegan segmentos y reflejando la ventana real en caché.

---

## Error 13: `29_駆け抜けて、この空を.dsf` suena con leve ruido tipo "papel arrugado" (local y remoto)

* **Archivo afectado**: `29_駆け抜けて、この空を.dsf` (`62,267,319 B`, DSD64 mono `2,822,400 Hz`, salida decimada a `88,200 Hz`, trailing ID3+MJPEG en offset `62,193,756`).
* **Síntoma reportado**: La pista se reproduce pero con un leve ruido crujiente de alta frecuencia ("papel arrugado") tanto en local como en remoto.
* **Causa raíz confirmada**:
  1. `DsdFirDecimator` en [`rust/src/decoder/dsf.rs`](../rust/src/decoder/dsf.rs) realiza una decimación directa 32x (`2.8224 MHz -> 88.2 kHz`) mediante un único filtro FIR Blackman-Harris truncado a `64` taps (`num_taps = (m * 2).clamp(32, 128)`, `fc = 0.45 / 32`).
  2. A razón de decimación `M = 32`, un filtro de solo 64 taps (`2` períodos de salida!) posee un lóbulo principal ~4 veces más ancho que la banda de paso y una atenuación de banda eliminada insuficiente frente al **enorme piso de ruido ultrasónico conformado (noise-shaping sigma-delta de 5.º orden)** propio de DSD64 por encima de `22 kHz` (`-20 dB a 0 dB` en `50 kHz–1.4 MHz`!). Ese ruido ultrasónico sufre aliasing hacia la banda audible (`0–44.1 kHz`), produciendo exactamente el timbre de crepitación/papel arrugado.
  3. Adicionalmente, debe respetarse de forma estricta `sample_count` al final del último bloque `4096 B` (`dsd_lsbf_planar` suele contener padding `0x69` en los bits finales no usados).
* **Corrección planeada**:
  * Reemplazar `DsdFirDecimator` por una etapa de decimación FIR de alta atenuación (diseño multi-etapa óptimo —p. ej. 4 etapas `4x -> 2x -> 2x -> 2x` o filtro Kaiser/equiripple largo `>= 256–512` taps en fase polifásica sobre tabla precomputada de 8 bits `256` entradas por fase, con banda de paso plana hasta `20–24 kHz` y rechazo `>= 90–100 dB` desde `~35–44.1 kHz` hasta Nyquist DSD `1.4112 MHz`), manteniendo alto rendimiento en tiempo real sin aliasing audible.
  * Verificar el manejo exacto de `sample_count` / padding en el último bloque y los saltos `seek_ms` sin discontinuidades del estado histórico FIR.
* **Pruebas requeridas**:
  * Tests unitarios DSP en Rust comprobando respuesta en frecuencia (`>= 85–90 dB` atenuación ultrasónica vs <0.1 dB caída en 0–20 kHz, sin aliasing al inyectar tono/ruido sigma-delta DSD de alta frecuencia) + decodificación de `29_駆け抜けて、この空を.dsf` midiendo piso de ruido / energía fuera de señal y ausencia de artefactos en seek/EOF.
