// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/src/platform/fs_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  allowHttpInTests();

  group('Real-World Web Audio Formats Verification', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      await player.dispose();
    });

    test('URL 1: Kanye M4A Non-Fast-Start from Archive.org', () async {
      const url =
          'https://dn711104.ca.archive.org/0/items/kanyes-whole-discography/Kanye%27s%20Whole%20Discography%2F808%27s%26Heartbreak%2FAmazing%20%28feat.%20Young%20Jeezy%29.m4a';

      await player.action.openUrl(url);

      print('URL 1 opened successfully!');
      print('Duration: ${player.state.duration}');
      print('Bitrate: ${player.state.audioBitrate}');
      print('metaBytes: ${player.state.metaBytes?.length}');

      expect(player.state.duration.inSeconds, greaterThan(180),
          reason: 'Duration must be > 3 minutes (actual is ~3m58s)');

      await player.action.play();

      // Monitor playback for 15 seconds to ensure it does not prematurely terminate at ~10s
      int lastPosMs = 0;
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final curPosMs = player.state.position.inMilliseconds;
        print('Play position at ${(i + 1) * 0.5}s: $curPosMs ms, playing: ${player.state.playing}, completed: ${player.state.completed}');
        expect(player.state.completed, isFalse,
            reason: 'Track must not jump to EOF prematurely around 10s');
        if (curPosMs > lastPosMs) {
          lastPosMs = curPosMs;
        }
      }

      expect(lastPosMs, greaterThan(10000),
          reason: 'Audio playback must advance past 10 seconds without stopping');

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('URL 1: Kanye M4A Seek to 3:50 and Play to End', () async {
      const url =
          'https://dn711104.ca.archive.org/0/items/kanyes-whole-discography/Kanye%27s%20Whole%20Discography%2F808%27s%26Heartbreak%2FAmazing%20%28feat.%20Young%20Jeezy%29.m4a';

      await player.action.openUrl(url);
      expect(player.state.duration.inSeconds, greaterThan(230));

      // Seek to 3:50 (230 seconds)
      await player.action.seek(const Duration(minutes: 3, seconds: 50));
      expect(player.state.completed, isFalse,
          reason: 'Seek to 3:50 must not trigger premature EOF');

      await player.action.play();

      // Verify that playback advances past 3:50
      bool reachedPast230 = false;
      for (int i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final posSec = player.state.position.inSeconds;
        print('Post-seek position at ${(i + 1) * 0.5}s: ${player.state.position}, completed: ${player.state.completed}');
        if (posSec >= 231) {
          reachedPast230 = true;
          break;
        }
        if (player.state.completed) {
          break;
        }
      }

      expect(reachedPast230, isTrue,
          reason: 'Audio must continue playing past 3:50 (230s)');

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 45)));

    test('URL 2: Art Bell MP3 from Archive.org', () async {
      const url =
          'https://dn710105.ca.archive.org/0/items/art-bell-1990-2000/1988-12-00%20-%20%20Terence%20Mckenna%20-%20Psilocybin%20And%20The%20Sands%20Of%20Time.mp3';

      await player.action.openUrl(url);
      print('URL 2 opened: duration=${player.state.duration}');
      expect(player.state.duration.inMinutes, greaterThan(10));

      await player.action.play();
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(player.state.position.inMilliseconds, greaterThan(0));
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('URL 3: Grateful Dead MP3 from Archive.org', () async {
      const url =
          'https://dn720307.ca.archive.org/0/items/gd85-06-30.sbd.miller.30158.sbeok.flacf/gd85-06-30d1t01.mp3';

      await player.action.openUrl(url);
      print('URL 3 opened: duration=${player.state.duration}');
      expect(player.state.duration.inMinutes, greaterThan(1));

      await player.action.play();
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(player.state.position.inMilliseconds, greaterThan(0));
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('URL 4: 24-bit WAV from Wikimedia Commons', () async {
      const url =
          'https://upload.wikimedia.org/wikipedia/commons/4/44/Creator_of_the_Universe_%28The_Space_Force_Hymn%29.wav';

      await player.action.openUrl(url);
      print('URL 4 opened: duration=${player.state.duration}');
      expect(player.state.duration.inSeconds, greaterThan(30));

      await player.action.play();
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(player.state.position.inMilliseconds, greaterThan(1000));
      expect(player.state.completed, isFalse);
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 45)));

    test('URL 5: Ogg Vorbis from Wikimedia Commons (Duration & Seek)', () async {
      const url =
          'https://upload.wikimedia.org/wikipedia/commons/4/41/Joy_to_the_World.ogg';

      await player.action.openUrl(url);
      print('URL 5 opened: duration=${player.state.duration}');

      // Duration should be ~1:31 (91s), NOT 0:57 (57s)
      expect(player.state.duration.inSeconds, greaterThan(80),
          reason: 'Ogg Vorbis duration must be ~91 seconds (1:31), not 57s');

      // Seek to 20s and verify playback does NOT jump to EOF
      await player.action.seek(const Duration(seconds: 20));
      expect(player.state.completed, isFalse);

      await player.action.play();

      bool advanced = false;
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        print('Ogg post-seek pos: ${player.state.position}, completed: ${player.state.completed}');
        if (player.state.position.inSeconds >= 21) {
          advanced = true;
          break;
        }
        expect(player.state.completed, isFalse,
            reason: 'Ogg seek must not trigger premature EOF at 20s');
      }

      expect(advanced, isTrue, reason: 'Playback must advance past 20s');
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 45)));
  }, retry: 2);
}
