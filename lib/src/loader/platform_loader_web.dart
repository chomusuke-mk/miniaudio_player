import 'dart:js_interop';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../rust/frb_generated.dart';

/// Candidate prefixes where `miniaudio_player.js` and `miniaudio_player_bg.wasm`
/// may be served from on Web:
/// 1. `assets/packages/miniaudio_player/assets/web/` — served automatically by
///    Flutter Web (`flutter build web` and `flutter run -d chrome`) via the
///    `flutter: assets:` declaration in `pubspec.yaml`.
/// 2. `packages/miniaudio_player/assets/web/` — Dart DWDS dev server package route.
/// 3. `assets/web/` — local app `web/assets/web/` bundle override.
/// 4. `pkg/` — custom manual `web/pkg/` deployment fallback.
const _candidateWebPrefixes = <String>[
  'assets/packages/miniaudio_player/assets/web/',
  'packages/miniaudio_player/assets/web/',
  'assets/web/',
  'pkg/',
];

/// Resolves and loads the WebAssembly `miniaudio_player` bundle across Flutter
/// Web (`assets/packages/...`), DWDS (`packages/...`), `assets/web/`, and `pkg/`.
Future<ExternalLibrary?> resolvePlatformExternalLibrary({
  String? customLibraryPath,
}) async {
  if (!_isCrossOriginIsolated()) {
    throw StateError(
      '[miniaudio_player] WebAssembly multi-threading requires Cross-Origin '
      'Isolation (`SharedArrayBuffer`). Serve your application with HTTP headers:\n'
      '  Cross-Origin-Opener-Policy: same-origin\n'
      '  Cross-Origin-Embedder-Policy: require-corp\n'
      'For local development with `flutter run`, pass:\n'
      '  flutter run -d chrome '
      '--web-header=Cross-Origin-Opener-Policy=same-origin '
      '--web-header=Cross-Origin-Embedder-Policy=require-corp',
    );
  }

  const defaultConfig = RustLib.kDefaultExternalLibraryLoaderConfig;
  final stem = defaultConfig.stem;

  for (final prefix in _candidateWebPrefixes) {
    final jsPath = '$prefix$stem.js';
    if (await _isWasmJsServed(jsPath)) {
      final library = await loadExternalLibrary(
        ExternalLibraryLoaderConfig(
          stem: stem,
          ioDirectory: defaultConfig.ioDirectory,
          webPrefix: prefix,
          wasmBindgenName: defaultConfig.wasmBindgenName,
        ),
      );
      _ensureWebAudioOutputBridge(defaultConfig.wasmBindgenName);
      return library;
    }
  }

  throw StateError(
    '[miniaudio_player] WebAssembly module ($stem.js / ${stem}_bg.wasm) could '
    'not be loaded from any candidate URL:\n'
    '${_candidateWebPrefixes.map((p) => '  - $p$stem.js').join('\n')}\n'
    'Ensure `flutter build web` bundled the package assets (`assets/web/`) '
    'or that your custom `pkg/` folder serves `$stem.js` and `${stem}_bg.wasm`.',
  );
}

/// Checks via `fetch` whether [url] exists and is served as JavaScript (and not
/// an SPA `index.html` fallback).
Future<bool> _isWasmJsServed(String url) async {
  try {
    final response = await _jsFetch(url.toJS).toDart;
    if (!response.ok) return false;
    final contentType =
        response.headers.get('content-type'.toJS)?.toDart.toLowerCase() ?? '';
    if (contentType.contains('text/html')) return false;
    return true;
  } catch (_) {
    return false;
  }
}

/// No-op on Web (Dart isolates do not share native finalizers in WASM).
void registerIsolateWithLibrary(ExternalLibrary library) {}

bool _webAudioOutputStarted = false;

void _ensureWebAudioOutputBridge(String wasmBindgenName) {
  if (_webAudioOutputStarted) return;
  _webAudioOutputStarted = true;
  _jsEval(_buildWebAudioBootstrapJs(wasmBindgenName).toJS);
}

