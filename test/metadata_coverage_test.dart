import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/concurrency_test_utils.dart';

File _resolveRelativeAsset(String relativePath) {
  final direct = File(relativePath);
  if (direct.existsSync()) return direct;
  final parent = File('../$relativePath');
  if (parent.existsSync()) return parent;
  return direct;
}

class _ExpectedPic {
  final PictureType type;
  final MimeType mime;
  final String? description;
  final int byteLength;

  const _ExpectedPic({
    required this.type,
    required this.mime,
    required this.description,
    required this.byteLength,
  });
}

class _ExpectedChapter {
  final String title;
  final int startMs;

  const _ExpectedChapter(this.title, this.startMs);
}

class _ExpectedTrack {
  final String relPath;
  final String reqTagFmt;
  final Id3v2Version? id3v2Version;
  final String? title;
  final String? trackArtist;
  final String? album;
  final String? albumArtist;
  final int? year;
  final String? genre;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final int? discTotal;
  final String? lyrics;
  final String? comment;
  final double? bpm;
  final String? replayGainTrackGain;
  final String? replayGainTrackPeak;
  final String? replayGainAlbumGain;
  final String? replayGainAlbumPeak;
  final List<_ExpectedPic> pictures;
  final List<_ExpectedChapter> chapters;
  final Map<String, String> customTags;
  final ExtendedMetadata extended;

  const _ExpectedTrack({
    required this.relPath,
    required this.reqTagFmt,
    required this.id3v2Version,
    required this.title,
    required this.trackArtist,
    required this.album,
    required this.albumArtist,
    required this.year,
    required this.genre,
    required this.trackNumber,
    required this.trackTotal,
    required this.discNumber,
    required this.discTotal,
    required this.lyrics,
    required this.comment,
    required this.bpm,
    required this.replayGainTrackGain,
    required this.replayGainTrackPeak,
    required this.replayGainAlbumGain,
    required this.replayGainAlbumPeak,
    required this.pictures,
    required this.chapters,
    required this.customTags,
    required this.extended,
  });
}

void _assertMetadataMatches(_ExpectedTrack exp, AudioMetadata meta) {
  expect(meta.tagFormats, contains(exp.reqTagFmt),
      reason: '${exp.relPath}: missing tagFormat ${exp.reqTagFmt} in ${meta.tagFormats}');
  expect(meta.id3v2Version, equals(exp.id3v2Version),
      reason: '${exp.relPath}: id3v2Version mismatch');

  // 17 Core Fields
  expect(meta.title, equals(exp.title), reason: '${exp.relPath}: title');
  expect(meta.trackArtist, equals(exp.trackArtist),
      reason: '${exp.relPath}: trackArtist');
  expect(meta.album, equals(exp.album), reason: '${exp.relPath}: album');
  expect(meta.albumArtist, equals(exp.albumArtist),
      reason: '${exp.relPath}: albumArtist');
  expect(meta.year, equals(exp.year), reason: '${exp.relPath}: year');
  expect(meta.genre, equals(exp.genre), reason: '${exp.relPath}: genre');
  expect(meta.trackNumber, equals(exp.trackNumber),
      reason: '${exp.relPath}: trackNumber');
  expect(meta.trackTotal, equals(exp.trackTotal),
      reason: '${exp.relPath}: trackTotal');
  expect(meta.discNumber, equals(exp.discNumber),
      reason: '${exp.relPath}: discNumber');
  expect(meta.discTotal, equals(exp.discTotal),
      reason: '${exp.relPath}: discTotal');
  expect(meta.lyrics, equals(exp.lyrics), reason: '${exp.relPath}: lyrics');
  expect(meta.comment, equals(exp.comment), reason: '${exp.relPath}: comment');
  if (exp.bpm != null) {
    expect(meta.bpm, isNotNull, reason: '${exp.relPath}: bpm missing');
    expect(meta.bpm!, closeTo(exp.bpm!, 0.05),
        reason: '${exp.relPath}: bpm value mismatch');
  } else {
    expect(meta.bpm, isNull, reason: '${exp.relPath}: expected null bpm');
  }
  expect(meta.replayGainTrackGain, equals(exp.replayGainTrackGain),
      reason: '${exp.relPath}: replayGainTrackGain');
  expect(meta.replayGainTrackPeak, equals(exp.replayGainTrackPeak),
      reason: '${exp.relPath}: replayGainTrackPeak');
  expect(meta.replayGainAlbumGain, equals(exp.replayGainAlbumGain),
      reason: '${exp.relPath}: replayGainAlbumGain');
  expect(meta.replayGainAlbumPeak, equals(exp.replayGainAlbumPeak),
      reason: '${exp.relPath}: replayGainAlbumPeak');

  // Pictures (all embedded images + MIME + PictureType + Description + magic bytes + byte length)
  expect(meta.pictures.length, equals(exp.pictures.length),
      reason: '${exp.relPath}: picture count mismatch (got ${meta.pictures})');
  for (var i = 0; i < exp.pictures.length; i++) {
    final ep = exp.pictures[i];
    final ap = meta.pictures[i];
    expect(ap.pictureType, equals(ep.type),
        reason: '${exp.relPath}: pic[$i] pictureType');
    expect(ap.mimeType, equals(ep.mime),
        reason: '${exp.relPath}: pic[$i] mimeType');
    expect(ap.description, equals(ep.description),
        reason: '${exp.relPath}: pic[$i] description');
    expect(ap.bytes.length, equals(ep.byteLength),
        reason: '${exp.relPath}: pic[$i] byteLength');
    if (ep.mime == MimeType.jpeg) {
      expect(ap.bytes.sublist(0, 3), equals([0xFF, 0xD8, 0xFF]),
          reason: '${exp.relPath}: pic[$i] JPEG magic header');
    } else if (ep.mime == MimeType.png) {
      expect(ap.bytes.sublist(0, 4), equals([0x89, 0x50, 0x4E, 0x47]),
          reason: '${exp.relPath}: pic[$i] PNG magic header');
    } else if (ep.mime == MimeType.webp) {
      expect(String.fromCharCodes(ap.bytes.sublist(0, 4)), equals('RIFF'),
          reason: '${exp.relPath}: pic[$i] WebP RIFF header');
      expect(String.fromCharCodes(ap.bytes.sublist(8, 12)), equals('WEBP'),
          reason: '${exp.relPath}: pic[$i] WebP WEBP header');
    }
  }

  // Chapters (sorted order + timestamps + titles)
  expect(meta.chapters.length, equals(exp.chapters.length),
      reason: '${exp.relPath}: chapters count');
  var prevStart = -1;
  for (var i = 0; i < exp.chapters.length; i++) {
    final ec = exp.chapters[i];
    final ac = meta.chapters[i];
    expect(ac.title, equals(ec.title),
        reason: '${exp.relPath}: chapter[$i] title');
    expect(ac.startMs, equals(ec.startMs),
        reason: '${exp.relPath}: chapter[$i] startMs');
    expect(ac.startMs, greaterThanOrEqualTo(prevStart),
        reason: '${exp.relPath}: chapter[$i] non-monotonic startMs');
    expect(ac.endMs, greaterThanOrEqualTo(ac.startMs),
        reason: '${exp.relPath}: chapter[$i] endMs < startMs');
    prevStart = ac.startMs;
  }

  // Custom tags (exact match -> zero leaked container/standard/extended tags)
  expect(meta.customTags, equals(exp.customTags),
      reason: '${exp.relPath}: customTags mismatch (leaks or missing)');

  // Extended 62 fields
  expect(meta.extended.toMap(), equals(exp.extended.toMap()),
      reason: '${exp.relPath}: extended fields mismatch');
}

