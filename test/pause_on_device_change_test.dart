import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  group('AudioDevice effectiveId and endpoint resolution', () {
    test('AudioDevice.auto has canonical auto id and empty effectiveId by default', () {
      expect(AudioDevice.auto.id, equals('auto'));
      expect(AudioDevice.auto.isAuto, isTrue);
      expect(AudioDevice.auto.effectiveId, isEmpty);
    });

    test('isSameEndpoint returns true for matching effectiveIds regardless of auto', () {
      const dev1 = AudioDevice(
        id: 'auto',
        effectiveId: 'endpoint-speakers-01',
        name: 'SYSTEM DEFAULT',
        isAuto: true,
      );
      const dev2 = AudioDevice(
        id: 'endpoint-speakers-01',
        effectiveId: 'endpoint-speakers-01',
        name: 'Speakers',
      );
      const dev3 = AudioDevice(
        id: 'endpoint-headphones-02',
        effectiveId: 'endpoint-headphones-02',
        name: 'Headphones',
      );

      expect(dev1.isSameEndpoint(dev2), isTrue);
      expect(dev2.isSameEndpoint(dev1), isTrue);
      expect(dev1.isSameEndpoint(dev3), isFalse);
      expect(dev2.isSameEndpoint(dev3), isFalse);
    });

    test('isSameEndpoint falls back to id / equality if effectiveId is empty', () {
      const devA = AudioDevice(id: 'devA', name: 'Device A');
      const devA2 = AudioDevice(id: 'devA', name: 'Device A (copy)');
      const devB = AudioDevice(id: 'devB', name: 'Device B');

      expect(devA.isSameEndpoint(devA2), isTrue);
      expect(devA.isSameEndpoint(devB), isFalse);
    });

    test('AudioDevice equality treats both id: auto and isAuto templates as equal', () {
      const autoEmpty = AudioDevice(id: '', name: 'SYSTEM DEFAULT', isAuto: true);
      const autoNamed = AudioDevice(id: 'auto', name: 'SYSTEM DEFAULT', isAuto: true);

      expect(autoEmpty == AudioDevice.auto, isTrue);
      expect(autoNamed == AudioDevice.auto, isTrue);
      expect(autoEmpty == autoNamed, isTrue);
    });
  });

  group('MiniaudioPlayer pauseOnDeviceChange configuration and reactivity', () {
    late MiniaudioPlayer player;

    tearDown(() async {
      await player.dispose();
    });

    test('pauseOnDeviceChange defaults to false', () {
      player = MiniaudioPlayer();
      expect(player.state.pauseOnDeviceChange, isFalse);
    });

    test('pauseOnDeviceChange constructor option sets initial state', () {
      player = MiniaudioPlayer(pauseOnDeviceChange: true);
      expect(player.state.pauseOnDeviceChange, isTrue);
    });

    test('action.setPauseOnDeviceChange updates state and emits to stream', () async {
      player = MiniaudioPlayer(pauseOnDeviceChange: false);
      expect(player.state.pauseOnDeviceChange, isFalse);

      final events = <bool>[];
      final sub = player.stream.pauseOnDeviceChange.listen(events.add);

      player.action.setPauseOnDeviceChange(true);
      await pumpEventQueue();
      expect(player.state.pauseOnDeviceChange, isTrue);
      expect(events, equals([true]));

      // Redundant set does not emit duplicate
      player.action.setPauseOnDeviceChange(true);
      await pumpEventQueue();
      expect(events, equals([true]));

      player.action.setPauseOnDeviceChange(false);
      await pumpEventQueue();
      expect(player.state.pauseOnDeviceChange, isFalse);
      expect(events, equals([true, false]));

      await sub.cancel();
    });
  });

  group('MiniaudioEngine pauseOnDeviceChange orchestration', () {
    late MiniaudioEngine engine;

    tearDown(() async {
      await engine.dispose();
    });

    test('pauseOnDeviceChange defaults to false and propagates to decks', () {
      engine = MiniaudioEngine();
      expect(engine.state.pauseOnDeviceChange, isFalse);
    });

    test('pauseOnDeviceChange constructor option propagates to child decks', () {
      engine = MiniaudioEngine(pauseOnDeviceChange: true);
      expect(engine.state.pauseOnDeviceChange, isTrue);
    });

    test('action.setPauseOnDeviceChange updates engine state and emits to stream', () async {
      engine = MiniaudioEngine(pauseOnDeviceChange: false);
      expect(engine.state.pauseOnDeviceChange, isFalse);

      final events = <bool>[];
      final sub = engine.stream.pauseOnDeviceChange.listen(events.add);

      engine.action.setPauseOnDeviceChange(true);
      await pumpEventQueue();
      expect(engine.state.pauseOnDeviceChange, isTrue);
      expect(events, equals([true]));

      // Redundant set does not emit duplicate
      engine.action.setPauseOnDeviceChange(true);
      await pumpEventQueue();
      expect(events, equals([true]));

      engine.action.setPauseOnDeviceChange(false);
      await pumpEventQueue();
      expect(engine.state.pauseOnDeviceChange, isFalse);
      expect(events, equals([true, false]));

      await sub.cancel();
    });
  });

  group('Audio device endpoint comparison logic during fallback scenarios', () {
    test('Fallback landing on SAME endpoint does not pause playback', () {
      // Scenario: Currently playing on Endpoint 3
      const currentActiveEndpoint = AudioDevice(
        id: '3',
        effectiveId: 'hw-endpoint-3',
        name: 'Device 3',
      );

      // Attempt to switch to 4, which fails and falls back to Default
      // In this system, Default happens to be Endpoint 3
      const fallbackResolvedEndpoint = AudioDevice(
        id: 'auto',
        effectiveId: 'hw-endpoint-3',
        name: 'SYSTEM DEFAULT',
        isAuto: true,
      );

      final samePhysicalEndpoint = currentActiveEndpoint.isSameEndpoint(fallbackResolvedEndpoint);
      expect(samePhysicalEndpoint, isTrue,
          reason: 'Fallback landed on the same physical hardware endpoint; playback must NOT pause.');
    });

    test('Fallback landing on DIFFERENT endpoint triggers pause condition', () {
      // Scenario: Currently playing on Endpoint 3 (e.g. bluetooth or headphones)
      const currentActiveEndpoint = AudioDevice(
        id: '3',
        effectiveId: 'hw-endpoint-3',
        name: 'Device 3',
      );

      // Attempt to switch to 4, which fails and falls back to Default (Device 1, e.g. Speakers)
      const fallbackResolvedEndpoint = AudioDevice(
        id: 'auto',
        effectiveId: 'hw-endpoint-1',
        name: 'SYSTEM DEFAULT',
        isAuto: true,
      );

      final samePhysicalEndpoint = currentActiveEndpoint.isSameEndpoint(fallbackResolvedEndpoint);
      expect(samePhysicalEndpoint, isFalse,
          reason: 'Fallback landed on a different physical endpoint; pauseOnDeviceChange must pause.');
    });
  });
}
