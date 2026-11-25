/// Exception thrown by `MiniaudioPlayer` on native or runtime errors.
class MiniaudioPlayerException implements Exception {
  /// The diagnostic error message describing the failure.
  final String message;

  /// The native numeric error code, if provided by the underlying engine.
  final int? errorCode;

  /// Optional raw details or stack information from the native layer.
  final String? details;

  /// Creates a [MiniaudioPlayerException] with a [message] and optional [errorCode] or [details].
  const MiniaudioPlayerException(this.message, {this.errorCode, this.details});

  /// Matches explicit `(code: N)` tags emitted by native Rust error formatting.
  static final RegExp _explicitCodeTagRegex = RegExp(r'\(code:\s*(-?\d+)\)');

  /// Fallback pattern matching `error N` or `code: N` tokens in native errors.
  static final RegExp _rustErrorCodeRegex =
      RegExp(r'(?:error|code:?)\s*(-?\d+)');

  /// Constructs a deterministic [MiniaudioPlayerException] from a raw Rust/FFI [error].
  ///
  /// Prepends [prefix] to the formatted message and falls back to [defaultErrorCode]
  /// if no numeric status code can be extracted from [error].
  factory MiniaudioPlayerException.fromRustError(
    Object error, {
    String prefix = 'Operation failed',
    int defaultErrorCode = MapResult.errorGeneric,
  }) {
    if (error is MiniaudioPlayerException) return error;
    final raw = error.toString();
    final explicitMatch = _explicitCodeTagRegex.allMatches(raw).lastOrNull;
    final match = explicitMatch ?? _rustErrorCodeRegex.firstMatch(raw);
    final code = match != null ? int.parse(match.group(1)!) : defaultErrorCode;
    return MiniaudioPlayerException(
      '$prefix (code $code): $raw',
      errorCode: code,
      details: raw,
    );
  }

  /// Returns a formatted diagnostic string including [errorCode] when present.
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
