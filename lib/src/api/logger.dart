import 'miniaudio_player.dart';

/// Callback signature for intercepting or redirecting [MapLogger] output.
///
/// Receives the diagnostic severity [level] and formatted log [message].
typedef MiniaudioLogCallback = void Function(
  MiniaudioLogLevel level,
  String message,
);

/// Centralized logging dispatcher for the MiniaudioPlayer Dart layer.
///
/// Output respects [MiniaudioPlayerGlobalConfig.logLevel]. If a custom
/// [MiniaudioPlayerGlobalConfig.onLog] callback is provided, logs are
/// forwarded to it instead of the default console output.
abstract final class MapLogger {
  /// Checks whether diagnostic messages at [level] are enabled.
  static bool isEnabled(MiniaudioLogLevel level) {
    if (level == MiniaudioLogLevel.none) return false;
    final currentLevel = MiniaudioPlayer.globalConfig.logLevel;
    return currentLevel.value >= level.value;
  }

  /// Dispatches a diagnostic [message] at the specified [level].
  static void log(MiniaudioLogLevel level, String message) {
    if (!isEnabled(level)) return;

    final customHandler = MiniaudioPlayerGlobalConfig.onLog;
    if (customHandler != null) {
      customHandler(level, message);
      return;
    }

    final tag = switch (level) {
      MiniaudioLogLevel.error => 'ERROR',
      MiniaudioLogLevel.warning => 'WARN',
      MiniaudioLogLevel.info => 'INFO',
      MiniaudioLogLevel.debug => 'DEBUG',
      MiniaudioLogLevel.verbose => 'VERBOSE',
      MiniaudioLogLevel.none => 'LOG',
    };

    // ignore: avoid_print
    print('[miniaudio_player][$tag] $message');
  }

  /// Logs an error [message] at [MiniaudioLogLevel.error] (`level = 1`).
  static void error(String message) => log(MiniaudioLogLevel.error, message);

  /// Logs a non-fatal warning [message] at [MiniaudioLogLevel.warning] (`level = 2`).
  static void warn(String message) => log(MiniaudioLogLevel.warning, message);

  /// Emits an important API misuse or platform-compatibility warning [message].
  ///
  /// Logs even when [MiniaudioLogLevel] defaults to [MiniaudioLogLevel.none],
  /// forwarding to [MiniaudioPlayerGlobalConfig.onLog] if installed.
  static void warnImportant(String message) {
    if (isEnabled(MiniaudioLogLevel.warning)) {
      warn(message);
      return;
    }
    final customHandler = MiniaudioPlayerGlobalConfig.onLog;
    if (customHandler != null) {
      customHandler(MiniaudioLogLevel.warning, message);
      return;
    }
    // ignore: avoid_print
    print('[miniaudio_player][WARN] $message');
  }

  /// Emits an important API usage [message] at info level.
  ///
  /// Logs even when [MiniaudioLogLevel] defaults to [MiniaudioLogLevel.none],
  /// forwarding to [MiniaudioPlayerGlobalConfig.onLog] if installed.
  static void infoImportant(String message) {
    if (isEnabled(MiniaudioLogLevel.info)) {
      info(message);
      return;
    }
    final customHandler = MiniaudioPlayerGlobalConfig.onLog;
    if (customHandler != null) {
      customHandler(MiniaudioLogLevel.info, message);
      return;
    }
    // ignore: avoid_print
    print('[miniaudio_player][INFO] $message');
  }

  /// Logs a standardized `[INFO]` notice when an unnecessary Web `opfs://` prefix is used.
  ///
  /// Reports the original [rawInput] and, when provided, the resolved [canonicalPath].
  static void logRedundantOpfsPrefix(
    String rawInput, {
    String? canonicalPath,
  }) {
    final normalizedNote = (canonicalPath != null && canonicalPath.isNotEmpty)
        ? ' (normalized to "$canonicalPath")'
        : '';
    infoImportant(
      'The "opfs://" prefix in "$rawInput" is unnecessary on Web: relative '
      'and absolute paths without a URI scheme already resolve automatically '
      'to OPFS$normalizedNote.',
    );
  }

  /// Logs a high-level lifecycle or state change [message] (`level = 3`).
  static void info(String message) => log(MiniaudioLogLevel.info, message);

  /// Logs a debug action or configuration change [message] (`level = 4`).
  static void debug(String message) => log(MiniaudioLogLevel.debug, message);

  /// Logs a verbose telemetry or stream diagnostic [message] (`level = 5`).
  static void verbose(String message) =>
      log(MiniaudioLogLevel.verbose, message);
}
