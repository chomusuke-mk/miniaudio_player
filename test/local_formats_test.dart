// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/concurrency_test_utils.dart';

/// Helper to log actions and player state during chaotic operations,
/// dumped on failure to pinpoint exact errors.
class LocalChaosTrace {
  final List<String> _entries = [];

  void log(String action, [Map<String, dynamic>? details]) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final detailStr =
        details != null ? ' | details=${jsonEncode(details)}' : '';
    _entries.add('[$ts] $action$detailStr');
  }

  void dump() {
    print('\n========== LOCAL CHAOS ACTION TRACE ==========');
    for (final e in _entries) {
      print(e);
    }
    print('==============================================\n');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  final dir = Directory('test/fixtures');
  final allFiles = dir.listSync().whereType<File>().toList();
  allFiles.sort((a, b) => a.path.compareTo(b.path));

  // Filter supported files
  final supportedFiles = allFiles.where((f) {
    final ext = f.path.split('.').last.toLowerCase();
    return miniAudioPlayerSupportedExtensions.contains(ext);
  }).toList();

  // =========================================================================
  // Group 1: Local Files Matrix (Direct Filesystem Playback & Accurate Seeking)
  // =========================================================================
  group('Local Files Matrix Playback & Seeking (setQueue + play)', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer(
        queue: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]));
    tearDown(() async => await player.dispose());

    for (final file in supportedFiles) {
      final fileName = file.uri.pathSegments.last;
      test('1.setQueue: $fileName', () async {
        // 1. setQueue & play
        await player.action.setQueue([AudioSource(file.path)]);
        await player.action.play();
        final duration = player.state.duration;
        expect(duration?.inMilliseconds, greaterThan(0),
            reason: '$fileName duration should be greater than 0');

        expect(player.state.isPlaying, isTrue,
            reason: '$fileName should be playing');
        expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0),
            reason: '$fileName position should be non-negative');

        // 3. seek
        if (duration != null && duration > const Duration(seconds: 3)) {
          const seekTarget = Duration(seconds: 2);
          await player.action.seek(seekTarget);
          final posAfterSeek = player.state.position.inMilliseconds;
          expect((posAfterSeek - 2000).abs(), lessThanOrEqualTo(1000),
              reason:
                  '$fileName position after seek should be near 2000 ms (was $posAfterSeek)');
        }
        // 4. pause
        await player.action.pause();
        expect(player.state.isPlaying, isFalse);

        // 5. stop
        await player.action.stop();
        expect(player.state.isPlaying, isFalse);
      }, timeout: const Timeout(Duration(seconds: 15)));
    }
  });

  // =========================================================================
  // Group 2: Direct In-Memory Buffer Matrix
  // =========================================================================
  group('Local In-Memory Buffer Matrix', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer(
        queue: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]));
    tearDown(() async => await player.dispose());

    for (final file in supportedFiles) {
      final fileName = file.uri.pathSegments.last;
      test('2.memory: $fileName', () async {
        final bytes = await file.readAsBytes();

        await player.action.setQueue([AudioSource(bytes)]);
        await player.action.play();
        final duration = player.state.duration;
        expect(duration?.inMilliseconds, greaterThan(0),
            reason: '$fileName in-memory duration should be > 0');

        expect(player.state.isPlaying, isTrue,
            reason: '$fileName in-memory should be playing');

        // Seek validation in memory
        if (duration != null && duration > const Duration(seconds: 3)) {
          const seekTarget = Duration(seconds: 2);
          await player.action.seek(seekTarget);
          final posAfterSeek = player.state.position.inMilliseconds;
          expect((posAfterSeek - 2000).abs(), lessThanOrEqualTo(1000),
              reason:
                  '$fileName in-memory position after seek should be near 2000 ms (was $posAfterSeek)');
        }

        await player.action.stop();
        expect(player.state.isPlaying, isFalse);
      }, timeout: const Timeout(Duration(seconds: 15)));
    }
  });

  // =========================================================================
  // Group 3: Asset Playback Matrix
  // =========================================================================
  group('Local Asset Playback Matrix', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer(
        queue: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]));
    tearDown(() async => await player.dispose());

    const representativeFormats = [
      'mp3',
      'wav',
      'flac',
      'ogg',
      'opus',
      'aac',
      'm4a',
      'aiff',
    ];

    for (final fmt in representativeFormats) {
      final match = supportedFiles.firstWhere(
        (f) => f.path.toLowerCase().endsWith('.$fmt'),
        orElse: () => supportedFiles.first,
      );
      final fileName = match.uri.pathSegments.last;

      test('3.asset: $fileName ($fmt)', () async {
        final assetKey = 'test/fixtures/$fileName';
        await player.action.setQueue([AudioSource(assetKey)]);
        await player.action.play();
        expect(player.state.duration?.inMilliseconds, greaterThan(0));
        expect(player.state.isPlaying, isTrue);

        await player.action.stop();
        expect(player.state.isPlaying, isFalse);
      }, timeout: const Timeout(Duration(seconds: 15)));
    }
  });

  // =========================================================================
  // Group 4: Polymorphic AudioSource & File Inputs
  // =========================================================================
  group('Polymorphic Local Source Types (AudioSource & File)', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer(
        queue: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]));
    tearDown(() async => await player.dispose());

    test('4.1: AudioSource with file path plays local file', () async {
      final file = File('test/fixtures/salida.mp3');
      await player.action.setQueue([AudioSource(file.path)]);
      await player.action.play();
      expect(player.state.duration?.inMilliseconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);
      await player.action.stop();
    });

    test('4.2: AudioSource with file:// URI plays local file', () async {
      final file = File('test/fixtures/salida.wav');
      await player.action.setQueue([AudioSource(file.absolute.uri)]);
      await player.action.play();
      expect(player.state.duration?.inMilliseconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);
      await player.action.stop();
    });

    test('4.3: File path passed to player.action.setQueue()', () async {
      final file = File('test/fixtures/salida.flac');
      await player.action.setQueue([AudioSource(file.path)]);
      await player.action.play();
      expect(player.state.duration?.inMilliseconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);
      await player.action.stop();
    });

    test('4.4: Raw path String passed to player.action.setQueue()', () async {
      await player.action
          .setQueue([AudioSource('test/fixtures/salida_aac.m4a')]);
      await player.action.play();
      expect(player.state.duration?.inMilliseconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);
      await player.action.stop();
    });
  });

  // =========================================================================
  // Group 5: Corrupt Local File Resilience & State Recovery
  // =========================================================================
  group('Corrupt Local File Resilience & Recovery', () {
    late MiniaudioPlayer player;
    late File corruptFile;

    setUp(() async {
      player = MiniaudioPlayer(
          queue: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]);
      corruptFile =
          File('${Directory.systemTemp.path}/temp_corrupt_test_file.mp3');
      // Create artificial garbage file
      await corruptFile
          .writeAsBytes(List<int>.generate(2048, (i) => (i * 7 + 13) % 256));
    });

    tearDown(() async {
      await player.dispose();
      if (corruptFile.existsSync()) {
        await corruptFile.delete();
      }
    });

    test(
        '5.1: Corrupt local file throws controlled exception on play() without breaking player',
        () async {
      // 1. Set queue with corrupt local file and attempt to play
      await player.action.setQueue([AudioSource(corruptFile.path)]);
      await expectLater(
        player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // 2. Player control methods remain safe
      await player.action.pause();
      await player.action.stop();
      expect(player.state.isPlaying, isFalse);

      // 3. Immediately recover by queueing and playing valid local file
      await player.action.setQueue([AudioSource('test/fixtures/salida.mp3')]);
      await player.action.play();
      expect(player.state.duration?.inMilliseconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);
      await player.action.stop();
    });
  });

  // =========================================================================
  // Group 6: Unsupported Local Formats Handling
  // =========================================================================
  group('Unsupported Local Format Clean Failure', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer(
        queue: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]));
    tearDown(() async => await player.dispose());

    test(
        '6.1: Playing unsupported format throws MiniaudioPlayerException gracefully',
        () async {
      final dummyFile = File('${Directory.systemTemp.path}/unsupported.xyz');
      await dummyFile.writeAsString('not a real audio stream');
      try {
        await player.action.setQueue([AudioSource(dummyFile.path)]);
        await expectLater(
          player.action.play(),
          throwsA(isA<MiniaudioPlayerException>()),
        );

        // Player must be immediately reusable
        await player.action
            .setQueue([AudioSource('test/fixtures/salida_alac.m4a')]);
        await player.action.play();
        expect(player.state.duration?.inMilliseconds, greaterThan(0));
        expect(player.state.isPlaying, isTrue);
        await player.action.stop();
      } finally {
        if (dummyFile.existsSync()) {
          await dummyFile.delete();
        }
      }
    });
  });

  // =========================================================================
  // Group 7: Chaotic Local Controls Sequence with Action Trace
  // =========================================================================
  group('Chaotic Local Controls Sequence', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer(
        queue: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]));
    tearDown(() async => await player.dispose());

    test(
        '7.1: Comprehensive chaotic commands loop with detailed trace validation',
        () async {
      final trace = LocalChaosTrace();

      try {
        const trackA = 'test/fixtures/salida.mp3';
        const trackB = 'test/fixtures/salida_aac.m4a';
        const trackC = 'test/fixtures/salida_alac.m4a';

        // Step 1: Set queue track A and play
        trace.log('Step 1: setQueue(trackA)');
        await player.action.setQueue([AudioSource(trackA)]);
        trace.log('Step 1.1: play()');
        await player.action.play();
        expect(player.state.isPlaying, isTrue);
        trace.log('Step 1.2: state verified playing',
            {'position': player.state.position.inMilliseconds});

        // Step 2: Seek forward while playing
        trace.log('Step 2: seek(2s)');
        await player.action.seek(const Duration(seconds: 2));
        expect(
            player.state.position.inMilliseconds, greaterThanOrEqualTo(1500));
        trace.log('Step 2.1: seek position verified',
            {'position': player.state.position.inMilliseconds});

        // Step 3: Pause while playing
        trace.log('Step 3: pause()');
        await player.action.pause();
        expect(player.state.isPlaying, isFalse);
        trace.log('Step 3.1: paused verified');

        // Step 4: Seek near end while paused
        final nearEnd = (player.state.duration ?? Duration.zero) -
            const Duration(milliseconds: 300);
        trace.log('Step 4: seek near end', {'target': nearEnd.inMilliseconds});
        await player.action.seek(nearEnd);

        // Step 5: Resume play to trigger natural completion
        trace.log('Step 5: play() until completion');
        await player.action.play();
        await awaitStateOrStream<PlaybackState>(
          stream: player.stream.playbackState,
          current: () => player.state.playbackState,
          predicate: (s) => s.isStopped,
          timeout: const Duration(seconds: 3),
          reason: 'Track failed to reach stopped state on EOF',
        );
        expect(player.state.playbackState.isStopped, isTrue);
        expect(player.state.isPlaying, isFalse);
        trace.log('Step 5.1: completed verified');

        // Step 6: Replay from completion auto-rewinds
        trace.log('Step 6: play() from completed state');
        await player.action.play();
        expect(player.state.isPlaying, isTrue);
        expect(player.state.playbackState.isPlaying, isTrue);
        trace.log('Step 6.1: auto-rewind replay verified',
            {'position': player.state.position.inMilliseconds});

        // Step 7: Switch in flight to M4A (AAC) track B
        trace.log('Step 7: switch to track B (M4A AAC)');
        await player.action.setQueue([AudioSource(trackB)]);
        await player.action.play();
        expect(player.state.isPlaying, isTrue);
        expect(player.state.duration?.inMilliseconds, greaterThan(0));
        trace.log('Step 7.1: track B playing verified',
            {'duration': player.state.duration?.inMilliseconds});

        // Step 8: Seek on track B
        trace.log('Step 8: seek(2s) on track B');
        await player.action.seek(const Duration(seconds: 2));
        expect((player.state.position.inMilliseconds - 2000).abs(),
            lessThanOrEqualTo(1000));
        trace.log('Step 8.1: track B seek verified',
            {'position': player.state.position.inMilliseconds});

        // Step 9: Switch in flight to M4A (ALAC) track C
        trace.log('Step 9: switch to track C (M4A ALAC)');
        await player.action.setQueue([AudioSource(trackC)]);
        await player.action.play();
        expect(player.state.isPlaying, isTrue);
        trace.log('Step 9.1: track C playing verified',
            {'duration': player.state.duration?.inMilliseconds});

        // Step 10: Final clean stop
        trace.log('Step 10: stop()');
        await player.action.stop();
        expect(player.state.isPlaying, isFalse);
        trace.log('Step 10.1: clean stop verified');
      } catch (e) {
        trace.dump();
        rethrow;
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
