// ignore_for_file: prefer_interpolation_to_compose_strings, unnecessary_new, strict_top_level_inference, avoid_print
// Auto-generated blob code for Web Worker and AudioWorklet.
import 'dart:js_interop';
import 'package:web/web.dart' as web;

const String kWorkletProcessorJs = r'''
class MiniaudioWorkletProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.queue = [];
    this.currentChunk = null;
    this.currentOffset = 0;
    this.port.onmessage = (e) => {
      if (e.data && e.data.type === "chunk") {
        this.queue.push(e.data);
      } else if (e.data && e.data.type === "flush") {
        this.queue = [];
        this.currentChunk = null;
        this.currentOffset = 0;
      }
    };
  }

  process(inputs, outputs, parameters) {
    const output = outputs[0];
    if (!output || output.length === 0) return true;
    const left = output[0];
    const right = output[1] || output[0];
    const quantum = left.length;

    let framesCopied = 0;
    while (framesCopied < quantum) {
      if (!this.currentChunk) {
        if (this.queue.length === 0) {
          left.fill(0, framesCopied);
          if (right !== left) right.fill(0, framesCopied);
          break;
        }
        this.currentChunk = this.queue.shift();
        this.currentOffset = 0;
      }

      const chunk = this.currentChunk;
      const chunkFrames = chunk.frameCount;
      const available = chunkFrames - this.currentOffset;
      const toCopy = Math.min(quantum - framesCopied, available);

      left.set(chunk.left.subarray(this.currentOffset, this.currentOffset + toCopy), framesCopied);
      if (right !== left && chunk.right) {
        right.set(chunk.right.subarray(this.currentOffset, this.currentOffset + toCopy), framesCopied);
      }

      this.currentOffset += toCopy;
      framesCopied += toCopy;

      if (this.currentOffset >= chunkFrames) {
        this.port.postMessage({ type: "recycle", buffer: chunk.rawBuffer }, [chunk.rawBuffer]);
        this.currentChunk = null;
        this.currentOffset = 0;
      }
    }
    return true;
  }
}
registerProcessor("miniaudio-worklet-processor", MiniaudioWorkletProcessor);
''';

