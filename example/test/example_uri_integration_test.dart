import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Example App First-Class URI Integration Tests', () {
    testWidgets('Initial tracks are prepared using unified AudioSource.uri schemes without hacks', (tester) async {
      await tester.pumpWidget(const MiniaudioPlayerExampleApp());
      await tester.pump();
      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 2));
      });
      await tester.pump();

      // Verify that AudioTrack items use native URI sources
      final dropdown = tester.widget<DropdownButton<AudioTrack>>(
        find.byWidgetPredicate((w) => w is DropdownButton<AudioTrack>),
      );

      final tracks = dropdown.items!.map((item) => item.value!).toList();
      expect(tracks, isNotEmpty);

      // Verify asset:// URI track presence
      final assetTrack = tracks.firstWhere((t) => t.source is AssetAudioSource);
      expect(assetTrack.source.uri?.scheme, equals('asset'));
      expect(assetTrack.displayType, equals('asset://'));

      // Verify https:// remote MP3 track
      final networkTrack = tracks.firstWhere((t) => t.source is NetworkAudioSource && !t.isLive);
      expect(networkTrack.source.uri?.scheme, equals('https'));
      expect(networkTrack.displayType, equals('https://'));

      // Verify icy:// live stream track
      final liveTrack = tracks.firstWhere((t) => t.isLive);
      expect(liveTrack.source.uri?.scheme, anyOf('http', 'https', 'icy'));
      expect(liveTrack.displayType, equals('icy:// (Live)'));

      // Verify data: RFC 2397 URI synth track
      final synthTrack = tracks.firstWhere((t) => t.isGenerated);
      expect(synthTrack.source, isA<MemoryAudioSource>());
      expect(synthTrack.displayType, equals('data: URI'));
    });

    test('AudioSource.uri polymorphically builds first-class sources for all schemes', () {
      final assetSource = AudioSource.uri('asset://assets/music/salida.mp3');
      expect(assetSource, isA<AssetAudioSource>());
      expect((assetSource as AssetAudioSource).assetKey, equals('assets/music/salida.mp3'));
      expect(assetSource.uri.toString(), equals('asset://assets/music/salida.mp3'));

      final httpSource = AudioSource.uri('https://example.com/audio.mp3');
      expect(httpSource, isA<NetworkAudioSource>());
      expect(httpSource.uri.toString(), equals('https://example.com/audio.mp3'));

      final icySource = AudioSource.uri('icy://stream.example.com/live');
      expect(icySource, isA<LiveStreamAudioSource>());
      expect(icySource.uri.toString(), equals('http://stream.example.com/live'));

      final dataBytes = base64Encode([0, 1, 2, 3]);
      final dataSource = AudioSource.uri('data:audio/wav;base64,$dataBytes');
      expect(dataSource, isA<MemoryAudioSource>());
      expect((dataSource as MemoryAudioSource).bytes, equals([0, 1, 2, 3]));

      final resolvingSource = AudioSource.uri('content://media/external/audio/media/42');
      expect(resolvingSource, isA<ResolvingAudioSource>());
    });
  });
}
