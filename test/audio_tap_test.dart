import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

Uint8List _generateWavSine({
  int sampleRate = 48000,
  int channels = 2,
  double durationSeconds = 1.5,
  double frequencyHz = 440.0,
  double amplitude = 0.5,
}) {
  final frameCount = (sampleRate * durationSeconds).round();
  final dataBytes = frameCount * channels * 2;
  final totalBytes = 44 + dataBytes;
  final bytes = Uint8List(totalBytes);
  final bd = ByteData.sublistView(bytes);

  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes[offset + i] = s.codeUnitAt(i);
    }
  }

  writeAscii(0, 'RIFF');
  bd.setUint32(4, totalBytes - 8, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * channels * 2, Endian.little);
  bd.setUint16(32, channels * 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bd.setUint32(40, dataBytes, Endian.little);

  for (var f = 0; f < frameCount; f++) {
    final s = math.sin(2.0 * math.pi * frequencyHz * (f / sampleRate)) * amplitude;
    final sample = (s.clamp(-1.0, 1.0) * 32767.0).round();
    for (var ch = 0; ch < channels; ch++) {
      bd.setInt16(44 + (f * channels + ch) * 2, sample, Endian.little);
    }
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  group('Phase 1 Multi-Bus Audio Tap (Push & Zero-Alloc Pull)', () {
    test('Idle player has activeTapBusMask == 0 and rejects invalid frameDuration / capacity',
        () async {
      final player = MiniaudioPlayer(
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      addTearDown(player.dispose);

      expect(player.activeTapBusMask, equals(0));
      expect(
        () => player.watchAudioBus(frameDuration: const Duration(milliseconds: 2)),
        throwsRangeError,
      );
      expect(
        () => player.watchAudioBus(frameDuration: const Duration(milliseconds: 250)),
        throwsRangeError,
      );
      expect(
        () => player.openAudioTapBuffer(capacityFrames: 0),
        throwsArgumentError,
      );
      expect(player.activeTapBusMask, equals(0));
    });

    test('Push broadcast shares VoiceOnly x3 + independent MusicMix with unmodifiable chunks',
        () async {
      final wavBytes = _generateWavSine(sampleRate: 48000, channels: 2, frequencyHz: 440.0);
      final sfxBytes = _generateWavSine(
        sampleRate: 48000,
        channels: 2,
        durationSeconds: 1.0,
        frequencyHz: 880.0,
        amplitude: 0.6,
      );
      final player = MiniaudioPlayer(
        queue: [AudioSource(wavBytes, data: 'sine440')],
        effects: [AudioEffect(id: 'beep', source: AudioSource(sfxBytes))],
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      addTearDown(player.dispose);

      final vStream1 = player.watchAudioBus(
        source: AudioOutputSource.voiceOnly,
        format: AudioTapFormat.float32,
        frameDuration: const Duration(milliseconds: 20),
      );
      final vStream2 = player.watchAudioBus(
        source: AudioOutputSource.voiceOnly,
        format: AudioTapFormat.float32,
        frameDuration: const Duration(milliseconds: 20),
      );
      final vStream3 = player.watchAudioBus(
        source: AudioOutputSource.voiceOnly,
        format: AudioTapFormat.float32,
        frameDuration: const Duration(milliseconds: 20),
      );
      expect(identical(vStream1, vStream2), isTrue);
      expect(identical(vStream2, vStream3), isTrue);

      final v1Chunks = <AudioPcmChunk>[];
      final v2Chunks = <AudioPcmChunk>[];
      final v3Chunks = <AudioPcmChunk>[];
      final musicChunks = <AudioPcmChunk>[];

      final sub1 = vStream1.listen(v1Chunks.add);
      final sub2 = vStream2.listen(v2Chunks.add);
      final sub3 = vStream3.listen(v3Chunks.add);
      final musicSub = player
          .watchAudioBus(
            source: AudioOutputSource.musicMix,
            format: AudioTapFormat.pcm16,
            frameDuration: const Duration(milliseconds: 20),
          )
          .listen(musicChunks.add);

      await player.action.play();
      await player.action.playEffect('beep');

      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while ((v1Chunks.isEmpty || musicChunks.isEmpty) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(player.activeTapBusMask, equals((1 << 4) | (1 << 1)));
      expect(v1Chunks, isNotEmpty);
      expect(v2Chunks.length, equals(v1Chunks.length));
      expect(v3Chunks.length, equals(v1Chunks.length));
      expect(musicChunks, isNotEmpty);

      // Verify unmodifiable protection across broadcast listeners
      expect(() => v1Chunks.first.bytes[0] = 99, throwsUnsupportedError);
      expect(() => v1Chunks.first.samplesF32[0] = 1.0, throwsUnsupportedError);
      expect(() => v1Chunks.first.samplesF32, returnsNormally);
      expect(() => v1Chunks.first.samplesI16, throwsStateError);
      expect(() => musicChunks.first.samplesI16, returnsNormally);
      expect(() => musicChunks.first.samplesF32, throwsStateError);

      // Cancel 2 of 3 VoiceOnly subscribers; VoiceOnly bit must remain armed
      await sub1.cancel();
      await sub2.cancel();
      final countBefore = v3Chunks.length;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(v3Chunks.length, greaterThan(countBefore));
      expect((player.activeTapBusMask & (1 << 4)) != 0, isTrue);

      // Cancel final VoiceOnly subscriber; only MusicMix remains armed
      await sub3.cancel();
      expect(player.activeTapBusMask, equals(1 << 1));

      // Cancel MusicMix; mask returns cleanly to 0
      await musicSub.cancel();
      expect(player.activeTapBusMask, equals(0));
    });

    test('Zero-alloc Pull AudioTapBuffer captures Float32 & Pcm16 without per-poll allocs',
        () async {
      final wavBytes = _generateWavSine(sampleRate: 48000, channels: 2, frequencyHz: 660.0);
      final player = MiniaudioPlayer(
        queue: [AudioSource(wavBytes, data: 'sine660')],
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      addTearDown(player.dispose);

      final pullF32 = await player.openAudioTapBuffer(
        source: AudioOutputSource.all,
        format: AudioTapFormat.float32,
        capacityFrames: 1024,
      );
      expect(player.activeTapBusMask, equals(1 << 0));

      final pullI16 = await player.openAudioTapBuffer(
        source: AudioOutputSource.musicMix,
        format: AudioTapFormat.pcm16,
        capacityFrames: 1024,
      );
      expect(player.activeTapBusMask, equals((1 << 0) | (1 << 1)));

      await player.action.play();

      var totalF32Frames = 0;
      var maxAbsF32 = 0.0;
      var totalI16Frames = 0;
      var maxAbsI16 = 0;

      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while ((totalF32Frames < 960 ||
              totalI16Frames < 960 ||
              maxAbsF32 <= 0.05 ||
              maxAbsI16 <= 1500) &&
          DateTime.now().isBefore(deadline)) {
        final f = pullF32.poll(maxFrames: 512);
        if (f > 0) {
          totalF32Frames += f;
          final samples = pullF32.float32View;
          expect(samples.length, equals(f * pullF32.channels));
          expect(pullF32.bytesView.length, equals(f * pullF32.channels * 4));
          for (final v in samples) {
            final a = v.abs();
            if (a > maxAbsF32) maxAbsF32 = a;
          }
        }
        final i = pullI16.poll(maxFrames: 512);
        if (i > 0) {
          totalI16Frames += i;
          final samples = pullI16.int16View;
          expect(samples.length, equals(i * pullI16.channels));
          expect(pullI16.bytesView.length, equals(i * pullI16.channels * 2));
          for (final v in samples) {
            final a = v.abs();
            if (a > maxAbsI16) maxAbsI16 = a;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(totalF32Frames, greaterThanOrEqualTo(960));
      expect(totalI16Frames, greaterThanOrEqualTo(960));
      expect(maxAbsF32, greaterThan(0.05));
      expect(maxAbsI16, greaterThan(1500));

      pullF32.close();
      expect(pullF32.isClosed, isTrue);
      expect(pullF32.poll(), equals(0));
      expect(player.activeTapBusMask, equals(1 << 1));

      pullI16.close();
      expect(player.activeTapBusMask, equals(0));
    });
  });
}
