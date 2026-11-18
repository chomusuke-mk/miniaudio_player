# Test Assets & Fixture Manifest (`test/MANIFEST.md`)

`miniaudio_player` centralizes all audio fixtures inside the single Git submodule at [`../example/assets/music/`](../example/assets/music) (`miniaudio_player_assets`).

> **Zero duplication & clean `.pubignore`**:
>
> - No audio binaries are stored inside `test/` (legacy `test/fixtures/` binaries have been removed).
> - Rust integration tests (`test/rust/`), Dart/Flutter tests (`test/`), `example/test/`, and the example app itself all share `example/assets/music/`.
> - [`../.pubignore`](../.pubignore) excludes `/test/`, `/example/assets/music/`, and `/.gitmodules` so published `pub.dev` tarballs remain lightweight (`~4 MB` compressed, `0` bytes of sample audio).
> - For the complete 29-track inventory, artwork pipeline, and generator details, see [`../example/assets/music/README.md`](../example/assets/music/README.md).

---

## 1. Quick Setup

Initialize the asset submodule after cloning the repository:

```bash
git submodule update --init example/assets/music
```

### Path Resolution in Tests

- **Rust (`test/rust/`)**: [`FixtureResolver`](rust/common/mod.rs) resolves paths relative to `CARGO_MANIFEST_DIR/../example/assets/music/`.
- **Dart / Flutter (`test/`)**: Test helpers resolve paths relative to the repository root (`example/assets/music/...`).
- **Local Adversarial HTTP Server**: [`test/helpers/test_http_server.py`](helpers/test_http_server.py) defaults `--dir` to `example/assets/music` and resolves root tracks, `tripartite/`, and `hls/` (`.m3u8`, `.ts`, `.key`) including URL-decoded Unicode filenames.

---

## 2. Test-to-Fixture Contract

### 2.1 Core Format, Metadata & ReplayGain Suites

| Track / Directory                                                                       | Primary Test Consumers                                                                                                                                                                                                         | Verified Invariants                                                                                                                                                                                                                                                                                                |
| :-------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `01_Apex_Momentum.mp3`                                                                  | [`replay_gain_test.dart`](replay_gain_test.dart), [`uri_playback_test.dart`](uri_playback_test.dart), [`metadata_and_audio_info_test.dart`](metadata_and_audio_info_test.dart), [`visualizer_test.dart`](visualizer_test.dart) | 48 kHz stereo MP3 (`176.8 s`); `ID3v2` header is `161,876 B` (4 embedded covers, 86 keys); ReplayGain peak `~1.05`, LUFS `~-12.2`, gain `~-5.75 dB` @ `-18` target; initial silence ~`0.96 s` (`maxAnalysisDuration` tests use `2 s`). Mid-stream TCP drop tests use `?after=393216` to clear the `161 KB` header. |
| `03_Before_The_Dawn_cbr_noxing.mp3`                                                     | [`miniaudio_player_test.dart`](miniaudio_player_test.dart), [`decoder_and_formats_test.rs`](rust/decoder_and_formats_test.rs), [`engine/miniaudio_engine_fsm_test.dart`](engine/miniaudio_engine_fsm_test.dart)                | 44.1 kHz mono CBR MP3 (`180.0 s`) without Xing/VBRI header; validates mono→stereo upmix & CBR duration estimation.                                                                                                                                                                                                 |
| `04_Belaya_Tishina.flac`                                                                | [`metadata_and_audio_info_test.dart`](metadata_and_audio_info_test.dart), [`decoder_and_formats_test.rs`](rust/decoder_and_formats_test.rs)                                                                                    | 24-bit 48 kHz FLAC with non-CDDA `CUESHEET` (`is_compact_disc=0x00`), 3 covers, UTF-8 Vorbis Comments, and extended tags.                                                                                                                                                                                          |
| `08_Firelight_Promise_24bit_mono.wav`, `12_Mi_más_bonita_coincidencia_24bit_stereo.wav` | [`local_formats_test.dart`](local_formats_test.dart), [`engine/miniaudio_engine_fsm_test.dart`](engine/miniaudio_engine_fsm_test.dart)                                                                                         | 24-bit LE PCM (`48 kHz` mono `179.1 s` and `44.1 kHz` stereo `181.4 s`); validates 24-bit normalization, seeks, and auto-crossfade EOF transitions relative to `duration`.                                                                                                                                         |
| `17_Running_To_Meet_The_Sun.wav`                                                        | [`replay_gain_test.dart`](replay_gain_test.dart), [`recording_and_buffer_test.dart`](recording_and_buffer_test.dart), stress suites                                                                                            | Baseline 16-bit 48 kHz stereo WAV (`154.2 s`); ReplayGain LUFS `~-11.7`, gain `~-5.41 dB`.                                                                                                                                                                                                                         |
| All 27 root containers (`01`..`25`, `27`, `29`)                                         | [`decoder_and_formats_test.rs`](rust/decoder_and_formats_test.rs), [`local_formats_test.dart`](local_formats_test.dart)                                                                                                        | Container sniffing, sample rate/channels, metadata/artwork parsing, seek accuracy (excluding non-seekable elemental ADTS `10_La_cicatriz_del_andén.aac`).                                                                                                                                                          |

