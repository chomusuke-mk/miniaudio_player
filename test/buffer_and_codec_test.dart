import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  group('Misnamed Files and Extensionless URLs Handling', () {
    late MiniaudioPlayer player;
    late Directory tempDir;

    setUp(() async {
      player = MiniaudioPlayer(source: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]);
      tempDir = Directory.systemTemp.createTempSync('miniaudio_codec_test_');
    });

    tearDown(() async {
      await player.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Plays MP3 correctly when file is renamed with wrong extension (.wav)', () async {
      final srcFile = File('test/fixtures/salida.mp3');
      if (!srcFile.existsSync()) return;

      final misnamed = File('${tempDir.path}/track_actually_mp3.wav');
      misnamed.writeAsBytesSync(srcFile.readAsBytesSync());

      await player.action.open([AudioSource(misnamed.path)]);
      expect(player.state.duration?.inMilliseconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('Plays FLAC correctly when file has NO extension at all', () async {
      final srcFile = File('test/fixtures/salida.flac');
      if (!srcFile.existsSync()) return;

      final extensionless = File('${tempDir.path}/audio_stream_payload');
      extensionless.writeAsBytesSync(srcFile.readAsBytesSync());

      await player.action.open([AudioSource(extensionless.path)]);
      expect(player.state.duration?.inMilliseconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('Plays AAC M4A correctly when file has .bin extension', () async {
      final srcFile = File('test/fixtures/salida_aac.m4a');
      if (!srcFile.existsSync()) return;

      final misnamed = File('${tempDir.path}/opaque_blob.bin');
      misnamed.writeAsBytesSync(srcFile.readAsBytesSync());

      await player.action.open([AudioSource(misnamed.path)]);
      expect(player.state.duration?.inMilliseconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });
  });

  group('Second-Based Buffer Configuration and Telemetry', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer(source: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]);
    });

    tearDown(() async {
      await player.dispose();
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
    });

    test('Buffer telemetry properties', () {
      const buffer = Buffer(
        start: Duration(seconds: 5),
        end: Duration(seconds: 25),
        isBuffering: false,
      );

      expect(buffer.start, equals(const Duration(seconds: 5)));
      expect(buffer.end, equals(const Duration(seconds: 25)));
      expect(buffer.isBuffering, isFalse);
    });

    test('Playback populates sampleRate, channels, and buffered telemetry', () async {
      final file = File('test/fixtures/salida.mp3');
      if (!file.existsSync()) return;

      await player.action.open([AudioSource(file.path)]);

      expect(player.state.sampleRate, greaterThan(0));
      expect(player.state.channels, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final buf = player.state.buffer;
      expect(buf, isNotNull);
      expect(buf.end, greaterThanOrEqualTo(Duration.zero));

      await player.action.stop();
    });
  });
}
