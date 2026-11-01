import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  test('invoke native function via native assets', () {
    final devices = MiniaudioPlayer.getAudioDevicesSync();
    expect(devices, isNotEmpty);
  });

  test('AudioDevice correctly handles UTF-8 device names with accented characters', () {
    const deviceName = 'Audio Interno Estéreo analógico';
    const device = AudioDevice(
      id: 'hw_1',
      name: deviceName,
      isAuto: false,
    );
    expect(device.name, equals(deviceName));
  });

  test('AudioDevice correctly handles Android device ID and type metadata', () {
    const deviceWithNoType = AudioDevice(
      id: '2',
      name: 'Built-in Speaker',
      isAuto: false,
    );
    expect(deviceWithNoType.id, equals('2'));
    expect(deviceWithNoType.type, isNull);
    expect(deviceWithNoType.toString(), contains('Built-in Speaker'));

    const deviceWithType = AudioDevice(
      id: '14',
      name: 'Bluetooth Headset',
      isAuto: false,
      type: 7, // TYPE_BLUETOOTH_SCO
    );
    expect(deviceWithType.id, equals('14'));
    expect(deviceWithType.type, equals(7));
    expect(deviceWithType.toString(), contains('type: 7'));
  });

  test('AudioDevice.auto static constant has auto ID and isAuto true', () {
    expect(AudioDevice.auto.id, equals('auto'));
    expect(AudioDevice.auto.isAuto, isTrue);
    expect(AudioDevice.auto.effectiveId, isEmpty);
    expect(AudioDevice.auto.name, equals('SYSTEM DEFAULT'));
    expect(AudioDevice.auto.toString(), contains('auto'));
  });

  test('AudioDevice displayName uses defaultDeviceDisplayNameResolver for auto devices', () {
    const autoDevice = AudioDevice(
      id: '',
      name: 'SYSTEM DEFAULT',
      resolvedName: 'Speakers (Realtek)',
      isAuto: true,
    );
    expect(autoDevice.displayName, equals('System Default (Speakers (Realtek))'));

    // Custom resolver
    MiniaudioPlayer.config(
      defaultDeviceDisplayNameResolver: (resolved) =>
          resolved.isEmpty ? 'Predeterminado' : 'Predeterminado: $resolved',
    );
    expect(autoDevice.displayName, equals('Predeterminado: Speakers (Realtek)'));

    // Non-auto device returns name directly
    const hardwareDevice = AudioDevice(
      id: 'hw_1',
      name: 'USB Headphones',
    );
    expect(hardwareDevice.displayName, equals('USB Headphones'));

    // Reset resolver to default
    MiniaudioPlayer.config(
      defaultDeviceDisplayNameResolver: (resolved) {
        final clean = resolved.trim();
        return clean.isEmpty ? 'System Default' : 'System Default ($clean)';
      },
    );
  });

  test('AudioDevice equality is based on ID', () {
    const devA = AudioDevice(
      id: 'hw_123',
      name: 'Speakers A',
    );
    const devB = AudioDevice(
      id: 'hw_123',
      name: 'Speakers A Renamed',
    );
    const devC = AudioDevice(
      id: 'hw_999',
      name: 'Headphones',
    );
    expect(devA, equals(devB));
    expect(devA == devC, isFalse);

    const autoA = AudioDevice(
      id: '',
      name: 'SYSTEM DEFAULT',
      resolvedName: 'Speakers',
      isAuto: true,
    );
    const autoB = AudioDevice(
      id: '',
      name: 'SYSTEM DEFAULT',
      resolvedName: 'Headphones',
      isAuto: true,
    );
    expect(autoA, equals(autoB));
    expect(autoA, equals(AudioDevice.auto));
  });

  test('MiniaudioPlayer.getAudioDevices and getAudioDevicesSync enumerate devices', () async {
    final asyncDevices = await MiniaudioPlayer.getAudioDevices();
    final syncDevices = MiniaudioPlayer.getAudioDevicesSync();

    expect(asyncDevices, isNotEmpty);
    expect(syncDevices, isNotEmpty);
    expect(asyncDevices.first, equals(AudioDevice.auto));
    expect(syncDevices.first, equals(AudioDevice.auto));
  });

  test('MiniaudioPlayer.getAudioDevicesStream returns a broadcast stream', () {
    final stream = MiniaudioPlayer.getAudioDevicesStream();
    expect(stream.isBroadcast, isTrue);
  });

  test('MiniaudioPlayer.getAudioDevicesStream handles listen and cancel lifecycle cleanly', () async {
    final stream = MiniaudioPlayer.getAudioDevicesStream();
    final sub1 = stream.listen((_) {});
    final sub2 = stream.listen((_) {});
    await sub1.cancel();
    await sub2.cancel();

    // Re-listening should smoothly recreate the native callback
    final sub3 = stream.listen((_) {});
    await sub3.cancel();
  });

  test('cbr_noxing.mp3 memory playback, seek and duration', () async {
    final file = File('example/assets/music/cbr_noxing.mp3');
    expect(file.existsSync(), isTrue);
    final bytes = await file.readAsBytes();

    final player = MiniaudioPlayer(AudioSource(bytes));
    try {
      await player.waitUntilOpen;
      expect(player.state.duration.inMilliseconds, inInclusiveRange(10000, 10100));

      await player.action.play();
      expect(player.state.playing, isTrue);

      await player.action.seek(const Duration(milliseconds: 2000));
      expect(player.state.position.inMilliseconds, inInclusiveRange(1900, 2100));

      await player.action.seek(const Duration(milliseconds: 4000));
      expect(player.state.position.inMilliseconds, inInclusiveRange(3900, 4100));

      await player.action.seek(Duration.zero);
      expect(player.state.position.inMilliseconds, inInclusiveRange(0, 200));

      // Wait a moment while playing and verify it advances smoothly without jumping to end
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(player.state.position.inMilliseconds, inInclusiveRange(300, 1000));
      expect(player.state.playing, isTrue);

      // Seek to 3.5 seconds during active playback
      await player.action.seek(const Duration(milliseconds: 3500));
      expect(player.state.position.inMilliseconds, inInclusiveRange(3400, 3600));

      await Future<void>.delayed(const Duration(milliseconds: 500));
      // Must NOT jump to EOF (10031ms)
      expect(player.state.position.inMilliseconds, inInclusiveRange(3800, 4500));
      expect(player.state.playing, isTrue);

      await player.action.pause();
      expect(player.state.playing, isFalse);
    } finally {
      await player.dispose();
    }
  });

  test('switching memory tracks does not crash and updates correctly', () async {
    final file1 = File('example/assets/music/cbr_noxing.mp3');
    final file2 = File('example/assets/music/salida.mp3');
    expect(file1.existsSync(), isTrue);
    expect(file2.existsSync(), isTrue);

    final bytes1 = await file1.readAsBytes();
    final bytes2 = await file2.readAsBytes();

    final player = MiniaudioPlayer(AudioSource(bytes1));
    try {
      // 1. Open track 1
      await player.waitUntilOpen;
      expect(player.state.duration.inMilliseconds, inInclusiveRange(10000, 10100));
      await player.action.play();
      expect(player.state.playing, isTrue);

      // 2. Switch directly to track 2 while playing (previously caused crash/segfault)
      await player.action.open(AudioSource(bytes2));
      expect(player.state.duration.inMilliseconds, inInclusiveRange(65000, 72000));
      await player.action.play();
      expect(player.state.playing, isTrue);

      // 3. Switch back to track 1
      await player.action.open(AudioSource(bytes1));
      expect(player.state.duration.inMilliseconds, inInclusiveRange(10000, 10100));
    } finally {
      await player.dispose();
    }
  });
}
