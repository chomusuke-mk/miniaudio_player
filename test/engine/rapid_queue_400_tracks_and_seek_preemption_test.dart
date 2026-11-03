import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  group('Rapid 400 Track Queue Navigation & Seek Preemption', () {
    test('Queue of 400 tracks updates currentIndex immediately at t=0 on next()', () async {
      final engine = MiniaudioPlayer<String>();

      // Populate a 400 track queue
      final items = List.generate(
        400,
        (i) => AudioSource<String>(
          'test/fixtures/salida.wav',
          data: 'Track $i',
        ),
      );

      await engine.action.open(items, startIndex: 0);
      expect(engine.state.currentIndex, 0);

      // Perform 50 rapid sequential next() calls
      for (int expectedIndex = 1; expectedIndex <= 50; expectedIndex++) {
        await engine.action.next();
        expect(
          engine.state.currentIndex,
          expectedIndex,
          reason: 'currentIndex must update on next()',
        );
      }

      expect(engine.state.currentIndex, 50);
      await engine.dispose();
    });

    test('Rapid consecutive seeks preempt previous in-flight seeks without delay', () async {
      final player = MiniaudioPlayer(source: [AudioSource('test/fixtures/salida.wav')]);
      await player.action.play();

      final stopwatch = Stopwatch()..start();

      // Dispatch 30 consecutive seeks rapidly
      final futures = <Future<void>>[];
      for (int i = 1; i <= 30; i++) {
        final target = Duration(milliseconds: i * 50);
        futures.add(player.action.seek(target));
      }

      // All 30 seeks must complete without queuing or 25-second stalls
      await Future.wait(futures);
      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(3000),
        reason: '30 consecutive seeks must resolve in < 3s, not 25s stall',
      );

      await player.dispose();
    });
  });
}
