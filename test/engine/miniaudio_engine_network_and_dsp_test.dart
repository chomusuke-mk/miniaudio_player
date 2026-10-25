import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:miniaudio_player/miniaudio_player.dart';

import '../helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late File localWavFile1;
  late File localWavFile2;
  late Uint8List memoryWavBytes;
  Process? serverProcess;
  int? serverPort;

  setUpAll(() async {
    // 1. Create synthetic local test WAV files
    localWavFile1 = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'dsp_test_track1.wav',
      frequencyHz: 440.0,
      durationSeconds: 5.0,
    );
    localWavFile2 = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'dsp_test_track2.wav',
      frequencyHz: 880.0,
      durationSeconds: 5.0,
    );

    // 2. Create in-memory synthetic WAV bytes
    memoryWavBytes = SyntheticAudioGenerator.generateWavBytes(
      frequencyHz: 554.37,
      durationSeconds: 4.0,
    );

    // 3. Start local Python test HTTP server for network and live chunked streaming
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
      environment: {'MAP_TEST_DEBUG': '1'},
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

    await Future.wait([
      SyntheticAudioGenerator.cleanUp(localWavFile1),
      SyntheticAudioGenerator.cleanUp(localWavFile2),
    ]);
  });

  group('2.3 Network & Web Audio: Strict Separation of open / openQueue and play()', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>();
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test('openQueue only prepares queue and leaves engine paused (state.playing == false)', () async {
      await engine.action.openQueue([
        EngineItem.file(localWavFile1.path, data: 'Track 1'),
        EngineItem.file(localWavFile2.path, data: 'Track 2'),
      ]);

      expect(engine.state.playing, isFalse);
      expect(engine.state.phase, equals(EnginePhase.paused));
      expect(engine.state.currentIndex, equals(0));

      // Playback begins only upon explicit play()
      await engine.action.play();
      expect(engine.state.playing, isTrue);
      expect(engine.state.phase, equals(EnginePhase.playing));
    });

    test('openFile, openMemory, and openUrl leave engine paused without autoplay', () async {
      // 1. openFile
      await engine.action.openFile(localWavFile1.path);
      expect(engine.state.playing, isFalse);
      expect(engine.state.phase, equals(EnginePhase.paused));

      // 2. openMemory
      await engine.action.openMemory(memoryWavBytes);
      expect(engine.state.playing, isFalse);
      expect(engine.state.phase, equals(EnginePhase.paused));

      // 3. openUrl
      final url = Uri.parse('http://127.0.0.1:$serverPort/music/salida.mp3');
      await engine.action.openUrl(url);
      expect(engine.state.playing, isFalse);
      expect(engine.state.phase, equals(EnginePhase.paused));
    });

    test('skipToIndex preserves current playback state (paused stays paused, playing stays playing)', () async {
      await engine.action.openQueue([
        EngineItem.file(localWavFile1.path, data: 'Track 1'),
        EngineItem.file(localWavFile2.path, data: 'Track 2'),
        EngineItem.memory(memoryWavBytes, data: 'Track 3'),
      ]);

      // While paused, skipToIndex stays paused
      expect(engine.state.playing, isFalse);
      await engine.action.skipToIndex(1);
      expect(engine.state.currentIndex, equals(1));
      expect(engine.state.playing, isFalse);
      expect(engine.state.phase, equals(EnginePhase.paused));

      // Start playing
      await engine.action.play();
      expect(engine.state.playing, isTrue);

      // While playing, skipToIndex stays playing
      await engine.action.skipToIndex(2);
      expect(engine.state.currentIndex, equals(2));
      expect(engine.state.playing, isTrue);
      expect(
        engine.state.phase == EnginePhase.manualCrossfading ||
            engine.state.phase == EnginePhase.playing,
        isTrue,
      );
      // Allow manual crossfade to settle
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.state.phase, equals(EnginePhase.playing));
    });
  });

  group('2.3 Network & Livestreams in Mixed Queue (LiveStreamAudioSource)', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: CrossfadeConfig(
          duration: const Duration(seconds: 2),
          manualDuration: const Duration(milliseconds: 200),
          curve: CrossfadeCurve.linear,
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test('LiveStreamAudioSource reports isLiveStream == true and seek is a safe no-op', () async {
      final liveUri = Uri.parse('http://127.0.0.1:$serverPort/live/salida.mp3');
      await engine.action.open(
        AudioSource.liveStream(liveUri),
        data: 'Live Radio',
      );

      expect(engine.state.isLiveStream, isTrue);
      await engine.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(engine.state.playing, isTrue);

      // Seek on livestream is a safe no-op
      await engine.action.seek(const Duration(minutes: 5));
      expect(engine.state.playing, isTrue);
    });

    test('previous() on livestream bypasses 3-second restartThreshold and steps back', () async {
      final liveUri = Uri.parse('http://127.0.0.1:$serverPort/live/salida.mp3');
      await engine.action.openQueue([
        EngineItem.file(localWavFile1.path, data: 'Local Track 1'),
        EngineItem(source: AudioSource.liveStream(liveUri), data: 'Live Radio 2'),
      ], startIndex: 1);

      await engine.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(engine.state.isLiveStream, isTrue);
      expect(engine.state.currentIndex, equals(1));

      // Calling previous() on livestream steps back directly to index 0
      await engine.action.previous();
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.currentItem?.data, equals('Local Track 1'));
      expect(engine.state.isLiveStream, isFalse);
    });

    test('manual crossfade between livestream and local file runs smoothly', () async {
      final liveUri = Uri.parse('http://127.0.0.1:$serverPort/live/salida.mp3');
      await engine.action.openQueue([
        EngineItem(source: AudioSource.liveStream(liveUri), data: 'Live Stream'),
        EngineItem.file(localWavFile1.path, data: 'Local File'),
      ]);

      await engine.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.isLiveStream, isTrue);

      // next() initiates manual crossfade from livestream to local file
      await engine.action.next();
      expect(engine.state.currentIndex, equals(1));
      expect(engine.state.currentItem?.data, equals('Local File'));

      // Allow crossfade (200ms) to complete
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(engine.state.phase, equals(EnginePhase.playing));
      expect(engine.state.playing, isTrue);
      expect(engine.state.isLiveStream, isFalse);
    });
  });

  group('2.4 ReplayGain Normalization per Track', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>();
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test('ReplayGain metadata applied to deck on open without altering master volume', () async {
      await engine.action.openQueue([
        EngineItem.file(
          localWavFile1.path,
          data: 'Track with RG',
          replayGainDb: -6.0,
          replayPeak: 0.95,
        ),
        EngineItem.file(
          localWavFile2.path,
          data: 'Track without RG',
        ),
      ]);

      await engine.action.setVolume(0.85);

      // Master volume remains exactly 0.85
      expect(engine.state.volume, closeTo(0.85, 1e-4));
      // ReplayGain is applied to native deck
      expect(engine.state.replayGain.gainDb, closeTo(-6.0, 1e-2));
      expect(engine.state.replayGain.peak, closeTo(0.95, 1e-2));

      // Transition to track without ReplayGain clears ReplayGain
      await engine.action.next();
      expect(engine.state.currentIndex, equals(1));
      expect(engine.state.replayGain.gainDb, closeTo(0.0, 1e-2));
      expect(engine.state.volume, closeTo(0.85, 1e-4));
    });

    test('setVolumeNormalization(false) clears ReplayGain, true restores it', () async {
      await engine.action.open(
        EngineItem.file(
          localWavFile1.path,
          replayGainDb: -4.5,
          replayPeak: 0.88,
        ),
      );

      expect(engine.state.volumeNormalization, isTrue);
      expect(engine.state.replayGain.gainDb, closeTo(-4.5, 1e-2));

      // Disable volume normalization
      await engine.action.setVolumeNormalization(false);
      expect(engine.state.volumeNormalization, isFalse);
      expect(engine.state.replayGain.gainDb, closeTo(0.0, 1e-2));

      // Re-enable volume normalization
      await engine.action.setVolumeNormalization(true);
      expect(engine.state.volumeNormalization, isTrue);
      expect(engine.state.replayGain.gainDb, closeTo(-4.5, 1e-2));
    });
  });

  group('2.4 Dual-Deck Studio DSP Synchronization & Visualizer State', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: CrossfadeConfig(
          manualDuration: const Duration(milliseconds: 100),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test('DSP settings (equalizer, reverb, preamp, balance, mono, crossfeed, limiter) persist across deck swaps', () async {
      await engine.action.openQueue([
        EngineItem.file(localWavFile1.path, data: 'Track 1'),
        EngineItem.file(localWavFile2.path, data: 'Track 2'),
      ]);

      // Apply various DSP settings
      await engine.action.setEqualizer(Equalizer.rock);
      await engine.action.setReverb(Reverb.concertHall);
      await engine.action.setPreamp(2.5);
      await engine.action.setBalance(-0.3);
      await engine.action.setMono(true);
      await engine.action.setCrossfeed(CrossfeedMode.moffatBauer);
      await engine.action.setLimiter(false);
      await engine.action.setSpatializer(enabled: true, width: 1.5);

      expect(engine.state.equalizer, equals(Equalizer.rock));
      expect(engine.state.reverb, equals(Reverb.concertHall));
      expect(engine.state.preampDb, closeTo(2.5, 1e-4));
      expect(engine.state.balance, closeTo(-0.3, 1e-4));
      expect(engine.state.mono, isTrue);
      expect(engine.state.crossfeed, equals(CrossfeedMode.moffatBauer));
      expect(engine.state.limiterEnabled, isFalse);
      expect(engine.state.spatializerEnabled, isTrue);
      expect(engine.state.spatializerWidth, closeTo(1.5, 1e-4));

      // Advance track (swapping active and standby decks)
      await engine.action.play();
      await engine.action.next();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // DSP state must remain identically configured after deck swap
      expect(engine.state.equalizer, equals(Equalizer.rock));
      expect(engine.state.reverb, equals(Reverb.concertHall));
      expect(engine.state.preampDb, closeTo(2.5, 1e-4));
      expect(engine.state.balance, closeTo(-0.3, 1e-4));
      expect(engine.state.mono, isTrue);
      expect(engine.state.crossfeed, equals(CrossfeedMode.moffatBauer));
      expect(engine.state.limiterEnabled, isFalse);
      expect(engine.state.spatializerEnabled, isTrue);
      expect(engine.state.spatializerWidth, closeTo(1.5, 1e-4));
    });

    test('Visualizer FFT computation enables only when listened and stays false on standby deck', () async {
      await engine.action.openQueue([
        EngineItem.file(localWavFile1.path, data: 'Track 1'),
        EngineItem.file(localWavFile2.path, data: 'Track 2'),
      ]);

      // Initially no listeners -> visualizerEnabled is false
      expect(engine.state.visualizerEnabled, isFalse);

      // Listen to visualizer stream -> activates on active deck
      final sub = engine.stream.visualizer.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.state.visualizerEnabled, isTrue);

      // Advance deck -> visualizer state remains enabled on new active deck
      await engine.action.play();
      await engine.action.next();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(engine.state.visualizerEnabled, isTrue);

      // Canceling subscription disables visualizer to save CPU
      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.state.visualizerEnabled, isFalse);
    });
  });
}
