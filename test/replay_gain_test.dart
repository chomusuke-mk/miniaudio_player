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

  group('Unified Audio Analysis (ReplayGain, Loudness & Waveform)', () {
    test('analyzeAudio calculates both ReplayGain and Waveform in a single pass on MP3 asset', () async {
      final mp3 = resolveAsset('example/assets/music/salida.mp3');
      expect(mp3.existsSync(), isTrue, reason: 'Test asset salida.mp3 must exist');

      final result = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        replayGain: true,
        waveform: true,
        waveformPoints: 100,
        targetLufs: -18.0,
      );

      // Track metadata
      expect(result.duration.inMilliseconds, greaterThan(0));
      expect(result.sampleRate, equals(48000));
      expect(result.channels, equals(2));
      expect(result.bitrate, greaterThan(0));
      expect(result.peak, greaterThan(0.9));
      expect(result.peak, lessThanOrEqualTo(1.05));

      // ReplayGain metrics
      expect(result.replayGain, isNotNull);
      final rg = result.replayGain!;
      expect(rg.peak, greaterThan(0.9));
      expect(rg.peak, lessThanOrEqualTo(1.05));
      expect(rg.lufs, closeTo(-4.7, 0.5)); // Expected ~ -4.7 LUFS (matches ffmpeg ebur128)
      expect(rg.gainDb, closeTo(-13.3, 0.5)); // Target -18 - (-4.7) = -13.3 dB

      // Check recommended volume
      final volWithClippingDefense = rg.getRecommendedVolume(preventClipping: true);
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
      expect(wf.getPointAtPosition(Duration.zero, result.duration), equals(wf.points.first));
    });

    test('analyzeAudio with only waveform skips ReplayGain calculation', () async {
      final mp3 = resolveAsset('example/assets/music/salida.mp3');
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

    test('analyzeAudio with only replayGain skips Waveform extraction', () async {
      final mp3 = resolveAsset('example/assets/music/salida.mp3');
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
      final wav = resolveAsset('example/assets/music/salida.wav');
      expect(wav.existsSync(), isTrue);

      final result = MiniaudioPlayer.analyzeAudioSync(
        wav.path,
        targetLufs: -14.0,
        waveformPoints: 50,
      );

      expect(result.peak, greaterThan(0.9));
      expect(result.replayGain, isNotNull);
      expect(result.replayGain!.lufs, closeTo(-4.7, 0.5));
      expect(result.replayGain!.gainDb, closeTo(-9.3, 0.5)); // Target -14 - (-4.7) = -9.3 dB

      expect(result.waveform, isNotNull);
      expect(result.waveform!.length, equals(50));
    });

    test('analyzes FLAC, OPUS, AAC, and M4A seamlessly across codecs', () async {
      final formats = [
        'example/assets/music/salida.flac',
        'example/assets/music/salida.opus',
        'example/assets/music/salida.aac',
        'example/assets/music/salida_aac.m4a',
      ];

      for (final relPath in formats) {
        final file = resolveAsset(relPath);
        if (!file.existsSync()) continue;

        final result = await MiniaudioPlayer.analyzeAudio(file.path, waveformPoints: 80);
        expect(result.peak, greaterThan(0.5), reason: 'Peak for $relPath');
        expect(result.replayGain, isNotNull, reason: 'ReplayGain for $relPath');
        expect(result.replayGain!.lufs, lessThan(0.0), reason: 'LUFS for $relPath');
        expect(result.replayGain!.gainDb.isFinite, isTrue, reason: 'Gain for $relPath');
        expect(result.waveform, isNotNull, reason: 'Waveform for $relPath');
        expect(result.waveform!.length, equals(80), reason: 'Waveform points for $relPath');
      }
    });

    test('analyzes synthetic generated WAV with accurate peak', () async {
      final tempFile = File('${Directory.systemTemp.path}/test_synth_analysis_${DateTime.now().millisecondsSinceEpoch}.wav');
      try {
        final wavBytes = SyntheticAudioGenerator.generateWavBytes(
          durationSeconds: 2.0,
          frequencyHz: 1000.0,
          amplitude: 0.65,
        );
        await tempFile.writeAsBytes(wavBytes, flush: true);

        final result = await MiniaudioPlayer.analyzeAudio(tempFile.path, waveformPoints: 30);
        expect(result.peak, closeTo(0.65, 0.05));
        expect(result.replayGain, isNotNull);
        expect(result.replayGain!.lufs.isFinite, isTrue);
        expect(result.replayGain!.gainDb.isFinite, isTrue);
        expect(result.waveform, isNotNull);
        expect(result.waveform!.length, equals(30));
      } finally {
        if (tempFile.existsSync()) {
          tempFile.deleteSync();
        }
      }
    });

    test('handles non-existent file cleanly with MiniaudioPlayerException', () async {
      expect(
        () => MiniaudioPlayer.analyzeAudio('/path/to/non_existent_file_xyz_123.mp3'),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('handles empty file cleanly with MiniaudioPlayerException', () async {
      final tempEmpty = File('${Directory.systemTemp.path}/empty_analysis_${DateTime.now().millisecondsSinceEpoch}.wav');
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
  });
}
