/// Exception thrown by [MiniaudioPlayer] on native or runtime errors.
class MiniaudioPlayerException implements Exception {
  /// The diagnostic error message describing the failure.
  final String message;

  /// The native numeric error code, if provided by the underlying engine.
  final int? errorCode;

  /// Optional raw details or stack information from the native layer.
  final String? details;

  /// Creates a [MiniaudioPlayerException] with a [message] and optional [errorCode] or [details].
  const MiniaudioPlayerException(this.message, {this.errorCode, this.details});

  static final RegExp _rustErrorCodeRegex = RegExp(r'error (-?\d+)');

  /// Constructs a deterministic [MiniaudioPlayerException] from a raw Rust/FFI exception.
  factory MiniaudioPlayerException.fromRustError(
    Object error, {
    String prefix = 'Operation failed',
    int defaultErrorCode = MapResult.errorGeneric,
  }) {
    if (error is MiniaudioPlayerException) return error;
    final raw = error.toString();
    final match = _rustErrorCodeRegex.firstMatch(raw);
    final code = match != null ? int.parse(match.group(1)!) : defaultErrorCode;
    return MiniaudioPlayerException(
      '$prefix (code $code): $raw',
      errorCode: code,
      details: raw,
    );
  }

  @override
  String toString() {
    if (errorCode != null) {
      return 'MiniaudioPlayerException(code: $errorCode): $message';
    }
    return 'MiniaudioPlayerException: $message';
  }
}

/// Exception thrown when attempting to play or manipulate an audio effect that is not loaded.
class AudioEffectNotFoundException extends MiniaudioPlayerException {
  /// The unique identifier of the missing audio effect.
  final String effectId;

  /// Creates an [AudioEffectNotFoundException] for the given [effectId].
  const AudioEffectNotFoundException(this.effectId)
      : super('Audio effect not found: $effectId', errorCode: MapResult.errorFileNotFound);
}

/// Exception thrown when loading an audio effect exceeds the configured RAM budget.
class RamBudgetExceededException extends MiniaudioPlayerException {
  /// The size in bytes of the effect that exceeded the budget.
  final int requestedBytes;

  /// The maximum allowable RAM budget in bytes.
  final int maxBytes;

  /// Creates a [RamBudgetExceededException] indicating memory budget exhaustion.
  const RamBudgetExceededException(this.requestedBytes, this.maxBytes)
      : super('RAM budget exceeded: requested $requestedBytes bytes, max budget is $maxBytes bytes',
            errorCode: MapResult.errorOutOfMemory);
}

/// Error and status codes matching `miniaudio_player_result_t`.
abstract final class MapResult {
  /// Successful operation (`0`).
  static const int success = 0;

  /// Generic unspecified error (`-1`).
  static const int errorGeneric = -1;

  /// Invalid argument supplied (`-2`).
  static const int errorInvalidArgs = -2;

  /// Memory allocation failure (`-3`).
  static const int errorOutOfMemory = -3;

  /// Audio engine initialization failure (`-4`).
  static const int errorEngineInit = -4;

  /// Target audio file was not found (`-5`).
  static const int errorFileNotFound = -5;

  /// Audio decoding or demuxing failure (`-6`).
  static const int errorDecodeFailed = -6;

  /// Operation executed in an invalid player state (`-7`).
  static const int errorInvalidState = -7;

  /// Audio seek operation failed (`-8`).
  static const int errorSeekFailed = -8;

  /// DSP node or processing pipeline error (`-9`).
  static const int errorNodeFailed = -9;

  /// Unsupported audio format or feature (`-10`).
  static const int errorUnsupported = -10;

  /// Hardware device access permission denied (`-11`).
  static const int errorAccessDenied = -11;

  /// Audio buffer full or device busy (`-12`).
  static const int errorBusy = -12;

  /// Returns a human-readable English description of the given result [code].
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
  /// Stopped playback state (`0`).
  static const int stopped = 0;

  /// Actively playing state (`1`).
  static const int playing = 1;

  /// Paused playback state (`2`).
  static const int paused = 2;

  /// Completed playback state (`3`).
  static const int completed = 3;

  /// Buffering state waiting for audio data (`4`).
  static const int buffering = 4;

  /// Error state (`5`).
  static const int error = 5;

  /// Opening or probing audio source state (`6`).
  static const int opening = 6;

  /// Returns a human-readable English description of the given [state].
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
  /// Logging completely disabled (`0`).
  static const int none = 0;

  /// Critical errors only (`1`).
  static const int error = 1;

  /// Warnings and errors (`2`).
  static const int warning = 2;

  /// High-level informational events (`3`).
  static const int info = 3;

  /// Debug diagnostics (`4`).
  static const int debug = 4;

  /// Verbose telemetry diagnostics (`5`).
  static const int verbose = 5;
}
