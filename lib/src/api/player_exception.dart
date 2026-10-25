/// Exception thrown by [MiniaudioPlayer] on native or runtime errors.
class MiniaudioPlayerException implements Exception {
  final String message;
  final int? errorCode;
  final String? details;

  const MiniaudioPlayerException(this.message, {this.errorCode, this.details});

  @override
  String toString() {
    if (errorCode != null) {
      return 'MiniaudioPlayerException(code: $errorCode): $message';
    }
    return 'MiniaudioPlayerException: $message';
  }
}

/// Error and status codes matching `miniaudio_player_result_t`.
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
  static const int errorAccessDenied = -11;
  static const int errorBusy = -12;

  static String describe(int code) {
    switch (code) {
      case success:
        return 'Success';
      case errorGeneric:
        return 'Generic error';
      case errorInvalidArgs:
        return 'Invalid argument(s)';
      case errorOutOfMemory:
        return 'Memory allocation failed';
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
      case errorAccessDenied:
        return 'Access denied or permission failure';
      case errorBusy:
        return 'Buffer full or device busy';
      default:
        return 'Unknown error code ($code)';
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
  static const int opening = 6;

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
      case opening:
        return 'Opening';
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