const List<_ExpectedTrack> _expectations27 = [
  _ExpectedTrack(
    relPath: "example/assets/music/01_Apex_Momentum.mp3",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Apex Momentum",
    trackArtist: "Elena Vance",
    album: "Kinetic Landscapes",
    albumArtist: "Chomusuke Ensemble",
    year: 2026,
    genre: "Electronic",
    trackNumber: 1,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "[00:04.00]Rise through electric haze\n[00:16.00]Pulse locks the midnight maze\n[00:32.00]Apex momentum never fades",
    comment: "Royalty-free fixture 01_Apex_Momentum.mp3 generated for miniaudio_player",
    bpm: 128.0,
    replayGainTrackGain: "-5.80 dB",
    replayGainTrackPeak: "1.071519",
    replayGainAlbumGain: "-5.80 dB",
    replayGainAlbumPeak: "1.071519",
    pictures: [_ExpectedPic(type: PictureType.icon, mime: MimeType.png, description: "32x32 Icon", byteLength: 1913), _ExpectedPic(type: PictureType.leaflet, mime: MimeType.webp, description: "Leaflet Card", byteLength: 18406), _ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 47318), _ExpectedPic(type: PictureType.coverBack, mime: MimeType.png, description: "Back Cover", byteLength: 85149)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 58924), _ExpectedChapter("Climax & Outro", 117849)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "64be8675-2edb-aa0a-3495-669ae8a98127", musicBrainzTrackId: "23c28144-87c7-801b-1a3a-d5d4149cf155", musicBrainzReleaseId: "0494243a-b019-25ed-7a71-6cc5e619120a", musicBrainzReleaseGroupId: "0525f62f-66ec-7909-9190-e197dfaf2701", musicBrainzArtistId: "96ee49a4-9c7e-0a66-e1ca-85e61b82a5c9", musicBrainzReleaseArtistId: "a017c278-3d70-451b-af46-5d925e783b1a", musicBrainzWorkId: "04a6785e-a3c2-bdc2-fb56-0b0238683f28", musicBrainzReleaseType: "Album", acoustId: "71bdc0f0-0f43-9afd-fe33-953db3b12c82", acoustIdFingerprint: "AQADt64be86752edbaa0a3495669ae8a9_CC0_MINIAUDIO_01", isrc: "ZZCHM2600001", barcode: "000000000001", catalogNumber: "MAP-CAT-001", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Elena Vance", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Elena Vance (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Elena Vance", composer: "Elena Vance", originalLyricist: "Elena Vance", recordingDate: "2026-05-15", releaseDate: "2026-06-01", originalReleaseDate: "2026-04-10", initialKey: "Am", color: "Midnight Indigo", mood: "Energetic", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/01_Apex_Momentum.mp3", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2026) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #01 (mp3_vbr_max) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-01-mp3_vbr_max", podcastKeywords: "audio, rust, flutter, mp3_vbr_max, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[MP3_VBR_MAX Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Apex_Momentum.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 01"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/02_Bailando_con_tu_recuerdo.opus",
    reqTagFmt: "VorbisComments",
    id3v2Version: null,
    title: "Bailando con tu recuerdo",
    trackArtist: "Mateo Valdés",
    album: "Noches de Brisa",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Latin Pop",
    trackNumber: 2,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "[00:05.00]Bajo luces suaves vuelve tu voz\n[00:18.00]Bailando lento entre el reloj\n[00:35.00]Tu recuerdo marca el compás",
    comment: "Royalty-free fixture 02_Bailando_con_tu_recuerdo.opus generated for miniaudio_player",
    bpm: 102.0,
    replayGainTrackGain: "-6.50 dB",
    replayGainTrackPeak: "1.035142",
    replayGainAlbumGain: "-6.50 dB",
    replayGainAlbumPeak: "1.035142",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 13583), _ExpectedPic(type: PictureType.coverBack, mime: MimeType.png, description: "Back Cover", byteLength: 32643)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 59752), _ExpectedChapter("Climax & Outro", 119505)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "3c5294fd-0558-5a37-c838-3c41855f8d92", musicBrainzTrackId: "c4bc39f2-8f2a-7d50-19be-22207090c9c0", musicBrainzReleaseId: "b6adef45-c58e-4f70-e19c-3e7d59249c0a", musicBrainzReleaseGroupId: "a0d1f385-9696-07c5-39a7-6afe61bb67c8", musicBrainzArtistId: "e2bea95e-b539-b7c3-a3c0-7075d6ed724c", musicBrainzReleaseArtistId: "0845c485-e236-678a-cf60-f3957f05bd51", musicBrainzWorkId: "8b6dcf69-356a-8de0-0977-3b8f6259d9a0", musicBrainzReleaseType: "Album", acoustId: "ce15f408-f85f-94f5-870d-adeb1ab1c8c6", acoustIdFingerprint: "AQADt3c5294fd05585a37c8383c41855f_CC0_MINIAUDIO_02", isrc: "ZZCHM2600002", barcode: "000000000002", catalogNumber: "MAP-CAT-002", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Mateo Valdés", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Mateo Valdés (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Mateo Valdés", composer: "Mateo Valdés", originalLyricist: "Mateo Valdés", recordingDate: "2025-05-15", releaseDate: "2025-06-01", originalReleaseDate: "2025-04-10", initialKey: "Dm", color: "Midnight Indigo", mood: "Nostalgic", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/02_Bailando_con_tu_recuerdo.opus", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #02 (opus) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-02-opus", podcastKeywords: "audio, rust, flutter, opus, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[OPUS Reference Edition]", language: "spa", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Bailando_con_tu_recuerdo.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 02"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/03_Before_The_Dawn_cbr_noxing.mp3",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Before The Dawn",
    trackArtist: "Clara Lindqvist",
    album: "Radiant Horizons",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Progressive House",
    trackNumber: 3,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Silent streets before the dawn, silver embers linger on.",
    comment: "Royalty-free fixture 03_Before_The_Dawn_cbr_noxing.mp3 generated for miniaudio_player",
    bpm: 124.0,
    replayGainTrackGain: "-2.40 dB",
    replayGainTrackPeak: "0.988553",
    replayGainAlbumGain: "-2.40 dB",
    replayGainAlbumPeak: "0.988553",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 30742)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 59992), _ExpectedChapter("Climax & Outro", 119985)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "f3437084-1a37-5838-378c-db60c260a1bb", musicBrainzTrackId: "9d70ee8a-7c68-6e41-78e1-18a8960b5115", musicBrainzReleaseId: "e3308ed6-dd6c-a96e-6f06-0485972f459f", musicBrainzReleaseGroupId: "b2e97400-545b-840d-1003-9175a9cbb9f8", musicBrainzArtistId: "21ebbbe3-ba49-1d19-c411-6a03e616e0da", musicBrainzReleaseArtistId: "75e65486-b873-a292-073f-832bce9adc45", musicBrainzWorkId: "65580ea8-141c-6e44-f6c0-2cb62164fdb3", musicBrainzReleaseType: "Album", acoustId: "1e451c6f-8850-a34f-25b7-602edeab2287", acoustIdFingerprint: "AQADtf34370841a375838378cdb60c260_CC0_MINIAUDIO_03", isrc: "ZZCHM2600003", barcode: "000000000003", catalogNumber: "MAP-CAT-003", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Clara Lindqvist", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Clara Lindqvist (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Clara Lindqvist", composer: "Clara Lindqvist", originalLyricist: "Clara Lindqvist", recordingDate: "2025-05-15", releaseDate: "2025-06-01", originalReleaseDate: "2025-04-10", initialKey: "F#m", color: "Midnight Indigo", mood: "Uplifting", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/03_Before_The_Dawn_cbr_noxing.mp3", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #03 (mp3_cbr_mono_noxing) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-03-mp3_cbr_mono_noxing", podcastKeywords: "audio, rust, flutter, mp3_cbr_mono_noxing, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[MP3_CBR_MONO_NOXING Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Before_The_Dawn.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 03"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/04_Belaya_Tishina.flac",
    reqTagFmt: "VorbisComments",
    id3v2Version: null,
    title: "Белая тишина (Belaya Tishina)",
    trackArtist: "Dmitri Volkov",
    album: "За краем веков",
    albumArtist: "Chomusuke Ensemble",
    year: 2024,
    genre: "Russian Folk-Ballad",
    trackNumber: 4,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Снег ложится на поля, спит под небом тишина.",
    comment: "Royalty-free fixture 04_Belaya_Tishina.flac generated for miniaudio_player",
    bpm: 84.0,
    replayGainTrackGain: "-6.60 dB",
    replayGainTrackPeak: "0.977237",
    replayGainAlbumGain: "-6.60 dB",
    replayGainAlbumPeak: "0.977237",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 35391), _ExpectedPic(type: PictureType.coverBack, mime: MimeType.png, description: "Back Cover", byteLength: 79546), _ExpectedPic(type: PictureType.leaflet, mime: MimeType.webp, description: "Leaflet WebP", byteLength: 15800)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 59613), _ExpectedChapter("Climax & Outro", 119226)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "3ad521f1-72e7-6e7d-b24f-442f7512fcb3", musicBrainzTrackId: "7e5ea7d9-f5ba-1e80-12e3-fbea0c62b1ee", musicBrainzReleaseId: "640a8aa3-1f07-9c13-0efa-91491de3b88c", musicBrainzReleaseGroupId: "4c566554-487e-093f-6582-782aa4a239bb", musicBrainzArtistId: "79007f71-1531-6d70-f0a8-37e16ca2379d", musicBrainzReleaseArtistId: "7bacfa41-f9dd-0595-d44e-ac519e75d253", musicBrainzWorkId: "7b5c213b-a252-2280-5727-085880533413", musicBrainzReleaseType: "Album", acoustId: "2b426fab-ae86-2583-a447-0463ef10ab00", acoustIdFingerprint: "AQADt3ad521f172e76e7db24f442f7512_CC0_MINIAUDIO_04", isrc: "ZZCHM2600004", barcode: "000000000004", catalogNumber: "MAP-CAT-004", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Dmitri Volkov", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Dmitri Volkov (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Dmitri Volkov", composer: "Dmitri Volkov", originalLyricist: "Dmitri Volkov", recordingDate: "2024-05-15", releaseDate: "2024-06-01", originalReleaseDate: "2024-04-10", initialKey: "Cm", color: "Midnight Indigo", mood: "Serene", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/04_Belaya_Tishina.flac", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2024) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #04 (flac_24) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-04-flac_24", podcastKeywords: "audio, rust, flutter, flac_24, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[FLAC_24 Reference Edition]", language: "rus", script: "Cyrl", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Belaya_Tishina.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 04"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/05_Burning_in_the_Electric_Light.ogg",
    reqTagFmt: "VorbisComments",
    id3v2Version: null,
    title: "Burning in the Electric Light",
    trackArtist: "The Meridian Echo",
    album: "After the Glare",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Alternative Rock",
    trackNumber: 5,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "[00:08.00]Static hums beneath the wire\n[00:24.00]Burning bright in neon fire",
    comment: "Royalty-free fixture 05_Burning_in_the_Electric_Light.ogg generated for miniaudio_player",
    bpm: 136.0,
    replayGainTrackGain: "-6.40 dB",
    replayGainTrackPeak: "1.035142",
    replayGainAlbumGain: "-6.40 dB",
    replayGainAlbumPeak: "1.035142",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 48065), _ExpectedPic(type: PictureType.coverBack, mime: MimeType.png, description: "Back Cover", byteLength: 85110)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 59551), _ExpectedChapter("Climax & Outro", 119102)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "a693532a-ad24-e9bc-ab20-6ae9fdd3cd2c", musicBrainzTrackId: "45a70069-f3e0-d54d-7b88-acf7224e0b0c", musicBrainzReleaseId: "c0a026c2-2d25-59f1-0ef1-638b234fa97b", musicBrainzReleaseGroupId: "d01c057d-4c6c-7923-f006-aab8ffa6e2c7", musicBrainzArtistId: "8a128748-25aa-ad28-96fa-9cc612c3ceb3", musicBrainzReleaseArtistId: "1155e8ea-a811-2135-0453-13150b58b497", musicBrainzWorkId: "19412ae3-899f-7509-5568-208a7c441168", musicBrainzReleaseType: "Album", acoustId: "2b1d12fa-49d8-87f7-a3e8-98804794c5ba", acoustIdFingerprint: "AQADta693532aad24e9bcab206ae9fdd3_CC0_MINIAUDIO_05", isrc: "ZZCHM2600005", barcode: "000000000005", catalogNumber: "MAP-CAT-005", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "The Meridian Echo", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "The Meridian Echo (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "The Meridian Echo", composer: "The Meridian Echo", originalLyricist: "The Meridian Echo", recordingDate: "2025-05-15", releaseDate: "2025-06-01", originalReleaseDate: "2025-04-10", initialKey: "Em", color: "Midnight Indigo", mood: "Driving", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/05_Burning_in_the_Electric_Light.ogg", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #05 (ogg_vorbis) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-05-ogg_vorbis", podcastKeywords: "audio, rust, flutter, ogg_vorbis, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[OGG_VORBIS Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Burning_in_the_Electric_Light.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 05"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/06_Calculated_Motion_aac.m4a",
    reqTagFmt: "iTunes",
    id3v2Version: null,
    title: "Calculated Motion",
    trackArtist: "Kairo Tanaka",
    album: "Active State",
    albumArtist: "Chomusuke Ensemble",
    year: 2026,
    genre: "Glitch Pop",
    trackNumber: 6,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Every step computed clean, shifting light behind the screen.",
    comment: "Fixture 06_Calculated_Motion_aac.m4a (CC0)",
    bpm: 118.0,
    replayGainTrackGain: "-5.20 dB",
    replayGainTrackPeak: "1.047129",
    replayGainAlbumGain: null,
    replayGainAlbumPeak: null,
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: null, byteLength: 50634), _ExpectedPic(type: PictureType.coverFront, mime: MimeType.png, description: null, byteLength: 85457)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Section", 59969), _ExpectedChapter("Outro", 119938)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "861c3e52-01e0-9dd3-c8fb-fe7e52d58cdc", isrc: "ZZCHM2600006", barcode: "000000000006", catalogNumber: "MAP-CAT-006", conductor: "Nadia Alverez", producer: "Chomusuke Production", label: "Chomusuke Open Records", composer: "Kairo Tanaka", recordingDate: "2026-05-15", initialKey: "Gm", mood: "Focused", copyrightMessage: "CC0 1.0 Public Domain Dedication (2026) Chomusuke Studio", podcastDescription: "Copyright-free fixture #06 (m4a_aac) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-06-m4a_aac", podcastKeywords: "audio, rust, flutter, m4a_aac, lossless-test", contentGroup: "Miniaudio Format Matrix (29 Tracks)", parentalAdvisory: "0", encoderSoftware: "FFmpeg + Mutagen + Pillow"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/07_Fevered_Strings_alac.m4a",
    reqTagFmt: "iTunes",
    id3v2Version: null,
    title: "Fevered Strings",
    trackArtist: "Aria Montgomery",
    album: "The Kinetic Suite",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Symphonic House",
    trackNumber: 7,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Velvet bows cut through the floor as brass awakens.",
    comment: "Fixture 07_Fevered_Strings_alac.m4a (CC0)",
    bpm: 122.0,
    replayGainTrackGain: "-5.90 dB",
    replayGainTrackPeak: "1.023293",
    replayGainAlbumGain: null,
    replayGainAlbumPeak: null,
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: null, byteLength: 43617)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Section", 58506), _ExpectedChapter("Outro", 117013)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "214772f7-9876-5865-afd4-6315d35e8767", isrc: "ZZCHM2600007", barcode: "000000000007", catalogNumber: "MAP-CAT-007", conductor: "Nadia Alverez", producer: "Chomusuke Production", label: "Chomusuke Open Records", composer: "Aria Montgomery", recordingDate: "2025-05-15", initialKey: "Bm", mood: "Dramatic", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", podcastDescription: "Copyright-free fixture #07 (m4a_alac) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-07-m4a_alac", podcastKeywords: "audio, rust, flutter, m4a_alac, lossless-test", contentGroup: "Miniaudio Format Matrix (29 Tracks)", parentalAdvisory: "0", encoderSoftware: "FFmpeg + Mutagen + Pillow"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/08_Firelight_Promise_24bit_mono.wav",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Firelight Promise",
    trackArtist: "Nolan Reid",
    album: "Midnight Solstice",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Progressive House",
    trackNumber: 8,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Hold the ember till the morning rain.",
    comment: "Royalty-free fixture 08_Firelight_Promise_24bit_mono.wav generated for miniaudio_player",
    bpm: 120.0,
    replayGainTrackGain: "-2.50 dB",
    replayGainTrackPeak: "1.000000",
    replayGainAlbumGain: "-2.50 dB",
    replayGainAlbumPeak: "1.000000",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 24683)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 59714), _ExpectedChapter("Climax & Outro", 119428)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "45ccaea9-1aa1-998a-86b1-c63b7e66cc91", musicBrainzTrackId: "402f1e7b-6df7-bfa9-f49a-dd500b252049", musicBrainzReleaseId: "a141edb2-bb16-28d6-9e8f-b0f1f316d93f", musicBrainzReleaseGroupId: "541529b3-0efd-11d2-beb8-6dcc26e74646", musicBrainzArtistId: "d6a800e8-193a-7fdb-db0d-6a49034f2cb7", musicBrainzReleaseArtistId: "060b3786-b7ec-16c5-8a12-d5aa40c0375a", musicBrainzWorkId: "8fad814e-ebe2-4358-def9-87ba4e5f7b32", musicBrainzReleaseType: "Album", acoustId: "08d7ffe6-7826-2c9b-aff3-7d40196fbbfc", acoustIdFingerprint: "AQADt45ccaea91aa1998a86b1c63b7e66_CC0_MINIAUDIO_08", isrc: "ZZCHM2600008", barcode: "000000000008", catalogNumber: "MAP-CAT-008", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Nolan Reid", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Nolan Reid (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Nolan Reid", composer: "Nolan Reid", originalLyricist: "Nolan Reid", recordingDate: "2025-05-15", releaseDate: "2025-06-01", originalReleaseDate: "2025-04-10", initialKey: "G", color: "Midnight Indigo", mood: "Warm", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/08_Firelight_Promise_24bit_mono.wav", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #08 (wav_24_mono) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-08-wav_24_mono", podcastKeywords: "audio, rust, flutter, wav_24_mono, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[WAV_24_MONO Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Firelight_Promise.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 08"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/09_Flesh_and_Chrome.wv",
    reqTagFmt: "APE",
    id3v2Version: null,
    title: "Flesh and Chrome",
    trackArtist: "Vespera 9",
    album: "Velvet Machine",
    albumArtist: "Chomusuke Ensemble",
    year: 2026,
    genre: "Melodic Techno",
    trackNumber: 9,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Alloy skin meets human pulse in silver haze.",
    comment: "Royalty-free fixture 09_Flesh_and_Chrome.wv generated for miniaudio_player",
    bpm: 130.0,
    replayGainTrackGain: "-5.60 dB",
    replayGainTrackPeak: "1.000000",
    replayGainAlbumGain: "-5.60 dB",
    replayGainAlbumPeak: "1.000000",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "cover.jpg", byteLength: 26067), _ExpectedPic(type: PictureType.coverBack, mime: MimeType.png, description: "cover_back.png", byteLength: 64424)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 60898), _ExpectedChapter("Climax & Outro", 121796)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "8e5ec00e-b91b-e9f0-f8ea-316f5693a44a", musicBrainzTrackId: "d5dc5b2c-d9e2-a5c8-04a6-b75019294fef", musicBrainzReleaseId: "3e625cf1-dab8-3ac1-a2a2-b66b776483d3", musicBrainzReleaseGroupId: "f04adb76-8f7e-4d1b-91be-0cda437671ef", musicBrainzArtistId: "5fe2757d-4c9d-635c-f035-90980fe66bc4", musicBrainzReleaseArtistId: "828e5303-957c-2e81-f00c-c9821d8fdfbe", musicBrainzWorkId: "3645bb9d-0fd0-31fc-33fe-568ada8351fb", musicBrainzReleaseType: "Album", acoustId: "2cb76de6-64c5-045d-a487-19a70fc36f8f", acoustIdFingerprint: "AQADt8e5ec00eb91be9f0f8ea316f5693_CC0_MINIAUDIO_09", isrc: "ZZCHM2600009", barcode: "000000000009", catalogNumber: "MAP-CAT-009", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Vespera 9", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Vespera 9 (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Vespera 9", composer: "Vespera 9", originalLyricist: "Vespera 9", recordingDate: "2026-05-15", releaseDate: "2026-06-01", originalReleaseDate: "2026-04-10", initialKey: "C#m", color: "Midnight Indigo", mood: "Industrial", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/09_Flesh_and_Chrome.wv", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2026) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #09 (wavpack) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-09-wavpack", podcastKeywords: "audio, rust, flutter, wavpack, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[WAVPACK Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Flesh_and_Chrome.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 09"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/10_La_cicatriz_del_andén.aac",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v3,
    title: "La cicatriz del andén",
    trackArtist: "Lucía Benítez",
    album: "Viajeros del tiempo perdido",
    albumArtist: "Chomusuke Ensemble",
    year: 2024,
    genre: "Theatrical Art-Rock",
    trackNumber: 10,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Último tren sin equipaje en el andén gris.",
    comment: "Royalty-free fixture 10_La_cicatriz_del_andén.aac generated for miniaudio_player",
    bpm: 96.0,
    replayGainTrackGain: "-6.70 dB",
    replayGainTrackPeak: "1.011579",
    replayGainAlbumGain: "-6.70 dB",
    replayGainAlbumPeak: "1.011579",
    pictures: [_ExpectedPic(type: PictureType.icon, mime: MimeType.png, description: "Compact Icon", byteLength: 1640)],
    chapters: [],
    customTags: {},
    extended: ExtendedMetadata(recordingDate: "2024-05-15"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/11_Mar_de_cristal.mka",
    reqTagFmt: "Matroska",
    id3v2Version: null,
    title: "Mar de cristal",
    trackArtist: "Camila Solís",
    album: "Arquitectura de luz",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Melodic House",
    trackNumber: 11,
    trackTotal: 29,
    discNumber: null,
    discTotal: null,
    lyrics: "Reflejos azules sobre el agua inmóvil.",
    comment: "Fixture 11_Mar_de_cristal.mka",
    bpm: 121.0,
    replayGainTrackGain: "-6.00 dB",
    replayGainTrackPeak: "1.011579",
    replayGainAlbumGain: null,
    replayGainAlbumPeak: null,
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "cover.jpg", byteLength: 46785), _ExpectedPic(type: PictureType.coverBack, mime: MimeType.png, description: "cover_back.png", byteLength: 73248)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Section", 60310), _ExpectedChapter("Outro Fade", 120620)],
    customTags: {},
    extended: ExtendedMetadata(musicBrainzRecordingId: "05c44591-5ada-2fe4-cd27-6bcd8c9e83fb", isrc: "ZZCHM2600011", publisher: "Chomusuke Open Audio Press", composer: "Camila Solís", recordingDate: "2025-05-15", initialKey: "D", mood: "Ethereal", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", encoderSoftware: "FFmpeg + Mutagen + Pillow"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/12_Mi_más_bonita_coincidencia_24bit_stereo.wav",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Mi más bonita coincidencia",
    trackArtist: "Julián Cabrera",
    album: "Cielo de Febrero",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Bachata",
    trackNumber: 12,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Entre mil calles te volví a encontrar sin avisar.",
    comment: "Royalty-free fixture 12_Mi_más_bonita_coincidencia_24bit_stereo.wav generated for miniaudio_player",
    bpm: 132.0,
    replayGainTrackGain: "-6.50 dB",
    replayGainTrackPeak: "1.035142",
    replayGainAlbumGain: "-6.50 dB",
    replayGainAlbumPeak: "1.035142",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 32348)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 60480), _ExpectedChapter("Climax & Outro", 120960)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "bddb2dde-c564-06da-6625-4ace2be37d82", musicBrainzTrackId: "c9b6d625-e745-a74b-7762-cb69305fd26c", musicBrainzReleaseId: "87373fbe-cc16-4727-295f-153ba94555b0", musicBrainzReleaseGroupId: "3703a480-ae54-cef2-4020-db6c61568c34", musicBrainzArtistId: "b4a1741e-bb2d-f10f-3dd4-27a951ac3d98", musicBrainzReleaseArtistId: "c5925d4c-85af-56da-be4b-d032261fa092", musicBrainzWorkId: "796f5668-3c65-e5c7-189f-2a0ddd5d3212", musicBrainzReleaseType: "Album", acoustId: "ffc011b7-da52-a5e9-cf44-040cefa9e1e9", acoustIdFingerprint: "AQADtbddb2ddec56406da66254ace2be3_CC0_MINIAUDIO_12", isrc: "ZZCHM2600012", barcode: "000000000012", catalogNumber: "MAP-CAT-012", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Julián Cabrera", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Julián Cabrera (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Julián Cabrera", composer: "Julián Cabrera", originalLyricist: "Julián Cabrera", recordingDate: "2025-05-15", releaseDate: "2025-06-01", originalReleaseDate: "2025-04-10", initialKey: "Bb", color: "Midnight Indigo", mood: "Romantic", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/12_Mi_m%C3%A1s_bonita_coincidencia_24bit_stereo.wav", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #12 (wav_24_stereo) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-12-wav_24_stereo", podcastKeywords: "audio, rust, flutter, wav_24_stereo, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[WAV_24_STEREO Reference Edition]", language: "spa", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Mi_más_bonita_coincidencia.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 12"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/13_Overture_for_the_Floor.webm",
    reqTagFmt: "Matroska",
    id3v2Version: null,
    title: "Overture for the Floor",
    trackArtist: "Studio Monochrome",
    album: "Concrete Conservatory",
    albumArtist: "Chomusuke Ensemble",
    year: 2026,
    genre: "Melodic Progressive House",
    trackNumber: 13,
    trackTotal: 29,
    discNumber: null,
    discTotal: null,
    lyrics: "Echoes rise from timber vaults.",
    comment: "Fixture 13_Overture_for_the_Floor.webm",
    bpm: 125.0,
    replayGainTrackGain: "-5.80 dB",
    replayGainTrackPeak: "1.047129",
    replayGainAlbumGain: null,
    replayGainAlbumPeak: null,
    pictures: [],
    chapters: [],
    customTags: {},
    extended: ExtendedMetadata(musicBrainzRecordingId: "61535de6-46af-efeb-265f-9f66228a1ced", isrc: "ZZCHM2600013", publisher: "Chomusuke Open Audio Press", composer: "Studio Monochrome", recordingDate: "2026-05-15", initialKey: "F", mood: "Atmospheric", copyrightMessage: "CC0 1.0 Public Domain Dedication (2026) Chomusuke Studio", encoderSoftware: "FFmpeg + Mutagen + Pillow"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/14_Painting_the_Sky.mkv",
    reqTagFmt: "Matroska",
    id3v2Version: null,
    title: "Painting the Sky",
    trackArtist: "Sora Takashi",
    album: "Prism Flight",
    albumArtist: "Chomusuke Ensemble",
    year: 2026,
    genre: "Melodic Future Bass",
    trackNumber: 14,
    trackTotal: 29,
    discNumber: null,
    discTotal: null,
    lyrics: "Brushstrokes of violet scatter over clouds.",
    comment: "Fixture 14_Painting_the_Sky.mkv",
    bpm: 142.0,
    replayGainTrackGain: "-5.70 dB",
    replayGainTrackPeak: "1.059254",
    replayGainAlbumGain: null,
    replayGainAlbumPeak: null,
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "cover.jpg", byteLength: 150802)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Section", 59743), _ExpectedChapter("Outro Fade", 119486)],
    customTags: {},
    extended: ExtendedMetadata(musicBrainzRecordingId: "c91cfd4e-9bcc-89c9-14c9-9a972aa6bc6a", isrc: "ZZCHM2600014", publisher: "Chomusuke Open Audio Press", composer: "Sora Takashi", recordingDate: "2026-05-15", initialKey: "Ab", mood: "Euphoric", copyrightMessage: "CC0 1.0 Public Domain Dedication (2026) Chomusuke Studio", encoderSoftware: "FFmpeg + Mutagen + Pillow"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/15_Resting_At_Your_Feet.mp2",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Resting At Your Feet",
    trackArtist: "Helena Novak",
    album: "Cathedral Of Silence",
    albumArtist: "Chomusuke Ensemble",
    year: 2024,
    genre: "Dark Art Pop",
    trackNumber: 15,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Stone arches keep every whispered vow.",
    comment: "Royalty-free fixture 15_Resting_At_Your_Feet.mp2 generated for miniaudio_player",
    bpm: 78.0,
    replayGainTrackGain: "-5.40 dB",
    replayGainTrackPeak: "1.000000",
    replayGainAlbumGain: "-5.40 dB",
    replayGainAlbumPeak: "1.000000",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 29640)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 55101), _ExpectedChapter("Climax & Outro", 110202)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "248f8d0e-092f-8a67-e6df-ae820a3cd5b7", musicBrainzTrackId: "1abe211e-7c98-7531-3c19-dac8ba57c8b1", musicBrainzReleaseId: "a5efabc6-5b5a-2843-5d30-462e5fe944a5", musicBrainzReleaseGroupId: "933d5640-f807-6e56-f57b-b1db684add64", musicBrainzArtistId: "03a0e0e9-349b-dd18-8090-4713e758c7c2", musicBrainzReleaseArtistId: "61424680-4c95-b99e-2606-9c289fc8010e", musicBrainzWorkId: "60577b47-03dc-5b8b-5c47-aef3b0cd9a30", musicBrainzReleaseType: "Album", acoustId: "09982e0d-0cf9-ab9c-9593-becde5b94d05", acoustIdFingerprint: "AQADt248f8d0e092f8a67e6dfae820a3c_CC0_MINIAUDIO_15", isrc: "ZZCHM2600015", barcode: "000000000015", catalogNumber: "MAP-CAT-015", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Helena Novak", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Helena Novak (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Helena Novak", composer: "Helena Novak", originalLyricist: "Helena Novak", recordingDate: "2024-05-15", releaseDate: "2024-06-01", originalReleaseDate: "2024-04-10", initialKey: "Eb", color: "Midnight Indigo", mood: "Solemn", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/15_Resting_At_Your_Feet.mp2", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2024) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #15 (mp2) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-15-mp2", podcastKeywords: "audio, rust, flutter, mp2, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[MP2 Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Resting_At_Your_Feet.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 15"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/16_Ribbons_on_Anchors.oga",
    reqTagFmt: "VorbisComments",
    id3v2Version: null,
    title: "Ribbons on Anchors",
    trackArtist: "Yuki Fujimoto",
    album: "Glitter & Grit",
    albumArtist: "Chomusuke Ensemble",
    year: 2026,
    genre: "Kawaii Future Bass",
    trackNumber: 16,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Silk knots trailing deep below azure tides.",
    comment: "Royalty-free fixture 16_Ribbons_on_Anchors.oga generated for miniaudio_player",
    bpm: 150.0,
    replayGainTrackGain: "-6.10 dB",
    replayGainTrackPeak: "1.023293",
    replayGainAlbumGain: "-6.10 dB",
    replayGainAlbumPeak: "1.023293",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 71415), _ExpectedPic(type: PictureType.coverBack, mime: MimeType.png, description: "Back Cover", byteLength: 87211)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 56687), _ExpectedChapter("Climax & Outro", 113375)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "d514fb22-f26e-a685-1148-6dcedcb20ead", musicBrainzTrackId: "23c035b7-617a-ebae-f637-e0746336e9ad", musicBrainzReleaseId: "b93cc850-f33e-a97b-7435-91e7f4d78f5a", musicBrainzReleaseGroupId: "f5b6759d-ad71-bd8b-ddde-4c9b7cd9d922", musicBrainzArtistId: "d9249410-4285-8a43-3fb0-c8a372eb6c0d", musicBrainzReleaseArtistId: "4775a3af-005f-6d92-27f3-204ef02415ee", musicBrainzWorkId: "77155d8e-f81c-1dd5-b123-f4c1b081eba7", musicBrainzReleaseType: "Album", acoustId: "52260dcf-7678-9e6c-ae34-dcd030dc69ba", acoustIdFingerprint: "AQADtd514fb22f26ea68511486dcedcb2_CC0_MINIAUDIO_16", isrc: "ZZCHM2600016", barcode: "000000000016", catalogNumber: "MAP-CAT-016", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Yuki Fujimoto", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Yuki Fujimoto (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Yuki Fujimoto", composer: "Yuki Fujimoto", originalLyricist: "Yuki Fujimoto", recordingDate: "2026-05-15", releaseDate: "2026-06-01", originalReleaseDate: "2026-04-10", initialKey: "E", color: "Midnight Indigo", mood: "Playful", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/16_Ribbons_on_Anchors.oga", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2026) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #16 (oga_vorbis) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-16-oga_vorbis", podcastKeywords: "audio, rust, flutter, oga_vorbis, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[OGA_VORBIS Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Ribbons_on_Anchors.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 16"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/17_Running_To_Meet_The_Sun.wav",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Running To Meet The Sun",
    trackArtist: "Caleb Mercer",
    album: "Westbound Narratives",
    albumArtist: "Chomusuke Ensemble",
    year: 2024,
    genre: "Modern Americana",
    trackNumber: 17,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Dusty highways open golden before sunrise.",
    comment: "Royalty-free fixture 17_Running_To_Meet_The_Sun.wav generated for miniaudio_player",
    bpm: 112.0,
    replayGainTrackGain: "-6.30 dB",
    replayGainTrackPeak: "1.011579",
    replayGainAlbumGain: "-6.30 dB",
    replayGainAlbumPeak: "1.011579",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 60035)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 51409), _ExpectedChapter("Climax & Outro", 102818)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "12577ae9-24cd-9b6a-d59b-07be510aa2a7", musicBrainzTrackId: "efd49491-050f-f71b-06ec-410262ca9e3e", musicBrainzReleaseId: "acb585ea-c88f-0bd5-f896-d7a92299da74", musicBrainzReleaseGroupId: "17d1c63a-07c6-8b2f-54fc-2589c828b22f", musicBrainzArtistId: "54e44fec-a253-5a9a-d922-84f535b4c951", musicBrainzReleaseArtistId: "4714e704-471e-b685-bd3a-873ea04d294a", musicBrainzWorkId: "4423e905-71df-fa3b-7c79-9085f3b0456e", musicBrainzReleaseType: "Album", acoustId: "98c7e8a7-04f9-aa3a-6208-173ca4a2e0cb", acoustIdFingerprint: "AQADt12577ae924cd9b6ad59b07be510a_CC0_MINIAUDIO_17", isrc: "ZZCHM2600017", barcode: "000000000017", catalogNumber: "MAP-CAT-017", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Caleb Mercer", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Caleb Mercer (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Caleb Mercer", composer: "Caleb Mercer", originalLyricist: "Caleb Mercer", recordingDate: "2024-05-15", releaseDate: "2024-06-01", originalReleaseDate: "2024-04-10", initialKey: "C", color: "Midnight Indigo", mood: "Hopeful", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/17_Running_To_Meet_The_Sun.wav", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2024) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #17 (wav_16_stereo) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-17-wav_16_stereo", podcastKeywords: "audio, rust, flutter, wav_16_stereo, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[WAV_16_STEREO Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Running_To_Meet_The_Sun.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 17"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/18_Running_With_Daylight.aif",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Running With Daylight",
    trackArtist: "Noah Lind",
    album: "Calculated Motion",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Electro House",
    trackNumber: 18,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Chasing shadows off asphalt lanes.",
    comment: "Royalty-free fixture 18_Running_With_Daylight.aif generated for miniaudio_player",
    bpm: 128.0,
    replayGainTrackGain: "-5.40 dB",
    replayGainTrackPeak: "1.059254",
    replayGainAlbumGain: "-5.40 dB",
    replayGainAlbumPeak: "1.059254",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 41419)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 57430), _ExpectedChapter("Climax & Outro", 114861)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "59c3ecce-9bd6-aa63-7c1a-b3fc22d0fd13", musicBrainzTrackId: "2d7fc6a3-3410-23e9-1f90-03534abad514", musicBrainzReleaseId: "e8c11081-805a-1c5c-0f4c-97e7fd7ea57a", musicBrainzReleaseGroupId: "c145d2d9-3f17-505f-ed40-9f6eb1b8a38a", musicBrainzArtistId: "cdf63297-ab7c-23a3-9a95-b81babf7225f", musicBrainzReleaseArtistId: "837988b6-1455-8d1b-ace4-b36a296ff985", musicBrainzWorkId: "e7d6256a-271d-0567-1acd-017731c805e4", musicBrainzReleaseType: "Album", acoustId: "23a1ab91-6219-d4ae-470b-c3281dc53ef7", acoustIdFingerprint: "AQADt59c3ecce9bd6aa637c1ab3fc22d0_CC0_MINIAUDIO_18", isrc: "ZZCHM2600018", barcode: "000000000018", catalogNumber: "MAP-CAT-018", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Noah Lind", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Noah Lind (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Noah Lind", composer: "Noah Lind", originalLyricist: "Noah Lind", recordingDate: "2025-05-15", releaseDate: "2025-06-01", originalReleaseDate: "2025-04-10", initialKey: "Gm", color: "Midnight Indigo", mood: "Kinetic", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/18_Running_With_Daylight.aif", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #18 (aif) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-18-aif", podcastKeywords: "audio, rust, flutter, aif, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[AIF Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Running_With_Daylight.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 18"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/19_Spin_Me_In_The_Dark.rf64",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Spin Me In The Dark",
    trackArtist: "Mireia Costa",
    album: "The Midnight Ballroom",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Melodic House",
    trackNumber: 19,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Mirrorballs turning slow across velvet walls.",
    comment: "Royalty-free fixture 19_Spin_Me_In_The_Dark.rf64 generated for miniaudio_player",
    bpm: 122.0,
    replayGainTrackGain: "-5.70 dB",
    replayGainTrackPeak: "1.023293",
    replayGainAlbumGain: "-5.70 dB",
    replayGainAlbumPeak: "1.023293",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 42609)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 60395), _ExpectedChapter("Climax & Outro", 120790)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "2ad54590-6f80-a4ed-064e-38a322d373c1", musicBrainzTrackId: "cd8cba07-efc5-81bf-6064-a7803e45b750", musicBrainzReleaseId: "63a8eed2-8cf7-eb25-d6ce-20b69b30ce2f", musicBrainzReleaseGroupId: "92a6ea64-9a1d-845d-4d9b-937f3ecf0488", musicBrainzArtistId: "4810bfb6-3636-c5c2-0816-0bd9aeac3e6f", musicBrainzReleaseArtistId: "02bbd5d6-ee7b-d144-6791-ff0400ef479e", musicBrainzWorkId: "37ff692e-d68b-f0a1-5a54-f4338b1c45c5", musicBrainzReleaseType: "Album", acoustId: "0826a5f6-f655-abab-38de-49033497b264", acoustIdFingerprint: "AQADt2ad545906f80a4ed064e38a322d3_CC0_MINIAUDIO_19", isrc: "ZZCHM2600019", barcode: "000000000019", catalogNumber: "MAP-CAT-019", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Mireia Costa", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Mireia Costa (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Mireia Costa", composer: "Mireia Costa", originalLyricist: "Mireia Costa", recordingDate: "2025-05-15", releaseDate: "2025-06-01", originalReleaseDate: "2025-04-10", initialKey: "Bm", color: "Midnight Indigo", mood: "Hypnotic", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/19_Spin_Me_In_The_Dark.rf64", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #19 (rf64) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-19-rf64", podcastKeywords: "audio, rust, flutter, rf64, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[RF64 Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Spin_Me_In_The_Dark.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 19"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/20_Swallowing_This_Glitter_Pill.w64",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Swallowing This Glitter Pill",
    trackArtist: "Koko Arakawa",
    album: "Curated Facades",
    albumArtist: "Chomusuke Ensemble",
    year: 2026,
    genre: "Kawaii Future Bass",
    trackNumber: 20,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Sugar glass shimmers in synthlight.",
    comment: "Royalty-free fixture 20_Swallowing_This_Glitter_Pill.w64 generated for miniaudio_player",
    bpm: 148.0,
    replayGainTrackGain: "-5.60 dB",
    replayGainTrackPeak: "1.059254",
    replayGainAlbumGain: "-5.60 dB",
    replayGainAlbumPeak: "1.059254",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 42531)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 52964), _ExpectedChapter("Climax & Outro", 105929)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "5bb41543-3643-f5e1-d92b-699bc3c3fe69", musicBrainzTrackId: "0b0c671c-f329-4c27-5997-cff59eb32f27", musicBrainzReleaseId: "c74bf077-1996-02fc-4dc8-3a20251589ce", musicBrainzReleaseGroupId: "6d80823f-060f-0d91-7b49-16c8c43e9b7d", musicBrainzArtistId: "02ed245f-6ee0-1cab-a4c2-fea199d787e8", musicBrainzReleaseArtistId: "8328a7a7-279d-fcad-3b65-148e5d70460c", musicBrainzWorkId: "decd3ab3-d73d-e256-ceb7-0436e8328f61", musicBrainzReleaseType: "Album", acoustId: "c8bfda88-512a-654b-33e2-e848a37e196e", acoustIdFingerprint: "AQADt5bb415433643f5e1d92b699bc3c3_CC0_MINIAUDIO_20", isrc: "ZZCHM2600020", barcode: "000000000020", catalogNumber: "MAP-CAT-020", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Koko Arakawa", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Koko Arakawa (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Koko Arakawa", composer: "Koko Arakawa", originalLyricist: "Koko Arakawa", recordingDate: "2026-05-15", releaseDate: "2026-06-01", originalReleaseDate: "2026-04-10", initialKey: "Db", color: "Midnight Indigo", mood: "Bright", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/20_Swallowing_This_Glitter_Pill.w64", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2026) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #20 (w64) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-20-w64", podcastKeywords: "audio, rust, flutter, w64, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[W64 Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Swallowing_This_Glitter_Pill.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 20"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/21_The_Great_Equalizer.bwf",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "The Great Equalizer",
    trackArtist: "Victor Kestrel",
    album: "Broadcast Masters",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Synthwave",
    trackNumber: 21,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Balanced faders across the open frequency.",
    comment: "Royalty-free fixture 21_The_Great_Equalizer.bwf generated for miniaudio_player",
    bpm: 116.0,
    replayGainTrackGain: "-6.20 dB",
    replayGainTrackPeak: "1.047129",
    replayGainAlbumGain: "-6.20 dB",
    replayGainAlbumPeak: "1.047129",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 13889)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 53514), _ExpectedChapter("Climax & Outro", 107028)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "96f452d4-534b-1f94-909e-f0fb5bdcd0af", musicBrainzTrackId: "fa622067-222e-73cd-1a9a-b01c5c55ba2f", musicBrainzReleaseId: "2d35bc20-7041-e084-c85c-784adaef06a2", musicBrainzReleaseGroupId: "c4b10494-50e4-8be1-2516-dbdf1de90b11", musicBrainzArtistId: "4e8d37ec-d98c-685c-c68d-427eaf833e79", musicBrainzReleaseArtistId: "a7b178da-297c-d33e-7392-c88312e77bca", musicBrainzWorkId: "ffcedee5-d353-bc38-e2f6-3e699f8ef4d0", musicBrainzReleaseType: "Album", acoustId: "ec2be29c-cf1a-536a-16fc-fe9c622c353a", acoustIdFingerprint: "AQADt96f452d4534b1f94909ef0fb5bdc_CC0_MINIAUDIO_21", isrc: "ZZCHM2600021", barcode: "000000000021", catalogNumber: "MAP-CAT-021", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Victor Kestrel", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Victor Kestrel (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Victor Kestrel", composer: "Victor Kestrel", originalLyricist: "Victor Kestrel", recordingDate: "2025-05-15", releaseDate: "2025-06-01", originalReleaseDate: "2025-04-10", initialKey: "Dm", color: "Midnight Indigo", mood: "Bold", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/21_The_Great_Equalizer.bwf", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #21 (bwf) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-21-bwf", podcastKeywords: "audio, rust, flutter, bwf, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[BWF Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "The_Great_Equalizer.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 21"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/22_The_Midnight_Pursuit.rifx",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "The Midnight Pursuit",
    trackArtist: "Clara Rostova",
    album: "Bravura Nocturnes",
    albumArtist: "Chomusuke Ensemble",
    year: 2023,
    genre: "Romantic Classical",
    trackNumber: 22,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Nocturnal strings sprint under moonlit arches.",
    comment: "Royalty-free fixture 22_The_Midnight_Pursuit.rifx generated for miniaudio_player",
    bpm: 94.0,
    replayGainTrackGain: "-7.00 dB",
    replayGainTrackPeak: "1.011579",
    replayGainAlbumGain: "-7.00 dB",
    replayGainAlbumPeak: "1.011579",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 66358)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 58568), _ExpectedChapter("Climax & Outro", 117136)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "25f96542-9a31-a3a7-8889-d6bffae8783b", musicBrainzTrackId: "21f01be7-136f-204c-a427-6e340962df80", musicBrainzReleaseId: "b75d912d-6e0f-d73b-da61-affb58af1a4d", musicBrainzReleaseGroupId: "4b546ec0-8f6b-10f8-c323-30cac094e217", musicBrainzArtistId: "117d984b-ba42-c89b-1910-c73caa860b19", musicBrainzReleaseArtistId: "0ef6ee9d-e874-3da5-081b-4c0fb673077f", musicBrainzWorkId: "dcd2b8de-2378-dbca-e3a7-44c009337c79", musicBrainzReleaseType: "Album", acoustId: "664475b0-415e-cfbc-0738-89b6ed91d0dd", acoustIdFingerprint: "AQADt25f965429a31a3a78889d6bffae8_CC0_MINIAUDIO_22", isrc: "ZZCHM2600022", barcode: "000000000022", catalogNumber: "MAP-CAT-022", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Clara Rostova", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Clara Rostova (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Clara Rostova", composer: "Clara Rostova", originalLyricist: "Clara Rostova", recordingDate: "2023-05-15", releaseDate: "2023-06-01", originalReleaseDate: "2023-04-10", initialKey: "Cm", color: "Midnight Indigo", mood: "Intense", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/22_The_Midnight_Pursuit.rifx", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2023) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #22 (rifx) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-22-rifx", podcastKeywords: "audio, rust, flutter, rifx, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[RIFX Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "The_Midnight_Pursuit.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 22"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/23_Tracing_Lines.aifc",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Tracing Lines",
    trackArtist: "Owen Gallagher",
    album: "Midnight Horizon",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Melodic House",
    trackNumber: 23,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Drawing constellations on foggy glass.",
    comment: "Royalty-free fixture 23_Tracing_Lines.aifc generated for miniaudio_player",
    bpm: 123.0,
    replayGainTrackGain: "-6.40 dB",
    replayGainTrackPeak: "1.011579",
    replayGainAlbumGain: "-6.40 dB",
    replayGainAlbumPeak: "1.011579",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 27104)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 59690), _ExpectedChapter("Climax & Outro", 119381)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "298a6810-5a46-6481-3839-a6ed1e1a6d29", musicBrainzTrackId: "e261a52a-5227-306d-4f14-5e3bba13af9c", musicBrainzReleaseId: "b3050e27-6cc8-f6e1-26df-5a67ca5670be", musicBrainzReleaseGroupId: "26d1371a-b97e-ee73-aa19-12be1cdb0e15", musicBrainzArtistId: "6b10e416-c23a-71d4-85b6-76920631ca5e", musicBrainzReleaseArtistId: "2b35f9fe-0861-0bcb-3f54-1dd2617b23d2", musicBrainzWorkId: "709387c8-7195-2387-5f0c-0b2221cb43c8", musicBrainzReleaseType: "Album", acoustId: "66b4d1f8-9f0c-31db-2027-496c3db988ef", acoustIdFingerprint: "AQADt298a68105a4664813839a6ed1e1a_CC0_MINIAUDIO_23", isrc: "ZZCHM2600023", barcode: "000000000023", catalogNumber: "MAP-CAT-023", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Owen Gallagher", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Owen Gallagher (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Owen Gallagher", composer: "Owen Gallagher", originalLyricist: "Owen Gallagher", recordingDate: "2025-05-15", releaseDate: "2025-06-01", originalReleaseDate: "2025-04-10", initialKey: "Em", color: "Midnight Indigo", mood: "Reflective", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/23_Tracing_Lines.aifc", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #23 (aifc) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-23-aifc", podcastKeywords: "audio, rust, flutter, aifc, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[AIFC Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Tracing_Lines.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 23"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/24_Tracks_Into_The_Dawn.aiff",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "Tracks Into The Dawn",
    trackArtist: "Rafael Ortega",
    album: "Horizon Velocity",
    albumArtist: "Chomusuke Ensemble",
    year: 2026,
    genre: "Melodic Progressive House",
    trackNumber: 24,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Steel rails gleam in first violet light.",
    comment: "Royalty-free fixture 24_Tracks_Into_The_Dawn.aiff generated for miniaudio_player",
    bpm: 126.0,
    replayGainTrackGain: "-6.10 dB",
    replayGainTrackPeak: "1.011579",
    replayGainAlbumGain: "-6.10 dB",
    replayGainAlbumPeak: "1.011579",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 55462)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 60983), _ExpectedChapter("Climax & Outro", 121966)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "9cbdc9eb-9d44-7060-92ef-f3fc023211af", musicBrainzTrackId: "5fe8bdf9-16a9-4747-213f-636b75c170af", musicBrainzReleaseId: "2ff61ae3-2352-1a8f-1793-9871d48d2329", musicBrainzReleaseGroupId: "a8bd00a2-ae31-7cb0-cf69-cfd75ddcdc9c", musicBrainzArtistId: "03318143-ef7d-94c9-a661-9e5cd5192329", musicBrainzReleaseArtistId: "4f3651bd-89d2-26ad-d020-42c14e798e29", musicBrainzWorkId: "fe92bbfa-1af1-feee-5b78-6544f98f2b9d", musicBrainzReleaseType: "Album", acoustId: "ce44db8e-aca1-8e5c-a6bd-1005cd15d7f6", acoustIdFingerprint: "AQADt9cbdc9eb9d44706092eff3fc0232_CC0_MINIAUDIO_24", isrc: "ZZCHM2600024", barcode: "000000000024", catalogNumber: "MAP-CAT-024", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Rafael Ortega", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Rafael Ortega (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Rafael Ortega", composer: "Rafael Ortega", originalLyricist: "Rafael Ortega", recordingDate: "2026-05-15", releaseDate: "2026-06-01", originalReleaseDate: "2026-04-10", initialKey: "Am", color: "Midnight Indigo", mood: "Driving", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/24_Tracks_Into_The_Dawn.aiff", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2026) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #24 (aiff) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-24-aiff", podcastKeywords: "audio, rust, flutter, aiff, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[AIFF Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Tracks_Into_The_Dawn.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 24"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/25_Velocity_of_One.ape",
    reqTagFmt: "APE",
    id3v2Version: null,
    title: "Velocity of One",
    trackArtist: "Lucas Moreau",
    album: "Radiant Motion",
    albumArtist: "Chomusuke Ensemble",
    year: 2025,
    genre: "Melodic Electro House",
    trackNumber: 25,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "Single trajectory past acoustic barriers.",
    comment: "Royalty-free fixture 25_Velocity_of_One.ape generated for miniaudio_player",
    bpm: 128.0,
    replayGainTrackGain: "-6.10 dB",
    replayGainTrackPeak: "1.083927",
    replayGainAlbumGain: "-6.10 dB",
    replayGainAlbumPeak: "1.083927",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "cover.jpg", byteLength: 44378), _ExpectedPic(type: PictureType.coverBack, mime: MimeType.png, description: "cover_back.png", byteLength: 88980)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 60426), _ExpectedChapter("Climax & Outro", 120852)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "a17ce130-b03a-bb33-0638-8fb07d1db575", musicBrainzTrackId: "6d801e85-cbd7-9104-5a21-759bc17b7d31", musicBrainzReleaseId: "a9c09703-ca10-559b-117c-2749356b7913", musicBrainzReleaseGroupId: "8b0662c4-886e-def8-d1b3-0993a9fefd9f", musicBrainzArtistId: "1aa1c146-f78a-38ca-90ac-4dcc45591548", musicBrainzReleaseArtistId: "6b3f5da7-b4bc-ac55-85ae-62bdd3294424", musicBrainzWorkId: "d9e53923-b3c8-40ac-cf6a-8bfb2cca15b7", musicBrainzReleaseType: "Album", acoustId: "26b2a0ab-e85e-edba-4c08-351a1d7e76c9", acoustIdFingerprint: "AQADta17ce130b03abb3306388fb07d1d_CC0_MINIAUDIO_25", isrc: "ZZCHM2600025", barcode: "000000000025", catalogNumber: "MAP-CAT-025", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "Lucas Moreau", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "Lucas Moreau (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "Lucas Moreau", composer: "Lucas Moreau", originalLyricist: "Lucas Moreau", recordingDate: "2025-05-15", releaseDate: "2025-06-01", originalReleaseDate: "2025-04-10", initialKey: "F#m", color: "Midnight Indigo", mood: "Propulsive", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/25_Velocity_of_One.ape", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2025) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #25 (ape) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-25-ape", podcastKeywords: "audio, rust, flutter, ape, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[APE Reference Edition]", language: "eng", script: "Latn", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "Velocity_of_One.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 25"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/27_¡Yo_me_opongo_.caf",
    reqTagFmt: "CAF",
    id3v2Version: null,
    title: "¡Yo me opongo!",
    trackArtist: "Gabriel Peña",
    album: "Sentimientos de Amargue",
    albumArtist: null,
    year: 2024,
    genre: "Bachata",
    trackNumber: 27,
    trackTotal: 29,
    discNumber: null,
    discTotal: null,
    lyrics: null,
    comment: "Copyright-free CAF fixture 27_¡Yo_me_opongo_.caf",
    bpm: 130.0,
    replayGainTrackGain: null,
    replayGainTrackPeak: null,
    replayGainAlbumGain: null,
    replayGainAlbumPeak: null,
    pictures: [],
    chapters: [],
    customTags: {},
    extended: ExtendedMetadata(composer: "Gabriel Peña", recordingDate: "2024", initialKey: "Am", copyrightMessage: "CC0 1.0 Public Domain Dedication (2024) Chomusuke Studio", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "Lavf62.3.100"),
  ),
  _ExpectedTrack(
    relPath: "example/assets/music/29_駆け抜けて、この空を.dsf",
    reqTagFmt: "ID3v2",
    id3v2Version: Id3v2Version.v4,
    title: "駆け抜けて、この空を",
    trackArtist: "桜庭 凛 (Rin Sakuraba)",
    album: "光のまにまに",
    albumArtist: "Chomusuke Ensemble",
    year: 2026,
    genre: "J-Pop",
    trackNumber: 29,
    trackTotal: 29,
    discNumber: 1,
    discTotal: 2,
    lyrics: "蒼い風を切って、どこまでも駆け抜ける！",
    comment: "Royalty-free fixture 29_駆け抜けて、この空を.dsf generated for miniaudio_player",
    bpm: 138.0,
    replayGainTrackGain: "-3.40 dB",
    replayGainTrackPeak: "0.988553",
    replayGainAlbumGain: "-3.40 dB",
    replayGainAlbumPeak: "0.988553",
    pictures: [_ExpectedPic(type: PictureType.coverFront, mime: MimeType.jpeg, description: "Front Cover", byteLength: 69688)],
    chapters: [_ExpectedChapter("Intro & Theme", 0), _ExpectedChapter("Main Progression", 58762), _ExpectedChapter("Climax & Outro", 117524)],
    customTags: {"STUDIO_ENGINE": "miniaudio_player", "ASSET_LICENSE": "CC0-1.0"},
    extended: ExtendedMetadata(musicBrainzRecordingId: "0f681a3e-9272-66a1-18ff-ef3a860d381f", musicBrainzTrackId: "5b6de209-7c14-9d26-6fa1-9030b5077920", musicBrainzReleaseId: "fd82e20e-c62c-185f-8a7d-b57007742c59", musicBrainzReleaseGroupId: "c38c4721-13f8-ba5a-b1c3-f291f402b5c6", musicBrainzArtistId: "6b0d9ce3-3e6e-1921-2ecd-81c3aa28aa39", musicBrainzReleaseArtistId: "ddf57148-ac0b-9684-73d9-181d84157c4e", musicBrainzWorkId: "4317f5a2-9872-1e38-85f1-a3ea5c88a03c", musicBrainzReleaseType: "Album", acoustId: "a04efdb2-a8ba-9b02-0bd5-43e9760bd1ea", acoustIdFingerprint: "AQADt0f681a3e927266a118ffef3a860d_CC0_MINIAUDIO_29", isrc: "ZZCHM2600029", barcode: "000000000029", catalogNumber: "MAP-CAT-029", arranger: "Lukas Lind", conductor: "Nadia Alverez", director: "Taro Watanabe", engineer: "Javier Studio Lab", lyricist: "桜庭 凛 (Rin Sakuraba)", mixDj: "DJ Chomusuke", mixEngineer: "Mina Solberg", performer: "桜庭 凛 (Rin Sakuraba) (Synth & Vocals)", producer: "Chomusuke Production", publisher: "Chomusuke Open Audio Press", label: "Chomusuke Open Records", remixer: "Studio DSP Rework", writer: "桜庭 凛 (Rin Sakuraba)", composer: "桜庭 凛 (Rin Sakuraba)", originalLyricist: "桜庭 凛 (Rin Sakuraba)", recordingDate: "2026-05-15", releaseDate: "2026-06-01", originalReleaseDate: "2026-04-10", initialKey: "D", color: "Midnight Indigo", mood: "Soaring", audioFileUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets/blob/main/29_%E9%A7%86%E3%81%91%E6%8A%9C%E3%81%91%E3%81%A6%E3%80%81%E3%81%93%E3%81%AE%E7%A9%BA%E3%82%92.dsf", audioSourceUrl: "https://github.com/chomusuke-mk/miniaudio_player", commercialInformationUrl: "https://pub.dev/packages/miniaudio_player", copyrightUrl: "https://creativecommons.org/publicdomain/zero/1.0/", trackArtistUrl: "https://github.com/chomusuke-mk", radioStationUrl: "https://chomusuke-mk.github.io/radio", paymentUrl: "https://pub.dev/packages/miniaudio_player/license", publisherUrl: "https://github.com/chomusuke-mk/miniaudio_player_assets", copyrightMessage: "CC0 1.0 Public Domain Dedication (2026) Chomusuke Studio", license: "CC0-1.0", podcastDescription: "Copyright-free fixture #29 (dsf) for miniaudio_player testing.", podcastSeriesCategory: "Audio Testing / DSP Showcase", podcastUrl: "https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player_assets/main/hls/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8", podcastGlobalUniqueId: "miniaudio-fixture-29-dsf", podcastKeywords: "audio, rust, flutter, dsf, lossless-test", setSubtitle: "Disc 1: Format Coverage Suite", showName: "Miniaudio Audio Showcase", contentGroup: "Miniaudio Format Matrix (29 Tracks)", trackSubtitle: "[DSF Reference Edition]", language: "jpn", script: "Jpan", parentalAdvisory: "0", fileOwner: "miniaudio_player Test Suite", originalFileName: "駆け抜けて、この空を.mp4", originalMediaType: "DIG", encodedBy: "miniaudio_player build_assets.py", encoderSoftware: "FFmpeg + Mutagen + Pillow", encoderSettings: "48kHz / Mastering Profile 29"),
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  group('Dart Static Analysis Coverage (All 27 Fixtures)', () {
    for (final exp in _expectations27) {
      final fileName = exp.relPath.split('/').last;
      test('analyzeAudio: $fileName', () async {
        final file = _resolveRelativeAsset(exp.relPath);
        expect(file.existsSync(), isTrue,
            reason: 'Missing fixture ${exp.relPath}');
        final res = await MiniaudioPlayer.analyzeAudio(
          exp.relPath,
          replayGain: false,
          waveform: false,
          metadata: true,
        );
        expect(res.metadata, isNotNull,
            reason: '${exp.relPath}: analyzeAudio returned null metadata');
        _assertMetadataMatches(exp, res.metadata!);
      });
    }

    test('analyzeAudioSync parity across tricky container formats', () {
      const syncRelPaths = <String>[
        'example/assets/music/01_Apex_Momentum.mp3',
        'example/assets/music/06_Calculated_Motion_aac.m4a',
        'example/assets/music/09_Flesh_and_Chrome.wv',
        'example/assets/music/11_Mar_de_cristal.mka',
        'example/assets/music/13_Overture_for_the_Floor.webm',
        'example/assets/music/14_Painting_the_Sky.mkv',
        'example/assets/music/18_Running_With_Daylight.aif',
        'example/assets/music/25_Velocity_of_One.ape',
        'example/assets/music/27_\u00a1Yo_me_opongo_.caf',
        'example/assets/music/29_\u99c6\u3051\u629c\u3051\u3066\u3001\u3053\u306e\u7a7a\u3092.dsf',
      ];
      for (final rel in syncRelPaths) {
        final exp = _expectations27.firstWhere((e) => e.relPath == rel);
        final res = MiniaudioPlayer.analyzeAudioSync(
          rel,
          replayGain: false,
          waveform: false,
          metadata: true,
        );
        expect(res.metadata, isNotNull,
            reason: '$rel: analyzeAudioSync returned null metadata');
        _assertMetadataMatches(exp, res.metadata!);
      }
    });
  });

  group('Dart Live Playback Coverage (setMetadataEnabled)', () {
    const liveRelPaths = <String>[
      'example/assets/music/01_Apex_Momentum.mp3',
      'example/assets/music/04_Belaya_Tishina.flac',
      'example/assets/music/06_Calculated_Motion_aac.m4a',
      'example/assets/music/09_Flesh_and_Chrome.wv',
      'example/assets/music/11_Mar_de_cristal.mka',
      'example/assets/music/13_Overture_for_the_Floor.webm',
      'example/assets/music/14_Painting_the_Sky.mkv',
      'example/assets/music/18_Running_With_Daylight.aif',
      'example/assets/music/20_Swallowing_This_Glitter_Pill.w64',
      'example/assets/music/25_Velocity_of_One.ape',
      'example/assets/music/27_\u00a1Yo_me_opongo_.caf',
      'example/assets/music/29_\u99c6\u3051\u629c\u3051\u3066\u3001\u3053\u306e\u7a7a\u3092.dsf',
    ];

    for (final rel in liveRelPaths) {
      final exp = _expectations27.firstWhere((e) => e.relPath == rel);
      final fileName = rel.split('/').last;
      test('live playback metadata: $fileName', () async {
        final player = MiniaudioPlayer();
        try {
          await player.action.setMetadataEnabled(true);
          await player.action.setQueue([AudioSource(rel)]);
          await player.action.play();
          final meta = await awaitStateOrStream<AudioMetadata?>(
            stream: player.stream.metadata,
            current: () => player.state.metadata,
            predicate: (m) => m != null && m.title == exp.title,
            timeout: const Duration(seconds: 6),
            reason: '$fileName: live playback timed out waiting for metadata',
          );
          expect(meta, isNotNull);
          _assertMetadataMatches(exp, meta!);
        } finally {
          await player.dispose();
        }
      });
    }
  });
}
