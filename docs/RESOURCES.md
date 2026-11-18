# Plan Maestro de Recursos de Audio, Metadatos y Submódulo (`miniaudio_player_assets`)

Este documento define la arquitectura aprobada (**Enfoque C: Sub-repositorio dedicado + Submódulo único sin symlinks ni Git LFS**) para migrar los recursos de audio de prueba y demostración hacia el catálogo libre de derechos de autor.

> **Regla para `pub.dev`**: Ningún archivo de música del catálogo forma parte del paquete publicado en `pub.dev`. Tanto `/test/` como `/example/assets/music/` y `/.gitmodules` quedan excluidos en [`.pubignore`](../.pubignore).

---

## 1. Inventario Real Verificado

### 1.1 Catálogo Sin Copyright Recolectado (29 Canciones = 58 Archivos)
* **Ubicación de entrada**: `29` pares `.mp3` + `.mp4` (`368 MB` en total).
* Incluye las 7 canciones añadidas recientemente (`Before_The_Dawn`, `Firelight_Promise`, `Mi_más_bonita_coincidencia`, `Running_With_Daylight`, `Tracing_Lines`, `Velocity_of_One`, `Where_Miracles_Start`) más títulos con caracteres UTF-8 complejos (`La_cicatriz_del_andén`, `¡Yo_me_opongo_`, `Разводят_мосты`, `駆け抜けて、この空を`).
* Cada `.mp4` provee video H.264 `1024x1024 @ 30 fps` (~176 s), utilizable para extraer múltiples frames reales como portadas.

