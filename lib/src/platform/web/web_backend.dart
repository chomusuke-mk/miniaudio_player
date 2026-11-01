import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_web.dart';

import '../../api/audio_analysis_result.dart';
import '../../rust/frb_generated.dart';
import '../platform_backend.dart';

@JS('eval')
external JSAny? _jsEval(JSString code);

extension type _JsFunction(JSObject _) implements JSObject {
  @JS('call')
  external JSPromise invoke(
    JSAny? thisArg,
    JSString bindgenName,
    JSString scriptUrl,
    JSString wasmUrl,
  );
}

/// Private coordinator that initializes the `flutter_rust_bridge` WebAssembly module
/// inside a Dedicated Web Worker communicating exclusively via `postMessage`
/// (`MessagePort` and `BroadcastChannel`), without `SharedArrayBuffer`,
/// `COOP`/`COEP` server headers, or `setTimeout`.
abstract final class _WebWorkerLoader {
  static Future<void>? _initFuture;

  static Future<void> ensureInitialized() async {
    if (RustLib.instance.initialized) return;
    await (_initFuture ??= _init());
  }

  static Future<void> _init() async {
    const config = RustLib.kDefaultExternalLibraryLoaderConfig;
    final root = '${config.webPrefix}${config.stem}';
    final bindgenName = config.wasmBindgenName;

    final scriptUrl = _resolveAssetUrl('$root.js');
    final wasmUrl = _resolveAssetUrl('${root}_bg.wasm');

    final bootstrapFn = _jsEval(_workerBootstrapJs.toJS) as JSObject;
    await _JsFunction(bootstrapFn)
        .invoke(null, bindgenName.toJS, scriptUrl.toJS, wasmUrl.toJS)
        .toDart;

    final dynamic extLib = ExternalLibrary(
      debugInfo: 'moduleRoot=$root (dedicated web worker, message-passing)',
      wasmBindgenName: bindgenName,
    );
    await RustLib.init(externalLibrary: extLib);
  }

  static String _resolveAssetUrl(String relativePath) {
    try {
      return Uri.base.resolve(relativePath).toString();
    } catch (_) {
      return relativePath;
    }
  }

