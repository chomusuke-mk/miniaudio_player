import 'dart:js_interop';

@JS()
extension type JSAnalysisResult._(JSObject _) implements JSObject {
  external factory JSAnalysisResult({
    double durationMs,
    double peak,
    double bitrate,
    double sampleRate,
    double channels,
    bool hasReplayGain,
    double replayGainGainDb,
    double replayGainPeak,
    double replayGainLufs,
    JSFloat32Array? waveform,
  });

  external double get durationMs;
  external double get peak;
  external double get bitrate;
  external double get sampleRate;
  external double get channels;
  external bool get hasReplayGain;
  external double get replayGainGainDb;
  external double get replayGainPeak;
  external double get replayGainLufs;
  external JSFloat32Array? get waveform;
}

@JS()
extension type WebWorkerMessage._(JSObject _) implements JSObject {
  external String get type;
  external JSArray<JSNumber>? get data;
  external String? error;
  external int? player;
  external int? result;
  external int? audioDataOffset;
  external int? pinnedHeadSize;
  external int? id;
  external int? status;
  external JSAnalysisResult? get analysisResult;
}

@JS()
extension type WebWorkerCommand._(JSObject _) implements JSObject {
  external factory WebWorkerCommand({
    required String type,
    String? wasmUrl,
    int? sampleRate,
    int? channels,
    int? periodSize,
    int? logLevel,
    String? url,
    bool? isLive,
    int? bufferCapacity,
    int? encodingFormat,
    int? totalSize,
    JSUint8Array? bytes,
    JSUint8Array? tailBytes,
    int? tailOffset,
    int? newStreamOffset,
    double? positionMs,
    double? volume,
    double? rate,
    double? pitch,
    double? pan,
    double? preampDb,
    double? peak,
    bool? preventClipping,
    double? width,
    double? roomSize,
    double? damping,
    double? wet,
    double? dry,
    int? band,
    double? gainDb,
    JSArray<JSNumber>? gainsDb,
    bool? enabled,
    int? preset,
    int? mode,
    double? thresholdDb,
    int? minDurationMs,
    int? id,
    int? flags,
    double? targetLufs,
    int? waveformPoints,
  });
}
