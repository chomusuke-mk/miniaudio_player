import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../../miniaudio_player_bindings_generated.dart' as native;
import '../../api/audio_analysis_result.dart';
import '../../api/audio_device.dart';
import '../../api/buffered_range.dart';
import '../../api/dsp_config.dart';
import '../../api/player_state.dart';
import '../../api/silence_skip_config.dart';
import '../../api/visualizer_data.dart';
import '../../equalizer.dart';
import '../../ffi/native_types.dart';
import '../../reverb.dart';
import '../platform_backend.dart';

class NativePlayerBackend implements PlayerBackend, Finalizable {
  NativePlayerBackend([dynamic _]);

  Pointer<native.miniaudio_player_t> _playerHandle = nullptr;
  late final NativeCallable<native.miniaudio_player_completed_cbFunction>
      _completedCallable;
  late final NativeCallable<native.miniaudio_player_event_cbFunction>
      _eventCallable;

  Pointer<Uint8> _stagingPtr = nullptr;
  int _stagingCapacity = 0;
  Pointer<native.miniaudio_stream_status_t> _streamStatusPtr = nullptr;

  PlayerBackendListener? _listener;
  bool _isDisposed = false;

  void _ensureNotDisposed() {
    if (_isDisposed || _playerHandle == nullptr) {
      throw const MiniaudioPlayerException('Player is disposed');
    }
  }

  Pointer<Uint8> _ensureStagingBuffer(int minBytes) {
    if (_stagingCapacity < minBytes || _stagingPtr == nullptr) {
      if (_stagingPtr != nullptr) {
        calloc.free(_stagingPtr);
      }
      final newCap = minBytes < 65536 ? 65536 : minBytes;
      _stagingPtr = calloc<Uint8>(newCap);
      _stagingCapacity = newCap;
    }
    return _stagingPtr;
  }

  @override
  Pointer<native.miniaudio_player_t> get handle => _playerHandle;

  @override
  int get sampleRate => _playerHandle == nullptr
      ? 0
      : native.miniaudio_player_get_sample_rate(_playerHandle);

  @override
  int get channels => _playerHandle == nullptr
      ? 0
      : native.miniaudio_player_get_channels(_playerHandle);

  static final _finalizer = NativeFinalizer(
    Native.addressOf<
      NativeFunction<Int32 Function(Pointer<native.miniaudio_player_t>)>
    >(native.miniaudio_player_destroy).cast(),
  );

  @override
  void setListener(PlayerBackendListener listener) {
    _listener = listener;
  }

  @override
  int get pinnedHeadSize {
    if (_isDisposed || _playerHandle == nullptr) return 0;
    return native.miniaudio_player_stream_get_pinned_head_size(_playerHandle);
  }

  int _cachedMetaVersion = -1;
  Uint8List? _cachedMetaBytes;

  @override
  Uint8List? getMetaBytes() {
    if (_isDisposed || _playerHandle == nullptr) return _cachedMetaBytes;
    final currentVer =
        native.miniaudio_player_get_meta_bytes_version(_playerHandle);
    if (currentVer != _cachedMetaVersion) {
      _cachedMetaVersion = currentVer;
      final size = native.miniaudio_player_get_meta_bytes_size(_playerHandle);
      if (size > 0) {
        final ptr = calloc<Uint8>(size);
        try {
          final copied =
              native.miniaudio_player_copy_meta_bytes(_playerHandle, ptr, size);
          if (copied > 0) {
            _cachedMetaBytes = Uint8List.fromList(ptr.asTypedList(copied));
          } else {
            _cachedMetaBytes = null;
          }
        } finally {
          calloc.free(ptr);
        }
      } else {
        _cachedMetaBytes = null;
      }
    }
    return _cachedMetaBytes;
  }

