// test/challenger_stress_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  Process? serverProcess;
  int? serverPort;

  setUpAll(() async {
    final completer = Completer<int>();
    serverProcess = await Process.start(
      'python3',
      [
        'test/helpers/test_http_server.py',
        '--port',
        '0',
        '--dir',
        'example/assets/music',
      ],
    );

    serverProcess!.stderr.drain<void>();
    serverProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final match = RegExp(r'SERVER_STARTED_PORT:(\d+)').firstMatch(line);
      if (match != null && !completer.isCompleted) {
        completer.complete(int.parse(match.group(1)!));
      }
    });

    serverPort = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Failed to start python test HTTP server'),
    );
  });

  tearDownAll(() async {
    if (serverPort != null) {
      try {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$serverPort/shutdown'));
        final res = await req.close();
        await res.drain<void>();
      } catch (_) {}
    }
    serverProcess?.kill();
    await serverProcess?.exitCode;
  });

  // =========================================================================
  // Challenge Group 1: Extreme & Hostile Corrupt Audio Payloads
  // =========================================================================
  group('Empirical Challenge: Hostile Audio Payloads & Corrupt Buffers', () {
    late MiniaudioPlayer player;
    File? tempFile;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
      await SyntheticAudioGenerator.cleanUp(tempFile);
      tempFile = null;
    });

    test('C1.1: openMemory rejects 0-length and tiny buffers (1..43 bytes) without crashing', () async {
      // 0 bytes
      expect(
        () => player.action.openMemory(Uint8List(0)),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // Micro buffers from 1 to 43 bytes (less than 44-byte WAV header)
      for (final size in [1, 2, 4, 12, 16, 36, 43]) {
        final microBytes = Uint8List(size);
        for (int i = 0; i < size; i++) {
          microBytes[i] = (i * 37) & 0xFF;
        }
        await expectLater(
          player.action.openMemory(microBytes),
          throwsA(isA<MiniaudioPlayerException>()),
        );
      }
    });

    test('C1.2: Hostile WAV header fuzzing: invalid channel counts, zero sample rate, corrupted bit depths', () async {
      // Valid base WAV
      final validWav = SyntheticAudioGenerator.generateWavBytes(durationSeconds: 0.2);

      // Mutate 1: 0 channels (offset 22)
      final zeroChan = Uint8List.fromList(validWav);
      ByteData.view(zeroChan.buffer).setUint16(22, 0, Endian.little);
      await expectLater(
        player.action.openMemory(zeroChan),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // Mutate 2: 255 channels (offset 22)
      final highChan = Uint8List.fromList(validWav);
      ByteData.view(highChan.buffer).setUint16(22, 255, Endian.little);
      await expectLater(
        player.action.openMemory(highChan),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // Mutate 3: 0 sample rate (offset 24)
      final zeroSampleRate = Uint8List.fromList(validWav);
      ByteData.view(zeroSampleRate.buffer).setUint32(24, 0, Endian.little);
      await expectLater(
        player.action.openMemory(zeroSampleRate),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // Mutate 4: Corrupted bits per sample = 0 (offset 34)
      final zeroBits = Uint8List.fromList(validWav);
      ByteData.view(zeroBits.buffer).setUint16(34, 0, Endian.little);
      await expectLater(
        player.action.openMemory(zeroBits),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // Mutate 4b: Non-standard 7-bit depth handled by dr_wav container packing without crash
      final sevenBits = Uint8List.fromList(validWav);
      ByteData.view(sevenBits.buffer).setUint16(34, 7, Endian.little);
      await player.action.openMemory(sevenBits);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await player.action.stop();

      // Mutate 5: Bad magic bytes 'NOPE' instead of 'RIFF' fails cleanly
      final badMagic = Uint8List.fromList(validWav);
      badMagic[0] = 0x4E; // 'N'
      badMagic[1] = 0x4F; // 'O'
      badMagic[2] = 0x50; // 'P'
      badMagic[3] = 0x45; // 'E'
      await expectLater(
        player.action.openMemory(badMagic),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // Mutate 6: Format tag 0xFFFF does not crash decoder or audio thread
      final unknownFmt = Uint8List.fromList(validWav);
      ByteData.view(unknownFmt.buffer).setUint16(20, 0xFFFF, Endian.little);
      try {
        await player.action.openMemory(unknownFmt);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await player.action.stop();
      } on MiniaudioPlayerException catch (_) {
        // Failing gracefully is also fine
      }
    });

    test('C1.3: Truncated files midway through PCM data chunk', () async {
      final validWav = SyntheticAudioGenerator.generateWavBytes(durationSeconds: 0.5);

      // Truncate at header boundary (exactly 44 bytes, 0 data samples)
      final truncatedAtHeader = validWav.sublist(0, 44);
      // Miniaudio may either open with 0 frames or fail gracefully, but must NOT crash
      try {
        await player.action.openMemory(truncatedAtHeader);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await player.action.stop();
      } on MiniaudioPlayerException catch (_) {
        // Graceful error is valid
      }

      // Truncate halfway through data
      final truncatedHalf = validWav.sublist(0, validWav.length ~/ 2);
      await player.action.openMemory(truncatedHalf);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));
      await player.action.stop();
    });

    test('C1.4: Random garbage pseudorandom payload (128 KB of noise) as audio source', () async {
      final rng = Random(12345);
      final garbage = Uint8List(128 * 1024);
      for (int i = 0; i < garbage.length; i++) {
        garbage[i] = rng.nextInt(256);
      }

      final tempDir = await Directory.systemTemp.createTemp('garbage_audio_');
      tempFile = File('${tempDir.path}/garbage.wav');
      await tempFile!.writeAsBytes(garbage, flush: true);

      // Must fail cleanly without SIGSEGV
      await expectLater(
        player.action.open(tempFile!.path),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // Also via openMemory
      await expectLater(
        player.action.openMemory(garbage),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('C1.5: 5-second 32-bit float WAV saturated with NaNs, Infs, and Subnormals under DSP', () async {
      final floatBytes = SyntheticAudioGenerator.generateFloat32WavWithNaN(
        duration: const Duration(seconds: 2),
        injectInfinity: true,
        injectDenormals: true,
      );

      await player.action.openMemory(floatBytes);
      // Enable EQ, Limiter, Reverb, and Spatializer to stress DSP filter registers
      await player.action.setEqualizer(const Equalizer(hz1k: 6.0));
      await player.action.setLimiter(true);
      await player.action.setReverb(Reverb.concertHall);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));
      await player.action.seek(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await player.action.stop();
      expect(player.state.playing, isFalse);
    });
  });

  // =========================================================================
  // Challenge Group 2: Hostile Network Streaming Scenarios
  // =========================================================================
  group('Empirical Challenge: Hostile Network & Server Failure Modes', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('C2.1: HTTP Error responses (404, 403, 500) throw cleanly without unhandled exceptions', () async {
      for (final code in [404, 403, 500]) {
        final errUrl = 'http://127.0.0.1:$serverPort/error/$code';
        await expectLater(
          player.action.openUrl(errUrl),
          throwsA(isA<MiniaudioPlayerException>()),
        );
      }
    });

    test('C2.2: Server delivering malformed garbage headers throws cleanly', () async {
      final corruptUrl = 'http://127.0.0.1:$serverPort/corrupt/headers';
      await expectLater(
        player.action.openUrl(corruptUrl),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('C2.3: Connection aborted during initial 64 KB header buffering (after 500 bytes)', () async {
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=500';
      // Server closes socket after 500 bytes (< 65536 prebuffer)
      // Player must throw or handle without unhandled future rejection or crash
      try {
        await player.action.openUrl(dropUrl);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await player.action.stop();
      } on MiniaudioPlayerException catch (e) {
        expect(e.message, isNotEmpty);
      }
    });

    test('C2.4: Extreme trickle bandwidth (500 bytes/sec) handles starvation without deadlocks', () async {
      // 4 kbps = ~500 bytes/sec with 64KB initial burst
      final trickleUrl = 'http://127.0.0.1:$serverPort/ratelimit/salida.mp3?kbps=4&initial_burst=65536';
      await player.action.openUrl(trickleUrl);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Issue concurrent rapid playback controls
      await player.action.pause();
      expect(player.state.playing, isFalse);
      await player.action.play();
      expect(player.state.playing, isTrue);

      await player.action.setVolume(0.5);
      await player.action.stop();
      expect(player.state.playing, isFalse);
    });

    test('C2.5: HTTP Redirection (302 Found) to valid audio stream resolves seamlessly', () async {
      final redirectUrl = 'http://127.0.0.1:$serverPort/redirect/302?target=/music/salida.mp3';
      await player.action.openUrl(redirectUrl);

      expect(player.state.duration.inSeconds, greaterThan(0));
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));
      await player.action.stop();
    });

    test('C2.6: Rapid openUrl and immediate dispose before initial buffering completes', () async {
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=1024';
      for (int i = 0; i < 10; i++) {
        final p = MiniaudioPlayer();
        // Fire open without awaiting, then immediately dispose
        unawaited(p.action.openUrl(dropUrl).catchError((_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await p.dispose();
      }
    });
  });

  // =========================================================================
  // Challenge Group 3: High-Stress Concurrency & Multi-Instance Fuzzing
  // =========================================================================
  group('Empirical Challenge: High Concurrency & Memory Churn', () {
    test('C3.1: 5 concurrent players streaming flaky & stalled endpoints simultaneously', () async {
      final players = List.generate(5, (_) => MiniaudioPlayer());
      addTearDown(() async {
        for (final p in players) {
          if (!p.isDisposed) await p.dispose();
        }
      });

      final futures = <Future<void>>[];
      for (int i = 0; i < players.length; i++) {
        final p = players[i];
        final url = (i % 2 == 0)
            ? 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=8192&stall_ms=200&initial_burst=32768'
            : 'http://127.0.0.1:$serverPort/ratelimit/salida.mp3?kbps=64&initial_burst=32768';

        futures.add(() async {
          await p.action.openUrl(url);
          await p.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await p.action.setVolume(0.8);
          await p.action.pause();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await p.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await p.action.stop();
        }());
      }

      await Future.wait(futures).timeout(const Duration(seconds: 15));
    });

    test('C3.2: 40 iterations of rapid openMemory -> play -> dispose lifecycle churn', () async {
      final wavBytes = SyntheticAudioGenerator.generateWavBytes(durationSeconds: 0.2);

      for (int i = 0; i < 40; i++) {
        final p = MiniaudioPlayer();
        await p.action.openMemory(wavBytes);
        await p.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await p.dispose();
      }
    });
  });
}
