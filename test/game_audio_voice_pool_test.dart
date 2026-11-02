import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Game Audio VoicePool Subsystem', () {
    late MiniaudioVoicePool pool;
    late Uint8List wavBytes;

    setUpAll(() async {
      wavBytes = await File('test/fixtures/test_24bit_stereo.wav').readAsBytes();
    });

    setUp(() async {
      pool = await MiniaudioVoicePool.create(
        sampleRate: 44100,
        channels: 2,
        periodSize: 512,
        maxVoices: 8,
      );
    });

    tearDown(() {
      pool.dispose();
    });

    test('Loads sound buffer and verifies accurate metadata', () async {
      final buffer = await pool.loadSound(wavBytes);
      expect(buffer.sampleRate, equals(44100));
      expect(buffer.channels, equals(2));
      expect(buffer.duration.inMilliseconds, greaterThan(200));
      expect(buffer.frameCount, greaterThan(10000));
      expect(buffer.id, greaterThan(BigInt.zero));

      final unloaded = pool.unloadSound(buffer);
      expect(unloaded, isTrue);
    });

    test('Plays sounds concurrently within voice pool capacity', () async {
      final buffer = await pool.loadSound(wavBytes);

      final v1 = pool.playSound(buffer, volume: 0.8, pitch: 1.0, priority: 100);
      final v2 = pool.playSound(buffer, volume: 0.5, pitch: 1.2, priority: 150);
      final v3 = pool.playSound(buffer, volume: 1.0, pitch: 0.9, priority: 200);

      expect(v1, greaterThan(0));
      expect(v2, greaterThan(0));
      expect(v3, greaterThan(0));
      expect(v1 != v2 && v2 != v3, isTrue);

      pool.stopAll();
      expect(pool.activeVoicesCount, equals(0));
    });

    test('Plays one-shot sound with pitch and volume jitter', () async {
      final buffer = await pool.loadSound(wavBytes);

      final v1 = pool.playOneShot(
        buffer,
        volume: 0.9,
        pitch: 1.0,
        pitchJitter: 0.05,
        volumeJitter: 0.05,
        priority: 128,
      );
      expect(v1, greaterThan(0));

      final v2 = pool.playOneShot(
        buffer,
        volume: 0.9,
        pitch: 1.0,
        pitchJitter: 0.1,
        volumeJitter: 0.1,
        priority: 128,
      );
      expect(v2, greaterThan(0));
    });

    test('Sets voice stealing policies cleanly', () async {
      expect(() => pool.setPolicy(VoiceStealingPolicy.lowestPriority), returnsNormally);
      expect(() => pool.setPolicy(VoiceStealingPolicy.oldest), returnsNormally);
      expect(() => pool.setPolicy(VoiceStealingPolicy.quietest), returnsNormally);
      expect(() => pool.setPolicy(VoiceStealingPolicy.farthest), returnsNormally);
    });

    test('Supports bullet-time / slow-motion TimeScale adjustments', () async {
      expect(() => pool.setTimeScale(0.5), returnsNormally);
      expect(() => pool.setTimeScale(2.0), returnsNormally);
      expect(() => pool.setTimeScale(1.0), returnsNormally);
    });

    test('Plays synchronized stem layers (vertical layering)', () async {
      final bufA = await pool.loadSound(wavBytes);
      final bufB = await pool.loadSound(wavBytes);

      final stems = pool.playStems([bufA, bufB], volumes: [0.7, 0.4], looping: true);
      expect(stems.length, equals(2));
      expect(stems[0], greaterThan(0));
      expect(stems[1], greaterThan(0));

      // Modulate individual stem volume dynamically
      expect(() => pool.setVoiceVolume(stems[0], 0.2), returnsNormally);
      expect(() => pool.setVoicePitch(stems[1], 1.05), returnsNormally);

      pool.stopVoice(stems[0]);
      pool.stopVoice(stems[1]);
    });

    test('Integrates 3D spatial listener and voice emitters with Doppler', () async {
      final buffer = await pool.loadSound(wavBytes);

      pool.setListener(const SpatialListener(
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

      final voiceId = pool.playSound(
        buffer,
        volume: 1.0,
        pitch: 1.0,
        emitter: emitter,
      );
      expect(voiceId, greaterThan(0));

      // Update voice emitter dynamically in 3D space
      pool.setVoiceEmitter(
        voiceId,
        emitter.copyWith(position: const Vector3(0.0, 1.7, 5.0)),
      );
    });

    test('Disposes cleanly and rejects subsequent operations', () async {
      final buffer = await pool.loadSound(wavBytes);
      pool.dispose();
      expect(pool.isDisposed, isTrue);

      expect(() => pool.loadSound(wavBytes), throwsStateError);
      expect(() => pool.playSound(buffer), throwsStateError);
      expect(() => pool.stopAll(), throwsStateError);
    });
  });
}
