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

  group('ReplayGain and ITU-R BS.1770-4 Loudness Analysis', () {
    test('calculateReplayGain calculates loudness and peak on MP3 asset', () async {
      final mp3 = resolveAsset('example/assets/music/salida.mp3');
      expect(mp3.existsSync(), isTrue, reason: 'Test asset salida.mp3 must exist');

      final result = await MiniaudioPlayer.calculateReplayGain(mp3.path, targetLufs: -18.0);

      expect(result.peak, greaterThan(0.9));
      expect(result.peak, lessThanOrEqualTo(1.05));
      expect(result.lufs, closeTo(-4.7, 0.5)); // Expected ~ -4.7 LUFS (matches ffmpeg ebur128)
      expect(result.gainDb, closeTo(-13.3, 0.5)); // Target -18 - (-4.7) = -13.3 dB

      // Check recommended volume
      final volWithClippingDefense = result.getRecommendedVolume(preventClipping: true);
      expect(volWithClippingDefense, greaterThan(0.0));
      expect(volWithClippingDefense, lessThanOrEqualTo(1.0));
    });

    test('calculateReplayGainSync calculates loudness synchronously', () {
      final wav = resolveAsset('example/assets/music/salida.wav');
      expect(wav.existsSync(), isTrue);

      final result = MiniaudioPlayer.calculateReplayGainSync(wav.path, targetLufs: -14.0);

      expect(result.peak, greaterThan(0.9));
      expect(result.lufs, closeTo(-4.7, 0.5));
      expect(result.gainDb, closeTo(-9.3, 0.5)); // Target -14 - (-4.7) = -9.3 dB
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

        final result = await MiniaudioPlayer.calculateReplayGain(file.path);
        expect(result.peak, greaterThan(0.5), reason: 'Peak for $relPath');
        expect(result.lufs, lessThan(0.0), reason: 'LUFS for $relPath');
        expect(result.gainDb.isFinite, isTrue, reason: 'Gain for $relPath');
      }
    });

    test('analyzes synthetic generated WAV with accurate peak', () async {
      final tempFile = File('${Directory.systemTemp.path}/test_synth_rg_${DateTime.now().millisecondsSinceEpoch}.wav');
      try {
        final wavBytes = SyntheticAudioGenerator.generateWavBytes(
          durationSeconds: 2.0,
          frequencyHz: 1000.0,
          amplitude: 0.65,
        );
        await tempFile.writeAsBytes(wavBytes, flush: true);

        final result = await MiniaudioPlayer.calculateReplayGain(tempFile.path);
        expect(result.peak, closeTo(0.65, 0.05));
        expect(result.lufs.isFinite, isTrue);
        expect(result.gainDb.isFinite, isTrue);
      } finally {
        if (tempFile.existsSync()) {
          tempFile.deleteSync();
        }
      }
    });

    test('handles non-existent file cleanly with MiniaudioPlayerException', () async {
      expect(
        () => MiniaudioPlayer.calculateReplayGain('/path/to/non_existent_file_xyz_123.mp3'),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('handles empty file cleanly with MiniaudioPlayerException', () async {
      final tempEmpty = File('${Directory.systemTemp.path}/empty_rg_${DateTime.now().millisecondsSinceEpoch}.wav');
      try {
        tempEmpty.createSync();
        expect(
          () => MiniaudioPlayer.calculateReplayGain(tempEmpty.path),
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
