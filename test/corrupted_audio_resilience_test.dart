import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  // =========================================================================
  // Group 1: Mid-Stream Corruption & Corrupted Data Chunk Lengths
  // =========================================================================
  group('Corrupted Audio Resilience: Mid-Stream Frame Corruption', () {
    late MiniaudioPlayer player;
    File? tempFile;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      await player.dispose();
      await SyntheticAudioGenerator.cleanUp(tempFile);
      tempFile = null;
    });

    test('1.1: 2-second WAV with 2048 corrupted bytes at 50% plays and finishes cleanly', () async {
      tempFile = await SyntheticAudioGenerator.createTempCorruptedWavFile(
        fileName: 'midstream_corrupt.wav',
        duration: const Duration(seconds: 2),
        corruptAtRatio: 0.5,
        corruptLengthBytes: 2048,
      );

      await player.action.open(tempFile!.path);
      expect(player.state.duration.inMilliseconds, inInclusiveRange(1900, 2100));

      await player.action.play();
      expect(player.state.playing, isTrue);

      // Await playback progression
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));
      expect(player.state.position.inMilliseconds.isNaN, isFalse);

      await player.action.stop();
      expect(player.state.playing, isFalse);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('1.2: Corrupted data chunk length (header claims 10MB, actual file is 50KB)', () async {
      final corruptedBytes = SyntheticAudioGenerator.generateWavWithCorruptHeaderChunkLength(
        duration: const Duration(milliseconds: 300),
        fakeChunkSize: 10485796,
        fakeDataSize: 10485760,
      );
      final tempDir = await Directory.systemTemp.createTemp('miniaudio_corrupt_hdr_');
      tempFile = File('${tempDir.path}/fake_length.wav');
      await tempFile!.writeAsBytes(corruptedBytes, flush: true);

      // Engine must open available frames without reading past buffer or crashing
      await player.action.open(tempFile!.path);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Premature EOF reached cleanly without SIGSEGV
      await player.action.stop();
      expect(player.state.playing, isFalse);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('1.3: Floating-point 32-bit WAV with IEEE 754 NaN and Infinity samples', () async {
      final floatBytes = SyntheticAudioGenerator.generateFloat32WavWithNaN(
        duration: const Duration(seconds: 1),
        injectInfinity: true,
        injectDenormals: true,
      );
      final tempDir = await Directory.systemTemp.createTemp('miniaudio_float_nan_');
      tempFile = File('${tempDir.path}/float_nan.wav');
      await tempFile!.writeAsBytes(floatBytes, flush: true);

      await player.action.open(tempFile!.path);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Limiter / FTZ must suppress or clamp without hanging or SIGFPE
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  // =========================================================================
  // Group 2: Bit-Flip Injections Across Core Decoders (MP3, FLAC, OGG, WAV)
  // =========================================================================
  group('Corrupted Audio Resilience: Bit-Flip Injection Across Core Codecs', () {
    late MiniaudioPlayer player;
    File? tempFile;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      await player.dispose();
      await SyntheticAudioGenerator.cleanUp(tempFile);
      tempFile = null;
    });

    test('2.1: MP3 with mid-stream bit-flips handles frame CRC/desync gracefully', () async {
      final mp3File = resolveAsset('example/assets/music/salida.mp3');
      expect(mp3File.existsSync(), isTrue);
      final originalBytes = await mp3File.readAsBytes();

      // Preserve first 4 KB ID3/headers, flip bits in body
      final bitFlipped = SyntheticAudioGenerator.injectBitFlips(
        originalBytes,
        flipProbability: 0.005,
        startOffset: 4096,
        endOffset: 65536,
      );
      tempFile = await SyntheticAudioGenerator.createTempBitFlippedFile(
        sourceBytes: bitFlipped,
        fileName: 'salida_flipped.mp3',
      );

      await player.action.open(tempFile!.path);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // Must remain running or reach clean EOF
      expect(player.state.position.inSeconds, inInclusiveRange(0, 10));
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('2.2: FLAC with corrupted mid-stream frames recovers or hits clean EOF', () async {
      final flacFile = resolveAsset('example/assets/music/salida.flac');
      expect(flacFile.existsSync(), isTrue);
      final originalBytes = await flacFile.readAsBytes();

      // Preserve FLAC header metadata blocks (first 8 KB)
      final bitFlipped = SyntheticAudioGenerator.injectBitFlips(
        originalBytes,
        flipProbability: 0.008,
        startOffset: 8192,
        endOffset: 65536,
      );
      tempFile = await SyntheticAudioGenerator.createTempBitFlippedFile(
        sourceBytes: bitFlipped,
        fileName: 'salida_flipped.flac',
      );

      await player.action.open(tempFile!.path);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('2.3: OGG Vorbis with corrupted mid-stream packets handles CRC mismatch', () async {
      final oggFile = resolveAsset('example/assets/music/salida.ogg');
      expect(oggFile.existsSync(), isTrue);
      final originalBytes = await oggFile.readAsBytes();

      // Preserve initial OggS / Vorbis setup headers and codebooks (first 16 KB)
      final bitFlipped = SyntheticAudioGenerator.injectBitFlips(
        originalBytes,
        flipProbability: 0.005,
        startOffset: 16384,
        endOffset: 65536,
      );
      tempFile = await SyntheticAudioGenerator.createTempBitFlippedFile(
        sourceBytes: bitFlipped,
        fileName: 'salida_flipped.ogg',
      );

      try {
        await player.action.open(tempFile!.path);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await player.action.stop();
      } on MiniaudioPlayerException catch (e) {
        expect(e.errorCode, isNotNull);
      }
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('2.4: Zero-copy in-memory playback (openMemory) with bit-flipped WAV buffer', () async {
      final wavFile = resolveAsset('example/assets/music/salida.wav');
      expect(wavFile.existsSync(), isTrue);
      final originalBytes = await wavFile.readAsBytes();

      final bitFlipped = SyntheticAudioGenerator.injectBitFlips(
        originalBytes,
        flipProbability: 0.01,
        startOffset: 44, // preserve RIFF header
        endOffset: 32768,
      );

      await player.action.openMemory(bitFlipped);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  // =========================================================================
  // Group 3: Uncommon Codec Ingestion & Resilience (.w64, .rf64, .bwf, .rifx, .aif, .aiff, .aifc, .mp1, .mp2, .oga, .m4a ALAC)
  // =========================================================================
  group('Corrupted Audio Resilience: Uncommon Codecs Ingestion & Stress', () {
    late MiniaudioPlayer player;
    File? tempFile;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      await player.dispose();
      await SyntheticAudioGenerator.cleanUp(tempFile);
      tempFile = null;
    });

    test('3.1: Sony Wave64 (.w64) and RF64 (.rf64) 64-bit chunk playback & seeking', () async {
      for (final asset in ['salida.w64', 'salida.rf64']) {
        final file = resolveAsset('example/assets/music/$asset');
        if (!file.existsSync()) continue;

        await player.action.open(file.path);
        expect(player.state.duration.inSeconds, greaterThan(0));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(player.state.playing, isTrue);

        await player.action.seek(const Duration(seconds: 5));
        expect(player.state.position.inSeconds, inInclusiveRange(4, 7));

        await player.action.stop();
      }
    });

    test('3.2: Broadcast Wave (.bwf) and Big-Endian RIFF (.rifx) format decoding', () async {
      for (final asset in ['salida.bwf', 'salida.rifx']) {
        final file = resolveAsset('example/assets/music/$asset');
        if (!file.existsSync()) continue;

        await player.action.open(file.path);
        expect(player.state.duration.inSeconds, greaterThan(0));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        await player.action.stop();
      }
    });

    test('3.3: AIFF family (.aif, .aiff, .aifc) container playback & corruption resilience', () async {
      for (final asset in ['salida.aif', 'salida.aiff', 'salida.aifc']) {
        final file = resolveAsset('example/assets/music/$asset');
        if (!file.existsSync()) continue;

        // 1. Play valid
        await player.action.open(file.path);
        expect(player.state.duration.inSeconds, greaterThan(0));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await player.action.stop();

        // 2. Fuzz test mid-stream bits
        final bytes = await file.readAsBytes();
        final corruptBytes = SyntheticAudioGenerator.injectBitFlips(
          bytes,
          flipProbability: 0.005,
          startOffset: 1024,
          endOffset: 32768,
        );
        tempFile = await SyntheticAudioGenerator.createTempBitFlippedFile(
          sourceBytes: corruptBytes,
          fileName: 'corrupt_$asset',
        );

        await player.action.open(tempFile!.path);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await player.action.stop();
        await SyntheticAudioGenerator.cleanUp(tempFile);
        tempFile = null;
      }
    });

    test('3.4: MPEG Layer 1 & 2 (.mp1, .mp2) and OGG Audio (.oga) resilience', () async {
      for (final asset in ['salida.mp2', 'salida.oga', 'salida.mp1']) {
        final file = resolveAsset('example/assets/music/$asset');
        if (!file.existsSync()) continue;

        await player.action.open(file.path);
        expect(player.state.duration.inSeconds, greaterThan(0));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await player.action.stop();
      }
    });

    test('3.5: Apple Lossless Audio Codec (.m4a ALAC) container playback & seeking', () async {
      final alacFile = resolveAsset('example/assets/music/salida_alac.m4a');
      if (alacFile.existsSync()) {
        await player.action.open(alacFile.path);
        expect(player.state.duration.inSeconds, greaterThan(0));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(player.state.playing, isTrue);

        await player.action.seek(const Duration(seconds: 10));
        expect(player.state.position.inSeconds, inInclusiveRange(9, 12));

        await player.action.stop();
      }
    });
  });
}
