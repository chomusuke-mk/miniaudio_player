// test/compound_feature_interaction_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('Compound Feature Interactions (R2)', () {
    Process? serverProcess;
    int? serverPort;
    late MiniaudioPlayer player;

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

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    // =========================================================================
    // Test 1: Skip-Silence Enabled During Network Buffering / Underrun
    // =========================================================================
    test(
      'C1: Skip-silence enabled during network underrun does NOT falsely increment saved silence',
      () async {
        // Configure continuous silence skipping
        await player.action.setSilenceConfig(
          const SilenceSkipConfig.continuous(
            thresholdDb: -45.0,
            minSilenceDuration: Duration(milliseconds: 200),
            padding: Duration(milliseconds: 40),
          ),
        );
        expect(player.state.skipSilence, isTrue);

        // Open throttled stream with burst prebuffer (burst 64KB, then 4KB / 300ms starvation)
        final url = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=4096&stall_ms=300&initial_burst=65536';
        await player.action.open(AudioSource.uri(url));
        await player.action.play();

        // Allow initial playback and observe starvation
        await Future<void>.delayed(const Duration(milliseconds: 600));

        // Underflow synthesized silence must NOT be counted as skipped audio silence
        final savedDuringStarvation = player.state.silenceSavedDuration;
        expect(
          savedDuringStarvation.inMilliseconds,
          equals(0),
          reason: 'Network starvation zeroes must bypass silence detector and not increment savedDuration',
        );

        // Invariant: skipSilence state remains uncorrupted
        expect(player.state.skipSilence, isTrue);
        expect(player.state.silenceSkipMode, equals(SilenceSkipMode.continuous));

        await player.action.stop();
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    // =========================================================================
    // Test 2: Dynamic Skip-Silence Toggling During Buffering / Starvation
    // =========================================================================
    test(
      'C2: Dynamically reconfiguring and toggling skip-silence while buffering does not crash or corrupt',
      () async {
        final url = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=4096&stall_ms=300&initial_burst=65536';
        await player.action.open(AudioSource.uri(url));
        await player.action.play();

        // Wait until buffering state is active
        await Future<void>.delayed(const Duration(milliseconds: 400));

        // 1. Toggle ON -> OFF -> ON during active starvation
        await player.action.setSkipSilence(false);
        expect(player.state.skipSilence, isFalse);
        expect(player.state.silenceSkipMode, equals(SilenceSkipMode.disabled));

        await player.action.setSkipSilence(true);
        expect(player.state.skipSilence, isTrue);

        // 2. Change modes during active starvation
        await player.action.setSilenceConfig(
          const SilenceSkipConfig.trimEdges(thresholdDb: -50.0),
        );
        expect(player.state.silenceSkipMode, equals(SilenceSkipMode.trimEdges));

        await player.action.setSilenceConfig(
          const SilenceSkipConfig.all(thresholdDb: -40.0),
        );
        expect(player.state.silenceSkipMode, equals(SilenceSkipMode.all));

        // Let engine process frames without deadlocks
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(player.state.silenceConfig.mode, equals(SilenceSkipMode.all));
        expect(player.state.silenceConfig.thresholdDb, equals(-40.0));

        await player.action.stop();
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    // =========================================================================
    // Test 3: Seeking During Active Stream Stalls / Buffering
    // =========================================================================
    test(
      'C3: Seeking during network stream starvation does not deadlock and resumes cleanly via Byte-Range',
      () async {
        final url = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=4096&stall_ms=300&initial_burst=65536';
        await player.action.open(AudioSource.uri(url));
        await player.action.play();

        await Future<void>.delayed(const Duration(milliseconds: 500));

        // Issue seek into 30-second offset while data feed is stalled
        final targetPosition = const Duration(seconds: 30);
        await player.action.seek(targetPosition);

        // Ensure seek returned without thread hang
        expect(player.state.position.inSeconds, inInclusiveRange(28, 35));

        // Allow Range response to deliver frames and verify engine remains responsive
        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(player.state.playing, isTrue);

        await player.action.stop();
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    // =========================================================================
    // Test 4: Active Full DSP Chain During Flaky Network Drops
    // =========================================================================
    test(
      'C4: Full DSP chain (EQ, limiter, reverb, visualizer, crossfeed) active during abrupt network disconnect',
      () async {
        // 1. Activate entire DSP processing chain
        await player.action.setEqualizer(
          const Equalizer(
            hz31: 6.0,
            hz63: 4.0,
            hz125: 2.0,
            hz250: 0.0,
            hz500: -2.0,
            hz1k: -3.0,
            hz2k: 0.0,
            hz4k: 3.0,
            hz8k: 5.0,
            hz16k: 7.0,
          ),
        );
        await player.action.setLimiter(true);
        await player.action.setReverb(Reverb.cathedral);
        await player.action.setBalance(-0.35);
        await player.action.setCrossfeed(CrossfeedMode.moffatBauer);
        await player.action.setVisualizerEnabled(true);

        final capturedVisualizerData = <VisualizerData>[];
        final sub = player.stream.visualizer.listen((data) {
          capturedVisualizerData.add(data);
        });
        addTearDown(() => sub.cancel());

        // 2. Open stream that abruptly drops socket after 128 KB
        final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=131072';
        await player.action.open(AudioSource.uri(dropUrl));
        await player.action.play();

        // Allow audio to play and drop
        await Future<void>.delayed(const Duration(milliseconds: 600));

        // 3. Verify DSP signal integrity: zero NaNs, zero Infinities, bounded RMS
        expect(capturedVisualizerData, isNotEmpty);
        for (final data in capturedVisualizerData) {
          expect(data.rms.isNaN, isFalse);
          expect(data.rms.isInfinite, isFalse);
          expect(data.rms, greaterThanOrEqualTo(0.0));
          expect(data.rms, lessThanOrEqualTo(1.5)); // Limiter keeps signal contained

          for (final band in data.bands) {
            expect(band.isNaN, isFalse);
            expect(band.isInfinite, isFalse);
            expect(band, greaterThanOrEqualTo(0.0));
            expect(band, lessThanOrEqualTo(1.5));
          }
        }

        // 4. Verify clean teardown with active DSP chain
        await player.action.stop();
        expect(player.state.playing, isFalse);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}