  static const String _workerBootstrapJs = r'''
(async function(bindgenName, scriptUrl, wasmUrl) {
  if (globalThis.__miniaudioWorkerInitialized) {
    return;
  }

  if (typeof globalThis[bindgenName] === 'undefined') {
    if (typeof document !== 'undefined' && document.head) {
      await new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = scriptUrl;
        s.onload = resolve;
        s.onerror = () => reject(new Error('Failed to load ' + scriptUrl));
        document.head.appendChild(s);
      });
    }
    try {
      globalThis[bindgenName] = eval(bindgenName);
    } catch (_) {}
  }

  const hostBindgen = globalThis[bindgenName];
  await hostBindgen(wasmUrl);

  if (typeof Worker === 'undefined' || typeof Blob === 'undefined' || typeof URL === 'undefined' || typeof URL.createObjectURL !== 'function') {
    globalThis.__miniaudioWorkerInitialized = true;
    return;
  }

  const workerCode = `
    importScripts(${JSON.stringify(scriptUrl)});
    let wasm = null;

    function pumpQuantum(frames) {
      if (!wasm || typeof wasm.wasm_worker_has_active_work !== 'function') return;
      if (!wasm.wasm_worker_has_active_work()) return;
      const pcm = wasm.wasm_worker_pump_quantum(frames);
      if (pcm && pcm.length > 0) {
        const copy = new Float32Array(pcm);
        self.postMessage({ type: 'pcm', samples: copy }, [copy.buffer]);
      }
    }

    function prefillIfActive() {
      if (!wasm || typeof wasm.wasm_worker_has_active_work !== 'function') return;
      for (let i = 0; i < 4; i++) {
        if (!wasm.wasm_worker_has_active_work()) break;
        pumpQuantum(1024);
      }
    }

    self.onmessage = async (event) => {
      const msg = event.data;
      if (!msg) return;

      if (msg.type === 'init') {
        try {
          const fn = self[${JSON.stringify(bindgenName)}] || eval(${JSON.stringify(bindgenName)});
          await fn(msg.wasmUrl);
          wasm = fn;
          self.postMessage({ type: 'ready' });
        } catch (err) {
          self.postMessage({ type: 'error', error: String(err) });
        }
        return;
      }

      if (!wasm) return;

      if (msg.type === 'primary') {
        wasm.frb_pde_ffi_dispatcher_primary(
          msg.funcId,
          msg.port,
          msg.bytes,
          msg.rustVecLen,
          msg.dataLen
        );
        prefillIfActive();
      } else if (msg.type === 'sync') {
        wasm.frb_pde_ffi_dispatcher_sync(
          msg.funcId,
          msg.bytes,
          msg.rustVecLen,
          msg.dataLen
        );
        prefillIfActive();
      } else if (msg.type === 'arc') {
        if (typeof wasm[msg.fn] === 'function') {
          wasm[msg.fn](msg.ptr);
        }
      } else if (msg.type === 'pull_quantum') {
        pumpQuantum(msg.frames || 1024);
      }
    };
  `;

  const blob = new Blob([workerCode], { type: 'application/javascript' });
  const workerUrl = URL.createObjectURL(blob);
  const worker = new Worker(workerUrl);

  const pcmQueue = [];
  let audioCtx = null;
  let scriptNode = null;

  function ensureWebAudioOutput() {
    if (audioCtx || typeof window === 'undefined') return;
    const AudioCtx = window.AudioContext || window.webkitAudioContext;
    if (!AudioCtx) return;
    try {
      audioCtx = new AudioCtx();
      scriptNode = audioCtx.createScriptProcessor(1024, 0, 2);
      scriptNode.onaudioprocess = (e) => {
        const left = e.outputBuffer.getChannelData(0);
        const right = e.outputBuffer.numberOfChannels > 1 ? e.outputBuffer.getChannelData(1) : null;
        const chunk = pcmQueue.shift();
        if (pcmQueue.length < 4) {
          worker.postMessage({ type: 'pull_quantum', frames: left.length });
        }
        if (!chunk) {
          left.fill(0);
          if (right) right.fill(0);
          return;
        }
        const frames = Math.min(left.length, (chunk.length / 2) | 0);
        for (let i = 0; i < frames; i++) {
          left[i] = chunk[i * 2];
          if (right) right[i] = chunk[i * 2 + 1];
        }
        for (let i = frames; i < left.length; i++) {
          left[i] = 0;
          if (right) right[i] = 0;
        }
      };
      scriptNode.connect(audioCtx.destination);
    } catch (_) {}
  }

  await new Promise((resolve, reject) => {
    worker.onmessage = (event) => {
      const data = event.data;
      if (!data) return;
      if (data.type === 'ready') {
        resolve();
      } else if (data.type === 'error') {
        reject(new Error(data.error));
      } else if (data.type === 'pcm') {
        ensureWebAudioOutput();
        if (audioCtx && audioCtx.state === 'suspended') {
          audioCtx.resume().catch(() => {});
        }
        if (pcmQueue.length < 32) {
          pcmQueue.push(data.samples);
        }
      }
    };
    worker.onerror = (err) => reject(err);
    worker.postMessage({ type: 'init', wasmUrl: wasmUrl });
  });

  const origSync = hostBindgen.frb_pde_ffi_dispatcher_sync.bind(hostBindgen);

  hostBindgen.frb_pde_ffi_dispatcher_primary = function(funcId, port, ptr, rustVecLen, dataLen) {
    const bytes = new Uint8Array(ptr);
    worker.postMessage(
      {
        type: 'primary',
        funcId: funcId,
        port: port,
        bytes: bytes,
        rustVecLen: rustVecLen,
        dataLen: dataLen
      },
      [port, bytes.buffer]
    );
  };

  hostBindgen.frb_pde_ffi_dispatcher_sync = function(funcId, ptr, rustVecLen, dataLen) {
    const bytes = new Uint8Array(ptr);
    worker.postMessage(
      {
        type: 'sync',
        funcId: funcId,
        bytes: bytes,
        rustVecLen: rustVecLen,
        dataLen: dataLen
      },
      [bytes.buffer]
    );
    return origSync(funcId, ptr, rustVecLen, dataLen);
  };

  const arcFns = [
    'rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustEngine',
    'rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustEngine',
    'rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustPlayer',
    'rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustPlayer',
    'rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustVoicePool',
    'rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustVoicePool'
  ];

  for (const fnName of arcFns) {
    if (typeof hostBindgen[fnName] === 'function') {
      const origArc = hostBindgen[fnName].bind(hostBindgen);
      hostBindgen[fnName] = function(ptr) {
        worker.postMessage({ type: 'arc', fn: fnName, ptr: ptr });
        return origArc(ptr);
      };
    }
  }

  globalThis.__miniaudioWorkerInitialized = true;
})
''';
}

/// Ensures the `flutter_rust_bridge` WebAssembly runtime is initialized.
Future<void> ensureRustInitialized() => _WebWorkerLoader.ensureInitialized();

/// WebAssembly implementation of [PlayerBackend] bridged via `flutter_rust_bridge`.
class WebPlayerBackend extends RustBridgePlayerBackend {
  WebPlayerBackend([dynamic _]);

  @override
  Future<void> ensureRuntimeInitialized() =>
      _WebWorkerLoader.ensureInitialized();
}

/// WebAssembly implementation of [PlatformService] bridged via `flutter_rust_bridge`.
class WebPlatformService extends RustBridgePlatformService {
  @override
  Future<void> ensureRuntimeInitialized() =>
      _WebWorkerLoader.ensureInitialized();

  @override
  Future<AudioAnalysisResult> analyzeAudio(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) =>
      Future.error(
        UnsupportedError(
          'analyzeAudio(filePath) is not supported on Web; use analyzeAudioMemory(bytes).',
        ),
      );

  @override
  AudioAnalysisResult analyzeAudioSync(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) =>
      throw UnsupportedError(
        'analyzeAudioSync(filePath) is not supported on Web; use analyzeAudioMemory(bytes).',
      );
}