String _buildWebAudioBootstrapJs(String wasmBindgenName) => '''
(function() {
  if (window.__miniaudioWebAudioStarted) return;
  window.__miniaudioWebAudioStarted = true;

  let audioCtx = null;
  let scriptNode = null;
  let workletNode = null;
  let workletInitPromise = null;
  let workletInitError = null;
  let statsTimer = null;

  function setBackendState(name) {
    window.__miniaudioAudioBackend = name;
    if (typeof document !== "undefined" && document.documentElement) {
      document.documentElement.setAttribute("data-miniaudio-audio-backend", name);
    }
  }
  setBackendState("initializing");

  const AudioCtx = window.AudioContext || window.webkitAudioContext;

  const WORKLET_PROCESSOR_SOURCE = [
    'class MiniaudioRingProcessor extends AudioWorkletProcessor {',
    '  constructor() {',
    '    super();',
    '    this.memObj = null;',
    '    this.sab = null;',
    '    this.cachedBuf = null;',
    '    this.ctrlI32 = null;',
    '    this.dataF32 = null;',
    '    this.ctrlPtr = 0;',
    '    this.dataPtr = 0;',
    '    this.capSamples = 0;',
    '    this.mask = 0;',
    '    this.ready = false;',
    '    this.port.onmessage = (ev) => {',
    '      const d = ev.data;',
    '      if (!d || d.type !== "init") return;',
    '      this.memObj = d.memory || null;',
    '      this.sab = d.buffer || (this.memObj ? this.memObj.buffer : null);',
    '      this.ctrlPtr = d.ctrlPtr >>> 0;',
    '      this.dataPtr = d.dataPtr >>> 0;',
    '      this.capSamples = d.capSamples >>> 0;',
    '      this.mask = (this.capSamples - 1) >>> 0;',
    '      this.cachedBuf = null;',
    '      this.ready = !!(this.sab || this.memObj) &&',
    '        this.capSamples > 0 &&',
    '        ((this.capSamples & this.mask) === 0);',
    '    };',
    '  }',
    '  _ensureViews() {',
    '    const buf = this.memObj ? this.memObj.buffer : this.sab;',
    '    if (!buf) return false;',
    '    if (buf !== this.cachedBuf) {',
    '      this.cachedBuf = buf;',
    '      this.ctrlI32 = new Int32Array(buf, this.ctrlPtr, 8);',
    '      this.dataF32 = new Float32Array(buf, this.dataPtr, this.capSamples);',
    '    }',
    '    return true;',
    '  }',
    '  process(inputs, outputs, parameters) {',
    '    const output = outputs[0];',
    '    if (!output || output.length === 0) return true;',
    '    const ch0 = output[0];',
    '    const ch1 = output.length > 1 ? output[1] : null;',
    '    const frames = ch0.length;',
    '    if (!this.ready || !this._ensureViews()) {',
    '      ch0.fill(0);',
    '      if (ch1) ch1.fill(0);',
    '      return true;',
    '    }',
    '    const ctrl = this.ctrlI32;',
    '    const data = this.dataF32;',
    '    const mask = this.mask;',
    '    Atomics.add(ctrl, 6, 1);',
    '    const writePos = Atomics.load(ctrl, 0) >>> 0;',
    '    const readPos = Atomics.load(ctrl, 1) >>> 0;',
    '    let avail = (writePos - readPos) >>> 0;',
    '    if (avail > this.capSamples) avail = this.capSamples;',
    '    const availFrames = avail >>> 1;',
    '    const toReadFrames = availFrames < frames ? availFrames : frames;',
    '    const toReadSamples = toReadFrames * 2;',
    '    let idx = readPos;',
    '    for (let i = 0; i < toReadFrames; i++) {',
    '      const base = idx & mask;',
    '      ch0[i] = data[base];',
    '      if (ch1) ch1[i] = data[(base + 1) & mask];',
    '      idx = (idx + 2) >>> 0;',
    '    }',
    '    if (toReadFrames < frames) {',
    '      for (let i = toReadFrames; i < frames; i++) {',
    '        ch0[i] = 0;',
    '        if (ch1) ch1[i] = 0;',
    '      }',
    '      if (Atomics.load(ctrl, 7) !== 0) {',
    '        Atomics.add(ctrl, 5, 1);',
    '      }',
    '    }',
    '    if (toReadSamples > 0) {',
    '      Atomics.store(ctrl, 1, (readPos + toReadSamples) | 0);',
    '    }',
    '    return true;',
    '  }',
    '}',
    'registerProcessor("miniaudio-ring-processor", MiniaudioRingProcessor);'
  ].join("\\n");

  function attachScriptProcessorFallback() {
    if (!audioCtx || scriptNode || workletNode) return;
    setBackendState("script-processor");
    scriptNode = audioCtx.createScriptProcessor(2048, 0, 2);
    scriptNode.onaudioprocess = function(e) {
      const ch0 = e.outputBuffer.getChannelData(0);
      const ch1 = e.outputBuffer.numberOfChannels > 1 ? e.outputBuffer.getChannelData(1) : null;
      const frames = ch0.length;
      const bindgen = window["$wasmBindgenName"];
      if (!bindgen || typeof bindgen.wasm_render_web_audio !== "function") {
        ch0.fill(0);
        if (ch1) ch1.fill(0);
        return;
      }
      try {
        const interleaved = bindgen.wasm_render_web_audio(frames);
        if (interleaved && interleaved.length >= frames * 2) {
          for (let i = 0; i < frames; i++) {
            ch0[i] = interleaved[i * 2];
            if (ch1) ch1[i] = interleaved[i * 2 + 1];
          }
        } else {
          ch0.fill(0);
          if (ch1) ch1.fill(0);
        }
      } catch (_) {
        ch0.fill(0);
        if (ch1) ch1.fill(0);
      }
    };
    scriptNode.connect(audioCtx.destination);
  }

  function initAudioWorklet(wb) {
    if (workletInitPromise || workletNode) return;
    if (!audioCtx || !audioCtx.audioWorklet || typeof AudioWorkletNode !== "function" ||
        typeof wb.wasm_get_web_audio_ring_descriptor !== "function") {
      attachScriptProcessorFallback();
      return;
    }

    const desc = wb.wasm_get_web_audio_ring_descriptor();
    const blob = new Blob([WORKLET_PROCESSOR_SOURCE], { type: "application/javascript" });
    const moduleUrl = URL.createObjectURL(blob);

    workletInitPromise = audioCtx.audioWorklet.addModule(moduleUrl).then(function() {
      URL.revokeObjectURL(moduleUrl);
      if (workletNode || !audioCtx) return;
      workletNode = new AudioWorkletNode(audioCtx, "miniaudio-ring-processor", {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [2]
      });
      const baseMsg = {
        type: "init",
        ctrlPtr: desc.ctrlPtr,
        dataPtr: desc.dataPtr,
        capSamples: desc.capSamples,
        channels: desc.channels
      };
      try {
        workletNode.port.postMessage(Object.assign({}, baseMsg, { memory: desc.memory }));
      } catch (_) {
        workletNode.port.postMessage(Object.assign({}, baseMsg, { buffer: desc.memory.buffer }));
      }
      workletNode.connect(audioCtx.destination);
      setBackendState("worklet");
      syncStatsDataset();
    }).catch(function(err) {
      URL.revokeObjectURL(moduleUrl);
      workletInitError = String(err);
      if (typeof console !== "undefined" && typeof console.warn === "function") {
        console.warn("[miniaudio_player] AudioWorklet init failed, using ScriptProcessor fallback:", err);
      }
      attachScriptProcessorFallback();
      syncStatsDataset();
    });
  }

  function ensureWebAudioOutput() {
    if (!AudioCtx) return;
    const wb = window["$wasmBindgenName"];
    if (!wb || typeof wb.wasm_get_web_audio_ring_descriptor !== "function") return;
    if (!audioCtx) {
      let targetSr = 44100;
      if (typeof wb.wasm_get_sample_rate === "function") {
        const sr = wb.wasm_get_sample_rate();
        if (sr >= 8000 && sr <= 192000) targetSr = sr;
      }
      try {
        audioCtx = new AudioCtx({ sampleRate: targetSr, latencyHint: "playback" });
      } catch (_) {
        audioCtx = new AudioCtx();
      }
      if (typeof wb.wasm_set_web_audio_sample_rate === "function") {
        wb.wasm_set_web_audio_sample_rate(audioCtx.sampleRate || targetSr);
      }
      if (typeof audioCtx.addEventListener === "function") {
        audioCtx.addEventListener("statechange", syncStatsDataset);
      }
    }
    initAudioWorklet(wb);
  }

  function unlockAudio() {
    ensureWebAudioOutput();
    if (audioCtx && audioCtx.state === "suspended") {
      audioCtx.resume().then(syncStatsDataset).catch(function() {});
    }
    scheduleStatsSync();
  }

  window.__miniaudioDebugAudioStats = function() {
    const wb = window["$wasmBindgenName"];
    return {
      backend: window.__miniaudioAudioBackend,
      state: audioCtx ? audioCtx.state : "none",
      sampleRate: audioCtx ? audioCtx.sampleRate : 0,
      baseLatency: audioCtx && typeof audioCtx.baseLatency === "number" ? audioCtx.baseLatency : null,
      outputLatency: audioCtx && typeof audioCtx.outputLatency === "number" ? audioCtx.outputLatency : null,
      queuedFrames: wb && typeof wb.wasm_get_web_audio_queued_frames === "function" ? wb.wasm_get_web_audio_queued_frames() : -1,
      underruns: wb && typeof wb.wasm_get_web_audio_underruns === "function" ? wb.wasm_get_web_audio_underruns() : -1,
      framesConsumed: wb && typeof wb.wasm_get_web_audio_frames_consumed === "function" ? wb.wasm_get_web_audio_frames_consumed() : -1,
      crossOriginIsolated: Boolean(window.crossOriginIsolated),
      workletInitError: workletInitError
    };
  };

  function syncStatsDataset() {
    if (typeof document !== "undefined" && document.documentElement) {
      try {
        document.documentElement.setAttribute(
          "data-miniaudio-audio-stats",
          JSON.stringify(window.__miniaudioDebugAudioStats())
        );
      } catch (_) {}
    }
  }

  function scheduleStatsSync() {
    syncStatsDataset();
    if (statsTimer) clearTimeout(statsTimer);
    statsTimer = setTimeout(syncStatsDataset, 400);
  }

  ensureWebAudioOutput();
  syncStatsDataset();

  if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
    window.addEventListener("pointerdown", unlockAudio, { capture: true, passive: true });
    window.addEventListener("click", unlockAudio, { capture: true, passive: true });
    window.addEventListener("keydown", unlockAudio, { capture: true, passive: true });
    window.addEventListener("wheel", scheduleStatsSync, { capture: true, passive: true });
  }
})();
''';

bool _isCrossOriginIsolated() {
  try {
    return _jsCrossOriginIsolated ?? false;
  } catch (_) {
    return false;
  }
}

@JS('crossOriginIsolated')
external bool? get _jsCrossOriginIsolated;

@JS('eval')
external JSAny? _jsEval(JSString code);

@JS('fetch')
external JSPromise<_FetchResponse> _jsFetch(JSString url);

extension type _FetchResponse._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external _FetchHeaders get headers;
}

extension type _FetchHeaders._(JSObject _) implements JSObject {
  external JSString? get(JSString name);
}
