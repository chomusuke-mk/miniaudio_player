import 'dart:convert' show base64Encode;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'audio_track.dart';

abstract final class MockData {
  static Uint8List generateSineWaveBytes({
    int sampleRate = 44100,
    double frequency = 440.0,
    double durationSeconds = 3.0,
  }) {
    final totalSamples = (sampleRate * durationSeconds).round();
    final dataSize = totalSamples * 2; // 16-bit mono = 2 bytes per sample
    final fileSize = 44 + dataSize;
    final byteData = ByteData(fileSize);

    // RIFF header
    byteData.setUint8(0, 0x52); // 'R'
    byteData.setUint8(1, 0x49); // 'I'
    byteData.setUint8(2, 0x46); // 'F'
    byteData.setUint8(3, 0x46); // 'F'
    byteData.setUint32(4, fileSize - 8, Endian.little);
    byteData.setUint8(8, 0x57); // 'W'
    byteData.setUint8(9, 0x41); // 'A'
    byteData.setUint8(10, 0x56); // 'V'
    byteData.setUint8(11, 0x45); // 'E'

    // fmt subchunk
    byteData.setUint8(12, 0x66); // 'f'
    byteData.setUint8(13, 0x6D); // 'm'
    byteData.setUint8(14, 0x74); // 't'
    byteData.setUint8(15, 0x20); // ' '
    byteData.setUint32(16, 16, Endian.little);
    byteData.setUint16(20, 1, Endian.little); // PCM
    byteData.setUint16(22, 1, Endian.little); // 1 channel
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    byteData.setUint16(32, 2, Endian.little); // block align
    byteData.setUint16(34, 16, Endian.little); // bits per sample

    // data subchunk
    byteData.setUint8(36, 0x64); // 'd'
    byteData.setUint8(37, 0x61); // 'a'
    byteData.setUint8(38, 0x74); // 't'
    byteData.setUint8(39, 0x61); // 'a'
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

  static bool isAudioFile(String path) {
    final lower = path.toLowerCase().split('.').last;
    return miniAudioPlayerSupportedExtensions.contains(lower);
  }

  static Future<List<AudioTrack>> loadTracks({AssetBundle? bundle}) async {
    final root = bundle ?? rootBundle;
    final List<AudioTrack> tracks = [];
    final Set<String> seenFilenames = {};

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
      final key = title.toLowerCase();
      if (seenFilenames.contains(key)) return;
      seenFilenames.add(key);
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

    // 1. Assets from bundle (submodule: example/assets/music)
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
      }).toList()
        ..sort();

      for (final asset in localAssets) {
        final rawName = asset.substring('assets/music/'.length);
        final decodedName = Uri.decodeFull(rawName);
        addTrack(
          id: 'asset://$asset',
          title: decodedName,
          source: AudioSource('asset://$asset'),
          artist: 'Local Asset Bundle',
        );
      }
    } catch (_) {}

    // 2. Remote progressive HTTP streams & HLS playlists from miniaudio_player_assets (CORS + COEP + HTTP 206)
    const rawAssetsBase =
        'https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main';

    final remoteTracks = <({String path, String title, String artist})>[
      (
        path: '01_Apex_Momentum.mp3',
        title: 'Apex Momentum (Remote MP3)',
        artist: 'Elena Vance • Remote Raw CDN',
      ),
      (
        path: '02_Bailando_con_tu_recuerdo.opus',
        title: 'Bailando con tu recuerdo (Remote Opus)',
        artist: 'Mateo Valdés • Remote Raw CDN',
      ),
      (
        path: '04_Belaya_Tishina.flac',
        title: 'Belaya Tishina (Remote FLAC)',
        artist: 'Dmitri Volkov • Remote Raw CDN',
      ),
      (
        path: '05_Burning_in_the_Electric_Light.ogg',
        title: 'Burning in the Electric Light (Remote OGG)',
        artist: 'The Meridian Echo • Remote Raw CDN',
      ),
      (
        path: '06_Calculated_Motion_aac.m4a',
        title: 'Calculated Motion (Remote M4A)',
        artist: 'Kairo Tanaka • Remote Raw CDN',
      ),
      (
        path: '09_Flesh_and_Chrome.wv',
        title: 'Flesh and Chrome (Remote WavPack)',
        artist: 'Vespera 9 • Remote Raw CDN',
      ),
      (
        path: 'hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8',
        title: 'Разводят мосты (Remote HLS VOD)',
        artist: 'Анна Крылова • Remote Raw CDN',
      ),
    ];

    for (final item in remoteTracks) {
      final url = '$rawAssetsBase/${item.path}';
      addTrack(
        id: url,
        title: item.title,
        source: AudioSource(url),
        artist: item.artist,
      );
    }

    // 3. Live Icecast stream using native icy:// URI
    addTrack(
      id: 'icy://icecast.radiofrance.fr/fip-midfi.mp3',
      title: 'Radio FIP (Icecast Live Stream)',
      source: AudioSource('icy://icecast.radiofrance.fr/fip-midfi.mp3'),
      artist: 'Radio France',
    );

    // 4. In-memory synthesized audio via data: URI
    final synthWav = generateSineWaveBytes();
    final synthBase64 = base64Encode(synthWav);
    addTrack(
      id: 'data:audio/wav;base64,...',
      title: 'Synthesized 440Hz Tone (data: URI)',
      source: AudioSource('data:audio/wav;base64,$synthBase64'),
      isGenerated: true,
      artist: 'In-Memory DSP',
    );

    return tracks;
  }
}
