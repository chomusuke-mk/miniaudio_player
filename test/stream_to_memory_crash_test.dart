import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('Switching from stream to openMemory does not crash with free invalid pointer', () async {
    final player = MiniaudioPlayer();
    try {
      final aiffFile = File('example/assets/music/salida.aiff');
      final aiffBytes = await aiffFile.readAsBytes();

      const oggUrl = 'https://upload.wikimedia.org/wikipedia/commons/4/41/Joy_to_the_World.ogg';
      await player.action.openUrl(oggUrl);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await player.action.seek(const Duration(milliseconds: 13987));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await player.action.seek(const Duration(milliseconds: 2122));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await player.action.stop();

      // Now switch to memory (salida.aiff)
      await player.action.openMemory(aiffBytes);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await player.action.stop();
      expect(player.state.playing, isFalse);
    } finally {
      await player.dispose();
    }
  });
}
