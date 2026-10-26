import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DSP Data Models', () {
    test('ReplayGainConfig initializes defaults and computes effectiveGainDb', () {
      const defaultRg = ReplayGainConfig();
      expect(defaultRg.enabled, isFalse);
      expect(defaultRg.gainDb, equals(0.0));
      expect(defaultRg.peak, equals(0.0));
      expect(defaultRg.preventClipping, isTrue);
      expect(defaultRg.effectiveGainDb, equals(0.0));

      const activeRg = ReplayGainConfig(
        gainDb: -8.5,
        peak: 0.95,
        preventClipping: true,
        enabled: true,
      );
      expect(activeRg.enabled, isTrue);
      expect(activeRg.gainDb, equals(-8.5));
      expect(activeRg.peak, equals(0.95));
      expect(activeRg.effectiveGainDb, equals(-8.5));

      const disabledRg = ReplayGainConfig(
        gainDb: -8.5,
        enabled: false,
      );
      expect(disabledRg.effectiveGainDb, equals(0.0));
    });

    test('CrossfeedMode enum has valid values', () {
      expect(CrossfeedMode.values.length, equals(3));
      expect(CrossfeedMode.off.index, equals(0));
      expect(CrossfeedMode.moffatBauer.index, equals(1));
      expect(CrossfeedMode.chuMoy.index, equals(2));
    });

    test('Reverb model initializes defaults, presets and copyWith', () {
      const defaultReverb = Reverb();
      expect(defaultReverb.enabled, isFalse);
      expect(defaultReverb.roomSize, equals(0.5));
      expect(defaultReverb.damping, equals(0.5));
      expect(defaultReverb.width, equals(1.0));
      expect(defaultReverb.wet, equals(0.33));
      expect(defaultReverb.dry, equals(1.0));

      expect(Reverb.off.enabled, isFalse);
      expect(Reverb.smallRoom.enabled, isTrue);
      expect(Reverb.studio.enabled, isTrue);
      expect(Reverb.concertHall.enabled, isTrue);
      expect(Reverb.cathedral.enabled, isTrue);
      expect(Reverb.plate.enabled, isTrue);
      expect(Reverb.ambient.enabled, isTrue);

      expect(Reverb.presets.containsKey('Concert Hall'), isTrue);
      expect(Reverb.presets['Concert Hall'], equals(Reverb.concertHall));
      expect(Reverb.presets['Small Room'], equals(Reverb.smallRoom));

      final modified = Reverb.concertHall.copyWith(wet: 0.55, damping: 0.2);
      expect(modified.enabled, isTrue);
      expect(modified.wet, equals(0.55));
      expect(modified.damping, equals(0.2));
      expect(modified.roomSize, equals(Reverb.concertHall.roomSize));
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
        preventClipping: true,
      );

      expect(player.state.replayGain.enabled, isTrue);
      expect(player.state.replayGain.gainDb, closeTo(-12.5, 0.01));
      expect(player.state.replayGain.peak, closeTo(0.98, 0.01));
      expect(player.state.replayGain.preventClipping, isTrue);

      await player.action.clearReplayGain();
      expect(player.state.replayGain.enabled, isFalse);
    });

    test('Preamp control updates state and native engine independently', () async {
      expect(player.state.preamp, equals(0.0));

      await player.action.setPreamp(3.5);
      expect(player.state.preamp, closeTo(3.5, 0.01));
      expect(player.state.preamp, closeTo(3.5, 0.01));

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

    test('Reverb controls and presets update state and native engine', () async {
      expect(player.state.reverb.enabled, isFalse);

      await player.action.setReverb(Reverb.concertHall);
      expect(player.state.reverb.enabled, isTrue);
      expect(player.state.reverb.roomSize, closeTo(0.80, 0.01));
      expect(player.state.reverb.damping, closeTo(0.35, 0.01));
      expect(player.state.reverb.wet, closeTo(0.40, 0.01));
      expect(player.state.reverb.dry, closeTo(0.95, 0.01));

      // Test copyWith parameter override
      await player.action.setReverb(player.state.reverb.copyWith(wet: 0.60));
      expect(player.state.reverb.wet, closeTo(0.60, 0.01));
      expect(player.state.reverb.roomSize, closeTo(0.80, 0.01));

      // Test disable / off preset
      await player.action.setReverb(Reverb.off);
      expect(player.state.reverb.enabled, isFalse);
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

      // Configure complete DSP chain including Reverb
      await player.action.setReplayGain(gainDb: -10.0, peak: 0.95);
      await player.action.setPreamp(1.0);
      await player.action.setBalance(-0.2);
      await player.action.setCrossfeed(CrossfeedMode.moffatBauer);
      await player.action.setReverb(Reverb.concertHall);
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

    test('DSP actions emit directly on their respective streams', () async {
      ReplayGainConfig? streamRg;
      double? streamPreamp;
      double? streamBalance;
      bool? streamMono;
      CrossfeedMode? streamCrossfeed;
      bool? streamSpatializerEnabled;
      double? streamSpatializerWidth;
      bool? streamLimiter;
      Reverb? streamReverb;

      final subs = [
        player.stream.replayGain.listen((v) => streamRg = v),
        player.stream.preamp.listen((v) => streamPreamp = v),
        player.stream.balance.listen((v) => streamBalance = v),
        player.stream.mono.listen((v) => streamMono = v),
        player.stream.crossfeed.listen((v) => streamCrossfeed = v),
        player.stream.spatializerEnabled.listen((v) => streamSpatializerEnabled = v),
        player.stream.spatializerWidth.listen((v) => streamSpatializerWidth = v),
        player.stream.limiterEnabled.listen((v) => streamLimiter = v),
        player.stream.reverb.listen((v) => streamReverb = v),
      ];

      await player.action.setReplayGain(gainDb: -6.0, peak: 0.9);
      await player.action.setPreamp(2.5);
      await player.action.setBalance(0.4);
      await player.action.setMono(true);
      await player.action.setCrossfeed(CrossfeedMode.chuMoy);
      await player.action.setSpatializer(enabled: true, width: 1.5);
      await player.action.setLimiter(false);
      await player.action.setReverb(Reverb.cathedral);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(streamRg?.gainDb, equals(-6.0));
      expect(streamRg?.peak, equals(0.9));
      expect(streamPreamp, equals(2.5));
      expect(streamBalance, equals(0.4));
      expect(streamMono, isTrue);
      expect(streamCrossfeed, equals(CrossfeedMode.chuMoy));
      expect(streamSpatializerEnabled, isTrue);
      expect(streamSpatializerWidth, equals(1.5));
      expect(streamLimiter, isFalse);
      expect(streamReverb, equals(Reverb.cathedral));

      for (final s in subs) {
        await s.cancel();
      }
    });

    test('DSP actions do NOT flood unrelated streams', () async {
      await player.action.open(testWavFile.path);

      int positionEvents = 0;
      int playingEvents = 0;
      int preampEvents = 0;
      int reverbEvents = 0;
      int balanceEvents = 0;

      final subs = [
        player.stream.position.listen((_) => positionEvents++),
        player.stream.playing.listen((_) => playingEvents++),
        player.stream.preamp.listen((_) => preampEvents++),
        player.stream.reverb.listen((_) => reverbEvents++),
        player.stream.balance.listen((_) => balanceEvents++),
      ];

      // Mutate only balance
      await player.action.setBalance(0.3);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(balanceEvents, equals(1));
      expect(positionEvents, equals(0), reason: 'position should not emit on balance change');
      expect(playingEvents, equals(0), reason: 'playing should not emit on balance change');
      expect(preampEvents, equals(0), reason: 'preamp should not emit on balance change');
      expect(reverbEvents, equals(0), reason: 'reverb should not emit on balance change');

      for (final s in subs) {
        await s.cancel();
      }
    });

    test('Distinct deduplication prevents duplicate emissions for identical values', () async {
      int volumeEvents = 0;
      int balanceEvents = 0;
      int preampEvents = 0;
      int limiterEvents = 0;

      final subs = [
        player.stream.volume.listen((_) => volumeEvents++),
        player.stream.balance.listen((_) => balanceEvents++),
        player.stream.preamp.listen((_) => preampEvents++),
        player.stream.limiterEnabled.listen((_) => limiterEvents++),
      ];

      // Initial changes
      await player.action.setVolume(0.7);
      await player.action.setBalance(-0.5);
      await player.action.setPreamp(1.2);
      await player.action.setLimiter(false);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(volumeEvents, equals(1));
      expect(balanceEvents, equals(1));
      expect(preampEvents, equals(1));
      expect(limiterEvents, equals(1));

      // Setting identical values MUST NOT emit duplicate events
      await player.action.setVolume(0.7);
      await player.action.setBalance(-0.5);
      await player.action.setPreamp(1.2);
      await player.action.setLimiter(false);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(volumeEvents, equals(1), reason: 'volume stream should deduplicate identical values');
      expect(balanceEvents, equals(1), reason: 'balance stream should deduplicate identical values');
      expect(preampEvents, equals(1), reason: 'preamp stream should deduplicate identical values');
      expect(limiterEvents, equals(1), reason: 'limiter stream should deduplicate identical values');

      for (final s in subs) {
        await s.cancel();
      }
    });
  });
}
