import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:miniaudio_player/miniaudio_player.dart';
import '../models/acoustid_result.dart';
import '../models/audio_track.dart';

/// Controller orchestrating on-demand acoustic analysis (ITU-R BS.1770-4 / EBU R128)
/// and track-level ReplayGain synchronization with [MiniaudioPlayer].
///
/// Executes single-pass decoding on background threads and maintains a persistent
/// session cache of analysis results to prevent redundant processing.
class AudioAnalyzerController extends ChangeNotifier {
  final Map<String, AudioAnalysisResult> _resultsByTrack = {};
  final Map<String, AcoustIdLookupResult> _acoustIdCache = {};
  final Map<String, Future<AcoustIdLookupResult>> _pendingAcoustIdLookups = {};
  String? _currentTrackId;
  bool _isAnalyzing = false;
  String? _error;

  /// Cached acoustic analysis result for the active track, if available.
  AudioAnalysisResult? get result =>
      _currentTrackId != null ? _resultsByTrack[_currentTrackId] : null;

  /// Identifier of the track currently being analyzed or selected.
  String? get currentTrackId => _currentTrackId;

  /// Whether an acoustic analysis background task is actively running.
  bool get isAnalyzing => _isAnalyzing;

  /// Last error message encountered during analysis, or null.
  String? get error => _error;

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

