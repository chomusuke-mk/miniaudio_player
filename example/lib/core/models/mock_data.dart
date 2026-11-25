import 'dart:convert' show base64Encode;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'audio_track.dart';

/// Factory providing fixture playlists and synthesized WAV payloads for the example app.
abstract final class MockData {
  /// Generates an uncompressed 16-bit PCM mono WAV byte buffer containing a sine tone.
  ///
  /// Uses [sampleRate] Hz, oscillator [frequency] Hz, and [durationSeconds] length.
  static Uint8List generateSineWaveBytes({
    int sampleRate = 44100,
    double frequency = 440.0,
    double durationSeconds = 3.0,
  }) {
    final totalSamples = (sampleRate * durationSeconds).round();
    final dataSize = totalSamples * 2;
    final fileSize = 44 + dataSize;
    final byteData = ByteData(fileSize);

    // RIFF header
    byteData.setUint8(0, 0x52);
    byteData.setUint8(1, 0x49);
    byteData.setUint8(2, 0x46);
    byteData.setUint8(3, 0x46);
    byteData.setUint32(4, fileSize - 8, Endian.little);
    byteData.setUint8(8, 0x57);
    byteData.setUint8(9, 0x41);
    byteData.setUint8(10, 0x56);
    byteData.setUint8(11, 0x45);

    // fmt subchunk
    byteData.setUint8(12, 0x66);
    byteData.setUint8(13, 0x6D);
    byteData.setUint8(14, 0x74);
    byteData.setUint8(15, 0x20);
    byteData.setUint32(16, 16, Endian.little);
    byteData.setUint16(20, 1, Endian.little);
    byteData.setUint16(22, 1, Endian.little);
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, sampleRate * 2, Endian.little);
    byteData.setUint16(32, 2, Endian.little);
    byteData.setUint16(34, 16, Endian.little);

    // data subchunk
    byteData.setUint8(36, 0x64);
    byteData.setUint8(37, 0x61);
    byteData.setUint8(38, 0x74);
    byteData.setUint8(39, 0x61);
    byteData.setUint32(40, dataSize, Endian.little);

    for (int i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      final sampleVal = (sin(2 * pi * frequency * t) * 30000).round();
      byteData.setInt16(
        44 + (i * 2),
        sampleVal.clamp(-32768, 32767),
        Endian.little,
      );
    }

