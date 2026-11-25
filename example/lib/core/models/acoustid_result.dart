/// Strongly-typed MusicBrainz release group descriptor returned by AcoustID.
class AcoustIdReleaseGroup {
  /// MusicBrainz release group UUID.
  final String id;

  /// Album or release group title.
  final String title;

  /// Optional release classification (for example `Album`, `Single`, or `EP`).
  final String? type;

  /// Creates an [AcoustIdReleaseGroup] with the given [id], [title], and
  /// optional [type].
  const AcoustIdReleaseGroup({
    required this.id,
    required this.title,
    this.type,
  });

  /// Parses an [AcoustIdReleaseGroup] from a JSON [json] map.
  factory AcoustIdReleaseGroup.fromJson(Map<String, dynamic> json) {
    return AcoustIdReleaseGroup(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      type: json['type'] as String?,
    );
  }
}

/// Individual MusicBrainz recording match returned within an [AcoustIdMatch].
class AcoustIdRecording {
  /// MusicBrainz recording UUID.
  final String id;

  /// Recording track title.
  final String title;

  /// Primary artist names credited on this recording.
  final List<String> artists;

  /// Associated release groups or albums containing this recording.
  final List<AcoustIdReleaseGroup> releaseGroups;

  /// Creates an [AcoustIdRecording] with [id], [title], [artists], and
  /// [releaseGroups].
  const AcoustIdRecording({
    required this.id,
    required this.title,
    required this.artists,
    required this.releaseGroups,
  });

  /// Parses an [AcoustIdRecording] from a JSON [json] map.
  factory AcoustIdRecording.fromJson(Map<String, dynamic> json) {
    final artistsList = <String>[];
    if (json['artists'] is List) {
      for (final a in json['artists']) {
        if (a is Map && a['name'] is String) {
          artistsList.add(a['name'] as String);
        }
      }
    }

    final rgsList = <AcoustIdReleaseGroup>[];
    if (json['releasegroups'] is List) {
      for (final rg in json['releasegroups']) {
        if (rg is Map) {
          rgsList.add(
            AcoustIdReleaseGroup.fromJson(rg.cast<String, dynamic>()),
          );
        }
      }
    }

    return AcoustIdRecording(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artists: artistsList,
      releaseGroups: rgsList,
    );
  }
}

/// AcoustID acoustic match cluster with a normalized similarity score.
class AcoustIdMatch {
  /// AcoustID track UUID.
  final String id;

  /// Acoustic match similarity score in the range `0.0` to `1.0`.
  final double score;

  /// MusicBrainz recordings associated with this acoustic cluster.
  final List<AcoustIdRecording> recordings;

  /// Creates an [AcoustIdMatch] with [id], [score], and [recordings].
  const AcoustIdMatch({
    required this.id,
    required this.score,
    required this.recordings,
  });

  /// Parses an [AcoustIdMatch] from a JSON [json] map.
  factory AcoustIdMatch.fromJson(Map<String, dynamic> json) {
    final recList = <AcoustIdRecording>[];
    if (json['recordings'] is List) {
      for (final r in json['recordings']) {
        if (r is Map) {
          recList.add(AcoustIdRecording.fromJson(r.cast<String, dynamic>()));
        }
      }
    }

    return AcoustIdMatch(
      id: json['id'] as String? ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
      recordings: recList,
    );
  }
}

/// Session lookup result encapsulating an AcoustID API response and cache flag.
class AcoustIdLookupResult {
  /// Whether the network request and JSON decoding succeeded.
  final bool success;

  /// Human-readable error message when [success] is `false`.
  final String? errorMessage;

  /// Ranked acoustic matches returned by the AcoustID service.
  final List<AcoustIdMatch> matches;

  /// Whether this result was served from the in-memory session cache.
  final bool isFromCache;

  /// Timestamp when this result was fetched or stored in the cache.
  final DateTime timestamp;

  /// Creates an [AcoustIdLookupResult] describing the lookup outcome.
  const AcoustIdLookupResult({
    required this.success,
    this.errorMessage,
    this.matches = const [],
    this.isFromCache = false,
    required this.timestamp,
  });

  /// Constructs a failed [AcoustIdLookupResult] carrying [message] and
  /// [isFromCache].
  factory AcoustIdLookupResult.failure(
    String message, {
    bool isFromCache = false,
  }) {
    return AcoustIdLookupResult(
      success: false,
      errorMessage: message,
      matches: const [],
      isFromCache: isFromCache,
      timestamp: DateTime.now(),
    );
  }

  /// Constructs a successful [AcoustIdLookupResult] with [matches] and
  /// [isFromCache].
  factory AcoustIdLookupResult.success(
    List<AcoustIdMatch> matches, {
    bool isFromCache = false,
  }) {
    return AcoustIdLookupResult(
      success: true,
      matches: matches,
      isFromCache: isFromCache,
      timestamp: DateTime.now(),
    );
  }

  /// Returns a copy of this result with [isFromCache] updated to [fromCache].
  AcoustIdLookupResult withCacheFlag(bool fromCache) {
    return AcoustIdLookupResult(
      success: success,
      errorMessage: errorMessage,
      matches: matches,
      isFromCache: fromCache,
      timestamp: timestamp,
    );
  }
}