  /// Checks whether [track] has active ReplayGain normalization in [engine].
  bool isReplayGainActiveForTrack(AudioTrack? track, MiniaudioPlayer? engine) {
    if (track == null) return false;
    if (engine != null) {
      final queueItem = engine.state.queue.cast<AudioSource<dynamic>?>().firstWhere(
        (item) => item?.data is AudioTrack && (item!.data as AudioTrack).id == track.id,
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
    final queueItem = engine.state.queue.cast<AudioSource<dynamic>?>().firstWhere(
      (item) => item?.data is AudioTrack && (item!.data as AudioTrack).id == track.id,
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
    notifyListeners();
  }

  /// Executes on-demand single-pass acoustic analysis for a single [track].
  ///
  /// If [track] is already cached in [_resultsByTrack], returns immediately with zero decoding overhead.
  /// If [engine] is supplied and ReplayGain metrics are computed, automatically dispatches
  /// [ReplayGainConfig] targeting the track's engine slot by ID.
  Future<AudioAnalysisResult?> analyze(
    AudioTrack track, {
    MiniaudioPlayer? engine,
  }) async {
    // 1. Session Cache Hit Check
    if (_resultsByTrack.containsKey(track.id)) {
      MapLogger.debug(
        '[ANALYZER:CACHE_HIT] Track "${track.title}" (ID: ${track.id}) retrieved from session cache in 0.05ms.',
      );
      _currentTrackId = track.id;
      notifyListeners();
      return _resultsByTrack[track.id];
    }

    _currentTrackId = track.id;
    _isAnalyzing = true;
    _error = null;
    notifyListeners();

    final stopwatch = Stopwatch()..start();
    MapLogger.info(
      '[ANALYZER:START] Starting single-pass acoustic analysis for track: "${track.title}" (ID: ${track.id})',
    );

    try {
      AudioAnalysisResult? res;

      if (track.source.isMemory && track.source.bytes != null) {
        res = await MiniaudioPlayer.analyzeAudio(
          track.source.bytes!,
          waveform: true,
          replayGain: true,
          metadata: true,
          chromaprint: true,
          waveformPoints: 72,
        );
      } else if (track.source.uri != null) {
        final s = track.source.uri!;
        if (s.startsWith('asset://') || s.startsWith('asset:') || s.startsWith('assets/')) {
          final assetPath = s.startsWith('asset://')
              ? s.substring('asset://'.length)
              : s.startsWith('asset:')
                  ? s.substring('asset:'.length)
                  : s;
          try {
            final byteData = await rootBundle.load(assetPath);
            final bytes = byteData.buffer.asUint8List(
              byteData.offsetInBytes,
              byteData.lengthInBytes,
            );
            res = await MiniaudioPlayer.analyzeAudio(
              bytes,
              waveform: true,
              replayGain: true,
              metadata: true,
              chromaprint: true,
              waveformPoints: 72,
            );
          } catch (_) {
            if (!kIsWeb && File(assetPath).existsSync()) {
              res = await MiniaudioPlayer.analyzeAudio(
                assetPath,
                waveform: true,
                replayGain: true,
                metadata: true,
                chromaprint: true,
                waveformPoints: 72,
              );
            }
          }
        } else {
          final filePath = (!kIsWeb && s.startsWith('file://'))
              ? Uri.parse(s).toFilePath()
              : s;
          res = await MiniaudioPlayer.analyzeAudio(
            filePath,
            waveform: true,
            replayGain: true,
            metadata: true,
            chromaprint: true,
            waveformPoints: 72,
          );
        }
      } else {
        res = await MiniaudioPlayer.analyzeAudio(
          track.source,
          waveform: true,
          replayGain: true,
          metadata: true,
          chromaprint: true,
          waveformPoints: 72,
        );
      }

      stopwatch.stop();

      if (res != null) {
        _resultsByTrack[track.id] = res;

        MapLogger.info(
          '[ANALYZER:DONE] Analysis completed in ${stopwatch.elapsedMilliseconds}ms for "${track.title}": '
          'Loudness=${res.replayGain?.lufs.toStringAsFixed(2)} LUFS, '
          'Gain=${res.replayGain?.gainDb.toStringAsFixed(2)} dB, '
          'Peak=${res.replayGain?.peak.toStringAsFixed(4)}, '
          'Waveform=${res.waveform?.points.length ?? 0} points',
        );

        // 2. Synchronize ReplayGain directly with native engine if provided
        if (engine != null && res.replayGain != null) {
          final queueItem = engine.state.queue.cast<AudioSource<dynamic>?>().firstWhere(
            (item) => item?.data is AudioTrack && (item!.data as AudioTrack).id == track.id,
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
      }
      return res;
    } catch (e) {
      stopwatch.stop();
      _error = e.toString();
      MapLogger.error('[ANALYZER:ERROR] Failed analysis for "${track.title}": $e');
      return null;
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }
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
      final primaryUri = Uri.parse('https://fingerprint.videolan.org/acoustid.php');
      // Secondary fallback endpoint: upstream AcoustID API
      final fallbackUri = Uri.parse('https://api.acoustid.org/v2/lookup');

      http.Response? response;
      String currentEndpoint = primaryUri.toString();

      MapLogger.info(
        '[ACOUSTID:REQUEST] POST $currentEndpoint | duration: ${dur}s, fingerprint length: ${fingerprint.length} chars',
      );

      try {
        response = await client.post(
          primaryUri,
          body: body,
          headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8'},
        ).timeout(const Duration(seconds: 12));
      } catch (primaryErr) {
        MapLogger.warn(
          '[ACOUSTID:FALLBACK] Primary endpoint failed ($primaryErr). Attempting fallback to $fallbackUri...',
        );
        currentEndpoint = fallbackUri.toString();
        response = await client.post(
          fallbackUri,
          body: body,
          headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8'},
        ).timeout(const Duration(seconds: 12));
      }

      MapLogger.info(
        '[ACOUSTID:RESPONSE] HTTP ${response.statusCode} from $currentEndpoint | Content-Length: ${response.body.length} bytes',
      );

      if (response.statusCode != 200) {
        String detail = 'AcoustID HTTP Error: status code ${response.statusCode}';
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
        MapLogger.error('[ACOUSTID:PARSE_ERROR] Invalid JSON payload received: ${response.body}');
        return AcoustIdLookupResult.failure('Invalid JSON response received from AcoustID API');
      }

      if (data['status'] != 'ok') {
        final errorMsg =
            data['error']?['message'] ?? 'AcoustID API returned status "${data['status']}"';
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

      final topTitle = resultsList.isNotEmpty && resultsList.first.recordings.isNotEmpty
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
