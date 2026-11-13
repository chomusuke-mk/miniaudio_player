import 'dart:typed_data';

import '../rust/api/types.dart' as rust_types;

/// Type of embedded picture according to the ID3v2 `APIC` and FLAC `METADATA_BLOCK_PICTURE` standards.
enum PictureType {
  /// Other picture type not covered by standard categories (`0`).
  other,

  /// 32x32 pixels file icon (PNG only) (`1`).
  icon,

  /// Other file icon (`2`).
  otherIcon,

  /// Cover (front) (`3`).
  coverFront,

  /// Cover (back) (`4`).
  coverBack,

  /// Leaflet page (`5`).
  leaflet,

  /// Media (e.g. label side of CD) (`6`).
  media,

  /// Lead artist / lead performer / soloist (`7`).
  leadArtist,

  /// Artist / performer (`8`).
  artist,

  /// Conductor (`9`).
  conductor,

  /// Band / orchestra (`10`).
  band,

  /// Composer (`11`).
  composer,

  /// Lyricist / text writer (`12`).
  lyricist,

  /// Recording location (`13`).
  recordingLocation,

  /// During recording (`14`).
  duringRecording,

  /// During performance (`15`).
  duringPerformance,

  /// Movie / video screen capture (`16`).
  screenCapture,

  /// A bright coloured fish (`17`).
  brightFish,

  /// Illustration (`18`).
  illustration,

  /// Band / artist logotype (`19`).
  bandLogo,

  /// Publisher /studio logotype (`20`).
  publisherLogo;

  /// Converts a native [rust_types.RustPictureType] into a [PictureType].
  static PictureType fromRust(rust_types.RustPictureType type) =>
      switch (type) {
        rust_types.RustPictureType.other => PictureType.other,
        rust_types.RustPictureType.icon => PictureType.icon,
        rust_types.RustPictureType.otherIcon => PictureType.otherIcon,
        rust_types.RustPictureType.coverFront => PictureType.coverFront,
        rust_types.RustPictureType.coverBack => PictureType.coverBack,
        rust_types.RustPictureType.leaflet => PictureType.leaflet,
        rust_types.RustPictureType.media => PictureType.media,
        rust_types.RustPictureType.leadArtist => PictureType.leadArtist,
        rust_types.RustPictureType.artist => PictureType.artist,
        rust_types.RustPictureType.conductor => PictureType.conductor,
        rust_types.RustPictureType.band => PictureType.band,
        rust_types.RustPictureType.composer => PictureType.composer,
        rust_types.RustPictureType.lyricist => PictureType.lyricist,
        rust_types.RustPictureType.recordingLocation =>
          PictureType.recordingLocation,
        rust_types.RustPictureType.duringRecording =>
          PictureType.duringRecording,
        rust_types.RustPictureType.duringPerformance =>
          PictureType.duringPerformance,
        rust_types.RustPictureType.screenCapture => PictureType.screenCapture,
        rust_types.RustPictureType.brightFish => PictureType.brightFish,
        rust_types.RustPictureType.illustration => PictureType.illustration,
        rust_types.RustPictureType.bandLogo => PictureType.bandLogo,
        rust_types.RustPictureType.publisherLogo => PictureType.publisherLogo,
      };
}

/// MIME type of an embedded [AudioPicture].
enum MimeType {
  /// PNG image (`image/png`).
  png('image/png'),

  /// JPEG image (`image/jpeg`).
  jpeg('image/jpeg'),

  /// TIFF image (`image/tiff`).
  tiff('image/tiff'),

  /// BMP image (`image/bmp`).
  bmp('image/bmp'),

  /// GIF image (`image/gif`).
  gif('image/gif'),

  /// WebP image (`image/webp`).
  webp('image/webp'),

  /// Unrecognized or arbitrary binary MIME type (`application/octet-stream`).
  unknown('application/octet-stream');

  /// Standard IANA MIME string representation (e.g. `"image/jpeg"`).
  final String value;
  const MimeType(this.value);

  /// Converts a native [rust_types.RustMimeType] into a [MimeType].
  static MimeType fromRust(rust_types.RustMimeType type) => switch (type) {
        rust_types.RustMimeType.png => MimeType.png,
        rust_types.RustMimeType.jpeg => MimeType.jpeg,
        rust_types.RustMimeType.tiff => MimeType.tiff,
        rust_types.RustMimeType.bmp => MimeType.bmp,
        rust_types.RustMimeType.gif => MimeType.gif,
        rust_types.RustMimeType.webp => MimeType.webp,
        rust_types.RustMimeType.unknown => MimeType.unknown,
      };
}

