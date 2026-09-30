import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  String? skipIfMissing(String path) {
    final file = resolveAsset(path);
    return file.existsSync() ? null : 'Asset $path not found';
  }

  group('Native Codecs, Pitch/Speed & Buffer Configuration', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      await player.dispose();
    });

    test(
      'miniAudioPlayerSupportedExtensions exposes strictly native formats',
      () {
        expect(miniAudioPlayerSupportedExtensions, contains('mp3'));
        expect(miniAudioPlayerSupportedExtensions, contains('wav'));
        expect(miniAudioPlayerSupportedExtensions, contains('flac'));
        expect(miniAudioPlayerSupportedExtensions, contains('ogg'));
        expect(miniAudioPlayerSupportedExtensions, contains('opus'));
        expect(miniAudioPlayerSupportedExtensions, contains('aif'));
        expect(miniAudioPlayerSupportedExtensions, contains('aiff'));
        expect(miniAudioPlayerSupportedExtensions, contains('aifc'));
        expect(miniAudioPlayerSupportedExtensions, contains('w64'));
        expect(miniAudioPlayerSupportedExtensions, contains('rf64'));
        expect(miniAudioPlayerSupportedExtensions, contains('bwf'));
        expect(miniAudioPlayerSupportedExtensions, contains('rifx'));
        expect(miniAudioPlayerSupportedExtensions, contains('mp2'));
        expect(miniAudioPlayerSupportedExtensions, contains('mp1'));
        expect(miniAudioPlayerSupportedExtensions, contains('oga'));
        expect(miniAudioPlayerSupportedExtensions, isNot(contains('m4a')));
        expect(miniAudioPlayerSupportedExtensions, isNot(contains('aac')));
      },
    );

    test(
      'plays unmodified OPUS files seamlessly via native libopus',
      () async {
        final opusFiles = [
          resolveAsset('example/assets/music/salida.opus'),
        ];

        for (final file in opusFiles) {
          if (!file.existsSync()) continue;

          await player.action.open(file.absolute.path);
          expect(
            player.state.duration.inSeconds,
            greaterThan(0),
            reason: '${file.path} should have duration > 0',
          );

          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(player.state.playing, isTrue);

          await player.action.stop();
          expect(player.state.playing, isFalse);
        }
      },
      skip: skipIfMissing('example/assets/music/salida.opus'),
    );

    test(
      'plays unmodified OGG file seamlessly with accurate duration and seeking',
      () async {
        final oggFile = resolveAsset('example/assets/music/salida.ogg');

        await player.action.open(oggFile.absolute.path);
        final duration = player.state.duration;
        expect(
          duration.inSeconds,
          greaterThan(0),
          reason:
              'OGG duration should be greater than 0, but was ${duration.inMilliseconds} ms',
        );
        expect(duration.inSeconds, inInclusiveRange(65, 75));

        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(player.state.playing, isTrue);
        expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));

        // Test seeking
        await player.action.seek(const Duration(seconds: 30));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(player.state.position.inSeconds, inInclusiveRange(29, 32));

        await player.action.stop();
        expect(player.state.playing, isFalse);
      },
      skip: skipIfMissing('example/assets/music/salida.ogg'),
    );

    test(
      'plays unmodified MP3 file seamlessly via native dr_mp3',
      () async {
        final mp3File = resolveAsset('example/assets/music/salida.mp3');

        await player.action.open(mp3File.absolute.path);
        expect(
          player.state.duration.inSeconds,
          greaterThan(0),
          reason: 'MP3 duration should be greater than 0',
        );

        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(player.state.playing, isTrue);

        await player.action.stop();
        expect(player.state.playing, isFalse);
      },
      skip: skipIfMissing('example/assets/music/salida.mp3'),
    );

    test(
      'plays unmodified FLAC file seamlessly via native dr_flac',
      () async {
        final flacFile = resolveAsset('example/assets/music/salida.flac');

        await player.action.open(flacFile.absolute.path);
        expect(
          player.state.duration.inSeconds,
          greaterThan(0),
          reason: 'FLAC duration should be greater than 0',
        );

        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(player.state.playing, isTrue);

        await player.action.stop();
        expect(player.state.playing, isFalse);
      },
      skip: skipIfMissing('example/assets/music/salida.flac'),
    );

    test(
      'plays unmodified WAV files seamlessly via native dr_wav',
      () async {
        final wavFiles = [
          resolveAsset('example/assets/music/salida.wav'),
        ];

        for (final file in wavFiles) {
          if (!file.existsSync()) continue;

          await player.action.open(file.absolute.path);
          expect(
            player.state.duration.inSeconds,
            greaterThan(0),
            reason: '${file.path} should have duration > 0',
          );

          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(player.state.playing, isTrue);

          await player.action.stop();
          expect(player.state.playing, isFalse);
        }
      },
      skip: skipIfMissing('example/assets/music/salida.wav'),
    );

    test(
      'plays unmodified AIFF files (.aif, .aiff, .aifc) seamlessly via native dr_wav',
      () async {
        final aiffFiles = [
          resolveAsset('example/assets/music/salida.aif'),
          resolveAsset('example/assets/music/salida.aiff'),
          resolveAsset('example/assets/music/salida.aifc'),
        ];

        for (final file in aiffFiles) {
          if (!file.existsSync()) continue;

          await player.action.open(file.absolute.path);
          final duration = player.state.duration;
          expect(
            duration.inSeconds,
            greaterThan(0),
            reason: '${file.path} should have duration > 0',
          );
          expect(duration.inSeconds, inInclusiveRange(65, 75));

          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(player.state.playing, isTrue);

          // Test seeking
          await player.action.seek(const Duration(seconds: 15));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(player.state.position.inSeconds, inInclusiveRange(14, 17));

          await player.action.stop();
          expect(player.state.playing, isFalse);
        }
      },
      skip: skipIfMissing('example/assets/music/salida.aif') ??
          skipIfMissing('example/assets/music/salida.aiff') ??
          skipIfMissing('example/assets/music/salida.aifc'),
    );

    test(
      'plays unmodified Broadcast Wave, 64-bit WAV, and RIFX formats (.bwf, .rf64, .w64, .rifx) seamlessly via native dr_wav',
      () async {
        final wav64Files = [
          resolveAsset('example/assets/music/salida.bwf'),
          resolveAsset('example/assets/music/salida.rf64'),
          resolveAsset('example/assets/music/salida.w64'),
          resolveAsset('example/assets/music/salida.rifx'),
        ];

        for (final file in wav64Files) {
          if (!file.existsSync()) continue;

          await player.action.open(file.absolute.path);
          final duration = player.state.duration;
          expect(
            duration.inSeconds,
            greaterThan(0),
            reason: '${file.path} should have duration > 0',
          );
          expect(duration.inSeconds, inInclusiveRange(65, 75));

          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(player.state.playing, isTrue);

          // Test seeking
          await player.action.seek(const Duration(seconds: 20));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(player.state.position.inSeconds, inInclusiveRange(19, 22));

          await player.action.stop();
          expect(player.state.playing, isFalse);
        }
      },
      skip: skipIfMissing('example/assets/music/salida.bwf') ??
          skipIfMissing('example/assets/music/salida.rf64') ??
          skipIfMissing('example/assets/music/salida.w64') ??
          skipIfMissing('example/assets/music/salida.rifx'),
    );

    test(
      'plays unmodified MP2, MP1, and OGA files (.mp2, .mp1, .oga) seamlessly via native decoders',
      () async {
        final mpegOggFiles = [
          resolveAsset('example/assets/music/salida.mp2'),
          resolveAsset('example/assets/music/salida.oga'),
          resolveAsset('example/assets/music/salida.mp1'),
        ];

        for (final file in mpegOggFiles) {
          if (!file.existsSync()) continue;

          await player.action.open(file.absolute.path);
          final duration = player.state.duration;
          expect(
            duration.inSeconds,
            greaterThan(0),
            reason: '${file.path} should have duration > 0',
          );
          expect(duration.inSeconds, inInclusiveRange(65, 75));

          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(player.state.playing, isTrue);

          // Test seeking
          await player.action.seek(const Duration(seconds: 20));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(player.state.position.inSeconds, inInclusiveRange(19, 22));

          await player.action.stop();
          expect(player.state.playing, isFalse);
        }
      },
      skip: skipIfMissing('example/assets/music/salida.mp2') ??
          skipIfMissing('example/assets/music/salida.oga'),
    );

    test(
      'unsupported formats (e.g. M4A, AAC) fail decoding with exception without transcode',
      () async {
        final unsupportedFiles = [
          resolveAsset('example/assets/music/salida_aac.m4a'),
          resolveAsset('example/assets/music/salida.aac'),
        ];

        for (final file in unsupportedFiles) {
          if (!file.existsSync()) continue;

          expect(
            () => player.action.open(file.absolute.path),
            throwsA(isA<MiniaudioPlayerException>()),
          );
        }
      },
      skip: skipIfMissing('example/assets/music/salida_aac.m4a') ??
          skipIfMissing('example/assets/music/salida.aac'),
    );

    test(
      'rate and pitch can be adjusted independently without affecting each other',
      () async {
        final wavFile = resolveAsset('example/assets/music/salida.wav');

        await player.action.open(wavFile.absolute.path);
        await player.action.play();

        // Default state: rate 1.0, pitch 1.0
        expect(player.state.rate, equals(1.0));
        expect(player.state.pitch, equals(1.0));

        // Change rate to 2.0x (speed changes, pitch remains 1.00)
        await player.action.setRate(2.0);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(player.state.rate, equals(2.0));
        expect(player.state.pitch, equals(1.0));

        // Change pitch to 1.5x (pitch changes, rate remains 2.0)
        await player.action.setPitch(1.5);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(player.state.pitch, equals(1.5));
        expect(player.state.rate, equals(2.0));

        // Reset rate back to 1.0 (speed back to normal, pitch stays 1.5)
        await player.action.setRate(1.0);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(player.state.rate, equals(1.0));
        expect(player.state.pitch, equals(1.5));

        await player.action.stop();
      },
      skip: skipIfMissing('example/assets/music/salida.wav'),
    );

    test(
      'MiniaudioPlayer.config allows setting defaultBufferSize globally',
      () {
        final oldDefault = MiniaudioPlayer.config().defaultBufferSize;
        MiniaudioPlayer.config(defaultBufferSize: 1024);
        expect(MiniaudioPlayer.config().defaultBufferSize, equals(1024));

        final newPlayer = MiniaudioPlayer();
        expect(newPlayer.state.bufferSize, equals(1024));
        expect(newPlayer.bufferSize, equals(1024));
        newPlayer.dispose();

        // Restore old default
        MiniaudioPlayer.config(defaultBufferSize: oldDefault);
      },
    );

    test('player.action.setBufferSize updates state and stream', () async {
      final events = <int>[];
      final sub = player.stream.bufferSize.listen(events.add);

      expect(
        player.state.bufferSize,
        equals(MiniaudioPlayer.config().defaultBufferSize),
      );

      await player.action.setBufferSize(2048);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(player.state.bufferSize, equals(2048));
      expect(player.bufferSize, equals(2048));
      expect(events, contains(2048));

      // Test setting buffer size back to 0 (Native Default)
      await player.action.setBufferSize(0);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(player.state.bufferSize, equals(0));
      expect(player.bufferSize, equals(0));
      expect(events, contains(0));

      await sub.cancel();
    });

    test(
      'exposes audioBitrate and bitrate via getters and reactive streams for all formats',
      () async {
        final testFiles = [
          resolveAsset('example/assets/music/salida.mp3'),
          resolveAsset('example/assets/music/salida.ogg'),
          resolveAsset('example/assets/music/salida.flac'),
          resolveAsset('example/assets/music/salida.opus'),
          resolveAsset('example/assets/music/salida.wav'),
          resolveAsset('example/assets/music/salida.aif'),
          resolveAsset('example/assets/music/salida.aiff'),
          resolveAsset('example/assets/music/salida.aifc'),
          resolveAsset('example/assets/music/salida.bwf'),
          resolveAsset('example/assets/music/salida.rf64'),
          resolveAsset('example/assets/music/salida.w64'),
          resolveAsset('example/assets/music/salida.rifx'),
          resolveAsset('example/assets/music/salida.mp2'),
          resolveAsset('example/assets/music/salida.oga'),
        ];

        final streamBitrates = <int>[];
        final sub = player.stream.audioBitrate.listen(streamBitrates.add);

        for (final file in testFiles) {
          if (!file.existsSync()) continue;

          await player.action.open(file.absolute.path);
          await Future<void>.delayed(const Duration(milliseconds: 60));

          // State getter & player direct getter
          final bitrate = player.state.audioBitrate;
          expect(
            bitrate,
            greaterThan(0),
            reason: '${file.path} should report bitrate > 0',
          );
          expect(player.audioBitrate, equals(bitrate));
          expect(player.state.bitrate, equals(bitrate));
          expect(player.bitrate, equals(bitrate));

          // Stream verification
          expect(streamBitrates, contains(bitrate));
        }

        await sub.cancel();
      },
      skip: skipIfMissing('example/assets/music/salida.wav'),
    );

    test(
      'high-definition time stretching maintains stability and audio quality at high speeds',
      () async {
        final file = resolveAsset(
          'example/assets/music/salida.opus',
        );

        await player.action.open(file.absolute.path);
        await player.action.play();

        // Test increasing speed smoothly to 1.5x, 2.0x, 2.5x without errors or degradation
        for (final rate in [1.25, 1.5, 2.0, 2.5]) {
          await player.action.setRate(rate);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(player.state.playing, isTrue);
          expect(player.state.rate, equals(rate));
          expect(player.state.pitch, equals(1.0));
        }

        await player.action.stop();
        expect(player.state.playing, isFalse);
      },
      skip: skipIfMissing('example/assets/music/salida.opus'),
    );

    test('MiniaudioPlayer.config allows setting logLevel globally', () {
      final initialLevel = MiniaudioPlayer.config().logLevel;
      expect(initialLevel, isA<MiniaudioLogLevel>());

      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.debug);
      expect(
        MiniaudioPlayer.config().logLevel,
        equals(MiniaudioLogLevel.debug),
      );

      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.none);
      expect(MiniaudioPlayer.config().logLevel, equals(MiniaudioLogLevel.none));
    });

    test(
      'rapidly changing pitch, rate, volume and seeking does not crash or corrupt audio engine',
      () async {
        final file = resolveAsset('example/assets/music/salida.mp3');

        await player.action.open(file.absolute.path);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final duration = player.state.duration;
        expect(duration.inMilliseconds, greaterThan(0));

        // Simulate rapid user slider interactions (pitch, rate, volume, seek spam)
        for (int i = 0; i < 30; i++) {
          final targetMs = (i * 250) % duration.inMilliseconds;
          final testRate = 0.5 + (i % 15) * 0.1; // 0.5 to 1.9x
          final testPitch = 0.6 + ((i * 3) % 14) * 0.1; // 0.6 to 1.9x
          final testVolume = ((i % 10) + 1) / 10.0; // 0.1 to 1.0

          await Future.wait([
            player.action.seek(Duration(milliseconds: targetMs)),
            player.action.setRate(testRate),
            player.action.setPitch(testPitch),
            player.action.setVolume(testVolume),
          ]);

          // Very brief interval to stress thread contention and buffer resets
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }

        // Assert player is still healthy and responsive
        expect(player.state.playing, isTrue);
        await player.action.pause();
        expect(player.state.playing, isFalse);
        await player.action.play();
        expect(player.state.playing, isTrue);
        await player.action.stop();
        expect(player.state.playing, isFalse);
      },
      skip: skipIfMissing('example/assets/music/salida.mp3'),
    );

    test(
      'high pitch playback (pitch = 2.0) streams smoothly without audio underruns or stalls',
      () async {
        final wavFile = resolveAsset('example/assets/music/salida.wav');

        await player.action.open(wavFile.absolute.path);
        await player.action.setPitch(2.0);
        await player.action.setRate(1.0);
        await player.action.play();

        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(player.state.playing, isTrue);
        // Position must have progressed steadily (at least 200ms in 350ms real time)
        expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(200));

        await player.action.pause();
        expect(player.state.playing, isFalse);
      },
      skip: skipIfMissing('example/assets/music/salida.wav'),
    );

    test('MiniaudioPlayer.getAudioDevices enumerates native audio devices including AudioDevice.auto', () async {
      final devices = await MiniaudioPlayer.getAudioDevices();
      expect(devices, isNotEmpty);
      expect(devices.first, equals(AudioDevice.auto));
      expect(devices.first.isAuto, isTrue);
      expect(devices.first.isDefault, isTrue);

      for (final dev in devices) {
        expect(dev.name, isNotEmpty);
        expect(dev.id, isNotNull);
      }

      final rawDevices = await MiniaudioPlayer.getAudioDevices(
        includeAuto: false,
      );
      expect(rawDevices.any((d) => d.id.isEmpty), isFalse);
      expect(rawDevices.every((d) => !d.isAuto), isTrue);
    });

    test('MiniaudioPlayer.config allows setting and getting defaultAudioDevice globally', () async {
      final oldDevice = MiniaudioPlayer.config().defaultAudioDevice;
      expect(oldDevice, equals(AudioDevice.auto));

      const customDevice = AudioDevice(
        id: 'test_dev_id',
        name: 'Custom USB DAC',
        isDefault: false,
      );
      MiniaudioPlayer.config(defaultAudioDevice: customDevice);
      expect(MiniaudioPlayer.config().defaultAudioDevice, equals(customDevice));

      // Reset to default
      MiniaudioPlayer.config(defaultAudioDevice: AudioDevice.auto);
      expect(
        MiniaudioPlayer.config().defaultAudioDevice,
        equals(AudioDevice.auto),
      );
    });

    test('player.action.setDevice returns Future<bool> and updates audioDevice in state and reactive stream', () async {
      final devices = await MiniaudioPlayer.getAudioDevices();
      expect(devices, isNotEmpty);

      // Verify state has initial device populated
      expect(player.state.audioDevice, isNotNull);
      expect(player.state.audioDevice.name, isNotEmpty);

      // Listen to audioDevice stream
      final events = <AudioDevice>[];
      final sub = player.stream.audioDevice.listen(events.add);

      // Switch to AudioDevice.auto
      final bool autoSuccess = await player.action.setDevice(AudioDevice.auto);
      expect(autoSuccess, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(player.state.audioDevice, isNotNull);
      expect(player.state.audioDevice.isAuto, isTrue);
      expect(player.state.audioDevice.name, isNotEmpty);

      // If hardware devices exist, switch to one
      final hardwareDevices = devices.where((d) => !d.isAuto).toList();
      if (hardwareDevices.isNotEmpty) {
        final target = hardwareDevices.first;
        final bool hwSuccess = await player.setDevice(target);
        expect(hwSuccess, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(player.state.audioDevice.name, isNotEmpty);
        expect(player.state.audioDevice.isAuto, isFalse);
      }

      // Switch to a disconnected / non-existent device: must return false and fall back to default
      const disconnectedDev = AudioDevice(
        id: 'deadbeef0123456789abcdefdeadbeef',
        name: 'Unplugged Headphones',
        isDefault: false,
        isAuto: false,
      );
      final bool dcSuccess = await player.action.setDevice(disconnectedDev);
      expect(dcSuccess, isFalse);
      expect(player.state.audioDevice.isAuto, isTrue);

      // Switch back to AudioDevice.auto
      final bool backSuccess = await player.action.setDevice(AudioDevice.auto);
      expect(backSuccess, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await sub.cancel();
      expect(events, isNotEmpty);
    });

    test(
      'switching audio output device during active playback maintains stable playback without fallback loop',
      () async {
        final oggFile = resolveAsset('example/assets/music/salida.ogg');

        await player.action.open(oggFile.absolute.path);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(player.state.playing, isTrue);

        final devices = await MiniaudioPlayer.getAudioDevices();
        final hardwareDevices = devices.where((d) => !d.isAuto).toList();

        final deviceEvents = <AudioDevice>[];
        final deviceSub = player.stream.audioDevice.listen(deviceEvents.add);

        if (hardwareDevices.isNotEmpty) {
          // Switch to specific hardware device while playing
          await player.action.setDevice(hardwareDevices.first);
          await Future<void>.delayed(const Duration(milliseconds: 300));

          expect(player.state.playing, isTrue);
          expect(player.state.position.inMilliseconds, greaterThan(0));
        }

        // Switch back to auto while playing
        await player.action.setDevice(AudioDevice.auto);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(player.state.playing, isTrue);
        expect(player.state.position.inMilliseconds, greaterThan(0));

        await deviceSub.cancel();
        await player.action.stop();

        // Ensure no excessive/infinite event spam occurred (less than 10 events total for 2 switches)
        expect(deviceEvents.length, lessThanOrEqualTo(10));
      },
      skip: skipIfMissing('example/assets/music/salida.ogg'),
    );
  });
}
