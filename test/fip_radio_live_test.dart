import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('FIP Radio Icecast MP3 live stream opens and plays without decoder init failure -203', () async {
    final player = MiniaudioPlayer();
    try {
      const fipUrl = 'https://icecast.radiofrance.fr/fip-midfi.mp3';
      
      // Open stream - should probe MP3 without failing with -203
      await player.action.open(AudioSource.uri(fipUrl, isLive: true));
      
      expect(player.state.duration, equals(Duration.zero));
      expect(player.state.trackMetadata?.codec, equals(AudioCodec.mp3));

      // Play stream
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(player.state.playing, isTrue);

      await player.action.stop();
      expect(player.state.playing, isFalse);
    } finally {
      await player.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
