import 'dart:js_interop';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../rust/frb_generated.dart';

/// Candidate prefixes where `miniaudio_player.js` and `miniaudio_player_bg.wasm`
/// may be served from on Web:
/// 1. `assets/packages/miniaudio_player/web/pkg/` — served automatically by
///    Flutter Web (`flutter build web` and `flutter run -d chrome`) via the
///    `flutter: assets:` declaration in `pubspec.yaml`.
/// 2. `packages/miniaudio_player/web/pkg/` — Dart DWDS dev server package route.
/// 3. `pkg/` — standard `web/pkg/` directory provisioned by `hook/build.dart`.
const _candidateWebPrefixes = <String>[
  'assets/packages/miniaudio_player/web/pkg/',
  'packages/miniaudio_player/web/pkg/',
  'pkg/',
];

/// Resolves and loads the WebAssembly `miniaudio_player` bundle across Flutter
/// Web (`assets/packages/...`), DWDS (`packages/...`), and `web/pkg/`.
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
    'Ensure `flutter build web` bundled the package assets or that `web/pkg/` '
    'contains `$stem.js` and `${stem}_bg.wasm`.',
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
  const AudioCtx = window.AudioContext || window.webkitAudioContext;

  function ensureWebAudioOutput() {
    if (!AudioCtx) return;
    const wb = window["$wasmBindgenName"];
    if (!wb || typeof wb.wasm_render_web_audio !== "function") return;
    if (!audioCtx) {
      let targetSr = 44100;
      if (typeof wb.wasm_get_sample_rate === "function") {
        const sr = wb.wasm_get_sample_rate();
        if (sr >= 8000 && sr <= 192000) targetSr = sr;
      }
      try {
        audioCtx = new AudioCtx({ sampleRate: targetSr, latencyHint: "interactive" });
      } catch (_) {
        audioCtx = new AudioCtx();
      }
      const scriptNode = audioCtx.createScriptProcessor(2048, 0, 2);
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
  }

  function unlockAudio() {
    ensureWebAudioOutput();
    if (audioCtx && audioCtx.state === "suspended") {
      audioCtx.resume().catch(function() {});
    }
  }

  ensureWebAudioOutput();

  if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
    window.addEventListener("pointerdown", unlockAudio, { passive: true });
    window.addEventListener("click", unlockAudio, { passive: true });
    window.addEventListener("keydown", unlockAudio, { passive: true });
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
