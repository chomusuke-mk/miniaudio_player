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
  let workletRegistered = false;
  let statsTimer = null;
  let captureGumCalls = 0;
  let lastCaptureMode = "idle";
  const activeCaptures = new Map();
  let captureChannel = null;

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
    'registerProcessor("miniaudio-ring-processor", MiniaudioRingProcessor);',
    'class MiniaudioCaptureProcessor extends AudioWorkletProcessor {',
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
    '    this.generation = 0;',
    '    this.ready = false;',
    '    this.stopped = false;',
    '    this.port.onmessage = (ev) => {',
    '      const d = ev.data;',
    '      if (!d) return;',
    '      if (d.type === "stop") {',
    '        this.stopped = true;',
    '        this.ready = false;',
    '        return;',
    '      }',
    '      if (d.type !== "init") return;',
    '      this.memObj = d.memory || null;',
    '      this.sab = d.buffer || (this.memObj ? this.memObj.buffer : null);',
    '      this.ctrlPtr = d.ctrlPtr >>> 0;',
    '      this.dataPtr = d.dataPtr >>> 0;',
    '      this.capSamples = d.capSamples >>> 0;',
    '      this.mask = (this.capSamples - 1) >>> 0;',
    '      this.generation = d.generation | 0;',
    '      this.cachedBuf = null;',
    '      this.stopped = false;',
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
    '    if (this.stopped) return false;',
    '    const output = outputs[0];',
    '    if (output) {',
    '      for (let c = 0; c < output.length; c++) output[c].fill(0);',
    '    }',
    '    if (!this.ready || !this._ensureViews()) return true;',
    '    const ctrl = this.ctrlI32;',
    '    if (Atomics.load(ctrl, 5) === 0 || (Atomics.load(ctrl, 6) | 0) !== this.generation) {',
    '      return true;',
    '    }',
    '    const input = inputs[0];',
    '    if (!input || input.length === 0) return true;',
    '    const inCh0 = input[0];',
    '    if (!inCh0 || inCh0.length === 0) return true;',
    '    const frames = inCh0.length;',
    '    const inCh1 = input.length > 1 ? input[1] : null;',
    '    const writePos = Atomics.load(ctrl, 0) >>> 0;',
    '    const readPos = Atomics.load(ctrl, 1) >>> 0;',
    '    let used = (writePos - readPos) >>> 0;',
    '    if (used > this.capSamples) used = this.capSamples;',
    '    const free = this.capSamples - used;',
    '    const toWrite = free < frames ? free : frames;',
    '    if (toWrite <= 0) {',
    '      Atomics.add(ctrl, 7, 1);',
    '      return true;',
    '    }',
    '    const data = this.dataF32;',
    '    const mask = this.mask;',
    '    if (inCh1) {',
    '      for (let i = 0; i < toWrite; i++) {',
    '        data[(writePos + i) & mask] = 0.5 * (inCh0[i] + inCh1[i]);',
    '      }',
    '    } else {',
    '      for (let i = 0; i < toWrite; i++) {',
    '        data[(writePos + i) & mask] = inCh0[i];',
    '      }',
    '    }',
    '    Atomics.store(ctrl, 0, (writePos + toWrite) | 0);',
    '    return true;',
    '  }',
    '}',
    'registerProcessor("miniaudio-capture-processor", MiniaudioCaptureProcessor);'
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
      workletRegistered = true;
      setBackendState("worklet");
      syncStatsDataset();
    }).catch(function(err) {
      URL.revokeObjectURL(moduleUrl);
      workletInitError = String(err);
      workletRegistered = false;
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

  // Enumerate hardware endpoints without ever invoking getUserMedia (no permission popup at load).
  function refreshWebDevices() {
    if (typeof navigator === "undefined" || !navigator.mediaDevices ||
        typeof navigator.mediaDevices.enumerateDevices !== "function") {
      return Promise.resolve();
    }
    const wb = window["$wasmBindgenName"];
    if (!wb || typeof wb.wasm_set_web_capture_devices !== "function") {
      return Promise.resolve();
    }
    return navigator.mediaDevices.enumerateDevices().then(function(devs) {
      const inputs = [];
      for (let i = 0; i < devs.length; i++) {
        const d = devs[i];
        if (d && d.kind === "audioinput" && d.deviceId && d.deviceId.length > 0) {
          inputs.push(d);
        }
      }
      const hasExplicitDefault = inputs.some(function(d) { return d.deviceId === "default"; });
      const ids = [];
      const names = [];
      const defaults = [];
      for (let i = 0; i < inputs.length; i++) {
        const d = inputs[i];
        ids.push(d.deviceId);
        const label = d.label && d.label.trim().length > 0
          ? d.label.trim()
          : (d.deviceId === "default" ? "Browser Default Microphone" : "Microphone " + (i + 1));
        names.push(label);
        defaults.push(hasExplicitDefault ? d.deviceId === "default" : i === 0);
      }
      wb.wasm_set_web_capture_devices(ids, names, defaults);
    }).catch(function() {});
  }

  function cleanupCaptureSession(slotIdx, expectedGen) {
    const sess = activeCaptures.get(slotIdx);
    if (!sess) return;
    if (expectedGen !== undefined && sess.generation !== expectedGen) return;
    sess.cancelled = true;
    activeCaptures.delete(slotIdx);
    if (sess.workletNode) {
      try { sess.workletNode.port.postMessage({ type: "stop" }); } catch (_) {}
      try { sess.workletNode.disconnect(); } catch (_) {}
      sess.workletNode = null;
    }
    if (sess.scriptNode) {
      sess.scriptNode.onaudioprocess = null;
      try { sess.scriptNode.disconnect(); } catch (_) {}
      sess.scriptNode = null;
    }
    if (sess.gainNode) {
      try { sess.gainNode.disconnect(); } catch (_) {}
      sess.gainNode = null;
    }
    if (sess.sourceNode) {
      try { sess.sourceNode.disconnect(); } catch (_) {}
      sess.sourceNode = null;
    }
    if (sess.stream) {
      try {
        const tracks = sess.stream.getTracks();
        for (let i = 0; i < tracks.length; i++) tracks[i].stop();
      } catch (_) {}
      sess.stream = null;
    }
    syncStatsDataset();
    setTimeout(syncStatsDataset, 500);
  }

  function attachCaptureAudioGraph(sess, stream, cmd) {
    const wb = window["$wasmBindgenName"];
    if (!audioCtx || sess.cancelled || activeCaptures.get(sess.slotIdx) !== sess) return;

    const hostSr = audioCtx.sampleRate || 48000;
    if (wb && typeof wb.wasm_set_web_capture_sample_rate === "function") {
      wb.wasm_set_web_capture_sample_rate(sess.slotIdx, sess.generation, hostSr);
    }

    let sourceNode;
    try {
      sourceNode = audioCtx.createMediaStreamSource(stream);
    } catch (err) {
      const msg = err && err.message ? err.message : String(err);
      if (wb && typeof wb.wasm_notify_web_capture_failed === "function") {
        wb.wasm_notify_web_capture_failed(sess.slotIdx, sess.generation, msg);
      }
      cleanupCaptureSession(sess.slotIdx, sess.generation);
      return;
    }
    const silentGain = audioCtx.createGain();
    silentGain.gain.value = 0;
    sess.sourceNode = sourceNode;
    sess.gainNode = silentGain;

    let attachedWorklet = false;
    if (workletRegistered && typeof AudioWorkletNode === "function" && wb &&
        typeof wb.wasm_get_web_audio_ring_descriptor === "function") {
      try {
        const desc = wb.wasm_get_web_audio_ring_descriptor();
        const capNode = new AudioWorkletNode(audioCtx, "miniaudio-capture-processor", {
          numberOfInputs: 1,
          numberOfOutputs: 1,
          outputChannelCount: [1]
        });
        const baseMsg = {
          type: "init",
          ctrlPtr: cmd.ctrlPtr,
          dataPtr: cmd.dataPtr,
          capSamples: cmd.capSamples,
          generation: sess.generation
        };
        try {
          capNode.port.postMessage(Object.assign({}, baseMsg, { memory: desc.memory }));
        } catch (_) {
          capNode.port.postMessage(Object.assign({}, baseMsg, { buffer: desc.memory.buffer }));
        }
        sourceNode.connect(capNode);
        capNode.connect(silentGain);
        silentGain.connect(audioCtx.destination);
        sess.workletNode = capNode;
        attachedWorklet = true;
        lastCaptureMode = "worklet";
        if (typeof console !== "undefined" && typeof console.info === "function") {
          console.info("[miniaudio_player][INFO] Web microphone capture active (mode=worklet, sr=" + hostSr + ")");
        }
      } catch (wErr) {
        if (typeof console !== "undefined" && console.warn) {
          console.warn("[miniaudio_player] Capture AudioWorklet attach failed, falling back to ScriptProcessor:", wErr);
        }
      }
    }

    if (!attachedWorklet) {
      const sp = audioCtx.createScriptProcessor(1024, 2, 1);
      sp.onaudioprocess = function(ev) {
        if (sess.cancelled) return;
        const out = ev.outputBuffer.getChannelData(0);
        out.fill(0);
        const curWb = window["$wasmBindgenName"];
        if (!curWb || typeof curWb.wasm_push_web_capture_pcm !== "function") return;
        const inBuf = ev.inputBuffer;
        const frames = inBuf.length;
        const ch0 = inBuf.getChannelData(0);
        let mono = ch0;
        if (inBuf.numberOfChannels > 1) {
          const ch1 = inBuf.getChannelData(1);
          mono = new Float32Array(frames);
          for (let i = 0; i < frames; i++) mono[i] = 0.5 * (ch0[i] + ch1[i]);
        }
        try {
          curWb.wasm_push_web_capture_pcm(sess.slotIdx, sess.generation, mono, audioCtx.sampleRate || 48000);
        } catch (_) {}
      };
      sourceNode.connect(sp);
      sp.connect(silentGain);
      silentGain.connect(audioCtx.destination);
      sess.scriptNode = sp;
      lastCaptureMode = "script-processor";
      if (typeof console !== "undefined" && typeof console.info === "function") {
        console.info("[miniaudio_player][INFO] Web microphone capture active (mode=script-processor, sr=" + hostSr + ")");
      }
    }

    syncStatsDataset();
    setTimeout(syncStatsDataset, 500);
  }

  function handleStartCapture(cmd) {
    const slotIdx = cmd.slotIdx | 0;
    const gen = cmd.generation | 0;
    cleanupCaptureSession(slotIdx);

    function reportFailure(msg) {
      cleanupCaptureSession(slotIdx, gen);
      const wb = window["$wasmBindgenName"];
      if (wb && typeof wb.wasm_notify_web_capture_failed === "function") {
        try { wb.wasm_notify_web_capture_failed(slotIdx, gen, String(msg || "Capture error")); } catch (_) {}
      }
    }

    if (typeof navigator === "undefined" || !navigator.mediaDevices ||
        typeof navigator.mediaDevices.getUserMedia !== "function") {
      reportFailure("MediaDevices API unavailable (requires HTTPS or localhost)");
      return;
    }

    const sess = {
      slotIdx: slotIdx,
      generation: gen,
      cancelled: false,
      stream: null,
      sourceNode: null,
      workletNode: null,
      scriptNode: null,
      gainNode: null
    };
    activeCaptures.set(slotIdx, sess);

    unlockAudio();

    const reqDev = cmd.deviceId || "AUTO";
    const useExact = reqDev && reqDev !== "AUTO" && reqDev !== "auto" && reqDev !== "default";
    const constraints = {
      audio: useExact ? { deviceId: { exact: reqDev } } : true,
      video: false
    };

    captureGumCalls += 1;
    syncStatsDataset();
    navigator.mediaDevices.getUserMedia(constraints).then(function(stream) {
      if (sess.cancelled || activeCaptures.get(slotIdx) !== sess) {
        try {
          const tracks = stream.getTracks();
          for (let i = 0; i < tracks.length; i++) tracks[i].stop();
        } catch (_) {}
        return;
      }

      sess.stream = stream;
      const tracks = stream.getAudioTracks();
      for (let i = 0; i < tracks.length; i++) {
        tracks[i].addEventListener("ended", function() {
          if (!sess.cancelled && activeCaptures.get(slotIdx) === sess) {
            reportFailure("Microphone capture track ended");
          }
        });
      }

      // Now that permission was granted, populate labeled input devices without re-prompting.
      refreshWebDevices();

      ensureWebAudioOutput();
      if (audioCtx && audioCtx.state === "suspended") {
        audioCtx.resume().catch(function() {});
      }

      if (workletInitPromise && !workletRegistered) {
        workletInitPromise.then(function() {
          attachCaptureAudioGraph(sess, stream, cmd);
        }).catch(function() {
          attachCaptureAudioGraph(sess, stream, cmd);
        });
      } else {
        attachCaptureAudioGraph(sess, stream, cmd);
      }
    }).catch(function(err) {
      if (!sess.cancelled && activeCaptures.get(slotIdx) === sess) {
        const msg = err && err.name ? (err.name + ": " + (err.message || "")) : String(err);
        if (typeof console !== "undefined" && typeof console.warn === "function") {
          console.warn("[miniaudio_player] Web microphone capture failed:", msg);
        }
        reportFailure(msg);
      }
    });
  }

  function handleWebCaptureCmd(cmd) {
    if (!cmd || !cmd.cmd) return;
    if (cmd.cmd === "startCapture") {
      handleStartCapture(cmd);
    } else if (cmd.cmd === "stopCapture") {
      cleanupCaptureSession(cmd.slotIdx | 0, cmd.generation | 0);
    }
  }

  window.__miniaudioWebCaptureCmd = handleWebCaptureCmd;
  if (typeof BroadcastChannel === "function") {
    try {
      captureChannel = new BroadcastChannel("__miniaudio_web_capture_v1__");
      captureChannel.onmessage = function(ev) {
        handleWebCaptureCmd(ev.data);
      };
    } catch (_) {}
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
      activeCaptures: activeCaptures.size,
      captureMode: activeCaptures.size > 0 ? lastCaptureMode : "idle",
      captureGumCalls: captureGumCalls,
      captureSamplesWritten: wb && typeof wb.wasm_get_web_capture_samples_written === "function" ? wb.wasm_get_web_capture_samples_written() : 0,
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
  refreshWebDevices();
  syncStatsDataset();

  if (typeof navigator !== "undefined" && navigator.mediaDevices &&
      typeof navigator.mediaDevices.addEventListener === "function") {
    navigator.mediaDevices.addEventListener("devicechange", refreshWebDevices);
  }

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
