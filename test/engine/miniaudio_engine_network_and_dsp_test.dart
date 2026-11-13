import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../helpers/concurrency_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late File localWavFile1;
  late File localWavFile2;
  late Uint8List memoryWavBytes;
  Process? serverProcess;
  int? serverPort;

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
    localWavFile1 = File('test/fixtures/test_24bit_stereo.wav');
    localWavFile2 = File('test/fixtures/cbr_noxing.mp3');
    memoryWavBytes = await File('test/fixtures/test_24bit.wav').readAsBytes();

    // Start local Python test HTTP server for network and live chunked streaming
    final completer = Completer<int>();
    serverProcess = await Process.start(
      'python3',
      [
        'test/helpers/test_http_server.py',
        '--port',
        '0',
        '--dir',
        'test/fixtures',
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
      onTimeout: () =>
          throw TimeoutException('Failed to start python test HTTP server'),
    );
  });

  tearDownAll(() async {
    if (serverPort != null) {
      try {
        final client = HttpClient();
        final req = await client
            .getUrl(Uri.parse('http://127.0.0.1:$serverPort/shutdown'));
        final res = await req.close();
        await res.drain<void>();
      } catch (_) {}
    }
    serverProcess?.kill();
    await serverProcess?.exitCode;
  });

  group('2.3 Network & Web Audio: Strict Separation of setQueue and play()',
      () {
    late MiniaudioPlayer<String> engine;

    setUp(() {
      engine = MiniaudioPlayer<String>();
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test(
        'setQueue only prepares queue and leaves currentIndex == null and isPlaying == false',
        () async {
      await engine.action.setQueue([
        AudioSource(localWavFile1.path, data: 'Track 1'),
        AudioSource(localWavFile2.path, data: 'Track 2'),
      ]);

      expect(engine.state.isPlaying, isFalse);
      expect(engine.state.currentIndex, isNull);
      expect(engine.state.currentItem, isNull);

      // Playback begins only upon explicit play()
      await engine.action.play();
      expect(engine.state.isPlaying, isTrue);
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.playbackState, equals(PlaybackState.playing));
    });

    test(
        'setQueue with file, memory, and URL leaves engine idle without autoplay',
        () async {
      // 1. Local file
      await engine.action.setQueue([AudioSource(localWavFile1.path)]);
      expect(engine.state.isPlaying, isFalse);
      expect(engine.state.currentIndex, isNull);

      // 2. Memory bytes
      await engine.action
          .setQueue([AudioSource(Uint8List.fromList(memoryWavBytes))]);
      expect(engine.state.isPlaying, isFalse);
      expect(engine.state.currentIndex, isNull);

      // 3. Remote URL
      final url = Uri.parse('http://127.0.0.1:$serverPort/music/salida.mp3');
      await engine.action.setQueue([AudioSource(url)]);
      expect(engine.state.isPlaying, isFalse);
      expect(engine.state.currentIndex, isNull);
    });

    test(
        'play(position: ...) navigates to target track and crossfades when already playing',
        () async {
      await engine.action.setQueue([
        AudioSource(localWavFile1.path, data: 'Track 1'),
        AudioSource(localWavFile2.path, data: 'Track 2'),
        AudioSource(Uint8List.fromList(memoryWavBytes), data: 'Track 3'),
      ]);

      // Start playing at position 1
      await engine.action.play(position: 1);
      expect(engine.state.currentIndex, equals(1));
      expect(engine.state.isPlaying, isTrue);

      // While playing, play(position: 2) initiates manual crossfade
      await engine.action.play(position: 2);
      expect(engine.state.currentIndex, equals(2));
      expect(engine.state.isPlaying, isTrue);
      // Allow manual crossfade to settle
      await awaitStateOrStream<bool>(
        stream: engine.stream.isCrossfading,
        current: () => engine.state.isCrossfading,
        predicate: (crossfading) => !crossfading,
        timeout: const Duration(seconds: 2),
        reason: 'Manual crossfade failed to complete',
      );
      expect(engine.state.playbackState, equals(PlaybackState.playing));
    });
  });

  group('2.3 Network & Livestreams in Mixed Queue (LiveStreamAudioSource)', () {
    late MiniaudioPlayer<String> engine;

    setUp(() {
      engine = MiniaudioPlayer<String>(
        config: PlayerConfig(
          crossfade: CrossfadeConfig(
            autoDuration: const Duration(seconds: 2),
            manualDuration: const Duration(milliseconds: 200),
            curve: CrossfadeCurve.linear,
          ),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test(
        'LiveStreamAudioSource reports duration == null and seek is a safe no-op',
        () async {
      final liveUri = Uri.parse('http://127.0.0.1:$serverPort/live/salida.mp3');
      await engine.action.setQueue([
        AudioSource<String>(
          liveUri,
          data: 'Live Radio',
        ),
      ]);

      expect(engine.state.duration, isNull);
      await engine.action.play();
      await waitForAudioProgress(
        engine,
        minDelta: const Duration(milliseconds: 40),
        timeout: const Duration(seconds: 3),
      );
      expect(engine.state.isPlaying, isTrue);
      expect(engine.state.duration, isNull);

      // Seek on livestream is a safe no-op
      await engine.action.seek(const Duration(minutes: 5));
      expect(engine.state.isPlaying, isTrue);
    });

    test(
        'previous() on livestream bypasses 3-second restartThreshold and steps back',
        () async {
      final liveUri = Uri.parse('http://127.0.0.1:$serverPort/live/salida.mp3');
      await engine.action.setQueue([
        AudioSource(localWavFile1.path, data: 'Local Track 1'),
        AudioSource(liveUri, data: 'Live Radio 2'),
      ]);

      await engine.action.play(position: 1);
      await waitForAudioProgress(
        engine,
        minDelta: const Duration(milliseconds: 50),
        timeout: const Duration(seconds: 3),
      );
      expect(engine.state.duration, isNull);
      expect(engine.state.currentIndex, equals(1));

      // Calling previous() on livestream steps back directly to index 0
      await engine.action.previous();
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.currentItem?.data, equals('Local Track 1'));

      await awaitStateOrStream<Duration?>(
        stream: engine.stream.duration,
        current: () => engine.state.duration,
        predicate: (d) => d != null,
        timeout: const Duration(seconds: 2),
        reason: 'Track duration should populate after stepping back to local file',
      );
      expect(engine.state.duration, isNotNull);
    });

    test('manual crossfade between livestream and local file runs smoothly',
        () async {
      final liveUri = Uri.parse('http://127.0.0.1:$serverPort/live/salida.mp3');
      await engine.action.setQueue([
        AudioSource(liveUri, data: 'Live Stream'),
        AudioSource(localWavFile1.path, data: 'Local File'),
      ]);

      await engine.action.play();
      await waitForAudioProgress(
        engine,
        minDelta: const Duration(milliseconds: 40),
        timeout: const Duration(seconds: 3),
      );
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.duration, isNull);

      // next() initiates manual crossfade from livestream to local file
      await engine.action.next();
      expect(engine.state.currentIndex, equals(1));
      expect(engine.state.currentItem?.data, equals('Local File'));

      // Allow crossfade (200ms) to complete
      await awaitStateOrStream<bool>(
        stream: engine.stream.isCrossfading,
        current: () => engine.state.isCrossfading,
        predicate: (crossfading) => !crossfading,
        timeout: const Duration(seconds: 2),
        reason: 'Crossfade from livestream to local file failed to complete',
      );
      expect(engine.state.isCrossfading, isFalse);
      expect(engine.state.playbackState, equals(PlaybackState.playing));
      expect(engine.state.isPlaying, isTrue);
      expect(engine.state.duration, isNotNull);
    });
  });

  group('2.4 ReplayGain Normalization per Track', () {
    late MiniaudioPlayer<String> engine;

    setUp(() {
      engine = MiniaudioPlayer<String>();
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test(
        'ReplayGain metadata applied to deck on setQueue/play without altering master volume',
        () async {
      await engine.action.setQueue([
        AudioSource(
          localWavFile1.path,
          data: 'Track with RG',
          replayGainDb: -6.0,
          replayPeak: 0.95,
        ),
        AudioSource(
          localWavFile2.path,
          data: 'Track without RG',
        ),
      ]);

      await engine.action.play();
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

    test('setReplayGainMode(disabled) clears ReplayGain, track restores it',
        () async {
      await engine.action.setQueue([
        AudioSource<String>(
          localWavFile1.path,
          replayGainDb: -4.5,
          replayPeak: 0.88,
        ),
      ]);

      expect(engine.state.volumeNormalization, isTrue);
      expect(engine.state.replayGain.gainDb, closeTo(-4.5, 1e-2));

      // Disable volume normalization via ReplayGainMode
      await engine.action.setReplayGainMode(ReplayGainMode.disabled);
      expect(engine.state.volumeNormalization, isFalse);
      expect(engine.state.replayGain.gainDb, closeTo(0.0, 1e-2));

      // Re-enable volume normalization via ReplayGainMode
      await engine.action.setReplayGainMode(ReplayGainMode.track);
      expect(engine.state.volumeNormalization, isTrue);
      expect(engine.state.replayGain.gainDb, closeTo(-4.5, 1e-2));
    });

    test('defaultReplayGain acts as fallback for tracks lacking metadata',
        () async {
      await engine.action.setDefaultReplayGain(-5.0);
      expect(engine.state.defaultReplayGain, closeTo(-5.0, 1e-2));

      await engine.action.setQueue([
        AudioSource(
          localWavFile1.path,
          data: 'Track without RG',
        ),
        AudioSource(
          localWavFile2.path,
          data: 'Track with RG',
          replayGainDb: -8.0,
        ),
      ]);

      await engine.action.play();

      // Track 1 lacks metadata -> receives default fallback (-5.0 dB)
      expect(engine.state.replayGain.gainDb, closeTo(-5.0, 1e-2));

      // Track 2 has its own metadata -> uses -8.0 dB
      await engine.action.next();
      expect(engine.state.replayGain.gainDb, closeTo(-8.0, 1e-2));
    });

    test(
        'forcedReplayGain forces uniform gain across all tracks, ignoring metadata',
        () async {
      await engine.action.setQueue([
        AudioSource(
          localWavFile1.path,
          data: 'Track 1',
          replayGainDb: -3.0,
        ),
        AudioSource(
          localWavFile2.path,
          data: 'Track 2',
          replayGainDb: -10.0,
        ),
      ]);

      await engine.action.play();

      expect(engine.state.replayGainMode, equals(ReplayGainMode.track));
      expect(engine.state.replayGain.gainDb, closeTo(-3.0, 1e-2));

      // Force uniform gain
      await engine.action.setDefaultReplayGain(-7.5);
      await engine.action.setReplayGainMode(ReplayGainMode.forced);
      expect(engine.state.replayGainMode, equals(ReplayGainMode.forced));
      expect(engine.state.defaultReplayGain, closeTo(-7.5, 1e-2));
      expect(engine.state.replayGain.gainDb, closeTo(-7.5, 1e-2));

      // Next track also uses forced gain
      await engine.action.next();
      expect(engine.state.replayGain.gainDb, closeTo(-7.5, 1e-2));

      // Returning to track mode uses per-track metadata
      await engine.action.setReplayGainMode(ReplayGainMode.track);
      expect(engine.state.replayGainMode, equals(ReplayGainMode.track));
      expect(engine.state.replayGain.gainDb, closeTo(-10.0, 1e-2));
    });

    test(
        'Preamp and ReplayGain are completely decoupled and do not clobber each other',
        () async {
      await engine.action.setQueue([
        AudioSource<String>(
          localWavFile1.path,
          replayGainDb: -6.0,
        ),
      ]);

      // Set user preamp
      await engine.action.setPreamp(3.5);
      expect(engine.state.preamp, closeTo(3.5, 1e-2));
      expect(engine.state.replayGain.gainDb, closeTo(-6.0, 1e-2));

      // Changing ReplayGain does NOT reset or touch preamp
      await engine.action.setReplayGain(const ReplayGainConfig(gainDb: -9.0));
      expect(engine.state.replayGain.gainDb, closeTo(-9.0, 1e-2));
      expect(engine.state.preamp, closeTo(3.5, 1e-2));

      // Changing preamp does NOT alter active ReplayGain
      await engine.action.setPreamp(-2.0);
      expect(engine.state.preamp, closeTo(-2.0, 1e-2));
      expect(engine.state.replayGain.gainDb, closeTo(-9.0, 1e-2));
    });
  });

  group('2.4 Dual-Deck Studio DSP Synchronization & Visualizer State', () {
    late MiniaudioPlayer<String> engine;

    setUp(() {
      engine = MiniaudioPlayer<String>(
        config: PlayerConfig(
          crossfade: CrossfadeConfig(
            manualDuration: const Duration(milliseconds: 100),
          ),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test(
        'DSP settings (equalizer, reverb, preamp, balance, mono, crossfeed, limiter) persist across deck swaps',
        () async {
      await engine.action.setQueue([
        AudioSource(localWavFile1.path, data: 'Track 1'),
        AudioSource(localWavFile2.path, data: 'Track 2'),
      ]);

      // Apply various DSP settings
      await engine.action.setEqualizer(Equalizer.rock);
      await engine.action.setReverb(Reverb.concertHall);
      await engine.action.setPreamp(2.5);
      await engine.action.setBalance(-0.3);
      await engine.action.setMono(true);
      await engine.action.setCrossfeed(Crossfeed.moffatBauer);
      await engine.action.setLimiter(false);
      await engine.action.setSpatializer(enabled: true, width: 1.5);

      expect(engine.state.equalizer, equals(Equalizer.rock));
      expect(engine.state.reverb, equals(Reverb.concertHall));
      expect(engine.state.preamp, closeTo(2.5, 1e-4));
      expect(engine.state.balance, closeTo(-0.3, 1e-4));
      expect(engine.state.mono, isTrue);
      expect(engine.state.crossfeed, equals(Crossfeed.moffatBauer));
      expect(engine.state.limiterEnabled, isFalse);
      expect(engine.state.spatializerEnabled, isTrue);
      expect(engine.state.spatializerWidth, closeTo(1.5, 1e-4));

      // Advance track (swapping active and standby decks)
      await engine.action.play();
      await engine.action.next();

      // DSP state must remain identically configured after deck swap
      expect(engine.state.equalizer, equals(Equalizer.rock));
      expect(engine.state.reverb, equals(Reverb.concertHall));
      expect(engine.state.preamp, closeTo(2.5, 1e-4));
      expect(engine.state.balance, closeTo(-0.3, 1e-4));
      expect(engine.state.mono, isTrue);
      expect(engine.state.crossfeed, equals(Crossfeed.moffatBauer));
      expect(engine.state.limiterEnabled, isFalse);
      expect(engine.state.spatializerEnabled, isTrue);
      expect(engine.state.spatializerWidth, closeTo(1.5, 1e-4));
    });

    test(
        'Visualizer FFT computation is controlled via action.setVisualizerEnabled and persists across deck swaps',
        () async {
      await engine.action.setQueue([
        AudioSource(localWavFile1.path, data: 'Track 1'),
        AudioSource(localWavFile2.path, data: 'Track 2'),
      ]);

      // Initially visualizerEnabled is false
      expect(engine.state.visualizerEnabled, isFalse);

      // Enable visualizer via action
      await engine.action.setVisualizerEnabled(true);
      expect(engine.state.visualizerEnabled, isTrue);

      // Advance deck -> visualizer state remains enabled on new active deck
      await engine.action.play();
      await engine.action.next();
      expect(engine.state.visualizerEnabled, isTrue);

      // Explicitly disabling visualizer
      await engine.action.setVisualizerEnabled(false);
      expect(engine.state.visualizerEnabled, isFalse);
    });
  });
}
