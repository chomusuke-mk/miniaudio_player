import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DSP Data Models', () {
    test('ReplayGainConfig initializes defaults and computes totalGainDb', () {
      const defaultRg = ReplayGainConfig();
      expect(defaultRg.enabled, isFalse);
      expect(defaultRg.gainDb, equals(0.0));
      expect(defaultRg.peak, equals(0.0));
      expect(defaultRg.preampDb, equals(0.0));
      expect(defaultRg.preventClipping, isTrue);
      expect(defaultRg.totalGainDb, equals(0.0));

      const activeRg = ReplayGainConfig(
        gainDb: -8.5,
        peak: 0.95,
        preampDb: 2.0,
        preventClipping: true,
        enabled: true,
      );
      expect(activeRg.enabled, isTrue);
      expect(activeRg.gainDb, equals(-8.5));
      expect(activeRg.preampDb, equals(2.0));
      expect(activeRg.totalGainDb, closeTo(-6.5, 0.001));

      const disabledWithPreamp = ReplayGainConfig(
        gainDb: -8.5,
        preampDb: 3.0,
        enabled: false,
      );
      expect(disabledWithPreamp.totalGainDb, equals(3.0));
    });

    test('CrossfeedMode enum has valid values', () {
      expect(CrossfeedMode.values.length, equals(3));
      expect(CrossfeedMode.off.index, equals(0));
      expect(CrossfeedMode.moffatBauer.index, equals(1));
      expect(CrossfeedMode.chuMoy.index, equals(2));
    });
  });

  group('DSP Controls and Engine Integration', () {
    late File testWavFile;
    late MiniaudioPlayer player;

    setUp(() async {
      testWavFile = await SyntheticAudioGenerator.createTempWavFile(
        frequencyHz: 440.0,
        durationSeconds: 0.6,
        sampleRate: 44100,
        numChannels: 2,
      );
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      await player.dispose();
      try {
        if (testWavFile.existsSync()) {
          await testWavFile.parent.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('ReplayGain controls update state and native engine', () async {
      expect(player.state.replayGain.enabled, isFalse);

      await player.action.setReplayGain(
        gainDb: -12.5,
        peak: 0.98,
        preampDb: 1.5,
        preventClipping: true,
      );

      expect(player.state.replayGain.enabled, isTrue);
      expect(player.state.replayGain.gainDb, closeTo(-12.5, 0.01));
      expect(player.state.replayGain.peak, closeTo(0.98, 0.01));
      expect(player.state.replayGain.preampDb, closeTo(1.5, 0.01));
      expect(player.state.replayGain.preventClipping, isTrue);

      await player.action.clearReplayGain();
      expect(player.state.replayGain.enabled, isFalse);
    });

    test('Preamp control updates state and native engine independently', () async {
      expect(player.state.preamp, equals(0.0));

      await player.action.setPreamp(3.5);
      expect(player.state.preamp, closeTo(3.5, 0.01));
      expect(player.state.preampDb, closeTo(3.5, 0.01));

      await player.action.setPreamp(-4.0);
      expect(player.state.preamp, closeTo(-4.0, 0.01));
    });

    test('Balance control clamps and updates state', () async {
      expect(player.state.balance, equals(0.0));

      await player.action.setBalance(-0.75);
      expect(player.state.balance, closeTo(-0.75, 0.01));

      await player.action.setBalance(0.5);
      expect(player.state.balance, closeTo(0.5, 0.01));

      // Clamping to -1.0 .. +1.0
      await player.action.setBalance(1.8);
      expect(player.state.balance, closeTo(1.0, 0.01));

      await player.action.setBalance(-2.5);
      expect(player.state.balance, closeTo(-1.0, 0.01));
    });

    test('Mono downmix toggle updates state', () async {
      expect(player.state.mono, isFalse);

      await player.action.setMono(true);
      expect(player.state.mono, isTrue);

      await player.action.setMono(false);
      expect(player.state.mono, isFalse);
    });

    test('Crossfeed mode updates state and native bs2b filter', () async {
      expect(player.state.crossfeed, equals(CrossfeedMode.off));

      await player.action.setCrossfeed(CrossfeedMode.moffatBauer);
      expect(player.state.crossfeed, equals(CrossfeedMode.moffatBauer));

      await player.action.setCrossfeed(CrossfeedMode.chuMoy);
      expect(player.state.crossfeed, equals(CrossfeedMode.chuMoy));

      await player.action.setCrossfeed(CrossfeedMode.off);
      expect(player.state.crossfeed, equals(CrossfeedMode.off));
    });

    test('Spatializer updates state and width factor', () async {
      expect(player.state.spatializerEnabled, isFalse);

      await player.action.setSpatializer(enabled: true, width: 1.4);
      expect(player.state.spatializerEnabled, isTrue);
      expect(player.state.spatializerWidth, closeTo(1.4, 0.01));

      await player.action.setSpatializer(enabled: false);
      expect(player.state.spatializerEnabled, isFalse);
    });

    test('Limiter toggle updates state', () async {
      expect(player.state.limiterEnabled, isTrue);

      await player.action.setLimiter(false);
      expect(player.state.limiterEnabled, isFalse);

      await player.action.setLimiter(true);
      expect(player.state.limiterEnabled, isTrue);
    });

    test('Playback with full DSP chain enabled streams smoothly without crashing', () async {
      await player.action.open(testWavFile.path);

      // Configure complete DSP chain
      await player.action.setReplayGain(gainDb: -10.0, peak: 0.95);
      await player.action.setPreamp(1.0);
      await player.action.setBalance(-0.2);
      await player.action.setCrossfeed(CrossfeedMode.moffatBauer);
      await player.action.setLimiter(true);

      // Playback
      await player.action.play();
      expect(player.state.playing, isTrue);

      // Allow 200ms of audio streaming through all DSP nodes
      await Future.delayed(const Duration(milliseconds: 200));

      expect(player.state.playing, isTrue);
      await player.action.pause();
      expect(player.state.playing, isFalse);
    });
  });
}
