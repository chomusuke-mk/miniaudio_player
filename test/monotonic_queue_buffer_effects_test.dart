import 'dart:io';

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
      expect(b1.toString(), contains('Buffer(start: 0:00:01.000000, end: 0:00:10.000000, isBuffering: true)'));
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

    test('Assigns monotonically increasing unique IDs across queue operations', () async {
      final s1 = AudioSource('test/fixtures/salida.mp3', data: 'Track 1');
      final s2 = AudioSource('test/fixtures/salida.wav', data: 'Track 2');

      await player.action.open([s1, s2]);

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
      final inserted = player.state.queue.firstWhere((s) => s.data == 'Track 4');
      expect(inserted.id!, greaterThan(id3));
    });

    test('Reorders queue natively using list of unique track IDs', () async {
      final s1 = AudioSource('test/fixtures/salida.mp3', data: 'T1');
      final s2 = AudioSource('test/fixtures/salida.wav', data: 'T2');
      final s3 = AudioSource('test/fixtures/salida.flac', data: 'T3');

      await player.action.open([s1, s2, s3]);
      final id1 = player.state.queue[0].id!;
      final id2 = player.state.queue[1].id!;
      final id3 = player.state.queue[2].id!;

      // Reorder to [id3, id1, id2]
      await player.action.reorderByIds([id3, id1, id2]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(player.state.queue.length, equals(3));
      expect(player.state.queue[0].id, equals(id3));
      expect(player.state.queue[0].data, equals('T3'));
      expect(player.state.queue[1].id, equals(id1));
      expect(player.state.queue[1].data, equals('T1'));
      expect(player.state.queue[2].id, equals(id2));
      expect(player.state.queue[2].data, equals('T2'));
    });

    test('MemoryAudioSource transfers bytes to Rust and frees Dart RAM in queue', () async {
      final wavBytes = await File('test/fixtures/test_24bit_stereo.wav').readAsBytes();
      expect(wavBytes.isNotEmpty, isTrue);

      final memSource = AudioSource(wavBytes, data: 'Memory Song');
      await player.action.open([memSource]);

      expect(player.state.queue.length, equals(1));
      final queued = player.state.queue[0];
      expect(queued.data, equals('Memory Song'));
      expect(queued is MemoryAudioSource, isTrue);
      // Queued descriptor drops Dart-side byte buffer to avoid duplicating memory
      expect((queued as MemoryAudioSource).bytes.isEmpty, isTrue);
    });
  });

  group('RAM Sound Effects Managed Solely By Rust', () {
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

    test('Rust decodes AudioSource directly and reports real allocated RAM bytes', () async {
      final file = File('test/fixtures/test_24bit_stereo.wav');
      expect(file.existsSync(), isTrue);

      // Load via File path AudioSource directly without pre-reading bytes in Dart
      await player.action.loadEffect(
        AudioEffect(
          id: 'sfx_file',
          source: AudioSource(file.path),
          maxPolyphony: 4,
        ),
      );

      expect(player.state.loadedEffectIds, contains('sfx_file'));
      expect(player.state.allocatedRamBytes, greaterThan(0));

      // Unload and verify metrics reset from Rust
      await player.action.unloadEffect('sfx_file');
      expect(player.state.loadedEffectIds, isNot(contains('sfx_file')));
      expect(player.state.allocatedRamBytes, equals(0));
    });
  });
}
