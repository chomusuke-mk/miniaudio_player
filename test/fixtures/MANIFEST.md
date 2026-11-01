# Manifiesto de Archivos de Prueba (`test/fixtures/`)

Este directorio centraliza **todos** los archivos de audio requeridos por las suites de pruebas de Rust (`test/rust/`) y Dart (`test/`).

> **Importante**: Para no inflar el peso del repositorio en Git, los archivos binarios de audio dentro de `test/fixtures/` están excluidos en `.gitignore` y `.pubignore`. Únicamente este manifiesto (`MANIFEST.md`) forma parte del control de versiones. Quienes clonen el repositorio deben generar los archivos localmente siguiendo las instrucciones deterministas detalladas a continuación.

---

## 1. Catálogo de Archivos Requeridos en `test/fixtures/`

| Archivo | Contenedor / Formato | Códec | Tasa de Muestreo | Canales | Duración Aprox. | Propósito en Pruebas |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `salida.wav` | RIFF WAVE (`.wav`) | PCM 16-bit LE | 48000 Hz | 2 (Estéreo) | ~68 s | Decodificación base, seek, streaming RIFF |
| `test_24bit.wav` | RIFF WAVE (`.wav`) | PCM 24-bit LE | 44100 Hz | 1 (Mono) | ~2 s | Normalización de 24 bits y recorte de colas |
| `test_24bit_stereo.wav` | RIFF WAVE (`.wav`) | PCM 24-bit LE | 44100 Hz | 2 (Estéreo) | ~10 s | Reproducción y seek PCM 24-bit estéreo |
| `salida.rf64` | EBU RF64 (`.rf64`) | PCM 16-bit LE | 48000 Hz | 2 (Estéreo) | ~68 s | Contenedor WAVE de 64 bits (`RF64` + `ds64`) |
| `salida.rifx` | RIFF Big-Endian (`.rifx`) | PCM 16-bit BE | 48000 Hz | 2 (Estéreo) | ~68 s | Contenedor WAVE Big-Endian (`RIFX`) |
| `salida.w64` | Sony Wave64 (`.w64`) | PCM 16-bit LE | 48000 Hz | 2 (Estéreo) | ~68 s | Contenedor GUID de 64 bits (`riff` Wave64) |
| `salida.bwf` | Broadcast Wave (`.bwf`) | PCM 16-bit LE | 48000 Hz | 2 (Estéreo) | ~68 s | WAVE profesional con metadatos `bext` |
| `salida.aif` | Apple AIFF (`.aif`) | PCM 16-bit BE | 48000 Hz | 2 (Estéreo) | ~68 s | Contenedor IFF/AIFF estándar |
| `salida.aiff` | Apple AIFF (`.aiff`) | PCM 16-bit BE | 48000 Hz | 2 (Estéreo) | ~68 s | Variante de extensión `.aiff` |
| `salida.aifc` | Apple AIFF-C (`.aifc`) | PCM 16-bit BE | 48000 Hz | 2 (Estéreo) | ~68 s | Contenedor AIFF-C (`AIFC`) |
| `salida.caf` | Apple Core Audio (`.caf`) | PCM 16-bit BE | 48000 Hz | 2 (Estéreo) | ~68 s | Contenedor `caff` Core Audio Format |
| `salida.flac` | FLAC Nativo (`.flac`) | FLAC Lossless | 48000 Hz | 2 (Estéreo) | ~68 s | Integridad de velocidad 1.0x y seek exacto |
| `salida_alac.m4a` | ISO MP4/M4A (`.m4a`) | ALAC Lossless | 48000 Hz | 2 (Estéreo) | ~68 s | Decodificación ALAC sin aceleración espuria |
| `salida_aac.m4a` | ISO MP4/M4A (`.m4a`) | AAC-LC | 48000 Hz | 2 (Estéreo) | ~68 s | Contenedor M4A con AAC-LC (`fdk-aac`) |
| `salida.aac` | AAC ADTS (`.aac`) | AAC-LC | 48000 Hz | 2 (Estéreo) | ~68 s | Flujo elemental AAC con cabeceras ADTS |
| `salida.mp3` | MPEG-1 Audio (`.mp3`) | MP3 Layer 3 | 48000 Hz | 2 (Estéreo) | ~68 s | Continuidad de fase, streaming y ReplayGain |
| `cbr_noxing.mp3` | MPEG-1 Audio (`.mp3`) | MP3 CBR (Sin Xing) | 44100 Hz | 1 (Mono) | ~14 s | Upmix Mono->Estéreo y estimación CBR |
| `salida.mp2` | MPEG-1 Audio (`.mp2`) | MP2 Layer 2 | 48000 Hz | 2 (Estéreo) | ~68 s | Decodificación MPEG-1 Audio Layer II |
| `salida.ogg` | Ogg (`.ogg`) | Vorbis | 48000 Hz | 2 (Estéreo) | ~68 s | Demuxing Ogg y decodificación Vorbis |
| `salida.oga` | Ogg Audio (`.oga`) | Vorbis | 48000 Hz | 2 (Estéreo) | ~68 s | Extensión `.oga` de Ogg Audio |
| `salida.opus` | Ogg Opus (`.opus`) | Opus (`libopus`) | 48000 Hz | 2 (Estéreo) | ~68 s | Decodificación Opus vía FFI `libopus` |
| `salida.webm` | WebM (`.webm`) | Opus | 48000 Hz | 2 (Estéreo) | ~68 s | Contenedor Matroska/WebM con audio Opus |
| `salida.mka` | Matroska Audio (`.mka`) | FLAC | 48000 Hz | 2 (Estéreo) | ~68 s | Contenedor Matroska `.mka` con audio FLAC |
| `salida.wv` | WavPack (`.wv`) | WavPack Lossless | 48000 Hz | 2 (Estéreo) | ~68 s | Decodificador `WavpackReader` (`wavicle`) |
| `salida.dsf` | Sony DSF (`.dsf`) | DSD64 (2.8224 MHz) | 88200 Hz (PCM) | 2 (Estéreo) | ~68 s | Diezmado FIR Sigma-Delta PDM a PCM 88.2 kHz |
| `salida.ape` | Monkey's Audio (`.ape`) | APE v3.99 (`MAC `) | 44100 Hz | 2 (Estéreo) | ~8 s | Decodificador `ApeReader` (`ape-decoder`) |
| `salida.m3u8` | HLS Playlist (`.m3u8`) | Texto UTF-8 M3U8 | N/A | N/A | ~68 s | Lista de reproducción VOD con 7 segmentos |
| `salida_0.ts` .. `salida_6.ts` | MPEG-2 TS (`.ts`) | AAC ADTS (`0x0F`) | 48000 Hz | 2 (Estéreo) | ~10 s c/u | Demuxing PAT/PMT/PES y extracción ADTS |

