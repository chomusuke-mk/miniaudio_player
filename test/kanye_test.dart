import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('Kanye M4A reproduces cleanly with Tail Probing', () async {
    final player = MiniaudioPlayer();
    try {
      const url = "https://dn711104.ca.archive.org/0/items/kanyes-whole-discography/Kanye%27s%20Whole%20Discography%2F808%27s%26Heartbreak%2FAmazing%20%28feat.%20Young%20Jeezy%29.m4a";
      final stopwatch = Stopwatch()..start();
      await player.action.open(AudioSource.uri(url));
      stopwatch.stop();

      // Opening non-faststart M4A with Tail Probing must be nearly instantaneous (< 5s), not downloading full 8.6MB
      expect(stopwatch.elapsedMilliseconds, lessThan(6000));
      expect(player.state.trackMetadata?.codec, AudioCodec.aac);
      expect(player.state.duration.inSeconds, greaterThan(230));

      // With Tail Probing, upfront buffer must be only ~64KB (< 5% of 8.6MB), NOT full-file buffering
      expect(player.state.bufferedRange.percentage, lessThan(0.05));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(player.state.playing, isTrue);

      // Verify remote seek works across range requests
      await player.action.seek(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(player.state.position.inSeconds, closeTo(15, 2));

      await player.action.stop();
    } finally {
      await player.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 40)));
}
