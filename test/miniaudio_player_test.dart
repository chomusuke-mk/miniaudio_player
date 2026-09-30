import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
