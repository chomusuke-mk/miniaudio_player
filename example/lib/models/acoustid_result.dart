/// Strongly-typed models for AcoustID / MusicBrainz web lookup results.
class AcoustIdReleaseGroup {
  /// MusicBrainz release group UUID.
  final String id;

  /// Album or release group title.
  final String title;

  /// Release type (e.g. "Album", "Single", "EP").
  final String? type;

  const AcoustIdReleaseGroup({
    required this.id,
    required this.title,
    this.type,
  });

  factory AcoustIdReleaseGroup.fromJson(Map<String, dynamic> json) {
    return AcoustIdReleaseGroup(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      type: json['type'] as String?,
    );
  }
}

/// Represents an individual MusicBrainz recording match returned by AcoustID.
class AcoustIdRecording {
  /// MusicBrainz recording UUID.
  final String id;

  /// Recording track title.
  final String title;

  /// Primary artists credited on this recording.
  final List<String> artists;

  /// Associated release groups / albums containing this recording.
  final List<AcoustIdReleaseGroup> releaseGroups;

  const AcoustIdRecording({
    required this.id,
    required this.title,
    required this.artists,
    required this.releaseGroups,
  });

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
          rgsList.add(AcoustIdReleaseGroup.fromJson(rg.cast<String, dynamic>()));
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

/// AcoustID acoustic match cluster with confidence score.
class AcoustIdMatch {
  /// AcoustID track UUID.
  final String id;

  /// Acoustic match similarity score (0.0 to 1.0).
  final double score;

  /// Associated MusicBrainz recordings matching this acoustic cluster.
  final List<AcoustIdRecording> recordings;

  const AcoustIdMatch({
    required this.id,
    required this.score,
    required this.recordings,
  });

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

/// Session lookup result encapsulating API response, cached state, and error handling.
class AcoustIdLookupResult {
  /// Whether the network request and JSON parsing completed successfully.
  final bool success;

  /// Human-readable error message if the query failed.
  final String? errorMessage;

  /// Ranked acoustic matches returned by the AcoustID service.
  final List<AcoustIdMatch> matches;

  /// Whether this result was retrieved from session in-memory cache.
  final bool isFromCache;

  /// Timestamp when this result was produced or cached.
  final DateTime timestamp;

  const AcoustIdLookupResult({
    required this.success,
    this.errorMessage,
    this.matches = const [],
    this.isFromCache = false,
    required this.timestamp,
  });

  factory AcoustIdLookupResult.failure(String message, {bool isFromCache = false}) {
    return AcoustIdLookupResult(
      success: false,
      errorMessage: message,
      matches: const [],
      isFromCache: isFromCache,
      timestamp: DateTime.now(),
    );
  }

  factory AcoustIdLookupResult.success(List<AcoustIdMatch> matches, {bool isFromCache = false}) {
    return AcoustIdLookupResult(
      success: true,
      matches: matches,
      isFromCache: isFromCache,
      timestamp: DateTime.now(),
    );
  }

  /// Copies this result with updated cache status.
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
