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
      isDefault: true,
      isAuto: false,
    );
    expect(deviceWithNoType.id, equals('2'));
    expect(deviceWithNoType.type, isNull);
    expect(deviceWithNoType.toString(), contains('Built-in Speaker'));

    const deviceWithType = AudioDevice(
      id: '14',
      name: 'Bluetooth Headset',
      isDefault: false,
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
    expect(AudioDevice.auto.toString(), contains('auto'));
  });
}

