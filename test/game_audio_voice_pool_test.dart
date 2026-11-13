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
      wavBytes =
          await File('test/fixtures/test_24bit_stereo.wav').readAsBytes();
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

    test(
        'Registers sound effects catalog via setEffects and replaces catalog cleanly',
        () async {
      await player.action.setEffects([
        AudioEffect(
          id: 'test_sound',
          source: AudioSource(Uint8List.fromList(wavBytes)),
          maxPolyphony: 8,
        ),
      ]);

      expect(player.state.loadedEffectIds, contains('test_sound'));
      expect(player.state.allocatedRamBytes, greaterThan(0));

      await player.action.setEffects(const []);
      expect(player.state.loadedEffectIds, isNot(contains('test_sound')));
    });

    test(
        'Plays sounds concurrently within voice pool capacity and returns Voice handles',
        () async {
      await player.action.setEffects([
        AudioEffect(
          id: 'laser',
          source: AudioSource(Uint8List.fromList(wavBytes)),
          maxPolyphony: 8,
        ),
      ]);

      final v1 = await player.action.playEffect(
        'laser',
        config: const EffectConfig(volume: 0.8, pitch: 1.0, priority: 100),
      );
      final v2 = await player.action.playEffect(
        'laser',
        config: const EffectConfig(volume: 0.5, pitch: 1.2, priority: 150),
      );
      final v3 = await player.action.playEffect(
        'laser',
        config: const EffectConfig(volume: 1.0, pitch: 0.9, priority: 200),
      );

      expect(v1.id, greaterThan(0));
      expect(v2.id, greaterThan(0));
      expect(v3.id, greaterThan(0));
      expect(v1 != v2 && v2 != v3, isTrue);

      await player.action.stopAllEffects();
      expect(player.state.activeVoicesCount, equals(0));
    });

    test('Plays one-shot sound with pitch and volume jitter', () async {
      await player.action.setEffects([
        AudioEffect(
          id: 'hit',
          source: AudioSource(Uint8List.fromList(wavBytes)),
        ),
      ]);

      final v1 = await player.action.playEffect(
        'hit',
        config: const EffectConfig(
          volume: 0.9,
          pitch: 1.0,
          pitchJitter: 0.05,
          volumeJitter: 0.05,
          priority: 128,
        ),
      );
      expect(v1.id, greaterThan(0));

      final v2 = await player.action.playEffect(
        'hit',
        config: const EffectConfig(
          volume: 0.9,
          pitch: 1.0,
          pitchJitter: 0.1,
          volumeJitter: 0.1,
          priority: 128,
        ),
      );
      expect(v2.id, greaterThan(0));
    });

    test('Plays synchronized stem layers and modulates live Voice handles',
        () async {
      await player.action.setEffects([
        AudioEffect(
            id: 'stemA', source: AudioSource(Uint8List.fromList(wavBytes))),
        AudioEffect(
            id: 'stemB', source: AudioSource(Uint8List.fromList(wavBytes))),
      ]);

      final vA = await player.action.playEffect(
        'stemA',
        config: const EffectConfig(volume: 0.7, looping: true),
      );
      final vB = await player.action.playEffect(
        'stemB',
        config: const EffectConfig(volume: 0.4, looping: true),
      );

      expect(vA.id, greaterThan(0));
      expect(vB.id, greaterThan(0));

      // Modulate individual stem voices dynamically via Voice handle
      await vA.setVolume(0.2);
      await vB.setPitch(1.05);
      await vA.setBalance(-0.5);

      await vA.stop();
      await vB.stop();
    });

    test('Integrates 3D spatial listener and voice emitters with Doppler',
        () async {
      await player.action.setEffects([
        AudioEffect(
            id: 'spatial_hit',
            source: AudioSource(Uint8List.fromList(wavBytes))),
      ]);

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

      final voice = await player.action.playEffect(
        'spatial_hit',
        config: EffectConfig(
          volume: 1.0,
          pitch: 1.0,
          spatial: emitter,
        ),
      );
      expect(voice.id, greaterThan(0));

      // Update voice emitter dynamically in 3D space via Voice handle
      await voice.setEmitter(
        emitter.copyWith(position: const Vector3(0.0, 1.7, 5.0)),
      );
    });

    test(
        'Playing an effect 10 times concurrently produces 10 unique Voice handles and modulating/stopping one does not affect others',
        () async {
      final multiPlayer = MiniaudioPlayer(
        config: const PlayerConfig(
          sampleRate: 44100,
          channels: 2,
          bufferSizeFrames: 512,
          maxVoices: 16,
        ),
      );

      try {
        await multiPlayer.action.setEffects([
          AudioEffect(
            id: 'laser_multi',
            source: AudioSource(Uint8List.fromList(wavBytes)),
            maxPolyphony: 16,
          ),
        ]);

        final voices = <Voice>[];
        for (var i = 0; i < 10; i++) {
          final voice = await multiPlayer.action.playEffect(
            'laser_multi',
            config: const EffectConfig(
              volume: 0.8,
              looping: true,
            ),
          );
          voices.add(voice);
        }

        // Verify all 10 voices are unique instances with unique integer IDs
        final voiceIds = voices.map((v) => v.id).toSet();
        expect(voiceIds.length, equals(10));
        for (final voice in voices) {
          expect(voice.id, isA<int>());
          expect(voice.id, greaterThan(0));
        }

        expect(multiPlayer.state.activeVoicesCount, equals(10));

        // Modulate only the 5th voice handle
        final targetVoice = voices[4];
        await targetVoice.setVolume(0.2);
        await targetVoice.setPitch(1.5);
        await targetVoice.setBalance(-0.8);

        // Active voices must still be 10 because targetVoice was only modulated, not stopped
        expect(multiPlayer.state.activeVoicesCount, equals(10));

        // Stop only targetVoice
        await targetVoice.stop();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Exactly 9 voices must remain active
        expect(multiPlayer.state.activeVoicesCount, equals(9));

        // Clean up remaining voices
        await multiPlayer.action.stopAllEffects();
        expect(multiPlayer.state.activeVoicesCount, equals(0));
      } finally {
        await multiPlayer.dispose();
      }
    });

    test('Disposes cleanly and rejects subsequent operations', () async {
      await player.dispose();

      expect(
        () => player.action.setEffects([
          AudioEffect(
              id: 'x', source: AudioSource(Uint8List.fromList(wavBytes))),
        ]),
        throwsStateError,
      );
      expect(() => player.action.playEffect('x'), throwsStateError);
      expect(() => player.action.stopAllEffects(), throwsStateError);
    });
  });
}
