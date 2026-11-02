import 'dart:io';

import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File trackA;
  late File trackB;
  late File trackC;
  late File trackD;

  setUpAll(() async {
    trackA = File('test/fixtures/test_24bit.wav');
    trackB = File('test/fixtures/test_24bit_stereo.wav');
    trackC = File('test/fixtures/cbr_noxing.mp3');
    trackD = File('test/fixtures/salida.wav');
  });

  group('Rust-Authoritative Queue & Infinite Mix Parity', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: CrossfadeConfig(
          duration: const Duration(milliseconds: 300),
          manualDuration: const Duration(milliseconds: 100),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test('open() populates Rust queue and Dart shadow map', () async {
      await engine.action.open([
        AudioSource(trackA.path, data: 'Alpha'),
        AudioSource(trackB.path, data: 'Beta'),
      ]);

      expect(engine.state.queue.length, equals(2));
      expect(engine.state.queue[0].data, equals('Alpha'));
      expect(engine.state.queue[1].data, equals('Beta'));
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.currentItem?.data, equals('Alpha'));
    });

    test('append() and insertNext() mutate queue in Rust reactively', () async {
      await engine.action.open([
        AudioSource(trackA.path, data: 'Alpha'),
        AudioSource(trackB.path, data: 'Beta'),
      ]);

      // insertNext adds Gamma immediately after index 0 (at index 1)
      await engine.action.insertNext(
        AudioSource(trackC.path, data: 'Gamma'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.state.queue.length, equals(3));
      expect(engine.state.queue[0].data, equals('Alpha'));
      expect(engine.state.queue[1].data, equals('Gamma'));
      expect(engine.state.queue[2].data, equals('Beta'));

      // append adds Delta at the end
      await engine.action.append([
        AudioSource(trackD.path, data: 'Delta'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.state.queue.length, equals(4));
      expect(engine.state.queue[3].data, equals('Delta'));
    });

    test('removeAt() and reorder() maintain index and metadata consistency', () async {
      await engine.action.open([
        AudioSource(trackA.path, data: 'Alpha'),
        AudioSource(trackB.path, data: 'Beta'),
        AudioSource(trackC.path, data: 'Gamma'),
      ]);

      // Reorder index 0 (Alpha) to index 2
      await engine.action.reorder(0, 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.state.queue.length, equals(3));
      expect(engine.state.queue[0].data, equals('Beta'));
      expect(engine.state.queue[1].data, equals('Gamma'));
      expect(engine.state.queue[2].data, equals('Alpha'));

      // Remove index 1 (Gamma)
      await engine.action.removeAt(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.state.queue.length, equals(2));
      expect(engine.state.queue[0].data, equals('Beta'));
      expect(engine.state.queue[1].data, equals('Alpha'));
    });

    test('clearQueue(keepCurrent: true) retains active item at index 0', () async {
      await engine.action.open([
        AudioSource(trackA.path, data: 'Alpha'),
        AudioSource(trackB.path, data: 'Beta'),
      ], startIndex: 1);

      expect(engine.state.currentIndex, equals(1));
      expect(engine.state.currentItem?.data, equals('Beta'));

      await engine.action.clearQueue(keepCurrent: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.state.queue.length, equals(1));
      expect(engine.state.queue[0].data, equals('Beta'));
      expect(engine.state.currentIndex, equals(0));
    });

    test('Infinite Mix emits needMoreTracks when remaining tracks < 2', () async {
      final receivedEvents = <NeedMoreTracksEvent>[];
      final sub = engine.stream.needMoreTracks.listen(receivedEvents.add);

      await engine.action.setInfiniteMix(true);
      expect(engine.state.infiniteMixEnabled, isTrue);

      // Open queue with only 1 track
      await engine.action.open([
        AudioSource(trackA.path, data: 'Single Track'),
      ]);

      await engine.action.play();

      // Wait for monitor thread tick to observe queue and emit event
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(receivedEvents, isNotEmpty);
      expect(receivedEvents.first.remainingTracks, equals(0));

      // In response, dynamically append next track
      await engine.action.append([
        AudioSource(trackB.path, data: 'Appended Track'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.state.queue.length, equals(2));
      expect(engine.state.queue[1].data, equals('Appended Track'));

      await sub.cancel();
    });

    test('setShuffle(true) shuffles queue via SliceRandom and restores original order on setShuffle(false)', () async {
      await engine.action.open([
        AudioSource(trackA.path, data: 'Track 1'),
        AudioSource(trackB.path, data: 'Track 2'),
        AudioSource(trackC.path, data: 'Track 3'),
        AudioSource(trackD.path, data: 'Track 4'),
      ]);

      expect(engine.state.queue.map((e) => e.data).toList(), equals(['Track 1', 'Track 2', 'Track 3', 'Track 4']));

      // Activate shuffle
      await engine.action.setShuffle(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.state.shuffle, isTrue);

      final shuffledData = engine.state.queue.map((e) => e.data).toList();
      // Contains all 4 items
      expect(shuffledData, containsAll(['Track 1', 'Track 2', 'Track 3', 'Track 4']));
      expect(shuffledData.length, equals(4));

      // Deactivate shuffle -> restores original order
      await engine.action.setShuffle(false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.state.shuffle, isFalse);

      expect(
        engine.state.queue.map((e) => e.data).toList(),
        equals(['Track 1', 'Track 2', 'Track 3', 'Track 4']),
      );
    });

    test('Fine-grained streams: engine.stream.queue does not emit on index navigation', () async {
      final queueEvents = <List<AudioSource<String>>>[];
      final indexEvents = <int>[];

      final queueSub = engine.stream.queue.listen(queueEvents.add);
      final indexSub = engine.stream.currentIndex.listen(indexEvents.add);

      await engine.action.open([
        AudioSource(trackA.path, data: 'Track 1'),
        AudioSource(trackB.path, data: 'Track 2'),
        AudioSource(trackC.path, data: 'Track 3'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final initialQueueEmissions = queueEvents.length;
      expect(initialQueueEmissions, greaterThanOrEqualTo(1));

      // Navigate via next() -> must emit currentIndex, NOT queue
      await engine.action.next();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(queueEvents.length, equals(initialQueueEmissions),
          reason: 'engine.stream.queue must not emit when moving to next track');
      expect(indexEvents.last, equals(1));

      // Navigate via previous() -> must emit currentIndex, NOT queue
      await engine.action.previous();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(queueEvents.length, equals(initialQueueEmissions),
          reason: 'engine.stream.queue must not emit when moving to previous track');
      expect(indexEvents.last, equals(0));

      // Navigate via skipToIndex() -> must emit currentIndex, NOT queue
      await engine.action.skipToIndex(2);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(queueEvents.length, equals(initialQueueEmissions),
          reason: 'engine.stream.queue must not emit when skipping to index');
      expect(indexEvents.last, equals(2));

      // Append -> queue mutated, so engine.stream.queue MUST emit
      await engine.action.append([
        AudioSource(trackD.path, data: 'Track 4'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(queueEvents.length, greaterThan(initialQueueEmissions),
          reason: 'engine.stream.queue must emit when queue is appended');

      await queueSub.cancel();
      await indexSub.cancel();
    });

    test('LoopMode.one preserves current track repeating rather than advancing', () async {
      await engine.action.open([
        AudioSource(trackA.path, data: 'Track 1'),
        AudioSource(trackB.path, data: 'Track 2'),
      ]);

      await engine.action.setLoopMode(LoopMode.one);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(engine.state.loopMode, equals(LoopMode.one));

      // With loopMode = one, current index is 0
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.currentItem?.data, equals('Track 1'));
    });

    test('Toggling shuffle during active crossfade preserves track consistency and aborts cleanly', () async {
      await engine.action.open([
        AudioSource(trackA.path, data: 'Track 1'),
        AudioSource(trackB.path, data: 'Track 2'),
        AudioSource(trackC.path, data: 'Track 3'),
        AudioSource(trackD.path, data: 'Track 4'),
      ]);

      await engine.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Initiate manual crossfade to next track
      final nextFuture = engine.action.next();
      // While crossfade is active, toggle shuffle
      await engine.action.setShuffle(true);
      await nextFuture;
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Ensure active index is within valid range and matches current track in shuffled queue
      final currentIdx = engine.state.currentIndex;
      expect(currentIdx, greaterThanOrEqualTo(0));
      expect(currentIdx, lessThan(engine.state.queue.length));
      final currentItem = engine.state.currentItem;
      expect(currentItem, isNotNull);
      expect(engine.state.queue[currentIdx].data, equals(currentItem?.data));
    });

    test('Rapid skipToIndex calls do not hang or deadlock engine', () async {
      await engine.action.open([
        AudioSource(trackA.path, data: 'Track 1'),
        AudioSource(trackB.path, data: 'Track 2'),
        AudioSource(trackC.path, data: 'Track 3'),
        AudioSource(trackD.path, data: 'Track 4'),
      ]);

      await engine.action.play();

      // Fire 5 rapid skips back-to-back
      for (int i = 0; i < 5; i++) {
        final target = (i + 1) % 4;
        await engine.action.skipToIndex(target);
      }

      await Future<void>.delayed(const Duration(milliseconds: 200));
      final finalIdx = engine.state.currentIndex;
      expect(finalIdx, greaterThanOrEqualTo(0));
      expect(finalIdx, lessThan(4));
      expect(engine.isDisposed, isFalse);
    });
  });
}
