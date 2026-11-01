import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:miniaudio_player/miniaudio_player.dart';

import '../helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File trackA;
  late File trackB;

  setUpAll(() async {
    trackA = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'phase4_track_a.wav',
      frequencyHz: 440.0,
      durationSeconds: 2.0,
    );
    trackB = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'phase4_track_b.wav',
      frequencyHz: 880.0,
      durationSeconds: 2.0,
    );
  });

  tearDownAll(() async {
    await Future.wait([
      SyntheticAudioGenerator.cleanUp(trackA),
      SyntheticAudioGenerator.cleanUp(trackB),
    ]);
  });

  group('Phase 4: Sinks Desacoplados, Grabación & Pre-escucha Cue', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>();
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        if (engine.state.isRecording) {
          try {
            await engine.action.stopRecording();
          } catch (_) {}
        }
        await engine.dispose();
      }
    });

    test('AudioDevice capture device enumeration returns valid devices', () async {
      final captureDevicesAsync = await AudioDevice.getCaptureDevices();
      expect(captureDevicesAsync, isNotEmpty);
      expect(captureDevicesAsync.any((d) => d.isAuto), isTrue);

      final captureDevicesSync = AudioDevice.getCaptureDevicesSync();
      expect(captureDevicesSync, isNotEmpty);
      expect(captureDevicesSync.any((d) => d.isAuto), isTrue);
    });

    test('Live recording to 16-bit PCM WAV captures audio with valid RIFF headers', () async {
      final tempDir = await Directory.systemTemp.createTemp('map_rec_test_');
      final recordFile = File('${tempDir.path}/live_rec.wav');

      try {
        await engine.action.openQueue([
          EngineItem.from(trackA.path, data: 'Track A'),
        ]);

        expect(engine.state.isRecording, isFalse);

        await engine.action.startRecording(
          recordFile.path,
          format: WavFormat.pcm16,
        );

        expect(engine.state.isRecording, isTrue);
        expect(engine.action.isRecording(), isTrue);

        await engine.action.play();
        // Allow audio callback to feed audio frames into the ring buffer
        await Future.delayed(const Duration(milliseconds: 300));

        final bytesWritten = await engine.action.stopRecording();
        expect(engine.state.isRecording, isFalse);
        expect(bytesWritten, greaterThan(0));

        expect(recordFile.existsSync(), isTrue);
        final fileBytes = await recordFile.readAsBytes();
        expect(fileBytes.length, greaterThanOrEqualTo(44));

        // Validate RIFF header
        final riffTag = String.fromCharCodes(fileBytes.sublist(0, 4));
        final waveTag = String.fromCharCodes(fileBytes.sublist(8, 12));
        final fmtTag = String.fromCharCodes(fileBytes.sublist(12, 16));
        final dataTag = String.fromCharCodes(fileBytes.sublist(36, 40));

        expect(riffTag, equals('RIFF'));
        expect(waveTag, equals('WAVE'));
        expect(fmtTag, equals('fmt '));
        expect(dataTag, equals('data'));

        // Format code 1 = PCM integer
        final byteData = ByteData.sublistView(fileBytes);
        final formatCode = byteData.getUint16(20, Endian.little);
        expect(formatCode, equals(1)); // PCM16
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('Offline bounce exports entire mix to 32-bit float WAV without playback delay', () async {
      final tempDir = await Directory.systemTemp.createTemp('map_bounce_test_');
      final bounceFile = File('${tempDir.path}/offline_bounce.wav');

      try {
        await engine.action.openQueue([
          EngineItem.from(trackA.path, data: 'Track A'),
          EngineItem.from(trackB.path, data: 'Track B'),
        ]);

        final bytesWritten = await engine.action.offlineBounce(
          bounceFile.path,
          format: WavFormat.float32,
          duration: const Duration(milliseconds: 500),
        );

        expect(bytesWritten, greaterThan(0));
        expect(bounceFile.existsSync(), isTrue);

        final fileBytes = await bounceFile.readAsBytes();
        expect(fileBytes.length, greaterThanOrEqualTo(44));

        // Validate RIFF header
        final riffTag = String.fromCharCodes(fileBytes.sublist(0, 4));
        final waveTag = String.fromCharCodes(fileBytes.sublist(8, 12));
        expect(riffTag, equals('RIFF'));
        expect(waveTag, equals('WAVE'));

        // Format code 3 = IEEE Float
        final byteData = ByteData.sublistView(fileBytes);
        final formatCode = byteData.getUint16(20, Endian.little);
        expect(formatCode, equals(3)); // Float32
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('Microphone capture and auto-ducking configuration reacts to state and streams', () async {
      expect(engine.state.isMicrophoneEnabled, isFalse);

      final micStates = <bool>[];
      final duckingConfigs = <DuckingConfig>[];
      final micVolumes = <double>[];

      final sub1 = engine.stream.isMicrophoneEnabled.listen(micStates.add);
      final sub2 = engine.stream.duckingConfig.listen(duckingConfigs.add);
      final sub3 = engine.stream.micVolume.listen(micVolumes.add);

      // Enable microphone with custom ducking parameters
      await engine.action.enableMicrophone(
        autoDucking: true,
        duckingDb: -18.0,
        thresholdDb: -32.0,
      );

      expect(engine.state.isMicrophoneEnabled, isTrue);
      expect(engine.state.duckingConfig.enabled, isTrue);
      expect(engine.state.duckingConfig.duckingDb, equals(-18.0));
      expect(engine.state.duckingConfig.thresholdDb, equals(-32.0));

      // Adjust microphone volume
      await engine.action.setMicVolume(0.85);
      expect(engine.state.micVolume, closeTo(0.85, 0.001));

      // Disable microphone
      await engine.action.disableMicrophone();
      expect(engine.state.isMicrophoneEnabled, isFalse);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(micStates, containsAllInOrder([true, false]));
      expect(duckingConfigs, isNotEmpty);
      expect(micVolumes, contains(closeTo(0.85, 0.001)));

      await Future.wait([sub1.cancel(), sub2.cancel(), sub3.cancel()]);
    });

    test('DJ Cue headphone pre-listening device configuration and volume control', () async {
      expect(engine.state.cueConfig.enabled, isFalse);

      final cueConfigs = <CueConfig>[];
      final sub = engine.stream.cueConfig.listen(cueConfigs.add);

      // Configure Cue output for Deck B pre-listening
      await engine.action.configureCueOutput(
        volume: 0.9,
        mode: CueMode.deckB,
      );

      expect(engine.state.cueConfig.enabled, isTrue);
      expect(engine.state.cueConfig.volume, equals(0.9));
      expect(engine.state.cueConfig.mode, equals(CueMode.deckB));

      // Switch Cue source to Master mix
      await engine.action.setCueMode(CueMode.master);
      expect(engine.state.cueConfig.mode, equals(CueMode.master));

      // Adjust Cue headphone volume
      await engine.action.setCueVolume(0.65);
      expect(engine.state.cueConfig.volume, equals(0.65));

      // Disable Cue output
      await engine.action.disableCueOutput();
      expect(engine.state.cueConfig.enabled, isFalse);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(cueConfigs.length, greaterThanOrEqualTo(4));
      expect(cueConfigs.last.enabled, isFalse);

      await sub.cancel();
    });

    test('Unified configureOutputs configures master, cue, and recording in one call', () async {
      final tempDir = await Directory.systemTemp.createTemp('map_multi_out_test_');
      final recFile = File('${tempDir.path}/multi_out.wav');

      try {
        await engine.action.configureOutputs(
          masterDevice: AudioDevice.auto,
          cueDevice: AudioDevice.auto,
          recordPath: recFile.path,
          format: WavFormat.pcm16,
        );

        expect(engine.state.cueConfig.enabled, isTrue);
        expect(engine.state.isRecording, isTrue);

        await engine.action.stopRecording();
        expect(engine.state.isRecording, isFalse);
        expect(recFile.existsSync(), isTrue);
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
