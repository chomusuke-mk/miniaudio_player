import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final packageName = input.packageName;
    final targetOS = input.config.code.targetOS;

    final List<String> libraries = [];
    final Map<String, String> defines = {
      'DART_SHARED_LIB': '1',
      'MINIAUDIO_PLAYER_EXPORTS': '1',
      'OPUS_BUILD': '1',
      'HAVE_LRINT': '1',
      'HAVE_LRINTF': '1',
      'FLOAT_APPROX': '1',
      'USE_DEFAULT_STDLIB': '1',
    };

    final List<String> sources = [
      'src/miniaudio_impl.c',
      'src/map_silence.c',
      'src/map_dsp.c',
      'src/map_source.c',
      'src/map_device.c',
      'src/map_analysis.c',
      'src/miniaudio_player.c',
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
        final files =
            dir
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

    final List<String> commonFlags = [];
    final List<String> linkFlags = [];

    if (targetOS == OS.linux) {
      libraries.addAll(['pthread', 'm', 'dl']);
      defines['_GNU_SOURCE'] = '1';
      defines['VAR_ARRAYS'] = '1';
      commonFlags.addAll([
        '-std=c99',
        '-O3',
        '-fomit-frame-pointer',
        '-fno-math-errno',
        '-ffp-contract=fast',
        '-fno-trapping-math',
      ]);
    } else if (targetOS == OS.windows) {
      libraries.addAll(['ole32', 'uuid', 'winmm', 'advapi32']);
      defines['_CRT_SECURE_NO_WARNINGS'] = '1';
      defines['USE_ALLOCA'] = '1';
      // MSVC-compatible flags when compiling on Windows
      commonFlags.addAll([
        '/std:c11',
        '/fp:precise',
      ]);
    } else if (targetOS == OS.android) {
      libraries.addAll(['OpenSLES', 'log', 'm', 'dl']);
      defines['VAR_ARRAYS'] = '1';
      commonFlags.addAll([
        '-std=c99',
        '-O3',
        '-fomit-frame-pointer',
        '-fno-math-errno',
        '-ffp-contract=fast',
        '-fno-trapping-math',
      ]);

      // Android 15+ 16 KB Page Size ELF Segment Alignment
      linkFlags.addAll(['-Wl,-z,max-page-size=16384']);

      // 32-bit ARM NEON Hardware Activation
      if (input.config.code.targetArchitecture == Architecture.arm) {
        commonFlags.addAll(['-mfpu=neon-vfpv4', '-mfloat-abi=softfp']);
        defines['OPUS_ARM_MAY_HAVE_NEON_INTR'] = '1';
      } else if (input.config.code.targetArchitecture == Architecture.arm64) {
        defines['OPUS_ARM_PRESUME_AARCH64_NEON_INTR'] = '1';
      }
    } else {
      defines['VAR_ARRAYS'] = '1';
      commonFlags.addAll(['-std=c99', '-O3']);
    }

    final cbuilder = CBuilder.library(
      name: packageName,
      assetName: '${packageName}_bindings_generated.dart',
      sources: sources,
      includes: [
        'src',
        'src/sonic',
        'src/decoders/include',
        'src/decoders/include/opus',
        'src/decoders/include/ogg',
        'src/decoders/libogg',
        'src/decoders/libopus/opus_src',
        'src/decoders/libopus/celt',
        'src/decoders/libopus/silk',
        'src/decoders/libopus/silk/float',
        'src/decoders/helix-aac',
        'src/decoders/minimp4',
        'src/decoders/aac',
        'src/decoders/alac',
      ],
      libraries: libraries,
      defines: defines,
      flags: [...commonFlags, ...linkFlags],
    );

    hierarchicalLoggingEnabled = true;
    final logger = Logger(packageName)
      ..level = Level.ALL
      ..onRecord.listen((record) {
        // ignore: avoid_print
        print(record.message);
      });

    await cbuilder.run(input: input, output: output, logger: logger);
  });
}
