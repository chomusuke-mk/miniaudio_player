import 'dart:js_interop';

@JS()
extension type WebWorkerMessage._(JSObject _) implements JSObject {
  external String get type;
  external JSArray<JSNumber>? get data;
  external String? error;
  external int? player;
  external int? result;
  external int? audioDataOffset;
  external int? pinnedHeadSize;
}

@JS()
extension type WebWorkerCommand._(JSObject _) implements JSObject {
  external factory WebWorkerCommand({
    required String type,
    String? wasmUrl,
    int? sampleRate,
    int? channels,
    int? periodSize,
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
    int? band,
    double? gainDb,
    JSArray<JSNumber>? gainsDb,
    bool? enabled,
    int? preset,
    int? mode,
    double? thresholdDb,
    int? minDurationMs,
  });
}