---

## 2. Subdirectorio `test/fixtures/tripartite/` (Casos Borde de Buffer)

Generados automáticamente por `python3 test/helpers/generate_tripartite_fixtures.py`:

* `giant_cover.mp3`: MP3 con etiqueta ID3v2 `APIC` > 350 KB al inicio.
* `giant_cover.flac`: FLAC con bloque de metadatos `PICTURE` > 300 KB.
* `eof_chirp.mp3`: MP3 con etiquetas finales APEv2 + ID3v1 que contienen falsas palabras de sincronismo `0xFF 0xFB`.
* `non_faststart.m4a`: Contenedor MP4/M4A con el átomo `moov` ubicado al final del archivo (después de `mdat`).
* `trailing_chunks.wav`: Archivo WAV con chunks `LIST`/`INFO` posteriores al chunk `data`.
* `head_3mb_tail_25kb.mp3`: Archivo MP3 con cabecera ID3v2 de 3 MB y cola APEv2/ID3v1 de 25 KB.

---

## 3. Subdirectorio `test/fixtures/library/` (Lotes para Benchmark de Apertura y Seek)

Contiene muestras organizadas por formato para validar latencias de apertura y búsqueda (`p95`) sin depender de rutas del sistema anfitrión:

* `test/fixtures/library/opus/sample_01.opus` .. `sample_10.opus`
* `test/fixtures/library/m4a/sample_01.m4a` .. `sample_10.m4a`
* `test/fixtures/library/mp3/sample_01.mp3` .. `sample_10.mp3`
* `test/fixtures/library/wav/sample_01.wav` .. `sample_10.wav`
* `test/fixtures/library/flac/sample_01.flac` .. `sample_10.flac`

---

## 4. Cómo Generar Todos los Archivos Localmente

Desde la raíz del repositorio (`miniaudio_player/`), ejecute los siguientes comandos con `ffmpeg`, `python3` y `curl`:

```bash
# 1. Crear estructura de directorios
mkdir -p test/fixtures/tripartite \
         test/fixtures/library/{opus,m4a,mp3,wav,flac}

# 2. Generar archivo base WAV estéreo de 68s (48 kHz, 16-bit) y variantes
ffmpeg -y -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=68" \
       -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=68" \
       -filter_complex "[0:a][1:a]amerge=inputs=2[a]" -map "[a]" \
       -c:a pcm_s16le test/fixtures/salida.wav

ffmpeg -y -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=2" \
       -c:a pcm_s24le test/fixtures/test_24bit.wav

ffmpeg -y -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=10" \
       -ac 2 -c:a pcm_s24le test/fixtures/test_24bit_stereo.wav

ffmpeg -y -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=14" \
       -ac 1 -c:a libmp3lame -b:a 128k -write_xing 0 test/fixtures/cbr_noxing.mp3

# 3. Derivar todos los contenedores y códecs desde salida.wav
ffmpeg -y -i test/fixtures/salida.wav -rf64 always -c:a pcm_s16le test/fixtures/salida.rf64
ffmpeg -y -i test/fixtures/salida.wav -f w64 -c:a pcm_s16le test/fixtures/salida.w64
ffmpeg -y -i test/fixtures/salida.wav -write_bext 1 -c:a pcm_s16le test/fixtures/salida.bwf
ffmpeg -y -i test/fixtures/salida.wav -f aiff -c:a pcm_s16be test/fixtures/salida.aif
cp test/fixtures/salida.aif test/fixtures/salida.aiff
cp test/fixtures/salida.aif test/fixtures/salida.aifc
ffmpeg -y -i test/fixtures/salida.wav -f caf -c:a pcm_s16be test/fixtures/salida.caf
ffmpeg -y -i test/fixtures/salida.wav -c:a flac test/fixtures/salida.flac
ffmpeg -y -i test/fixtures/salida.wav -c:a alac test/fixtures/salida_alac.m4a
ffmpeg -y -i test/fixtures/salida.wav -c:a aac -b:a 192k test/fixtures/salida_aac.m4a
ffmpeg -y -i test/fixtures/salida.wav -f adts -c:a aac -b:a 192k test/fixtures/salida.aac
ffmpeg -y -i test/fixtures/salida.wav -c:a libmp3lame -b:a 192k test/fixtures/salida.mp3
ffmpeg -y -i test/fixtures/salida.wav -c:a mp2 -b:a 192k test/fixtures/salida.mp2
ffmpeg -y -i test/fixtures/salida.wav -c:a libvorbis -q:a 5 test/fixtures/salida.ogg
cp test/fixtures/salida.ogg test/fixtures/salida.oga
ffmpeg -y -i test/fixtures/salida.wav -c:a libopus -b:a 128k test/fixtures/salida.opus
ffmpeg -y -i test/fixtures/salida.wav -c:a libopus -b:a 128k test/fixtures/salida.webm
ffmpeg -y -i test/fixtures/salida.wav -c:a flac test/fixtures/salida.mka
ffmpeg -y -i test/fixtures/salida.wav -c:a wavpack test/fixtures/salida.wv

# 4. Generar RIFX (Big-Endian WAVE) y DSF (DSD64)
ffmpeg -y -i test/fixtures/salida.wav -ar 44100 -ac 2 -c:a pcm_s16le /tmp/salida_44100.wav
python3 tool/wav_to_dsf.py /tmp/salida_44100.wav test/fixtures/salida.dsf
rm -f /tmp/salida_44100.wav

python3 -c '
import struct, wave
with wave.open("test/fixtures/salida.wav", "rb") as w:
    ch, sw, sr, nf = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    raw = w.readframes(nf)
samples_be = struct.pack(f">{len(raw)//2}h", *struct.unpack(f"<{len(raw)//2}h", raw))
with open("test/fixtures/salida.rifx", "wb") as f:
    f.write(b"RIFX" + struct.pack(">I", 36 + len(samples_be)) + b"WAVE")
    f.write(b"fmt " + struct.pack(">IHHIIHH", 16, 1, ch, sr, sr * ch * sw, ch * sw, sw * 8))
    f.write(b"data" + struct.pack(">I", len(samples_be)) + samples_be)
'

# 5. Generar playlist HLS (salida.m3u8 + salida_0.ts .. salida_6.ts)
ffmpeg -y -i test/fixtures/salida.wav -c:a aac -b:a 192k \
       -f hls -hls_time 10 -hls_list_size 0 \
       -hls_segment_filename "test/fixtures/salida_%d.ts" \
       test/fixtures/salida.m3u8

# 6. Descargar muestra estándar Monkey's Audio (.ape v3.99) de FFmpeg FATE
curl -sL https://fate-suite.ffmpeg.org/lossless-audio/luckynight-partial.ape \
     -o test/fixtures/salida.ape

# 7. Generar fixtures de casos borde tripartitos y poblar lotes de benchmark
python3 test/helpers/generate_tripartite_fixtures.py
for i in $(seq -w 1 10); do
    cp test/fixtures/salida.opus "test/fixtures/library/opus/sample_${i}.opus"
    cp test/fixtures/salida_aac.m4a "test/fixtures/library/m4a/sample_${i}.m4a"
    cp test/fixtures/salida.mp3 "test/fixtures/library/mp3/sample_${i}.mp3"
    cp test/fixtures/salida.wav "test/fixtures/library/wav/sample_${i}.wav"
    cp test/fixtures/salida.flac "test/fixtures/library/flac/sample_${i}.flac"
done
```
