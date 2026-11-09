import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import '../models/audio_track.dart';

class AudioAnalyzerController extends ChangeNotifier {
  final Map<String, AudioAnalysisResult> _resultsByTrack = {};
  String? _currentTrackId;
  bool _isAnalyzing = false;
  String? _error;
  bool _replayGainActive = false;
  bool _preventClipping = true;

  AudioAnalysisResult? get result =>
      _currentTrackId != null ? _resultsByTrack[_currentTrackId] : null;

  String? get currentTrackId => _currentTrackId;
  bool get isAnalyzing => _isAnalyzing;
  String? get error => _error;
  bool get replayGainActive => _replayGainActive;
  bool get preventClipping => _preventClipping;

  AudioAnalysisResult? getResultForTrack(AudioTrack? track) {
    if (track == null) return null;
    return _resultsByTrack[track.id];
  }

  bool hasResultForTrack(AudioTrack? track) {
    if (track == null) return false;
    return _resultsByTrack.containsKey(track.id);
  }

  void setCurrentTrack(AudioTrack? track, MiniaudioPlayer engine) {
    _currentTrackId = track?.id;
    _error = null;

    if (track == null) {
      engine.action.setReplayGain(null);
    } else if (_replayGainActive) {
      final curRes = result;
      if (curRes?.replayGain != null) {
        engine.action.setReplayGain(
          ReplayGainConfig(
            gainDb: curRes!.replayGain!.gainDb,
            peak: curRes.replayGain!.peak,
          ),
        );
      } else {
        engine.action.setReplayGain(null);
      }
    }
    notifyListeners();
  }

  void setPreventClipping(bool val, MiniaudioPlayer engine) {
    _preventClipping = val;
    final curRes = result;
    if (_replayGainActive && curRes?.replayGain != null) {
      engine.action.setReplayGain(
        ReplayGainConfig(
          gainDb: curRes!.replayGain!.gainDb,
          peak: curRes.replayGain!.peak,
        ),
      );
    }
    notifyListeners();
  }

  void setReplayGainActive(bool val, MiniaudioPlayer engine) {
    _replayGainActive = val;
    final curRes = result;
    if (val && curRes?.replayGain != null) {
      engine.action.setReplayGain(
        ReplayGainConfig(
          gainDb: curRes!.replayGain!.gainDb,
          peak: curRes.replayGain!.peak,
        ),
      );
    } else {
      engine.action.setReplayGain(null);
    }
    notifyListeners();
  }

  /// Analyzes all tracks in [tracks] sequentially to populate metadata, waveform, and ReplayGain.
  Future<void> analyzeAll(List<AudioTrack> tracks) async {
    for (final track in tracks) {
      if (!_resultsByTrack.containsKey(track.id)) {
        await analyze(track);
      }
    }
  }

  Future<void> analyze(AudioTrack track) async {
    _currentTrackId = track.id;
    _isAnalyzing = true;
    _error = null;
    notifyListeners();

    try {
      AudioAnalysisResult? res;

      if (track.source.isMemory && track.source.bytes != null) {
        res = await MiniaudioPlayer.analyzeAudio(
          track.source.bytes!,
          waveform: true,
          replayGain: true,
          metadata: true,
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
              waveformPoints: 72,
            );
          } catch (_) {
            if (!kIsWeb && File(assetPath).existsSync()) {
              res = await MiniaudioPlayer.analyzeAudio(
                assetPath,
                waveform: true,
                replayGain: true,
                metadata: true,
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
            waveformPoints: 72,
          );
        }
      } else {
        // Fallback to analyzing source directly
        res = await MiniaudioPlayer.analyzeAudio(
          track.source,
          waveform: true,
          replayGain: true,
          metadata: true,
          waveformPoints: 72,
        );
      }

      if (res != null) {
        _resultsByTrack[track.id] = res;
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }
  }
}