/// Represents an embedded artwork or picture extracted from an audio container
/// (ID3v2 `APIC`/`PIC`, FLAC `METADATA_BLOCK_PICTURE`, Vorbis `METADATA_BLOCK_PICTURE`,
/// MP4 `covr`, or APEv2 binary cover art).
class AudioPicture {
  /// Semantic category of the picture (e.g. [PictureType.coverFront], [PictureType.coverBack]).
  final PictureType pictureType;

  /// Detected or declared MIME type of the image payload.
  final MimeType? mimeType;

  /// Optional textual description attached to the picture frame.
  final String? description;

  /// Raw encoded image bytes (PNG, JPEG, WebP, GIF, BMP, TIFF) ready for `Image.memory(picture.bytes)`.
  final Uint8List bytes;

  /// Creates an immutable [AudioPicture].
  const AudioPicture({
    required this.pictureType,
    this.mimeType,
    this.description,
    required this.bytes,
  });

  /// Creates an [AudioPicture] from a native [rust_types.RustAudioPicture] struct.
  factory AudioPicture.fromRust(rust_types.RustAudioPicture r) => AudioPicture(
        pictureType: PictureType.fromRust(r.pictureType),
        mimeType: r.mimeType != null ? MimeType.fromRust(r.mimeType!) : null,
        description: r.description,
        bytes: r.bytes,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioPicture &&
          runtimeType == other.runtimeType &&
          pictureType == other.pictureType &&
          mimeType == other.mimeType &&
          description == other.description &&
          AudioMetadata._bytesEquals(bytes, other.bytes);

  @override
  int get hashCode => Object.hash(
        pictureType,
        mimeType,
        description,
        Object.hashAll(bytes),
      );

  @override
  String toString() =>
      'AudioPicture(type: ${pictureType.name}, mime: ${mimeType?.value}, '
      'description: $description, ${bytes.length} bytes)';
}

/// Represents a chapter marker embedded in an audio track (ID3v2 `CHAP`,
/// MP4 `chpl`, Vorbis `CHAPTERxxx`, or Matroska `Chapters`).
class AudioChapter {
  /// Chapter title.
  final String title;

  /// Chapter start timestamp in milliseconds.
  final int startMs;

  /// Chapter end timestamp in milliseconds.
  final int endMs;

  /// Creates an immutable [AudioChapter].
  const AudioChapter({
    required this.title,
    required this.startMs,
    required this.endMs,
  });

  /// Chapter start timestamp as a [Duration].
  Duration get startTime => Duration(milliseconds: startMs);

  /// Chapter end timestamp as a [Duration].
  Duration get endTime => Duration(milliseconds: endMs);

  /// Chapter duration (`endTime - startTime`).
  Duration get duration =>
      Duration(milliseconds: endMs >= startMs ? endMs - startMs : 0);

