import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/main.dart';
import 'package:miniaudio_player_example/models/mock_data.dart';
import 'package:miniaudio_player_example/widgets/cards/playlist_queue_card.dart';

class _MockCustomByteProvider implements CustomByteProvider {
  @override
  int get streamId => 1;
  @override
  int? get totalBytes => 1024;
  @override
  bool get isSeekable => true;
  @override
  Future<Uint8List> readInitialBytes() async => Uint8List(0);
  @override
  Future<Uint8List> readBytes(int offset, int length) async => Uint8List(0);
  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Example App First-Class URI Integration Tests', () {
    testWidgets('Initial tracks are prepared using unified AudioSource without hacks', (tester) async {
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });

      await tester.pumpWidget(const MiniaudioPlayerExampleApp());
      await tester.pump();
      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 2));
      });
      await tester.pump();

      // Verify that PlaylistQueueCard renders the queue
      expect(find.byType(PlaylistQueueCard), findsOneWidget);

      // Verify track items loaded from MockData
      final tracks = await MockData.loadTracks();
      expect(tracks, isNotEmpty);

      // Verify asset URI track presence
      final assetTrack = tracks.firstWhere((t) => t.resourceBadge == 'ASSET');
      expect(assetTrack.source, isA<UriAudioSource>());
      expect((assetTrack.source as UriAudioSource).sourceString, startsWith('asset:'));
      expect(assetTrack.resourceBadge, equals('ASSET'));

      // Verify remote MP3 track
      final networkTrack = tracks.firstWhere((t) => t.resourceBadge == 'NETWORK' && !t.isLive);
      expect(networkTrack.source, isA<UriAudioSource>());
      expect((networkTrack.source as UriAudioSource).sourceString, startsWith('https:'));
      expect(networkTrack.resourceBadge, equals('NETWORK'));

      // Verify live stream track
      final liveTrack = tracks.firstWhere((t) => t.isLive);
      expect(liveTrack.source, isA<UriAudioSource>());
      expect(liveTrack.resourceBadge, equals('LIVE STREAM'));

      // Verify data: RFC 2397 URI synth track
      final synthTrack = tracks.firstWhere((t) => t.isGenerated);
      expect(synthTrack.source, isA<MemoryAudioSource>());
      expect(synthTrack.resourceBadge, equals('DATA URI'));

      // Verify badges are rendered in the UI
      expect(find.text('ASSET'), findsWidgets);
    });

    test('AudioSource polymorphically builds first-class sources for all schemes and bytes', () {
      final assetSource = AudioSource('asset://assets/music/salida.mp3');
      expect(assetSource, isA<UriAudioSource>());
      expect((assetSource as UriAudioSource).sourceString, equals('asset://assets/music/salida.mp3'));

      final httpSource = AudioSource(
        'https://example.com/audio.mp3',
        headers: {'Authorization': 'Bearer token'},
      );
      expect(httpSource, isA<UriAudioSource>());
      expect((httpSource as UriAudioSource).sourceString, equals('https://example.com/audio.mp3'));
      expect(httpSource.headers?['Authorization'], equals('Bearer token'));

      final dataBytes = base64Encode([0, 1, 2, 3]);
      final dataSource = AudioSource('data:audio/wav;base64,$dataBytes');
      expect(dataSource, isA<MemoryAudioSource>());
      expect((dataSource as MemoryAudioSource).bytes, equals([0, 1, 2, 3]));

      final memorySource = AudioSource(Uint8List.fromList([4, 5, 6]));
      expect(memorySource, isA<MemoryAudioSource>());
      expect((memorySource as MemoryAudioSource).bytes, equals([4, 5, 6]));

      final customSource = AudioSource.custom(_MockCustomByteProvider());
      expect(customSource, isA<CustomAudioSource>());
    });
  });
}
