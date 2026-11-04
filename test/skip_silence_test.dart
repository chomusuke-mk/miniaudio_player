import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

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

    setUp(() {
      player = MiniaudioPlayer(source: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]);
    });

    tearDown(() async {
      await player.dispose();
    });

    test('initial state has silence skipping disabled and 0 saved duration', () {
      expect(player.state.skipSilence, isFalse);
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

    test('setSilenceConfig with copyWith updates individual fields selectively', () async {
      await player.action.setSilenceConfig(const SilenceSkipConfig.all());
      expect(player.state.silenceSkipMode, equals(SilenceSkipMode.all));

      await player.action.setSilenceConfig(player.state.silenceConfig.copyWith(thresholdDb: -38.0));
      expect(player.state.silenceSkipMode, equals(SilenceSkipMode.all));
      expect(player.state.silenceConfig.thresholdDb, equals(-38.0));
      expect(
        player.state.silenceConfig.minSilenceDuration,
        equals(const Duration(milliseconds: 300)),
      );
    });

    test('dynamic toggling of skipSilence mid-playback engages without crashing', () async {
      await player.action.open([AudioSource('test/fixtures/salida.wav')]);
      await player.action.play();

      // Toggle silence skip ON while playing
      await player.action.setSkipSilence(true);
      expect(player.state.skipSilence, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Toggle silence skip OFF while playing
      await player.action.setSkipSilence(false);
      expect(player.state.skipSilence, isFalse);

      await player.action.stop();
    });

    test('seeking resets silence detector and preserves engine stability', () async {
      await player.action.setSilenceConfig(const SilenceSkipConfig.all());
      await player.action.open([AudioSource('test/fixtures/salida.wav')]);
      await player.action.play();

      await Future<void>.delayed(const Duration(milliseconds: 150));

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
