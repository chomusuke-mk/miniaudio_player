import 'dart:convert';
import 'dart:ffi';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../api/audio_device.dart';

/// Error and status codes matching `miniaudio_player_result_t` in `src/miniaudio_player.h`.
abstract final class MapResult {
  static const int success = 0;
  static const int errorGeneric = -1;
  static const int errorInvalidArgs = -2;
  static const int errorOutOfMemory = -3;
  static const int errorEngineInit = -4;
  static const int errorFileNotFound = -5;
  static const int errorDecodeFailed = -6;
  static const int errorInvalidState = -7;
  static const int errorSeekFailed = -8;
  static const int errorNodeFailed = -9;
  static const int errorUnsupported = -10;

  static String describe(int code) {
    switch (code) {
      case success:
        return 'Success';
      case errorGeneric:
        return 'Generic native error';
      case errorInvalidArgs:
        return 'Invalid argument(s)';
      case errorOutOfMemory:
        return 'Native memory allocation failed';
      case errorEngineInit:
        return 'Audio engine initialization failed';
      case errorFileNotFound:
        return 'Audio file not found';
      case errorDecodeFailed:
        return 'Audio decoding failed';
      case errorInvalidState:
        return 'Player in invalid state for operation';
      case errorSeekFailed:
        return 'Seek failed';
      case errorNodeFailed:
        return 'DSP audio node operation failed';
      case errorUnsupported:
        return 'Unsupported audio format or operation';
      default:
        return 'Unknown native error code ($code)';
    }
  }
}

/// Constants matching `miniaudio_player_playback_state_t`.
abstract final class MapPlaybackState {
  static const int stopped = 0;
  static const int playing = 1;
  static const int paused = 2;
  static const int completed = 3;
  static const int buffering = 4;
  static const int error = 5;

  static String describe(int state) {
    switch (state) {
      case stopped:
        return 'Stopped';
      case playing:
        return 'Playing';
      case paused:
        return 'Paused';
      case completed:
        return 'Completed';
      case buffering:
        return 'Buffering';
      case error:
        return 'Error';
      default:
        return 'Unknown state ($state)';
    }
  }
}

/// Constants matching `miniaudio_player_log_level_t`.
abstract final class MapLogLevel {
  static const int none = 0;
  static const int error = 1;
  static const int warning = 2;
  static const int info = 3;
  static const int debug = 4;
  static const int verbose = 5;
}

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
    final devName = _charArrayToString(name, 256);
    return AudioDevice(
      id: devId,
      name: devName.isEmpty ? 'Default' : devName,
      isDefault: is_default != 0,
      isAuto: is_auto != 0,
    );
  }
}
