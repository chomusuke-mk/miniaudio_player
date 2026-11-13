import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:miniaudio_player/miniaudio_player.dart';

import '../models/acoustid_result.dart';
import '../models/audio_track.dart';

class _PendingAnalysisRequest {
  final AudioTrack track;
  final MiniaudioPlayer? engine;
  final bool force;
  final Completer<AudioAnalysisResult?> completer;

  _PendingAnalysisRequest({
    required this.track,
    required this.engine,
    required this.force,
    required this.completer,
  });
}

/// Controller orchestrating on-demand acoustic analysis (ITU-R BS.1770-4 / EBU R128)
/// and track-level ReplayGain synchronization with [MiniaudioPlayer].
///
/// Executes single-pass decoding on background threads, coalesces rapid track switches
/// onto a serial worker without dropping the latest active track, and maintains a
/// persistent session cache of analysis results to prevent redundant processing.
class AudioAnalyzerController extends ChangeNotifier {
  @visibleForTesting
  final Future<AudioAnalysisResult?> Function(AudioTrack track)? analysisRunner;

  /// Creates an [AudioAnalyzerController], optionally injecting a custom [analysisRunner] for tests.
  AudioAnalyzerController({this.analysisRunner});

  final Map<String, AudioAnalysisResult> _resultsByTrack = {};
  final Map<String, String> _errorsByTrack = {};
  final Map<String, AcoustIdLookupResult> _acoustIdCache = {};
  final Map<String, Future<AcoustIdLookupResult>> _pendingAcoustIdLookups = {};
  String? _currentTrackId;
  String? _activeWorkerTrackId;
  Completer<AudioAnalysisResult?>? _activeWorkerCompleter;
  _PendingAnalysisRequest? _queuedRequest;
  bool _disposed = false;

  /// Cached acoustic analysis result for the active track, if available.
  AudioAnalysisResult? get result =>
      _currentTrackId != null ? _resultsByTrack[_currentTrackId] : null;

  /// Identifier of the track currently selected for inspection.
  String? get currentTrackId => _currentTrackId;

  /// Whether the currently selected track is actively analyzing or queued.
  bool get isAnalyzing =>
      _currentTrackId != null && _isTrackPendingById(_currentTrackId!);

  /// Whether an acoustic analysis background task or queued item is active for [track].
  bool isAnalyzingTrack(AudioTrack? track) =>
      track != null && _isTrackPendingById(track.id);

  /// Whether any acoustic analysis task is currently running in the background.
  bool get hasAnyAnalysisInFlight =>
      _activeWorkerTrackId != null || _queuedRequest != null;

  /// Last error message encountered during analysis for the active track, or null.
  String? get error =>
      _currentTrackId != null ? _errorsByTrack[_currentTrackId] : null;

  bool _isTrackPendingById(String trackId) =>
      _activeWorkerTrackId == trackId || _queuedRequest?.track.id == trackId;

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Retrieves the cached [AudioAnalysisResult] for [track], or null if unanalyzed.
  AudioAnalysisResult? getResultForTrack(AudioTrack? track) {
    if (track == null) return null;
    return _resultsByTrack[track.id];
  }

  /// Whether acoustic analysis metrics have been cached for [track].
  bool hasResultForTrack(AudioTrack? track) {
    if (track == null) return false;
    return _resultsByTrack.containsKey(track.id);
  }

  /// Whether the most recent analysis attempt for [track] failed with an error.
  bool hasErrorForTrack(AudioTrack? track) {
    if (track == null) return false;
    return _errorsByTrack.containsKey(track.id);
  }

  /// Sets the currently active track ID for inspection without triggering re-analysis.
  void selectTrack(AudioTrack? track) {
    if (track == null) {
      if (_currentTrackId != null) {
        _currentTrackId = null;
        _safeNotify();
      }
      return;
    }
    if (_currentTrackId != track.id) {
      _currentTrackId = track.id;
      _safeNotify();
    }
  }

