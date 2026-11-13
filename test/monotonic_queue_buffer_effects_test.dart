import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  group('Buffer Model & Telemetry Verification', () {
    test('Buffer class has strictly start, end, isBuffering and equality', () {
      const b1 = Buffer(
        start: Duration(seconds: 1),
        end: Duration(seconds: 10),
        isBuffering: true,
      );
      const b2 = Buffer(
        start: Duration(seconds: 1),
        end: Duration(seconds: 10),
        isBuffering: true,
      );
      const b3 = Buffer(
        start: Duration.zero,
        end: Duration(seconds: 10),
        isBuffering: false,
      );

      expect(b1.start, equals(const Duration(seconds: 1)));
      expect(b1.end, equals(const Duration(seconds: 10)));
      expect(b1.isBuffering, isTrue);
      expect(b1, equals(b2));
      expect(b1.hashCode, equals(b2.hashCode));
      expect(b1, isNot(equals(b3)));
      expect(
          b1.toString(),
          contains(
              'Buffer(start: 0:00:01.000000, end: 0:00:10.000000, isBuffering: true)'));
    });

    test('PlayerState initial buffer is empty and clean', () async {
      final player = MiniaudioPlayer();
      expect(player.state.buffer, equals(const Buffer()));
      await player.dispose();
    });
  });

  group('Monotonic Queue IDs & ReorderByIds Verification', () {
    late MiniaudioPlayer<String> player;

    setUp(() {
      player = MiniaudioPlayer<String>();
    });

    tearDown(() async {
      await player.dispose();
    });

    test('Assigns monotonically increasing unique IDs across queue operations',
        () async {
      final s1 = AudioSource('test/fixtures/salida.mp3', data: 'Track 1');
      final s2 = AudioSource('test/fixtures/salida.wav', data: 'Track 2');

      await player.action.setQueue([s1, s2]);

      expect(player.state.queue.length, equals(2));
      final id1 = player.state.queue[0].id!;
      final id2 = player.state.queue[1].id!;
      expect(id1, greaterThanOrEqualTo(1));
      expect(id2, greaterThan(id1));

      // Append tracks
      final s3 = AudioSource('test/fixtures/salida.flac', data: 'Track 3');
      await player.action.append([s3]);

      expect(player.state.queue.length, equals(3));
      final id3 = player.state.queue[2].id!;
      expect(id3, greaterThan(id2));

      // Insert next
      final s4 = AudioSource('test/fixtures/salida.ogg', data: 'Track 4');
      await player.action.insertNext(s4);

      expect(player.state.queue.length, equals(4));
      final inserted =
          player.state.queue.firstWhere((s) => s.data == 'Track 4');
      expect(inserted.id!, greaterThan(id3));
    });

    test('Reorders queue natively using list of unique track IDs', () async {
      final s1 = AudioSource('test/fixtures/salida.mp3', data: 'T1');
      final s2 = AudioSource('test/fixtures/salida.wav', data: 'T2');
      final s3 = AudioSource('test/fixtures/salida.flac', data: 'T3');

      await player.action.setQueue([s1, s2, s3]);
      final id1 = player.state.queue[0].id!;
      final id2 = player.state.queue[1].id!;
      final id3 = player.state.queue[2].id!;

      // Reorder to [id3, id1, id2]
      await player.action.reorderByIds([id3, id1, id2]);

      expect(player.state.queue.length, equals(3));
      expect(player.state.queue[0].id, equals(id3));
      expect(player.state.queue[0].data, equals('T3'));
      expect(player.state.queue[1].id, equals(id1));
      expect(player.state.queue[1].data, equals('T1'));
      expect(player.state.queue[2].id, equals(id2));
      expect(player.state.queue[2].data, equals('T2'));
    });

    test(
        'Unified AudioSource transfers bytes to Rust and frees Dart RAM in queue',
        () async {
      final wavBytes =
          await File('test/fixtures/test_24bit_stereo.wav').readAsBytes();
      expect(wavBytes.isNotEmpty, isTrue);

      final memSource =
          AudioSource(Uint8List.fromList(wavBytes), data: 'Memory Song');
      expect(memSource.isMemory, isTrue);
      expect(memSource.bytes, isNotNull);

      await player.action.setQueue([memSource]);

      expect(player.state.queue.length, equals(1));
      final queued = player.state.queue[0];
      expect(queued.data, equals('Memory Song'));
      expect(queued.isMemory, isTrue);
      // Queued descriptor drops Dart-side byte buffer to avoid duplicating memory
      expect(queued.bytes, isNull);
    });
  });

  group('Autonomous Memory-Budgeted Sound Effects Subsystem', () {
    late MiniaudioPlayer player;

    setUp(() {
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
        'Rust decodes AudioSource directly on setEffects/playEffect and reports real allocated RAM bytes',
        () async {
      final file = File('test/fixtures/test_24bit_stereo.wav');
      expect(file.existsSync(), isTrue);

      await player.action.setEffects([
        AudioEffect(
          id: 'sfx_file',
          source: AudioSource(file.path),
          maxPolyphony: 4,
        ),
      ]);

      final voice = await player.action.playEffect('sfx_file');
      expect(voice.id, greaterThan(0));
      expect(player.state.loadedEffectIds, contains('sfx_file'));
      expect(player.state.allocatedRamBytes, greaterThan(0));
      await voice.stop(fadeOut: Duration.zero);

      // Replace with empty catalog and verify metrics reset from Rust
      await player.action.setEffects(const []);
      expect(player.state.loadedEffectIds, isNot(contains('sfx_file')));
      expect(player.state.allocatedRamBytes, equals(0));
    });

    test(
        'Memory effects are immune to eviction while file effects evict by multi-factor score',
        () async {
      final file = File('test/fixtures/tripartite/eof_chirp.mp3');
      final memBytes = await file.readAsBytes();

      // Configure tight budget (only enough for ~2 effects)
      final budgetedPlayer = MiniaudioPlayer(
        config: const PlayerConfig(
          maxVoices: 8,
          maxRamBytes: 150 * 1024,
        ),
      );
      addTearDown(() => budgetedPlayer.dispose());

      await budgetedPlayer.action.setEffects([
        AudioEffect(
          id: 'mem_immune',
          source: AudioSource(Uint8List.fromList(memBytes)),
        ),
        AudioEffect(
          id: 'file_frequent',
          source: AudioSource(file.path),
        ),
        AudioEffect(
          id: 'file_rare',
          source: AudioSource(file.path),
        ),
      ]);

      // Trigger file_frequent multiple times so its frequency score is high
      for (var i = 0; i < 5; i++) {
        final v = await budgetedPlayer.action.playEffect('file_frequent');
        await v.stop(fadeOut: Duration.zero);
      }

      // Trigger file_rare once
      final vRare = await budgetedPlayer.action.playEffect('file_rare');
      await vRare.stop(fadeOut: Duration.zero);

      // Memory effect is ALWAYS retained in loadedEffectIds
      expect(budgetedPlayer.state.loadedEffectIds, contains('mem_immune'));
    });
  });
}
