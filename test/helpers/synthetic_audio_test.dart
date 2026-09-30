import 'package:flutter_test/flutter_test.dart';

import 'synthetic_audio.dart';

void main() {
  group('SyntheticAudioGenerator', () {
    test('generates valid 16-bit PCM RIFF WAV bytes for mono', () {
      final bytes = SyntheticAudioGenerator.generateWavBytes(
        frequencyHz: 440.0,
        durationSeconds: 0.5,
        sampleRate: 44100,
        numChannels: 1,
      );

      expect(SyntheticAudioGenerator.isValidWav(bytes), isTrue);
      expect(
        SyntheticAudioGenerator.parseWavDuration(bytes).inMilliseconds,
        closeTo(500, 5),
      );
    });

    test('generates valid 16-bit PCM RIFF WAV bytes for stereo', () {
      final bytes = SyntheticAudioGenerator.generateWavBytes(
        frequencyHz: 440.0,
        stereoRightFrequencyHz: 880.0,
        durationSeconds: 1.0,
        sampleRate: 44100,
        numChannels: 2,
      );

      expect(SyntheticAudioGenerator.isValidWav(bytes), isTrue);
      expect(
        SyntheticAudioGenerator.parseWavDuration(bytes).inMilliseconds,
        closeTo(1000, 5),
      );
    });

    test('generates valid silence audio', () {
      final bytes = SyntheticAudioGenerator.generateSilenceBytes(
        durationSeconds: 0.2,
      );

      expect(SyntheticAudioGenerator.isValidWav(bytes), isTrue);
      expect(
        SyntheticAudioGenerator.parseWavDuration(bytes).inMilliseconds,
        closeTo(200, 5),
      );
    });

    test('creates and cleans up temporary WAV file', () async {
      final file = await SyntheticAudioGenerator.createTempWavFile(
        durationSeconds: 0.1,
      );

      expect(await file.exists(), isTrue);
      final readBytes = await file.readAsBytes();
      expect(SyntheticAudioGenerator.isValidWav(readBytes), isTrue);

      await SyntheticAudioGenerator.cleanUp(file);
      expect(await file.exists(), isFalse);
    });

    test('creates corrupted file for decoder resilience testing', () async {
      final file = await SyntheticAudioGenerator.createCorruptedFile(
        byteLength: 32,
      );
      expect(await file.exists(), isTrue);
      final readBytes = await file.readAsBytes();
      expect(SyntheticAudioGenerator.isValidWav(readBytes), isFalse);

      await SyntheticAudioGenerator.cleanUp(file);
      expect(await file.exists(), isFalse);
    });

    test('creates 0-byte file for empty file boundary testing', () async {
      final file = await SyntheticAudioGenerator.createZeroByteFile();
      expect(await file.exists(), isTrue);
      expect(await file.length(), equals(0));

      await SyntheticAudioGenerator.cleanUp(file);
      expect(await file.exists(), isFalse);
    });
  });
}
