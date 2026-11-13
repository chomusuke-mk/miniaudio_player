import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/concurrency_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  group('Unified Audio Analysis (ReplayGain, Loudness & Waveform)', () {
    test(
        'analyzeAudio calculates both ReplayGain and Waveform in a single pass on MP3 asset',
        () async {
      final mp3 = resolveAsset('test/fixtures/salida.mp3');
      expect(mp3.existsSync(), isTrue,
          reason: 'Test asset salida.mp3 must exist');

      final result = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        replayGain: true,
        waveform: true,
        waveformPoints: 100,
        targetLufs: -18.0,
      );

      // Track metadata
      expect(result.audioInfo.duration?.inMilliseconds, greaterThan(0));
      expect(result.audioInfo.sampleRate, equals(48000));
      expect(result.audioInfo.channels, equals(2));
      expect(result.audioInfo.bitrate, greaterThan(0));

      // ReplayGain metrics
      expect(result.replayGain, isNotNull);
      final rg = result.replayGain!;
      expect(rg.peak, greaterThan(0.9));
      expect(
          rg.peak,
          closeTo(1.46,
              0.05)); // True unclipped peak for salida.mp3 (matches ffmpeg track_peak 1.461720)
      expect(rg.lufs,
          closeTo(-4.7, 0.5)); // Expected ~ -4.7 LUFS (matches ffmpeg ebur128)
      expect(
          rg.gainDb,
          closeTo(
              -10.41, 0.5)); // Matches ffmpeg replaygain track_gain -10.41 dB

      // Check recommended volume
      final volWithClippingDefense =
          rg.getRecommendedVolume(preventClipping: true);
      expect(volWithClippingDefense, greaterThan(0.0));
      expect(volWithClippingDefense, lessThanOrEqualTo(1.0));

      // Waveform metrics
      expect(result.waveform, isNotNull);
      final wf = result.waveform!;
      expect(wf.length, equals(100));
      expect(wf.points.length, equals(100));

      // All waveform points should be normalized between 0.0 and 1.0
      for (final pt in wf.points) {
        expect(pt, greaterThanOrEqualTo(0.0));
        expect(pt, lessThanOrEqualTo(1.0));
      }

      // Max normalized point should reach 1.0 due to relative normalization
      final maxPt = wf.points.reduce((a, b) => a > b ? a : b);
      expect(maxPt, closeTo(1.0, 0.001));

      // Progress and position sampling helpers
      expect(wf.getPointAtProgress(0.0), equals(wf.points.first));
      expect(wf.getPointAtProgress(1.0), equals(wf.points.last));
      expect(
          wf.getPointAtPosition(
              Duration.zero, result.audioInfo.duration ?? Duration.zero),
          equals(wf.points.first));
    });

    test('analyzeAudio with only waveform skips ReplayGain calculation',
        () async {
      final mp3 = resolveAsset('test/fixtures/salida.mp3');
      expect(mp3.existsSync(), isTrue);

      final result = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        replayGain: false,
        waveform: true,
        waveformPoints: 64,
      );

      expect(result.replayGain, isNull);
      expect(result.waveform, isNotNull);
      expect(result.waveform!.length, equals(64));
    });

    test('analyzeAudio with only replayGain skips Waveform extraction',
        () async {
      final mp3 = resolveAsset('test/fixtures/salida.mp3');
      expect(mp3.existsSync(), isTrue);

      final result = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        replayGain: true,
        waveform: false,
      );

      expect(result.replayGain, isNotNull);
      expect(result.waveform, isNull);
      expect(result.replayGain!.lufs, closeTo(-4.7, 0.5));
    });

    test('analyzeAudioSync calculates loudness and waveform synchronously', () {
      final wav = resolveAsset('test/fixtures/salida.wav');
      expect(wav.existsSync(), isTrue);

      final result = MiniaudioPlayer.analyzeAudioSync(
        wav.path,
        targetLufs: -14.0,
        waveformPoints: 50,
      );

      expect(result.replayGain, isNotNull);
      expect(result.replayGain!.peak, greaterThan(0.9));
      expect(result.replayGain!.lufs, closeTo(-4.8, 0.5));
      expect(result.replayGain!.gainDb,
          closeTo(-10.36, 0.5)); // Matches ffmpeg replaygain -10.36 dB

      expect(result.waveform, isNotNull);
      expect(result.waveform!.length, equals(50));
    });

    test('analyzes FLAC, OPUS, AAC, and M4A seamlessly across codecs',
        () async {
      final formats = [
        'test/fixtures/salida.flac',
        'test/fixtures/salida.opus',
        'test/fixtures/salida.aac',
        'test/fixtures/salida_aac.m4a',
      ];

      for (final relPath in formats) {
        final file = resolveAsset(relPath);
        if (!file.existsSync()) continue;

        final result =
            await MiniaudioPlayer.analyzeAudio(file.path, waveformPoints: 80);
        expect(result.replayGain, isNotNull, reason: 'ReplayGain for $relPath');
        expect(result.replayGain!.peak, greaterThan(0.5),
            reason: 'Peak for $relPath');
        expect(result.replayGain!.lufs, lessThan(0.0),
            reason: 'LUFS for $relPath');
        expect(result.replayGain!.gainDb.isFinite, isTrue,
            reason: 'Gain for $relPath');
        expect(result.waveform, isNotNull, reason: 'Waveform for $relPath');
        expect(result.waveform!.length, equals(80),
            reason: 'Waveform points for $relPath');
      }
    });

    test('analyzes 24-bit WAV fixture with accurate peak and waveform',
        () async {
      final wav24 = resolveAsset('test/fixtures/test_24bit_stereo.wav');
      expect(wav24.existsSync(), isTrue);

      final result =
          await MiniaudioPlayer.analyzeAudio(wav24.path, waveformPoints: 30);
      expect(result.replayGain, isNotNull);
      expect(result.replayGain!.peak, greaterThan(0.05));
      expect(result.replayGain!.lufs.isFinite, isTrue);
      expect(result.replayGain!.gainDb.isFinite, isTrue);
      expect(result.waveform, isNotNull);
      expect(result.waveform!.length, equals(30));
    });

    test('handles non-existent file cleanly with MiniaudioPlayerException',
        () async {
      expect(
        () => MiniaudioPlayer.analyzeAudio(
            '/path/to/non_existent_file_xyz_123.mp3'),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('handles empty file cleanly with MiniaudioPlayerException', () async {
      final tempEmpty = File(
          '${Directory.systemTemp.path}/empty_analysis_${DateTime.now().millisecondsSinceEpoch}.wav');
      try {
        tempEmpty.createSync();
        expect(
          () => MiniaudioPlayer.analyzeAudio(tempEmpty.path),
          throwsA(isA<MiniaudioPlayerException>()),
        );
      } finally {
        if (tempEmpty.existsSync()) {
          tempEmpty.deleteSync();
        }
      }
    });

    test(
        'analyzeAudio accepts AudioSource instances directly for file and memory sources',
        () async {
      final mp3 = resolveAsset('test/fixtures/salida.mp3');
      expect(mp3.existsSync(), isTrue);

      // File AudioSource
      final fileSource = AudioSource(mp3.path);
      final fileRes = await MiniaudioPlayer.analyzeAudio(
        fileSource,
        waveformPoints: 32,
      );
      expect(fileRes.audioInfo.sampleRate, equals(48000));
      expect(fileRes.audioInfo.channels, equals(2));
      expect(fileRes.audioInfo.format, equals('mp3'));
      expect(fileRes.waveform?.length, equals(32));

      // Memory AudioSource
      final bytes = mp3.readAsBytesSync();
      final memSource = AudioSource(bytes);
      final memRes = await MiniaudioPlayer.analyzeAudio(
        memSource,
        waveformPoints: 32,
      );
      expect(memRes.audioInfo.sampleRate, equals(48000));
      expect(memRes.audioInfo.channels, equals(2));
      expect(memRes.audioInfo.format, equals('mp3'));
      expect(memRes.waveform?.length, equals(32));

      // Synchronous analysis with memory source
      final syncMemRes = MiniaudioPlayer.analyzeAudioSync(
        AudioSource(bytes),
        waveformPoints: 16,
      );
      expect(syncMemRes.audioInfo.sampleRate, equals(48000));
      expect(syncMemRes.waveform?.length, equals(16));
    });

    test('analyzeAudio extracts AudioMetadata when metadata: true is requested',
        () async {
      final mp3 = resolveAsset('test/fixtures/salida.mp3');
      expect(mp3.existsSync(), isTrue);

      // Default: metadata == false -> metadata is null
      final noMeta =
          await MiniaudioPlayer.analyzeAudio(mp3.path, metadata: false);
      expect(noMeta.metadata, isNull);

      // metadata == true -> metadata is extracted
      final withMeta =
          await MiniaudioPlayer.analyzeAudio(mp3.path, metadata: true);
      expect(withMeta.metadata, isNotNull);
      expect(withMeta.metadata!.isNotEmpty, isTrue);
      expect(withMeta.metadata!.length, greaterThan(0));
      expect(
          withMeta.metadata!.bytes.length, equals(withMeta.metadata!.length));
    });

    test(
        'analyzeAudio Phase 1 fast path resolves without waveform or replayGain',
        () async {
      final mp3 = resolveAsset('test/fixtures/salida.mp3');
      expect(mp3.existsSync(), isTrue);

      final sw = Stopwatch()..start();
      final fastRes = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        replayGain: false,
        waveform: false,
        metadata: true,
      );
      sw.stop();

      expect(fastRes.replayGain, isNull);
      expect(fastRes.waveform, isNull);
      expect(fastRes.audioInfo.sampleRate, equals(48000));
      expect(fastRes.audioInfo.channels, equals(2));
      expect(fastRes.metadata, isNotNull);
      expect(fastRes.metadata!.isNotEmpty, isTrue);
      // Static header analysis should execute extremely fast (< 100 ms in debug)
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('analyzeAudio with maxAnalysisDuration limits decoded duration',
        () async {
      final mp3 = resolveAsset('test/fixtures/salida.mp3');
      expect(mp3.existsSync(), isTrue);

      final fullRes = await MiniaudioPlayer.analyzeAudio(mp3.path);
      final cappedRes = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        maxAnalysisDuration: const Duration(milliseconds: 500),
      );

      expect(cappedRes.waveform, isNotNull);
      expect(cappedRes.replayGain?.peak, greaterThan(0.0));
      expect(
          cappedRes.audioInfo.sampleRate, equals(fullRes.audioInfo.sampleRate));
    });

    test('analyzeAudio with chromaprint calculates acoustic fingerprint',
        () async {
      final mp3 = resolveAsset('test/fixtures/salida.mp3');
      expect(mp3.existsSync(), isTrue);

      final noCp =
          await MiniaudioPlayer.analyzeAudio(mp3.path, chromaprint: false);
      expect(noCp.chromaprint, isNull);

      final withCp = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        chromaprint: true,
        maxAnalysisDuration: const Duration(seconds: 5),
      );
      expect(withCp.chromaprint, isNotNull);
      expect(withCp.chromaprint!.fingerprint.isNotEmpty, isTrue);
      expect(withCp.chromaprint!.raw.isNotEmpty, isTrue);
      expect(withCp.chromaprint!.algorithm, greaterThanOrEqualTo(0));
    });
  });

  group('MiniaudioPlayer Metadata and AudioInfo state and stream integration',
      () {
    test('player exposes audioInfo and metadata on state and stream', () async {
      final wav = resolveAsset('test/fixtures/salida.wav');
      expect(wav.existsSync(), isTrue);

      final source = AudioSource(wav.path);
      final player = MiniaudioPlayer();
      try {
        await player.action.setQueue([source]);
        await player.action.play();

        await awaitStateOrStream<AudioInfo?>(
          stream: player.stream.audioInfo,
          current: () => player.state.audioInfo,
          predicate: (info) => info != null,
          timeout: const Duration(seconds: 2),
          reason: 'AudioInfo should populate on track play',
        );

        expect(player.state.audioInfo, isNotNull);
        expect(player.state.audioInfo?.sampleRate, greaterThan(0));
        expect(player.state.duration, isNotNull);
        expect(player.state.metadataEnabled, isFalse);

        await player.action.setMetadataEnabled(true);
        expect(player.state.metadataEnabled, isTrue);

        await player.action.setMetadataEnabled(false);
        expect(player.state.metadataEnabled, isFalse);
      } finally {
        await player.dispose();
      }
    });
  });

  group('MiniaudioPlayer ReplayGain integration from AudioSource', () {
    test('player applies replay gain from AudioSource automatically on open',
        () async {
      final wav = resolveAsset('test/fixtures/salida.wav');
      expect(wav.existsSync(), isTrue);

      final source = AudioSource(
        wav.path,
        replayGainDb: -6.5,
        replayPeak: 0.95,
      );

      expect(source.replayGainDb, equals(-6.5));
      expect(source.replayPeak, equals(0.95));

      final player = MiniaudioPlayer(queue: [source]);
      try {
        await awaitStateOrStream<ReplayGainConfig>(
          stream: player.stream.replayGain,
          current: () => player.state.replayGain,
          predicate: (rg) => rg.gainDb != 0.0,
          timeout: const Duration(seconds: 2),
          reason: 'Constructor queue failed to apply ReplayGain metadata',
        );

        expect(player.state.replayGainMode, equals(ReplayGainMode.track));
        expect(player.state.replayGain.gainDb, closeTo(-6.5, 1e-4));
        expect(player.state.replayGain.peak, closeTo(0.95, 1e-4));

        // Queueing another source with new replay gain applies it
        final source2 = AudioSource(
          wav.path,
          replayGainDb: -3.0,
          replayPeak: 0.8,
        );
        await player.action.setQueue([source2]);

        expect(player.state.replayGain.gainDb, closeTo(-3.0, 1e-4));
        expect(player.state.replayGain.peak, closeTo(0.8, 1e-4));

        // Clearing replay gain by passing null resets it to default fallback
        await player.action.setReplayGain(null);
        expect(player.state.replayGain.gainDb, closeTo(0.0, 1e-4));
      } finally {
        await player.dispose();
      }
    });
  });
}
