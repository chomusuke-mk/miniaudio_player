import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SilenceSkipConfig Data Model', () {
    test('default constructor initializes standard defaults', () {
      const config = SilenceSkipConfig();
      expect(config.mode, equals(SilenceSkipMode.disabled));
      expect(config.thresholdDb, equals(-45.0));
      expect(config.minSilenceDuration, equals(const Duration(milliseconds: 300)));
      expect(config.padding, equals(const Duration(milliseconds: 50)));
    });

    test('named constructors configure appropriate modes', () {
      const trimEdges = SilenceSkipConfig.trimEdges(thresholdDb: -50.0);
      expect(trimEdges.mode, equals(SilenceSkipMode.trimEdges));
      expect(trimEdges.thresholdDb, equals(-50.0));

      const continuous = SilenceSkipConfig.continuous(
        minSilenceDuration: Duration(milliseconds: 250),
      );
      expect(continuous.mode, equals(SilenceSkipMode.continuous));
      expect(continuous.minSilenceDuration, equals(const Duration(milliseconds: 250)));

      const all = SilenceSkipConfig.all(padding: Duration(milliseconds: 40));
      expect(all.mode, equals(SilenceSkipMode.all));
      expect(all.padding, equals(const Duration(milliseconds: 40)));
    });

    test('copyWith creates modified copy correctly', () {
      const original = SilenceSkipConfig();
      final updated = original.copyWith(
        mode: SilenceSkipMode.continuous,
        thresholdDb: -40.0,
      );
      expect(updated.mode, equals(SilenceSkipMode.continuous));
      expect(updated.thresholdDb, equals(-40.0));
      expect(updated.minSilenceDuration, equals(original.minSilenceDuration));
      expect(updated.padding, equals(original.padding));
    });

    test('equality and hashCode work as expected', () {
      const config1 = SilenceSkipConfig.continuous(thresholdDb: -42.0);
      const config2 = SilenceSkipConfig(
        mode: SilenceSkipMode.continuous,
        thresholdDb: -42.0,
      );
      const config3 = SilenceSkipConfig.trimEdges();

      expect(config1, equals(config2));
      expect(config1.hashCode, equals(config2.hashCode));
      expect(config1, isNot(equals(config3)));
    });

    test('toString includes all parameters', () {
      const config = SilenceSkipConfig.continuous(thresholdDb: -48.0);
      expect(config.toString(), contains('continuous'));
      expect(config.toString(), contains('-48.0dB'));
    });
  });

  group('Skip Silence Playback & DSP Control', () {
    late MiniaudioPlayer player;
    File? testAudioFile;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      await player.dispose();
      await SyntheticAudioGenerator.cleanUp(testAudioFile);
      testAudioFile = null;
    });

    test('initial state has silence skipping disabled and 0 saved duration', () {
      expect(player.state.skipSilence, isFalse);
      expect(player.state.isSkipSilenceEnabled, isFalse);
      expect(player.state.silenceSkipMode, equals(SilenceSkipMode.disabled));
      expect(player.state.silenceConfig.mode, equals(SilenceSkipMode.disabled));
      expect(player.state.silenceSavedDuration, equals(Duration.zero));
    });

    test('setSkipSilence enables and disables silence skipping with reactive streams', () async {
      final skipEvents = <bool>[];
      final sub = player.stream.skipSilence.listen(skipEvents.add);

      await player.action.setSkipSilence(true);
      expect(player.state.skipSilence, isTrue);
      expect(player.state.silenceSkipMode, equals(SilenceSkipMode.continuous));

      await player.action.setSkipSilence(false);
      expect(player.state.skipSilence, isFalse);
      expect(player.state.silenceSkipMode, equals(SilenceSkipMode.disabled));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(skipEvents, equals([true, false]));
    });

    test('setSilenceConfig applies customized thresholds and emits config stream', () async {
      final configEvents = <SilenceSkipConfig>[];
      final sub = player.stream.silenceConfig.listen(configEvents.add);

      const targetConfig = SilenceSkipConfig(
        mode: SilenceSkipMode.trimEdges,
        thresholdDb: -52.0,
        minSilenceDuration: Duration(milliseconds: 400),
        padding: Duration(milliseconds: 60),
      );

      await player.action.setSilenceConfig(targetConfig);

      expect(player.state.silenceSkipMode, equals(SilenceSkipMode.trimEdges));
      expect(player.state.silenceConfig.thresholdDb, equals(-52.0));
      expect(
        player.state.silenceConfig.minSilenceDuration,
        equals(const Duration(milliseconds: 400)),
      );
      expect(
        player.state.silenceConfig.padding,
        equals(const Duration(milliseconds: 60)),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(configEvents, contains(targetConfig));
    });

    test('configureSilenceSkip updates individual fields selectively', () async {
      await player.action.setSilenceConfig(const SilenceSkipConfig.all());
      expect(player.state.silenceSkipMode, equals(SilenceSkipMode.all));

      await player.action.configureSilenceSkip(thresholdDb: -38.0);
      expect(player.state.silenceSkipMode, equals(SilenceSkipMode.all));
      expect(player.state.silenceConfig.thresholdDb, equals(-38.0));
      expect(
        player.state.silenceConfig.minSilenceDuration,
        equals(const Duration(milliseconds: 300)),
      );
    });

    test('trimEdges trims lead-in silence immediately on playback start', () async {
      // 0.8s silence at start, followed by 0.5s audible 440Hz tone
      testAudioFile = await SyntheticAudioGenerator.createTempMultiSegmentWavFile(
        fileName: 'lead_in_test.wav',
        segments: [
          (durationSeconds: 0.8, frequencyHz: 0.0, amplitude: 0.0),
          (durationSeconds: 0.5, frequencyHz: 440.0, amplitude: 0.8),
        ],
      );

      await player.action.setSilenceConfig(
        const SilenceSkipConfig.trimEdges(
          thresholdDb: -45.0,
        ),
      );

      await player.action.open(testAudioFile!.path);
      await player.action.play();

      // Give engine a brief moment to decode initial audio
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final saved = player.state.silenceSavedDuration;
      // Lead-in silence of 0.8s (800ms) should be saved
      expect(saved.inMilliseconds, greaterThanOrEqualTo(500));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('continuous mode skips in-between pauses', () async {
      // 0.4s tone + 0.8s silence pause + 0.4s tone
      testAudioFile = await SyntheticAudioGenerator.createTempMultiSegmentWavFile(
        fileName: 'pause_test.wav',
        segments: [
          (durationSeconds: 0.4, frequencyHz: 440.0, amplitude: 0.8),
          (durationSeconds: 0.8, frequencyHz: 0.0, amplitude: 0.0),
          (durationSeconds: 0.4, frequencyHz: 440.0, amplitude: 0.8),
        ],
      );

      await player.action.setSilenceConfig(
        const SilenceSkipConfig.continuous(
          thresholdDb: -45.0,
          minSilenceDuration: Duration(milliseconds: 200),
          padding: Duration(milliseconds: 50),
        ),
      );

      await player.action.open(testAudioFile!.path);
      await player.action.play();

      // Wait until playback reaches and skips the silence pause
      for (int i = 0; i < 25; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        player.pollAndEmit(force: true);
        if (player.state.silenceSavedDuration.inMilliseconds >= 400) break;
      }

      final saved = player.state.silenceSavedDuration;
      // The 800ms silence in the middle should be truncated down to padding
      expect(saved.inMilliseconds, greaterThanOrEqualTo(400));

      await player.action.stop();
    });

    test('disabled mode does not skip silence pauses', () async {
      // 0.4s tone + 0.8s silence pause + 0.4s tone
      testAudioFile = await SyntheticAudioGenerator.createTempMultiSegmentWavFile(
        fileName: 'no_skip_test.wav',
        segments: [
          (durationSeconds: 0.4, frequencyHz: 440.0, amplitude: 0.8),
          (durationSeconds: 0.8, frequencyHz: 0.0, amplitude: 0.0),
          (durationSeconds: 0.4, frequencyHz: 440.0, amplitude: 0.8),
        ],
      );

      await player.action.setSkipSilence(false);

      await player.action.open(testAudioFile!.path);
      await player.action.play();

      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(player.state.silenceSavedDuration, equals(Duration.zero));

      await player.action.stop();
    });

    test('dynamic toggling of skipSilence mid-playback engages without crashing', () async {
      testAudioFile = await SyntheticAudioGenerator.createTempMultiSegmentWavFile(
        fileName: 'dynamic_toggle_test.wav',
        segments: [
          (durationSeconds: 0.5, frequencyHz: 440.0, amplitude: 0.8),
          (durationSeconds: 0.8, frequencyHz: 0.0, amplitude: 0.0),
          (durationSeconds: 0.5, frequencyHz: 880.0, amplitude: 0.8),
        ],
      );

      await player.action.open(testAudioFile!.path);
      await player.action.play();

      // Toggle silence skip ON while playing
      await player.action.setSkipSilence(true);
      expect(player.state.skipSilence, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Toggle silence skip OFF while playing
      await player.action.setSkipSilence(false);
      expect(player.state.skipSilence, isFalse);

      await player.action.stop();
    });

    test('seeking resets silence detector and preserves engine stability', () async {
      testAudioFile = await SyntheticAudioGenerator.createTempMultiSegmentWavFile(
        fileName: 'seek_silence_test.wav',
        segments: [
          (durationSeconds: 0.5, frequencyHz: 440.0, amplitude: 0.8),
          (durationSeconds: 0.8, frequencyHz: 0.0, amplitude: 0.0),
          (durationSeconds: 0.5, frequencyHz: 880.0, amplitude: 0.8),
        ],
      );

      await player.action.setSilenceConfig(const SilenceSkipConfig.all());
      await player.action.open(testAudioFile!.path);
      await player.action.play();

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Seek back to beginning
      await player.action.seek(Duration.zero);
      expect(player.state.playing, isTrue);

      // Seek to middle
      await player.action.seek(const Duration(milliseconds: 600));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });
  });
}
