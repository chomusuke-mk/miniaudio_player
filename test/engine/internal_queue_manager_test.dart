import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/src/engine/internal_queue_manager.dart';

class TestTrack {
  final String title;
  final String artist;
  TestTrack(this.title, this.artist);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InternalQueueManager - Pointer Identity (identical(item.data, originalData))', () {
    late InternalQueueManager<TestTrack> manager;
    late List<TestTrack> tracks;
    late List<EngineItem<TestTrack>> items;

    setUp(() {
      manager = InternalQueueManager<TestTrack>();
      tracks = [
        TestTrack('Track 0', 'Artist A'),
        TestTrack('Track 1', 'Artist B'),
        TestTrack('Track 2', 'Artist C'),
        TestTrack('Track 3', 'Artist D'),
        TestTrack('Track 4', 'Artist E'),
      ];
      items = [
        for (var i = 0; i < tracks.length; i++)
          EngineItem<TestTrack>(
            source: AudioSource.file('/path/to/song_$i.mp3'),
            data: tracks[i],
          ),
      ];
    });

    tearDown(() async {
      await manager.dispose();
    });

    test('Pointer identity preserved across setQueue, shuffle, unshuffle, reorder, insertNext, append, clear', () async {
      // 1. Initial setQueue
      manager.setQueue(items, startIndex: 2);
      expect(manager.length, equals(5));
      expect(manager.currentIndex, equals(2));
      for (var i = 0; i < manager.length; i++) {
        expect(
          identical(manager.activeQueue[i].data, tracks[i]),
          isTrue,
          reason: 'Item $i data must be identical to original track instance',
        );
      }

      // 2. setShuffle(true)
      manager.setShuffle(true);
      expect(manager.isShuffled, isTrue);
      // Item at current index (tracks[2]) must be pinned to index 0
      expect(identical(manager.currentItem?.data, tracks[2]), isTrue);
      for (final item in manager.activeQueue) {
        expect(
          tracks.any((t) => identical(t, item.data)),
          isTrue,
          reason: 'Shuffled item data must remain identical to original track',
        );
      }

      // 3. setShuffle(false) un-shuffle
      manager.setShuffle(false);
      expect(manager.isShuffled, isFalse);
      expect(manager.currentIndex, equals(2));
      for (var i = 0; i < manager.length; i++) {
        expect(
          identical(manager.activeQueue[i].data, tracks[i]),
          isTrue,
          reason: 'Un-shuffled item data must match original tracks in order',
        );
      }

      // 4. reorder
      manager.reorder(0, 4);
      expect(identical(manager.activeQueue[4].data, tracks[0]), isTrue);

      // 5. insertNext
      final newTrack = TestTrack('Inserted Track', 'Guest');
      final newItem = EngineItem<TestTrack>(
        source: AudioSource.file('/path/to/inserted.mp3'),
        data: newTrack,
      );
      manager.insertNext(newItem);
      final insertedEntry = manager.activeQueue[manager.currentIndex + 1];
      expect(identical(insertedEntry.data, newTrack), isTrue);

      // 6. append
      final appendedTrack = TestTrack('Appended Track', 'Guest 2');
      manager.append([
        EngineItem<TestTrack>(
          source: AudioSource.file('/path/to/appended.mp3'),
          data: appendedTrack,
        ),
      ]);
      expect(identical(manager.activeQueue.last.data, appendedTrack), isTrue);

      // 7. clear(keepCurrent: true)
      final currentBeforeClear = manager.currentItem;
      expect(currentBeforeClear, isNotNull);
      manager.clear(keepCurrent: true);
      expect(manager.length, equals(1));
      expect(identical(manager.currentItem?.data, currentBeforeClear!.data), isTrue);
    });
  });

  group('InternalQueueManager - Fisher-Yates Shuffle & Exact Un-shuffle', () {
    late List<EngineItem<String>> testItems;

    setUp(() {
      testItems = List.generate(
        10,
        (i) => EngineItem<String>(
          source: AudioSource.file('/music/track_$i.mp3'),
          data: 'Track $i',
        ),
      );
    });

    test('openQueue with shuffle: true and startIndex: 3 pins index 3 to index 0', () {
      final manager = InternalQueueManager<String>(random: Random(42));
      manager.setQueue(testItems, startIndex: 3, shuffle: true);

      expect(manager.isShuffled, isTrue);
      expect(manager.currentIndex, equals(0));
      expect(manager.currentItem?.data, equals('Track 3'));
      expect(manager.length, equals(10));

      // Ensure all 10 tracks are present without loss
      final allData = manager.activeQueue.map((e) => e.data).toSet();
      expect(allData.length, equals(10));
    });

    test('_avoidImmediateDuplicate prevents consecutive items with same sourceKey', () {
      final dupItems = [
        EngineItem<String>(source: AudioSource.file('/music/same.mp3'), data: 'Same A'),
        EngineItem<String>(source: AudioSource.file('/music/same.mp3'), data: 'Same B'),
        EngineItem<String>(source: AudioSource.file('/music/diff.mp3'), data: 'Diff'),
      ];

      final manager = InternalQueueManager<String>(random: Random(1));
      // Pin index 0 (Same A)
      manager.setQueue(dupItems, startIndex: 0, shuffle: true);

      expect(manager.activeQueue[0].data, equals('Same A'));
      // The second item should NOT have the same sourceKey if a different sourceKey exists
      expect(manager.activeQueue[1].sourceKey, isNot(equals(manager.activeQueue[0].sourceKey)));
      expect(manager.activeQueue[1].data, equals('Diff'));
    });

    test('openQueue with shuffle: true and startIndex: null chooses uniform random start', () {
      final chosenStarts = <int>{};
      for (var seed = 0; seed < 30; seed++) {
        final manager = InternalQueueManager<String>(random: Random(seed));
        manager.setQueue(testItems, shuffle: true);
        final currentData = manager.currentItem!.data!;
        final originalIndex = int.parse(currentData.split(' ').last);
        chosenStarts.add(originalIndex);
      }
      // Over 30 seeds, random start should pick multiple distinct tracks
      expect(chosenStarts.length, greaterThan(3));
    });

    test('setShuffle(false) restores exact originalQueue order while keeping active cursor', () {
      final manager = InternalQueueManager<String>(random: Random(100));
      manager.setQueue(testItems, startIndex: 2);
      expect(manager.currentIndex, equals(2));
      expect(manager.currentItem?.data, equals('Track 2'));

      // Shuffle while on Track 2
      manager.setShuffle(true);
      expect(manager.isShuffled, isTrue);
      expect(manager.currentIndex, equals(0));
      expect(manager.currentItem?.data, equals('Track 2'));

      // Advance to next song in shuffle
      manager.jumpTo(4);
      final playingInShuffle = manager.currentItem!;
      final expectedOriginalIndex = int.parse(playingInShuffle.data!.split(' ').last);

      // Unshuffle
      manager.setShuffle(false);
      expect(manager.isShuffled, isFalse);
      expect(manager.currentIndex, equals(expectedOriginalIndex));
      expect(manager.currentItem?.data, equals(playingInShuffle.data));

      // Verify activeQueue matches originalQueue exactly
      for (var i = 0; i < testItems.length; i++) {
        expect(manager.activeQueue[i].sourceKey, equals(testItems[i].sourceKey));
      }
    });
  });

  group('InternalQueueManager - Reactive nextItemStream & Auto-Crossfade Invalidation', () {
    late InternalQueueManager<String> manager;
    late List<EngineItem<String>> testItems;

    setUp(() {
      manager = InternalQueueManager<String>();
      testItems = List.generate(
        6,
        (i) => EngineItem<String>(
          source: AudioSource.file('/music/track_$i.mp3'),
          data: 'Track $i',
        ),
      );
      manager.setQueue(testItems, startIndex: 0);
    });

    tearDown(() async {
      await manager.dispose();
    });

    test('peekNext(distinct: true) returns next track and emits to nextItemStream', () {
      expect(manager.peekNext(distinct: true)?.data, equals('Track 1'));
      expect(manager.hasNextDifferent, isTrue);
    });

    test('far mutations (reorder(4,5), removeAt(4)) do NOT change peekNext(distinct: true)', () {
      final emittedCandidates = <EngineItem<String>?>[];
      final sub = manager.nextItemStream.listen(emittedCandidates.add);

      // Mutate tracks far away from current (0) and next (1)
      manager.reorder(4, 5);
      expect(manager.peekNext(distinct: true)?.data, equals('Track 1'));

      manager.remove(4);
      expect(manager.peekNext(distinct: true)?.data, equals('Track 1'));

      // Because next candidate did not change from Track 1, stream should not emit duplicate events
      expect(emittedCandidates.isEmpty, isTrue);
      sub.cancel();
    });

    test('near mutations that alter peekNext trigger nextItemStream', () {
      final emittedCandidates = <EngineItem<String>?>[];
      final sub = manager.nextItemStream.listen(emittedCandidates.add);

      // 1. insertNext inserts immediately after 0, displacing Track 1
      final inserted = EngineItem<String>(
        source: AudioSource.file('/music/urgent.mp3'),
        data: 'Urgent Track',
      );
      manager.insertNext(inserted);
      expect(manager.peekNext(distinct: true)?.data, equals('Urgent Track'));

      // 2. removeAt(1) removes the urgent track, restoring Track 1
      manager.remove(1);
      expect(manager.peekNext(distinct: true)?.data, equals('Track 1'));

      // 3. reorder(1, 4) moves Track 1 away; new next is Track 2
      manager.reorder(1, 4);
      expect(manager.peekNext(distinct: true)?.data, equals('Track 2'));

      // 4. setLoopMode(LoopMode.one) invalidates distinct next item (returns null)
      manager.setLoopMode(LoopMode.one);
      expect(manager.peekNext(distinct: true), isNull);

      // 5. setLoopMode(LoopMode.off) restores candidate
      manager.setLoopMode(LoopMode.off);
      expect(manager.peekNext(distinct: true)?.data, equals('Track 2'));

      expect(emittedCandidates.length, equals(5));
      expect(emittedCandidates[0]?.data, equals('Urgent Track'));
      expect(emittedCandidates[1]?.data, equals('Track 1'));
      expect(emittedCandidates[2]?.data, equals('Track 2'));
      expect(emittedCandidates[3], isNull);
      expect(emittedCandidates[4]?.data, equals('Track 2'));

      sub.cancel();
    });

    test('commitNext only advances if expected matches candidate', () {
      final expected = manager.peekNext(distinct: true)!;
      final fake = EngineItem<String>(
        source: AudioSource.file('/music/fake.mp3'),
        data: 'Fake',
      );

      // Attempt commit with wrong item -> returns null and does not advance
      expect(manager.commitNext(fake), isNull);
      expect(manager.currentIndex, equals(0));

      // Commit with expected candidate -> advances
      final committed = manager.commitNext(expected);
      expect(committed, isNotNull);
      expect(committed?.data, equals(expected.data));
      expect(manager.currentIndex, equals(1));
    });
  });

  group('InternalQueueManager - Proactive Lookahead Infinite Mix', () {
    test('calls infiniteMixProvider when cursor reaches last track in LoopMode.off', () async {
      var fetchCalls = 0;
      Future<List<EngineItem<String>>> provider(int count) async {
        fetchCalls++;
        return [
          EngineItem<String>(
            source: AudioSource.file('/music/mix_1.mp3'),
            data: 'Mix 1',
          ),
          EngineItem<String>(
            source: AudioSource.file('/music/mix_2.mp3'),
            data: 'Mix 2',
          ),
        ];
      }

      final manager = InternalQueueManager<String>(
        infiniteMixProvider: provider,
      );
      manager.setInfiniteMix(true);

      // Queue of 2 items
      manager.setQueue([
        EngineItem<String>(source: AudioSource.file('/music/1.mp3'), data: '1'),
        EngineItem<String>(source: AudioSource.file('/music/2.mp3'), data: '2'),
      ], startIndex: 0);

      expect(fetchCalls, equals(0));
      expect(manager.hasNext, isTrue);

      // Move to track 1 (the last track)
      await manager.next(isManual: true);
      expect(manager.currentIndex, equals(1));

      // Give microtask queue time to execute lookahead prefetch
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(fetchCalls, equals(1));
      // Queue length should have grown by 2 mix tracks
      expect(manager.length, equals(4));
      expect(manager.peekNext(distinct: true)?.data, equals('Mix 1'));

      await manager.dispose();
    });

    test('empty list marks _prefetchExhausted = true and avoids infinite loop', () async {
      var fetchCalls = 0;
      Future<List<EngineItem<String>>> provider(int count) async {
        fetchCalls++;
        return <EngineItem<String>>[]; // empty
      }

      final manager = InternalQueueManager<String>(
        infiniteMixProvider: provider,
      );
      manager.setInfiniteMix(true);

      manager.setQueue([
        EngineItem<String>(source: AudioSource.file('/music/1.mp3'), data: '1'),
      ], startIndex: 0);

      // Last track triggers lookahead prefetch
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fetchCalls, equals(1));

      // Attempting next should return null and not trigger infinite loops
      final next = await manager.next(isManual: true);
      expect(next, isNull);
      expect(fetchCalls, equals(1));

      await manager.dispose();
    });
  });

  group('InternalQueueManager - Navigation, Restart Thresholds & LiveStreams', () {
    late InternalQueueManager<String> manager;

    setUp(() {
      manager = InternalQueueManager<String>();
      manager.setQueue([
        EngineItem<String>(source: AudioSource.file('/music/1.mp3'), data: '1'),
        EngineItem<String>(source: AudioSource.file('/music/2.mp3'), data: '2'),
        EngineItem<String>(source: AudioSource.file('/music/3.mp3'), data: '3'),
      ], startIndex: 1);
    });

    tearDown(() async {
      await manager.dispose();
    });

    test('previous() returns prior track when position <= restartThreshold (3s)', () {
      final prev = manager.previous(
        position: const Duration(seconds: 2),
        isLiveStream: false,
      );
      expect(prev, isNotNull);
      expect(prev?.data, equals('1'));
      expect(manager.currentIndex, equals(0));
    });

    test('previous() returns null (to restart track) when position > restartThreshold (3s)', () {
      final prev = manager.previous(
        position: const Duration(seconds: 4),
        isLiveStream: false,
      );
      expect(prev, isNull);
      expect(manager.currentIndex, equals(1)); // did not step back
    });

    test('previous() on livestream bypasses restartThreshold and steps back', () {
      final prev = manager.previous(
        position: const Duration(hours: 5), // long running live stream
        isLiveStream: true,
      );
      expect(prev, isNotNull);
      expect(prev?.data, equals('1'));
      expect(manager.currentIndex, equals(0));
    });

    test('previous() at index 0 wraps to end in LoopMode.all', () {
      manager.jumpTo(0);
      manager.setLoopMode(LoopMode.all);

      final prev = manager.previous(
        position: const Duration(seconds: 1),
        isLiveStream: false,
      );
      expect(prev?.data, equals('3'));
      expect(manager.currentIndex, equals(2));
    });

    test('next() at end wraps to 0 in LoopMode.all', () async {
      manager.jumpTo(2);
      manager.setLoopMode(LoopMode.all);

      final next = await manager.next(isManual: true);
      expect(next?.data, equals('1'));
      expect(manager.currentIndex, equals(0));
    });

    test('next() in LoopMode.one returns current track on natural completion (isManual: false)', () async {
      manager.setLoopMode(LoopMode.one);
      final current = manager.currentItem;

      final next = await manager.next(isManual: false);
      expect(next?.data, equals(current?.data));
    });
  });
}