  /// Checks whether [track] has active ReplayGain normalization in [engine].
  bool isReplayGainActiveForTrack(AudioTrack? track, MiniaudioPlayer? engine) {
    if (track == null) return false;
    if (engine != null) {
      final queueItem = engine.state.queue
          .cast<AudioSource<dynamic>?>()
          .firstWhere(
            (item) =>
                item?.data is AudioTrack &&
                (item!.data as AudioTrack).id == track.id,
            orElse: () => null,
          );
      if (queueItem != null) {
        return queueItem.replayGainDb != null;
      }
    }
    return track.source.replayGainDb != null;
  }

  /// Toggles ReplayGain loudness normalization specifically for [track] on [engine].
  Future<void> toggleReplayGainForTrack(
    AudioTrack track,
    MiniaudioPlayer engine,
  ) async {
    final queueItem = engine.state.queue
        .cast<AudioSource<dynamic>?>()
        .firstWhere(
          (item) =>
              item?.data is AudioTrack &&
              (item!.data as AudioTrack).id == track.id,
          orElse: () => null,
        );
    final targetId = queueItem?.id ?? track.source.id;
    final currentGain = queueItem?.replayGainDb ?? track.source.replayGainDb;
    final analysis = getResultForTrack(track);

    if (currentGain != null) {
      MapLogger.info(
        '[REPLAY_GAIN:DISPATCH] Bypassing ReplayGain for track "${track.title}" (ID: $targetId)',
      );
      await engine.action.setReplayGain(null, id: targetId);
    } else if (analysis?.replayGain != null) {
      final config = ReplayGainConfig(
        gainDb: analysis!.replayGain!.gainDb,
        peak: analysis.replayGain!.peak,
      );
      MapLogger.info(
        '[REPLAY_GAIN:DISPATCH] Applying ReplayGain to track "${track.title}" (ID: $targetId): ${config.gainDb} dB, peak ${config.peak}',
      );
      await engine.action.setReplayGain(config, id: targetId);
    }
    _safeNotify();
  }

  /// Executes on-demand single-pass acoustic analysis for a single [track].
  ///
  /// If [track] is already cached in [_resultsByTrack] and [force] is false, returns
  /// immediately with zero decoding overhead. If another track is actively decoding,
  /// [track] is queued (coalescing superseded intermediate tracks) and automatically
  /// starts as soon as the active decode finishes.
  Future<AudioAnalysisResult?> analyze(
    AudioTrack track, {
    MiniaudioPlayer? engine,
    bool force = false,
  }) async {
    if (_disposed) return null;

    _currentTrackId = track.id;

    // 1. Session Cache Hit Check
    if (!force && _resultsByTrack.containsKey(track.id)) {
      MapLogger.debug(
        '[ANALYZER:CACHE_HIT] Track "${track.title}" (ID: ${track.id}) retrieved from session cache in 0.05ms.',
      );
      _errorsByTrack.remove(track.id);
      _safeNotify();
      return _resultsByTrack[track.id];
    }

    if (force) {
      _resultsByTrack.remove(track.id);
      _errorsByTrack.remove(track.id);
    }

    // 2. Join if already running for this track (unless re-analysis was forced).
    if (!force &&
        _activeWorkerTrackId == track.id &&
        _activeWorkerCompleter != null) {
      _safeNotify();
      return await _activeWorkerCompleter!.future;
    }

    // 3. Join if already waiting at the head of the queue.
    if (_queuedRequest != null &&
        _queuedRequest!.track.id == track.id &&
        (!force || _queuedRequest!.force)) {
      _safeNotify();
      return await _queuedRequest!.completer.future;
    }

    // 4. Coalesce onto the single background queue if another track is currently decoding.
    if (_activeWorkerTrackId != null) {
      final existing = _queuedRequest;
      if (existing != null && existing.track.id != track.id) {
        _queuedRequest = null;
        if (!existing.completer.isCompleted) {
          existing.completer.complete(null);
        }
      }
      final completer =
          (_queuedRequest != null && _queuedRequest!.track.id == track.id)
          ? _queuedRequest!.completer
          : Completer<AudioAnalysisResult?>();
      _queuedRequest = _PendingAnalysisRequest(
        track: track,
        engine: engine,
        force: force,
        completer: completer,
      );
      _safeNotify();
      return await completer.future;
    }

    final completer = Completer<AudioAnalysisResult?>();
    unawaited(
      _drainAnalysisLoop(
        track,
        engine: engine,
        initialCompleter: completer,
      ),
    );
    return await completer.future;
  }

