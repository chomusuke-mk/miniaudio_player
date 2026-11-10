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

    testWidgets('Renders ReplayGain operating modes with English descriptions', (tester) async {
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

      // Verify Header & Mode selector are present
      expect(find.text('UNIFIED AUDIO ANALYZER (BS.1770-4 / EBU R128)'), findsOneWidget);
      expect(find.text('REPLAYGAIN NORMALIZATION'), findsOneWidget);
      expect(find.text('TRACK (AUTO)'), findsOneWidget);

      // Verify default English description for ReplayGainMode.track
      expect(
        find.textContaining('Automatically applies individual ITU-R BS.1770-4'),
        findsOneWidget,
      );

      // Verify Real-Time Streaming Metadata toggle section
      expect(find.text('REAL-TIME STREAM METADATA'), findsOneWidget);
      expect(find.text('Parses live ICY radio headers and dynamic ID3v2 tags during playback'), findsOneWidget);
      expect(find.byType(Switch), findsWidgets);
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

      expect(find.text('UNIFIED AUDIO ANALYZER (BS.1770-4 / EBU R128)'), findsOneWidget);
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

      expect(tester.takeException(), isNull);
    });
  });
}
