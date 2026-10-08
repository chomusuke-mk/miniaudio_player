import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/miniaudio_player_bindings_generated.dart'
    as bindings;
import 'package:miniaudio_player/src/ffi/native_types.dart';

void main() {
  test('invoke native function via native assets', () {
    final level = bindings.miniaudio_player_get_log_level();
    expect(level, isA<int>());
  });

  test('correctly decodes UTF-8 device names with accented characters', () {
    final devPtr = calloc<bindings.miniaudio_device_info_t>();
    try {
      const deviceName = 'Audio Interno Estéreo analógico';
      final encoded = utf8.encode(deviceName);
      for (var i = 0; i < encoded.length; i++) {
        devPtr.ref.name[i] = encoded[i] > 127 ? encoded[i] - 256 : encoded[i];
      }
      devPtr.ref.name[encoded.length] = 0;

      final device = devPtr.ref.toAudioDevice();
      expect(device.name, equals(deviceName));
    } finally {
      calloc.free(devPtr);
    }
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

  test('AudioDevice.auto static constant has empty ID and isAuto true', () {
    expect(AudioDevice.auto.id, isEmpty);
    expect(AudioDevice.auto.isAuto, isTrue);
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
}