  Future<void> _drainAnalysisLoop(
    AudioTrack initialTrack, {
    MiniaudioPlayer? engine,
    required Completer<AudioAnalysisResult?> initialCompleter,
  }) async {
    var current = initialTrack;
    var currentEngine = engine;
    var currentCompleter = initialCompleter;
    _activeWorkerTrackId = current.id;
    _activeWorkerCompleter = currentCompleter;
    _errorsByTrack.remove(current.id);
    _safeNotify();

    try {
      while (!_disposed) {
        final result = await _performSingleAnalysis(
          current,
          engine: currentEngine,
        );

        _PendingAnalysisRequest? nextReq;
        while (!_disposed && _queuedRequest != null) {
          final candidate = _queuedRequest!;
          _queuedRequest = null;
          if (!candidate.force &&
              _resultsByTrack.containsKey(candidate.track.id)) {
            if (!candidate.completer.isCompleted) {
              candidate.completer.complete(_resultsByTrack[candidate.track.id]);
            }
            continue;
          }
          nextReq = candidate;
          break;
        }

        if (_disposed || nextReq == null) {
          _activeWorkerTrackId = null;
          _activeWorkerCompleter = null;
          if (!currentCompleter.isCompleted) {
            currentCompleter.complete(result);
          }
          break;
        }

        final completedCompleter = currentCompleter;
        current = nextReq.track;
        currentEngine = nextReq.engine;
        currentCompleter = nextReq.completer;
        _activeWorkerTrackId = current.id;
        _activeWorkerCompleter = currentCompleter;
        _errorsByTrack.remove(current.id);

        if (!completedCompleter.isCompleted) {
          completedCompleter.complete(result);
        }
        _safeNotify();
      }
    } finally {
      _activeWorkerTrackId = null;
      _activeWorkerCompleter = null;
      if (!currentCompleter.isCompleted) {
        currentCompleter.complete(null);
      }
      final pending = _queuedRequest;
      _queuedRequest = null;
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.complete(null);
      }
      _safeNotify();
    }
  }

  Future<AudioAnalysisResult?> _analyzeTarget(Object target) {
    return MiniaudioPlayer.analyzeAudio(
      target,
      waveform: true,
      replayGain: true,
      metadata: true,
      chromaprint: true,
      waveformPoints: 72,
    );
  }

  Future<AudioAnalysisResult?> _decodeAndAnalyze(AudioTrack track) async {
    final runner = analysisRunner;
    if (runner != null) {
      return await runner(track);
    }

    if (track.source.isMemory && track.source.bytes != null) {
      return await _analyzeTarget(track.source.bytes!);
    }

    final uri = track.source.uri;
    if (uri != null) {
      if (uri.startsWith('asset://') ||
          uri.startsWith('asset:') ||
          uri.startsWith('assets/')) {
        final assetPath = uri.startsWith('asset://')
            ? uri.substring('asset://'.length)
            : uri.startsWith('asset:')
            ? uri.substring('asset:'.length)
            : uri;
        if (!kIsWeb && File(assetPath).existsSync()) {
          return await _analyzeTarget(assetPath);
        }
        final byteData = await rootBundle.load(assetPath);
        final bytes = byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        );
        return await _analyzeTarget(bytes);
      }

      final filePath = (!kIsWeb && uri.startsWith('file://'))
          ? Uri.parse(uri).toFilePath()
          : uri;
      return await _analyzeTarget(filePath);
    }

    return await _analyzeTarget(track.source);
  }

  Future<AudioAnalysisResult?> _performSingleAnalysis(
    AudioTrack track, {
    MiniaudioPlayer? engine,
  }) async {
    final stopwatch = Stopwatch()..start();
    MapLogger.info(
      '[ANALYZER:START] Starting single-pass acoustic analysis for track: "${track.title}" (ID: ${track.id})',
    );

    try {
      final res = await _decodeAndAnalyze(track);
      stopwatch.stop();

      if (res == null) {
        _errorsByTrack[track.id] = 'Analysis returned no result';
        return null;
      }

      _resultsByTrack[track.id] = res;
      _errorsByTrack.remove(track.id);

      MapLogger.info(
        '[ANALYZER:DONE] Analysis completed in ${stopwatch.elapsedMilliseconds}ms for "${track.title}": '
        'Loudness=${res.replayGain?.lufs.toStringAsFixed(2)} LUFS, '
        'Gain=${res.replayGain?.gainDb.toStringAsFixed(2)} dB, '
        'Peak=${res.replayGain?.peak.toStringAsFixed(4)}, '
        'Waveform=${res.waveform?.points.length ?? 0} points',
      );

      // Synchronize ReplayGain directly with native engine if still active
      if (engine != null &&
          !engine.isDisposed &&
          !_disposed &&
          res.replayGain != null) {
        final queueItem = engine.state.queue
            .cast<AudioSource<dynamic>?>()
            .firstWhere(
              (item) =>
                  item?.data is AudioTrack &&
                  (item!.data as AudioTrack).id == track.id,
              orElse: () => null,
            );
        final targetId = queueItem?.id ?? track.source.id;
        if (targetId != null) {
          final config = ReplayGainConfig(
            gainDb: res.replayGain!.gainDb,
            peak: res.replayGain!.peak,
          );
          MapLogger.info(
            '[REPLAY_GAIN:DISPATCH] Synchronizing ReplayGain to engine for track "${track.title}" (ID: $targetId): ${config.gainDb} dB',
          );
          await engine.action.setReplayGain(config, id: targetId);
        }
      }
      return res;
    } catch (e) {
      stopwatch.stop();
      _errorsByTrack[track.id] = e.toString();
      MapLogger.error(
        '[ANALYZER:ERROR] Failed analysis for "${track.title}": $e',
      );
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _activeWorkerTrackId = null;
    final activeCompleter = _activeWorkerCompleter;
    _activeWorkerCompleter = null;
    if (activeCompleter != null && !activeCompleter.isCompleted) {
      activeCompleter.complete(null);
    }
    final pending = _queuedRequest;
    _queuedRequest = null;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(null);
    }
    super.dispose();
  }

  /// Retrieves cached AcoustID lookup result for [fingerprint], if previously fetched.
  AcoustIdLookupResult? getAcoustIdFromCache(String? fingerprint) {
    if (fingerprint == null) return null;
    return _acoustIdCache[fingerprint];
  }

  /// Queries AcoustID API for track identification with in-memory session caching
  /// and concurrency deduplication to prevent redundant network calls across rebuilds.
  Future<AcoustIdLookupResult> lookupAcoustId({
    required String fingerprint,
    required double durationSeconds,
  }) async {
    // 1. Session Cache Check
    if (_acoustIdCache.containsKey(fingerprint)) {
      MapLogger.debug(
        '[ACOUSTID:CACHE_HIT] Fingerprint "$fingerprint" retrieved from in-memory session cache.',
      );
      return _acoustIdCache[fingerprint]!.withCacheFlag(true);
    }

    // 2. Concurrency Deduplication (re-use in-flight future if already executing)
    if (_pendingAcoustIdLookups.containsKey(fingerprint)) {
      MapLogger.debug(
        '[ACOUSTID:IN_FLIGHT] Re-using in-flight network request for fingerprint "$fingerprint".',
      );
      return await _pendingAcoustIdLookups[fingerprint]!;
    }

    final future = _performAcoustIdLookup(fingerprint, durationSeconds);
    _pendingAcoustIdLookups[fingerprint] = future;

    try {
      final result = await future;
      _acoustIdCache[fingerprint] = result;
      notifyListeners();
      return result;
    } finally {
      _pendingAcoustIdLookups.remove(fingerprint);
    }
  }

  Future<AcoustIdLookupResult> _performAcoustIdLookup(
    String fingerprint,
    double durationSeconds,
  ) async {
    final client = http.Client();
    try {
      final dur = durationSeconds.round();
      final body = <String, String>{
        'meta': 'recordings releasegroups tracks usermeta releases',
        'duration': dur > 0 ? '$dur' : '1',
        'fingerprint': fingerprint,
      };

      // Primary endpoint: VideoLAN public AcoustID proxy (used by VLC media player)
      final primaryUri = Uri.parse(
        'https://fingerprint.videolan.org/acoustid.php',
      );
      // Secondary fallback endpoint: upstream AcoustID API
      final fallbackUri = Uri.parse('https://api.acoustid.org/v2/lookup');

      http.Response? response;
      String currentEndpoint = primaryUri.toString();

      MapLogger.info(
        '[ACOUSTID:REQUEST] POST $currentEndpoint | duration: ${dur}s, fingerprint length: ${fingerprint.length} chars',
      );

      try {
        response = await client
            .post(
              primaryUri,
              body: body,
              headers: {
                'Content-Type':
                    'application/x-www-form-urlencoded; charset=utf-8',
              },
            )
            .timeout(const Duration(seconds: 12));
      } catch (primaryErr) {
        MapLogger.warn(
          '[ACOUSTID:FALLBACK] Primary endpoint failed ($primaryErr). Attempting fallback to $fallbackUri...',
        );
        currentEndpoint = fallbackUri.toString();
        response = await client
            .post(
              fallbackUri,
              body: body,
              headers: {
                'Content-Type':
                    'application/x-www-form-urlencoded; charset=utf-8',
              },
            )
            .timeout(const Duration(seconds: 12));
      }

      MapLogger.info(
        '[ACOUSTID:RESPONSE] HTTP ${response.statusCode} from $currentEndpoint | Content-Length: ${response.body.length} bytes',
      );

      if (response.statusCode != 200) {
        String detail =
            'AcoustID HTTP Error: status code ${response.statusCode}';
        try {
          final errData = jsonDecode(response.body);
          if (errData is Map && errData['error'] is Map) {
            final msg = errData['error']['message'];
            if (msg != null) {
              detail = '$detail ($msg)';
            }
          }
        } catch (_) {}
        MapLogger.error('[ACOUSTID:ERROR_BODY] $detail: ${response.body}');
        return AcoustIdLookupResult.failure(detail);
      }

      final dynamic data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        MapLogger.error(
          '[ACOUSTID:PARSE_ERROR] Invalid JSON payload received: ${response.body}',
        );
        return AcoustIdLookupResult.failure(
          'Invalid JSON response received from AcoustID API',
        );
      }

      if (data['status'] != 'ok') {
        final errorMsg =
            data['error']?['message'] ??
            'AcoustID API returned status "${data['status']}"';
        MapLogger.warn('[ACOUSTID:STATUS_ERROR] $errorMsg');
        return AcoustIdLookupResult.failure(errorMsg.toString());
      }

      final resultsList = <AcoustIdMatch>[];
      if (data['results'] is List) {
        for (final r in data['results']) {
          if (r is Map) {
            resultsList.add(AcoustIdMatch.fromJson(r.cast<String, dynamic>()));
          }
        }
      }

      final topTitle =
          resultsList.isNotEmpty && resultsList.first.recordings.isNotEmpty
          ? resultsList.first.recordings.first.title
          : 'no recordings';
      MapLogger.info(
        '[ACOUSTID:DONE] Lookup succeeded: ${resultsList.length} clusters found. Top match: "$topTitle".',
      );
      return AcoustIdLookupResult.success(resultsList, isFromCache: false);
    } catch (e) {
      MapLogger.error('[ACOUSTID:EXCEPTION] AcoustID lookup failed: $e');
      return AcoustIdLookupResult.failure('Network or decoding error: $e');
    } finally {
      client.close();
    }
  }
}
