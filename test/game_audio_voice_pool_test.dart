import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Game Audio VoicePool Subsystem in MiniaudioPlayer', () {
    late MiniaudioPlayer player;
    late Uint8List wavBytes;

    setUpAll(() async {
      await MiniaudioPlayer.ensureInitialized();
      wavBytes = await File('test/fixtures/test_24bit_stereo.wav').readAsBytes();
    });

    setUp(() async {
      player = MiniaudioPlayer(
        config: const PlayerConfig(
          sampleRate: 44100,
          channels: 2,
          bufferSizeFrames: 512,
          maxVoices: 8,
        ),
      );
    });

    tearDown(() async {
      await player.dispose();
    });

    test('Loads sound effect into RAM and unloads successfully', () async {
      await player.action.loadEffect(
        AudioEffect(
          id: 'test_sound',
          source: AudioSource(wavBytes),
          maxPolyphony: 8,
        ),
      );

      expect(player.state.loadedEffectIds, contains('test_sound'));
      expect(player.state.allocatedRamBytes, greaterThan(0));

      await player.action.unloadEffect('test_sound');
      expect(player.state.loadedEffectIds, isNot(contains('test_sound')));
    });

    test('Plays sounds concurrently within voice pool capacity', () async {
      await player.action.loadEffect(
        AudioEffect(
          id: 'laser',
          source: AudioSource(wavBytes),
          maxPolyphony: 8,
        ),
      );

      final v1 = await player.action.playEffect(
        'laser',
        volume: 0.8,
        pitch: 1.0,
        config: const EffectConfig(priority: 100),
      );
      final v2 = await player.action.playEffect(
        'laser',
        volume: 0.5,
        pitch: 1.2,
        config: const EffectConfig(priority: 150),
      );
      final v3 = await player.action.playEffect(
        'laser',
        volume: 1.0,
        pitch: 0.9,
        config: const EffectConfig(priority: 200),
      );

      expect(v1, greaterThan(0));
      expect(v2, greaterThan(0));
      expect(v3, greaterThan(0));
      expect(v1 != v2 && v2 != v3, isTrue);

      await player.action.stopAllEffects();
      expect(player.state.activeVoicesCount, equals(0));
    });

    test('Plays one-shot sound with pitch and volume jitter', () async {
      await player.action.loadEffect(
        AudioEffect(
          id: 'hit',
          source: AudioSource(wavBytes),
        ),
      );

      final v1 = await player.action.playEffect(
        'hit',
        volume: 0.9,
        pitch: 1.0,
        pitchJitter: 0.05,
        volumeJitter: 0.05,
        config: const EffectConfig(priority: 128),
      );
      expect(v1, greaterThan(0));

      final v2 = await player.action.playEffect(
        'hit',
        volume: 0.9,
        pitch: 1.0,
        pitchJitter: 0.1,
        volumeJitter: 0.1,
        config: const EffectConfig(priority: 128),
      );
      expect(v2, greaterThan(0));
    });

    test('Plays synchronized stem layers (vertical layering)', () async {
      await player.action.loadEffect(
        AudioEffect(id: 'stemA', source: AudioSource(wavBytes)),
      );
      await player.action.loadEffect(
        AudioEffect(id: 'stemB', source: AudioSource(wavBytes)),
      );

      final vA = await player.action.playEffect('stemA', volume: 0.7, looping: true);
      final vB = await player.action.playEffect('stemB', volume: 0.4, looping: true);

      expect(vA, greaterThan(0));
      expect(vB, greaterThan(0));

      // Modulate individual stem volume dynamically
      expect(() => player.action.setEffectVolume(vA, 0.2), returnsNormally);
      expect(() => player.action.setEffectPitch(vB, 1.05), returnsNormally);

      await player.action.stopEffect(vA);
      await player.action.stopEffect(vB);
    });

    test('Integrates 3D spatial listener and voice emitters with Doppler', () async {
      await player.action.loadEffect(
        AudioEffect(id: 'spatial_hit', source: AudioSource(wavBytes)),
      );

      await player.action.setListener(const SpatialListener(
        position: Vector3(0.0, 1.7, 0.0),
        forward: Vector3(0.0, 0.0, -1.0),
        up: Vector3(0.0, 1.0, 0.0),
        velocity: Vector3(0.0, 0.0, 5.0),
      ));

      const emitter = SpatialEmitter(
        position: Vector3(10.0, 1.7, 20.0),
        velocity: Vector3(-15.0, 0.0, -25.0),
        minDistance: 2.0,
        maxDistance: 500.0,
        rolloffFactor: 1.0,
        dopplerFactor: 1.0,
      );

      final voiceId = await player.action.playEffect(
        'spatial_hit',
        volume: 1.0,
        pitch: 1.0,
        spatial: emitter,
      );
      expect(voiceId, greaterThan(0));

      // Update voice emitter dynamically in 3D space
      await player.action.setEffectEmitter(
        voiceId,
        emitter.copyWith(position: const Vector3(0.0, 1.7, 5.0)),
      );
    });

    test('Disposes cleanly and rejects subsequent operations', () async {
      await player.dispose();

      expect(
        () => player.action.loadEffect(AudioEffect(id: 'x', source: AudioSource(wavBytes))),
        throwsStateError,
      );
      expect(() => player.action.playEffect('x'), throwsStateError);
      expect(() => player.action.stopAllEffects(), throwsStateError);
    });
  });
}
