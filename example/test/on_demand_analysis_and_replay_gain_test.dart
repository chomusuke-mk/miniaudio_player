import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/app.dart';
import 'package:miniaudio_player_example/controllers/audio_analyzer_controller.dart';
import 'package:miniaudio_player_example/controllers/audio_engine_controller.dart';
import 'package:miniaudio_player_example/models/audio_track.dart';
import 'package:miniaudio_player_example/theme/studio_colors.dart';
import 'package:miniaudio_player_example/widgets/cards/audio_analyzer_card.dart';
import 'package:miniaudio_player_example/widgets/cards/playback_engine_card.dart';
import 'package:miniaudio_player_example/widgets/common/metadata_inspector_modal.dart';

AudioAnalysisResult _makeTestAnalysis({double gainDb = -3.5}) {
  return AudioAnalysisResult(
    audioInfo: const AudioInfo(
      sampleRate: 44100,
      channels: 2,
      bitrate: 320000,
      codec: 'Opus',
      containerFormat: 'OggOpus',
      lossless: false,
      bitrateMode: BitrateMode.vbr,
    ),
    replayGain: ReplayGainResult(gainDb: gainDb, peak: 0.98, lufs: -17.5),
    waveform: const WaveformResult(points: [0.1, 0.5, 0.8, 0.3]),
    metadata: AudioMetadata(title: 'Test Track'),
    chromaprint: const ChromaprintResult(
      fingerprint: 'AQADtEmyREmURImC5_jx',
      raw: [123456],
      algorithm: 1,
    ),
  );
}

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
      expect(res!.waveform?.points.length, equals(100));
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

    test(
      'Switching selected track during in-flight analysis never leaves isAnalyzing stuck true',
      () async {
        final completer4 = Completer<AudioAnalysisResult?>();
        final customController = AudioAnalyzerController(
          analysisRunner: (_) => completer4.future,
        );
        addTearDown(customController.dispose);

        final track4 = AudioTrack(
          id: 'track-4',
          title: 'Track 4',
          source: AudioSource('assets/music/test_24bit.wav'),
        );
        final track5 = AudioTrack(
          id: 'track-5',
          title: 'Track 5',
          source: AudioSource('assets/music/cbr_noxing.mp3'),
        );

        final future4 = customController.analyze(track4);
        expect(customController.currentTrackId, equals(track4.id));
        expect(customController.isAnalyzing, isTrue);
        expect(customController.isAnalyzingTrack(track4), isTrue);
        expect(customController.hasAnyAnalysisInFlight, isTrue);

        // User switches away before track 4 finishes analyzing.
        customController.selectTrack(track5);
        expect(customController.currentTrackId, equals(track5.id));
        expect(customController.isAnalyzing, isFalse);
        expect(customController.isAnalyzingTrack(track5), isFalse);
        expect(customController.isAnalyzingTrack(track4), isTrue);
        expect(customController.hasAnyAnalysisInFlight, isTrue);

        completer4.complete(_makeTestAnalysis(gainDb: -4.2));
        final result4 = await future4;
        expect(result4?.replayGain?.gainDb, closeTo(-4.2, 0.001));

        expect(customController.isAnalyzing, isFalse);
        expect(customController.isAnalyzingTrack(track4), isFalse);
        expect(customController.hasAnyAnalysisInFlight, isFalse);
        expect(customController.hasResultForTrack(track4), isTrue);

        customController.selectTrack(track4);
        expect(customController.isAnalyzing, isFalse);
        expect(customController.result, equals(result4));
      },
    );

    test(
      'Rapid track switches coalesce queued analysis onto latest track and finish cleanly',
      () async {
        final startedIds = <String>[];
        final completers = <String, Completer<AudioAnalysisResult?>>{
          'track-4': Completer<AudioAnalysisResult?>(),
          'track-5': Completer<AudioAnalysisResult?>(),
          'track-6': Completer<AudioAnalysisResult?>(),
        };
        final customController = AudioAnalyzerController(
          analysisRunner: (track) {
            startedIds.add(track.id);
            return completers[track.id]!.future;
          },
        );
        addTearDown(customController.dispose);

        final track4 = AudioTrack(
          id: 'track-4',
          title: 'Track 4',
          source: AudioSource('assets/music/test_24bit.wav'),
        );
        final track5 = AudioTrack(
          id: 'track-5',
          title: 'Track 5',
          source: AudioSource('assets/music/cbr_noxing.mp3'),
        );
        final track6 = AudioTrack(
          id: 'track-6',
          title: 'Track 6',
          source: AudioSource('assets/music/salida.aif'),
        );

        final future4 = customController.analyze(track4);
        final future6 = customController.analyze(track6);
        expect(startedIds, equals(['track-4']));
        expect(customController.isAnalyzingTrack(track6), isTrue);

        // Rapidly switch past track 6 onto track 5 before track 4 finishes.
        final future5 = customController.analyze(track5);
        expect(await future6, isNull);
        expect(customController.isAnalyzingTrack(track6), isFalse);
        expect(customController.isAnalyzingTrack(track5), isTrue);
        expect(customController.isAnalyzing, isTrue);

        // Complete track 4 -> queued track 5 automatically starts; track 6 is skipped.
        completers['track-4']!.complete(_makeTestAnalysis(gainDb: -4.0));
        final result4 = await future4;
        await Future<void>.delayed(Duration.zero);

        expect(result4?.replayGain?.gainDb, closeTo(-4.0, 0.001));
        expect(startedIds, equals(['track-4', 'track-5']));
        expect(customController.hasResultForTrack(track4), isTrue);
        expect(customController.isAnalyzingTrack(track4), isFalse);
        expect(customController.isAnalyzingTrack(track5), isTrue);

        // Selecting cached track 4 while track 5 decodes should NOT display loading on track 4.
        customController.selectTrack(track4);
        expect(customController.isAnalyzing, isFalse);
        expect(customController.hasAnyAnalysisInFlight, isTrue);

        completers['track-5']!.complete(_makeTestAnalysis(gainDb: -6.0));
        final result5 = await future5;
        expect(result5?.replayGain?.gainDb, closeTo(-6.0, 0.001));
        expect(customController.hasResultForTrack(track5), isTrue);
        expect(customController.hasAnyAnalysisInFlight, isFalse);
        expect(customController.isAnalyzing, isFalse);

        // Cached revisit returns immediately without invoking runner again.
        final cached5 = await customController.analyze(track5);
        expect(cached5, equals(result5));
        expect(startedIds, equals(['track-4', 'track-5']));
      },
    );

    test(
      'Failed analysis clears loading state, records per-track error, and retries with force',
      () async {
        var attempts = 0;
        final customController = AudioAnalyzerController(
          analysisRunner: (_) async {
            attempts++;
            if (attempts == 1) {
              throw StateError('Simulated decode failure');
            }
            return _makeTestAnalysis(gainDb: -5.0);
          },
        );
        addTearDown(customController.dispose);

        final track = AudioTrack(
          id: 'track-err',
          title: 'Track Err',
          source: AudioSource('assets/music/test_24bit.wav'),
        );

        final first = await customController.analyze(track);
        expect(first, isNull);
        expect(customController.isAnalyzing, isFalse);
        expect(customController.hasAnyAnalysisInFlight, isFalse);
        expect(customController.hasErrorForTrack(track), isTrue);
        expect(customController.error, contains('Simulated decode failure'));
        expect(customController.hasResultForTrack(track), isFalse);

        final retry = await customController.analyze(track, force: true);
        expect(retry?.replayGain?.gainDb, closeTo(-5.0, 0.001));
        expect(attempts, equals(2));
        expect(customController.hasErrorForTrack(track), isFalse);
        expect(customController.error, isNull);
        expect(customController.hasResultForTrack(track), isTrue);
        expect(customController.isAnalyzing, isFalse);
      },
    );
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

    testWidgets(
      'Renders 4-part AudioAnalyzerCard: Replay Gain, Waveform, Audio Info, and Metadata',
      (tester) async {
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
        expect(
          find.textContaining('discrete, un-smoothed rectangular blocks'),
          findsOneWidget,
        );

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

        // Verify Part 5: Chromaprint
        expect(find.text('CHROMAPRINT / ACOUSTID FINGERPRINT'), findsOneWidget);

        // Now pump with active analysis containing extended metadata, waveform, and chromaprint
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
          replayGain: const ReplayGainResult(
            gainDb: -3.5,
            peak: 0.98,
            lufs: -17.5,
          ),
          waveform: const WaveformResult(points: [0.1, 0.5, 0.8, 0.3]),
          metadata: AudioMetadata(
            title: 'Master Track',
            trackArtist: 'Studio Artist',
            album: 'Studio Album',
            extended: const ExtendedMetadata(isrc: 'US-XYZ-26-00001'),
          ),
          chromaprint: const ChromaprintResult(
            fingerprint: 'AQADtEmyREmURImC5_jx',
            raw: [123456, 789012],
            algorithm: 1,
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AudioAnalyzerCard(
                  analysis: sampleAnalysis,
                  isLoading: false,
                  analyzerController: analyzerController,
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
        expect(find.textContaining('ALGORITHM TEST2 (1)'), findsOneWidget);
        expect(find.text('AQADtEmyREmURImC5_jx'), findsOneWidget);
        expect(find.text('IDENTIFY TRACK (AcoustID API)'), findsOneWidget);

        // Verify Replay Gain stacks vertically with larger values than Audio Info
        final gainRect = tester.getRect(find.text('-3.5 dB'));
        final peakRect = tester.getRect(find.text('0.9800'));
        final lufsRect = tester.getRect(find.text('-17.5 LUFS'));
        expect(gainRect.top, lessThan(peakRect.top));
        expect(peakRect.top, lessThan(lufsRect.top));
        final gainText = tester.widget<Text>(find.text('-3.5 dB'));
        final audioInfoValText = tester.widget<Text>(find.text('VBR'));
        expect(
          gainText.style!.fontSize!,
          greaterThan(audioInfoValText.style!.fontSize!),
        );

        // Verify Chromaprint algorithm is inline in description with highlighted color
        final chromaDescFinder = find.byWidgetPredicate((w) {
          if (w is! Text || w.textSpan is! TextSpan) return false;
          final root = w.textSpan! as TextSpan;
          final spans = root.children?.whereType<TextSpan>().toList() ?? [];
          return spans.any(
                (s) => (s.text ?? '').contains('Digital acoustic fingerprint'),
              ) &&
              spans.any(
                (s) =>
                    s.text == 'ALGORITHM TEST2 (1)' &&
                    s.style?.color == StudioColors.accentCyan,
              );
        });
        expect(chromaDescFinder, findsOneWidget);
      },
    );

    testWidgets(
      'Full app mounts and displays acoustic analysis without errors',
      (tester) async {
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
      },
    );

    testWidgets(
      'PlaybackEngineCard renders thumbnail, metadata inspection button, and clean artist subtitle without asset://',
      (tester) async {
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
      },
    );

    testWidgets(
      'AudioAnalyzerCard clears loading across track switches and forces retry on reanalyze tap',
      (tester) async {
        final completer4 = Completer<AudioAnalysisResult?>();
        var track5Attempts = 0;
        final customAnalyzer = AudioAnalyzerController(
          analysisRunner: (track) async {
            if (track.id == 'track-4') {
              return completer4.future;
            }
            track5Attempts++;
            if (track5Attempts == 1) {
              return null;
            }
            return _makeTestAnalysis(gainDb: -5.5);
          },
        );
        addTearDown(customAnalyzer.dispose);

        final track4 = AudioTrack(
          id: 'track-4',
          title: 'Track 4',
          source: AudioSource('assets/music/test_24bit.wav'),
        );
        final track5 = AudioTrack(
          id: 'track-5',
          title: 'Track 5',
          source: AudioSource('assets/music/cbr_noxing.mp3'),
        );

        final future4 = customAnalyzer.analyze(track4);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AudioAnalyzerCard(
                  track: track4,
                  analyzerController: customAnalyzer,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('loading...'), findsWidgets);

        // Switching the displayed track clears loading immediately even while track-4 runs.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AudioAnalyzerCard(
                  track: track5,
                  analyzerController: customAnalyzer,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('loading...'), findsNothing);

        // Completing track-4 and failing initial track-5 analysis leaves no stuck loading state.
        completer4.complete(_makeTestAnalysis(gainDb: -4.0));
        await future4;
        await customAnalyzer.analyze(track5);
        await tester.pump();

        expect(find.text('loading...'), findsNothing);
        expect(customAnalyzer.hasErrorForTrack(track5), isTrue);

        // Tapping Reanalyze passes force: true and populates the retry result.
        await tester.tap(find.byIcon(Icons.refresh_rounded));
        await tester.pumpAndSettle();

        expect(track5Attempts, equals(2));
        expect(find.text('loading...'), findsNothing);
        expect(find.text('Test Track'), findsOneWidget);
        expect(find.text('-5.5 dB'), findsOneWidget);
      },
    );

    testWidgets(
      'AudioAnalyzerCard renders 4 additional Audio Info fields and 4 AudioMetadata ReplayGain tag fields',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final richAnalysis = AudioAnalysisResult(
          audioInfo: const AudioInfo(
            sampleRate: 44100,
            rawSampleRate: 2822400,
            channels: 2,
            bitsPerSample: 24,
            bitrate: 1411000,
            duration: Duration(seconds: 10),
            format: 'flac',
            fileSize: 2 * 1024 * 1024,
            codec: 'FLAC',
            containerFormat: 'FLAC',
            lossless: true,
            bitrateMode: BitrateMode.vbr,
          ),
          replayGain: const ReplayGainResult(
            gainDb: -9.9,
            peak: 0.55,
            lufs: -8.1,
          ),
          waveform: const WaveformResult(points: [0.2, 0.7]),
          metadata: AudioMetadata(
            title: 'Master Track',
            trackArtist: 'Studio Artist',
            album: 'Studio Album',
            replayGainTrackGain: '-6.50 dB',
            replayGainTrackPeak: '0.988553',
            replayGainAlbumGain: '-7.10 dB',
            replayGainAlbumPeak: '0.995000',
          ),
          chromaprint: const ChromaprintResult(
            fingerprint: 'AQADtEmyREmURImC5_jx',
            raw: [123456],
            algorithm: 1,
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AudioAnalyzerCard(
                  analysis: richAnalysis,
                  isLoading: false,
                  analyzerController: analyzerController,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 4 extra Audio Info fields
        expect(find.text('Format'), findsOneWidget);
        expect(find.text('flac'), findsOneWidget);
        expect(find.text('Raw Sample Rate'), findsOneWidget);
        expect(find.text('2822400 Hz'), findsOneWidget);
        expect(find.text('File Size'), findsOneWidget);
        expect(find.text('2.00 MB'), findsOneWidget);
        expect(find.text('Total Frames'), findsOneWidget);
        expect(find.text('441,000'), findsOneWidget);

        // 4 AudioMetadata ReplayGain tag fields kept independent of BS.1770 KPI (-9.9 dB)
        expect(find.text('-9.9 dB'), findsOneWidget);
        expect(find.text('RG Track Gain'), findsOneWidget);
        expect(find.text('-6.50 dB'), findsOneWidget);
        expect(find.text('RG Track Peak'), findsOneWidget);
        expect(find.text('0.988553'), findsOneWidget);
        expect(find.text('RG Album Gain'), findsOneWidget);
        expect(find.text('-7.10 dB'), findsOneWidget);
        expect(find.text('RG Album Peak'), findsOneWidget);
        expect(find.text('0.995000'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'AudioAnalyzerCard adapts ReplayGain, Audio Info, Metadata, and Chromaprint across 1/4x4, 2x2, and 1x4 layouts',
      (tester) async {
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final analysis = _makeTestAnalysis();

        Future<void> pumpAtWidth(double width) async {
          tester.view.physicalSize = Size(width, 1600);
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: AudioAnalyzerCard(
                    analysis: analysis,
                    isLoading: false,
                    analyzerController: analyzerController,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        // 1. Wide (>= 760 inner width): all 4 sections on one row starting with ReplayGain (1/4 each)
        await pumpAtWidth(1000);
        final rgWide = tester.getTopLeft(
          find.text('REPLAY GAIN (BS.1770-4 / EBU R128)'),
        );
        final audioWide = tester.getTopLeft(find.text('AUDIO INFO'));
        final metaWide = tester.getTopLeft(find.text('METADATA'));
        final chromaWide = tester.getTopLeft(
          find.text('CHROMAPRINT / ACOUSTID FINGERPRINT'),
        );
        expect(rgWide.dx, lessThan(audioWide.dx));
        expect(audioWide.dx, lessThan(metaWide.dx));
        expect(metaWide.dx, lessThan(chromaWide.dx));
        expect((rgWide.dy - audioWide.dy).abs(), lessThan(8));
        expect((audioWide.dy - metaWide.dy).abs(), lessThan(8));
        expect((metaWide.dy - chromaWide.dy).abs(), lessThan(8));
        expect(find.textContaining('ALGORITHM TEST2 (1)'), findsOneWidget);
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).maxLines,
          14,
        );

        // 2. Medium (500..759 inner width): 2x2 grid ([ReplayGain, Audio Info] / [Metadata, Chromaprint])
        await pumpAtWidth(640);
        final rgMed = tester.getTopLeft(
          find.text('REPLAY GAIN (BS.1770-4 / EBU R128)'),
        );
        final audioMed = tester.getTopLeft(find.text('AUDIO INFO'));
        final metaMed = tester.getTopLeft(find.text('METADATA'));
        final chromaMed = tester.getTopLeft(
          find.text('CHROMAPRINT / ACOUSTID FINGERPRINT'),
        );
        expect(rgMed.dx, lessThan(audioMed.dx));
        expect((rgMed.dy - audioMed.dy).abs(), lessThan(8));
        expect(metaMed.dy, greaterThan(rgMed.dy + 50));
        expect(metaMed.dx, lessThan(chromaMed.dx));
        expect((metaMed.dy - chromaMed.dy).abs(), lessThan(8));
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).maxLines,
          2,
        );

        // 3. Compact (< 500 inner width): 1+1+1+1 vertical stack starting with ReplayGain
        await pumpAtWidth(400);
        final rgNarrow = tester.getTopLeft(
          find.text('REPLAY GAIN (BS.1770-4 / EBU R128)'),
        );
        final audioNarrow = tester.getTopLeft(find.text('AUDIO INFO'));
        final metaNarrow = tester.getTopLeft(find.text('METADATA'));
        final chromaNarrow = tester.getTopLeft(
          find.text('CHROMAPRINT / ACOUSTID FINGERPRINT'),
        );
        expect(audioNarrow.dy, greaterThan(rgNarrow.dy + 50));
        expect(metaNarrow.dy, greaterThan(audioNarrow.dy + 50));
        expect(chromaNarrow.dy, greaterThan(metaNarrow.dy + 50));
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).maxLines,
          2,
        );
      },
    );

    testWidgets(
      'AudioAnalyzerCard v/up toggle next to Re-analyze hides and restores entire analyzer body',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1400);
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
                  analysis: _makeTestAnalysis(),
                  isLoading: false,
                  analyzerController: analyzerController,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initially expanded: "v" chevron is next to Refresh and body is visible
        final refreshCenter = tester.getCenter(
          find.byIcon(Icons.refresh_rounded),
        );
        final collapseIcon = find.byIcon(Icons.keyboard_arrow_down_rounded);
        expect(collapseIcon, findsOneWidget);
        expect(
          tester.getCenter(collapseIcon).dx,
          greaterThan(refreshCenter.dx),
        );
        expect(find.text('WAVEFORM PROFILE'), findsOneWidget);
        expect(find.text('REPLAY GAIN (BS.1770-4 / EBU R128)'), findsOneWidget);
        expect(find.text('AUDIO INFO'), findsOneWidget);
        expect(find.text('METADATA'), findsOneWidget);
        expect(
          find.text('CHROMAPRINT / ACOUSTID FINGERPRINT'),
          findsOneWidget,
        );

        // Click "v": hides entire analyzer body and shows "^" button
        await tester.tap(collapseIcon);
        await tester.pumpAndSettle();

        expect(find.text('UNIFIED AUDIO ANALYZER'), findsOneWidget);
        expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
        expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
        expect(find.text('WAVEFORM PROFILE'), findsNothing);
        expect(find.text('REPLAY GAIN (BS.1770-4 / EBU R128)'), findsNothing);
        expect(find.text('AUDIO INFO'), findsNothing);
        expect(find.text('METADATA'), findsNothing);
        expect(find.text('CHROMAPRINT / ACOUSTID FINGERPRINT'), findsNothing);

        // Click "^": restores entire analyzer body and flips back to "v"
        await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
        expect(find.text('WAVEFORM PROFILE'), findsOneWidget);
        expect(find.text('REPLAY GAIN (BS.1770-4 / EBU R128)'), findsOneWidget);
        expect(find.text('AUDIO INFO'), findsOneWidget);
        expect(find.text('METADATA'), findsOneWidget);
        expect(
          find.text('CHROMAPRINT / ACOUSTID FINGERPRINT'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'MetadataInspectorModal removes REPLAYGAIN & LOUDNESS TAGS, renames METADATA TAGS without CORE, and shows AudioMetadata ReplayGain tags',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final track = AudioTrack(
          id: 'inspect-rg',
          title: 'Inspect Track',
          source: AudioSource('assets/music/test_24bit.wav'),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MetadataInspectorModal(
                track: track,
                staticMetadata: AudioMetadata(
                  title: 'Static Song',
                  replayGainTrackGain: '-6.50 dB',
                  replayGainTrackPeak: '0.988553',
                  replayGainAlbumGain: '-7.10 dB',
                  replayGainAlbumPeak: '0.995000',
                ),
                dynamicMetadata: AudioMetadata(
                  title: 'Dynamic Song',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('REPLAYGAIN & LOUDNESS TAGS'), findsNothing);
        expect(find.text('CORE METADATA TAGS'), findsNothing);
        expect(find.text('METADATA TAGS'), findsNWidgets(2));
        expect(find.text('RG Track Gain'), findsNWidgets(2));
        expect(find.text('RG Track Peak'), findsNWidgets(2));
        expect(find.text('RG Album Gain'), findsNWidgets(2));
        expect(find.text('RG Album Peak'), findsNWidgets(2));
        expect(find.text('-6.50 dB'), findsOneWidget);
        expect(find.text('0.988553'), findsOneWidget);
        expect(find.text('-7.10 dB'), findsOneWidget);
        expect(find.text('0.995000'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
