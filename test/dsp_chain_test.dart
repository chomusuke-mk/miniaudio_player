import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  group('DSP Data Models', () {
    test('ReplayGainConfig initializes defaults', () {
      const defaultRg = ReplayGainConfig();
      expect(defaultRg.gainDb, equals(0.0));
      expect(defaultRg.peak, equals(1.0));

      const activeRg = ReplayGainConfig(
        gainDb: -8.5,
        peak: 0.95,
      );
      expect(activeRg.gainDb, equals(-8.5));
      expect(activeRg.peak, equals(0.95));
    });

    test('Crossfeed model initializes defaults, presets and copyWith', () {
      const defaultCf = Crossfeed();
      expect(defaultCf.enabled, isFalse);
      expect(defaultCf.cutoffHz, equals(700.0));
      expect(defaultCf.feedDb, equals(4.5));

      expect(Crossfeed.off.enabled, isFalse);
      expect(Crossfeed.moffatBauer.enabled, isTrue);
      expect(Crossfeed.moffatBauer.cutoffHz, equals(700.0));
      expect(Crossfeed.moffatBauer.feedDb, equals(4.5));
      expect(Crossfeed.chuMoy.enabled, isTrue);
      expect(Crossfeed.chuMoy.cutoffHz, equals(700.0));
      expect(Crossfeed.chuMoy.feedDb, equals(6.0));

      final custom =
          defaultCf.copyWith(enabled: true, cutoffHz: 800.0, feedDb: 5.0);
      expect(custom.enabled, isTrue);
      expect(custom.cutoffHz, equals(800.0));
      expect(custom.feedDb, equals(5.0));
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

    test('Equalizer model initializes defaults, presets and enabled state', () {
      const defaultEq = Equalizer();
      expect(defaultEq.enabled, isTrue);

      expect(Equalizer.off.enabled, isFalse);
      expect(Equalizer.flat.enabled, isTrue);
      expect(Equalizer.rock.enabled, isTrue);
      expect(Equalizer.pop.enabled, isTrue);
      expect(Equalizer.jazz.enabled, isTrue);
      expect(Equalizer.classical.enabled, isTrue);
      expect(Equalizer.bassBoost.enabled, isTrue);

      final custom = defaultEq.copyWith(enabled: false, hz31: 3.0);
      expect(custom.enabled, isFalse);
      expect(custom.hz31, equals(3.0));
    });
  });

  group('DSP Controls and Engine Integration', () {
    late File testWavFile;
    late MiniaudioPlayer player;

    setUp(() async {
      testWavFile = File('test/fixtures/salida.wav');
      player = MiniaudioPlayer(queue: [AudioSource(testWavFile.path)]);
    });

    tearDown(() async {
      await player.dispose();
    });

    test('ReplayGain controls update state and native engine', () async {
      expect(player.state.replayGain.gainDb, equals(0.0));

      await player.action.setReplayGain(
        const ReplayGainConfig(
          gainDb: -12.5,
          peak: 0.98,
        ),
      );

      expect(player.state.replayGain.gainDb, closeTo(-12.5, 0.01));
      expect(player.state.replayGain.peak, closeTo(0.98, 0.01));

      await player.action.setReplayGain(null);
      expect(player.state.replayGain.gainDb, closeTo(0.0, 0.01));
    });

    test(
        'setReplayGain updates targeted AudioSource by id, position and current track',
        () async {
      final track1 = AudioSource('test/fixtures/salida.wav',
          id: 101, replayGainDb: -2.0, replayPeak: 0.9);
      final track2 = AudioSource('test/fixtures/salida.wav',
          id: 102, replayGainDb: -4.0, replayPeak: 0.8);
      await player.action.setQueue([track1, track2]);
      await player.action.play();

      expect(track1.replayGainDb, closeTo(-2.0, 0.01));
      expect(track2.replayGainDb, closeTo(-4.0, 0.01));

      // Update track1 by id
      await player.action.setReplayGain(
          const ReplayGainConfig(gainDb: -7.5, peak: 0.95),
          id: 101);
      expect(track1.replayGainDb, closeTo(-7.5, 0.01));
      expect(track1.replayPeak, closeTo(0.95, 0.01));
      expect(track2.replayGainDb, closeTo(-4.0, 0.01));

      // Update track2 by position
      await player.action.setReplayGain(
          const ReplayGainConfig(gainDb: -6.0, peak: 0.85),
          position: 1);
      expect(track2.replayGainDb, closeTo(-6.0, 0.01));
      expect(track2.replayPeak, closeTo(0.85, 0.01));

      // Update current track (which is track1 at index 0) without specifying id or position
      await player.action
          .setReplayGain(const ReplayGainConfig(gainDb: -8.0, peak: 0.99));
      expect(track1.replayGainDb, closeTo(-8.0, 0.01));
      expect(track1.replayPeak, closeTo(0.99, 0.01));

      // Clear track1 by id
      await player.action.setReplayGain(null, id: 101);
      expect(track1.replayGainDb, isNull);
      expect(track1.replayPeak, isNull);
    });

    test('Preamp control updates state and native engine independently',
        () async {
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
      expect(player.state.crossfeed, equals(Crossfeed.off));

      await player.action.setCrossfeed(Crossfeed.moffatBauer);
      expect(player.state.crossfeed, equals(Crossfeed.moffatBauer));

      await player.action.setCrossfeed(Crossfeed.chuMoy);
      expect(player.state.crossfeed, equals(Crossfeed.chuMoy));

      await player.action.setCrossfeed(Crossfeed.off);
      expect(player.state.crossfeed, equals(Crossfeed.off));
    });

    test('Spatializer updates state and width factor', () async {
      expect(player.state.spatializerEnabled, isFalse);

      await player.action.setSpatializer(enabled: true, width: 1.4);
      expect(player.state.spatializerEnabled, isTrue);
      expect(player.state.spatializerWidth, closeTo(1.4, 0.01));

      await player.action.setSpatializer(enabled: false);
      expect(player.state.spatializerEnabled, isFalse);
    });

    test('Reverb controls and presets update state and native engine',
        () async {
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

    test(
        'Playback with full DSP chain enabled streams smoothly without crashing',
        () async {
      await player.action.setQueue([AudioSource(testWavFile.path)]);

      // Configure complete DSP chain including Reverb
      await player.action
          .setReplayGain(const ReplayGainConfig(gainDb: -10.0, peak: 0.95));
      await player.action.setPreamp(1.0);
      await player.action.setBalance(-0.2);
      await player.action.setCrossfeed(Crossfeed.moffatBauer);
      await player.action.setReverb(Reverb.concertHall);
      await player.action.setLimiter(true);

      // Playback
      await player.action.play();
      expect(player.state.isPlaying, isTrue);

      // Allow 200ms of audio streaming through all DSP nodes
      await Future.delayed(const Duration(milliseconds: 200));

      expect(player.state.isPlaying, isTrue);
      await player.action.pause();
      expect(player.state.isPlaying, isFalse);
    });

    test('DSP actions emit directly on their respective streams', () async {
      ReplayGainConfig? streamRg;
      double? streamPreamp;
      double? streamBalance;
      bool? streamMono;
      Crossfeed? streamCrossfeed;
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
        player.stream.spatializerEnabled
            .listen((v) => streamSpatializerEnabled = v),
        player.stream.spatializerWidth
            .listen((v) => streamSpatializerWidth = v),
        player.stream.limiterEnabled.listen((v) => streamLimiter = v),
        player.stream.reverb.listen((v) => streamReverb = v),
      ];

      await player.action
          .setReplayGain(const ReplayGainConfig(gainDb: -6.0, peak: 0.9));
      await player.action.setPreamp(2.5);
      await player.action.setBalance(0.4);
      await player.action.setMono(true);
      await player.action.setCrossfeed(Crossfeed.chuMoy);
      await player.action.setSpatializer(enabled: true, width: 1.5);
      await player.action.setLimiter(false);
      await player.action.setReverb(Reverb.cathedral);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(streamRg?.gainDb, closeTo(-6.0, 0.001));
      expect(streamRg?.peak, closeTo(0.9, 0.001));
      expect(streamPreamp, closeTo(2.5, 0.001));
      expect(streamBalance, closeTo(0.4, 0.001));
      expect(streamMono, isTrue);
      expect(streamCrossfeed, equals(Crossfeed.chuMoy));
      expect(streamSpatializerEnabled, isTrue);
      expect(streamSpatializerWidth, closeTo(1.5, 0.001));
      expect(streamLimiter, isFalse);
      expect(streamReverb, equals(Reverb.cathedral));

      for (final s in subs) {
        await s.cancel();
      }
    });

    test('DSP actions do NOT flood unrelated streams', () async {
      await player.action.setQueue([AudioSource(testWavFile.path)]);

      int positionEvents = 0;
      int playingEvents = 0;
      int preampEvents = 0;
      int reverbEvents = 0;
      int balanceEvents = 0;

      final subs = [
        player.stream.position.listen((_) => positionEvents++),
        player.stream.isPlaying.listen((_) => playingEvents++),
        player.stream.preamp.listen((_) => preampEvents++),
        player.stream.reverb.listen((_) => reverbEvents++),
        player.stream.balance.listen((_) => balanceEvents++),
      ];

      // Mutate only balance
      await player.action.setBalance(0.3);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(balanceEvents, equals(1));
      expect(positionEvents, equals(0),
          reason: 'position should not emit on balance change');
      expect(playingEvents, equals(0),
          reason: 'playing should not emit on balance change');
      expect(preampEvents, equals(0),
          reason: 'preamp should not emit on balance change');
      expect(reverbEvents, equals(0),
          reason: 'reverb should not emit on balance change');

      for (final s in subs) {
        await s.cancel();
      }
    });

    test(
        'Distinct deduplication prevents duplicate emissions for identical values',
        () async {
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

      expect(volumeEvents, equals(1),
          reason: 'volume stream should deduplicate identical values');
      expect(balanceEvents, equals(1),
          reason: 'balance stream should deduplicate identical values');
      expect(preampEvents, equals(1),
          reason: 'preamp stream should deduplicate identical values');
      expect(limiterEvents, equals(1),
          reason: 'limiter stream should deduplicate identical values');

      for (final s in subs) {
        await s.cancel();
      }
    });
  });
}
