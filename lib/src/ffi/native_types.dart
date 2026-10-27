import 'dart:convert';
import 'dart:ffi';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../api/audio_device.dart';

export '../api/player_exception.dart';

// Aliases to generated native structs
typedef MiniaudioPlayerEqualizerParamsC =
    native.miniaudio_player_equalizer_params_t;
typedef MiniaudioDeviceInfoC = native.miniaudio_device_info_t;
typedef MiniaudioPlayerStatusC = native.miniaudio_player_status_t;
typedef MiniaudioPlayerConfigC = native.miniaudio_player_config_t;

String _charArrayToString(Array<Char> array, int length) {
  final bytes = <int>[];
  for (var i = 0; i < length; i++) {
    final b = array[i];
    if (b == 0) break;
    bytes.add(b & 0xFF);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

extension MiniaudioDeviceInfoCX on native.miniaudio_device_info_t {
  AudioDevice toAudioDevice() {
    final devId = _charArrayToString(id, 516);
    final effId = _charArrayToString(effective_id, 516);
    final devName = _charArrayToString(name, 256);
    final isAutoDev = is_auto != 0;

    if (isAutoDev) {
      return AudioDevice(
        id: 'auto',
        effectiveId: effId,
        name: 'SYSTEM DEFAULT',
        resolvedName: devName.isNotEmpty ? devName : null,
        isAuto: true,
      );
    }

    return AudioDevice(
      id: devId,
      effectiveId: effId.isNotEmpty ? effId : devId,
      name: devName.isEmpty ? 'Default' : devName,
      isAuto: false,
    );
  }
}