### 2.2 HLS Playlists (`example/assets/music/hls/`)

- **`hls/28_Разводят_мосты.m3u8`** (19 `.ts` segments): Tested end-to-end for multi-segment VOD HLS HTTP playback in [`hls_test.dart`](hls_test.dart) and playlist/demux checks in [`hls_and_crypto_test.rs`](rust/hls_and_crypto_test.rs).
- **`hls/26_Where_Miracles_Start_aes.m3u8`** (19 AES-128-CBC `.ts` segments + `26_Where_Miracles_Start.key`): Verified by [`hls_and_crypto_test.rs`](rust/hls_and_crypto_test.rs) for `#EXT-X-KEY` parsing (`EncryptionKeyInfo`) and by [`hls_test.dart`](hls_test.dart) for clean error rejection (`MiniaudioPlayerException`, zero engine crash) since runtime AES-128 segment decryption is not yet wired into playback.

### 2.3 Buffer & Metadata Edge Cases (`example/assets/music/tripartite/`)

Consumed by [`buffer_and_source_test.rs`](rust/buffer_and_source_test.rs) and [`tripartite_buffer_metabytes_test.dart`](tripartite_buffer_metabytes_test.dart):

- `giant_cover.mp3`: Oversized `APIC` PNG cover (`> 360 KB`).
- `giant_cover.flac`: Compact FLAC containing a `1024×1024` `image/png` `PICTURE` block (`description: 'Giant 1024x1024 Cover'`, `1.16 MB`).
- `eof_chirp.mp3`: Trailing APEv2 + ID3v1 tags containing fake `0xFF 0xFB` syncwords.
- `non_faststart.m4a`: Trailing `5,898 B` `moov` atom after `mdat`; synthesized `.metadata` measures `5,942 B` (`< 30 KB`, `> 4 KB`).
- `trailing_chunks.wav`: 24-bit mono WAV with trailing `LIST/INFO` chunk (`INAM: 'Trailing Chunk Artist'`).
- `head_3mb_tail_25kb.mp3`: `3.15 MB` `PRIV` ID3v2.3 header + full CBR audio + `~25 KB` APEv2/ID3v1 tail (tested with `bufferSizeFrames: 1024`, `bufferNetworkDuration: 5s`).

### 2.4 Benchmark Corpus (`example/assets/music/library/`)

- 50 short (`3.5 s`) files (`sample_01`..`sample_10` across `opus`, `m4a`, `mp3`, `wav`, `flac`), consumed by [`benchmark_test.rs`](rust/benchmark_test.rs) for deterministic p95 open & seek latency assertions.

---

## 3. Regenerating `tripartite/` Only

While full asset generation lives in [`example/assets/music/scripts/build_assets.py`](../example/assets/music/scripts/build_assets.py), you can also rebuild the 6 `tripartite/` edge-case files directly from the submodule tracks:

```bash
python3 test/helpers/generate_tripartite_fixtures.py
```

---

## 4. Verification Commands

Run the full test and static analysis suite sequentially (`-j 1` avoids ALSA hardware contention across Dart suites):

```bash
# Static analysis
dart analyze
(cd example && flutter analyze)

# Rust unit + integration suites
cargo test --manifest-path rust/Cargo.toml --lib
cargo test --manifest-path rust/Cargo.toml --tests

# Flutter / Dart suites (root + example app)
flutter test -j 1
(cd example && flutter test -j 1)
```
