import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MiniaudioEngine State, Action & Stream Telemetry', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>();
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test('EngineState reflects initial idle state correctly', () {
      final state = engine.state;
      expect(state.buffering, isFalse);
      expect(state.bufferedPosition, Duration.zero);
      expect(state.bufferedPercentage, 0.0);
      expect(state.bufferedRange, const BufferedRange());
      expect(state.bufferSize, 0);

      // Active deck properties
      expect(state.sampleRate, anyOf(0, 44100, 48000));
      expect(state.channels, anyOf(0, 1, 2));
      expect(state.bitrate, 0);
      expect(state.trackMetadata, isNull);
      expect(state.playbackState, PlaybackState.stopped);
      expect(state.isPaused, isFalse);
      expect(state.isStopped, isTrue);
      expect(state.isError, isFalse);
      expect(state.skipSilence, isFalse);
      expect(state.preamp, 0.0);
    });

    test('action.setBufferSize updates bufferSize in state', () async {
      expect(engine.state.bufferSize, 0);

      await engine.action.setBufferSize(512);
      expect(engine.state.bufferSize, 512);

      await engine.action.setBufferSize(1024);
      expect(engine.state.bufferSize, 1024);
    });

    test('setIcyMeta and probeTail execute safely on engine.action without throwing', () {
      final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
      expect(() => engine.action.setIcyMeta(testData), returnsNormally);
      expect(() => engine.action.probeTail(testData, 128), returnsNormally);
    });

    test('Buffer size stream emits when buffer size is changed', () async {
      final bufferSizeEvents = <int>[];
      final sub = engine.stream.bufferSize.listen(bufferSizeEvents.add);

      await engine.action.setBufferSize(256);
      await engine.action.setBufferSize(1024);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(bufferSizeEvents, containsAllInOrder([256, 1024]));
    });
  });
}
