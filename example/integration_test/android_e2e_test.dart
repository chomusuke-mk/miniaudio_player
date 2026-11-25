import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/features/console/controllers/audio_engine_controller.dart';

Uint8List _wavSine({
  int sampleRate = 48000,
  int channels = 2,
  double durationSeconds = 2.0,
  double frequencyHz = 440.0,
}) {
  final frameCount = (sampleRate * durationSeconds).round();
  final dataBytes = frameCount * channels * 2;
  final totalBytes = 44 + dataBytes;
  final bytes = Uint8List(totalBytes);
  final bd = ByteData.sublistView(bytes);
  void ascii(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes[o + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  bd.setUint32(4, totalBytes - 8, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * channels * 2, Endian.little);
  bd.setUint16(32, channels * 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, dataBytes, Endian.little);
  for (var f = 0; f < frameCount; f++) {
    final s = (math.sin(2.0 * math.pi * frequencyHz * (f / sampleRate)) * 16000).round();
    for (var c = 0; c < channels; c++) {
      bd.setInt16(44 + (f * channels + c) * 2, s, Endian.little);
    }
  }
  return bytes;
}

const MethodChannel _contentTestChannel = MethodChannel(
  'dev.chomusuke.miniaudio_player_example/content_test',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized(
      rootIsolateToken: RootIsolateToken.instance,
    );
  });

  group('Android Real Device E2E: Tap + Recorder + content://', () {
    testWidgets('Phase 1 Push & Zero-Alloc Pull Tap on real Android ARM64 hardware',
        (tester) async {
      final player = MiniaudioPlayer(
        queue: [AudioSource(_wavSine(frequencyHz: 440.0), data: 'sine')],
        effects: [
          AudioEffect(id: 'beep', source: AudioSource(_wavSine(frequencyHz: 880.0))),
        ],
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      addTearDown(player.dispose);

      expect(player.activeTapBusMask, equals(0));

      // Push: VoiceOnly x2 + MusicMix
      final vChunks = <AudioPcmChunk>[];
      final mChunks = <AudioPcmChunk>[];
      final vStream = player.watchAudioBus(
        source: AudioOutputSource.voiceOnly,
        format: AudioTapFormat.float32,
      );
      final s1 = vStream.listen(vChunks.add);
      final s2 = vStream.listen((_) {});
      final sm = player
          .watchAudioBus(
            source: AudioOutputSource.musicMix,
            format: AudioTapFormat.pcm16,
          )
          .listen(mChunks.add);

      await player.action.play();
      await player.action.playEffect('beep');

      final deadline = DateTime.now().add(const Duration(seconds: 4));
      while ((vChunks.isEmpty || mChunks.isEmpty) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      expect(vChunks, isNotEmpty);
      expect(mChunks, isNotEmpty);
      expect(player.activeTapBusMask, equals((1 << 4) | (1 << 1)));

      await s1.cancel();
      expect((player.activeTapBusMask & (1 << 4)) != 0, isTrue);
      await s2.cancel();
      await sm.cancel();
      expect(player.activeTapBusMask, equals(0));

      // Pull Zero-Alloc via C-ABI map_tap_* symbols on Android ARM64 .so
      final pullBuf = await player.openAudioTapBuffer(
        source: AudioOutputSource.all,
        format: AudioTapFormat.float32,
        capacityFrames: 1024,
      );
      var pulledFrames = 0;
      var maxAmp = 0.0;
      final pullDeadline = DateTime.now().add(const Duration(seconds: 4));
      while ((pulledFrames < 960 || maxAmp <= 0.05) &&
          DateTime.now().isBefore(pullDeadline)) {
        final f = pullBuf.poll(maxFrames: 512);
        if (f > 0) {
          pulledFrames += f;
          for (final sample in pullBuf.float32View) {
            if (sample.abs() > maxAmp) maxAmp = sample.abs();
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 12));
      }
      expect(pulledFrames, greaterThanOrEqualTo(960));
      expect(maxAmp, greaterThan(0.05));
      pullBuf.close();
      expect(player.activeTapBusMask, equals(0));
    });

    testWidgets('Phase 2 & 3 MemoryRecordingBuffer, file:// URI, and AudioEngineController on Android',
        (tester) async {
      // 1. AudioEngineController default recording path (path_provider temp dir, no package:file)
      final controller = AudioEngineController();
      addTearDown(controller.dispose);
      await controller.init();
      await controller.engine.action.play();

      controller.setRecordingFormat(AudioFileFormat.wav);
      await controller.startRecording();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final diskRes = await controller.stopRecording();
      addTearDown(() {
        final f = File(diskRes.path);
        if (f.parent.existsSync()) f.parent.deleteSync(recursive: true);
      });

      expect(File(diskRes.path).existsSync(), isTrue);
      expect(diskRes.bytesWritten, greaterThan(0));
      expect(diskRes.droppedFrames, equals(0));

      // 2. MemoryRecordingBuffer Float32 on Android
      final memBuf = MemoryRecordingBuffer();
      await controller.engine.action.startRecordingToBuffer(
        memBuf,
        format: AudioFileFormat.wavFloat32,
      );
      await Future<void>.delayed(const Duration(milliseconds: 220));
      final memRes = await controller.engine.action.stopRecording();
      final wavBytes = memBuf.toBytes();
      expect(wavBytes.length, equals(44 + memRes.bytesWritten));
      expect(ByteData.sublistView(wavBytes).getUint16(20, Endian.little), equals(3));

      // 3. Unsupported format throws errorUnsupported (-9)
      await expectLater(
        () => controller.engine.action.startRecordingToBuffer(
          MemoryRecordingBuffer(),
          format: AudioFileFormat.mp3,
        ),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorUnsupported),
          ),
        ),
      );
    });

    testWidgets('Phase 4 real Android content:// (MediaStore SAF/FD) WAV recording & playback',
        (tester) async {
      expect(Platform.isAndroid, isTrue);

      final uriString = await _contentTestChannel.invokeMethod<String>(
        'createMediaStoreWavUri',
        <String, dynamic>{
          'displayName': 'map_e2e_${DateTime.now().millisecondsSinceEpoch}.wav',
        },
      );
      expect(uriString, isNotNull);
      expect(uriString!.startsWith('content://'), isTrue);

      addTearDown(() async {
        try {
          await _contentTestChannel.invokeMethod<int>(
            'deleteContentUri',
            <String, dynamic>{'uri': uriString},
          );
        } catch (_) {}
      });

      final player = MiniaudioPlayer(
        queue: [AudioSource(_wavSine(frequencyHz: 440.0), data: 'sine')],
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      addTearDown(player.dispose);

      // Start recording directly to real Android content:// URI (uses MiniaudioPlayerPlugin openWritableContentFd -> rust fd)
      await player.action.startRecording(
        uriString,
        format: AudioFileFormat.wavFloat32,
        source: AudioOutputSource.all,
      );
      expect(player.state.isRecording, isTrue);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 350));

      final recRes = await player.action.stopRecording();
      expect(recRes.path, equals(uriString));
      expect(recRes.bytesWritten, greaterThan(0));
      expect(recRes.droppedFrames, equals(0));
      expect(player.state.isRecording, isFalse);

      // Read back raw bytes from Android ContentResolver and validate RIFF/IEEE-Float WAV
      final rawBytes = await _contentTestChannel.invokeMethod<Uint8List>(
        'readContentBytes',
        <String, dynamic>{'uri': uriString},
      );
      expect(rawBytes, isNotNull);
      expect(rawBytes!.length, equals(44 + recRes.bytesWritten));
      expect(String.fromCharCodes(rawBytes.sublist(0, 4)), equals('RIFF'));
      expect(String.fromCharCodes(rawBytes.sublist(8, 12)), equals('WAVE'));

      final bd = ByteData.sublistView(rawBytes);
      expect(bd.getUint32(4, Endian.little), equals(rawBytes.length - 8));
      expect(bd.getUint16(20, Endian.little), equals(3)); // IEEE Float32
      expect(bd.getUint16(34, Endian.little), equals(32)); // 32 bits/sample
      expect(bd.getUint32(40, Endian.little), equals(recRes.bytesWritten));

      // Confirm non-zero recorded float waveform samples landed through MediaStore FD
      var maxFloat = 0.0;
      for (var off = 44; off + 4 <= rawBytes.length; off += 4) {
        final v = bd.getFloat32(off, Endian.little).abs();
        if (v > maxFloat) maxFloat = v;
      }
      expect(maxFloat, greaterThan(0.05));

      // Also verify playing back the recorded content:// URI via openContentFd works!
      final contentAnalysis = await MiniaudioPlayer.analyzeAudio(
        uriString,
        replayGain: false,
        waveform: false,
      );
      expect(contentAnalysis.audioInfo.sampleRate, equals(48000));
      expect(contentAnalysis.audioInfo.channels, equals(2));

      // Non-existent content:// URI maps cleanly to errorFileNotFound / errorAccessDenied
      await expectLater(
        () => player.action.startRecording('content://media/external/audio/media/999999999'),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    testWidgets('Phase 4 background Isolate.run with RootIsolateToken records content:// on Android',
        (tester) async {
      final token = RootIsolateToken.instance;
      expect(token, isNotNull);

      final uriString = await _contentTestChannel.invokeMethod<String>(
        'createMediaStoreWavUri',
        <String, dynamic>{
          'displayName': 'map_bg_iso_${DateTime.now().millisecondsSinceEpoch}.wav',
        },
      );
      expect(uriString, isNotNull);

      addTearDown(() async {
        try {
          await _contentTestChannel.invokeMethod<int>(
            'deleteContentUri',
            <String, dynamic>{'uri': uriString},
          );
        } catch (_) {}
      });

      final wavInput = _wavSine(frequencyHz: 520.0);
      final bytesWritten = await Isolate.run<int>(() async {
        await MiniaudioPlayer.ensureInitialized(rootIsolateToken: token);
        final bgPlayer = MiniaudioPlayer(
          queue: [AudioSource(wavInput, data: 'bg_sine')],
          outputs: const {},
          config: const PlayerConfig(sampleRate: 48000, channels: 2),
        );
        try {
          await bgPlayer.action.startRecording(
            uriString!,
            format: AudioFileFormat.wav,
          );
          await bgPlayer.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final res = await bgPlayer.action.stopRecording();
          return res.bytesWritten;
        } finally {
          await bgPlayer.dispose();
        }
      });

      expect(bytesWritten, greaterThan(0));
      final rawBytes = await _contentTestChannel.invokeMethod<Uint8List>(
        'readContentBytes',
        <String, dynamic>{'uri': uriString},
      );
      expect(rawBytes, isNotNull);
      expect(rawBytes!.length, equals(44 + bytesWritten));
      expect(String.fromCharCodes(rawBytes.sublist(0, 4)), equals('RIFF'));
      expect(ByteData.sublistView(rawBytes).getUint16(20, Endian.little), equals(1));
    });
  });
}