### 1.2 Herramientas Verificadas en el Sistema
* **Instaladas y listas**:
  * `ffmpeg` + `ffprobe` (codificadores `libmp3lame`, `mp2`/`libtwolame`, `aac`, `alac`, `flac`, `libopus`, `libvorbis`, `wavpack`, `pcm_s16le`/`be`/`s24le`/`f32le`, muxers `wav`/`rf64`/`w64`/`aiff`/`caf`/`adts`/`ogg`/`opus`/`matroska`/`webm`/`hls`/`mpegts`).
  * `python3` (`3.14.4`), **`python3-mutagen` (`1.47.0`, con `mid3v2` y `mutagen-inspect`)** y **`Pillow` (`PIL`)** con soporte JPEG, PNG, WebP y TIFF.
  * **`mkvtoolnix` (`97.0`, con `mkvmerge`, `mkvpropedit`, `mkvextract`)** para adjuntos múltiples, capítulos y etiquetas XML en Matroska (`.mka`, `.mkv`, `.webm`).
  * **`wav_to_dsf` (`example/assets/music/scripts/wav_to_dsf.c`)**: Codificador DSF propio en C compilado para generar DSD64 PDM desde WAV.
  * **`mac` (Monkey's Audio CLI)**: Compilado localmente desde fuente en `temp/monkeys-audio/build/mac` para codificar `.ape` (`25_Velocity_of_One.ape`). Únicamente `.mp1` (MPEG-1 Layer I) carece de codificador estándar en `ffmpeg`, cubriéndose los demás 29 formatos reales.

---

## 2. Ubicación Exacta y Diseño del Git Submodule (Enfoque C)

### 2.1 Ubicación Elegida: `example/assets/music`
```text
Repositorios en GitHub:
  ├── https://github.com/chomusuke-mk/miniaudio_player.git        (Librería: ~5-10 MB)
  └── https://github.com/chomusuke-mk/miniaudio_player_assets.git (Sub-repo multimedia)

Montaje único en el repo principal (SIN symlinks, SIN Git LFS):
  miniaudio_player/
  ├── .gitmodules                    # path = example/assets/music
  ├── .gitignore                     # Limpio; NO ignora example/assets/music
  ├── .pubignore                     # Excluye /example/assets/music/, /test/, /.gitmodules (0 MB música en pub.dev)
  ├── example/
  │   ├── .gitignore                 # SIN `/assets/music/` para permitir el gitlink 160000 limpio
  │   ├── pubspec.yaml               # Desktop: `assets/music/` completo; Android/iOS/Web: 4 formatos ligeros (~13.5 MiB)
  │   └── assets/
  │       └── music/   <───────────── SUBMÓDULO ÚNICO (1 única copia física compartida; incluye README.md)
  └── test/
      └── MANIFEST.md                # Contrato de pruebas en inglés (tests resuelven desde `example/assets/music/`)
```

### 2.2 Por Qué `example/assets/music` Es la Ubicación Única Óptima
1. **Compatibilidad nativa con Flutter (`flutter_tools`)**: `example/pubspec.yaml` exige que los assets declarados vivan dentro de `example/` (no permite rutas relativas externas como `../shared_assets/` de forma portátil en Android/iOS/Web).
2. **Cero duplicados entre `example/` y `test/`**:
   * `example/` empaqueta los archivos raíz de `assets/music/` automáticamente al estar declarados en `example/pubspec.yaml`.
   * `test/` (Dart) y `test/rust/` (`FixtureResolver`) leerán los mismos archivos desde `example/assets/music/` (eliminando los antiguos archivos de `test/fixtures/` y quitando la duplicación de ~293 MB + 231 MB actual).
3. **Subcarpetas estratégicas dentro del submódulo**:
   Flutter **no** empaqueta subcarpetas recursivamente salvo que se listen explícitamente en `pubspec.yaml`. Aprovecharemos eso para separar limpiamente:
   ```text
   example/assets/music/                 # <-- Contenido de chomusuke-mk/miniaudio_player_assets
   ├── 01_Apex_Momentum.mp3              # Nivel raíz: listado automáticamente por AssetManifest en example/
   ├── ...
   ├── 29_駆け抜けて、この空を.dsf
   ├── tripartite/                       # Casos borde de buffer para test/ (NO incluido en example APK/Web)
   │   ├── giant_cover.mp3
   │   ├── giant_cover.flac
   │   ├── eof_chirp.mp3
   │   ├── non_faststart.m4a
   │   ├── trailing_chunks.wav
   │   └── head_3mb_tail_25kb.mp3
   ├── hls/                              # Playlists .m3u8 + segmentos .ts (clear + AES-128-CBC opcional)
   ├── covers/                           # Frames .mp4 extraídos y miniaturas fuente (JPEG/PNG/WebP/32x32)
   └── scripts/build_assets.py           # Pipeline reproducible (ffmpeg + mutagen + PIL + mkvpropedit)
   ```
4. **Cero música en `pub.dev` y repo principal liviano**:
   * Git guarda únicamente el puntero gitlink (`160000`, ~40 bytes) en `miniaudio_player`.
   * [`../.pubignore`](../.pubignore) excluye `/example/assets/music/`, `/.gitmodules` y `/test/`, garantizando un tarball de `pub.dev` muy por debajo del límite de 100 MB (con **0 bytes de audio**).

---

## 3. Estado de `.gitignore`, `example/.gitignore` y `.pubignore`

* [`../.gitignore`](../.gitignore):
  * Eliminada la antigua regla `/test/fixtures/*` y `!/test/fixtures/MANIFEST.md` (los binarios heredados fueron purgados y no queda carpeta `test/fixtures/`).
  * Añade `/.venv/` por si se usan entornos virtuales locales de Python.
  * **No** ignora `/example/assets/music/` para que el submódulo quede versionado correctamente via `.gitmodules`.
* [`../example/.gitignore`](../example/.gitignore):
  * Se **eliminó** la regla `/assets/music/` que antes bloqueaba el rastreo de `example/assets/music` como submódulo Git.
* [`../.pubignore`](../.pubignore):
  * Añade `/example/assets/music/`, `/.gitmodules` y `/.venv/` junto a `/test/`, garantizando que `dart pub publish` no empaquete ningún archivo musical ni binario auxiliar.

---

## 4. Mapeo Completo: 29 Canciones → 29 Formatos y Variantes Únicos

Gracias a las **29 canciones únicas** actuales, cada formato principal y cada variante técnica recibe su propia canción (sin repetir canciones entre variantes), **manteniendo sus duraciones originales completas (`~154.2 s` – `~183.0 s`, sin recortes)** y garantizando que **ningún archivo individual supere el límite de 100 MB de GitHub** sin necesidad de Git LFS (~**`625.24 MiB`** totales en el submódulo incluyendo portadas, HLS, `tripartite/` y `library/`):

| # | Canción Fuente | Archivo / Variante Objetivo | Especificación Técnica & Variantes | Metadatos y Portadas (`mutagen` / `mkvpropedit` / `ffmpeg`) |
| :-: | :--- | :--- | :--- | :--- |
| 01 | `Apex_Momentum` | `01_Apex_Momentum.mp3` | MP3 VBR (`Xing`) + ID3v2.4 + ID3v1 | **Máxima cobertura**: 17 Core + 63 `ExtendedMetadata`, capítulos `CHAP`/`CTOC`, `USLT` letra, `TXXX`, **4 imágenes `APIC`** (`coverFront.jpg`, `coverBack.png`, `icon_32.png`, `leaflet.webp`) |
| 02 | `Bailando_con_tu_recuerdo` | `02_Bailando_con_tu_recuerdo.opus` | Ogg Opus (`libopus` 48 kHz) | `VorbisComments` + 2 `METADATA_BLOCK_PICTURE` + tags ReplayGain |
| 03 | `Before_The_Dawn` | `03_Before_The_Dawn_cbr_noxing.mp3` | **Variante MP3 CBR 128k Mono sin Xing** (`-write_xing 0`) | ID3v2.4 completo + portada JPEG (reemplaza `cbr_noxing.mp3`) |
| 04 | `Belaya_Tishina` | `04_Belaya_Tishina.flac` | FLAC Lossless 24-bit / 48 kHz | `VorbisComments` UTF-8 + `CUESHEET` + múltiples `PICTURE` (`jpeg`, `png`, `webp`) + 63 campos extendidos |
| 05 | `Burning_in_the_Electric_Light` | `05_Burning_in_the_Electric_Light.ogg` | Ogg Vorbis (`libvorbis`) | `VorbisComments` + portada + letras y ReplayGain |
| 06 | `Calculated_Motion` | `06_Calculated_Motion_aac.m4a` | MP4 / M4A (`aac` LC, `faststart`) | Átomos iTunes `ilst`, `covr` (JPEG + PNG), freeform `----`, capítulos MP4, BPM, `stik`/Podcast/Advisory |
| 07 | `Fevered_Strings` | `07_Fevered_Strings_alac.m4a` | MP4 / M4A (`alac` Lossless, `faststart`) | iTunes `ilst` + `covr` PNG + `ExtendedMetadata` |
| 08 | `Firelight_Promise` | `08_Firelight_Promise_24bit_mono.wav` | **Variante WAV 24-bit Mono** (179.1 s, 24.63 MiB) | `RIFF INFO` + bloque `ID3 ` (reemplaza `test_24bit.wav`) |
| 09 | `Flesh_and_Chrome` | `09_Flesh_and_Chrome.wv` | WavPack Lossless (`.wv`) | **APEv2** tags completos + `Cover Art (Front/Back)` binarios + ReplayGain |
| 10 | `La_cicatriz_del_andén` | `10_La_cicatriz_del_andén.aac` | ADTS AAC elemental (`.aac`) | **ID3v2.3** antepuesto a ADTS + acentos UTF-8 (`andén`) + portada JPEG |
| 11 | `Mar_de_cristal` | `11_Mar_de_cristal.mka` | Matroska Audio (FLAC, `.mka`) | Tags XML Matroska + capítulos + múltiples adjuntos portada con **`mkvpropedit`** |
| 12 | `Mi_más_bonita_coincidencia` | `12_Mi_más_bonita_coincidencia_24bit_stereo.wav` | **Variante WAV 24-bit Estéreo** (44.1 kHz, 181.4 s, 45.82 MiB < 50 MB) | `RIFF INFO` + `ID3 ` + portada + acentos UTF-8 (reemplaza `test_24bit_stereo.wav`) |
| 13 | `Overture_for_the_Floor` | `13_Overture_for_the_Floor.webm` | WebM (Opus, 180.9 s) | Metadatos XML globales Matroska-WebM con `mkvpropedit` |
| 14 | `Painting_the_Sky` | `14_Painting_the_Sky.mkv` | Matroska A/V (Opus + H.264, 179.2 s, 2.28 MiB) | Tags XML + adjunto portada con `ffmpeg` + **`mkvpropedit`** |
| 15 | `Resting_At_Your_Feet` | `15_Resting_At_Your_Feet.mp2` | MPEG-1 Layer II (`libtwolame`) | ID3v2.4 + portada JPEG |
| 16 | `Ribbons_on_Anchors` | `16_Ribbons_on_Anchors.oga` | Ogg Audio (`.oga`, Vorbis/FLAC) | `VorbisComments` + portada embebida |
| 17 | `Running_To_Meet_The_Sun` | `17_Running_To_Meet_The_Sun.wav` | WAV RIFF 16-bit Estéreo (154.2 s, 28.30 MiB) | `RIFF INFO` + chunk **`ID3 `** con `APIC` + ReplayGain |
| 18 | `Running_With_Daylight` | `18_Running_With_Daylight.aif` | **Variante Apple AIFF `.aif`** (172.3 s, 31.59 MiB) | Chunks AIFF (`NAME`, `AUTH`, `ANNO`, `(c) `) + `ID3 ` con portada |
| 19 | `Spin_Me_In_The_Dark` | `19_Spin_Me_In_The_Dark.rf64` | EBU RF64 (`.rf64`, 181.2 s, 33.22 MiB) | `bext` + `RIFF INFO` + chunk `ID3 ` con portada |
| 20 | `Swallowing_This_Glitter_Pill` | `20_Swallowing_This_Glitter_Pill.w64` | Sony Wave64 (`.w64`, 159.1 s, 29.14 MiB) | Contenedor 64-bit GUID (`ExtendedPcmReader`) |
| 21 | `The_Great_Equalizer` | `21_The_Great_Equalizer.bwf` | Broadcast Wave (`.bwf`, 160.5 s, 29.41 MiB) | **`bext` completo** (`Description`, `Originator`, `TimeReference`, `CodingHistory`) + `INFO` + `ID3 ` |
| 22 | `The_Midnight_Pursuit` | `22_The_Midnight_Pursuit.rifx` | Big-Endian RIFX (`.rifx`, 175.7 s, 32.24 MiB) | Contenedor `RIFX`/`WAVE` BE con `LIST INFO` + `ID3 ` |
| 23 | `Tracing_Lines` | `23_Tracing_Lines.aifc` | **Variante Apple AIFF-C `.aifc`** (179.1 s, 32.82 MiB) | `FORM/AIFC` + `FVER` + chunks AIFF + `ID3 ` |
| 24 | `Tracks_Into_The_Dawn` | `24_Tracks_Into_The_Dawn.aiff` | **Variante Apple AIFF `.aiff`** (183.0 s, 33.56 MiB) | Chunks AIFF estándar + `ID3 ` completo con portada |
| 25 | `Velocity_of_One` | `25_Velocity_of_One.ape` | Monkey's Audio (`.ape`, 44.1 kHz, 181.3 s, 19.70 MiB) | Decodificador `ApeReader` + etiquetas **APEv2** completas (generado con `mac`) |
| 26 | `Where_Miracles_Start` | `hls/26_Where_Miracles_Start_aes.m3u8` | **Variante HLS cifrada AES-128-CBC** (`19` `.ts` + `.key`) | Prueba de parseo M3U8 (`#EXT-X-KEY` / `EncryptionKeyInfo`) y rechazo seguro sin fallo de motor |
| 27 | `¡Yo_me_opongo_` | `27_¡Yo_me_opongo_.caf` | Apple Core Audio (`.caf`, 177.1 s, 32.43 MiB) | Átomo `info` (`title`, `artist`, `album`, etc.) + Unicode (`¡!`) |
| 28 | `Разводят_мосты` | `hls/28_Разводят_мосты.m3u8` (`19` `.ts`) | HLS VOD claro (`-f hls -hls_time 10`, 180.5 s) | Segmentos MPEG-TS AAC + etiquetas ID3 en transporte TS + UTF-8 cirílico |
| 29 | `駆け抜けて、この空を` | `29_駆け抜けて、この空を.dsf` | Sony DSD64 Mono (`.dsf`, 176.5 s, 59.38 MiB < 100 MB) | PDM 2.8224 MHz mono + bloque **ID3v2.4 final** con portada PNG y japonés UTF-8 |

Además, dentro de `example/assets/music/tripartite/` se regeneran los **6 fixtures de casos borde de buffer** derivados directamente de pistas de esta misma tabla (eliminando toda dependencia con copyright como `la_isla_bonita.m4a`):
* `giant_cover.mp3` (portada extraída del `.mp4` a `1024x1024` > 350 KB)
* `giant_cover.flac` (bloque `PICTURE` > 300 KB)
* `eof_chirp.mp3` (sobre la variante CBR mono con APEv2/ID3v1 con falsos sync `0xFF 0xFB`)
* `non_faststart.m4a` (M4A con átomo `moov` al final después de `mdat`)
* `trailing_chunks.wav` (WAV con `LIST`/`INFO` posterior a `data`)
* `head_3mb_tail_25kb.mp3` (cabecera ID3v2 > 3 MB y cola APEv2/ID3v1 de 25 KB)

---

## 5. Estado de Cambios Implementados (`example/` y `test/`) *(Completado)*

### 5.1 Actualizaciones en `example/` ([`mock_data.dart`](../example/lib/models/mock_data.dart) y [`pubspec.yaml`](../example/pubspec.yaml)) *(Completado)*
1. **Empaquetado selectivo por plataforma en [`example/pubspec.yaml`](../example/pubspec.yaml)**:
   * **Escritorio (`windows`, `macos`, `linux`)**: mantiene `- path: assets/music/` con los 27 archivos raíz locales (`~559 MiB`) para pruebas offline sin red.
   * **Móvil y Web (`android`, `ios`, `web`)**: declara únicamente los **4 formatos comprimidos ligeros** (`01_Apex_Momentum.mp3`, `02_Bailando_con_tu_recuerdo.opus`, `05_Burning_in_the_Electric_Light.ogg`, `06_Calculated_Motion_aac.m4a`, **~`13.5 MiB`** en total).
2. **Completado híbrido de catálogo en `MockData.loadTracks()`**:
   * Inspecciona `AssetManifest.loadFromAssetBundle(root)` para detectar qué pistas existen localmente en el bundle de la plataforma destino (cargadas como `asset://assets/music/...` con badge `ASSET`).
   * Recorre la tabla canónica ordenada de las pistas reproducibles del catálogo (`#01`–`#25`, `#27`, `hls/28_Разводят_мосты.m3u8` VOD y `#29`; excluye `#26` AES-128 HLS por no tener descifrado en reproducción), completando automáticamente cualquier canción ausente en el bundle local con su enlace remoto HTTPS en `https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/...` (codificación URI segura para UTF-8).
   * En escritorio (donde los 27 archivos raíz son locales), añade además un enlace de muestra HTTP progresivo (`Apex Momentum (Remote HTTP MP3)`) junto con `Radio FIP` (`icy://`) y la onda PCM sintetizada (`data: URI`).
   * **Sin `fallbackAssets` rotos en `pub.dev`**: Si `AssetManifest` no encuentra archivos locales (ej. clon sin submódulo o descarga desde `pub.dev`), el catálogo entero se resuelve vía HTTPS sin rutas inexistentes.

### 5.2 Actualizaciones en `test/` y `test/rust/` *(Completado)*
1. Actualizar `FixtureResolver` en `test/rust/` y los helpers/tests en `test/` para resolver directamente desde `example/assets/music/` (y `example/assets/music/tripartite/` / `hls/`).
2. Actualizar [`../test/MANIFEST.md`](../test/MANIFEST.md), [`../example/assets/music/README.md`](../example/assets/music/README.md) e [`../test/helpers/generate_tripartite_fixtures.py`](../test/helpers/generate_tripartite_fixtures.py) y eliminar todos los archivos viejos con copyright de `test/fixtures/` y `example/assets/music/`.
3. Ajustar aserciones de duración/nombre/ReplayGain en [`../test/rust/decoder_and_formats_test.rs`](../test/rust/decoder_and_formats_test.rs) y tests Dart que antes validaban duraciones fijas de `salida.*`, `cbr_noxing.mp3` u `Ojitos Mentirosos...mkv`.