  /// Creates an [AudioChapter] from a native [rust_types.RustAudioChapter] struct.
  factory AudioChapter.fromRust(rust_types.RustAudioChapter r) => AudioChapter(
        title: r.title,
        startMs: r.startMs.toInt(),
        endMs: r.endMs.toInt(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioChapter &&
          runtimeType == other.runtimeType &&
          title == other.title &&
          startMs == other.startMs &&
          endMs == other.endMs;

  @override
  int get hashCode => Object.hash(title, startMs, endMs);

  @override
  String toString() =>
      'AudioChapter(title: "$title", startMs: $startMs, endMs: $endMs)';
}

/// Major version of an ID3v2 tag header when present on the audio container.
enum Id3v2Version {
  /// ID3v2.2 (3-character frame identifiers such as `TT2`, `TP1`, `PIC`).
  v2,

  /// ID3v2.3 (4-character frame identifiers such as `TIT2`, `TPE1`, `APIC`).
  v3,

  /// ID3v2.4 (4-character frame identifiers, UTF-8 text support, `TDRC` timestamps).
  v4;

  /// Converts a native [rust_types.RustId3v2Version] into an [Id3v2Version].
  static Id3v2Version fromRust(rust_types.RustId3v2Version v) => switch (v) {
        rust_types.RustId3v2Version.v2 => Id3v2Version.v2,
        rust_types.RustId3v2Version.v3 => Id3v2Version.v3,
        rust_types.RustId3v2Version.v4 => Id3v2Version.v4,
      };
}

/// Shoutcast / Icecast (ICY) live stream metadata and station headers.
class IcyMetadata {
  /// Raw ICY `StreamTitle` string (typically `"Artist - Title"`).
  final String? streamTitle;

  /// Optional ICY `StreamUrl` value.
  final String? streamUrl;

  /// Optional `icy-name` station name header.
  final String? stationName;

  /// Optional `icy-genre` station genre header.
  final String? stationGenre;

  /// Optional `icy-url` station URL header.
  final String? stationUrl;

  /// Optional `icy-br` station nominal bitrate in kbps.
  final int? bitrateKbps;

  /// Creates an immutable [IcyMetadata] instance.
  const IcyMetadata({
    this.streamTitle,
    this.streamUrl,
    this.stationName,
    this.stationGenre,
    this.stationUrl,
    this.bitrateKbps,
  });

  /// Creates an [IcyMetadata] from a native [rust_types.RustIcyMetadata] struct.
  factory IcyMetadata.fromRust(rust_types.RustIcyMetadata r) => IcyMetadata(
        streamTitle: r.streamTitle,
        streamUrl: r.streamUrl,
        stationName: r.stationName,
        stationGenre: r.stationGenre,
        stationUrl: r.stationUrl,
        bitrateKbps: r.bitrateKbps,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IcyMetadata &&
          runtimeType == other.runtimeType &&
          streamTitle == other.streamTitle &&
          streamUrl == other.streamUrl &&
          stationName == other.stationName &&
          stationGenre == other.stationGenre &&
          stationUrl == other.stationUrl &&
          bitrateKbps == other.bitrateKbps;

  @override
  int get hashCode => Object.hash(
        streamTitle,
        streamUrl,
        stationName,
        stationGenre,
        stationUrl,
        bitrateKbps,
      );

  @override
  String toString() =>
      'IcyMetadata(streamTitle: $streamTitle, stationName: $stationName, '
      'stationGenre: $stationGenre, bitrateKbps: $bitrateKbps)';
}

/// Extended metadata fields (63 standardized fields covering MusicBrainz, AcoustID,
/// catalog identifiers, credits, dates, harmonic keys/moods, URLs, copyright,
/// podcast tags, sorting/grouping, and encoder details).
class ExtendedMetadata {
  /// MusicBrainz recording UUID.
  final String? musicBrainzRecordingId;

  /// MusicBrainz track UUID.
  final String? musicBrainzTrackId;

  /// MusicBrainz release UUID.
  final String? musicBrainzReleaseId;

  /// MusicBrainz release group UUID.
  final String? musicBrainzReleaseGroupId;

  /// MusicBrainz artist UUID.
  final String? musicBrainzArtistId;

  /// MusicBrainz release artist UUID.
  final String? musicBrainzReleaseArtistId;

  /// MusicBrainz work UUID.
  final String? musicBrainzWorkId;

  /// MusicBrainz release type (e.g. album, single, ep).
  final String? musicBrainzReleaseType;

  /// AcoustID fingerprint identifier.
  final String? acoustId;

  /// Raw AcoustID acoustic fingerprint string.
  final String? acoustIdFingerprint;

  /// International Standard Recording Code (ISRC).
  final String? isrc;

  /// EAN/UPC commercial barcode.
  final String? barcode;

  /// Record label catalog number.
  final String? catalogNumber;

  /// Music arranger name.
  final String? arranger;

  /// Orchestra or choir conductor name.
  final String? conductor;

  /// Performance or musical director name.
  final String? director;

  /// Audio recording or mastering engineer name.
  final String? engineer;

  /// Lyricist or text writer name.
  final String? lyricist;

  /// Disc jockey or mix DJ name.
  final String? mixDj;

  /// Mixing engineer name.
  final String? mixEngineer;

  /// Featured or guest performer credits.
  final String? performer;

  /// Music producer name.
  final String? producer;

  /// Music publisher entity.
  final String? publisher;

  /// Record label or imprint.
  final String? label;

  /// Remixer or rework artist.
  final String? remixer;

  /// Songwriter or lyric author.
  final String? writer;

  /// Music composer name.
  final String? composer;

  /// Original lyricist for translated or adapted works.
  final String? originalLyricist;

  /// Recording date string.
  final String? recordingDate;

  /// Commercial release date string.
  final String? releaseDate;

  /// Original commercial release date string.
  final String? originalReleaseDate;

  /// Musical initial key or tonality (e.g. "8A", "Am", "C# minor").
  final String? initialKey;

  /// Harmonic color code or tag.
  final String? color;

  /// Track mood description.
  final String? mood;

  /// Canonical audio file URL.
  final String? audioFileUrl;

  /// Official audio source web link.
  final String? audioSourceUrl;

  /// Commercial information or purchase URL.
  final String? commercialInformationUrl;

  /// Copyright or licensing information URL.
  final String? copyrightUrl;

  /// Official track artist website URL.
  final String? trackArtistUrl;

  /// Online radio station homepage URL.
  final String? radioStationUrl;

  /// Direct payment or tip jar URL.
  final String? paymentUrl;

  /// Record publisher official web URL.
  final String? publisherUrl;

  /// Legal copyright notice string.
  final String? copyrightMessage;

  /// Software or creative commons license declaration.
  final String? license;

  /// Podcast episode text description or show notes.
  final String? podcastDescription;

  /// Podcast iTunes/standard category taxonomy.
  final String? podcastSeriesCategory;

  /// Podcast feed or episode web URL.
  final String? podcastUrl;

  /// Globally unique identifier (GUID) for the podcast episode.
  final String? podcastGlobalUniqueId;

  /// Comma-separated search keywords for the podcast episode.
  final String? podcastKeywords;

  /// Subtitle or subtitle title for multi-disc box sets.
  final String? setSubtitle;

  /// Radio, TV, or podcast show name.
  final String? showName;

  /// Classical movement or content group designation.
  final String? contentGroup;

  /// Secondary track subtitle.
  final String? trackSubtitle;

  /// ISO 639 audio language code (e.g. "eng", "spa", "jpn").
  final String? language;

  /// Writing script system (e.g. "Latn", "Cyrl").
  final String? script;

  /// Parental advisory rating (e.g. "Explicit", "Clean").
  final String? parentalAdvisory;

  /// File owner or licensee identifier.
  final String? fileOwner;

  /// Original file name before export or ripping.
  final String? originalFileName;

  /// Original physical media type (e.g. "CD", "Vinyl", "DAT").
  final String? originalMediaType;

  /// Software or person responsible for audio encoding.
  final String? encodedBy;

  /// Software used to encode or rip the audio file.
  final String? encoderSoftware;

  /// Specific settings or flags passed to the audio encoder.
  final String? encoderSettings;

  /// Empty [ExtendedMetadata] constant.
  static const ExtendedMetadata empty = ExtendedMetadata();

  /// Creates an immutable [ExtendedMetadata] container.
  const ExtendedMetadata({
    this.musicBrainzRecordingId,
    this.musicBrainzTrackId,
    this.musicBrainzReleaseId,
    this.musicBrainzReleaseGroupId,
    this.musicBrainzArtistId,
    this.musicBrainzReleaseArtistId,
    this.musicBrainzWorkId,
    this.musicBrainzReleaseType,
    this.acoustId,
    this.acoustIdFingerprint,
    this.isrc,
    this.barcode,
    this.catalogNumber,
    this.arranger,
    this.conductor,
    this.director,
    this.engineer,
    this.lyricist,
    this.mixDj,
    this.mixEngineer,
    this.performer,
    this.producer,
    this.publisher,
    this.label,
    this.remixer,
    this.writer,
    this.composer,
    this.originalLyricist,
    this.recordingDate,
    this.releaseDate,
    this.originalReleaseDate,
    this.initialKey,
    this.color,
    this.mood,
    this.audioFileUrl,
    this.audioSourceUrl,
    this.commercialInformationUrl,
    this.copyrightUrl,
    this.trackArtistUrl,
    this.radioStationUrl,
    this.paymentUrl,
    this.publisherUrl,
    this.copyrightMessage,
    this.license,
    this.podcastDescription,
    this.podcastSeriesCategory,
    this.podcastUrl,
    this.podcastGlobalUniqueId,
    this.podcastKeywords,
    this.setSubtitle,
    this.showName,
    this.contentGroup,
    this.trackSubtitle,
    this.language,
    this.script,
    this.parentalAdvisory,
    this.fileOwner,
    this.originalFileName,
    this.originalMediaType,
    this.encodedBy,
    this.encoderSoftware,
    this.encoderSettings,
  });

  /// Creates an [ExtendedMetadata] from a native [rust_types.RustExtendedMetadata] struct.
  factory ExtendedMetadata.fromRust(rust_types.RustExtendedMetadata r) =>
      ExtendedMetadata(
        musicBrainzRecordingId: r.musicBrainzRecordingId,
        musicBrainzTrackId: r.musicBrainzTrackId,
        musicBrainzReleaseId: r.musicBrainzReleaseId,
        musicBrainzReleaseGroupId: r.musicBrainzReleaseGroupId,
        musicBrainzArtistId: r.musicBrainzArtistId,
        musicBrainzReleaseArtistId: r.musicBrainzReleaseArtistId,
        musicBrainzWorkId: r.musicBrainzWorkId,
        musicBrainzReleaseType: r.musicBrainzReleaseType,
        acoustId: r.acoustId,
        acoustIdFingerprint: r.acoustIdFingerprint,
        isrc: r.isrc,
        barcode: r.barcode,
        catalogNumber: r.catalogNumber,
        arranger: r.arranger,
        conductor: r.conductor,
        director: r.director,
        engineer: r.engineer,
        lyricist: r.lyricist,
        mixDj: r.mixDj,
        mixEngineer: r.mixEngineer,
        performer: r.performer,
        producer: r.producer,
        publisher: r.publisher,
        label: r.label,
        remixer: r.remixer,
        writer: r.writer,
        composer: r.composer,
        originalLyricist: r.originalLyricist,
        recordingDate: r.recordingDate,
        releaseDate: r.releaseDate,
        originalReleaseDate: r.originalReleaseDate,
        initialKey: r.initialKey,
        color: r.color,
        mood: r.mood,
        audioFileUrl: r.audioFileUrl,
        audioSourceUrl: r.audioSourceUrl,
        commercialInformationUrl: r.commercialInformationUrl,
        copyrightUrl: r.copyrightUrl,
        trackArtistUrl: r.trackArtistUrl,
        radioStationUrl: r.radioStationUrl,
        paymentUrl: r.paymentUrl,
        publisherUrl: r.publisherUrl,
        copyrightMessage: r.copyrightMessage,
        license: r.license,
        podcastDescription: r.podcastDescription,
        podcastSeriesCategory: r.podcastSeriesCategory,
        podcastUrl: r.podcastUrl,
        podcastGlobalUniqueId: r.podcastGlobalUniqueId,
        podcastKeywords: r.podcastKeywords,
        setSubtitle: r.setSubtitle,
        showName: r.showName,
        contentGroup: r.contentGroup,
        trackSubtitle: r.trackSubtitle,
        language: r.language,
        script: r.script,
        parentalAdvisory: r.parentalAdvisory,
        fileOwner: r.fileOwner,
        originalFileName: r.originalFileName,
        originalMediaType: r.originalMediaType,
        encodedBy: r.encodedBy,
        encoderSoftware: r.encoderSoftware,
        encoderSettings: r.encoderSettings,
      );

  /// Returns a map of all non-null extended metadata fields keyed by camelCase field name.
  Map<String, String> toMap() {
    final map = <String, String>{};
    void put(String key, String? val) {
      if (val != null) map[key] = val;
    }

    put('musicBrainzRecordingId', musicBrainzRecordingId);
    put('musicBrainzTrackId', musicBrainzTrackId);
    put('musicBrainzReleaseId', musicBrainzReleaseId);
    put('musicBrainzReleaseGroupId', musicBrainzReleaseGroupId);
    put('musicBrainzArtistId', musicBrainzArtistId);
    put('musicBrainzReleaseArtistId', musicBrainzReleaseArtistId);
    put('musicBrainzWorkId', musicBrainzWorkId);
    put('musicBrainzReleaseType', musicBrainzReleaseType);
    put('acoustId', acoustId);
    put('acoustIdFingerprint', acoustIdFingerprint);
    put('isrc', isrc);
    put('barcode', barcode);
    put('catalogNumber', catalogNumber);
    put('arranger', arranger);
    put('conductor', conductor);
    put('director', director);
    put('engineer', engineer);
    put('lyricist', lyricist);
    put('mixDj', mixDj);
    put('mixEngineer', mixEngineer);
    put('performer', performer);
    put('producer', producer);
    put('publisher', publisher);
    put('label', label);
    put('remixer', remixer);
    put('writer', writer);
    put('composer', composer);
    put('originalLyricist', originalLyricist);
    put('recordingDate', recordingDate);
    put('releaseDate', releaseDate);
    put('originalReleaseDate', originalReleaseDate);
    put('initialKey', initialKey);
    put('color', color);
    put('mood', mood);
    put('audioFileUrl', audioFileUrl);
    put('audioSourceUrl', audioSourceUrl);
    put('commercialInformationUrl', commercialInformationUrl);
    put('copyrightUrl', copyrightUrl);
    put('trackArtistUrl', trackArtistUrl);
    put('radioStationUrl', radioStationUrl);
    put('paymentUrl', paymentUrl);
    put('publisherUrl', publisherUrl);
    put('copyrightMessage', copyrightMessage);
    put('license', license);
    put('podcastDescription', podcastDescription);
    put('podcastSeriesCategory', podcastSeriesCategory);
    put('podcastUrl', podcastUrl);
    put('podcastGlobalUniqueId', podcastGlobalUniqueId);
    put('podcastKeywords', podcastKeywords);
    put('setSubtitle', setSubtitle);
    put('showName', showName);
    put('contentGroup', contentGroup);
    put('trackSubtitle', trackSubtitle);
    put('language', language);
    put('script', script);
    put('parentalAdvisory', parentalAdvisory);
    put('fileOwner', fileOwner);
    put('originalFileName', originalFileName);
    put('originalMediaType', originalMediaType);
    put('encodedBy', encodedBy);
    put('encoderSoftware', encoderSoftware);
    put('encoderSettings', encoderSettings);
    return map;
  }

  /// Looks up an extended metadata field by camelCase or case-insensitive key name.
  String? operator [](String key) {
    final map = toMap();
    if (map.containsKey(key)) return map[key];
    final normalized = key.replaceAll('_', '').toLowerCase();
    for (final entry in map.entries) {
      if (entry.key.toLowerCase() == normalized) {
        return entry.value;
      }
    }
    return null;
  }

  /// Whether all 63 extended metadata fields are `null`.
  bool get isEmpty => toMap().isEmpty;

  /// Whether at least one extended metadata field is non-null.
  bool get isNotEmpty => !isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExtendedMetadata &&
          runtimeType == other.runtimeType &&
          musicBrainzRecordingId == other.musicBrainzRecordingId &&
          musicBrainzTrackId == other.musicBrainzTrackId &&
          musicBrainzReleaseId == other.musicBrainzReleaseId &&
          musicBrainzReleaseGroupId == other.musicBrainzReleaseGroupId &&
          musicBrainzArtistId == other.musicBrainzArtistId &&
          musicBrainzReleaseArtistId == other.musicBrainzReleaseArtistId &&
          musicBrainzWorkId == other.musicBrainzWorkId &&
          musicBrainzReleaseType == other.musicBrainzReleaseType &&
          acoustId == other.acoustId &&
          acoustIdFingerprint == other.acoustIdFingerprint &&
          isrc == other.isrc &&
          barcode == other.barcode &&
          catalogNumber == other.catalogNumber &&
          arranger == other.arranger &&
          conductor == other.conductor &&
          director == other.director &&
          engineer == other.engineer &&
          lyricist == other.lyricist &&
          mixDj == other.mixDj &&
          mixEngineer == other.mixEngineer &&
          performer == other.performer &&
          producer == other.producer &&
          publisher == other.publisher &&
          label == other.label &&
          remixer == other.remixer &&
          writer == other.writer &&
          composer == other.composer &&
          originalLyricist == other.originalLyricist &&
          recordingDate == other.recordingDate &&
          releaseDate == other.releaseDate &&
          originalReleaseDate == other.originalReleaseDate &&
          initialKey == other.initialKey &&
          color == other.color &&
          mood == other.mood &&
          audioFileUrl == other.audioFileUrl &&
          audioSourceUrl == other.audioSourceUrl &&
          commercialInformationUrl == other.commercialInformationUrl &&
          copyrightUrl == other.copyrightUrl &&
          trackArtistUrl == other.trackArtistUrl &&
          radioStationUrl == other.radioStationUrl &&
          paymentUrl == other.paymentUrl &&
          publisherUrl == other.publisherUrl &&
          copyrightMessage == other.copyrightMessage &&
          license == other.license &&
          podcastDescription == other.podcastDescription &&
          podcastSeriesCategory == other.podcastSeriesCategory &&
          podcastUrl == other.podcastUrl &&
          podcastGlobalUniqueId == other.podcastGlobalUniqueId &&
          podcastKeywords == other.podcastKeywords &&
          setSubtitle == other.setSubtitle &&
          showName == other.showName &&
          contentGroup == other.contentGroup &&
          trackSubtitle == other.trackSubtitle &&
          language == other.language &&
          script == other.script &&
          parentalAdvisory == other.parentalAdvisory &&
          fileOwner == other.fileOwner &&
          originalFileName == other.originalFileName &&
          originalMediaType == other.originalMediaType &&
          encodedBy == other.encodedBy &&
          encoderSoftware == other.encoderSoftware &&
          encoderSettings == other.encoderSettings;

  @override
  int get hashCode =>
      Object.hashAll(toMap().entries.map((e) => Object.hash(e.key, e.value)));

  @override
  String toString() => 'ExtendedMetadata(${toMap()})';
}

/// Complete parsed audio metadata and raw synthesized container bytes.
///
/// Extracted only when explicitly requested via `analyzeAudio(..., metadata: true)` /
/// `analyzeAudioSync(..., metadata: true)` or during playback when
/// `player.action.setMetadataEnabled(true)` is active.
class AudioMetadata {
  // ===========================================================================
  // Core Tags (17 fields)
  // ===========================================================================

  /// Track title.
  final String? title;

  /// Primary track artist.
  final String? trackArtist;

  /// Album title.
  final String? album;

  /// Album artist.
  final String? albumArtist;

  /// Release or recording year.
  final int? year;

  /// Genre name.
  final String? genre;

  /// Track number within the album/disc.
  final int? trackNumber;

  /// Total tracks on the album/disc.
  final int? trackTotal;

  /// Disc number.
  final int? discNumber;

  /// Total discs in the release.
  final int? discTotal;

  /// Synchronized or unsynchronized lyrics.
  final String? lyrics;

  /// General comment tag.
  final String? comment;

  /// Tempo in beats per minute (BPM).
  final double? bpm;

  /// ReplayGain track gain string (e.g. `"-6.50 dB"`).
  final String? replayGainTrackGain;

  /// ReplayGain track peak string (e.g. `"0.988553"`).
  final String? replayGainTrackPeak;

  /// ReplayGain album gain string.
  final String? replayGainAlbumGain;

  /// ReplayGain album peak string.
  final String? replayGainAlbumPeak;

  // ===========================================================================
  // Pictures, Extended Tags, Chapters, Custom Tags & Container Details
  // ===========================================================================

  /// All embedded pictures / cover art extracted from the container.
  final List<AudioPicture> pictures;

  /// Convenience getter returning the first [PictureType.coverFront] picture,
  /// or the first available picture if no picture is explicitly marked as front cover.
  AudioPicture? get frontCover {
    if (pictures.isEmpty) return null;
    for (final p in pictures) {
      if (p.pictureType == PictureType.coverFront) return p;
    }
    return pictures.first;
  }

  /// Convenience getter returning the first [PictureType.coverBack] picture, or `null` if none.
  AudioPicture? get backCover {
    for (final p in pictures) {
      if (p.pictureType == PictureType.coverBack) return p;
    }
    return null;
  }

  /// Extended 63-field metadata set (MusicBrainz, AcoustID, credits, dates, URLs, podcast, etc.).
  final ExtendedMetadata extended;

  /// Embedded chapter markers sorted by start time.
  final List<AudioChapter> chapters;

  /// Custom user-defined key-value tag fields (`TXXX`, freeform MP4 `----`, custom Vorbis/APE keys).
  final Map<String, String> customTags;

  /// Detected tag container formats present in the stream (e.g. `"ID3v2"`, `"ID3v1"`,
  /// `"VorbisComments"`, `"iTunes"`, `"APE"`, `"RiffInfo"`, `"AiffText"`, `"BWF"`, `"ICY"`).
  final List<String> tagFormats;

  /// Specific ID3v2 major version (`v2`, `v3`, `v4`) if an ID3v2 tag is present.
  final Id3v2Version? id3v2Version;

  /// Live Shoutcast/Icecast ICY metadata when streaming from an ICY server.
  final IcyMetadata? icy;

  /// Raw synthesized metadata container bytes (ID3v2, Vorbis Comments, `moov` atom, etc.).
  final Uint8List bytes;

  static final Uint8List _emptyBytes = Uint8List(0);

  /// Creates an immutable [AudioMetadata] container.
  AudioMetadata({
    this.title,
    this.trackArtist,
    this.album,
    this.albumArtist,
    this.year,
    this.genre,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.discTotal,
    this.lyrics,
    this.comment,
    this.bpm,
    this.replayGainTrackGain,
    this.replayGainTrackPeak,
    this.replayGainAlbumGain,
    this.replayGainAlbumPeak,
    this.pictures = const [],
    this.extended = ExtendedMetadata.empty,
    this.chapters = const [],
    this.customTags = const {},
    this.tagFormats = const [],
    this.id3v2Version,
    this.icy,
    Uint8List? bytes,
  }) : bytes = bytes ?? _emptyBytes;

  /// Creates an [AudioMetadata] from a native [rust_types.RustAudioMetadata] struct.
  factory AudioMetadata.fromRust(rust_types.RustAudioMetadata r) {
    final customMap = <String, String>{
      for (final f in r.customTags) f.key: f.value,
    };
    return AudioMetadata(
      title: r.title,
      trackArtist: r.trackArtist,
      album: r.album,
      albumArtist: r.albumArtist,
      year: r.year,
      genre: r.genre,
      trackNumber: r.trackNumber,
      trackTotal: r.trackTotal,
      discNumber: r.discNumber,
      discTotal: r.discTotal,
      lyrics: r.lyrics,
      comment: r.comment,
      bpm: r.bpm,
      replayGainTrackGain: r.replayGainTrackGain,
      replayGainTrackPeak: r.replayGainTrackPeak,
      replayGainAlbumGain: r.replayGainAlbumGain,
      replayGainAlbumPeak: r.replayGainAlbumPeak,
      pictures: List.unmodifiable(r.pictures.map(AudioPicture.fromRust)),
      extended: ExtendedMetadata.fromRust(r.extended),
      chapters: List.unmodifiable(r.chapters.map(AudioChapter.fromRust)),
      customTags: Map.unmodifiable(customMap),
      tagFormats: List.unmodifiable(r.tagFormats),
      id3v2Version: r.id3V2Version != null
          ? Id3v2Version.fromRust(r.id3V2Version!)
          : null,
      icy: r.icy != null ? IcyMetadata.fromRust(r.icy!) : null,
      bytes: r.bytes,
    );
  }

  /// Converts a native [rust_types.RustAudioMetadata] into an [AudioMetadata],
  /// returning `null` if both [bytes] and all parsed metadata fields are empty.
  static AudioMetadata? fromRustNullable(rust_types.RustAudioMetadata r) {
    final parsed = AudioMetadata.fromRust(r);
    if (parsed.isEmpty) return null;
    return parsed;
  }

  /// Whether any structured tag, picture, chapter, custom tag, or ICY field is populated.
  bool get hasParsedTags =>
      title != null ||
      trackArtist != null ||
      album != null ||
      albumArtist != null ||
      year != null ||
      genre != null ||
      trackNumber != null ||
      trackTotal != null ||
      discNumber != null ||
      discTotal != null ||
      lyrics != null ||
      comment != null ||
      bpm != null ||
      replayGainTrackGain != null ||
      replayGainTrackPeak != null ||
      replayGainAlbumGain != null ||
      replayGainAlbumPeak != null ||
      pictures.isNotEmpty ||
      extended.isNotEmpty ||
      chapters.isNotEmpty ||
      customTags.isNotEmpty ||
      tagFormats.isNotEmpty ||
      id3v2Version != null ||
      icy != null;

  /// Length of the raw metadata byte buffer.
  int get length => bytes.length;

  /// Whether both the raw metadata byte buffer and all parsed metadata fields are empty.
  bool get isEmpty => bytes.isEmpty && !hasParsedTags;

  /// Whether either the raw metadata byte buffer or any parsed metadata field is non-empty.
  bool get isNotEmpty => !isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioMetadata &&
          runtimeType == other.runtimeType &&
          title == other.title &&
          trackArtist == other.trackArtist &&
          album == other.album &&
          albumArtist == other.albumArtist &&
          year == other.year &&
          genre == other.genre &&
          trackNumber == other.trackNumber &&
          trackTotal == other.trackTotal &&
          discNumber == other.discNumber &&
          discTotal == other.discTotal &&
          lyrics == other.lyrics &&
          comment == other.comment &&
          bpm == other.bpm &&
          replayGainTrackGain == other.replayGainTrackGain &&
          replayGainTrackPeak == other.replayGainTrackPeak &&
          replayGainAlbumGain == other.replayGainAlbumGain &&
          replayGainAlbumPeak == other.replayGainAlbumPeak &&
          _listEquals(pictures, other.pictures) &&
          extended == other.extended &&
          _listEquals(chapters, other.chapters) &&
          _mapEquals(customTags, other.customTags) &&
          _listEquals(tagFormats, other.tagFormats) &&
          id3v2Version == other.id3v2Version &&
          icy == other.icy &&
          _bytesEquals(bytes, other.bytes);

  @override
  int get hashCode => Object.hash(
        title,
        trackArtist,
        album,
        albumArtist,
        year,
        genre,
        trackNumber,
        trackTotal,
        discNumber,
        discTotal,
        lyrics,
        comment,
        bpm,
        replayGainTrackGain,
        replayGainTrackPeak,
        replayGainAlbumGain,
        replayGainAlbumPeak,
        Object.hashAll(pictures),
        Object.hash(
          extended,
          Object.hashAll(chapters),
          Object.hashAll(
              customTags.entries.map((e) => Object.hash(e.key, e.value))),
          Object.hashAll(tagFormats),
          id3v2Version,
          icy,
          Object.hashAll(bytes),
        ),
      );

  @override
  String toString() =>
      'AudioMetadata(title: $title, artist: $trackArtist, album: $album, '
      'year: $year, genre: $genre, pictures: ${pictures.length}, '
      'chapters: ${chapters.length}, customTags: ${customTags.length}, '
      'tagFormats: $tagFormats, id3v2Version: ${id3v2Version?.name}, '
      '${bytes.length} bytes)';

  static bool _bytesEquals(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _listEquals<E>(List<E> a, List<E> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }
}
