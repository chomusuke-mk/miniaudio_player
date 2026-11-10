import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/app.dart';
import 'package:miniaudio_player_example/controllers/audio_analyzer_controller.dart';
import 'package:miniaudio_player_example/controllers/audio_engine_controller.dart';
import 'package:miniaudio_player_example/models/audio_track.dart';
import 'package:miniaudio_player_example/widgets/cards/audio_analyzer_card.dart';
import 'package:miniaudio_player_example/widgets/cards/playback_engine_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  group('AudioAnalyzerController On-Demand Analysis & Session Cache Tests', () {
    late AudioAnalyzerController controller;

    setUp(() {
      controller = AudioAnalyzerController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('Initial state has no active analysis or cached tracks', () {
      expect(controller.isAnalyzing, isFalse);
      expect(controller.result, isNull);
      expect(controller.currentTrackId, isNull);
      final track = AudioTrack(
        id: 'track-0',
        title: 'Track 0',
        source: AudioSource('assets/music/test_24bit.wav'),
      );
      expect(controller.hasResultForTrack(track), isFalse);
    });

    test('On-demand analyze caches result and avoids re-analysis', () async {
      final track1 = AudioTrack(
        id: 'track-1',
        title: 'Test 24bit WAV',
        source: AudioSource('assets/music/test_24bit.wav'),
      );

      // Trigger on-demand analysis
      final res = await controller.analyze(track1);

      expect(res, isNotNull);
      expect(controller.hasResultForTrack(track1), isTrue);
      final result1 = controller.getResultForTrack(track1);
      expect(result1, isNotNull);
      expect(controller.result, equals(result1));
      expect(controller.currentTrackId, equals(track1.id));

      // Second invocation must be a cache hit (returns the exact same instance)
      final res2 = await controller.analyze(track1);
      expect(identical(res, res2), isTrue);
      final result2 = controller.getResultForTrack(track1);
      expect(identical(result1, result2), isTrue);
    });

    test('Switching tracks maintains isolated cache for each track', () async {
      final track1 = AudioTrack(
        id: 'track-1',
        title: 'Track 1',
        source: AudioSource('assets/music/test_24bit.wav'),
      );
      final track2 = AudioTrack(
        id: 'track-2',
        title: 'Track 2',
        source: AudioSource('assets/music/cbr_noxing.mp3'),
      );

      await controller.analyze(track1);
      expect(controller.currentTrackId, equals(track1.id));
      final result1 = controller.getResultForTrack(track1);

      await controller.analyze(track2);
      expect(controller.currentTrackId, equals(track2.id));
      final result2 = controller.getResultForTrack(track2);

      expect(controller.hasResultForTrack(track1), isTrue);
      expect(controller.hasResultForTrack(track2), isTrue);
      expect(result1, isNotNull);
      expect(result2, isNotNull);

      // Switching back to track1 should immediately restore track1's result
      await controller.analyze(track1);
      expect(controller.currentTrackId, equals(track1.id));
      expect(controller.result, equals(result1));
    });

    test('ReplayGain query and toggle safely handle track state', () async {
      final track1 = AudioTrack(
        id: 'track-1',
        title: 'Track 1',
        source: AudioSource('assets/music/test_24bit.wav'),
      );

      await controller.analyze(track1);
      expect(controller.isReplayGainActiveForTrack(track1, null), isFalse);
    });
  });

  group('ReplayGain Operating Mode UI & Metadata Toggle Suite', () {
    late AudioEngineController engineController;
    late AudioAnalyzerController analyzerController;

    setUp(() {
      engineController = AudioEngineController();
      analyzerController = AudioAnalyzerController();
    });

    tearDown(() {
      analyzerController.dispose();
      engineController.dispose();
    });

    testWidgets('Renders 4-part AudioAnalyzerCard: Replay Gain, Waveform, Audio Info, and Metadata', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AudioAnalyzerCard(
                playerController: engineController,
                analyzerController: analyzerController,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Header & Status pill & Re-analyze IconButton
      expect(find.text('UNIFIED AUDIO ANALYZER'), findsOneWidget);
      expect(find.byType(IconButton), findsWidgets);
      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);

      // Verify Part 1: Replay Gain
      expect(find.text('REPLAY GAIN (BS.1770-4 / EBU R128)'), findsOneWidget);
      expect(find.text('REPLAY GAIN'), findsOneWidget);
      expect(find.text('TRUE-PEAK'), findsOneWidget);
      expect(find.text('INTEGRATED LOUDNESS'), findsOneWidget);

      // Verify Part 2: Waveform
      expect(find.text('WAVEFORM PROFILE'), findsOneWidget);
      expect(find.textContaining('discrete, un-smoothed rectangular blocks'), findsOneWidget);

      // Verify Part 3: Audio Info
      expect(find.text('AUDIO INFO'), findsOneWidget);
      expect(find.text('Container Format'), findsOneWidget);
      expect(find.text('Audio Codec'), findsOneWidget);
      expect(find.text('Sample Rate'), findsOneWidget);
      expect(find.text('Bitrate Mode'), findsOneWidget);

      // Verify Part 4: Metadata
      expect(find.text('METADATA'), findsOneWidget);
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Artist'), findsOneWidget);
      expect(find.text('Album'), findsOneWidget);
      expect(find.text('Thumbnails'), findsOneWidget);
      expect(find.text('Extended Tags'), findsOneWidget);

      // Now pump with active analysis containing extended metadata and waveform
      final sampleAnalysis = AudioAnalysisResult(
        audioInfo: const AudioInfo(
          sampleRate: 44100,
          channels: 2,
          bitrate: 320000,
          codec: 'FLAC',
          containerFormat: 'FLAC',
          lossless: true,
          bitrateMode: BitrateMode.vbr,
        ),
        replayGain: const ReplayGainResult(gainDb: -3.5, peak: 0.98, lufs: -17.5),
        waveform: const WaveformResult(points: [0.1, 0.5, 0.8, 0.3]),
        metadata: AudioMetadata(
          title: 'Master Track',
          trackArtist: 'Studio Artist',
          album: 'Studio Album',
          extended: const ExtendedMetadata(isrc: 'US-XYZ-26-00001'),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AudioAnalyzerCard(
                analysis: sampleAnalysis,
                isLoading: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify populated UI values
      expect(find.text('4 blocks'), findsOneWidget);
      expect(find.text('VBR'), findsOneWidget);
      expect(find.text('Master Track'), findsOneWidget);
      expect(find.textContaining('VIEW EXTENDED (1)'), findsOneWidget);
    });

    testWidgets('Full app mounts and displays acoustic analysis without errors', (tester) async {
      tester.view.physicalSize = const Size(412 * 2.0, 915 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(const MiniaudioPlayerExampleApp());
      await tester.pump();

      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 1));
      });
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('UNIFIED AUDIO ANALYZER'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('PlaybackEngineCard renders thumbnail, metadata inspection button, and clean artist subtitle without asset://', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(const MiniaudioPlayerExampleApp());
      await tester.pump();

      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 1));
      });
      await tester.pump(const Duration(milliseconds: 100));

      // 1. Verify "• asset://" or "• file://" is NOT present in any track subtitle
      expect(find.textContaining('• asset://'), findsNothing);
      expect(find.textContaining('• file://'), findsNothing);

      // 2. Verify Inspect Metadata button is present in PlaybackEngineCard
      final inspectButton = find.descendant(
        of: find.byType(PlaybackEngineCard),
        matching: find.byTooltip('Inspect Metadata (Static vs Dynamic)'),
      );
      expect(inspectButton, findsOneWidget);

      // 3. Tap the Metadata Inspector button and verify modal opens
      await tester.tap(inspectButton);
      await tester.pumpAndSettle();

      expect(find.text('METADATA INSPECTOR'), findsOneWidget);
      expect(find.text('STATIC METADATA (audioAnalysis)'), findsOneWidget);
      expect(find.text('DYNAMIC METADATA (Playback Engine)'), findsOneWidget);

      // Close modal
      final closeButton = find.byIcon(Icons.close);
      expect(closeButton, findsOneWidget);
      await tester.tap(closeButton);
      await tester.pumpAndSettle();

      final ex = tester.takeException();
      if (ex is FlutterError) {
        // ignore: avoid_print
        print(ex.toStringDeep());
      }
      expect(ex, isNull);
    });
  });
}
