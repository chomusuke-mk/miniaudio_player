// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../equalizer.dart';
import '../ffi/native_types.dart';
import 'audio_device.dart';
import 'audio_source.dart';
import 'miniaudio_player.dart';
import 'player_exception.dart';
import 'silence_skip_config.dart';
import 'dsp_config.dart';
import 'track_metadata.dart';
import '../reverb.dart';
import '../network/network_audio_streamer.dart';

/// Action interface executing asynchronous playback, seeking, volume, and DSP controls.
class PlayerAction {
  final MiniaudioPlayer _player;
  final void Function(Duration position) _onOptimisticSeek;
  NetworkAudioStreamer? _activeStreamer;

  PlayerAction(
    this._player, {
    required void Function(Duration) onOptimisticSeek,
  }) : _onOptimisticSeek = onOptimisticSeek;

  void _stopActiveStreamer() {
    _activeStreamer?.dispose();
    _activeStreamer = null;
  }

  /// Disposes any active network streaming sessions.
  void dispose() {
    _stopActiveStreamer();
  }

  /// Prepares an audio source for playback.
  ///
  /// Accepts:
  /// - An [AudioSource] instance ([FileAudioSource], [AssetAudioSource], [MemoryAudioSource], [NetworkAudioSource], [LiveStreamAudioSource]).
  /// - A [String] path or URI (`file://...`, `asset://...`, `assets/...`, `http://...`, `https://...`, or standard file path).
  /// - A [Uri] object.
  /// - A [Uint8List] containing raw audio file bytes in memory.
  /// - A [FileSystemEntity] (e.g. [File]).
  Future<void> open(
    dynamic source, {
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
    Duration? bufferBehind,
    Duration? bufferLocalDuration,
    Duration? bufferNetworkDuration,
    Duration? bufferLiveStreamDuration,
    int? bufferLocalInSeconds,
    int? bufferNetworkInSeconds,
    int? bufferStreamsInSeconds,
  }) async {
    _player.ensureNotDisposed();

    final effectiveAhead = bufferAhead;
    final effectiveBehind = bufferBehind;

    if (source is AudioSource) {
      switch (source) {
        case FileAudioSource s:
          return openFile(s.filePath);
        case AssetAudioSource s:
          return openAsset(s.assetKey);
        case MemoryAudioSource s:
          return openMemory(s.bytes);
        case NetworkAudioSource s:
          return openUrl(
            s.uri,
            headers: headers ?? s.headers,
            bufferAhead: effectiveAhead ?? s.bufferAhead,
            bufferBehind: effectiveBehind,
            bufferNetworkDuration: bufferNetworkDuration,
            bufferNetworkInSeconds: bufferNetworkInSeconds,
          );
        case LiveStreamAudioSource s:
          return openUrl(
            s.uri,
            headers: headers ?? s.headers,
            isLive: true,
            bufferAhead: effectiveAhead ?? s.jitterBuffer,
            bufferBehind: effectiveBehind,
            bufferLiveStreamDuration: bufferLiveStreamDuration,
            bufferStreamsInSeconds: bufferStreamsInSeconds,
          );
      }
    } else if (source is Uint8List) {
      return openMemory(source);
    } else if (source is Uri) {
      final str = source.toString();
      if (str.startsWith('http://') || str.startsWith('https://')) {
        return openUrl(
          source,
          headers: headers,
          isLive: isLive,
          bufferAhead: effectiveAhead,
          bufferBehind: effectiveBehind,
          bufferNetworkDuration: bufferNetworkDuration,
          bufferLiveStreamDuration: bufferLiveStreamDuration,
          bufferNetworkInSeconds: bufferNetworkInSeconds,
          bufferStreamsInSeconds: bufferStreamsInSeconds,
        );
      } else if (str.startsWith('asset://') || str.startsWith('assets/')) {
        return openAsset(str);
      } else if (source.isScheme('file')) {
        return openFile(source.toFilePath());
      } else {
        return openFile(str);
      }
    } else if (source is String) {
      final trimmed = source.trim();
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        return openUrl(
          Uri.parse(trimmed),
          headers: headers,
          isLive: isLive,
          bufferAhead: effectiveAhead,
          bufferBehind: effectiveBehind,
          bufferNetworkDuration: bufferNetworkDuration,
          bufferLiveStreamDuration: bufferLiveStreamDuration,
          bufferNetworkInSeconds: bufferNetworkInSeconds,
          bufferStreamsInSeconds: bufferStreamsInSeconds,
        );
      } else if (trimmed.startsWith('asset://') || trimmed.startsWith('assets/')) {
        return openAsset(trimmed);
      } else if (trimmed.startsWith('file://')) {
        return openFile(Uri.parse(trimmed).toFilePath());
      } else {
        return openFile(trimmed);
      }
    } else if (source is FileSystemEntity) {
      return openFile(source.path);
    } else {
      throw ArgumentError.value(source, 'source', 'Unsupported audio source type');
    }
  }

  /// Opens a local filesystem audio file.
  Future<void> openFile(String filePath) async {
    _player.ensureNotDisposed();
    _stopActiveStreamer();

    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    final file = File(path);
    final totalBytes = file.existsSync() ? file.lengthSync() : -1;
    List<int> headerBytes = const [];
    if (file.existsSync()) {
      try {
        final raf = file.openSync(mode: FileMode.read);
        headerBytes = raf.readSync(min(64, totalBytes > 0 ? totalBytes : 64));
        raf.closeSync();
      } catch (_) {}
    }

    final pathPtr = path.toNativeUtf8();
    try {
      final res = native.miniaudio_player_open_file(
        _player.handle,
        pathPtr.cast(),
      );
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to open audio file: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }

      _player.pollAndEmit(force: true);

      final codec = AudioCodec.detect(headerBytes);
      final format = AudioFormat.fromCodec(codec);
      final audioOffset = native.miniaudio_player_get_audio_data_offset(_player.handle);
      final metadata = AudioTrackMetadata(
        codec: codec,
        format: format,
        formatName: codec.name,
        duration: _player.state.duration,
        totalBytes: totalBytes,
        bitrate: _player.state.audioBitrate,
        sampleRate: _player.sampleRate,
        channels: _player.channels,
        isNetwork: false,
        isLiveStream: false,
        uri: Uri.file(path),
        audioDataOffset: audioOffset > 0 ? audioOffset : 0,
      );
      _player.setTrackMetadata(metadata);
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Opens an audio file directly from an in-memory byte buffer (RAM).
  ///
  /// Zero disk I/O, zero temporary files, instantaneous startup.
  Future<void> openMemory(Uint8List bytes, {Uri? uri}) async {
    _player.ensureNotDisposed();
    if (bytes.isEmpty) {
      throw const MiniaudioPlayerException('Cannot open empty byte buffer');
    }
    _stopActiveStreamer();

    final ptr = malloc.allocate<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);

    final res = native.miniaudio_player_open_memory(
      _player.handle,
      ptr.cast(),
      bytes.length,
      1, // Native C engine takes ownership and frees with free() on close
    );
    if (res != MapResult.success) {
      malloc.free(ptr);
      throw MiniaudioPlayerException(
        'Failed to open audio from memory: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }

    _player.pollAndEmit(force: true);

    final codec = AudioCodec.detect(bytes.sublist(0, min(64, bytes.length)));
    final format = AudioFormat.fromCodec(codec);
    final audioOffset = native.miniaudio_player_get_audio_data_offset(_player.handle);
    final metadata = AudioTrackMetadata(
      codec: codec,
      format: format,
      formatName: codec.name,
      duration: _player.state.duration,
      totalBytes: bytes.length,
      bitrate: _player.state.audioBitrate,
      sampleRate: _player.sampleRate,
      channels: _player.channels,
      isNetwork: false,
      isLiveStream: false,
      uri: uri,
      audioDataOffset: audioOffset > 0 ? audioOffset : 0,
    );
    _player.setTrackMetadata(metadata);
  }

  /// Opens an asset directly without copying to disk.
  ///
  /// Uses [loader] or [MiniaudioPlayerGlobalConfig.assetLoader] if defined,
  /// otherwise falls back to filesystem candidate matching.
  Future<void> openAsset(
    String assetPath, {
    String? package,
    AssetBytesLoader? loader,
  }) async {
    _player.ensureNotDisposed();
    final cleanKey = assetPath.replaceFirst(RegExp(r'^asset(s)?://'), '');
    final resolvedKey = package != null ? 'packages/$package/$cleanKey' : cleanKey;
    Uint8List? bytes;

    final effectiveLoader = loader ?? MiniaudioPlayerGlobalConfig.assetLoader;
    if (effectiveLoader != null) {
      try {
        bytes = await effectiveLoader(resolvedKey);
      } catch (e) {
        throw MiniaudioPlayerException('Failed to load asset "$resolvedKey": $e');
      }
    } else {
      final candidates = [
        resolvedKey,
        cleanKey,
        'assets/$cleanKey',
        'example/assets/$cleanKey',
        'example/assets/music/$cleanKey',
      ];
      for (final candidate in candidates) {
        final f = File(candidate);
        if (f.existsSync()) {
          bytes = await f.readAsBytes();
          break;
        }
      }
    }

    if (bytes == null || bytes.isEmpty) {
      throw MiniaudioPlayerException(
        'Asset not found: "$resolvedKey". Configure MiniaudioPlayerGlobalConfig.assetLoader for Flutter assets.',
        errorCode: MapResult.errorFileNotFound,
      );
    }

    await openMemory(bytes, uri: Uri.parse('asset://$resolvedKey'));
  }

  /// Opens a remote audio URL (HTTP/HTTPS) or live stream with progressive streaming.
  /// Accepts either a [Uri] or a [String].
  Future<void> openUrl(
    dynamic urlOrUri, {
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
    Duration? bufferBehind,
    Duration? bufferNetworkDuration,
    Duration? bufferLiveStreamDuration,
    int? bufferNetworkInSeconds,
    int? bufferStreamsInSeconds,
  }) async {
    _player.ensureNotDisposed();
    _stopActiveStreamer();

    final Uri uri;
    if (urlOrUri is Uri) {
      uri = urlOrUri;
    } else if (urlOrUri is String) {
      uri = Uri.parse(urlOrUri);
    } else {
      throw ArgumentError.value(urlOrUri, 'urlOrUri', 'Expected Uri or String');
    }

    final effectiveBufferAhead = bufferAhead ??
        (isLive
            ? (bufferLiveStreamDuration ??
                (bufferStreamsInSeconds != null
                    ? Duration(seconds: bufferStreamsInSeconds)
                    : MiniaudioPlayerGlobalConfig().bufferLiveStreamDuration))
            : (bufferNetworkDuration ??
                (bufferNetworkInSeconds != null
                    ? Duration(seconds: bufferNetworkInSeconds)
                    : MiniaudioPlayerGlobalConfig().bufferNetworkDuration)));

    final effectiveBufferBehind = bufferBehind ?? MiniaudioPlayerGlobalConfig().bufferBehindDuration;

    final streamer = NetworkAudioStreamer(
      _player,
      uri: uri,
      headers: headers,
      isLive: isLive,
      bufferAhead: effectiveBufferAhead,
      bufferBehind: effectiveBufferBehind,
    );

    _activeStreamer = streamer;
    try {
      await streamer.start();
    } catch (e) {
      _stopActiveStreamer();
      _player.pollAndEmit(force: true);
      rethrow;
    }
  }

  /// Starts or resumes audio playback.
  Future<void> play() async {
    _player.ensureNotDisposed();
    if (_player.state.completed ||
        (_player.state.duration > Duration.zero &&
            _player.state.position >= _player.state.duration)) {
      await seek(Duration.zero);
    }
    final res = native.miniaudio_player_play(_player.handle);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to start playback: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Pauses audio playback at the current position.
  Future<void> pause() async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_pause(_player.handle);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to pause playback: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Stops audio playback and resets the position to the beginning.
  Future<void> stop() async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_stop(_player.handle);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to stop playback: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.notifyStopped();
    _player.pollAndEmit(force: true);
  }

  /// Seeks to the specified [position].
  Future<void> seek(Duration position) async {
    _player.ensureNotDisposed();
    _onOptimisticSeek(position);
    if (_activeStreamer != null) {
      await _activeStreamer!.seek(position);
      _player.pollAndEmit(force: true);
      return;
    }
    final durationMs = native.miniaudio_player_get_duration_ms(_player.handle);
    var targetMs = position.inMilliseconds;
    if (targetMs < 0) targetMs = 0;
    if (durationMs > 0 && targetMs > durationMs) {
      targetMs = durationMs;
    }
    final res = native.miniaudio_player_seek(_player.handle, targetMs);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to seek: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Sets the audio volume level (default: 1.0, 0.0 to 2.0).
  Future<void> setVolume(double volume) async {
    _player.ensureNotDisposed();
    if (volume.isNaN || volume.isInfinite) {
      throw ArgumentError.value(volume, 'volume', 'Volume must be finite');
    }
    if (volume < 0.0) {
      throw ArgumentError.value(
        volume,
        'volume',
        'Volume must be non-negative',
      );
    }
    final clampedVolume = volume.clamp(0.0, 2.0);
    final res = native.miniaudio_player_set_volume(_player.handle, clampedVolume);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set volume: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.notifyVolumeChanged(clampedVolume);
  }

  /// Sets the playback speed multiplier (default: 1.0, 0.1 to 4.0).
  Future<void> setRate(double rate) async {
    _player.ensureNotDisposed();
    if (rate.isNaN || rate.isInfinite) {
      throw ArgumentError.value(rate, 'rate', 'Playback rate must be finite');
    }
    if (rate <= 0.0) {
      throw ArgumentError.value(rate, 'rate', 'Playback rate must be positive');
    }
    final clampedRate = rate.clamp(0.1, 4.0);
    final res = native.miniaudio_player_set_rate(_player.handle, clampedRate);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set rate: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.notifyRateChanged(clampedRate);
  }

  /// Sets the audio pitch multiplier (default: 1.0, 0.5 to 2.0).
  Future<void> setPitch(double pitch) async {
    _player.ensureNotDisposed();
    if (pitch.isNaN || pitch.isInfinite) {
      throw ArgumentError.value(pitch, 'pitch', 'Pitch must be finite');
    }
    if (pitch <= 0.0) {
      throw ArgumentError.value(pitch, 'pitch', 'Pitch must be positive');
    }
    final clampedPitch = pitch.clamp(0.5, 2.0);
    final res = native.miniaudio_player_set_pitch(_player.handle, clampedPitch);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set pitch: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.notifyPitchChanged(clampedPitch);
  }

  /// Sets the internal buffer size in frames (0 = native miniaudio default).
  Future<void> setBufferSize(int bufferSize) async {
    _player.ensureNotDisposed();
    if (bufferSize < 0) {
      throw ArgumentError.value(
        bufferSize,
        'bufferSize',
        'Buffer size must be non-negative',
      );
    }
    final res = native.miniaudio_player_set_buffer_size(_player.handle, bufferSize);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set buffer size: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    final actualBufferSize = native.miniaudio_player_get_buffer_size(_player.handle);
    _player.notifyBufferSizeChanged(actualBufferSize);
  }

  /// Applies a 10-band [Equalizer] configuration.
  Future<void> setEqualizer(Equalizer equalizer) async {
    _player.ensureNotDisposed();
    final gainsDb = equalizer.toList();
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

      final res = native.miniaudio_player_set_equalizer(_player.handle, eqPtr);
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to set equalizer: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }
      _player.notifyEqualizerChanged(equalizer);
    } finally {
      calloc.free(eqPtr);
    }
  }

  /// Sets the active audio output device.
  ///
  /// Returns `true` if the device was successfully set, or `false` if the device
  /// was unavailable / disconnected and the player fell back to the default output.
  ///
  /// Supports [AudioDevice.auto] for automatic system default routing, or any
  /// [AudioDevice] obtained via [MiniaudioPlayer.getAudioDevices].
  Future<bool> setDevice(AudioDevice device) async {
    _player.ensureNotDisposed();
    final isAutoTarget = device.isAuto ||
        device.id.isEmpty ||
        device.id == 'auto' ||
        device.id == 'default' ||
        device.id == '0';
    Pointer<Utf8>? devIdPtr;
    if (!isAutoTarget) {
      devIdPtr = device.id.toNativeUtf8();
    }
    try {
      final res = native.miniaudio_player_set_device(
        _player.handle,
        devIdPtr != null ? devIdPtr.cast() : nullptr,
      );
      final devPtr = calloc<native.miniaudio_device_info_t>();
      bool success = res == MapResult.success;
      try {
        if (native.miniaudio_player_get_current_device(_player.handle, devPtr) ==
            MapResult.success) {
          final activeDev = devPtr.ref.toAudioDevice();
          var eventDev = activeDev;
          if (isAutoTarget) {
            final resolved = activeDev.resolvedName?.isNotEmpty == true
                ? activeDev.resolvedName
                : (device.resolvedName?.isNotEmpty == true
                    ? device.resolvedName
                    : null);
            eventDev = AudioDevice(
              id: '',
              name: 'SYSTEM DEFAULT',
              resolvedName: resolved,
              isAuto: true,
            );
          } else if (activeDev.id == device.id && device.name.isNotEmpty) {
            eventDev = AudioDevice(
              id: activeDev.id,
              name: device.name,
              isAuto: false,
              type: device.type,
            );
          }
          _player.notifyDeviceChanged(eventDev);
          if (isAutoTarget) {
            success = activeDev.isAuto;
          } else {
            success = !activeDev.isAuto && activeDev.id == device.id;
          }
        } else if (!success) {
          throw MiniaudioPlayerException(
            'Failed to set audio device: ${MapResult.describe(res)}',
            errorCode: res,
          );
        }
      } finally {
        calloc.free(devPtr);
      }
      return success;
    } finally {
      if (devIdPtr != null) calloc.free(devIdPtr);
    }
  }

  /// Sets whether silence skipping is enabled, optionally configuring mode and thresholds.
  ///
  /// - [enabled]: When `false`, disables silence skipping ([SilenceSkipMode.disabled]).
  ///   When `true`, activates silence skipping (defaults to [SilenceSkipMode.continuous] if [mode] is omitted or disabled).
  /// - [mode]: Operational mode ([SilenceSkipMode.trimEdges], [SilenceSkipMode.continuous], or [SilenceSkipMode.all]).
  /// - [thresholdDb]: Audio amplitude silence threshold in dBFS (default: `-45.0`, clamp: `-90.0` to `-10.0`).
  /// - [minSilenceDuration]: Minimum duration of silence before skipping (default: `300ms`).
  /// - [padding]: Safety margin preserved before and after speech (default: `50ms`).
  Future<void> setSkipSilence(
    bool enabled, {
    SilenceSkipMode mode = SilenceSkipMode.continuous,
    double? thresholdDb,
    Duration? minSilenceDuration,
    Duration? padding,
  }) async {
    final effectiveMode = enabled
        ? (mode == SilenceSkipMode.disabled ? SilenceSkipMode.continuous : mode)
        : SilenceSkipMode.disabled;

    final current = _player.state.silenceConfig;
    final newConfig = SilenceSkipConfig(
      mode: effectiveMode,
      thresholdDb: thresholdDb ?? current.thresholdDb,
      minSilenceDuration: minSilenceDuration ?? current.minSilenceDuration,
      padding: padding ?? current.padding,
    );
    await setSilenceConfig(newConfig);
  }

  /// Configures dynamic silence detection and skipping.
  Future<void> setSilenceConfig(SilenceSkipConfig config) async {
    _player.ensureNotDisposed();

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
        _player.handle,
        configPtr,
      );
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to set silence config: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }

      final normalizedConfig = SilenceSkipConfig(
        mode: config.mode,
        thresholdDb: threshold,
        minSilenceDuration: Duration(milliseconds: minMs),
        padding: Duration(milliseconds: padMs),
      );
      _player.notifySilenceConfigChanged(normalizedConfig);
    } finally {
      calloc.free(configPtr);
    }
  }

  /// Updates specific parameters of the silence detector while keeping existing values.
  Future<void> configureSilenceSkip({
    SilenceSkipMode? mode,
    double? thresholdDb,
    Duration? minSilenceDuration,
    Duration? padding,
  }) async {
    final current = _player.state.silenceConfig;
    final updated = current.copyWith(
      mode: mode,
      thresholdDb: thresholdDb,
      minSilenceDuration: minSilenceDuration,
      padding: padding,
    );
    await setSilenceConfig(updated);
  }

  /// Enables or disables real-time audio visualizer DSP analysis in native C.
  ///
  /// Setting this to `false` explicitly overrides and disables visualizer DSP processing,
  /// even if listeners are subscribed to `player.stream.visualizer`.
  /// Setting this to `true` explicitly force-enables visualizer DSP processing.
  Future<void> setVisualizerEnabled(bool enabled) async {
    _player.ensureNotDisposed();
    _player.setManualVisualizerOverride(enabled);
  }

  /// Clears any manual visualizer override, reverting to reactive on-demand
  /// control based on active `player.stream.visualizer` listeners.
  Future<void> clearVisualizerOverride() async {
    _player.ensureNotDisposed();
    _player.setManualVisualizerOverride(null);
  }

  /// Sets replay gain normalization for the track.
  ///
  /// Accepts primitive numerical values read from databases or tags:
  /// - [gainDb]: Recommended adjustment in decibels relative to target LUFS (e.g. `-13.3`).
  /// - [peak]: Track absolute peak amplitude (where `1.0` = 0 dBFS).
  /// - [preampDb]: Additional user-configured preamp adjustment in dB (default `0.0`).
  /// - [preventClipping]: When `true` (default), caps gain so `(gainDb + preampDb) * peak <= 1.0`.
  Future<void> setReplayGain({
    required double gainDb,
    double? peak,
    double preampDb = 0.0,
    bool preventClipping = true,
  }) async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_set_replay_gain(
      _player.handle,
      gainDb,
      peak ?? 0.0,
      preampDb,
      preventClipping ? 1 : 0,
    );
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set replay gain: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Clears replay gain normalization back to unity gain (0.0 dB).
  Future<void> clearReplayGain() async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_clear_replay_gain(_player.handle);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to clear replay gain: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Sets standalone manual preamp gain in decibels applied prior to the equalizer.
  Future<void> setPreamp(double preampDb) async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_set_preamp(_player.handle, preampDb);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set preamp: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Sets stereo channel balance (-1.0 for full left, 0.0 for center, +1.0 for full right).
  Future<void> setBalance(double pan) async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_set_balance(_player.handle, pan.clamp(-1.0, 1.0));
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set balance: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Sets whether mono downmix is enabled for accessibility or single speakers.
  Future<void> setMono(bool enabled) async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_set_mono(_player.handle, enabled ? 1 : 0);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set mono: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Configures headphone binaural crossfeed (Bauer bs2b).
  Future<void> setCrossfeed(CrossfeedMode mode) async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_set_crossfeed(_player.handle, mode.index);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set crossfeed: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Configures the stereo widener / spatializer.
  Future<void> setSpatializer({required bool enabled, double width = 1.3}) async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_set_spatializer(
      _player.handle,
      enabled ? 1 : 0,
      width.clamp(1.0, 2.0),
    );
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set spatializer: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Enables or disables the True-Peak soft-knee output limiter protector.
  Future<void> setLimiter(bool enabled) async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_set_limiter(_player.handle, enabled ? 1 : 0);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set limiter: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Configures studio-grade algorithmic reverberation.
  ///
  /// Can use convenient presets like [Reverb.smallRoom], [Reverb.studio],
  /// [Reverb.concertHall], [Reverb.cathedral], [Reverb.plate], [Reverb.ambient] or [Reverb.off].
  Future<void> setReverb(Reverb config) async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_set_reverb(
      _player.handle,
      config.enabled ? 1 : 0,
      config.roomSize.clamp(0.0, 1.0),
      config.damping.clamp(0.0, 1.0),
      config.width.clamp(0.0, 1.0),
      config.wet.clamp(0.0, 2.0),
      config.dry.clamp(0.0, 2.0),
    );
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set reverb: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Updates specific parameters of the active reverb effect while preserving others.
  Future<void> configureReverb({
    bool? enabled,
    double? roomSize,
    double? damping,
    double? width,
    double? wet,
    double? dry,
  }) async {
    final current = _player.state.reverb;
    final updated = current.copyWith(
      enabled: enabled,
      roomSize: roomSize,
      damping: damping,
      width: width,
      wet: wet,
      dry: dry,
    );
    await setReverb(updated);
  }
}
