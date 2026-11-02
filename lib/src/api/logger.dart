import 'miniaudio_player.dart';

/// Callback signature for intercepting or redirecting [MapLogger] output.
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

  /// Dispatches a diagnostic log message at [level].
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
      _ => 'LOG',
    };

    // ignore: avoid_print
    print('[miniaudio_player][$tag] $message');
  }

  /// Logs an error message (`level = 1`).
  static void error(String message) => log(MiniaudioLogLevel.error, message);

  /// Logs a non-fatal warning message (`level = 2`).
  static void warn(String message) => log(MiniaudioLogLevel.warning, message);

  /// Logs a high-level lifecycle or state change event (`level = 3`).
  static void info(String message) => log(MiniaudioLogLevel.info, message);

  /// Logs a debug action or configuration change (`level = 4`).
  static void debug(String message) => log(MiniaudioLogLevel.debug, message);

  /// Logs verbose, fine-grained telemetry or stream diagnostics (`level = 5`).
  static void verbose(String message) => log(MiniaudioLogLevel.verbose, message);
}
