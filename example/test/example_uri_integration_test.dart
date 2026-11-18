import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  Future<Uint8List> readBytes(int offset, int length) async => Uint8List(0);
  @override
  Future<void> close() async {}
}

class _FakeAssetManifestBundle extends CachingAssetBundle {
  final List<String> assets;
  _FakeAssetManifestBundle(this.assets);

  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      final map = <Object?, Object?>{
        for (final path in assets)
          path: <Object?>[
            <Object?, Object?>{'asset': path},
          ],
      };
      return const StandardMessageCodec().encodeMessage(map)!;
    }
    throw FlutterError('Asset not found: $key');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Example App First-Class URI Integration Tests', () {
    testWidgets(
      'Initial tracks are prepared using unified AudioSource without hacks',
      (tester) async {
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        });

        await tester.pumpWidget(const MiniaudioPlayerExampleApp());
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        // Verify that PlaylistQueueCard renders the queue
        expect(find.byType(PlaylistQueueCard), findsOneWidget);

        // Verify track items loaded from MockData
        final tracks = await MockData.loadTracks();
        expect(tracks, isNotEmpty);

        // Verify asset URI track presence (including accented/Unicode tracks #10, #12, #27, #29)
        final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
        final bundledMusicCount = manifest
            .listAssets()
            .where(
              (a) =>
                  a.startsWith('assets/music/') &&
                  !a.contains('/tripartite/') &&
                  !a.contains('/covers/') &&
                  !a.contains('/scripts/') &&
                  !a.contains('/library/') &&
                  !a.contains('/hls/') &&
                  MockData.isAudioFile(a),
            )
            .length;
        final assetTracks =
            tracks.where((t) => t.resourceBadge == 'ASSET').toList();
        expect(assetTracks.length, equals(bundledMusicCount));
        if (bundledMusicCount == 27) {
          for (final expectedPath in const [
            'assets/music/10_La_cicatriz_del_andén.aac',
            'assets/music/12_Mi_más_bonita_coincidencia_24bit_stereo.wav',
            'assets/music/25_Velocity_of_One.ape',
            'assets/music/27_¡Yo_me_opongo_.caf',
            'assets/music/29_駆け抜けて、この空を.dsf',
          ]) {
            expect(
              assetTracks.any((t) => t.source.uri == 'asset://$expectedPath'),
              isTrue,
              reason: 'Expected $expectedPath to be recognized as local ASSET',
            );
          }
        }

        final assetTrack = assetTracks.first;
        expect(assetTrack.source.uri, startsWith('asset:'));
        expect(assetTrack.resourceBadge, equals('ASSET'));

        // Verify remote MP3 track
        final networkTrack = tracks.firstWhere(
          (t) => t.resourceBadge == 'NETWORK' && !t.isLive,
        );
        expect(networkTrack.source.isNetwork, isTrue);
        expect(networkTrack.source.uri, startsWith('https:'));
        expect(networkTrack.resourceBadge, equals('NETWORK'));

        // Verify live stream track
        final liveTrack = tracks.firstWhere((t) => t.isLive);
        expect(liveTrack.source.uri, startsWith('icy:'));
        expect(liveTrack.resourceBadge, equals('LIVE STREAM'));

        // Verify data: RFC 2397 URI synth track
        final synthTrack = tracks.firstWhere((t) => t.isGenerated);
        expect(synthTrack.source.isMemory, isTrue);
        expect(synthTrack.resourceBadge, equals('DATA URI'));

        // Verify badges are rendered in the UI
        expect(find.text('ASSET'), findsWidgets);
      },
    );

    test('AudioSource polymorphically builds first-class sources for all schemes and bytes', () {
      final assetSource = AudioSource('asset://assets/music/01_Apex_Momentum.mp3');
      expect(assetSource.uri, equals('asset://assets/music/01_Apex_Momentum.mp3'));

      final httpSource = AudioSource(
        'https://example.com/audio.mp3',
        headers: {'Authorization': 'Bearer token'},
      );
      expect(httpSource.isNetwork, isTrue);
      expect(httpSource.uri, equals('https://example.com/audio.mp3'));
      expect(httpSource.headers?['Authorization'], equals('Bearer token'));

      final dataBytes = base64Encode([0, 1, 2, 3]);
      final dataSource = AudioSource('data:audio/wav;base64,$dataBytes');
      expect(dataSource.isMemory, isTrue);
      expect(dataSource.bytes, equals([0, 1, 2, 3]));

      final memorySource = AudioSource(Uint8List.fromList([4, 5, 6]));
      expect(memorySource.isMemory, isTrue);
      expect(memorySource.bytes, equals([4, 5, 6]));

      final customSource = AudioSource(_MockCustomByteProvider());
      expect(customSource.isCustom, isTrue);
    });

    test(
      'MockData hybrid completion preserves 4 mobile/web assets and fills missing songs remotely',
      () async {
        final mobileWebBundle = _FakeAssetManifestBundle(const [
          'assets/music/01_Apex_Momentum.mp3',
          'assets/music/02_Bailando_con_tu_recuerdo.opus',
          'assets/music/05_Burning_in_the_Electric_Light.ogg',
          'assets/music/06_Calculated_Motion_aac.m4a',
        ]);

        final mobileTracks = await MockData.loadTracks(bundle: mobileWebBundle);
        expect(mobileTracks.length, equals(30));
        expect(
          mobileTracks.where((t) => t.resourceBadge == 'ASSET').length,
          equals(4),
        );
        expect(
          mobileTracks.where((t) => t.resourceBadge == 'NETWORK').length,
          equals(23),
        );
        expect(
          mobileTracks.where((t) => t.resourceBadge == 'HLS VOD').length,
          equals(1),
        );
        expect(
          mobileTracks.where((t) => t.resourceBadge == 'LIVE STREAM').length,
          equals(1),
        );
        expect(
          mobileTracks.where((t) => t.resourceBadge == 'DATA URI').length,
          equals(1),
        );

        // Verify percent-encoded remote UTF-8 filenames
        final remoteDsf = mobileTracks.firstWhere(
          (t) => t.source.uri?.endsWith('.dsf') ?? false,
        );
        expect(remoteDsf.resourceBadge, equals('NETWORK'));
        expect(remoteDsf.source.uri, contains('29_%'));

        // Empty bundle (e.g. pub.dev download without submodule) falls back cleanly to 100% remote + icy + synth
        final emptyTracks =
            await MockData.loadTracks(bundle: _FakeAssetManifestBundle(const []));
        expect(emptyTracks.length, equals(30));
        expect(
          emptyTracks.where((t) => t.resourceBadge == 'ASSET').length,
          equals(0),
        );
        expect(
          emptyTracks.where((t) => t.resourceBadge == 'NETWORK').length,
          equals(27),
        );
      },
    );

    test(
      'MockData decodes both raw UTF-8 and percent-encoded AssetManifest keys without aborting',
      () async {
        final mixedUnicodeBundle = _FakeAssetManifestBundle(const [
          'assets/music/09_Flesh_and_Chrome.wv',
          'assets/music/10_La_cicatriz_del_and%C3%A9n.aac',
          'assets/music/11_Mar_de_cristal.mka',
          'assets/music/12_Mi_más_bonita_coincidencia_24bit_stereo.wav',
          'assets/music/25_Velocity_of_One.ape',
          'assets/music/27_%C2%A1Yo_me_opongo_.caf',
          'assets/music/29_%E9%A7%86%E3%81%91%E6%8A%9C%E3%81%91%E3%81%A6%E3%80%81%E3%81%93%E3%81%AE%E7%A9%BA%E3%82%92.dsf',
          'assets/music/100%_canción%20demo.mp3',
        ]);

        final tracks = await MockData.loadTracks(bundle: mixedUnicodeBundle);
        final assetTracks =
            tracks.where((t) => t.resourceBadge == 'ASSET').toList();

        expect(assetTracks.length, equals(8));
        expect(
          assetTracks.any(
            (t) =>
                t.source.uri ==
                    'asset://assets/music/10_La_cicatriz_del_and%C3%A9n.aac' &&
                t.title == 'La cicatriz del andén (AAC ADTS)',
          ),
          isTrue,
        );
        expect(
          assetTracks.any(
            (t) =>
                t.source.uri ==
                    'asset://assets/music/12_Mi_más_bonita_coincidencia_24bit_stereo.wav' &&
                t.title == 'Mi más bonita coincidencia (WAV 24-bit Stereo)',
          ),
          isTrue,
        );
        expect(
          assetTracks.any(
            (t) =>
                t.source.uri ==
                    'asset://assets/music/27_%C2%A1Yo_me_opongo_.caf' &&
                t.title == '¡Yo me opongo! (CAF)',
          ),
          isTrue,
        );
        expect(
          assetTracks.any(
            (t) =>
                t.source.uri ==
                    'asset://assets/music/29_%E9%A7%86%E3%81%91%E6%8A%9C%E3%81%91%E3%81%A6%E3%80%81%E3%81%93%E3%81%AE%E7%A9%BA%E3%82%92.dsf' &&
                t.title == '駆け抜けて、この空を (DSF DSD64)',
          ),
          isTrue,
        );
        expect(
          assetTracks.any(
            (t) =>
                t.source.uri == 'asset://assets/music/100%_canción%20demo.mp3' &&
                t.title == '100%_canción demo.mp3',
          ),
          isTrue,
        );
      },
    );
  });
}