    return byteData.buffer.asUint8List();
  }

  /// Returns `true` when [path] ends with an extension supported by `miniaudio_player`.
  static bool isAudioFile(String path) {
    final lower = path.toLowerCase().split('.').last;
    return miniAudioPlayerSupportedExtensions.contains(lower);
  }

  /// Base URL of the public audio fixture mirror used for unbundled tracks.
  static const String _rawAssetsBase =
      'https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main';

  /// Percent-encodes each path segment in [relPath] for raw CDN URL construction.
  static String _encodeRelativeUrlPath(String relPath) =>
      relPath.split('/').map(Uri.encodeComponent).join('/');

  /// Pattern matching UTF-8 `%XX` runs in Flutter asset manifest keys.
  static final RegExp _percentEncodedRunPattern = RegExp(
    r'(?:%[0-9A-Fa-f]{2})+',
  );

  /// Decodes `%XX` UTF-8 sequences in [rawName] while preserving literal non-ASCII
  /// characters that cause [Uri.decodeFull] to throw [ArgumentError].
  static String _decodeAssetRelativeName(String rawName) {
    if (!rawName.contains('%')) return rawName;
    return rawName.replaceAllMapped(_percentEncodedRunPattern, (match) {
      final segment = match.group(0)!;
      try {
        return Uri.decodeComponent(segment);
      } on ArgumentError {
        return segment;
      }
    });
  }

  /// Loads the demo playlist from bundled Flutter assets, CDN fallback URLs,
  /// live ICY radio, and an in-memory synthesized `data:` WAV URI using [bundle].
  static Future<List<AudioTrack>> loadTracks({AssetBundle? bundle}) async {
    final root = bundle ?? rootBundle;
    final List<AudioTrack> tracks = [];
    final Set<String> seenIds = {};

    void addTrack({
      required String id,
      required String title,
      required AudioSource source,
      bool isGenerated = false,
      String? artist,
      String? album,
      double? replayGainDb,
      double? replayPeak,
    }) {
      if (!seenIds.add(id)) return;
      tracks.add(
        AudioTrack(
          id: id,
          title: title,
          source: source,
          isGenerated: isGenerated,
          artist: artist,
          album: album,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
        ),
      );
    }

    // 1. Discover assets bundled on the current target platform.
    final Map<String, String> bundledByDecodedName = {};
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(root);
      final localAssets = manifest.listAssets().where((asset) {
        if (!asset.startsWith('assets/music/')) return false;
        if (asset.contains('/tripartite/') ||
            asset.contains('/covers/') ||
            asset.contains('/scripts/') ||
            asset.contains('/library/') ||
            asset.contains('/hls/')) {
          return false;
        }
        return isAudioFile(asset);
      }).toList()..sort();

      for (final asset in localAssets) {
        final rawName = asset.substring('assets/music/'.length);
        bundledByDecodedName[_decodeAssetRelativeName(rawName)] = asset;
      }
    } catch (e) {
      MapLogger.warn('[MockData] Failed to inspect AssetManifest: $e');
    }

    // 2. Canonical playable catalog (28 entries; bundles use asset://, rest use CDN).
    const catalog =
        <
          ({
            String path,
            String title,
            String artist,
            String album,
            String format,
            bool remoteOnly,
          })
        >[
          (
            path: '01_Apex_Momentum.mp3',
            title: 'Apex Momentum',
            artist: 'Elena Vance',
            album: 'Kinetic Landscapes',
            format: 'MP3',
            remoteOnly: false,
          ),
          (
            path: '02_Bailando_con_tu_recuerdo.opus',
            title: 'Bailando con tu recuerdo',
            artist: 'Mateo Valdés',
            album: 'Noches de Brisa',
            format: 'Opus',
            remoteOnly: false,
          ),
          (
            path: '03_Before_The_Dawn_cbr_noxing.mp3',
            title: 'Before The Dawn',
            artist: 'Clara Lindqvist',
            album: 'Radiant Horizons',
            format: 'MP3 CBR Mono',
            remoteOnly: false,
          ),
          (
            path: '04_Belaya_Tishina.flac',
            title: 'Белая тишина (Belaya Tishina)',
            artist: 'Dmitri Volkov',
            album: 'За краем веков',
            format: 'FLAC 24-bit',
            remoteOnly: false,
          ),
          (
            path: '05_Burning_in_the_Electric_Light.ogg',
            title: 'Burning in the Electric Light',
            artist: 'The Meridian Echo',
            album: 'After the Glare',
            format: 'OGG Vorbis',
            remoteOnly: false,
          ),
          (
            path: '06_Calculated_Motion_aac.m4a',
            title: 'Calculated Motion',
            artist: 'Kairo Tanaka',
            album: 'Active State',
            format: 'M4A AAC',
            remoteOnly: false,
          ),
          (
            path: '07_Fevered_Strings_alac.m4a',
            title: 'Fevered Strings',
            artist: 'Aria Montgomery',
            album: 'The Kinetic Suite',
            format: 'ALAC Lossless',
            remoteOnly: false,
          ),
          (
            path: '08_Firelight_Promise_24bit_mono.wav',
            title: 'Firelight Promise',
            artist: 'Nolan Reid',
            album: 'Midnight Solstice',
            format: 'WAV 24-bit Mono',
            remoteOnly: false,
          ),
          (
            path: '09_Flesh_and_Chrome.wv',
            title: 'Flesh and Chrome',
            artist: 'Vespera 9',
            album: 'Velvet Machine',
            format: 'WavPack',
            remoteOnly: false,
          ),
          (
            path: '10_La_cicatriz_del_andén.aac',
            title: 'La cicatriz del andén',
            artist: 'Lucía Benítez',
            album: 'Viajeros del tiempo perdido',
            format: 'AAC ADTS',
            remoteOnly: false,
          ),
          (
            path: '11_Mar_de_cristal.mka',
            title: 'Mar de cristal',
            artist: 'Camila Solís',
            album: 'Arquitectura de luz',
            format: 'MKA FLAC',
            remoteOnly: false,
          ),
          (
            path: '12_Mi_más_bonita_coincidencia_24bit_stereo.wav',
            title: 'Mi más bonita coincidencia',
            artist: 'Julián Cabrera',
            album: 'Cielo de Febrero',
            format: 'WAV 24-bit Stereo',
            remoteOnly: false,
          ),
          (
            path: '13_Overture_for_the_Floor.webm',
            title: 'Overture for the Floor',
            artist: 'Studio Monochrome',
            album: 'Concrete Conservatory',
            format: 'WebM Opus',
            remoteOnly: false,
          ),
          (
            path: '14_Painting_the_Sky.mkv',
            title: 'Painting the Sky',
            artist: 'Sora Takashi',
            album: 'Prism Flight',
            format: 'MKV Opus',
            remoteOnly: false,
          ),
          (
            path: '15_Resting_At_Your_Feet.mp2',
            title: 'Resting At Your Feet',
            artist: 'Helena Novak',
            album: 'Cathedral Of Silence',
            format: 'MP2',
            remoteOnly: false,
          ),
          (
            path: '16_Ribbons_on_Anchors.oga',
            title: 'Ribbons on Anchors',
            artist: 'Yuki Fujimoto',
            album: 'Glitter & Grit',
            format: 'OGA Vorbis',
            remoteOnly: false,
          ),
          (
            path: '17_Running_To_Meet_The_Sun.wav',
            title: 'Running To Meet The Sun',
            artist: 'Caleb Mercer',
            album: 'Westbound Narratives',
            format: 'WAV 16-bit',
            remoteOnly: false,
          ),
          (
            path: '18_Running_With_Daylight.aif',
            title: 'Running With Daylight',
            artist: 'Noah Lind',
            album: 'Calculated Motion',
            format: 'AIFF',
            remoteOnly: false,
          ),
          (
            path: '19_Spin_Me_In_The_Dark.rf64',
            title: 'Spin Me In The Dark',
            artist: 'Mireia Costa',
            album: 'The Midnight Ballroom',
            format: 'RF64',
            remoteOnly: false,
          ),
          (
            path: '20_Swallowing_This_Glitter_Pill.w64',
            title: 'Swallowing This Glitter Pill',
            artist: 'Koko Arakawa',
            album: 'Curated Facades',
            format: 'Wave64',
            remoteOnly: false,
          ),
          (
            path: '21_The_Great_Equalizer.bwf',
            title: 'The Great Equalizer',
            artist: 'Victor Kestrel',
            album: 'Broadcast Masters',
            format: 'BWF',
            remoteOnly: false,
          ),
          (
            path: '22_The_Midnight_Pursuit.rifx',
            title: 'The Midnight Pursuit',
            artist: 'Clara Rostova',
            album: 'Bravura Nocturnes',
            format: 'RIFX BE',
            remoteOnly: false,
          ),
          (
            path: '23_Tracing_Lines.aifc',
            title: 'Tracing Lines',
            artist: 'Owen Gallagher',
            album: 'Midnight Horizon',
            format: 'AIFC',
            remoteOnly: false,
          ),
          (
            path: '24_Tracks_Into_The_Dawn.aiff',
            title: 'Tracks Into The Dawn',
            artist: 'Rafael Ortega',
            album: 'Horizon Velocity',
            format: 'AIFF',
            remoteOnly: false,
          ),
          (
            path: '25_Velocity_of_One.ape',
            title: 'Velocity of One',
            artist: 'Lucas Moreau',
            album: 'Radiant Motion',
            format: 'APE',
            remoteOnly: false,
          ),
          (
            path: '27_¡Yo_me_opongo_.caf',
            title: '¡Yo me opongo!',
            artist: 'Gabriel Peña',
            album: 'Sentimientos de Amargue',
            format: 'CAF',
            remoteOnly: false,
          ),
          (
            path: 'hls/28_Разводят_мосты.m3u8',
            title: 'Разводят мосты',
            artist: 'Анна Крылова',
            album: 'Городские сны',
            format: 'HLS VOD',
            remoteOnly: true,
          ),
          (
            path: '29_駆け抜けて、この空を.dsf',
            title: '駆け抜けて、この空を',
            artist: '桜庭 凛 (Rin Sakuraba)',
            album: '光のまにまに',
            format: 'DSF DSD64',
            remoteOnly: false,
          ),
        ];

    final Set<String> consumedAssets = {};
    for (final item in catalog) {
      final bundledAsset = item.remoteOnly
          ? null
          : bundledByDecodedName[item.path];
      if (bundledAsset != null) {
        consumedAssets.add(item.path);
        addTrack(
          id: 'asset://$bundledAsset',
          title: '${item.title} (${item.format})',
          source: AudioSource('asset://$bundledAsset'),
          artist: '${item.artist} • Local Asset',
          album: item.album,
        );
      } else {
        final url = '$_rawAssetsBase/${_encodeRelativeUrlPath(item.path)}';
        addTrack(
          id: url,
          title: '${item.title} (Remote ${item.format})',
          source: AudioSource(url),
          artist: '${item.artist} • Remote Raw CDN',
          album: item.album,
        );
      }
    }

    // Preserve additional bundled assets outside the canonical table.
    for (final entry in bundledByDecodedName.entries) {
      if (consumedAssets.contains(entry.key)) continue;
      addTrack(
        id: 'asset://${entry.value}',
        title: entry.key,
        source: AudioSource('asset://${entry.value}'),
        artist: 'Local Asset Bundle',
      );
    }

    // Ensure at least one progressive HTTPS track is always available.
    if (!tracks.any((t) => t.resourceBadge == 'NETWORK' && !t.isLive)) {
      const showcaseUrl = '$_rawAssetsBase/01_Apex_Momentum.mp3';
      addTrack(
        id: showcaseUrl,
        title: 'Apex Momentum (Remote HTTP MP3)',
        source: AudioSource(showcaseUrl),
        artist: 'Elena Vance • Remote Raw CDN',
        album: 'Kinetic Landscapes',
      );
    }

    // 3. Live Icecast stream using native icy:// URI.
    addTrack(
      id: 'icy://icecast.radiofrance.fr/fip-midfi.mp3',
      title: 'Radio FIP (Icecast Live Stream)',
      source: AudioSource('icy://icecast.radiofrance.fr/fip-midfi.mp3'),
      artist: 'Radio France',
    );

    // 4. In-memory synthesized audio via data: URI.
    final synthWav = generateSineWaveBytes();
    final synthBase64 = base64Encode(synthWav);
    addTrack(
      id: 'data:audio/wav;base64,...',
      title: 'Synthesized 440Hz Tone (data: URI)',
      source: AudioSource('data:audio/wav;base64,$synthBase64'),
      isGenerated: true,
      artist: 'In-Memory DSP',
    );

    MapLogger.info(
      '[MockData] Loaded ${tracks.length} tracks (${bundledByDecodedName.length} bundled assets).',
    );
    return tracks;
  }
}