  @override
  void init({
    required int sampleRate,
    required int channels,
    required int periodSize,
    String? playbackDeviceId,
  }) {
    final configPtr = calloc<native.miniaudio_player_config_t>();
    final outResultPtr = calloc<Int32>();
    Pointer<Utf8>? devIdPtr;

    try {
      configPtr.ref.sample_rate = sampleRate;
      configPtr.ref.channels = channels;
      configPtr.ref.period_size_in_frames = periodSize;

      _completedCallable =
          NativeCallable<native.miniaudio_player_completed_cbFunction>.listener(
        _onNativeCompleted,
      );
      configPtr.ref.on_completed = _completedCallable.nativeFunction;

      if (playbackDeviceId != null && playbackDeviceId.isNotEmpty) {
        devIdPtr = playbackDeviceId.toNativeUtf8();
        configPtr.ref.playback_device_id = devIdPtr.cast();
      }

      _playerHandle = native.miniaudio_player_create(configPtr, outResultPtr);
      final result = outResultPtr.value;

      if (_playerHandle == nullptr || result != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to create native miniaudio player: ${MapResult.describe(result)}',
          errorCode: result,
        );
      }

      _finalizer.attach(this, _playerHandle.cast(), detach: this);
      _streamStatusPtr = calloc<native.miniaudio_stream_status_t>();

      _eventCallable =
          NativeCallable<native.miniaudio_player_event_cbFunction>.listener(
        _onNativeEvent,
      );
      native.miniaudio_player_set_event_callback(
        _playerHandle,
        _eventCallable.nativeFunction,
        nullptr,
      );
    } finally {
      if (devIdPtr != null) calloc.free(devIdPtr);
      calloc.free(outResultPtr);
      calloc.free(configPtr);
    }
  }

  void _onNativeCompleted(Pointer<Void> _) {
    _listener?.onCompleted(true);
  }

  static double _f32(double v) => (v * 1e6).roundToDouble() / 1e6;

  void _onNativeEvent(
    Pointer<Void> userData,
    Pointer<native.map_event> eventPtr,
  ) {
    if (_isDisposed || eventPtr == nullptr || _listener == null) return;
    final event = eventPtr.ref;
    final type = event.type;

    if (type == native.map_event_type_t.MAP_EVENT_STATE.value) {
      final stateInt = event.data.state;
      PlaybackState newState;
      switch (stateInt) {
        case MapPlaybackState.stopped:
          newState = PlaybackState.stopped;
          break;
        case MapPlaybackState.playing:
          newState = PlaybackState.playing;
          break;
        case MapPlaybackState.paused:
          newState = PlaybackState.paused;
          break;
        case MapPlaybackState.completed:
          newState = PlaybackState.completed;
          break;
        case MapPlaybackState.buffering:
          newState = PlaybackState.buffering;
          break;
        case MapPlaybackState.error:
          newState = PlaybackState.error;
          break;
        case MapPlaybackState.opening:
          newState = PlaybackState.opening;
          break;
        default:
          newState = PlaybackState.stopped;
          break;
      }
      _listener?.onState(newState);
    } else if (type == native.map_event_type_t.MAP_EVENT_POSITION.value) {
      _listener?.onPosition(Duration(milliseconds: event.data.position_ms));
    } else if (type == native.map_event_type_t.MAP_EVENT_DURATION.value) {
      _listener?.onDuration(Duration(milliseconds: event.data.duration_ms));
    } else if (type == native.map_event_type_t.MAP_EVENT_IS_PLAYING.value) {
      _listener?.onPlaying(event.data.is_playing != 0);
    } else if (type == native.map_event_type_t.MAP_EVENT_IS_BUFFERING.value) {
      _listener?.onBuffering(event.data.is_buffering != 0);
    } else if (type == native.map_event_type_t.MAP_EVENT_IS_COMPLETED.value) {
      _listener?.onCompleted(event.data.is_completed != 0);
    } else if (type == native.map_event_type_t.MAP_EVENT_VOLUME.value) {
      _listener?.onVolume(event.data.volume);
    } else if (type == native.map_event_type_t.MAP_EVENT_RATE.value) {
      _listener?.onRate(event.data.rate);
    } else if (type == native.map_event_type_t.MAP_EVENT_PITCH.value) {
      _listener?.onPitch(event.data.pitch);
    } else if (type == native.map_event_type_t.MAP_EVENT_BITRATE.value) {
      _listener?.onBitrate(event.data.bitrate);
    } else if (type == native.map_event_type_t.MAP_EVENT_SILENCE_SAVED.value) {
      _listener?.onSilenceSaved(
        Duration(milliseconds: event.data.silence_saved_ms),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_BUFFERED_RANGE.value) {
      final b = event.data.buffered_range;
      _listener?.onBufferedRange(
        BufferedRange(
          start: Duration(milliseconds: b.start_ms),
          end: Duration(milliseconds: b.end_ms),
          duration: Duration(milliseconds: b.duration_ms),
          fillPercentage: b.fill_percentage.clamp(0.0, 1.0),
          percentage: b.stream_percentage.clamp(0.0, 1.0),
          isBuffering: b.is_buffering != 0,
          isEof: b.is_eof != 0,
        ),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_VISUALIZER.value) {
      final v = event.data.visualizer;
      final bands = <double>[];
      for (var i = 0; i < 10; i++) {
        bands.add(v.bands[i]);
      }
      _listener?.onVisualizer(
        VisualizerData(
          bands: bands,
          rms: v.rms,
          peak: v.peak,
          left: v.left,
          right: v.right,
        ),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_DEVICE.value) {
      final d = event.data.device;
      _listener?.onDevice(d.toAudioDevice());
    } else if (type ==
        native.map_event_type_t.MAP_EVENT_VISUALIZER_ENABLED.value) {
      _listener?.onVisualizerEnabled(event.data.visualizer_enabled != 0);
    } else if (type == native.map_event_type_t.MAP_EVENT_BUFFER_SIZE.value) {
      _listener?.onBufferSize(event.data.buffer_size);
    } else if (type == native.map_event_type_t.MAP_EVENT_SILENCE_CONFIG.value) {
      final sc = event.data.silence_config;
      _listener?.onSilenceConfig(
        SilenceSkipConfig.fromRaw(
          mode: sc.mode,
          thresholdDb: _f32(sc.threshold_db),
          minSilenceDurationMs: sc.min_silence_duration_ms,
          paddingMs: sc.padding_ms,
        ),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_EQUALIZER.value) {
      final eq = event.data.equalizer;
      _listener?.onEqualizer(
        Equalizer(
          hz31: _f32(eq.hz31),
          hz63: _f32(eq.hz63),
          hz125: _f32(eq.hz125),
          hz250: _f32(eq.hz250),
          hz500: _f32(eq.hz500),
          hz1k: _f32(eq.hz1k),
          hz2k: _f32(eq.hz2k),
          hz4k: _f32(eq.hz4k),
          hz8k: _f32(eq.hz8k),
          hz16k: _f32(eq.hz16k),
        ),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_PREAMP.value) {
      _listener?.onPreamp(_f32(event.data.preamp_db));
    } else if (type == native.map_event_type_t.MAP_EVENT_REPLAY_GAIN.value) {
      final rg = event.data.replay_gain;
      _listener?.onReplayGain(
        ReplayGainConfig(
          gainDb: _f32(rg.gain_db),
          peak: _f32(rg.peak),
          preventClipping: rg.prevent_clipping != 0,
          enabled: rg.enabled != 0,
        ),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_BALANCE.value) {
      _listener?.onBalance(_f32(event.data.balance));
    } else if (type == native.map_event_type_t.MAP_EVENT_MONO.value) {
      _listener?.onMono(event.data.mono_enabled != 0);
    } else if (type == native.map_event_type_t.MAP_EVENT_CROSSFEED.value) {
      final cfInt = event.data.crossfeed_mode;
      final cf = switch (cfInt) {
        1 => CrossfeedMode.moffatBauer,
        2 => CrossfeedMode.chuMoy,
        _ => CrossfeedMode.off,
      };
      _listener?.onCrossfeed(cf);
    } else if (type == native.map_event_type_t.MAP_EVENT_SPATIALIZER.value) {
      final sp = event.data.spatializer;
      _listener?.onSpatializer(
        enabled: sp.enabled != 0,
        width: _f32(sp.width),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_REVERB.value) {
      final rv = event.data.reverb;
      _listener?.onReverb(
        Reverb(
          enabled: rv.enabled != 0,
          roomSize: _f32(rv.room_size),
          damping: _f32(rv.damping),
          width: _f32(rv.width),
          wet: _f32(rv.wet),
          dry: _f32(rv.dry),
        ),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_LIMITER.value) {
      _listener?.onLimiter(event.data.limiter_enabled != 0);
    } else if (type == native.map_event_type_t.MAP_EVENT_ERROR.value) {
      _listener?.onError(
        'Native error: ${event.data.error_code}',
        event.data.error_code,
      );
    }
  }

  // --- Unified Stream Lifecycle ---

  @override
  Future<void> beginOpen() async {
    _ensureNotDisposed();
    _cachedMetaVersion = -1;
    _cachedMetaBytes = null;
    final res = native.miniaudio_player_begin_open(_playerHandle);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to begin open: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
  }

  @override
  Future<int> openStreamEx({
    required Uint8List initialBytes,
    Uint8List? tailBytes,
    required int totalSize,
    required bool isLive,
    required int bufferCapacityBytes,
    int encodingFormat = 0,
  }) async {
    _ensureNotDisposed();
    if (initialBytes.isEmpty) {
      return MapResult.errorInvalidArgs;
    }
    _cachedMetaVersion = -1;
    _cachedMetaBytes = null;

    final headPtr = malloc.allocate<Uint8>(initialBytes.length);
    Pointer<Uint8> tailPtr = nullptr;
    try {
      headPtr.asTypedList(initialBytes.length).setAll(0, initialBytes);
      final int tailLen = tailBytes?.length ?? 0;
      if (tailBytes != null && tailLen > 0) {
        tailPtr = malloc.allocate<Uint8>(tailLen);
        tailPtr.asTypedList(tailLen).setAll(0, tailBytes);
      }
      final res = native.miniaudio_player_open_stream_ex(
        _playerHandle,
        headPtr.cast(),
        initialBytes.length,
        tailPtr == nullptr ? nullptr : tailPtr.cast(),
        tailLen,
        totalSize,
        isLive ? 1 : 0,
        bufferCapacityBytes,
        encodingFormat,
      );
      if (res == MapResult.success) {
        final durMs = native.miniaudio_player_get_duration_ms(_playerHandle);
        final bitrate = native.miniaudio_player_get_bitrate(_playerHandle);
        _listener?.onDuration(Duration(milliseconds: durMs > 0 ? durMs : 0));
        _listener?.onBitrate(bitrate > 0 ? bitrate : 0);
        _listener?.onPosition(Duration.zero);
        _listener?.onCompleted(false);
      }
      return res;
    } finally {
      malloc.free(headPtr);
      if (tailPtr != nullptr) {
        malloc.free(tailPtr);
      }
    }
  }

  @override
  int streamFeed(Uint8List chunk) {
    if (_isDisposed || _playerHandle == nullptr || chunk.isEmpty) {
      return MapResult.errorInvalidState;
    }
    final ptr = _ensureStagingBuffer(chunk.length);
    ptr.asTypedList(chunk.length).setAll(0, chunk);
    return native.miniaudio_player_stream_feed(
      _playerHandle,
      ptr.cast(),
      chunk.length,
    );
  }

  @override
  int streamFlush(int newStreamOffset) {
    if (_isDisposed || _playerHandle == nullptr) {
      return MapResult.errorInvalidState;
    }
    return native.miniaudio_player_stream_flush(_playerHandle, newStreamOffset);
  }

  @override
  int streamSeek(int positionMs, int newStreamOffset) {
    if (_isDisposed || _playerHandle == nullptr) {
      return MapResult.errorInvalidState;
    }
    final durationMs = native.miniaudio_player_get_duration_ms(_playerHandle);
    var clampedMs = positionMs < 0 ? 0 : positionMs;
    if (durationMs > 0 && clampedMs > durationMs) {
      clampedMs = durationMs;
    }
    final res = native.miniaudio_player_stream_seek(
      _playerHandle,
      clampedMs,
      newStreamOffset,
    );
    if (res >= 0) {
      final isComp = native.miniaudio_player_is_completed(_playerHandle) != 0;
      _listener?.onCompleted(isComp);
      if (!isComp) {
        _listener?.onPosition(Duration(milliseconds: clampedMs));
      }
    }
    return res;
  }

  @override
  int streamGetSeekByte(int positionMs) {
    if (_isDisposed || _playerHandle == nullptr) return -1;
    return native.miniaudio_player_stream_get_seek_byte(
      _playerHandle,
      positionMs,
    );
  }

  @override
  int getAudioDataOffset() {
    if (_isDisposed || _playerHandle == nullptr) return 0;
    return native.miniaudio_player_get_audio_data_offset(_playerHandle);
  }

  @override
  int streamEnd() {
    if (_isDisposed || _playerHandle == nullptr) {
      return MapResult.errorInvalidState;
    }
    return native.miniaudio_player_stream_end(_playerHandle);
  }

  @override
  void notifyOpenError(int errorCode) {
    if (_isDisposed || _playerHandle == nullptr) return;
    final int code = errorCode < 0 ? errorCode : MapResult.errorDecodeFailed;
    native.miniaudio_player_open_stream_ex(
      _playerHandle,
      nullptr,
      0,
      nullptr,
      0,
      0,
      0,
      0,
      code,
    );
  }

  @override
  BackendStreamStatus? getStreamStatus() {
    if (_isDisposed || _playerHandle == nullptr || _streamStatusPtr == nullptr) {
      return null;
    }
    final res = native.miniaudio_player_stream_get_status(
      _playerHandle,
      _streamStatusPtr,
    );
    if (res != MapResult.success) return null;
    final ref = _streamStatusPtr.ref;
    return BackendStreamStatus(
      bufferCapacity: ref.buffer_capacity,
      bufferFill: ref.buffer_fill,
      fillPercentage: ref.fill_percentage,
      isBuffering: ref.is_buffering != 0,
      isEof: ref.is_eof != 0,
      readCursorByte: ref.read_cursor_byte,
      rangeStart: ref.range_start,
      rangeEnd: ref.range_end,
    );
  }

  // --- Transport Controls ---

  @override
  Future<void> play() async {
    _ensureNotDisposed();
    final res = native.miniaudio_player_play(_playerHandle);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to start playback: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _listener?.onState(PlaybackState.playing);
    _listener?.onCompleted(false);
    _listener?.onPlaying(true);
  }

  @override
  Future<void> pause() async {
    _ensureNotDisposed();
    final res = native.miniaudio_player_pause(_playerHandle);
    if (res == MapResult.errorInvalidState) {
      return;
    }
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to pause playback: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _listener?.onPlaying(false);
    _listener?.onState(PlaybackState.paused);
  }

  @override
  Future<void> stop() async {
    _ensureNotDisposed();
    final res = native.miniaudio_player_stop(_playerHandle);
    if (res != MapResult.success && res != MapResult.errorInvalidState) {
      throw MiniaudioPlayerException(
        'Failed to stop playback: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _listener?.onPlaying(false);
    _listener?.onCompleted(false);
    _listener?.onPosition(Duration.zero);
    _listener?.onState(PlaybackState.stopped);
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureNotDisposed();
    final durationMs = native.miniaudio_player_get_duration_ms(_playerHandle);
    var targetMs = position.inMilliseconds;
    if (targetMs < 0) targetMs = 0;
    if (durationMs > 0 && targetMs > durationMs) {
      targetMs = durationMs;
    }
    final res = native.miniaudio_player_seek(_playerHandle, targetMs);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to seek: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    final isComp = native.miniaudio_player_is_completed(_playerHandle) != 0;
    _listener?.onCompleted(isComp);
    if (!isComp) {
      _listener?.onPosition(Duration(milliseconds: targetMs));
    }
  }

  // --- Audio & DSP Controls ---

  @override
  void setVolume(double volume) {
    native.miniaudio_player_set_volume(_playerHandle, volume);
  }

  @override
  void setRate(double rate) {
    native.miniaudio_player_set_rate(_playerHandle, rate);
  }

  @override
  void setPitch(double pitch) {
    native.miniaudio_player_set_pitch(_playerHandle, pitch);
  }

  @override
  void setPan(double pan) {
    native.miniaudio_player_set_balance(_playerHandle, pan);
  }

  @override
  void setBufferSize(int frames) {
    native.miniaudio_player_set_buffer_size(_playerHandle, frames);
  }

  @override
  void setEqualizerBand(int bandIndex, double gainDb) {
    native.miniaudio_player_set_equalizer_band(
      _playerHandle,
      bandIndex,
      gainDb,
    );
  }

  @override
  void setEqualizer(Equalizer params) {
    _ensureNotDisposed();
    final gainsDb = params.toList();
    final eqPtr = calloc<native.miniaudio_player_equalizer_params_t>();
    try {
      eqPtr.ref.hz31 = gainsDb[0];
      eqPtr.ref.hz63 = gainsDb[1];
      eqPtr.ref.hz125 = gainsDb[2];
      eqPtr.ref.hz250 = gainsDb[3];
      eqPtr.ref.hz500 = gainsDb[4];
      eqPtr.ref.hz1k = gainsDb[5];
      eqPtr.ref.hz2k = gainsDb[6];
      eqPtr.ref.hz4k = gainsDb[7];
      eqPtr.ref.hz8k = gainsDb[8];
      eqPtr.ref.hz16k = gainsDb[9];

      final res = native.miniaudio_player_set_equalizer(_playerHandle, eqPtr);
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to set equalizer: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }
    } finally {
      calloc.free(eqPtr);
    }
  }

  @override
  void setReverb({
    required bool enabled,
    required double roomSize,
    required double damping,
    required double width,
    required double wet,
    required double dry,
  }) {
    _ensureNotDisposed();
    native.miniaudio_player_set_reverb(
      _playerHandle,
      enabled ? 1 : 0,
      roomSize,
      damping,
      width,
      wet,
      dry,
    );
  }

  @override
  void setCrossfeed(CrossfeedMode mode) {
    _ensureNotDisposed();
    native.miniaudio_player_set_crossfeed(_playerHandle, mode.index);
  }

  @override
  void setLimiterEnabled(bool enabled) {
    _ensureNotDisposed();
    native.miniaudio_player_set_limiter(_playerHandle, enabled ? 1 : 0);
  }

  @override
  void setSilenceSkip(SilenceSkipConfig config) {
    _ensureNotDisposed();
    final threshold = config.thresholdDb.clamp(-90.0, -10.0);
    final minMs = config.minSilenceDuration.inMilliseconds.clamp(50, 5000);
    final maxPad = minMs ~/ 2;
    final padMs = config.padding.inMilliseconds.clamp(0, maxPad);

    final configPtr = calloc<native.miniaudio_player_silence_config_t>();
    try {
      configPtr.ref.mode = config.mode.value;
      configPtr.ref.threshold_db = threshold;
      configPtr.ref.min_silence_duration_ms = minMs;
      configPtr.ref.padding_ms = padMs;
      final res = native.miniaudio_player_set_silence_config(
        _playerHandle,
        configPtr,
      );
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to set silence config: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }
    } finally {
      calloc.free(configPtr);
    }
  }

  @override
  void setVisualizerEnabled(bool enabled) {
    native.miniaudio_player_set_visualizer_enabled(
      _playerHandle,
      enabled ? 1 : 0,
    );
  }

  @override
  void setPreamp(double preampDb) {
    _ensureNotDisposed();
    native.miniaudio_player_set_preamp(_playerHandle, preampDb);
  }

  @override
  void setReplayGain(ReplayGainConfig config) {
    _ensureNotDisposed();
    if (!config.enabled) {
      native.miniaudio_player_clear_replay_gain(_playerHandle);
    } else {
      native.miniaudio_player_set_replay_gain(
        _playerHandle,
        config.gainDb,
        config.peak > 0 ? config.peak : 0.0,
        config.preventClipping ? 1 : 0,
      );
    }
  }

  @override
  void setBalance(double balance) {
    _ensureNotDisposed();
    native.miniaudio_player_set_balance(_playerHandle, balance.clamp(-1.0, 1.0));
  }

  @override
  void setMono(bool enabled) {
    _ensureNotDisposed();
    native.miniaudio_player_set_mono(_playerHandle, enabled ? 1 : 0);
  }

  @override
  void setSpatializer({required bool enabled, required double width}) {
    _ensureNotDisposed();
    native.miniaudio_player_set_spatializer(
      _playerHandle,
      enabled ? 1 : 0,
      width,
    );
  }

  @override
  void setIcyMeta(Uint8List data) {
    _ensureNotDisposed();
    if (data.isEmpty) return;
    final ptr = _ensureStagingBuffer(data.length);
    ptr.asTypedList(data.length).setAll(0, data);
    native.miniaudio_player_set_icy_meta(_playerHandle, ptr, data.length);
  }

  @override
  void probeTail(Uint8List data, int tailOffset) {
    _ensureNotDisposed();
    if (data.isEmpty) return;
    final ptr = _ensureStagingBuffer(data.length);
    ptr.asTypedList(data.length).setAll(0, data);
    native.miniaudio_player_probe_tail(
      _playerHandle,
      ptr,
      data.length,
      tailOffset,
    );
    final durMs = native.miniaudio_player_get_duration_ms(_playerHandle);
    final bitrate = native.miniaudio_player_get_bitrate(_playerHandle);
    if (durMs > 0) {
      _listener?.onDuration(Duration(milliseconds: durMs));
    }
    if (bitrate > 0) {
      _listener?.onBitrate(bitrate);
    }
  }

  @override
  Future<void> setDevice(String deviceId) async {
    final devPtr = deviceId.isEmpty ? nullptr : deviceId.toNativeUtf8();
    try {
      final res = native.miniaudio_player_set_device(
        _playerHandle,
        devPtr == nullptr ? nullptr : devPtr.cast(),
      );
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to set device: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }
    } finally {
      if (devPtr != nullptr) calloc.free(devPtr);
    }
  }

  @override
  AudioDevice getCurrentDevice() {
    final devPtr = calloc<native.miniaudio_device_info_t>();
    try {
      final res = native.miniaudio_player_get_current_device(
        _playerHandle,
        devPtr,
      );
      if (res == MapResult.success) {
        return devPtr.ref.toAudioDevice();
      }
      return AudioDevice.auto;
    } finally {
      calloc.free(devPtr);
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _finalizer.detach(this);
    _completedCallable.close();
    _eventCallable.close();
    if (_stagingPtr != nullptr) {
      calloc.free(_stagingPtr);
      _stagingPtr = nullptr;
      _stagingCapacity = 0;
    }
    if (_streamStatusPtr != nullptr) {
      calloc.free(_streamStatusPtr);
      _streamStatusPtr = nullptr;
    }
    if (_playerHandle != nullptr) {
      native.miniaudio_player_destroy(_playerHandle);
      _playerHandle = nullptr;
    }
  }
}

class NativePlatformService implements PlatformService {
  final StreamController<List<AudioDevice>> _deviceController =
      StreamController<List<AudioDevice>>.broadcast();

  @override
  Future<List<AudioDevice>> getAudioDevices() async {
    final outDevicesPtr = calloc<Pointer<native.miniaudio_device_info_t>>();
    final outCountPtr = calloc<Uint32>();

    try {
      final res =
          native.miniaudio_player_get_devices(outDevicesPtr, outCountPtr);
      if (res != MapResult.success) {
        return [AudioDevice.auto];
      }

      final count = outCountPtr.value;
      final devicesPtr = outDevicesPtr.value;
      final list = <AudioDevice>[AudioDevice.auto];

      for (var i = 0; i < count; i++) {
        final d = devicesPtr[i];
        list.add(d.toAudioDevice());
      }

      if (devicesPtr != nullptr) {
        native.miniaudio_player_free_devices(devicesPtr, count);
      }
      return list;
    } finally {
      calloc.free(outDevicesPtr);
      calloc.free(outCountPtr);
    }
  }

  @override
  Stream<List<AudioDevice>> getAudioDevicesStream() => _deviceController.stream;

  @override
  List<AudioDevice> getAudioDevicesSync() {
    final outDevicesPtr = calloc<Pointer<native.miniaudio_device_info_t>>();
    final outCountPtr = calloc<Uint32>();

    try {
      final res =
          native.miniaudio_player_get_devices(outDevicesPtr, outCountPtr);
      if (res != MapResult.success) {
        return [AudioDevice.auto];
      }

      final count = outCountPtr.value;
      final devicesPtr = outDevicesPtr.value;
      final list = <AudioDevice>[AudioDevice.auto];

      for (var i = 0; i < count; i++) {
        final d = devicesPtr[i];
        list.add(d.toAudioDevice());
      }

      if (devicesPtr != nullptr) {
        native.miniaudio_player_free_devices(devicesPtr, count);
      }
      return list;
    } finally {
      calloc.free(outDevicesPtr);
      calloc.free(outCountPtr);
    }
  }

  @override
  Future<AudioAnalysisResult> analyzeAudio(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) async {
    final completer = Completer<AudioAnalysisResult>();
    var flags = 0;
    if (replayGain) {
      flags |= native.miniaudio_analysis_flags_t.MAP_ANALYSIS_FLAG_REPLAY_GAIN.value;
    }
    if (waveform) {
      flags |= native.miniaudio_analysis_flags_t.MAP_ANALYSIS_FLAG_WAVEFORM.value;
    }

    late final NativeCallable<
        native.miniaudio_audio_analysis_completed_cbFunction> callback;
    callback = NativeCallable<
        native.miniaudio_audio_analysis_completed_cbFunction>.listener(
      (
        Pointer<native.miniaudio_audio_analysis_result_t> resultPtr,
        Pointer<Void> userData,
      ) {
        try {
          if (resultPtr == nullptr) {
            completer.completeError(
              const MiniaudioPlayerException('Null result received'),
            );
            return;
          }
          final res = resultPtr.ref;
          if (res.status == MapResult.success) {
            ReplayGainResult? rg;
            if (res.has_replay_gain != 0) {
              rg = ReplayGainResult(
                gainDb: res.replay_gain.gain_db,
                peak: res.replay_gain.peak,
                lufs: res.replay_gain.lufs,
              );
            }
            WaveformResult? wf;
            if (res.has_waveform != 0 && res.waveform.points != nullptr) {
              final count = res.waveform.point_count;
              final pts = List<double>.generate(
                count,
                (i) => res.waveform.points[i],
                growable: false,
              );
              wf = WaveformResult(points: pts);
            }
            completer.complete(
              AudioAnalysisResult(
                duration: Duration(milliseconds: res.duration_ms),
                sampleRate: res.sample_rate,
                channels: res.channels,
                bitrate: res.bitrate,
                peak: res.peak,
                replayGain: rg,
                waveform: wf,
              ),
            );
          } else {
            completer.completeError(
              MiniaudioPlayerException(
                'Analysis failed: ${res.status}',
                errorCode: res.status,
              ),
            );
          }
        } finally {
          if (resultPtr != nullptr) {
            native.miniaudio_player_free_audio_analysis(resultPtr, 1);
          }
          callback.close();
        }
      },
    );

    final configPtr = calloc<native.miniaudio_audio_analysis_config_t>();
    configPtr.ref.flags = flags;
    configPtr.ref.target_lufs = targetLufs;
    configPtr.ref.waveform_points = waveformPoints;
    final pathPtr = filePath.toNativeUtf8();

    try {
      final res = native.miniaudio_player_analyze_audio_async(
        pathPtr.cast(),
        configPtr,
        callback.nativeFunction,
        nullptr,
      );
      if (res != MapResult.success) {
        callback.close();
        throw MiniaudioPlayerException(
          'Failed to start analysis: $res',
          errorCode: res,
        );
      }
    } finally {
      calloc.free(pathPtr);
      calloc.free(configPtr);
    }

    return completer.future;
  }

  @override
  AudioAnalysisResult analyzeAudioSync(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) {
    var flags = 0;
    if (replayGain) {
      flags |= native.miniaudio_analysis_flags_t.MAP_ANALYSIS_FLAG_REPLAY_GAIN.value;
    }
    if (waveform) {
      flags |= native.miniaudio_analysis_flags_t.MAP_ANALYSIS_FLAG_WAVEFORM.value;
    }

    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    final pathPtr = path.toNativeUtf8();
    final configPtr = calloc<native.miniaudio_audio_analysis_config_t>();
    final outResultPtr = calloc<native.miniaudio_audio_analysis_result_t>();

    try {
      configPtr.ref.flags = flags;
      configPtr.ref.target_lufs = targetLufs;
      configPtr.ref.waveform_points = waveformPoints;

      final res = native.miniaudio_player_analyze_audio(
        pathPtr.cast(),
        configPtr,
        outResultPtr,
      );
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to analyze audio: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }

      final out = outResultPtr.ref;
      final duration = Duration(milliseconds: out.duration_ms);
      final sampleRate = out.sample_rate;
      final channels = out.channels;
      final bitrate = out.bitrate;
      final peak = out.peak;

      ReplayGainResult? replayGainResult;
      if (out.has_replay_gain != 0) {
        replayGainResult = ReplayGainResult(
          gainDb: out.replay_gain.gain_db,
          peak: out.replay_gain.peak,
          lufs: out.replay_gain.lufs,
        );
      }

      WaveformResult? waveformResult;
      if (out.has_waveform != 0 && out.waveform.points != nullptr) {
        final count = out.waveform.point_count;
        final points = List<double>.generate(
          count,
          (i) => out.waveform.points[i],
          growable: false,
        );
        waveformResult = WaveformResult(points: points);
      }

      return AudioAnalysisResult(
        duration: duration,
        sampleRate: sampleRate,
        channels: channels,
        bitrate: bitrate,
        peak: peak,
        replayGain: replayGainResult,
        waveform: waveformResult,
      );
    } finally {
      if (outResultPtr != nullptr) {
        native.miniaudio_player_free_audio_analysis(outResultPtr, 0);
        calloc.free(outResultPtr);
      }
      calloc.free(pathPtr);
      calloc.free(configPtr);
    }
  }

  @override
  Future<AudioAnalysisResult> analyzeAudioMemory(
    Uint8List bytes, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) async {
    final configPtr = calloc<native.miniaudio_audio_analysis_config_t>();
    configPtr.ref.flags = (replayGain
            ? native.miniaudio_analysis_flags_t.MAP_ANALYSIS_FLAG_REPLAY_GAIN.value
            : 0) |
        (waveform
            ? native.miniaudio_analysis_flags_t.MAP_ANALYSIS_FLAG_WAVEFORM.value
            : 0);
    configPtr.ref.target_lufs = targetLufs;
    configPtr.ref.waveform_points = waveformPoints;

    final resultPtr = calloc<native.miniaudio_audio_analysis_result_t>();
    final dataPtr = calloc<Uint8>(bytes.length);
    dataPtr.asTypedList(bytes.length).setAll(0, bytes);

    try {
      final status = native.miniaudio_player_analyze_audio_memory(
        dataPtr.cast(),
        bytes.length,
        configPtr,
        resultPtr,
      );
      if (status != MapResult.success) {
        throw MiniaudioPlayerException(
          'Analysis memory failed: $status',
          errorCode: status,
        );
      }
      final res = resultPtr.ref;
      ReplayGainResult? rg;
      if (res.has_replay_gain != 0) {
        rg = ReplayGainResult(
          gainDb: res.replay_gain.gain_db,
          peak: res.replay_gain.peak,
          lufs: res.replay_gain.lufs,
        );
      }
      WaveformResult? wf;
      if (res.has_waveform != 0 && res.waveform.points != nullptr) {
        final count = res.waveform.point_count;
        final pts = List<double>.generate(
          count,
          (i) => res.waveform.points[i],
          growable: false,
        );
        wf = WaveformResult(points: pts);
      }
      return AudioAnalysisResult(
        duration: Duration(milliseconds: res.duration_ms),
        sampleRate: res.sample_rate,
        channels: res.channels,
        bitrate: res.bitrate,
        peak: res.peak,
        replayGain: rg,
        waveform: wf,
      );
    } finally {
      native.miniaudio_player_free_audio_analysis(resultPtr, 0);
      calloc.free(resultPtr);
      calloc.free(dataPtr);
      calloc.free(configPtr);
    }
  }

  @override
  void setLogLevel(int level) {
    native.miniaudio_player_set_log_level(level);
  }
}

PlayerBackend createPlayerBackend([dynamic player]) =>
    NativePlayerBackend(player);
PlatformService getPlatformService() => NativePlatformService();
