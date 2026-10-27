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
    byteData.setUint8(8, 0x57);  // 'W'
    byteData.setUint8(9, 0x41);  // 'A'
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
    final lower = path.toLowerCase();
    return lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.opus') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.aif') ||
        lower.endsWith('.aiff') ||
        lower.endsWith('.aifc') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.w64') ||
        lower.endsWith('.rf64') ||
        lower.endsWith('.bwf') ||
        lower.endsWith('.mp2');
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

    // 1. Assets from bundle
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(root);
      final assets = manifest.listAssets();
      for (final asset in assets) {
        if (asset.startsWith('assets/music/') && isAudioFile(asset)) {
          final filename = asset.substring('assets/music/'.length);
          addTrack(
            id: 'asset://$asset',
            title: filename,
            source: AudioSource.uri('asset://$asset'),
            artist: 'Local Asset Bundle',
          );
        }
      }
    } catch (_) {}

    // Fallback bundled assets for tests/headless environments
    if (tracks.isEmpty) {
      const fallbackAssets = [
        'assets/music/salida.mp3',
        'assets/music/salida.flac',
        'assets/music/salida.wav',
        'assets/music/salida.ogg',
        'assets/music/cbr_noxing.mp3',
      ];
      for (final asset in fallbackAssets) {
        final filename = asset.split('/').last;
        addTrack(
          id: 'asset://$asset',
          title: filename,
          source: AudioSource.uri('asset://$asset'),
          artist: 'Bundled Asset',
        );
      }
    }

    // 2. Remote progressive HTTP streams (CORS enabled)
    addTrack(
      id: 'https://raw.githubusercontent.com/rafaelreis-hotmart/Audio-Sample-files/master/sample.mp3',
      title: 'Sample Track (Remote MP3, CORS)',
      source: AudioSource.uri(
        'https://raw.githubusercontent.com/rafaelreis-hotmart/Audio-Sample-files/master/sample.mp3',
      ),
      artist: 'Remote CDN',
    );

    addTrack(
      id: 'https://upload.wikimedia.org/wikipedia/commons/4/41/Joy_to_the_World.ogg',
      title: 'Joy to the World (Wikimedia OGG, CORS)',
      source: AudioSource.uri(
        'https://upload.wikimedia.org/wikipedia/commons/4/41/Joy_to_the_World.ogg',
      ),
      artist: 'Wikimedia Commons',
    );

    // 3. Live Icecast stream using native icy:// URI
    addTrack(
      id: 'icy://icecast.radiofrance.fr/fip-midfi.mp3',
      title: 'Radio FIP (Icecast Live Stream)',
      source: AudioSource.uri('icy://icecast.radiofrance.fr/fip-midfi.mp3'),
      artist: 'Radio France',
    );

    // 4. In-memory synthesized audio via data: URI
    final synthWav = generateSineWaveBytes();
    final synthBase64 = base64Encode(synthWav);
    addTrack(
      id: 'data:audio/wav;base64,...',
      title: 'Synthesized 440Hz Tone (data: URI)',
      source: AudioSource.uri('data:audio/wav;base64,$synthBase64'),
      isGenerated: true,
      artist: 'In-Memory DSP',
    );

    return tracks;
  }
}
