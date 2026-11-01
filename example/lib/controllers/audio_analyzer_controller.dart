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

  void setCurrentTrack(AudioTrack? track, MiniaudioEngine engine) {
    _currentTrackId = track?.id;
    _error = null;

    if (track == null || !track.canAnalyze) {
      engine.action.clearReplayGain();
    } else if (_replayGainActive) {
      final curRes = result;
      if (curRes?.replayGain != null) {
        engine.action.setReplayGain(
          gainDb: curRes!.replayGain!.gainDb,
          peak: curRes.replayGain!.peak,
          preventClipping: _preventClipping,
        );
      } else {
        engine.action.clearReplayGain();
      }
    }
    notifyListeners();
  }

  void setPreventClipping(bool val, MiniaudioEngine engine) {
    _preventClipping = val;
    final curRes = result;
    if (_replayGainActive && curRes?.replayGain != null) {
      engine.action.setReplayGain(
        gainDb: curRes!.replayGain!.gainDb,
        peak: curRes.replayGain!.peak,
        preventClipping: _preventClipping,
      );
    }
    notifyListeners();
  }

  void setReplayGainActive(bool val, MiniaudioEngine engine) {
    _replayGainActive = val;
    final curRes = result;
    if (val && curRes?.replayGain != null) {
      engine.action.setReplayGain(
        gainDb: curRes!.replayGain!.gainDb,
        peak: curRes.replayGain!.peak,
        preventClipping: _preventClipping,
      );
    } else {
      engine.action.clearReplayGain();
    }
    notifyListeners();
  }

  Future<void> analyze(AudioTrack track) async {
    if (_isAnalyzing) return;
    _currentTrackId = track.id;

    if (!track.canAnalyze) {
      _error = 'Format ${track.displayType} does not support offline analysis.';
      notifyListeners();
      return;
    }

    _isAnalyzing = true;
    _error = null;
    notifyListeners();

    try {
      AudioAnalysisResult? res;

      if (track.source is MemoryAudioSource) {
        final bytes = (track.source as MemoryAudioSource).bytes;
        res = await MiniaudioPlayer.analyzeAudioMemory(
          bytes,
          waveform: true,
          replayGain: true,
          waveformPoints: 72,
        );
      } else if (!kIsWeb && track.source is UriAudioSource) {
        final s = (track.source as UriAudioSource).sourceString;
        if (s.startsWith('assets/')) {
          final byteData = await rootBundle.load(s);
          final bytes = byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          );
          res = await MiniaudioPlayer.analyzeAudioMemory(
            bytes,
            waveform: true,
            replayGain: true,
            waveformPoints: 72,
          );
        } else if (File(s).existsSync()) {
          res = await MiniaudioPlayer.analyzeAudio(
            s,
            waveform: true,
            replayGain: true,
            waveformPoints: 72,
          );
        }
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
