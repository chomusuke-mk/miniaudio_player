import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

/// Builds a synchsafe 28-bit integer for ID3v2 headers.
List<int> _synchsafe32(int value) => [
      (value >> 21) & 0x7F,
      (value >> 14) & 0x7F,
      (value >> 7) & 0x7F,
      value & 0x7F,
    ];

/// Builds a big-endian 32-bit unsigned integer.
List<int> _u32be(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

/// Builds a little-endian 32-bit unsigned integer.
List<int> _u32le(int value) => [
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];

/// Builds a little-endian 64-bit unsigned integer.
List<int> _u64le(int value) => [
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
      (value >> 32) & 0xFF,
      (value >> 40) & 0xFF,
      (value >> 48) & 0xFF,
      (value >> 56) & 0xFF,
    ];

/// Builds an ID3v2.3 text frame (encoding 0x03 = UTF-8).
List<int> _id3TextFrame(String id, String text) {
  final textBytes = utf8.encode(text);
  final payload = <int>[0x03, ...textBytes];
  return [
    ...ascii.encode(id),
    ..._u32be(payload.length),
    0x00,
    0x00,
    ...payload,
  ];
}

/// Builds an ID3v2.3 TXXX user text frame.
List<int> _id3TxxxFrame(String description, String value) {
  final descBytes = utf8.encode(description);
  final valBytes = utf8.encode(value);
  final payload = <int>[0x03, ...descBytes, 0x00, ...valBytes];
  return [
    ...ascii.encode('TXXX'),
    ..._u32be(payload.length),
    0x00,
    0x00,
    ...payload,
  ];
}

/// Builds an ID3v2.3 USLT lyrics frame.
List<int> _id3UsltFrame(String lyrics) {
  final textBytes = utf8.encode(lyrics);
  final payload = <int>[
    0x03, // UTF-8
    ...ascii.encode('eng'),
    0x00, // empty content descriptor
    ...textBytes,
  ];
  return [
    ...ascii.encode('USLT'),
    ..._u32be(payload.length),
    0x00,
    0x00,
    ...payload,
  ];
}

/// Builds an ID3v2.3 COMM comment frame.
List<int> _id3CommFrame(String comment) {
  final textBytes = utf8.encode(comment);
  final payload = <int>[
    0x03, // UTF-8
    ...ascii.encode('eng'),
    0x00, // empty short description
    ...textBytes,
  ];
  return [
    ...ascii.encode('COMM'),
    ..._u32be(payload.length),
    0x00,
    0x00,
    ...payload,
  ];
}

/// Builds an ID3v2.3 APIC picture frame.
List<int> _id3ApicFrame({
  required String mime,
  required int picType,
  required String description,
  required List<int> imageBytes,
}) {
  final payload = <int>[
    0x03, // UTF-8
    ...ascii.encode(mime),
    0x00,
    picType,
    ...utf8.encode(description),
    0x00,
    ...imageBytes,
  ];
  return [
    ...ascii.encode('APIC'),
    ..._u32be(payload.length),
    0x00,
    0x00,
    ...payload,
  ];
}

/// Builds an ID3v2.3 CHAP chapter frame with a nested TIT2 sub-frame.
List<int> _id3ChapFrame({
  required String elementId,
  required String title,
  required int startMs,
  required int endMs,
}) {
  final tit2 = _id3TextFrame('TIT2', title);
  final payload = <int>[
    ...ascii.encode(elementId),
    0x00,
    ..._u32be(startMs),
    ..._u32be(endMs),
    0xFF, 0xFF, 0xFF, 0xFF, // start byte offset
    0xFF, 0xFF, 0xFF, 0xFF, // end byte offset
    ...tit2,
  ];
  return [
    ...ascii.encode('CHAP'),
    ..._u32be(payload.length),
    0x00,
    0x00,
    ...payload,
  ];
}

/// Wraps ID3v2.3 frames into a complete ID3v2.3 tag header + body.
Uint8List _buildId3v23Tag(List<List<int>> frames) {
  final body = <int>[for (final f in frames) ...f];
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    0x03, // v2.3
    0x00, // revision
    0x00, // flags
    ..._synchsafe32(body.length),
    ...body,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  group('AudioInfo Zero-Cost Complete Properties', () {
    test(
        'populates codec, containerFormat, lossless, bitrateMode, bitsPerSample, fileSize across formats',
        () async {
      // 1. MP3 (lossy, MP3 codec & container)
      final mp3 = resolveAsset('test/fixtures/salida.mp3');
      final mp3Res = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        replayGain: false,
        waveform: false,
        metadata: false,
      );
      expect(mp3Res.metadata, isNull);
      expect(mp3Res.audioInfo.sampleRate, equals(48000));
      expect(mp3Res.audioInfo.channels, equals(2));
      expect(mp3Res.audioInfo.codec, equals('MP3'));
      expect(mp3Res.audioInfo.containerFormat, equals('MP3'));
      expect(mp3Res.audioInfo.lossless, isFalse);
      expect(mp3Res.audioInfo.bitrate, greaterThan(0));
      expect(mp3Res.audioInfo.bitrateMode, isNot(equals(BitrateMode.unknown)));
      expect(mp3Res.audioInfo.fileSize, equals(mp3.lengthSync()));

      // 2. FLAC (lossless, FLAC codec & container, bitsPerSample > 0)
      final flac = resolveAsset('test/fixtures/salida.flac');
      final flacRes = await MiniaudioPlayer.analyzeAudio(
        flac.path,
        replayGain: false,
        waveform: false,
        metadata: false,
      );
      expect(flacRes.audioInfo.codec, equals('FLAC'));
      expect(flacRes.audioInfo.containerFormat, equals('FLAC'));
      expect(flacRes.audioInfo.lossless, isTrue);
      expect(flacRes.audioInfo.bitsPerSample, isNotNull);
      expect(flacRes.audioInfo.bitsPerSample, greaterThanOrEqualTo(16));
      expect(flacRes.audioInfo.bitrateMode, equals(BitrateMode.vbr));
      expect(flacRes.audioInfo.fileSize, equals(flac.lengthSync()));

      // 3. 24-bit WAV (lossless PCM, 24 bitsPerSample, CBR)
      final wav24 = resolveAsset('test/fixtures/test_24bit_stereo.wav');
      final wav24Res = MiniaudioPlayer.analyzeAudioSync(
        wav24.path,
        replayGain: false,
        waveform: false,
        metadata: false,
      );
      expect(wav24Res.audioInfo.codec, equals('PCM'));
      expect(wav24Res.audioInfo.containerFormat, equals('WAV'));
      expect(wav24Res.audioInfo.lossless, isTrue);
      expect(wav24Res.audioInfo.bitsPerSample, equals(24));
      expect(wav24Res.audioInfo.bitrateMode, equals(BitrateMode.cbr));
      expect(wav24Res.audioInfo.fileSize, equals(wav24.lengthSync()));

      // 4. Opus in Ogg container
      final opus = resolveAsset('test/fixtures/salida.opus');
      if (opus.existsSync()) {
        final opusRes = await MiniaudioPlayer.analyzeAudio(
          opus.path,
          replayGain: false,
          waveform: false,
          metadata: false,
        );
        expect(opusRes.audioInfo.codec, equals('Opus'));
        expect(opusRes.audioInfo.containerFormat, equals('Ogg'));
        expect(opusRes.audioInfo.lossless, isFalse);
      }

      // 5. M4A (AAC in MP4 container)
      final m4a = resolveAsset('test/fixtures/salida_aac.m4a');
      if (m4a.existsSync()) {
        final m4aRes = await MiniaudioPlayer.analyzeAudio(
          m4a.path,
          replayGain: false,
          waveform: false,
          metadata: false,
        );
        expect(m4aRes.audioInfo.codec, equals('AAC'));
        expect(m4aRes.audioInfo.containerFormat, equals('MP4'));
        expect(m4aRes.audioInfo.lossless, isFalse);
      }
    });

    test(
        'DSF (DSD64) exposes rawSampleRate (2822400 Hz), decimated sampleRate (88200 Hz), bitsPerSample (1), and trailing ID3v2 metadata',
        () async {
      // Construct a synthetic valid DSF (DSD64 stereo) with a trailing ID3v2.3 chunk
      final id3Bytes = _buildId3v23Tag([
        _id3TextFrame('TIT2', 'DSD Audiophile Master'),
        _id3TextFrame('TPE1', 'DSD Ensemble'),
        _id3TextFrame('TALB', 'Direct Stream Sessions'),
        _id3TextFrame('TYER', '2026'),
      ]);

      const int channels = 2;
      const int rawSampleRate = 2822400; // DSD64
      const int blockSizePerChannel = 4096;
      const int audioDataBytes = blockSizePerChannel *
          channels; // 8192 bytes = 65536 bits = 32768 samples/ch
      const int sampleCountPerChannel = blockSizePerChannel * 8;
      const int dsdChunkSize = 28;
      const int fmtChunkSize = 52;
      const int dataChunkSize = 12 + audioDataBytes;
      final int metadataOffset = dsdChunkSize + fmtChunkSize + dataChunkSize;
      final int totalFileSize = metadataOffset + id3Bytes.length;

      final dsfBytes = BytesBuilder()
        // 'DSD ' chunk (28 bytes)
        ..add(ascii.encode('DSD '))
        ..add(_u64le(dsdChunkSize))
        ..add(_u64le(totalFileSize))
        ..add(_u64le(metadataOffset))
        // 'fmt ' chunk (52 bytes)
        ..add(ascii.encode('fmt '))
        ..add(_u64le(fmtChunkSize))
        ..add(_u32le(1)) // format version = 1
        ..add(_u32le(0)) // format ID = 0 (DSD raw)
        ..add(_u32le(2)) // channel type = stereo
        ..add(_u32le(channels))
        ..add(_u32le(rawSampleRate))
        ..add(_u32le(1)) // bits per sample = 1
        ..add(_u64le(sampleCountPerChannel))
        ..add(_u32le(blockSizePerChannel))
        ..add(_u32le(0)) // reserved
        // 'data' chunk (12 + audioDataBytes)
        ..add(ascii.encode('data'))
        ..add(_u64le(dataChunkSize))
        ..add(List<int>.filled(audioDataBytes, 0x69))
        // Trailing ID3v2 tag at metadataOffset
        ..add(id3Bytes);

      final result = await MiniaudioPlayer.analyzeAudio(
        dsfBytes.toBytes(),
        replayGain: false,
        waveform: false,
        metadata: true,
      );

      expect(result.audioInfo.codec, equals('DSD'));
      expect(result.audioInfo.containerFormat, equals('DSF'));
      expect(result.audioInfo.lossless, isTrue);
      expect(result.audioInfo.bitsPerSample, equals(1));
      expect(result.audioInfo.rawSampleRate, equals(2822400));
      expect(result.audioInfo.sampleRate, equals(88200));
      expect(result.audioInfo.bitrateMode, equals(BitrateMode.cbr));
      expect(result.audioInfo.fileSize, equals(totalFileSize));

      expect(result.metadata, isNotNull);
      expect(result.metadata!.title, equals('DSD Audiophile Master'));
      expect(result.metadata!.trackArtist, equals('DSD Ensemble'));
      expect(result.metadata!.album, equals('Direct Stream Sessions'));
      expect(result.metadata!.year, equals(2026));
      expect(result.metadata!.tagFormats, contains('ID3v2'));
      expect(result.metadata!.id3v2Version, equals(Id3v2Version.v3));
    });
  });

  group(
      'AudioMetadata Full Parsing (Core, Pictures, 63 Extended Tags, Chapters, Custom Tags)',
      () {
    test(
        'parses all 17 core tags, front/back cover pictures, extended tags, chapters, and custom tags from ID3v2 MP3',
        () async {
      final rawMp3 =
          resolveAsset('test/fixtures/cbr_noxing.mp3').readAsBytesSync();
      // Strip any existing ID3v2 tag on the fixture so our synthetic ID3v2 tag is the sole header tag
      final int existingId3Len = (rawMp3.length >= 10 &&
              rawMp3[0] == 0x49 &&
              rawMp3[1] == 0x44 &&
              rawMp3[2] == 0x33)
          ? 10 +
              (((rawMp3[6] & 0x7F) << 21) |
                  ((rawMp3[7] & 0x7F) << 14) |
                  ((rawMp3[8] & 0x7F) << 7) |
                  (rawMp3[9] & 0x7F))
          : 0;
      final baseMp3 = rawMp3.sublist(existingId3Len);

      final frontPng = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
      ]);
      final backJpeg = Uint8List.fromList([
        0xFF,
        0xD8,
        0xFF,
        0xE0,
        0x00,
        0x10,
        0x4A,
        0x46,
        0x49,
        0x46,
        0xFF,
        0xD9,
      ]);

      final id3 = _buildId3v23Tag([
        // 17 Core tags
        _id3TextFrame('TIT2', 'Symphony of Rust'),
        _id3TextFrame('TPE1', 'The Borrow Checkers'),
        _id3TextFrame('TALB', 'Zero Cost Abstractions'),
        _id3TextFrame('TPE2', 'Ferris Orchestra'),
        _id3TextFrame('TYER', '2026'),
        _id3TextFrame('TCON', 'Progressive Metal'),
        _id3TextFrame('TRCK', '4/12'),
        _id3TextFrame('TPOS', '1/2'),
        _id3UsltFrame('Line 1: Fearless concurrency\nLine 2: Memory safety'),
        _id3CommFrame('Recorded in 32-bit float'),
        _id3TextFrame('TBPM', '128.5'),
        _id3TxxxFrame('REPLAYGAIN_TRACK_GAIN', '-6.42 dB'),
        _id3TxxxFrame('REPLAYGAIN_TRACK_PEAK', '0.981234'),
        _id3TxxxFrame('REPLAYGAIN_ALBUM_GAIN', '-5.10 dB'),
        _id3TxxxFrame('REPLAYGAIN_ALBUM_PEAK', '0.995000'),
        // Extended tags
        _id3TextFrame('TSRC', 'USRC17607839'),
        _id3TextFrame('TCOM', 'Niklaus Wirth'),
        _id3TextFrame('TPE3', 'Herbert von Karajan'),
        _id3TextFrame('TEXT', 'Ada Lovelace'),
        _id3TextFrame('TPUB', 'DeepMind Records'),
        _id3TextFrame('TKEY', 'F#m'),
        _id3TextFrame('TMOO', 'Energetic'),
        _id3TextFrame('TCOP', '2026 DeepMind Records'),
        _id3TextFrame('TLAN', 'eng'),
        _id3TextFrame('TENC', 'Antigravity Encoder'),
        _id3TextFrame('TSSE', 'LAME 3.100 -V0'),
        _id3TextFrame('TIT1', 'Main Suite'),
        _id3TextFrame('TIT3', 'Op. 42'),
        _id3TxxxFrame(
            'MUSICBRAINZ_TRACKID', 'f4e7c9d8-1234-5678-9abc-def012345678'),
        _id3TxxxFrame('BARCODE', '0123456789012'),
        _id3TxxxFrame('CATALOGNUMBER', 'DM-2026-LP'),
        // Custom user tags
        _id3TxxxFrame('MY_CUSTOM_FIELD', 'CustomValue42'),
        _id3TxxxFrame('DJ_CUE_POINT', '00:45.200'),
        // Pictures (Front & Back cover)
        _id3ApicFrame(
          mime: 'image/png',
          picType: 3, // CoverFront
          description: 'Front Cover Art',
          imageBytes: frontPng,
        ),
        _id3ApicFrame(
          mime: 'image/jpeg',
          picType: 4, // CoverBack
          description: 'Back Tray Art',
          imageBytes: backJpeg,
        ),
        // Chapters
        _id3ChapFrame(
          elementId: 'chp1',
          title: 'I. Overture',
          startMs: 0,
          endMs: 1200,
        ),
        _id3ChapFrame(
          elementId: 'chp2',
          title: 'II. Finale',
          startMs: 1200,
          endMs: 2500,
        ),
      ]);

      final taggedMp3 = Uint8List.fromList([...id3, ...baseMp3]);

      final res = await MiniaudioPlayer.analyzeAudio(
        taggedMp3,
        replayGain: false,
        waveform: false,
        metadata: true,
      );

      final meta = res.metadata;
      expect(meta, isNotNull);
      expect(meta!.hasParsedTags, isTrue);

      // Core 17 fields
      expect(meta.title, equals('Symphony of Rust'));
      expect(meta.trackArtist, equals('The Borrow Checkers'));
      expect(meta.artist, equals('The Borrow Checkers'));
      expect(meta.album, equals('Zero Cost Abstractions'));
      expect(meta.albumArtist, equals('Ferris Orchestra'));
      expect(meta.year, equals(2026));
      expect(meta.genre, equals('Progressive Metal'));
      expect(meta.trackNumber, equals(4));
      expect(meta.trackTotal, equals(12));
      expect(meta.discNumber, equals(1));
      expect(meta.discTotal, equals(2));
      expect(meta.lyrics,
          equals('Line 1: Fearless concurrency\nLine 2: Memory safety'));
      expect(meta.comment, equals('Recorded in 32-bit float'));
      expect(meta.bpm, closeTo(128.5, 0.01));
      expect(meta.replayGainTrackGain, equals('-6.42 dB'));
      expect(meta.replayGainTrackPeak, equals('0.981234'));
      expect(meta.replayGainAlbumGain, equals('-5.10 dB'));
      expect(meta.replayGainAlbumPeak, equals('0.995000'));

      // Pictures
      expect(meta.pictures.length, equals(2));
      expect(meta.frontCover, isNotNull);
      expect(meta.frontCover!.pictureType, equals(PictureType.coverFront));
      expect(meta.frontCover!.mimeType, equals(MimeType.png));
      expect(meta.frontCover!.description, equals('Front Cover Art'));
      expect(meta.frontCover!.bytes, equals(frontPng));

      expect(meta.backCover, isNotNull);
      expect(meta.backCover!.pictureType, equals(PictureType.coverBack));
      expect(meta.backCover!.mimeType, equals(MimeType.jpeg));
      expect(meta.backCover!.description, equals('Back Tray Art'));
      expect(meta.backCover!.bytes, equals(backJpeg));

      // Extended 63 fields
      expect(meta.extended.isNotEmpty, isTrue);
      expect(meta.extended.isrc, equals('USRC17607839'));
      expect(meta.extended.composer, equals('Niklaus Wirth'));
      expect(meta.extended.conductor, equals('Herbert von Karajan'));
      expect(meta.extended.lyricist, equals('Ada Lovelace'));
      expect(meta.extended.publisher, equals('DeepMind Records'));
      expect(meta.extended.initialKey, equals('F#m'));
      expect(meta.extended.mood, equals('Energetic'));
      expect(meta.extended.copyrightMessage, equals('2026 DeepMind Records'));
      expect(meta.extended.language, equals('eng'));
      expect(meta.extended.encodedBy, equals('Antigravity Encoder'));
      expect(meta.extended.encoderSettings, equals('LAME 3.100 -V0'));
      expect(meta.extended.contentGroup, equals('Main Suite'));
      expect(meta.extended.trackSubtitle, equals('Op. 42'));
      expect(meta.extended.musicBrainzRecordingId,
          equals('f4e7c9d8-1234-5678-9abc-def012345678'));
      expect(meta.extended.barcode, equals('0123456789012'));
      expect(meta.extended.catalogNumber, equals('DM-2026-LP'));
      expect(meta.extended['isrc'], equals('USRC17607839'));
      expect(meta.extended.toMap()['composer'], equals('Niklaus Wirth'));

      // Chapters
      expect(meta.chapters.length, equals(2));
      expect(meta.chapters[0].title, equals('I. Overture'));
      expect(meta.chapters[0].startMs, equals(0));
      expect(meta.chapters[0].endMs, equals(1200));
      expect(meta.chapters[0].duration,
          equals(const Duration(milliseconds: 1200)));
      expect(meta.chapters[1].title, equals('II. Finale'));
      expect(meta.chapters[1].startMs, equals(1200));
      expect(meta.chapters[1].endMs, equals(2500));

      // Custom tags
      expect(meta.customTags['MY_CUSTOM_FIELD'], equals('CustomValue42'));
      expect(meta.customTags['DJ_CUE_POINT'], equals('00:45.200'));

      // Tag formats & ID3v2 version
      expect(meta.tagFormats, contains('ID3v2'));
      expect(meta.id3v2Version, equals(Id3v2Version.v3));
    });

    test('parses giant FLAC PICTURE block and WAV trailing LIST/INFO chunks',
        () async {
      final giantFlac =
          resolveAsset('test/fixtures/tripartite/giant_cover.flac');
      if (giantFlac.existsSync()) {
        final flacRes = await MiniaudioPlayer.analyzeAudio(
          giantFlac.path,
          replayGain: false,
          waveform: false,
          metadata: true,
        );
        expect(flacRes.metadata, isNotNull);
        expect(flacRes.metadata!.pictures, isNotEmpty);
        final cover = flacRes.metadata!.frontCover!;
        expect(cover.pictureType, equals(PictureType.coverFront));
        expect(cover.mimeType, equals(MimeType.jpeg));
        expect(cover.description, equals('Test Cover'));
        expect(cover.bytes.length, greaterThan(290000));
      }

      final trailingWav =
          resolveAsset('test/fixtures/tripartite/trailing_chunks.wav');
      if (trailingWav.existsSync()) {
        final wavRes = await MiniaudioPlayer.analyzeAudio(
          trailingWav.path,
          replayGain: false,
          waveform: false,
          metadata: true,
        );
        expect(wavRes.metadata, isNotNull);
        expect(wavRes.metadata!.title, equals('Test Title 1234'));
        expect(wavRes.metadata!.trackArtist, equals('Test Artist 123'));
        expect(wavRes.metadata!.tagFormats, contains('RiffInfo'));
      }
    });

    test(
        'player emits full AudioInfo always and full AudioMetadata when setMetadataEnabled(true) is toggled',
        () async {
      final baseMp3 =
          resolveAsset('test/fixtures/cbr_noxing.mp3').readAsBytesSync();
      final id3 = _buildId3v23Tag([
        _id3TextFrame('TIT2', 'Live Deck Track'),
        _id3TextFrame('TPE1', 'Deck Artist'),
        _id3TextFrame('TALB', 'Deck Album'),
      ]);
      final taggedMp3 = Uint8List.fromList([...id3, ...baseMp3]);

      final player = MiniaudioPlayer();
      try {
        final durationFuture = player.stream.duration
            .firstWhere((d) => d != null && d > Duration.zero)
            .timeout(const Duration(seconds: 3));

        await player.action.setQueue([AudioSource(taggedMp3)]);
        await player.action.play();

        final sw = Stopwatch()..start();
        while (
            player.state.audioInfo == null && sw.elapsedMilliseconds < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        // AudioInfo is ALWAYS populated even when metadataEnabled == false
        expect(player.state.metadataEnabled, isFalse);
        expect(player.state.metadata, isNull);
        expect(player.state.audioInfo, isNotNull);
        expect(player.state.audioInfo!.codec, equals('MP3'));
        expect(player.state.audioInfo!.containerFormat, equals('MP3'));
        expect(player.state.audioInfo!.lossless, isFalse);
        expect(player.state.audioInfo!.sampleRate, greaterThan(0));

        // Player state and stream duration are populated from AudioInfo
        expect(player.state.duration, isNotNull);
        expect(player.state.duration, equals(player.state.audioInfo!.duration));
        final streamDur = await durationFuture;
        expect(streamDur, equals(player.state.audioInfo!.duration));

        // Enabling metadata while track is open immediately parses and emits AudioMetadata
        final metaFuture = player.stream.metadata
            .firstWhere((m) => m != null && m.title == 'Live Deck Track')
            .timeout(const Duration(seconds: 2));
        await player.action.setMetadataEnabled(true);
        final streamedMeta = await metaFuture;

        expect(streamedMeta, isNotNull);
        expect(streamedMeta!.title, equals('Live Deck Track'));
        expect(streamedMeta.trackArtist, equals('Deck Artist'));
        expect(streamedMeta.album, equals('Deck Album'));
        expect(player.state.metadata?.title, equals('Live Deck Track'));

        // Disabling metadata clears state.metadata to null
        await player.action.setMetadataEnabled(false);
        expect(player.state.metadata, isNull);
      } finally {
        await player.dispose();
      }
    });
  });
}
