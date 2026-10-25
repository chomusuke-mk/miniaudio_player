// ignore_for_file: avoid_print
import 'dart:io';

void main(List<String> args) async {
  print(
      '=== Building miniaudio_player WebAssembly (wasm32 + SIMD128 + Brotli) ===');

  final emsdkPath = Platform.environment['EMSDK'] ?? (throw Exception('EMSDK environment variable is not set'));
  final emccPath = Platform.environment['EMCC'] ??
      (File('$emsdkPath/upstream/emscripten/emcc').existsSync()
          ? '$emsdkPath/upstream/emscripten/emcc'
          : 'emcc');
  final wasmOptPath = Platform.environment['WASM_OPT'] ??
      (File('$emsdkPath/upstream/bin/wasm-opt').existsSync()
          ? '$emsdkPath/upstream/bin/wasm-opt'
          : 'wasm-opt');
  final brotliPath = 'brotli';

  // Ensure output dirs exist
  final buildDir = Directory('build/web');
  final assetsDir = Directory('assets/web');
  if (!buildDir.existsSync()) buildDir.createSync(recursive: true);
  if (!assetsDir.existsSync()) assetsDir.createSync(recursive: true);

  final List<String> sources = [
    'src/miniaudio_impl.c',
    'src/map_silence.c',
    'src/map_reverb.c',
    'src/map_dsp.c',
    'src/map_source.c',
    'src/map_buffer.c',
    'src/map_device.c',
    'src/map_analysis.c',
    'src/map_sniffer.c',
    'src/map_event_dispatcher.c',
    'src/miniaudio_player.c',
    'src/map_wasm_bridge.c',
    'src/sonic/sonic.c',
    'src/decoders/libogg/bitwise.c',
    'src/decoders/libogg/framing.c',
    'src/decoders/libopus/miniaudio_libopus.c',
    'src/decoders/libopus/opusfile.c',
    'src/decoders/libopus/info.c',
    'src/decoders/libopus/internal.c',
    'src/decoders/libopus/stream.c',
    'src/decoders/libopus/opus_src/opus.c',
    'src/decoders/libopus/opus_src/opus_decoder.c',
    'src/decoders/libopus/opus_src/opus_multistream.c',
    'src/decoders/libopus/opus_src/opus_multistream_decoder.c',
    'src/decoders/libopus/opus_src/repacketizer.c',
    'src/decoders/libopus/opus_src/mapping_matrix.c',
    'src/decoders/libopus/opus_src/extensions.c',
    'src/decoders/aac/miniaudio_aac.c',
    'src/decoders/alac/alac.c',
  ];

  void addCDir(String path) {
    final dir = Directory(path);
    if (dir.existsSync()) {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.c'))
          .map((f) => f.path)
          .toList()
        ..sort();
      sources.addAll(files);
    }
  }

  addCDir('src/decoders/libopus/celt');
  addCDir('src/decoders/libopus/silk');
  addCDir('src/decoders/libopus/silk/float');
  addCDir('src/decoders/helix-aac');

  final exportedFunctions = [
    '_malloc',
    '_free',
    '_map_wasm_get_staging_ptr',
    '_map_wasm_get_staging_capacity',
    '_map_wasm_player_create',
    '_map_wasm_player_destroy',
    '_map_wasm_malloc',
    '_map_wasm_free',
    '_map_wasm_play',
    '_map_wasm_pause',
    '_map_wasm_stop',
    '_map_wasm_seek',
    '_map_wasm_get_position_ms',
    '_map_wasm_get_duration_ms',
    '_map_wasm_get_state',
    '_map_wasm_is_playing',
    '_map_wasm_is_buffering',
    '_map_wasm_is_completed',
    '_map_wasm_get_silence_saved_ms',
    '_map_wasm_get_bitrate',
    '_map_wasm_get_sample_rate',
    '_map_wasm_get_channels',
    '_map_wasm_open_memory',
    '_map_wasm_open_stream',
    '_map_wasm_open_stream_ex',
    '_map_wasm_stream_feed',
    '_map_wasm_stream_flush',
    '_map_wasm_stream_seek',
    '_map_wasm_stream_get_seek_byte',
    '_map_wasm_get_audio_data_offset',
    '_map_wasm_stream_get_pinned_head_size',
    '_map_wasm_stream_end',
    '_map_wasm_probe_tail',
    '_map_wasm_set_volume',
    '_map_wasm_get_volume',
    '_map_wasm_set_playback_rate',
    '_map_wasm_get_playback_rate',
    '_map_wasm_set_pitch',
    '_map_wasm_get_pitch',
    '_map_wasm_set_pan',
    '_map_wasm_set_equalizer_band',
    '_map_wasm_set_equalizer_bands',
    '_map_wasm_set_equalizer_enabled',
    '_map_wasm_set_reverb_enabled',
    '_map_wasm_set_reverb_preset',
    '_map_wasm_set_crossfeed_enabled',
    '_map_wasm_set_crossfeed_preset',
    '_map_wasm_set_limiter_enabled',
    '_map_wasm_set_silence_skip',
    '_map_wasm_set_visualizer_enabled',
    '_map_wasm_render_pcm_frames',
    '_map_wasm_poll_telemetry',
    '_map_wasm_analyze_audio_memory',
  ];

  final cmdArgs = [
    ...sources,
    '-Isrc',
    '-Isrc/sonic',
    '-Isrc/decoders/include',
    '-Isrc/decoders/include/opus',
    '-Isrc/decoders/include/ogg',
    '-Isrc/decoders/libogg',
    '-Isrc/decoders/libopus',
    '-Isrc/decoders/libopus/opus_src',
    '-Isrc/decoders/libopus/celt',
    '-Isrc/decoders/libopus/silk',
    '-Isrc/decoders/libopus/silk/float',
    '-Isrc/decoders/helix-aac',
    '-Isrc/decoders/minimp4',
    '-Isrc/decoders/aac',
    '-Isrc/decoders/alac',
    '-std=c99',
    '-O3',
    '-flto',
    '-msimd128',
    '-mrelaxed-simd',
    '-fomit-frame-pointer',
    '-fno-math-errno',
    '-ffp-contract=fast',
    '-fno-trapping-math',
    '-DDART_SHARED_LIB=1',
    '-DMINIAUDIO_PLAYER_EXPORTS=1',
    '-DOPUS_BUILD=1',
    '-DHAVE_LRINT=1',
    '-DHAVE_LRINTF=1',
    '-DFLOAT_APPROX=1',
    '-DUSE_DEFAULT_STDLIB=1',
    '-DVAR_ARRAYS=1',
    '-DMA_NO_DEVICE_IO=1',
    '-sWASM=1',
    '-sUSE_PTHREADS=0',
    '-sFILESYSTEM=0',
    '-sALLOW_MEMORY_GROWTH=1',
    '-sINITIAL_MEMORY=16777216',
    '-sMAXIMUM_MEMORY=268435456',
    '-sSTACK_SIZE=262144',
    '-sSTANDALONE_WASM=0',
    '-sMODULARIZE=1',
    '-sEXPORT_NAME=createMiniaudioModule',
    '-sEXPORT_ES6=0',
    '-sENVIRONMENT=worker,web',
    '-sEXPORTED_RUNTIME_METHODS=["HEAPU8","HEAP32","HEAPU32","HEAPF32","HEAPF64"]',
    "-sEXPORTED_FUNCTIONS=['${exportedFunctions.join("','")}']",
    '-o',
    'build/web/miniaudio_player.js',
  ];

  print('1. Compiling with emcc...');
  final env = Map<String, String>.from(Platform.environment);
  if (!env.containsKey('EMSDK')) {
    env['EMSDK'] = emsdkPath;
    env['PATH'] = '$emsdkPath:$emsdkPath/upstream/emscripten:${env['PATH']}';
  }

  final compileResult = await Process.run(emccPath, cmdArgs, environment: env);
  if (compileResult.exitCode != 0) {
    print('emcc failed with exit code ${compileResult.exitCode}:');
    print(compileResult.stderr);
    print(compileResult.stdout);
    exit(1);
  }
  print('emcc compilation succeeded.');

  // Check generated wasm
  final wasmFile = File('build/web/miniaudio_player.wasm');
  if (!wasmFile.existsSync()) {
    print('Error: build/web/miniaudio_player.wasm not generated');
    exit(1);
  }
  print(
      'Raw Wasm size: ${(wasmFile.lengthSync() / 1024).toStringAsFixed(1)} KB');

  // Run wasm-opt if available
  print('2. Optimizing with wasm-opt...');
  try {
    final optResult = await Process.run(
        wasmOptPath,
        [
          '-O3',
          '--enable-simd',
          '--enable-relaxed-simd',
          '--enable-bulk-memory',
          '--enable-nontrapping-float-to-int',
          '--strip-debug',
          'build/web/miniaudio_player.wasm',
          '-o',
          'build/web/miniaudio_player.wasm',
        ],
        environment: env);
    if (optResult.exitCode == 0) {
      print(
          'wasm-opt succeeded. Optimized Wasm size: ${(wasmFile.lengthSync() / 1024).toStringAsFixed(1)} KB');
    } else {
      print('wasm-opt warning: ${optResult.stderr}');
    }
  } catch (e) {
    print('wasm-opt skipped: $e');
  }

  // Copy uncompressed wasm to assets/web
  wasmFile.copySync('assets/web/miniaudio_player.wasm');

  // Compress with brotli
  print('3. Compressing with Brotli (-q 11)...');
  final brotliResult = await Process.run(brotliPath, [
    '-q',
    '11',
    '-w',
    '24',
    '-f',
    'build/web/miniaudio_player.wasm',
    '-o',
    'assets/web/miniaudio_player.wasm.br',
  ]);
  if (brotliResult.exitCode != 0) {
    print('brotli failed: ${brotliResult.stderr}');
    exit(1);
  }

  final brFile = File('assets/web/miniaudio_player.wasm.br');
  print(
      'Brotli compressed size: ${(brFile.lengthSync() / 1024).toStringAsFixed(1)} KB');
  print('=== WebAssembly build completed successfully! ===');
}
