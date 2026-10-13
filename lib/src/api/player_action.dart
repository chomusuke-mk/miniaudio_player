// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../equalizer.dart';
import '../ffi/native_types.dart';
import 'audio_device.dart';
import 'miniaudio_player.dart';
import 'player_exception.dart';
import 'silence_skip_config.dart';
import 'dsp_config.dart';
import '../reverb.dart';

/// Action interface executing asynchronous playback, seeking, volume, and DSP controls.
class PlayerAction {
  final MiniaudioPlayer _player;
  final void Function(Duration position) _onOptimisticSeek;

  PlayerAction(
    this._player, {
    required void Function(Duration) onOptimisticSeek,
  }) : _onOptimisticSeek = onOptimisticSeek;

  /// Prepares an audio file for playback.
  ///
  /// If [autoPlay] is `true`, playback starts immediately upon opening.
  Future<void> open(String filePath, {bool autoPlay = false}) async {
    _player.ensureNotDisposed();
    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
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

      if (autoPlay) {
        final playRes = native.miniaudio_player_play(_player.handle);
        if (playRes != MapResult.success) {
          throw MiniaudioPlayerException(
            'Failed to start playback on autoPlay: ${MapResult.describe(playRes)}',
            errorCode: playRes,
          );
        }
      }

      _player.pollAndEmit(force: true);
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Starts or resumes audio playback.
  Future<void> play() async {
    _player.ensureNotDisposed();
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
