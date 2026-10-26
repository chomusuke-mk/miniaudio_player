import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioCodec Pure Magic-Bytes Sniffing (No Extension Reliance)', () {
    test('Sniffs FLAC magic bytes (fLaC)', () {
      final bytes = Uint8List.fromList([0x66, 0x4C, 0x61, 0x43, 0x00, 0x00]);
      expect(AudioCodec.detect(bytes), equals(AudioCodec.flac));
    });

    test('Sniffs WAV / PCM (RIFF....WAVE)', () {
      final bytes = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0x24, 0x00, 0x00, 0x00, // Size
        0x57, 0x41, 0x56, 0x45, // WAVE
      ]);
      expect(AudioCodec.detect(bytes), equals(AudioCodec.pcm));
    });

    test('Sniffs RF64 / PCM (RF64....WAVE)', () {
      final bytes = Uint8List.fromList([
        0x52, 0x46, 0x36, 0x34, // RF64
        0xFF, 0xFF, 0xFF, 0xFF, // Size
        0x57, 0x41, 0x56, 0x45, // WAVE
      ]);
      expect(AudioCodec.detect(bytes), equals(AudioCodec.pcm));
    });

    test('Sniffs AIFF / PCM (FORM....AIFF)', () {
      final bytes = Uint8List.fromList([
        0x46, 0x4F, 0x52, 0x4D, // FORM
        0x00, 0x00, 0x10, 0x00, // Size
        0x41, 0x49, 0x46, 0x46, // AIFF
      ]);
      expect(AudioCodec.detect(bytes), equals(AudioCodec.pcm));
    });

    test('Sniffs Ogg Opus (OggS....OpusHead)', () {
      final bytes = Uint8List.fromList([
        0x4F, 0x67, 0x67, 0x53, // OggS
        0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x13,
        0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64, // OpusHead
      ]);
      expect(AudioCodec.detect(bytes), equals(AudioCodec.opus));
    });

    test('Sniffs Ogg Vorbis (OggS....vorbis)', () {
      final bytes = Uint8List.fromList([
        0x4F, 0x67, 0x67, 0x53, // OggS
        0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x1E,
        0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73, // vorbis
      ]);
      expect(AudioCodec.detect(bytes), equals(AudioCodec.vorbis));
    });

    test('Sniffs MP3 with ID3v2 tag (ID3)', () {
      final bytes = Uint8List.fromList([
        0x49, 0x44, 0x33, // ID3
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
      ]);
      expect(AudioCodec.detect(bytes), equals(AudioCodec.mp3));
    });

    test('Sniffs MP3 MPEG sync word without ID3 (0xFFFB)', () {
      final bytes = Uint8List.fromList([
        0xFF, 0xFB, 0x90, 0x64, 0x00, 0x00, 0x00, 0x00,
      ]);
      expect(AudioCodec.detect(bytes), equals(AudioCodec.mp3));
    });

    test('Sniffs AAC ADTS sync word (0xFFF1)', () {
      final bytes = Uint8List.fromList([
        0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC,
      ]);
      expect(AudioCodec.detect(bytes), equals(AudioCodec.aac));
    });

    test('Sniffs MP4 / M4A AAC (ftypM4A)', () {
      final bytes = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x20, // size
        0x66, 0x74, 0x79, 0x70, // ftyp
        0x4D, 0x34, 0x41, 0x20, // M4A 
        0x00, 0x00, 0x00, 0x00,
      ]);
      expect(AudioCodec.detect(bytes), equals(AudioCodec.aac));
    });

    test('Falls back to MIME type when magic bytes are unknown', () {
      final unknownBytes = Uint8List.fromList([0x12, 0x34, 0x56, 0x78]);
      expect(
        AudioCodec.detect(unknownBytes, mime: 'audio/flac'),
        equals(AudioCodec.flac),
      );
      expect(
        AudioCodec.detect(unknownBytes, mime: 'audio/mpeg'),
        equals(AudioCodec.mp3),
      );
      expect(
        AudioCodec.detect(unknownBytes, mime: 'audio/aac'),
        equals(AudioCodec.aac),
      );
      expect(
        AudioCodec.detect(unknownBytes, mime: 'audio/opus'),
        equals(AudioCodec.opus),
      );
      expect(
        AudioCodec.detect(unknownBytes, mime: 'audio/ogg'),
        equals(AudioCodec.vorbis),
      );
      expect(
        AudioCodec.detect(unknownBytes, mime: 'audio/wav'),
        equals(AudioCodec.pcm),
      );
      expect(
        AudioCodec.detect(unknownBytes, mime: 'application/octet-stream'),
        equals(AudioCodec.unknown),
      );
    });

    test('Real asset files codec detection matches expected codecs', () {
      final assets = {
        'example/assets/music/salida.flac': AudioCodec.flac,
        'example/assets/music/salida.mp3': AudioCodec.mp3,
        'example/assets/music/cbr_noxing.mp3': AudioCodec.mp3,
        'example/assets/music/salida.wav': AudioCodec.pcm,
        'example/assets/music/salida.ogg': AudioCodec.vorbis,
        'example/assets/music/salida_aac.m4a': AudioCodec.aac,
        'example/assets/music/salida_alac.m4a': AudioCodec.alac,
      };

      for (final entry in assets.entries) {
        final file = File(entry.key);
        if (file.existsSync()) {
          final header = file.openSync().readSync(4096);
          final detected = AudioCodec.detect(header);
          expect(
            detected,
            equals(entry.value),
            reason: '${entry.key} detected as $detected instead of ${entry.value}',
          );
        }
      }
    });
  });

  group('Misnamed Files and Extensionless URLs Handling', () {
    late MiniaudioPlayer player;
    late Directory tempDir;

    setUp(() async {
      player = MiniaudioPlayer();
      tempDir = Directory.systemTemp.createTempSync('miniaudio_codec_test_');
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Plays MP3 correctly when file is renamed with wrong extension (.wav)', () async {
      final srcFile = File('example/assets/music/salida.mp3');
      if (!srcFile.existsSync()) return;

      final misnamed = File('${tempDir.path}/track_actually_mp3.wav');
      misnamed.writeAsBytesSync(srcFile.readAsBytesSync());

      await player.action.open(AudioSource.file(misnamed.path));
      expect(player.state.trackMetadata?.codec, equals(AudioCodec.mp3));
      expect(player.state.duration.inMilliseconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('Plays FLAC correctly when file has NO extension at all', () async {
      final srcFile = File('example/assets/music/salida.flac');
      if (!srcFile.existsSync()) return;

      final extensionless = File('${tempDir.path}/audio_stream_payload');
      extensionless.writeAsBytesSync(srcFile.readAsBytesSync());

      await player.action.open(AudioSource.file(extensionless.path));
      expect(player.state.trackMetadata?.codec, equals(AudioCodec.flac));
      expect(player.state.duration.inMilliseconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('Plays AAC M4A correctly when file has .bin extension', () async {
      final srcFile = File('example/assets/music/salida_aac.m4a');
      if (!srcFile.existsSync()) return;

      final misnamed = File('${tempDir.path}/opaque_blob.bin');
      misnamed.writeAsBytesSync(srcFile.readAsBytesSync());

      await player.action.open(AudioSource.file(misnamed.path));
      expect(player.state.trackMetadata?.codec, equals(AudioCodec.aac));
      expect(player.state.duration.inMilliseconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });
  });

  group('Second-Based Buffer Configuration and Telemetry', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('Global config accepts typed Duration buffer settings', () {
      MiniaudioPlayer.config(
        bufferLocalDuration: const Duration(seconds: 8),
        bufferNetworkDuration: const Duration(seconds: 30),
        bufferLiveStreamDuration: const Duration(seconds: 15),
        bufferBehindLocalDuration: const Duration(seconds: 4),
        bufferBehindNetworkDuration: const Duration(seconds: 12),
        bufferBehindLiveStreamDuration: const Duration(seconds: 6),
      );

      expect(MiniaudioPlayer.globalConfig.bufferLocalDuration.inSeconds, equals(8));
      expect(MiniaudioPlayer.globalConfig.bufferNetworkDuration.inSeconds, equals(30));
      expect(MiniaudioPlayer.globalConfig.bufferLiveStreamDuration.inSeconds, equals(15));
      expect(MiniaudioPlayer.globalConfig.bufferBehindLocalDuration.inSeconds, equals(4));
      expect(MiniaudioPlayer.globalConfig.bufferBehindNetworkDuration.inSeconds, equals(12));
      expect(MiniaudioPlayer.globalConfig.bufferBehindLiveStreamDuration.inSeconds, equals(6));

      // Player instance delegates cleanly to global config
      expect(player.bufferLocalDuration.inSeconds, equals(8));
      expect(player.bufferNetworkDuration.inSeconds, equals(30));
      expect(player.bufferLiveStreamDuration.inSeconds, equals(15));
      expect(player.bufferBehindLocalDuration.inSeconds, equals(4));
      expect(player.bufferBehindNetworkDuration.inSeconds, equals(12));
      expect(player.bufferBehindLiveStreamDuration.inSeconds, equals(6));
    });

    test('BufferedRange telemetry calculation and getters', () {
      const range = BufferedRange(
        start: Duration(seconds: 5),
        end: Duration(seconds: 25),
        duration: Duration(seconds: 100),
        isBuffering: false,
        isEof: false,
      );

      expect(range.windowDuration, equals(const Duration(seconds: 20)));
      expect(range.percentage, closeTo(0.25, 0.001));
      expect(range.fillPercentage, closeTo(0.20, 0.001));
      expect(range.percentage, closeTo(0.25, 0.001));
      expect(range.contains(const Duration(seconds: 10)), isTrue);
      expect(range.contains(const Duration(seconds: 3)), isFalse);
      expect(range.contains(const Duration(seconds: 30)), isFalse);
    });

    test('Playback populates sampleRate, channels, and buffered telemetry', () async {
      final file = File('example/assets/music/salida.mp3');
      if (!file.existsSync()) return;

      await player.action.open(
        file.path,
        bufferAhead: const Duration(seconds: 15),
        bufferBehind: const Duration(seconds: 5),
      );

      expect(player.sampleRate, greaterThan(0));
      expect(player.channels, greaterThan(0));
      expect(player.state.trackMetadata, isNotNull);
      expect(player.state.trackMetadata!.codec, equals(AudioCodec.mp3));
      expect(player.state.trackMetadata!.sampleRate, greaterThan(0));
      expect(player.state.trackMetadata!.channels, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final range = player.state.bufferedRange;
      expect(range, isNotNull);
      expect(player.state.bufferedPercentage, greaterThanOrEqualTo(0.0));

      await player.action.stop();
    });
  });
}