const String kMiniaudioJs = r'''var createMiniaudioModule=(()=>{var _scriptName=globalThis.document?.currentScript?.src;return async function(moduleArg={}){var Module=moduleArg;var ENVIRONMENT_IS_WEB=!!globalThis.window;var ENVIRONMENT_IS_WORKER=!!globalThis.WorkerGlobalScope;var ENVIRONMENT_IS_NODE=globalThis.process?.versions?.node&&globalThis.process?.type!="renderer";var programArgs=[];var thisProgram="./this.program";var quit_=(status,toThrow)=>{throw toThrow};if(ENVIRONMENT_IS_WORKER){_scriptName=self.location.href}var scriptDirectory="";function locateFile(path){if(Module["locateFile"]){return Module["locateFile"](path,scriptDirectory)}return scriptDirectory+path}var readAsync,readBinary;if(ENVIRONMENT_IS_WEB||ENVIRONMENT_IS_WORKER){try{scriptDirectory=new URL(".",_scriptName).href}catch{}{if(ENVIRONMENT_IS_WORKER){readBinary=url=>{var xhr=new XMLHttpRequest;xhr.open("GET",url,false);xhr.responseType="arraybuffer";xhr.send(null);return new Uint8Array(xhr.response)}}readAsync=async url=>{var response=await fetch(url,{credentials:"same-origin"});if(response.ok){return response.arrayBuffer()}throw new Error(response.status+" : "+response.url)}}}else{}var out=console.log.bind(console);var err=console.error.bind(console);var wasmBinary;var ABORT=false;var EXITSTATUS;class EmscriptenEH{}class EmscriptenSjLj extends EmscriptenEH{}var runtimeInitialized=false;function getMemoryBuffer(){return wasmMemory.buffer}function updateMemoryViews(){if(HEAP8?.buffer?.resizable)return;var b=getMemoryBuffer();HEAP8=new Int8Array(b);Module["HEAPU8"]=HEAPU8=new Uint8Array(b);Module["HEAP32"]=HEAP32=new Int32Array(b);Module["HEAPU32"]=HEAPU32=new Uint32Array(b);Module["HEAPF32"]=HEAPF32=new Float32Array(b);Module["HEAPF64"]=HEAPF64=new Float64Array(b)}function preRun(){var preRun=Module["preRun"];if(preRun){if(typeof preRun=="function")preRun=[preRun];onPreRuns.push(...preRun)}callRuntimeCallbacks(onPreRuns)}function initRuntime(){runtimeInitialized=true;wasmExports["q"]()}function postRun(){var postRun=Module["postRun"];if(postRun){if(typeof postRun=="function")postRun=[postRun];onPostRuns.push(...postRun)}callRuntimeCallbacks(onPostRuns)}function abort(what){Module["onAbort"]?.(what);what=`Aborted(${what})`;err(what);ABORT=true;what+=". Build with -sASSERTIONS for more info.";var e=new WebAssembly.RuntimeError(what);throw e}var wasmBinaryFile;function findWasmBinary(){return locateFile("miniaudio_player.wasm")}function getBinarySync(file){if(readBinary){return readBinary(file)}throw"both async and sync fetching of the wasm failed"}async function getWasmBinary(binaryFile){if(!wasmBinary){try{var response=await readAsync(binaryFile);return new Uint8Array(response)}catch{}}return getBinarySync(binaryFile)}async function instantiateArrayBuffer(binaryFile,imports){try{var binary=await getWasmBinary(binaryFile);var instance=await WebAssembly.instantiate(binary,imports);return instance}catch(reason){err(`failed to asynchronously prepare wasm: ${reason}`);abort(reason)}}async function instantiateAsync(binary,binaryFile,imports){if(!binary){try{var response=fetch(binaryFile,{credentials:"same-origin"});var instantiationResult=await WebAssembly.instantiateStreaming(response,imports);return instantiationResult}catch(reason){err(`wasm streaming compile failed: ${reason}`);err("falling back to ArrayBuffer instantiation")}}return instantiateArrayBuffer(binaryFile,imports)}function getWasmImports(){var imports={a:wasmImports};return imports}async function createWasm(){function receiveInstance(instance){wasmExports=instance.exports;assignWasmExports(wasmExports);updateMemoryViews();return wasmExports}function receiveInstantiationResult(result){return receiveInstance(result["instance"])}var info=getWasmImports();var instantiateWasm=Module["instantiateWasm"];if(instantiateWasm){return new Promise(resolve=>{instantiateWasm(info,inst=>resolve(receiveInstance(inst)))})}wasmBinaryFile??=findWasmBinary();var result=await instantiateAsync(wasmBinary,wasmBinaryFile,info);var exports=receiveInstantiationResult(result);return exports}class ExitStatus{name="ExitStatus";constructor(status){this.message=`Program terminated with exit(${status})`;this.status=status}}var HEAP8;var callRuntimeCallbacks=callbacks=>{while(callbacks.length>0){callbacks.shift()(Module)}};var onPostRuns=[];var onPreRuns=[];var noExitRuntime=true;var UTF8Decoder=globalThis.TextDecoder&&new TextDecoder;var findStringEnd=(heapOrArray,idx,maxBytesToRead,ignoreNul)=>{var maxIdx=idx+maxBytesToRead;if(ignoreNul)return maxIdx;while(heapOrArray[idx]&&!(idx>=maxIdx))++idx;return idx};var UTF8ArrayToString=(heapOrArray,idx=0,maxBytesToRead,ignoreNul)=>{var endPtr=findStringEnd(heapOrArray,idx,maxBytesToRead,ignoreNul);if(endPtr-idx>16&&heapOrArray.buffer&&UTF8Decoder){return UTF8Decoder.decode(heapOrArray.subarray(idx,endPtr))}var str="";while(idx<endPtr){var u0=heapOrArray[idx++];if(!(u0&128)){str+=String.fromCharCode(u0);continue}var u1=heapOrArray[idx++]&63;if((u0&224)==192){str+=String.fromCharCode((u0&31)<<6|u1);continue}var u2=heapOrArray[idx++]&63;if((u0&240)==224){u0=(u0&15)<<12|u1<<6|u2}else{u0=(u0&7)<<18|u1<<12|u2<<6|heapOrArray[idx++]&63}if(u0<65536){str+=String.fromCharCode(u0)}else{var ch=u0-65536;str+=String.fromCharCode(55296|ch>>10,56320|ch&1023)}}return str};var HEAPU8;var UTF8ToString=(ptr,maxBytesToRead,ignoreNul)=>ptr?UTF8ArrayToString(HEAPU8,ptr,maxBytesToRead,ignoreNul):"";var ___assert_fail=(condition,filename,line,func)=>abort(`Assertion failed: ${UTF8ToString(condition)}, at: `+[filename?UTF8ToString(filename):"unknown filename",line,func?UTF8ToString(func):"unknown function"]);var SYSCALLS={varargs:undefined,getStr(ptr){var ret=UTF8ToString(ptr);return ret}};function ___syscall_fcntl64(fd,cmd,varargs){SYSCALLS.varargs=varargs;return 0}var ___syscall_fstat64=(fd,buf)=>{};function ___syscall_ioctl(fd,op,varargs){SYSCALLS.varargs=varargs;return 0}function ___syscall_openat(dirfd,path,flags,varargs){SYSCALLS.varargs=varargs}var __abort_js=()=>abort("");var runtimeKeepaliveCounter=0;var __emscripten_runtime_keepalive_clear=()=>{noExitRuntime=false;runtimeKeepaliveCounter=0};var timers={};var handleException=e=>{if(e instanceof ExitStatus||e=="unwind"){return EXITSTATUS}quit_(1,e)};var keepRuntimeAlive=()=>noExitRuntime||runtimeKeepaliveCounter>0;var _proc_exit=code=>{EXITSTATUS=code;if(!keepRuntimeAlive()){Module["onExit"]?.(code);ABORT=true}quit_(code,new ExitStatus(code))};var exitJS=(status,implicit)=>{EXITSTATUS=status;_proc_exit(status)};var _exit=exitJS;var maybeExit=()=>{if(!keepRuntimeAlive()){try{_exit(EXITSTATUS)}catch(e){handleException(e)}}};var callUserCallback=(func,...args)=>{if(ABORT){return}try{return func(...args)}catch(e){handleException(e)}finally{maybeExit()}};var _emscripten_get_now=()=>performance.now();var __setitimer_js=(which,timeout_ms)=>{if(timers[which]){clearTimeout(timers[which].id);delete timers[which]}if(!timeout_ms)return 0;var id=setTimeout(()=>{delete timers[which];callUserCallback(__emscripten_timeout,which,_emscripten_get_now())},timeout_ms);timers[which]={id,timeout_ms};return 0};var _emscripten_date_now=()=>Date.now();var getHeapMax=()=>268435456;var alignMemory=(size,alignment)=>Math.ceil(size/alignment)*alignment;var growMemory=size=>{var oldHeapSize=wasmMemory.buffer.byteLength;var pages=(size-oldHeapSize+65535)/65536|0;try{wasmMemory.grow(pages);updateMemoryViews();return 1}catch(e){}};var _emscripten_resize_heap=requestedSize=>{var oldSize=HEAPU8.length;requestedSize>>>=0;var maxHeapSize=getHeapMax();if(requestedSize>maxHeapSize){return false}for(var cutDown=1;cutDown<=4;cutDown*=2){var overGrownHeapSize=oldSize*(1+.2/cutDown);overGrownHeapSize=Math.min(overGrownHeapSize,requestedSize+100663296);var newSize=Math.min(maxHeapSize,alignMemory(Math.max(requestedSize,overGrownHeapSize),65536));var replacement=growMemory(newSize);if(replacement){return true}}return false};var _fd_close=fd=>52;var _fd_read=(fd,iov,iovcnt,pnum)=>52;var INT53_MAX=9007199254740992;var INT53_MIN=-9007199254740992;var bigintToI53Checked=num=>num<INT53_MIN||num>INT53_MAX?NaN:Number(num);function _fd_seek(fd,offset,whence,newOffset){offset=bigintToI53Checked(offset);return 70}var printCharBuffers=[null,[],[]];var printChar=(stream,curr)=>{var buffer=printCharBuffers[stream];if(!curr||curr===10){(stream===1?out:err)(UTF8ArrayToString(buffer));buffer.length=0}else{buffer.push(curr)}};var HEAPU32;var _fd_write=(fd,iov,iovcnt,pnum)=>{var num=0;for(var i=0;i<iovcnt;i++){var ptr=HEAPU32[iov>>2];var len=HEAPU32[iov+4>>2];iov+=8;for(var j=0;j<len;j++){printChar(fd,HEAPU8[ptr+j])}num+=len}HEAPU32[pnum>>2]=num;return 0};var HEAP32;var HEAPF32;var HEAPF64;{if(Module["noExitRuntime"])noExitRuntime=Module["noExitRuntime"];if(Module["print"])out=Module["print"];if(Module["printErr"])err=Module["printErr"];if(Module["arguments"])programArgs=Module["arguments"];if(Module["thisProgram"])thisProgram=Module["thisProgram"];var preInit=Module["preInit"];if(preInit){if(typeof preInit=="function")Module["preInit"]=preInit=[preInit];while(preInit.length>0){preInit.shift()()}}}var _malloc,_free,_map_wasm_get_staging_ptr,_map_wasm_get_staging_capacity,_map_wasm_malloc,_map_wasm_free,_map_wasm_player_create,_map_wasm_player_destroy,_map_wasm_play,_map_wasm_pause,_map_wasm_stop,_map_wasm_seek,_map_wasm_get_position_ms,_map_wasm_get_duration_ms,_map_wasm_get_state,_map_wasm_is_playing,_map_wasm_is_buffering,_map_wasm_is_completed,_map_wasm_get_silence_saved_ms,_map_wasm_get_bitrate,_map_wasm_get_sample_rate,_map_wasm_get_channels,_map_wasm_open_memory,_map_wasm_open_stream,_map_wasm_open_stream_ex,_map_wasm_stream_feed,_map_wasm_stream_flush,_map_wasm_stream_seek,_map_wasm_stream_get_seek_byte,_map_wasm_get_audio_data_offset,_map_wasm_stream_get_pinned_head_size,_map_wasm_stream_end,_map_wasm_probe_tail,_map_wasm_set_volume,_map_wasm_get_volume,_map_wasm_set_playback_rate,_map_wasm_get_playback_rate,_map_wasm_set_pitch,_map_wasm_get_pitch,_map_wasm_set_pan,_map_wasm_set_equalizer_band,_map_wasm_set_equalizer_bands,_map_wasm_set_equalizer_enabled,_map_wasm_set_reverb_enabled,_map_wasm_set_reverb_preset,_map_wasm_set_crossfeed_enabled,_map_wasm_set_crossfeed_preset,_map_wasm_set_limiter_enabled,_map_wasm_set_silence_skip,_map_wasm_set_visualizer_enabled,_map_wasm_render_pcm_frames,_map_wasm_poll_telemetry,_map_wasm_analyze_audio_memory,__emscripten_timeout,memory,__indirect_function_table,wasmMemory;function assignWasmExports(wasmExports){_malloc=Module["_malloc"]=wasmExports["r"];_free=Module["_free"]=wasmExports["s"];_map_wasm_get_staging_ptr=Module["_map_wasm_get_staging_ptr"]=wasmExports["t"];_map_wasm_get_staging_capacity=Module["_map_wasm_get_staging_capacity"]=wasmExports["u"];_map_wasm_malloc=Module["_map_wasm_malloc"]=wasmExports["v"];_map_wasm_free=Module["_map_wasm_free"]=wasmExports["w"];_map_wasm_player_create=Module["_map_wasm_player_create"]=wasmExports["x"];_map_wasm_player_destroy=Module["_map_wasm_player_destroy"]=wasmExports["y"];_map_wasm_play=Module["_map_wasm_play"]=wasmExports["z"];_map_wasm_pause=Module["_map_wasm_pause"]=wasmExports["A"];_map_wasm_stop=Module["_map_wasm_stop"]=wasmExports["B"];_map_wasm_seek=Module["_map_wasm_seek"]=wasmExports["C"];_map_wasm_get_position_ms=Module["_map_wasm_get_position_ms"]=wasmExports["D"];_map_wasm_get_duration_ms=Module["_map_wasm_get_duration_ms"]=wasmExports["E"];_map_wasm_get_state=Module["_map_wasm_get_state"]=wasmExports["F"];_map_wasm_is_playing=Module["_map_wasm_is_playing"]=wasmExports["G"];_map_wasm_is_buffering=Module["_map_wasm_is_buffering"]=wasmExports["H"];_map_wasm_is_completed=Module["_map_wasm_is_completed"]=wasmExports["I"];_map_wasm_get_silence_saved_ms=Module["_map_wasm_get_silence_saved_ms"]=wasmExports["J"];_map_wasm_get_bitrate=Module["_map_wasm_get_bitrate"]=wasmExports["K"];_map_wasm_get_sample_rate=Module["_map_wasm_get_sample_rate"]=wasmExports["L"];_map_wasm_get_channels=Module["_map_wasm_get_channels"]=wasmExports["M"];_map_wasm_open_memory=Module["_map_wasm_open_memory"]=wasmExports["N"];_map_wasm_open_stream=Module["_map_wasm_open_stream"]=wasmExports["O"];_map_wasm_open_stream_ex=Module["_map_wasm_open_stream_ex"]=wasmExports["P"];_map_wasm_stream_feed=Module["_map_wasm_stream_feed"]=wasmExports["Q"];_map_wasm_stream_flush=Module["_map_wasm_stream_flush"]=wasmExports["R"];_map_wasm_stream_seek=Module["_map_wasm_stream_seek"]=wasmExports["S"];_map_wasm_stream_get_seek_byte=Module["_map_wasm_stream_get_seek_byte"]=wasmExports["T"];_map_wasm_get_audio_data_offset=Module["_map_wasm_get_audio_data_offset"]=wasmExports["U"];_map_wasm_stream_get_pinned_head_size=Module["_map_wasm_stream_get_pinned_head_size"]=wasmExports["V"];_map_wasm_stream_end=Module["_map_wasm_stream_end"]=wasmExports["W"];_map_wasm_probe_tail=Module["_map_wasm_probe_tail"]=wasmExports["X"];_map_wasm_set_volume=Module["_map_wasm_set_volume"]=wasmExports["Y"];_map_wasm_get_volume=Module["_map_wasm_get_volume"]=wasmExports["Z"];_map_wasm_set_playback_rate=Module["_map_wasm_set_playback_rate"]=wasmExports["_"];_map_wasm_get_playback_rate=Module["_map_wasm_get_playback_rate"]=wasmExports["$"];_map_wasm_set_pitch=Module["_map_wasm_set_pitch"]=wasmExports["aa"];_map_wasm_get_pitch=Module["_map_wasm_get_pitch"]=wasmExports["ba"];_map_wasm_set_pan=Module["_map_wasm_set_pan"]=wasmExports["ca"];_map_wasm_set_equalizer_band=Module["_map_wasm_set_equalizer_band"]=wasmExports["da"];_map_wasm_set_equalizer_bands=Module["_map_wasm_set_equalizer_bands"]=wasmExports["ea"];_map_wasm_set_equalizer_enabled=Module["_map_wasm_set_equalizer_enabled"]=wasmExports["fa"];_map_wasm_set_reverb_enabled=Module["_map_wasm_set_reverb_enabled"]=wasmExports["ga"];_map_wasm_set_reverb_preset=Module["_map_wasm_set_reverb_preset"]=wasmExports["ha"];_map_wasm_set_crossfeed_enabled=Module["_map_wasm_set_crossfeed_enabled"]=wasmExports["ia"];_map_wasm_set_crossfeed_preset=Module["_map_wasm_set_crossfeed_preset"]=wasmExports["ja"];_map_wasm_set_limiter_enabled=Module["_map_wasm_set_limiter_enabled"]=wasmExports["ka"];_map_wasm_set_silence_skip=Module["_map_wasm_set_silence_skip"]=wasmExports["la"];_map_wasm_set_visualizer_enabled=Module["_map_wasm_set_visualizer_enabled"]=wasmExports["ma"];_map_wasm_render_pcm_frames=Module["_map_wasm_render_pcm_frames"]=wasmExports["na"];_map_wasm_poll_telemetry=Module["_map_wasm_poll_telemetry"]=wasmExports["oa"];_map_wasm_analyze_audio_memory=Module["_map_wasm_analyze_audio_memory"]=wasmExports["pa"];__emscripten_timeout=wasmExports["qa"];memory=wasmMemory=wasmExports["p"];__indirect_function_table=wasmExports["__indirect_function_table"]}var wasmImports={a:___assert_fail,c:___syscall_fcntl64,e:___syscall_fstat64,j:___syscall_ioctl,f:___syscall_openat,o:__abort_js,n:__emscripten_runtime_keepalive_clear,k:__setitimer_js,g:_emscripten_date_now,l:_emscripten_resize_heap,b:_fd_close,i:_fd_read,d:_fd_seek,h:_fd_write,m:_proc_exit};async function run(){preRun();var setStatus=Module["setStatus"];if(setStatus){setStatus("Running...");await new Promise(resolve=>setTimeout(resolve,1));setTimeout(setStatus,1,"")}if(ABORT)return;initRuntime();Module["onRuntimeInitialized"]?.();postRun()}var wasmExports;wasmExports=await createWasm();await run();
;return Module}})();if(typeof exports==="object"&&typeof module==="object"){module.exports=createMiniaudioModule;module.exports.default=createMiniaudioModule}else if(typeof define==="function"&&define["amd"])define([],()=>createMiniaudioModule);
''';

