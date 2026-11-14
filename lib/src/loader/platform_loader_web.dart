import 'dart:js_interop';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../rust/frb_generated.dart';

/// Indicates whether the current runtime is targeting WebAssembly / JavaScript.
const bool kIsWeb = true;

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
  const defaultConfig = RustLib.kDefaultExternalLibraryLoaderConfig;
  final stem = defaultConfig.stem;

  for (final prefix in _candidateWebPrefixes) {
    final jsPath = '$prefix$stem.js';
    final wasmPath = '$prefix${stem}_bg.wasm';
    if (await _isWasmJsServed(jsPath)) {
      final library = await loadExternalLibrary(
        ExternalLibraryLoaderConfig(
          stem: stem,
          ioDirectory: defaultConfig.ioDirectory,
          webPrefix: prefix,
          wasmBindgenName: defaultConfig.wasmBindgenName,
        ),
      );
      _ensureWebAudioRuntimeStarted(
        defaultConfig.wasmBindgenName,
        jsPath,
        wasmPath,
      );
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

Future<bool> _isWasmJsServed(String url) async {
  try {
    final response = await _jsFetch(url.toJS).toDart;
    final contentType =
        response.headers.get('content-type'.toJS)?.toDart.toLowerCase() ?? '';
    return response.ok && !contentType.contains('text/html');
  } catch (_) {
    // If CSP blocks fetch(), allow the default prefix to attempt script loading.
    return url.startsWith('pkg/');
  }
}

/// No-op on Web (isolate finalizers only apply to native FFI isolates).
void registerIsolateWithLibrary(ExternalLibrary library) {}

/// Legacy helper kept for API compatibility; on Web, audio sources are fetched
/// directly inside the Dedicated Web Workers (`audioWorker` / `analyzerWorker`)
/// so the main UI thread never blocks or copies large buffers.
Future<Uint8List?> resolveWebSourceBytes(
  String? uri, {
  Map<String, String>? headers,
}) async =>
    null;

void _ensureWebAudioRuntimeStarted(
  String bindgenName,
  String jsPath,
  String wasmPath,
) {
  try {
    _jsEval(_buildWebAudioBootstrapJs(bindgenName, jsPath, wasmPath).toJS);
  } catch (_) {}
}

String _buildWebAudioBootstrapJs(
  String bindgenName,
  String jsPath,
  String wasmPath,
) =>
    _kWebAudioBootstrapTemplate
        .replaceAll('__BINDGEN_NAME__', bindgenName)
        .replaceAll('__JS_PATH__', jsPath)
        .replaceAll('__WASM_PATH__', wasmPath);

const String _kWebAudioBootstrapTemplate = r'''
(function() {
  if (globalThis.__miniaudioWebRuntimeStarted) return;
  globalThis.__miniaudioWebRuntimeStarted = true;

  const bindgenName = "__BINDGEN_NAME__";
  const baseUrl = (typeof window !== "undefined" && window.location)
    ? new URL(".", window.location.href).href
    : "";
  const absJsUrl = new URL("__JS_PATH__", baseUrl).href;
  const absWasmUrl = new URL("__WASM_PATH__", baseUrl).href;

  function getMainBindgen() {
    return globalThis[bindgenName] || (typeof wasm_bindgen !== "undefined" ? wasm_bindgen : null);
  }

  const mainBindgen = getMainBindgen();
  if (!mainBindgen) return;

  // Dedicated MessageChannel linking audioWorker <-> AudioWorkletProcessor directly
  // so decoded PCM Float32 frames never pass through the main UI thread.
  const audioChannel = new MessageChannel();

  function miniaudioWorkerMain() {
    let bindgen = null;
    let origPrimary = null;
    let origSync = null;
    let origArcInc = null;
    let origArcDec = null;
    let baseUrl = "";
    let isAudioWorker = false;
    let audioPort = null;
    let workletBufferedFrames = 0;
    let lastWorkletStatMs = 0;
    let ready = false;
    const queue = [];
    let processing = false;
    const playerPtrMap = new Map();
    let latestWorkerPlayerPtr = 0;
    const icyCache = new Map();
    const icyInflight = new Map();
    const knownIcyUrls = new Set();

    function encodeAssetSegments(rawPath) {
      return rawPath.split("/").map(function(seg) {
        if (!seg) return "";
        try {
          return encodeURIComponent(decodeURIComponent(seg));
        } catch (_) {
          return encodeURIComponent(seg);
        }
      }).join("/");
    }

    function xhrFetchSync(url, headers) {
      try {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", url, false);
        xhr.responseType = "arraybuffer";
        if (Array.isArray(headers)) {
          for (let i = 0; i < headers.length; i++) {
            const pair = headers[i];
            if (Array.isArray(pair) && pair.length >= 2) {
              try { xhr.setRequestHeader(String(pair[0]), String(pair[1])); } catch (_) {}
            }
          }
        }
        xhr.send(null);
        if (xhr.status >= 200 && xhr.status < 300 && xhr.response) {
          const ct = (xhr.getResponseHeader("content-type") || "").toLowerCase();
          if (ct.indexOf("text/html") !== -1) return null;
          const u8 = new Uint8Array(xhr.response);
          if (u8.byteLength > 0) return u8;
        }
      } catch (_) {}
      return null;
    }

    async function prefetchIcyStream(icyUrl) {
      if (icyInflight.has(icyUrl)) {
        return icyInflight.get(icyUrl);
      }
      const p = (async function() {
        const httpUrl = "https://" + icyUrl.substring(6);
        const urls = [httpUrl, "http://" + icyUrl.substring(6)];
        for (let u = 0; u < urls.length; u++) {
          const ctrl = new AbortController();
          const timer = setTimeout(function() { try { ctrl.abort(); } catch (_) {} }, 2200);
          try {
            const res = await fetch(urls[u], { signal: ctrl.signal });
            if (res.ok && res.body) {
              const reader = res.body.getReader();
              const chunks = [];
              let total = 0;
              while (total < 163840) {
                const step = await reader.read();
                if (step.done) break;
                if (step.value && step.value.byteLength > 0) {
                  chunks.push(step.value);
                  total += step.value.byteLength;
                }
              }
              try { ctrl.abort(); } catch (_) {}
              clearTimeout(timer);
              if (total > 0) {
                const merged = new Uint8Array(total);
                let off = 0;
                for (let c = 0; c < chunks.length; c++) {
                  merged.set(chunks[c], off);
                  off += chunks[c].byteLength;
                }
                icyCache.set(icyUrl, merged);
                return merged;
              }
            }
          } catch (_) {
            clearTimeout(timer);
          }
        }
        return null;
      })();
      icyInflight.set(icyUrl, p);
      try {
        return await p;
      } finally {
        icyInflight.delete(icyUrl);
      }
    }

    function extractIcyUrls(u8) {
      try {
        const text = new TextDecoder("utf-8", { fatal: false }).decode(u8);
        if (text.indexOf("icy://") === -1) return [];
        const matches = text.match(/icy:\/\/[A-Za-z0-9_.~:/?#\[\]@!$&'()*+,;=%-]+/g);
        return matches || [];
      } catch (_) {
        return [];
      }
    }

    self.__miniaudioFetchBytesSync = function(source, headers) {
      if (!source || typeof source !== "string") return -5;
      const trimmed = source.trim();
      if (!trimmed) return -5;
      const lower = trimmed.toLowerCase();

      if (lower.indexOf("icy://") === 0) {
        const cached = icyCache.get(trimmed);
        if (cached && cached.byteLength > 0) return cached;
        for (const [k, v] of icyCache.entries()) {
          if (k.toLowerCase() === lower && v && v.byteLength > 0) return v;
        }
        return -4;
      }

      if (lower.indexOf("asset://") === 0 || lower.indexOf("asset:") === 0) {
        let rawPath = lower.indexOf("asset://") === 0
          ? trimmed.substring(8)
          : trimmed.substring(6);
        while (rawPath.charAt(0) === "/") rawPath = rawPath.substring(1);
        const encoded = encodeAssetSegments(rawPath);
        const doubleEncoded = encoded.replace(/%/g, "%25");
        const candidates = [];
        if (doubleEncoded !== encoded) {
          candidates.push(new URL("assets/" + doubleEncoded, baseUrl).href);
        }
        candidates.push(new URL("assets/" + encoded, baseUrl).href);
        if (doubleEncoded !== encoded) {
          candidates.push(new URL(doubleEncoded, baseUrl).href);
        }
        candidates.push(new URL(encoded, baseUrl).href);
        for (let i = 0; i < candidates.length; i++) {
          const bytes = xhrFetchSync(candidates[i], headers);
          if (bytes) return bytes;
        }
        return -5;
      }

      if (lower.indexOf("http://") === 0 || lower.indexOf("https://") === 0 || lower.indexOf("blob:") === 0) {
        const bytes = xhrFetchSync(trimmed, headers);
        return bytes ? bytes : -4;
      }

      let clean = trimmed;
      while (clean.charAt(0) === "/") clean = clean.substring(1);
      const encoded = encodeAssetSegments(clean);
      const doubleEncoded = encoded.replace(/%/g, "%25");
      const fallbackCandidates = [];
      if (doubleEncoded !== encoded) {
        fallbackCandidates.push(new URL("assets/" + doubleEncoded, baseUrl).href);
      }
      fallbackCandidates.push(new URL("assets/" + encoded, baseUrl).href);
      if (doubleEncoded !== encoded) {
        fallbackCandidates.push(new URL(doubleEncoded, baseUrl).href);
      }
      fallbackCandidates.push(new URL(encoded, baseUrl).href);
      for (let i = 0; i < fallbackCandidates.length; i++) {
        const bytes = xhrFetchSync(fallbackCandidates[i], headers);
        if (bytes) return bytes;
      }
      return -5;
    };

    function isPlayerInstanceMethod(funcId) {
      if (funcId < 5 || funcId > 72) return false;
      return funcId !== 12 && funcId !== 14 && funcId !== 15 &&
             funcId !== 17 && funcId !== 18 && funcId !== 20;
    }

    function patchPlayerPtrInSse(u8, funcId) {
      if (!isPlayerInstanceMethod(funcId) || u8.byteLength < 8) return;
      const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
      const mainPtr = dv.getUint32(0, true) >>> 0;
      const workerPtr = playerPtrMap.get(mainPtr) || latestWorkerPlayerPtr;
      if (workerPtr) {
        dv.setUint32(0, workerPtr >>> 0, true);
        dv.setUint32(4, 0, true);
      }
    }

    function clearWorkletBuffer() {
      workletBufferedFrames = 0;
      if (audioPort) {
        try { audioPort.postMessage({ type: "clear" }); } catch (_) {}
      }
    }

    function pumpAudio() {
      if (!ready || !isAudioWorker || !bindgen) return;
      if (typeof bindgen.wasm_worker_has_active_work !== "function") return;
      if (!bindgen.wasm_worker_has_active_work()) return;

      const now = Date.now();
      const workletActive = audioPort && (now - lastWorkletStatMs < 180);

      if (workletActive) {
        let loops = 0;
        while (workletBufferedFrames < 6144 && loops < 4) {
          const chunk = bindgen.wasm_worker_pump_quantum(1024);
          if (!chunk || chunk.length === 0) break;
          const out = new Float32Array(chunk);
          const frames = (out.length / 2) | 0;
          workletBufferedFrames += frames;
          audioPort.postMessage({ type: "pcm", samples: out }, [out.buffer]);
          loops++;
        }
      } else {
        bindgen.wasm_worker_pump_quantum(1024);
      }
    }

    async function processQueue() {
      if (processing || !ready) return;
      processing = true;
      while (queue.length > 0) {
        const msg = queue.shift();
        try {
          if (msg.type === "sync") {
            const u8 = new Uint8Array(msg.bytes);
            patchPlayerPtrInSse(u8, msg.funcId);
            const ret = origSync(msg.funcId, u8, msg.rustVecLen, msg.dataLen);
            if (msg.funcId === 20 && ret && ret.byteLength >= 9 && ret[0] === 0) {
              const dv = new DataView(ret.buffer, ret.byteOffset, ret.byteLength);
              const workerPtr = dv.getUint32(1, true) >>> 0;
              if (workerPtr) {
                latestWorkerPlayerPtr = workerPtr;
                if (msg.mainPtr) {
                  playerPtrMap.set(msg.mainPtr >>> 0, workerPtr);
                }
              }
            }
          } else if (msg.type === "arc_inc") {
            const wPtr = playerPtrMap.get(msg.ptr >>> 0) || latestWorkerPlayerPtr || msg.ptr;
            origArcInc(wPtr);
          } else if (msg.type === "arc_dec") {
            const wPtr = playerPtrMap.get(msg.ptr >>> 0) || latestWorkerPlayerPtr || msg.ptr;
            origArcDec(wPtr);
          } else if (msg.type === "primary") {
            const u8 = new Uint8Array(msg.bytes);
            const icyUrls = extractIcyUrls(u8);
            for (let i = 0; i < icyUrls.length; i++) {
              knownIcyUrls.add(icyUrls[i]);
              if (!icyCache.has(icyUrls[i])) {
                prefetchIcyStream(icyUrls[i]);
              }
            }
            if (msg.funcId === 73 && icyUrls.length > 0) {
              for (let i = 0; i < icyUrls.length; i++) {
                if (!icyCache.has(icyUrls[i])) {
                  await prefetchIcyStream(icyUrls[i]);
                }
              }
            } else if ((msg.funcId === 23 || msg.funcId === 21 || msg.funcId === 25) && knownIcyUrls.size > 0) {
              for (const u of knownIcyUrls) {
                if (icyInflight.has(u) && !icyCache.has(u)) {
                  await prefetchIcyStream(u);
                }
              }
            }

            if (msg.funcId === 22 || msg.funcId === 68 || msg.funcId === 32 ||
                msg.funcId === 21 || msg.funcId === 25 || msg.funcId === 23) {
              clearWorkletBuffer();
            }

            patchPlayerPtrInSse(u8, msg.funcId);
            origPrimary(msg.funcId, msg.port, u8, msg.rustVecLen, msg.dataLen);

            if (isAudioWorker && (msg.funcId === 23 || msg.funcId === 32 || msg.funcId === 21 || msg.funcId === 25)) {
              pumpAudio();
            }
          }
        } catch (err) {
          console.error("[miniaudio_player worker]", err);
        }
      }
      processing = false;
    }

    self.onmessage = async function(e) {
      const msg = e.data;
      if (msg.type === "init") {
        baseUrl = msg.baseUrl;
        isAudioWorker = !!msg.isAudioWorker;
        if (msg.audioPort) {
          audioPort = msg.audioPort;
          audioPort.onmessage = function(ev) {
            if (ev.data && ev.data.type === "stat") {
              workletBufferedFrames = ev.data.buffered | 0;
              lastWorkletStatMs = Date.now();
              if (workletBufferedFrames < 4096) {
                pumpAudio();
              }
            }
          };
        }
        importScripts(msg.jsUrl);
        if (typeof wasm_bindgen !== "undefined") {
          self.wasm_bindgen = wasm_bindgen;
          self[msg.bindgenName] = wasm_bindgen;
        }
        bindgen = self[msg.bindgenName] || self.wasm_bindgen || (typeof wasm_bindgen !== "undefined" ? wasm_bindgen : null);
        await bindgen(msg.wasmUrl);
        origPrimary = bindgen.frb_pde_ffi_dispatcher_primary.bind(bindgen);
        origSync = bindgen.frb_pde_ffi_dispatcher_sync.bind(bindgen);
        origArcInc = bindgen.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustMiniaudioPlayer.bind(bindgen);
        origArcDec = bindgen.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustMiniaudioPlayer.bind(bindgen);
        ready = true;
        await processQueue();
        if (isAudioWorker) {
          setInterval(pumpAudio, 12);
        }
        return;
      }
      queue.push(msg);
      processQueue();
    };
  }

  const workerBlob = new Blob(["(" + miniaudioWorkerMain.toString() + ")()"], {
    type: "application/javascript"
  });
  const workerUrl = URL.createObjectURL(workerBlob);
  const audioWorker = new Worker(workerUrl);
  const analyzerWorker = new Worker(workerUrl);

  audioWorker.postMessage({
    type: "init",
    jsUrl: absJsUrl,
    wasmUrl: absWasmUrl,
    bindgenName: bindgenName,
    baseUrl: baseUrl,
    isAudioWorker: true,
    audioPort: audioChannel.port1
  }, [audioChannel.port1]);

  analyzerWorker.postMessage({
    type: "init",
    jsUrl: absJsUrl,
    wasmUrl: absWasmUrl,
    bindgenName: bindgenName,
    baseUrl: baseUrl,
    isAudioWorker: false
  });

  // Intercept mainBindgen so all async operations execute on Dedicated Web Workers.
  const origMainSync = mainBindgen.frb_pde_ffi_dispatcher_sync.bind(mainBindgen);
  const origMainArcInc = mainBindgen.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustMiniaudioPlayer.bind(mainBindgen);
  const origMainArcDec = mainBindgen.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustMiniaudioPlayer.bind(mainBindgen);

  function copySseBytes(ptr, len) {
    if (ptr instanceof Uint8Array) {
      return ptr.slice(0, len >= 0 ? len : ptr.byteLength);
    }
    if (ArrayBuffer.isView(ptr)) {
      return new Uint8Array(ptr.buffer, ptr.byteOffset, len >= 0 ? len : ptr.byteLength).slice();
    }
    return new Uint8Array(0);
  }

  mainBindgen.frb_pde_ffi_dispatcher_sync = function(func_id, ptr_, rust_vec_len_, data_len_) {
    const copy = copySseBytes(ptr_, data_len_);
    const ret = origMainSync(func_id, ptr_, rust_vec_len_, data_len_);
    let mainPtr = 0;
    if (func_id === 20 && ret && ret.byteLength >= 9 && ret[0] === 0) {
      const dv = new DataView(ret.buffer, ret.byteOffset, ret.byteLength);
      mainPtr = dv.getUint32(1, true) >>> 0;
    }
    audioWorker.postMessage({
      type: "sync",
      funcId: func_id,
      bytes: copy.buffer,
      rustVecLen: rust_vec_len_,
      dataLen: data_len_,
      mainPtr: mainPtr
    }, [copy.buffer]);
    return ret;
  };

  mainBindgen.rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustMiniaudioPlayer = function(ptr) {
    origMainArcInc(ptr);
    audioWorker.postMessage({ type: "arc_inc", ptr: ptr >>> 0 });
  };

  mainBindgen.rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRustMiniaudioPlayer = function(ptr) {
    origMainArcDec(ptr);
    audioWorker.postMessage({ type: "arc_dec", ptr: ptr >>> 0 });
  };

  mainBindgen.frb_pde_ffi_dispatcher_primary = function(func_id, port_, ptr_, rust_vec_len_, data_len_) {
    if (func_id === 23 || func_id === 24) {
      unlockAudio();
    }
    const copy = copySseBytes(ptr_, data_len_);
    const targetWorker = (func_id === 73) ? analyzerWorker : audioWorker;
    const transfer = [copy.buffer];
    let workerPort = port_;
    if (typeof MessagePort !== "undefined" && port_ instanceof MessagePort) {
      transfer.push(port_);
    } else if (port_ && typeof port_.postMessage === "function") {
      const mc = new MessageChannel();
      mc.port1.onmessage = function(ev) {
        try { port_.postMessage(ev.data); } catch (_) {}
      };
      workerPort = mc.port2;
      transfer.push(mc.port2);
    }
    targetWorker.postMessage({
      type: "primary",
      funcId: func_id,
      port: workerPort,
      bytes: copy.buffer,
      rustVecLen: rust_vec_len_,
      dataLen: data_len_
    }, transfer);
  };

  let audioCtx = null;
  let audioPortTransferred = false;

  const workletCode = [
    "class MiniaudioWorkletProcessor extends AudioWorkletProcessor {",
    "  constructor() {",
    "    super();",
    "    this.cap = 32768;",
    "    this.left = new Float32Array(this.cap);",
    "    this.right = new Float32Array(this.cap);",
    "    this.readPos = 0;",
    "    this.writePos = 0;",
    "    this.avail = 0;",
    "    this.workerPort = null;",
    "    this.framesSinceStat = 0;",
    "    this.port.onmessage = (e) => {",
    "      if (e.data && e.data.type === 'init_port') {",
    "        this.workerPort = e.data.port;",
    "        this.workerPort.onmessage = (ev) => this.onWorkerMsg(ev.data);",
    "        this.workerPort.postMessage({ type: 'stat', buffered: this.avail });",
    "      }",
    "    };",
    "  }",
    "  onWorkerMsg(data) {",
    "    if (!data) return;",
    "    if (data.type === 'clear') {",
    "      this.readPos = 0;",
    "      this.writePos = 0;",
    "      this.avail = 0;",
    "      if (this.workerPort) {",
    "        this.workerPort.postMessage({ type: 'stat', buffered: 0 });",
    "      }",
    "      return;",
    "    }",
    "    if (data.type === 'pcm' && data.samples) {",
    "      const s = data.samples;",
    "      const frames = (s.length / 2) | 0;",
    "      for (let i = 0; i < frames; i++) {",
    "        if (this.avail < this.cap) {",
    "          this.left[this.writePos] = s[i * 2];",
    "          this.right[this.writePos] = s[i * 2 + 1];",
    "          this.writePos = (this.writePos + 1) & (this.cap - 1);",
    "          this.avail++;",
    "        }",
    "      }",
    "    }",
    "  }",
    "  process(inputs, outputs) {",
    "    const out = outputs[0];",
    "    if (!out || out.length === 0) return true;",
    "    const ch0 = out[0];",
    "    const ch1 = out.length > 1 ? out[1] : null;",
    "    const n = ch0.length;",
    "    for (let i = 0; i < n; i++) {",
    "      if (this.avail > 0) {",
    "        ch0[i] = this.left[this.readPos];",
    "        if (ch1) ch1[i] = this.right[this.readPos];",
    "        this.readPos = (this.readPos + 1) & (this.cap - 1);",
    "        this.avail--;",
    "      } else {",
    "        ch0[i] = 0;",
    "        if (ch1) ch1[i] = 0;",
    "      }",
    "    }",
    "    this.framesSinceStat += n;",
    "    if (this.workerPort && this.framesSinceStat >= 512) {",
    "      this.framesSinceStat = 0;",
    "      this.workerPort.postMessage({ type: 'stat', buffered: this.avail });",
    "    }",
    "    return true;",
    "  }",
    "}",
    "registerProcessor('miniaudio-worklet-processor', MiniaudioWorkletProcessor);"
  ].join("\n");

  async function ensureWebAudioOutput() {
    if (audioCtx || typeof window === "undefined") return;
    const AudioCtx = window.AudioContext || window.webkitAudioContext;
    if (!AudioCtx) return;
    try {
      audioCtx = new AudioCtx({ sampleRate: 44100, latencyHint: "interactive" });
    } catch (_) {
      try { audioCtx = new AudioCtx(); } catch (_) { return; }
    }

    if (audioCtx.audioWorklet && typeof AudioWorkletNode !== "undefined") {
      try {
        const wBlob = new Blob([workletCode], { type: "application/javascript" });
        const wUrl = URL.createObjectURL(wBlob);
        await audioCtx.audioWorklet.addModule(wUrl);
        const workletNode = new AudioWorkletNode(audioCtx, "miniaudio-worklet-processor", {
          numberOfInputs: 0,
          numberOfOutputs: 1,
          outputChannelCount: [2]
        });
        workletNode.connect(audioCtx.destination);
        if (!audioPortTransferred) {
          audioPortTransferred = true;
          workletNode.port.postMessage({ type: "init_port", port: audioChannel.port2 }, [audioChannel.port2]);
        }
        return;
      } catch (err) {
        console.warn("[miniaudio_player] AudioWorklet fallback to ScriptProcessorNode:", err);
      }
    }

    if (!audioPortTransferred) {
      audioPortTransferred = true;
      const cap = 32768;
      const leftBuf = new Float32Array(cap);
      const rightBuf = new Float32Array(cap);
      let readPos = 0;
      let writePos = 0;
      let avail = 0;
      audioChannel.port2.onmessage = function(ev) {
        const data = ev.data;
        if (!data) return;
        if (data.type === "clear") {
          readPos = 0; writePos = 0; avail = 0;
          audioChannel.port2.postMessage({ type: "stat", buffered: 0 });
          return;
        }
        if (data.type === "pcm" && data.samples) {
          const s = data.samples;
          const frames = (s.length / 2) | 0;
          for (let i = 0; i < frames; i++) {
            if (avail < cap) {
              leftBuf[writePos] = s[i * 2];
              rightBuf[writePos] = s[i * 2 + 1];
              writePos = (writePos + 1) & (cap - 1);
              avail++;
            }
          }
        }
      };
      const scriptNode = audioCtx.createScriptProcessor(2048, 0, 2);
      scriptNode.onaudioprocess = function(e) {
        const ch0 = e.outputBuffer.getChannelData(0);
        const ch1 = e.outputBuffer.numberOfChannels > 1 ? e.outputBuffer.getChannelData(1) : null;
        for (let i = 0; i < ch0.length; i++) {
          if (avail > 0) {
            ch0[i] = leftBuf[readPos];
            if (ch1) ch1[i] = rightBuf[readPos];
            readPos = (readPos + 1) & (cap - 1);
            avail--;
          } else {
            ch0[i] = 0;
            if (ch1) ch1[i] = 0;
          }
        }
        audioChannel.port2.postMessage({ type: "stat", buffered: avail });
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

@JS('eval')
external JSAny? _jsEval(JSString code);

@JS('fetch')
external JSPromise<_FetchResponse> _jsFetch(JSString url);

extension type _FetchResponse._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external _FetchHeaders get headers;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _FetchHeaders._(JSObject _) implements JSObject {
  external JSString? get(JSString name);
}
