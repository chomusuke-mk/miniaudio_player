import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File trackA;

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
    trackA = File('test/fixtures/test_24bit.wav');
  });

  group('Phase 4: Sinks Desacoplados, Grabación & Pre-escucha Cue', () {
    late MiniaudioPlayer<String> engine;

    setUp(() {
      engine = MiniaudioPlayer<String>();
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

    test('globalInputDevices capture device enumeration returns valid devices',
        () async {
      final captureDevices = engine.state.globalInputDevices;
      expect(captureDevices, isNotEmpty);
      expect(captureDevices.any((d) => d.isAuto), isTrue);
    });

    test(
        'Live recording to 16-bit PCM WAV captures audio with valid RIFF headers',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('map_rec_test_');
      final recordFile = File('${tempDir.path}/live_rec.wav');

      try {
        await engine.action.setQueue([
          AudioSource(trackA.path, data: 'Track A'),
        ]);

        expect(engine.state.isRecording, isFalse);

        await engine.action.startRecording(
          recordFile.path,
          format: AudioFileFormat.wav,
        );

        expect(engine.state.isRecording, isTrue);

        await engine.action.play();
        await Future.delayed(const Duration(milliseconds: 300));

        final result = await engine.action.stopRecording();
        expect(engine.state.isRecording, isFalse);
        expect(result.bytesWritten, greaterThan(0));
        expect(result.duration.inMilliseconds, greaterThan(0));

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

    test(
        'Microphone capture and auto-ducking configuration reacts to state and streams',
        () async {
      expect(engine.state.inputs.isNotEmpty, isFalse);

      final duckingStates = <bool>[];
      final rmsLevels = <double>[];

      final sub1 = engine.stream.isDuckingActive.listen(duckingStates.add);
      final sub2 = engine.stream.micRmsLevel.listen(rmsLevels.add);

      final micInput = AudioInput(
        config: const AudioInputConfig(
          ducking: DuckingConfig(
            enabled: true,
            duckingDb: -18.0,
            thresholdDb: -32.0,
          ),
          volume: 0.85,
          monitorDirect: false,
        ),
      );

      // Add input with custom ducking parameters
      await engine.action.addInput(micInput);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.state.inputs.isNotEmpty, isTrue);
      expect(engine.state.inputs.first.config.volume, closeTo(0.85, 0.001));

      // Remove input
      await engine.action.removeInput(micInput);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.state.inputs.isEmpty, isTrue);

      await Future.delayed(const Duration(milliseconds: 50));
      await Future.wait([sub1.cancel(), sub2.cancel()]);
    });

    test('AudioInput direct instantiation, routing and state updates',
        () async {
      expect(engine.state.inputs, isEmpty);

      final micInput = AudioInput(
        config: const AudioInputConfig(
          volume: 0.75,
          ducking: DuckingConfig(enabled: true, duckingDb: -12.0),
          monitorDirect: false,
        ),
      );

      await engine.action.addInput(micInput);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.state.inputs, contains(micInput));
      expect(engine.state.inputs.first.config.volume, closeTo(0.75, 0.001));

      // Re-adding the same input device must throw StateError
      expect(() => engine.action.addInput(micInput), throwsStateError);

      // Modulate parameters with configureInput
      await engine.action.configureInput(
        const AudioInputConfig(volume: 0.9),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.state.inputs.first.config.volume, closeTo(0.9, 0.001));

      await engine.action.removeInput(micInput);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.state.inputs, isEmpty);

      await engine.action.setInputs({micInput});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.state.inputs, contains(micInput));

      await engine.action.setInputs({});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.state.inputs, isEmpty);
    });

    test('Selective AudioOutputSource configuration and output routing',
        () async {
      const headphoneOutput = AudioOutput(
        deviceId: 'headphone_device',
        source: AudioOutputSource.standbyTrack,
      );

      // Add output for standby track pre-listening
      await engine.action.addOutput(headphoneOutput);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(
        engine.state.outputs.any(
          (o) =>
              o.source == AudioOutputSource.standbyTrack &&
              o.deviceId == 'headphone_device',
        ),
        isTrue,
      );

      // Remove output
      await engine.action.removeOutput(headphoneOutput);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(
        engine.state.outputs.any(
          (o) =>
              o.source == AudioOutputSource.standbyTrack &&
              o.deviceId == 'headphone_device',
        ),
        isFalse,
      );
    });

    test(
        'Unified setOutputs configures audio outputs, while selective startRecording handles disk recording',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('map_multi_out_test_');
      final recFile = File('${tempDir.path}/multi_out.wav');

      try {
        await engine.action.setOutputs({
          const AudioOutput(),
          const AudioOutput(
              deviceId: 'headphone_dev',
              source: AudioOutputSource.standbyTrack),
        });
        await Future.delayed(const Duration(milliseconds: 50));

        expect(engine.state.outputs.length, equals(2));
        expect(
          engine.state.outputs.any((o) => o.source == AudioOutputSource.all),
          isTrue,
        );
        expect(
          engine.state.outputs
              .any((o) => o.source == AudioOutputSource.standbyTrack),
          isTrue,
        );

        await engine.action.startRecording(
          recFile.path,
          format: AudioFileFormat.wav,
          source: AudioOutputSource.musicMix,
        );
        expect(engine.state.isRecording, isTrue);
        expect(
            engine.state.recordingSource, equals(AudioOutputSource.musicMix));

        final recResult = await engine.action.stopRecording();
        expect(engine.state.isRecording, isFalse);
        expect(engine.state.recordingSource, isNull);
        expect(recResult.path, equals(recFile.path));
        expect(recFile.existsSync(), isTrue);
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('Zero hardware outputs (outputs: {}) runs in pure recording mode',
        () async {
      final recEngine = MiniaudioPlayer<String>(outputs: const {});
      await Future.delayed(const Duration(milliseconds: 50));
      expect(recEngine.state.outputs, isEmpty);

      final tempDir =
          await Directory.systemTemp.createTemp('map_rec_only_test_');
      final recFile = File('${tempDir.path}/rec_only.wav');
      try {
        await recEngine.action.startRecording(
          recFile.path,
          source: AudioOutputSource.all,
        );
        expect(recEngine.state.isRecording, isTrue);
        expect(recEngine.state.recordingSource, equals(AudioOutputSource.all));

        final result = await recEngine.action.stopRecording();
        expect(recEngine.state.isRecording, isFalse);
        expect(recEngine.state.recordingSource, isNull);
        expect(result.path, equals(recFile.path));
        expect(recFile.existsSync(), isTrue);
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
        await recEngine.dispose();
      }
    });
  });
}