const String kEngineWorkerJs = r'''
let Module = null;
let player = 0;
let workletPort = null;
let pcmBufferPtr = 0;
let telemetryPtr = 0;
let stagingPtr = 0;
let stagingCapacity = 0;

let isPlaying = false;
let isBuffering = false;
let isCompleted = false;
let pumpInterval = null;
let telemetryInterval = null;

let initResolver = null;
const initReadyPromise = new Promise(resolve => { initResolver = resolve; });

let recycledBuffers = [];
let chunksInFlight = 0;
const MAX_CHUNKS_IN_FLIGHT = 4;
const RENDER_FRAME_COUNT = 2048;

let activeAbortController = null;
let streamTotalSize = -1;
let streamIsLive = false;
let streamUrl = null;
let streamBufferCapacity = 2 * 1024 * 1024;
let streamEncodingFormat = 0;

async function loadWasm(wasmUrl) {
  const resp = await fetch(wasmUrl);
  if (!resp.ok) {
    if (wasmUrl.endsWith(".br")) {
      return loadWasm(wasmUrl.slice(0, -3));
    }
    throw new Error("Failed to fetch wasm from " + wasmUrl + ": HTTP " + resp.status);
  }
  const rawBuf = await resp.arrayBuffer();
  let wasmBytes = new Uint8Array(rawBuf);

  if (wasmBytes.length < 4 || wasmBytes[0] !== 0 || wasmBytes[1] !== 0x61 || wasmBytes[2] !== 0x73 || wasmBytes[3] !== 0x6D) {
    let decompressed = false;
    if (typeof DecompressionStream !== "undefined") {
      try {
        const ds = new DecompressionStream("br");
        const stream = new Response(wasmBytes).body.pipeThrough(ds);
        wasmBytes = new Uint8Array(await new Response(stream).arrayBuffer());
        decompressed = true;
      } catch (_) {}
    }
    if (!decompressed && wasmUrl.endsWith(".br")) {
      return loadWasm(wasmUrl.slice(0, -3));
    }
  }

  const mod = await WebAssembly.compile(wasmBytes);
  return mod;
}

self.onmessage = async function(e) {
  const msg = e.data;
  if (!msg) return;

  if (msg.type !== "init" && msg.type !== "connectWorklet") {
    await initReadyPromise;
  }

  switch (msg.type) {
    case "init": {
      try {
        const wasmUrl = msg.wasmUrl;
        const sampleRate = msg.sampleRate || 48000;
        const channels = msg.channels || 2;
        const periodSize = msg.periodSize || 2048;

        const mod = await loadWasm(wasmUrl);
        Module = await createMiniaudioModule({
          instantiateWasm(info, receiveInstance) {
            const instance = new WebAssembly.Instance(mod, info);
            receiveInstance(instance, mod);
            return instance.exports;
          }
        });

        player = Module._map_wasm_player_create(sampleRate, channels, periodSize);
        stagingPtr = Module._map_wasm_get_staging_ptr();
        stagingCapacity = Module._map_wasm_get_staging_capacity();
        pcmBufferPtr = Module._map_wasm_malloc(4096 * 2 * 4);
        telemetryPtr = Module._map_wasm_malloc(32 * 8);

        if (initResolver) initResolver();
        self.postMessage({ type: "initialized", player });
      } catch (err) {
        self.postMessage({ type: "error", error: err.message });
      }
      break;
    }

    case "connectWorklet": {
      workletPort = e.ports[0];
      workletPort.onmessage = function(ev) {
        if (ev.data && ev.data.type === "recycle") {
          recycledBuffers.push(ev.data.buffer);
          chunksInFlight = Math.max(0, chunksInFlight - 1);
          if (isPlaying) {
            pumpAudio();
          }
        }
      };
      break;
    }

    case "openStreamEx": {
      try {
        stopPlaybackLoop();
        if (activeAbortController) {
          activeAbortController.abort();
          activeAbortController = null;
        }
        const initialBytes = new Uint8Array(msg.bytes);
        const tailBytes = msg.tailBytes ? new Uint8Array(msg.tailBytes) : null;
        const headPtr = Module._map_wasm_malloc(initialBytes.length);
        Module.HEAPU8.set(initialBytes, headPtr);
        let tailPtr = 0;
        let tailLen = 0;
        if (tailBytes && tailBytes.length > 0) {
          tailLen = tailBytes.length;
          tailPtr = Module._map_wasm_malloc(tailLen);
          Module.HEAPU8.set(tailBytes, tailPtr);
        }
        const totalSize = (msg.totalSize !== undefined && msg.totalSize !== null) ? msg.totalSize : -1;
        const isLive = msg.isLive ? 1 : 0;
        const bufferCap = msg.bufferCapacity || (2 * 1024 * 1024);
        const encFmt = msg.encodingFormat || 0;

        const res = Module._map_wasm_open_stream_ex(
          player,
          headPtr,
          initialBytes.length,
          tailPtr,
          tailLen,
          totalSize,
          isLive,
          bufferCap,
          encFmt
        );
        Module._map_wasm_free(headPtr);
        if (tailPtr) Module._map_wasm_free(tailPtr);

        let audioOffset = 0;
        let pinnedSize = 0;
        if (res === 0) {
          audioOffset = Module._map_wasm_get_audio_data_offset(player);
          pinnedSize = Module._map_wasm_stream_get_pinned_head_size(player);
          Module._map_wasm_poll_telemetry(player, telemetryPtr);
          const raw = Module.HEAPF64.slice(telemetryPtr >> 3, (telemetryPtr >> 3) + 32);
          self.postMessage({ type: "telemetry", data: Array.from(raw) });
        }
        self.postMessage({
          type: "opened",
          result: res,
          audioDataOffset: audioOffset,
          pinnedHeadSize: pinnedSize
        });
      } catch (err) {
        self.postMessage({ type: "error", error: err.message });
      }
      break;
    }

    case "streamFeed": {
      if (!player || !msg.bytes) break;
      const chunk = new Uint8Array(msg.bytes);
      let offset = 0;
      while (offset < chunk.length) {
        const sliceLen = Math.min(chunk.length - offset, stagingCapacity);
        Module.HEAPU8.set(chunk.subarray(offset, offset + sliceLen), stagingPtr);
        Module._map_wasm_stream_feed(player, stagingPtr, sliceLen);
        offset += sliceLen;
      }
      break;
    }

    case "streamFlush": {
      if (!player) break;
      Module._map_wasm_stream_flush(player, msg.newStreamOffset || 0);
      if (workletPort) workletPort.postMessage({ type: "flush" });
      chunksInFlight = 0;
      break;
    }

    case "streamSeek": {
      if (!player) break;
      Module._map_wasm_stream_seek(player, msg.positionMs || 0, msg.newStreamOffset || 0);
      if (workletPort) workletPort.postMessage({ type: "flush" });
      chunksInFlight = 0;
      if (isPlaying) {
        pumpAudio();
      }
      break;
    }

    case "streamEnd": {
      if (!player) break;
      Module._map_wasm_stream_end(player);
      break;
    }

    case "probeTail": {
      if (!player || !msg.bytes) break;
      const buf = new Uint8Array(msg.bytes);
      if (buf.length > 0) {
        const mem = Module._map_wasm_malloc(buf.length);
        Module.HEAPU8.set(buf, mem);
        Module._map_wasm_probe_tail(player, mem, buf.length, msg.tailOffset || 0);
        Module._map_wasm_free(mem);
      }
      break;
    }

    case "openMemory": {
      try {
        stopPlaybackLoop();
        const bytes = new Uint8Array(msg.bytes);
        const memPtr = Module._map_wasm_malloc(bytes.length);
        Module.HEAPU8.set(bytes, memPtr);
        const res = Module._map_wasm_open_memory(player, memPtr, bytes.length);
        if (res !== 0) {
          Module._map_wasm_free(memPtr);
        }
        self.postMessage({ type: "opened", result: res });
      } catch (err) {
        self.postMessage({ type: "error", error: err.message });
      }
      break;
    }

    case "openStream": {
      try {
        stopPlaybackLoop();
        if (activeAbortController) {
          activeAbortController.abort();
          activeAbortController = null;
        }
        streamUrl = msg.url;
        streamIsLive = !!msg.isLive;
        streamBufferCapacity = msg.bufferCapacity || (2 * 1024 * 1024);
        streamEncodingFormat = msg.encodingFormat || 0;
        streamTotalSize = msg.totalSize || -1;

        startStreaming(streamUrl, 0);
        self.postMessage({ type: "opened", result: 0 });
      } catch (err) {
        self.postMessage({ type: "error", error: err.message });
      }
      break;
    }

    case "play": {
      if (!player) return;
      Module._map_wasm_play(player);
      isPlaying = true;
      startPlaybackLoop();
      startTelemetryLoop();
      self.postMessage({ type: "played" });
      break;
    }

    case "pause": {
      if (!player) return;
      Module._map_wasm_pause(player);
      isPlaying = false;
      stopPlaybackLoop();
      self.postMessage({ type: "paused" });
      break;
    }

    case "stop": {
      if (!player) return;
      isPlaying = false;
      stopPlaybackLoop();
      if (activeAbortController) {
        activeAbortController.abort();
        activeAbortController = null;
      }
      Module._map_wasm_stop(player);
      if (workletPort) workletPort.postMessage({ type: "flush" });
      chunksInFlight = 0;
      self.postMessage({ type: "stopped" });
      break;
    }

    case "seek": {
      if (!player) return;
      const targetMs = msg.positionMs;
      if (streamUrl && streamTotalSize > 0) {
        const newByteOffset = Module._map_wasm_stream_get_seek_byte(player, targetMs);
        const cacheHit = Module._map_wasm_stream_seek(player, targetMs, newByteOffset);
        if (cacheHit === 0) {
          startStreaming(streamUrl, newByteOffset);
        }
      } else {
        Module._map_wasm_seek(player, targetMs);
      }
      if (workletPort) workletPort.postMessage({ type: "flush" });
      chunksInFlight = 0;
      if (isPlaying) {
        pumpAudio();
      }
      self.postMessage({ type: "seeked" });
      break;
    }

    case "setVolume": {
      if (player) Module._map_wasm_set_volume(player, msg.volume);
      break;
    }
    case "setRate": {
      if (player) Module._map_wasm_set_playback_rate(player, msg.rate);
      break;
    }
    case "setPitch": {
      if (player) Module._map_wasm_set_pitch(player, msg.pitch);
      break;
    }
    case "setPan": {
      if (player) Module._map_wasm_set_pan(player, msg.pan);
      break;
    }
    case "setEqualizerBand": {
      if (player) Module._map_wasm_set_equalizer_band(player, msg.band, msg.gainDb);
      break;
    }
    case "setEqualizerBands": {
      if (player) {
        const bands = msg.gainsDb;
        const mem = Module._map_wasm_malloc(bands.length * 4);
        Module.HEAPF32.set(bands, mem >> 2);
        Module._map_wasm_set_equalizer_bands(player, mem, bands.length);
        Module._map_wasm_free(mem);
      }
      break;
    }
    case "setEqualizerEnabled": {
      if (player) Module._map_wasm_set_equalizer_enabled(player, msg.enabled ? 1 : 0);
      break;
    }
    case "setReverb": {
      if (player) Module._map_wasm_set_reverb_preset(player, msg.preset);
      break;
    }
    case "setCrossfeed": {
      if (player) Module._map_wasm_set_crossfeed_preset(player, msg.preset);
      break;
    }
    case "setLimiterEnabled": {
      if (player) Module._map_wasm_set_limiter_enabled(player, msg.enabled ? 1 : 0);
      break;
    }
    case "setSilenceSkip": {
      if (player) Module._map_wasm_set_silence_skip(player, msg.mode, msg.thresholdDb, msg.minDurationMs);
      break;
    }
    case "setVisualizerEnabled": {
      if (player) Module._map_wasm_set_visualizer_enabled(player, msg.enabled ? 1 : 0);
      break;
    }

    case "destroy": {
      isPlaying = false;
      stopPlaybackLoop();
      stopTelemetryLoop();
      if (activeAbortController) {
        activeAbortController.abort();
        activeAbortController = null;
      }
      if (player && Module) {
        Module._map_wasm_player_destroy(player);
        player = 0;
      }
      if (pcmBufferPtr) Module._map_wasm_free(pcmBufferPtr);
      if (telemetryPtr) Module._map_wasm_free(telemetryPtr);
      break;
    }
  }
};

async function startStreaming(url, startByte) {
  if (activeAbortController) {
    activeAbortController.abort();
  }
  const ac = new AbortController();
  activeAbortController = ac;

  try {
    const headers = {};
    if (startByte > 0) {
      headers["Range"] = "bytes=" + startByte + "-";
    }

    const resp = await fetch(url, { headers, signal: ac.signal });
    if (!resp.ok && resp.status !== 206) {
      throw new Error("HTTP " + resp.status);
    }

    const cr = resp.headers.get("Content-Range");
    const cl = resp.headers.get("Content-Length");
    if (cr) {
      const match = cr.match(/\/(\d+)/);
      if (match) streamTotalSize = parseInt(match[1], 10);
    } else if (cl && startByte === 0) {
      streamTotalSize = parseInt(cl, 10);
    }

    if (startByte === 0 && streamTotalSize > 64 * 1024) {
      probeTail(url, streamTotalSize, ac.signal);
    }

    const reader = resp.body.getReader();
    let isInitial = (startByte === 0);

    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        Module._map_wasm_stream_end(player);
        break;
      }
      if (ac.signal.aborted) break;

      feedChunk(value, isInitial);
      isInitial = false;
    }
  } catch (err) {
    if (!ac.signal.aborted) {
      self.postMessage({ type: "streamError", error: err.message });
    }
  }
}

function feedChunk(uint8Data, isInitial) {
  let offset = 0;
  while (offset < uint8Data.length) {
    const chunkSize = Math.min(uint8Data.length - offset, stagingCapacity);
    Module.HEAPU8.set(uint8Data.subarray(offset, offset + chunkSize), stagingPtr);
    if (isInitial && offset === 0) {
      Module._map_wasm_open_stream(
        player,
        stagingPtr,
        chunkSize,
        streamTotalSize,
        streamIsLive ? 1 : 0,
        streamBufferCapacity,
        streamEncodingFormat
      );
    } else {
      Module._map_wasm_stream_feed(player, stagingPtr, chunkSize);
    }
    offset += chunkSize;
  }
}

async function probeTail(url, totalSize, signal) {
  try {
    const tailLen = Math.min(256 * 1024, totalSize);
    const tailStart = totalSize - tailLen;
    const resp = await fetch(url, {
      headers: { "Range": "bytes=" + tailStart + "-" + (totalSize - 1) },
      signal
    });
    if (resp.status === 206 || resp.ok) {
      const buf = new Uint8Array(await resp.arrayBuffer());
      if (buf.length > 0 && !signal.aborted) {
        const mem = Module._map_wasm_malloc(buf.length);
        Module.HEAPU8.set(buf, mem);
        Module._map_wasm_probe_tail(player, mem, buf.length, tailStart);
        Module._map_wasm_free(mem);
      }
    }
  } catch (_) {}
}

function startPlaybackLoop() {
  if (pumpInterval) return;
  pumpAudio();
  pumpInterval = setInterval(pumpAudio, 20);
}

function stopPlaybackLoop() {
  if (pumpInterval) {
    clearInterval(pumpInterval);
    pumpInterval = null;
  }
}

function pumpAudio() {
  if (!isPlaying || !player || !workletPort) return;
  while (chunksInFlight < MAX_CHUNKS_IN_FLIGHT) {
    const framesRead = Module._map_wasm_render_pcm_frames(player, pcmBufferPtr, RENDER_FRAME_COUNT);
    if (framesRead === 0) break;

    let rawBuffer = recycledBuffers.pop();
    if (!rawBuffer || rawBuffer.byteLength !== RENDER_FRAME_COUNT * 2 * 4) {
      rawBuffer = new ArrayBuffer(RENDER_FRAME_COUNT * 2 * 4);
    }

    const left = new Float32Array(rawBuffer, 0, RENDER_FRAME_COUNT);
    const right = new Float32Array(rawBuffer, RENDER_FRAME_COUNT * 4, RENDER_FRAME_COUNT);

    left.set(Module.HEAPF32.subarray(pcmBufferPtr >> 2, (pcmBufferPtr >> 2) + framesRead));
    right.set(Module.HEAPF32.subarray((pcmBufferPtr >> 2) + RENDER_FRAME_COUNT, (pcmBufferPtr >> 2) + RENDER_FRAME_COUNT + framesRead));

    workletPort.postMessage({
      type: "chunk",
      rawBuffer,
      frameCount: framesRead,
      left,
      right
    }, [rawBuffer]);

    chunksInFlight++;
  }
}

function startTelemetryLoop() {
  if (telemetryInterval) return;
  telemetryInterval = setInterval(() => {
    if (!player || !Module) return;
    Module._map_wasm_poll_telemetry(player, telemetryPtr);
    const raw = Module.HEAPF64.slice(telemetryPtr >> 3, (telemetryPtr >> 3) + 32);
    self.postMessage({
      type: "telemetry",
      data: Array.from(raw)
    });
  }, 33);
}

function stopTelemetryLoop() {
  if (telemetryInterval) {
    clearInterval(telemetryInterval);
    telemetryInterval = null;
  }
}
''';

String createWorkletBlobUrl() {
  final blob = web.Blob([kWorkletProcessorJs.toJS].toJS, web.BlobPropertyBag(type: 'application/javascript'));
  return web.URL.createObjectURL(blob);
}

String createEngineWorkerBlobUrl() {
  final blob = web.Blob([
    kMiniaudioJs.toJS,
    '\n'.toJS,
    kEngineWorkerJs.toJS,
  ].toJS, web.BlobPropertyBag(type: 'application/javascript'));
  return web.URL.createObjectURL(blob);
}
