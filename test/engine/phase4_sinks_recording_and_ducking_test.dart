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

    test('globalInputDevices capture device enumeration returns valid devices', () async {
      final captureDevices = engine.state.globalInputDevices;
      expect(captureDevices, isNotEmpty);
      expect(captureDevices.any((d) => d.isAuto), isTrue);
    });

    test('Live recording to 16-bit PCM WAV captures audio with valid RIFF headers', () async {
      final tempDir = await Directory.systemTemp.createTemp('map_rec_test_');
      final recordFile = File('${tempDir.path}/live_rec.wav');

      try {
        await engine.action.open([
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

    test('Microphone capture and auto-ducking configuration reacts to state and streams', () async {
      expect(engine.state.isMicrophoneEnabled, isFalse);

      final duckingStates = <bool>[];
      final rmsLevels = <double>[];

      final sub1 = engine.stream.isDuckingActive.listen(duckingStates.add);
      final sub2 = engine.stream.micRmsLevel.listen(rmsLevels.add);

      // Enable microphone with custom ducking parameters
      await engine.action.enableMicrophone(
        ducking: const DuckingConfig(
          enabled: true,
          duckingDb: -18.0,
          thresholdDb: -32.0,
        ),
        volume: 0.85,
        monitorDirect: false,
      );

      expect(engine.state.isMicrophoneEnabled, isTrue);
      expect(engine.state.micVolume, closeTo(0.85, 0.001));

      // Disable microphone
      await engine.action.disableMicrophone();
      expect(engine.state.isMicrophoneEnabled, isFalse);

      await Future.delayed(const Duration(milliseconds: 50));
      await Future.wait([sub1.cancel(), sub2.cancel()]);
    });

    test('DJ Cue headphone pre-listening device configuration and volume control', () async {
      expect(engine.state.cueVolume, equals(1.0));

      // Configure Cue output for Deck B pre-listening via matrix
      await engine.action.addOutput(
        const AudioOutput.cue(
          'cue_headphone_device',
          source: CueSource.standbyTrack,
        ),
      );

      expect(engine.state.outputs.any((o) => o is CueAudioOutput), isTrue);

      // Adjust Cue headphone volume
      await engine.action.setCueVolume(0.65);
      expect(engine.state.cueVolume, closeTo(0.65, 0.001));

      // Switch Cue source
      await engine.action.setCueSource(CueSource.masterMix);
      expect(engine.state.cueSource, equals(CueSource.masterMix));

      // Remove Cue output
      await engine.action.removeOutput(
        const AudioOutput.cue(
          'cue_headphone_device',
          source: CueSource.standbyTrack,
        ),
      );
      expect(engine.state.outputs.any((o) => o is CueAudioOutput), isFalse);
    });

    test('Unified configureOutputs configures master, cue, and recording in one call', () async {
      final tempDir = await Directory.systemTemp.createTemp('map_multi_out_test_');
      final recFile = File('${tempDir.path}/multi_out.wav');

      try {
        await engine.action.configureOutputs([
          const AudioOutput.speaker(),
          const AudioOutput.cue('', source: CueSource.standbyTrack),
          AudioOutput.file(recFile.path, format: AudioFileFormat.wav),
        ]);

        expect(engine.state.outputs.length, equals(3));
        expect(engine.state.outputs.any((o) => o is CueAudioOutput), isTrue);
        expect(engine.state.outputs.any((o) => o is FileAudioOutput), isTrue);
        expect(engine.state.isRecording, isTrue);

        final recResult = await engine.action.stopRecording();
        expect(engine.state.isRecording, isFalse);
        expect(recResult.path, equals(recFile.path));
        expect(recFile.existsSync(), isTrue);
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
