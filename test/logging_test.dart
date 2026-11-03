import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  setUp(() {
    MiniaudioPlayer.resetGlobalConfig();
  });

  tearDown(() {
    MiniaudioPlayer.resetGlobalConfig();
  });

  group('MapLogger and Logging Configuration Tests', () {
    test('Default log level is none and logger is disabled', () {
      expect(
        MiniaudioPlayer.globalConfig.logLevel,
        equals(MiniaudioLogLevel.none),
      );
      expect(MapLogger.isEnabled(MiniaudioLogLevel.none), isFalse);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.error), isFalse);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.warning), isFalse);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.info), isFalse);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.debug), isFalse);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.verbose), isFalse);
    });

    test('MiniaudioPlayer.config updates logLevel and isEnabled correctly', () {
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.info);
      expect(
        MiniaudioPlayer.globalConfig.logLevel,
        equals(MiniaudioLogLevel.info),
      );
      expect(MapLogger.isEnabled(MiniaudioLogLevel.error), isTrue);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.warning), isTrue);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.info), isTrue);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.debug), isFalse);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.verbose), isFalse);
    });

    test('Verbose level enables all diagnostic levels', () {
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.verbose);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.error), isTrue);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.warning), isTrue);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.info), isTrue);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.debug), isTrue);
      expect(MapLogger.isEnabled(MiniaudioLogLevel.verbose), isTrue);
    });

    test('Custom onLog callback intercepts structured logs', () {
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.verbose);
      final captured = <(MiniaudioLogLevel, String)>[];
      MiniaudioPlayerGlobalConfig.onLog = (level, message) {
        captured.add((level, message));
      };

      MapLogger.error('Test error message');
      MapLogger.warn('Test warning message');
      MapLogger.info('Test info message');
      MapLogger.debug('Test debug message');
      MapLogger.verbose('Test verbose message');

      expect(captured.length, equals(5));
      expect(captured[0].$1, equals(MiniaudioLogLevel.error));
      expect(captured[0].$2, equals('Test error message'));
      expect(captured[1].$1, equals(MiniaudioLogLevel.warning));
      expect(captured[1].$2, equals('Test warning message'));
      expect(captured[2].$1, equals(MiniaudioLogLevel.info));
      expect(captured[2].$2, equals('Test info message'));
      expect(captured[3].$1, equals(MiniaudioLogLevel.debug));
      expect(captured[3].$2, equals('Test debug message'));
      expect(captured[4].$1, equals(MiniaudioLogLevel.verbose));
      expect(captured[4].$2, equals('Test verbose message'));
    });

    test('onLog filters out messages above current log level', () {
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.warning);
      final captured = <(MiniaudioLogLevel, String)>[];
      MiniaudioPlayerGlobalConfig.onLog = (level, message) {
        captured.add((level, message));
      };

      MapLogger.error('Should be logged');
      MapLogger.warn('Should be logged');
      MapLogger.info('Should NOT be logged');
      MapLogger.debug('Should NOT be logged');
      MapLogger.verbose('Should NOT be logged');

      expect(captured.length, equals(2));
      expect(captured[0].$1, equals(MiniaudioLogLevel.error));
      expect(captured[1].$1, equals(MiniaudioLogLevel.warning));
    });

    test('Player lifecycle and actions generate structured logs when enabled',
        () async {
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.verbose);
      final messages = <String>[];
      MiniaudioPlayerGlobalConfig.onLog = (level, message) {
        messages.add('[$level] $message');
      };

      final player = MiniaudioPlayer(
        source: [AudioSource('test/fixtures/salida.wav')],
      );

      expect(
        messages.any((m) => m.contains('Initializing MiniaudioPlayer')),
        isTrue,
      );

      await player.action.open(
        AudioSource('test/fixtures/salida.wav'),
      );
      expect(
        messages.any((m) => m.contains('open() requested for source')),
        isTrue,
      );

      await player.action.setVolume(0.8);
      expect(
        messages.any((m) => m.contains('setVolume() -> 0.8')),
        isTrue,
      );

      await player.action.play();
      expect(
        messages.any((m) => m.contains('play() requested')),
        isTrue,
      );

      await player.action.pause();
      expect(
        messages.any((m) => m.contains('pause() requested')),
        isTrue,
      );

      await player.dispose();
      expect(
        messages.any((m) => m.contains('Disposing MiniaudioPlayer instance')),
        isTrue,
      );
    });

    test('Player lifecycle and actions generate structured logs when enabled (queue)',
        () async {
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.verbose);
      final messages = <String>[];
      MiniaudioPlayerGlobalConfig.onLog = (level, message) {
        messages.add('[$level] $message');
      };

      final engine = MiniaudioPlayer<int>();
      expect(
        messages.any((m) => m.contains('Initializing MiniaudioPlayer')),
        isTrue,
      );

      await engine.action.open([
        AudioSource<int>(
          'test/fixtures/salida.wav',
          data: 1,
        ),
      ]);
      expect(
        messages.any((m) => m.contains('open() requested for source:')),
        isTrue,
      );

      await engine.dispose();
      expect(
        messages.any((m) => m.contains('Disposing MiniaudioPlayer instance')),
        isTrue,
      );
    });
  });
}
