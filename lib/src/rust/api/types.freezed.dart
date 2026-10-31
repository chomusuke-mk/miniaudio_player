// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'types.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$RustPlayerEvent {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is RustPlayerEvent);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'RustPlayerEvent()';
  }
}

/// @nodoc
class $RustPlayerEventCopyWith<$Res> {
  $RustPlayerEventCopyWith(
      RustPlayerEvent _, $Res Function(RustPlayerEvent) __);
}

/// Adds pattern-matching-related methods to [RustPlayerEvent].
extension RustPlayerEventPatterns on RustPlayerEvent {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(RustPlayerEvent_State value)? state,
    TResult Function(RustPlayerEvent_Position value)? position,
    TResult Function(RustPlayerEvent_Duration value)? duration,
    TResult Function(RustPlayerEvent_IsPlaying value)? isPlaying,
    TResult Function(RustPlayerEvent_IsBuffering value)? isBuffering,
    TResult Function(RustPlayerEvent_IsCompleted value)? isCompleted,
    TResult Function(RustPlayerEvent_Volume value)? volume,
    TResult Function(RustPlayerEvent_Rate value)? rate,
    TResult Function(RustPlayerEvent_Pitch value)? pitch,
    TResult Function(RustPlayerEvent_Bitrate value)? bitrate,
    TResult Function(RustPlayerEvent_BufferSize value)? bufferSize,
    TResult Function(RustPlayerEvent_Device value)? device,
    TResult Function(RustPlayerEvent_Visualizer value)? visualizer,
    TResult Function(RustPlayerEvent_VisualizerEnabled value)?
        visualizerEnabled,
    TResult Function(RustPlayerEvent_BufferedRange value)? bufferedRange,
    TResult Function(RustPlayerEvent_SilenceConfig value)? silenceConfig,
    TResult Function(RustPlayerEvent_SilenceSaved value)? silenceSaved,
    TResult Function(RustPlayerEvent_Equalizer value)? equalizer,
    TResult Function(RustPlayerEvent_Preamp value)? preamp,
    TResult Function(RustPlayerEvent_ReplayGain value)? replayGain,
    TResult Function(RustPlayerEvent_Balance value)? balance,
    TResult Function(RustPlayerEvent_Mono value)? mono,
    TResult Function(RustPlayerEvent_Crossfeed value)? crossfeed,
    TResult Function(RustPlayerEvent_Spatializer value)? spatializer,
    TResult Function(RustPlayerEvent_Reverb value)? reverb,
    TResult Function(RustPlayerEvent_Limiter value)? limiter,
    TResult Function(RustPlayerEvent_Error value)? error,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_State() when state != null:
        return state(_that);
      case RustPlayerEvent_Position() when position != null:
        return position(_that);
      case RustPlayerEvent_Duration() when duration != null:
        return duration(_that);
      case RustPlayerEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that);
      case RustPlayerEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that);
      case RustPlayerEvent_IsCompleted() when isCompleted != null:
        return isCompleted(_that);
      case RustPlayerEvent_Volume() when volume != null:
        return volume(_that);
      case RustPlayerEvent_Rate() when rate != null:
        return rate(_that);
      case RustPlayerEvent_Pitch() when pitch != null:
        return pitch(_that);
      case RustPlayerEvent_Bitrate() when bitrate != null:
        return bitrate(_that);
      case RustPlayerEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that);
      case RustPlayerEvent_Device() when device != null:
        return device(_that);
      case RustPlayerEvent_Visualizer() when visualizer != null:
        return visualizer(_that);
      case RustPlayerEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that);
      case RustPlayerEvent_BufferedRange() when bufferedRange != null:
        return bufferedRange(_that);
      case RustPlayerEvent_SilenceConfig() when silenceConfig != null:
        return silenceConfig(_that);
      case RustPlayerEvent_SilenceSaved() when silenceSaved != null:
        return silenceSaved(_that);
      case RustPlayerEvent_Equalizer() when equalizer != null:
        return equalizer(_that);
      case RustPlayerEvent_Preamp() when preamp != null:
        return preamp(_that);
      case RustPlayerEvent_ReplayGain() when replayGain != null:
        return replayGain(_that);
      case RustPlayerEvent_Balance() when balance != null:
        return balance(_that);
      case RustPlayerEvent_Mono() when mono != null:
        return mono(_that);
      case RustPlayerEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that);
      case RustPlayerEvent_Spatializer() when spatializer != null:
        return spatializer(_that);
      case RustPlayerEvent_Reverb() when reverb != null:
        return reverb(_that);
      case RustPlayerEvent_Limiter() when limiter != null:
        return limiter(_that);
      case RustPlayerEvent_Error() when error != null:
        return error(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(RustPlayerEvent_State value) state,
    required TResult Function(RustPlayerEvent_Position value) position,
    required TResult Function(RustPlayerEvent_Duration value) duration,
    required TResult Function(RustPlayerEvent_IsPlaying value) isPlaying,
    required TResult Function(RustPlayerEvent_IsBuffering value) isBuffering,
    required TResult Function(RustPlayerEvent_IsCompleted value) isCompleted,
    required TResult Function(RustPlayerEvent_Volume value) volume,
    required TResult Function(RustPlayerEvent_Rate value) rate,
    required TResult Function(RustPlayerEvent_Pitch value) pitch,
    required TResult Function(RustPlayerEvent_Bitrate value) bitrate,
    required TResult Function(RustPlayerEvent_BufferSize value) bufferSize,
    required TResult Function(RustPlayerEvent_Device value) device,
    required TResult Function(RustPlayerEvent_Visualizer value) visualizer,
    required TResult Function(RustPlayerEvent_VisualizerEnabled value)
        visualizerEnabled,
    required TResult Function(RustPlayerEvent_BufferedRange value)
        bufferedRange,
    required TResult Function(RustPlayerEvent_SilenceConfig value)
        silenceConfig,
    required TResult Function(RustPlayerEvent_SilenceSaved value) silenceSaved,
    required TResult Function(RustPlayerEvent_Equalizer value) equalizer,
    required TResult Function(RustPlayerEvent_Preamp value) preamp,
    required TResult Function(RustPlayerEvent_ReplayGain value) replayGain,
    required TResult Function(RustPlayerEvent_Balance value) balance,
    required TResult Function(RustPlayerEvent_Mono value) mono,
    required TResult Function(RustPlayerEvent_Crossfeed value) crossfeed,
    required TResult Function(RustPlayerEvent_Spatializer value) spatializer,
    required TResult Function(RustPlayerEvent_Reverb value) reverb,
    required TResult Function(RustPlayerEvent_Limiter value) limiter,
    required TResult Function(RustPlayerEvent_Error value) error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_State():
        return state(_that);
      case RustPlayerEvent_Position():
        return position(_that);
      case RustPlayerEvent_Duration():
        return duration(_that);
      case RustPlayerEvent_IsPlaying():
        return isPlaying(_that);
      case RustPlayerEvent_IsBuffering():
        return isBuffering(_that);
      case RustPlayerEvent_IsCompleted():
        return isCompleted(_that);
      case RustPlayerEvent_Volume():
        return volume(_that);
      case RustPlayerEvent_Rate():
        return rate(_that);
      case RustPlayerEvent_Pitch():
        return pitch(_that);
      case RustPlayerEvent_Bitrate():
        return bitrate(_that);
      case RustPlayerEvent_BufferSize():
        return bufferSize(_that);
      case RustPlayerEvent_Device():
        return device(_that);
      case RustPlayerEvent_Visualizer():
        return visualizer(_that);
      case RustPlayerEvent_VisualizerEnabled():
        return visualizerEnabled(_that);
      case RustPlayerEvent_BufferedRange():
        return bufferedRange(_that);
      case RustPlayerEvent_SilenceConfig():
        return silenceConfig(_that);
      case RustPlayerEvent_SilenceSaved():
        return silenceSaved(_that);
      case RustPlayerEvent_Equalizer():
        return equalizer(_that);
      case RustPlayerEvent_Preamp():
        return preamp(_that);
      case RustPlayerEvent_ReplayGain():
        return replayGain(_that);
      case RustPlayerEvent_Balance():
        return balance(_that);
      case RustPlayerEvent_Mono():
        return mono(_that);
      case RustPlayerEvent_Crossfeed():
        return crossfeed(_that);
      case RustPlayerEvent_Spatializer():
        return spatializer(_that);
      case RustPlayerEvent_Reverb():
        return reverb(_that);
      case RustPlayerEvent_Limiter():
        return limiter(_that);
      case RustPlayerEvent_Error():
        return error(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(RustPlayerEvent_State value)? state,
    TResult? Function(RustPlayerEvent_Position value)? position,
    TResult? Function(RustPlayerEvent_Duration value)? duration,
    TResult? Function(RustPlayerEvent_IsPlaying value)? isPlaying,
    TResult? Function(RustPlayerEvent_IsBuffering value)? isBuffering,
    TResult? Function(RustPlayerEvent_IsCompleted value)? isCompleted,
    TResult? Function(RustPlayerEvent_Volume value)? volume,
    TResult? Function(RustPlayerEvent_Rate value)? rate,
    TResult? Function(RustPlayerEvent_Pitch value)? pitch,
    TResult? Function(RustPlayerEvent_Bitrate value)? bitrate,
    TResult? Function(RustPlayerEvent_BufferSize value)? bufferSize,
    TResult? Function(RustPlayerEvent_Device value)? device,
    TResult? Function(RustPlayerEvent_Visualizer value)? visualizer,
    TResult? Function(RustPlayerEvent_VisualizerEnabled value)?
        visualizerEnabled,
    TResult? Function(RustPlayerEvent_BufferedRange value)? bufferedRange,
    TResult? Function(RustPlayerEvent_SilenceConfig value)? silenceConfig,
    TResult? Function(RustPlayerEvent_SilenceSaved value)? silenceSaved,
    TResult? Function(RustPlayerEvent_Equalizer value)? equalizer,
    TResult? Function(RustPlayerEvent_Preamp value)? preamp,
    TResult? Function(RustPlayerEvent_ReplayGain value)? replayGain,
    TResult? Function(RustPlayerEvent_Balance value)? balance,
    TResult? Function(RustPlayerEvent_Mono value)? mono,
    TResult? Function(RustPlayerEvent_Crossfeed value)? crossfeed,
    TResult? Function(RustPlayerEvent_Spatializer value)? spatializer,
    TResult? Function(RustPlayerEvent_Reverb value)? reverb,
    TResult? Function(RustPlayerEvent_Limiter value)? limiter,
    TResult? Function(RustPlayerEvent_Error value)? error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_State() when state != null:
        return state(_that);
      case RustPlayerEvent_Position() when position != null:
        return position(_that);
      case RustPlayerEvent_Duration() when duration != null:
        return duration(_that);
      case RustPlayerEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that);
      case RustPlayerEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that);
      case RustPlayerEvent_IsCompleted() when isCompleted != null:
        return isCompleted(_that);
      case RustPlayerEvent_Volume() when volume != null:
        return volume(_that);
      case RustPlayerEvent_Rate() when rate != null:
        return rate(_that);
      case RustPlayerEvent_Pitch() when pitch != null:
        return pitch(_that);
      case RustPlayerEvent_Bitrate() when bitrate != null:
        return bitrate(_that);
      case RustPlayerEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that);
      case RustPlayerEvent_Device() when device != null:
        return device(_that);
      case RustPlayerEvent_Visualizer() when visualizer != null:
        return visualizer(_that);
      case RustPlayerEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that);
      case RustPlayerEvent_BufferedRange() when bufferedRange != null:
        return bufferedRange(_that);
      case RustPlayerEvent_SilenceConfig() when silenceConfig != null:
        return silenceConfig(_that);
      case RustPlayerEvent_SilenceSaved() when silenceSaved != null:
        return silenceSaved(_that);
      case RustPlayerEvent_Equalizer() when equalizer != null:
        return equalizer(_that);
      case RustPlayerEvent_Preamp() when preamp != null:
        return preamp(_that);
      case RustPlayerEvent_ReplayGain() when replayGain != null:
        return replayGain(_that);
      case RustPlayerEvent_Balance() when balance != null:
        return balance(_that);
      case RustPlayerEvent_Mono() when mono != null:
        return mono(_that);
      case RustPlayerEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that);
      case RustPlayerEvent_Spatializer() when spatializer != null:
        return spatializer(_that);
      case RustPlayerEvent_Reverb() when reverb != null:
        return reverb(_that);
      case RustPlayerEvent_Limiter() when limiter != null:
        return limiter(_that);
      case RustPlayerEvent_Error() when error != null:
        return error(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int field0)? state,
    TResult Function(PlatformInt64 field0)? position,
    TResult Function(PlatformInt64 field0)? duration,
    TResult Function(bool field0)? isPlaying,
    TResult Function(bool field0)? isBuffering,
    TResult Function(bool field0)? isCompleted,
    TResult Function(double field0)? volume,
    TResult Function(double field0)? rate,
    TResult Function(double field0)? pitch,
    TResult Function(int field0)? bitrate,
    TResult Function(int field0)? bufferSize,
    TResult Function(RustAudioDevice field0)? device,
    TResult Function(RustVisualizerData field0)? visualizer,
    TResult Function(bool field0)? visualizerEnabled,
    TResult Function(RustBufferedRange field0)? bufferedRange,
    TResult Function(RustSilenceConfig field0)? silenceConfig,
    TResult Function(PlatformInt64 field0)? silenceSaved,
    TResult Function(RustEqualizerParams field0)? equalizer,
    TResult Function(double field0)? preamp,
    TResult Function(RustReplayGainConfig field0)? replayGain,
    TResult Function(double field0)? balance,
    TResult Function(bool field0)? mono,
    TResult Function(int field0)? crossfeed,
    TResult Function(bool enabled, double width)? spatializer,
    TResult Function(RustReverbParams field0)? reverb,
    TResult Function(bool field0)? limiter,
    TResult Function(String message, int code)? error,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_State() when state != null:
        return state(_that.field0);
      case RustPlayerEvent_Position() when position != null:
        return position(_that.field0);
      case RustPlayerEvent_Duration() when duration != null:
        return duration(_that.field0);
      case RustPlayerEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that.field0);
      case RustPlayerEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that.field0);
      case RustPlayerEvent_IsCompleted() when isCompleted != null:
        return isCompleted(_that.field0);
      case RustPlayerEvent_Volume() when volume != null:
        return volume(_that.field0);
      case RustPlayerEvent_Rate() when rate != null:
        return rate(_that.field0);
      case RustPlayerEvent_Pitch() when pitch != null:
        return pitch(_that.field0);
      case RustPlayerEvent_Bitrate() when bitrate != null:
        return bitrate(_that.field0);
      case RustPlayerEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that.field0);
      case RustPlayerEvent_Device() when device != null:
        return device(_that.field0);
      case RustPlayerEvent_Visualizer() when visualizer != null:
        return visualizer(_that.field0);
      case RustPlayerEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that.field0);
      case RustPlayerEvent_BufferedRange() when bufferedRange != null:
        return bufferedRange(_that.field0);
      case RustPlayerEvent_SilenceConfig() when silenceConfig != null:
        return silenceConfig(_that.field0);
      case RustPlayerEvent_SilenceSaved() when silenceSaved != null:
        return silenceSaved(_that.field0);
      case RustPlayerEvent_Equalizer() when equalizer != null:
        return equalizer(_that.field0);
      case RustPlayerEvent_Preamp() when preamp != null:
        return preamp(_that.field0);
      case RustPlayerEvent_ReplayGain() when replayGain != null:
        return replayGain(_that.field0);
      case RustPlayerEvent_Balance() when balance != null:
        return balance(_that.field0);
      case RustPlayerEvent_Mono() when mono != null:
        return mono(_that.field0);
      case RustPlayerEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that.field0);
      case RustPlayerEvent_Spatializer() when spatializer != null:
        return spatializer(_that.enabled, _that.width);
      case RustPlayerEvent_Reverb() when reverb != null:
        return reverb(_that.field0);
      case RustPlayerEvent_Limiter() when limiter != null:
        return limiter(_that.field0);
      case RustPlayerEvent_Error() when error != null:
        return error(_that.message, _that.code);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int field0) state,
    required TResult Function(PlatformInt64 field0) position,
    required TResult Function(PlatformInt64 field0) duration,
    required TResult Function(bool field0) isPlaying,
    required TResult Function(bool field0) isBuffering,
    required TResult Function(bool field0) isCompleted,
    required TResult Function(double field0) volume,
    required TResult Function(double field0) rate,
    required TResult Function(double field0) pitch,
    required TResult Function(int field0) bitrate,
    required TResult Function(int field0) bufferSize,
    required TResult Function(RustAudioDevice field0) device,
    required TResult Function(RustVisualizerData field0) visualizer,
    required TResult Function(bool field0) visualizerEnabled,
    required TResult Function(RustBufferedRange field0) bufferedRange,
    required TResult Function(RustSilenceConfig field0) silenceConfig,
    required TResult Function(PlatformInt64 field0) silenceSaved,
    required TResult Function(RustEqualizerParams field0) equalizer,
    required TResult Function(double field0) preamp,
    required TResult Function(RustReplayGainConfig field0) replayGain,
    required TResult Function(double field0) balance,
    required TResult Function(bool field0) mono,
    required TResult Function(int field0) crossfeed,
    required TResult Function(bool enabled, double width) spatializer,
    required TResult Function(RustReverbParams field0) reverb,
    required TResult Function(bool field0) limiter,
    required TResult Function(String message, int code) error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_State():
        return state(_that.field0);
      case RustPlayerEvent_Position():
        return position(_that.field0);
      case RustPlayerEvent_Duration():
        return duration(_that.field0);
      case RustPlayerEvent_IsPlaying():
        return isPlaying(_that.field0);
      case RustPlayerEvent_IsBuffering():
        return isBuffering(_that.field0);
      case RustPlayerEvent_IsCompleted():
        return isCompleted(_that.field0);
      case RustPlayerEvent_Volume():
        return volume(_that.field0);
      case RustPlayerEvent_Rate():
        return rate(_that.field0);
      case RustPlayerEvent_Pitch():
        return pitch(_that.field0);
      case RustPlayerEvent_Bitrate():
        return bitrate(_that.field0);
      case RustPlayerEvent_BufferSize():
        return bufferSize(_that.field0);
      case RustPlayerEvent_Device():
        return device(_that.field0);
      case RustPlayerEvent_Visualizer():
        return visualizer(_that.field0);
      case RustPlayerEvent_VisualizerEnabled():
        return visualizerEnabled(_that.field0);
      case RustPlayerEvent_BufferedRange():
        return bufferedRange(_that.field0);
      case RustPlayerEvent_SilenceConfig():
        return silenceConfig(_that.field0);
      case RustPlayerEvent_SilenceSaved():
        return silenceSaved(_that.field0);
      case RustPlayerEvent_Equalizer():
        return equalizer(_that.field0);
      case RustPlayerEvent_Preamp():
        return preamp(_that.field0);
      case RustPlayerEvent_ReplayGain():
        return replayGain(_that.field0);
      case RustPlayerEvent_Balance():
        return balance(_that.field0);
      case RustPlayerEvent_Mono():
        return mono(_that.field0);
      case RustPlayerEvent_Crossfeed():
        return crossfeed(_that.field0);
      case RustPlayerEvent_Spatializer():
        return spatializer(_that.enabled, _that.width);
      case RustPlayerEvent_Reverb():
        return reverb(_that.field0);
      case RustPlayerEvent_Limiter():
        return limiter(_that.field0);
      case RustPlayerEvent_Error():
        return error(_that.message, _that.code);
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int field0)? state,
    TResult? Function(PlatformInt64 field0)? position,
    TResult? Function(PlatformInt64 field0)? duration,
    TResult? Function(bool field0)? isPlaying,
    TResult? Function(bool field0)? isBuffering,
    TResult? Function(bool field0)? isCompleted,
    TResult? Function(double field0)? volume,
    TResult? Function(double field0)? rate,
    TResult? Function(double field0)? pitch,
    TResult? Function(int field0)? bitrate,
    TResult? Function(int field0)? bufferSize,
    TResult? Function(RustAudioDevice field0)? device,
    TResult? Function(RustVisualizerData field0)? visualizer,
    TResult? Function(bool field0)? visualizerEnabled,
    TResult? Function(RustBufferedRange field0)? bufferedRange,
    TResult? Function(RustSilenceConfig field0)? silenceConfig,
    TResult? Function(PlatformInt64 field0)? silenceSaved,
    TResult? Function(RustEqualizerParams field0)? equalizer,
    TResult? Function(double field0)? preamp,
    TResult? Function(RustReplayGainConfig field0)? replayGain,
    TResult? Function(double field0)? balance,
    TResult? Function(bool field0)? mono,
    TResult? Function(int field0)? crossfeed,
    TResult? Function(bool enabled, double width)? spatializer,
    TResult? Function(RustReverbParams field0)? reverb,
    TResult? Function(bool field0)? limiter,
    TResult? Function(String message, int code)? error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_State() when state != null:
        return state(_that.field0);
      case RustPlayerEvent_Position() when position != null:
        return position(_that.field0);
      case RustPlayerEvent_Duration() when duration != null:
        return duration(_that.field0);
      case RustPlayerEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that.field0);
      case RustPlayerEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that.field0);
      case RustPlayerEvent_IsCompleted() when isCompleted != null:
        return isCompleted(_that.field0);
      case RustPlayerEvent_Volume() when volume != null:
        return volume(_that.field0);
      case RustPlayerEvent_Rate() when rate != null:
        return rate(_that.field0);
      case RustPlayerEvent_Pitch() when pitch != null:
        return pitch(_that.field0);
      case RustPlayerEvent_Bitrate() when bitrate != null:
        return bitrate(_that.field0);
      case RustPlayerEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that.field0);
      case RustPlayerEvent_Device() when device != null:
        return device(_that.field0);
      case RustPlayerEvent_Visualizer() when visualizer != null:
        return visualizer(_that.field0);
      case RustPlayerEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that.field0);
      case RustPlayerEvent_BufferedRange() when bufferedRange != null:
        return bufferedRange(_that.field0);
      case RustPlayerEvent_SilenceConfig() when silenceConfig != null:
        return silenceConfig(_that.field0);
      case RustPlayerEvent_SilenceSaved() when silenceSaved != null:
        return silenceSaved(_that.field0);
      case RustPlayerEvent_Equalizer() when equalizer != null:
        return equalizer(_that.field0);
      case RustPlayerEvent_Preamp() when preamp != null:
        return preamp(_that.field0);
      case RustPlayerEvent_ReplayGain() when replayGain != null:
        return replayGain(_that.field0);
      case RustPlayerEvent_Balance() when balance != null:
        return balance(_that.field0);
      case RustPlayerEvent_Mono() when mono != null:
        return mono(_that.field0);
      case RustPlayerEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that.field0);
      case RustPlayerEvent_Spatializer() when spatializer != null:
        return spatializer(_that.enabled, _that.width);
      case RustPlayerEvent_Reverb() when reverb != null:
        return reverb(_that.field0);
      case RustPlayerEvent_Limiter() when limiter != null:
        return limiter(_that.field0);
      case RustPlayerEvent_Error() when error != null:
        return error(_that.message, _that.code);
      case _:
        return null;
    }
  }
}

/// @nodoc

class RustPlayerEvent_State extends RustPlayerEvent {
  const RustPlayerEvent_State(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_StateCopyWith<RustPlayerEvent_State> get copyWith =>
      _$RustPlayerEvent_StateCopyWithImpl<RustPlayerEvent_State>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_State &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.state(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_StateCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_StateCopyWith(RustPlayerEvent_State value,
          $Res Function(RustPlayerEvent_State) _then) =
      _$RustPlayerEvent_StateCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_StateCopyWithImpl<$Res>
    implements $RustPlayerEvent_StateCopyWith<$Res> {
  _$RustPlayerEvent_StateCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_State _self;
  final $Res Function(RustPlayerEvent_State) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_State(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Position extends RustPlayerEvent {
  const RustPlayerEvent_Position(this.field0) : super._();

  final PlatformInt64 field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_PositionCopyWith<RustPlayerEvent_Position> get copyWith =>
      _$RustPlayerEvent_PositionCopyWithImpl<RustPlayerEvent_Position>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Position &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.position(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_PositionCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_PositionCopyWith(RustPlayerEvent_Position value,
          $Res Function(RustPlayerEvent_Position) _then) =
      _$RustPlayerEvent_PositionCopyWithImpl;
  @useResult
  $Res call({PlatformInt64 field0});
}

/// @nodoc
class _$RustPlayerEvent_PositionCopyWithImpl<$Res>
    implements $RustPlayerEvent_PositionCopyWith<$Res> {
  _$RustPlayerEvent_PositionCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Position _self;
  final $Res Function(RustPlayerEvent_Position) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Position(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Duration extends RustPlayerEvent {
  const RustPlayerEvent_Duration(this.field0) : super._();

  final PlatformInt64 field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_DurationCopyWith<RustPlayerEvent_Duration> get copyWith =>
      _$RustPlayerEvent_DurationCopyWithImpl<RustPlayerEvent_Duration>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Duration &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.duration(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_DurationCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_DurationCopyWith(RustPlayerEvent_Duration value,
          $Res Function(RustPlayerEvent_Duration) _then) =
      _$RustPlayerEvent_DurationCopyWithImpl;
  @useResult
  $Res call({PlatformInt64 field0});
}

/// @nodoc
class _$RustPlayerEvent_DurationCopyWithImpl<$Res>
    implements $RustPlayerEvent_DurationCopyWith<$Res> {
  _$RustPlayerEvent_DurationCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Duration _self;
  final $Res Function(RustPlayerEvent_Duration) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Duration(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_IsPlaying extends RustPlayerEvent {
  const RustPlayerEvent_IsPlaying(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_IsPlayingCopyWith<RustPlayerEvent_IsPlaying> get copyWith =>
      _$RustPlayerEvent_IsPlayingCopyWithImpl<RustPlayerEvent_IsPlaying>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_IsPlaying &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.isPlaying(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_IsPlayingCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_IsPlayingCopyWith(RustPlayerEvent_IsPlaying value,
          $Res Function(RustPlayerEvent_IsPlaying) _then) =
      _$RustPlayerEvent_IsPlayingCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_IsPlayingCopyWithImpl<$Res>
    implements $RustPlayerEvent_IsPlayingCopyWith<$Res> {
  _$RustPlayerEvent_IsPlayingCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_IsPlaying _self;
  final $Res Function(RustPlayerEvent_IsPlaying) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_IsPlaying(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_IsBuffering extends RustPlayerEvent {
  const RustPlayerEvent_IsBuffering(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_IsBufferingCopyWith<RustPlayerEvent_IsBuffering>
      get copyWith => _$RustPlayerEvent_IsBufferingCopyWithImpl<
          RustPlayerEvent_IsBuffering>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_IsBuffering &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.isBuffering(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_IsBufferingCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_IsBufferingCopyWith(
          RustPlayerEvent_IsBuffering value,
          $Res Function(RustPlayerEvent_IsBuffering) _then) =
      _$RustPlayerEvent_IsBufferingCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_IsBufferingCopyWithImpl<$Res>
    implements $RustPlayerEvent_IsBufferingCopyWith<$Res> {
  _$RustPlayerEvent_IsBufferingCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_IsBuffering _self;
  final $Res Function(RustPlayerEvent_IsBuffering) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_IsBuffering(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_IsCompleted extends RustPlayerEvent {
  const RustPlayerEvent_IsCompleted(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_IsCompletedCopyWith<RustPlayerEvent_IsCompleted>
      get copyWith => _$RustPlayerEvent_IsCompletedCopyWithImpl<
          RustPlayerEvent_IsCompleted>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_IsCompleted &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.isCompleted(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_IsCompletedCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_IsCompletedCopyWith(
          RustPlayerEvent_IsCompleted value,
          $Res Function(RustPlayerEvent_IsCompleted) _then) =
      _$RustPlayerEvent_IsCompletedCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_IsCompletedCopyWithImpl<$Res>
    implements $RustPlayerEvent_IsCompletedCopyWith<$Res> {
  _$RustPlayerEvent_IsCompletedCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_IsCompleted _self;
  final $Res Function(RustPlayerEvent_IsCompleted) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_IsCompleted(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Volume extends RustPlayerEvent {
  const RustPlayerEvent_Volume(this.field0) : super._();

  final double field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_VolumeCopyWith<RustPlayerEvent_Volume> get copyWith =>
      _$RustPlayerEvent_VolumeCopyWithImpl<RustPlayerEvent_Volume>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Volume &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.volume(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_VolumeCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_VolumeCopyWith(RustPlayerEvent_Volume value,
          $Res Function(RustPlayerEvent_Volume) _then) =
      _$RustPlayerEvent_VolumeCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustPlayerEvent_VolumeCopyWithImpl<$Res>
    implements $RustPlayerEvent_VolumeCopyWith<$Res> {
  _$RustPlayerEvent_VolumeCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Volume _self;
  final $Res Function(RustPlayerEvent_Volume) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Volume(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Rate extends RustPlayerEvent {
  const RustPlayerEvent_Rate(this.field0) : super._();

  final double field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_RateCopyWith<RustPlayerEvent_Rate> get copyWith =>
      _$RustPlayerEvent_RateCopyWithImpl<RustPlayerEvent_Rate>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Rate &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.rate(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_RateCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_RateCopyWith(RustPlayerEvent_Rate value,
          $Res Function(RustPlayerEvent_Rate) _then) =
      _$RustPlayerEvent_RateCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustPlayerEvent_RateCopyWithImpl<$Res>
    implements $RustPlayerEvent_RateCopyWith<$Res> {
  _$RustPlayerEvent_RateCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Rate _self;
  final $Res Function(RustPlayerEvent_Rate) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Rate(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Pitch extends RustPlayerEvent {
  const RustPlayerEvent_Pitch(this.field0) : super._();

  final double field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_PitchCopyWith<RustPlayerEvent_Pitch> get copyWith =>
      _$RustPlayerEvent_PitchCopyWithImpl<RustPlayerEvent_Pitch>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Pitch &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.pitch(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_PitchCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_PitchCopyWith(RustPlayerEvent_Pitch value,
          $Res Function(RustPlayerEvent_Pitch) _then) =
      _$RustPlayerEvent_PitchCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustPlayerEvent_PitchCopyWithImpl<$Res>
    implements $RustPlayerEvent_PitchCopyWith<$Res> {
  _$RustPlayerEvent_PitchCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Pitch _self;
  final $Res Function(RustPlayerEvent_Pitch) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Pitch(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Bitrate extends RustPlayerEvent {
  const RustPlayerEvent_Bitrate(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_BitrateCopyWith<RustPlayerEvent_Bitrate> get copyWith =>
      _$RustPlayerEvent_BitrateCopyWithImpl<RustPlayerEvent_Bitrate>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Bitrate &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.bitrate(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_BitrateCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_BitrateCopyWith(RustPlayerEvent_Bitrate value,
          $Res Function(RustPlayerEvent_Bitrate) _then) =
      _$RustPlayerEvent_BitrateCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_BitrateCopyWithImpl<$Res>
    implements $RustPlayerEvent_BitrateCopyWith<$Res> {
  _$RustPlayerEvent_BitrateCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Bitrate _self;
  final $Res Function(RustPlayerEvent_Bitrate) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Bitrate(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_BufferSize extends RustPlayerEvent {
  const RustPlayerEvent_BufferSize(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_BufferSizeCopyWith<RustPlayerEvent_BufferSize>
      get copyWith =>
          _$RustPlayerEvent_BufferSizeCopyWithImpl<RustPlayerEvent_BufferSize>(
              this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_BufferSize &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.bufferSize(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_BufferSizeCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_BufferSizeCopyWith(RustPlayerEvent_BufferSize value,
          $Res Function(RustPlayerEvent_BufferSize) _then) =
      _$RustPlayerEvent_BufferSizeCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_BufferSizeCopyWithImpl<$Res>
    implements $RustPlayerEvent_BufferSizeCopyWith<$Res> {
  _$RustPlayerEvent_BufferSizeCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_BufferSize _self;
  final $Res Function(RustPlayerEvent_BufferSize) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_BufferSize(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Device extends RustPlayerEvent {
  const RustPlayerEvent_Device(this.field0) : super._();

  final RustAudioDevice field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_DeviceCopyWith<RustPlayerEvent_Device> get copyWith =>
      _$RustPlayerEvent_DeviceCopyWithImpl<RustPlayerEvent_Device>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Device &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.device(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_DeviceCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_DeviceCopyWith(RustPlayerEvent_Device value,
          $Res Function(RustPlayerEvent_Device) _then) =
      _$RustPlayerEvent_DeviceCopyWithImpl;
  @useResult
  $Res call({RustAudioDevice field0});
}

/// @nodoc
class _$RustPlayerEvent_DeviceCopyWithImpl<$Res>
    implements $RustPlayerEvent_DeviceCopyWith<$Res> {
  _$RustPlayerEvent_DeviceCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Device _self;
  final $Res Function(RustPlayerEvent_Device) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Device(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustAudioDevice,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Visualizer extends RustPlayerEvent {
  const RustPlayerEvent_Visualizer(this.field0) : super._();

  final RustVisualizerData field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_VisualizerCopyWith<RustPlayerEvent_Visualizer>
      get copyWith =>
          _$RustPlayerEvent_VisualizerCopyWithImpl<RustPlayerEvent_Visualizer>(
              this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Visualizer &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.visualizer(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_VisualizerCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_VisualizerCopyWith(RustPlayerEvent_Visualizer value,
          $Res Function(RustPlayerEvent_Visualizer) _then) =
      _$RustPlayerEvent_VisualizerCopyWithImpl;
  @useResult
  $Res call({RustVisualizerData field0});
}

/// @nodoc
class _$RustPlayerEvent_VisualizerCopyWithImpl<$Res>
    implements $RustPlayerEvent_VisualizerCopyWith<$Res> {
  _$RustPlayerEvent_VisualizerCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Visualizer _self;
  final $Res Function(RustPlayerEvent_Visualizer) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Visualizer(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustVisualizerData,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_VisualizerEnabled extends RustPlayerEvent {
  const RustPlayerEvent_VisualizerEnabled(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_VisualizerEnabledCopyWith<RustPlayerEvent_VisualizerEnabled>
      get copyWith => _$RustPlayerEvent_VisualizerEnabledCopyWithImpl<
          RustPlayerEvent_VisualizerEnabled>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_VisualizerEnabled &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.visualizerEnabled(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_VisualizerEnabledCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_VisualizerEnabledCopyWith(
          RustPlayerEvent_VisualizerEnabled value,
          $Res Function(RustPlayerEvent_VisualizerEnabled) _then) =
      _$RustPlayerEvent_VisualizerEnabledCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_VisualizerEnabledCopyWithImpl<$Res>
    implements $RustPlayerEvent_VisualizerEnabledCopyWith<$Res> {
  _$RustPlayerEvent_VisualizerEnabledCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_VisualizerEnabled _self;
  final $Res Function(RustPlayerEvent_VisualizerEnabled) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_VisualizerEnabled(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_BufferedRange extends RustPlayerEvent {
  const RustPlayerEvent_BufferedRange(this.field0) : super._();

  final RustBufferedRange field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_BufferedRangeCopyWith<RustPlayerEvent_BufferedRange>
      get copyWith => _$RustPlayerEvent_BufferedRangeCopyWithImpl<
          RustPlayerEvent_BufferedRange>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_BufferedRange &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.bufferedRange(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_BufferedRangeCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_BufferedRangeCopyWith(
          RustPlayerEvent_BufferedRange value,
          $Res Function(RustPlayerEvent_BufferedRange) _then) =
      _$RustPlayerEvent_BufferedRangeCopyWithImpl;
  @useResult
  $Res call({RustBufferedRange field0});
}

/// @nodoc
class _$RustPlayerEvent_BufferedRangeCopyWithImpl<$Res>
    implements $RustPlayerEvent_BufferedRangeCopyWith<$Res> {
  _$RustPlayerEvent_BufferedRangeCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_BufferedRange _self;
  final $Res Function(RustPlayerEvent_BufferedRange) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_BufferedRange(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustBufferedRange,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_SilenceConfig extends RustPlayerEvent {
  const RustPlayerEvent_SilenceConfig(this.field0) : super._();

  final RustSilenceConfig field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_SilenceConfigCopyWith<RustPlayerEvent_SilenceConfig>
      get copyWith => _$RustPlayerEvent_SilenceConfigCopyWithImpl<
          RustPlayerEvent_SilenceConfig>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_SilenceConfig &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.silenceConfig(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_SilenceConfigCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_SilenceConfigCopyWith(
          RustPlayerEvent_SilenceConfig value,
          $Res Function(RustPlayerEvent_SilenceConfig) _then) =
      _$RustPlayerEvent_SilenceConfigCopyWithImpl;
  @useResult
  $Res call({RustSilenceConfig field0});
}

/// @nodoc
class _$RustPlayerEvent_SilenceConfigCopyWithImpl<$Res>
    implements $RustPlayerEvent_SilenceConfigCopyWith<$Res> {
  _$RustPlayerEvent_SilenceConfigCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_SilenceConfig _self;
  final $Res Function(RustPlayerEvent_SilenceConfig) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_SilenceConfig(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustSilenceConfig,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_SilenceSaved extends RustPlayerEvent {
  const RustPlayerEvent_SilenceSaved(this.field0) : super._();

  final PlatformInt64 field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_SilenceSavedCopyWith<RustPlayerEvent_SilenceSaved>
      get copyWith => _$RustPlayerEvent_SilenceSavedCopyWithImpl<
          RustPlayerEvent_SilenceSaved>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_SilenceSaved &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.silenceSaved(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_SilenceSavedCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_SilenceSavedCopyWith(
          RustPlayerEvent_SilenceSaved value,
          $Res Function(RustPlayerEvent_SilenceSaved) _then) =
      _$RustPlayerEvent_SilenceSavedCopyWithImpl;
  @useResult
  $Res call({PlatformInt64 field0});
}

/// @nodoc
class _$RustPlayerEvent_SilenceSavedCopyWithImpl<$Res>
    implements $RustPlayerEvent_SilenceSavedCopyWith<$Res> {
  _$RustPlayerEvent_SilenceSavedCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_SilenceSaved _self;
  final $Res Function(RustPlayerEvent_SilenceSaved) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_SilenceSaved(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Equalizer extends RustPlayerEvent {
  const RustPlayerEvent_Equalizer(this.field0) : super._();

  final RustEqualizerParams field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_EqualizerCopyWith<RustPlayerEvent_Equalizer> get copyWith =>
      _$RustPlayerEvent_EqualizerCopyWithImpl<RustPlayerEvent_Equalizer>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Equalizer &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.equalizer(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_EqualizerCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_EqualizerCopyWith(RustPlayerEvent_Equalizer value,
          $Res Function(RustPlayerEvent_Equalizer) _then) =
      _$RustPlayerEvent_EqualizerCopyWithImpl;
  @useResult
  $Res call({RustEqualizerParams field0});
}

/// @nodoc
class _$RustPlayerEvent_EqualizerCopyWithImpl<$Res>
    implements $RustPlayerEvent_EqualizerCopyWith<$Res> {
  _$RustPlayerEvent_EqualizerCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Equalizer _self;
  final $Res Function(RustPlayerEvent_Equalizer) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Equalizer(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustEqualizerParams,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Preamp extends RustPlayerEvent {
  const RustPlayerEvent_Preamp(this.field0) : super._();

  final double field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_PreampCopyWith<RustPlayerEvent_Preamp> get copyWith =>
      _$RustPlayerEvent_PreampCopyWithImpl<RustPlayerEvent_Preamp>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Preamp &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.preamp(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_PreampCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_PreampCopyWith(RustPlayerEvent_Preamp value,
          $Res Function(RustPlayerEvent_Preamp) _then) =
      _$RustPlayerEvent_PreampCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustPlayerEvent_PreampCopyWithImpl<$Res>
    implements $RustPlayerEvent_PreampCopyWith<$Res> {
  _$RustPlayerEvent_PreampCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Preamp _self;
  final $Res Function(RustPlayerEvent_Preamp) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Preamp(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_ReplayGain extends RustPlayerEvent {
  const RustPlayerEvent_ReplayGain(this.field0) : super._();

  final RustReplayGainConfig field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_ReplayGainCopyWith<RustPlayerEvent_ReplayGain>
      get copyWith =>
          _$RustPlayerEvent_ReplayGainCopyWithImpl<RustPlayerEvent_ReplayGain>(
              this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_ReplayGain &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.replayGain(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_ReplayGainCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_ReplayGainCopyWith(RustPlayerEvent_ReplayGain value,
          $Res Function(RustPlayerEvent_ReplayGain) _then) =
      _$RustPlayerEvent_ReplayGainCopyWithImpl;
  @useResult
  $Res call({RustReplayGainConfig field0});
}

/// @nodoc
class _$RustPlayerEvent_ReplayGainCopyWithImpl<$Res>
    implements $RustPlayerEvent_ReplayGainCopyWith<$Res> {
  _$RustPlayerEvent_ReplayGainCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_ReplayGain _self;
  final $Res Function(RustPlayerEvent_ReplayGain) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_ReplayGain(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustReplayGainConfig,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Balance extends RustPlayerEvent {
  const RustPlayerEvent_Balance(this.field0) : super._();

  final double field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_BalanceCopyWith<RustPlayerEvent_Balance> get copyWith =>
      _$RustPlayerEvent_BalanceCopyWithImpl<RustPlayerEvent_Balance>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Balance &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.balance(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_BalanceCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_BalanceCopyWith(RustPlayerEvent_Balance value,
          $Res Function(RustPlayerEvent_Balance) _then) =
      _$RustPlayerEvent_BalanceCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustPlayerEvent_BalanceCopyWithImpl<$Res>
    implements $RustPlayerEvent_BalanceCopyWith<$Res> {
  _$RustPlayerEvent_BalanceCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Balance _self;
  final $Res Function(RustPlayerEvent_Balance) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Balance(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Mono extends RustPlayerEvent {
  const RustPlayerEvent_Mono(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_MonoCopyWith<RustPlayerEvent_Mono> get copyWith =>
      _$RustPlayerEvent_MonoCopyWithImpl<RustPlayerEvent_Mono>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Mono &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.mono(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_MonoCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_MonoCopyWith(RustPlayerEvent_Mono value,
          $Res Function(RustPlayerEvent_Mono) _then) =
      _$RustPlayerEvent_MonoCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_MonoCopyWithImpl<$Res>
    implements $RustPlayerEvent_MonoCopyWith<$Res> {
  _$RustPlayerEvent_MonoCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Mono _self;
  final $Res Function(RustPlayerEvent_Mono) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Mono(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Crossfeed extends RustPlayerEvent {
  const RustPlayerEvent_Crossfeed(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_CrossfeedCopyWith<RustPlayerEvent_Crossfeed> get copyWith =>
      _$RustPlayerEvent_CrossfeedCopyWithImpl<RustPlayerEvent_Crossfeed>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Crossfeed &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.crossfeed(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_CrossfeedCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_CrossfeedCopyWith(RustPlayerEvent_Crossfeed value,
          $Res Function(RustPlayerEvent_Crossfeed) _then) =
      _$RustPlayerEvent_CrossfeedCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_CrossfeedCopyWithImpl<$Res>
    implements $RustPlayerEvent_CrossfeedCopyWith<$Res> {
  _$RustPlayerEvent_CrossfeedCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Crossfeed _self;
  final $Res Function(RustPlayerEvent_Crossfeed) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Crossfeed(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Spatializer extends RustPlayerEvent {
  const RustPlayerEvent_Spatializer(
      {required this.enabled, required this.width})
      : super._();

  final bool enabled;
  final double width;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_SpatializerCopyWith<RustPlayerEvent_Spatializer>
      get copyWith => _$RustPlayerEvent_SpatializerCopyWithImpl<
          RustPlayerEvent_Spatializer>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Spatializer &&
            (identical(other.enabled, enabled) || other.enabled == enabled) &&
            (identical(other.width, width) || other.width == width));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, enabled, width);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.spatializer(enabled: $enabled, width: $width)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_SpatializerCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_SpatializerCopyWith(
          RustPlayerEvent_Spatializer value,
          $Res Function(RustPlayerEvent_Spatializer) _then) =
      _$RustPlayerEvent_SpatializerCopyWithImpl;
  @useResult
  $Res call({bool enabled, double width});
}

/// @nodoc
class _$RustPlayerEvent_SpatializerCopyWithImpl<$Res>
    implements $RustPlayerEvent_SpatializerCopyWith<$Res> {
  _$RustPlayerEvent_SpatializerCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Spatializer _self;
  final $Res Function(RustPlayerEvent_Spatializer) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? enabled = null,
    Object? width = null,
  }) {
    return _then(RustPlayerEvent_Spatializer(
      enabled: null == enabled
          ? _self.enabled
          : enabled // ignore: cast_nullable_to_non_nullable
              as bool,
      width: null == width
          ? _self.width
          : width // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Reverb extends RustPlayerEvent {
  const RustPlayerEvent_Reverb(this.field0) : super._();

  final RustReverbParams field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_ReverbCopyWith<RustPlayerEvent_Reverb> get copyWith =>
      _$RustPlayerEvent_ReverbCopyWithImpl<RustPlayerEvent_Reverb>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Reverb &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.reverb(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_ReverbCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_ReverbCopyWith(RustPlayerEvent_Reverb value,
          $Res Function(RustPlayerEvent_Reverb) _then) =
      _$RustPlayerEvent_ReverbCopyWithImpl;
  @useResult
  $Res call({RustReverbParams field0});
}

/// @nodoc
class _$RustPlayerEvent_ReverbCopyWithImpl<$Res>
    implements $RustPlayerEvent_ReverbCopyWith<$Res> {
  _$RustPlayerEvent_ReverbCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Reverb _self;
  final $Res Function(RustPlayerEvent_Reverb) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Reverb(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustReverbParams,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Limiter extends RustPlayerEvent {
  const RustPlayerEvent_Limiter(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_LimiterCopyWith<RustPlayerEvent_Limiter> get copyWith =>
      _$RustPlayerEvent_LimiterCopyWithImpl<RustPlayerEvent_Limiter>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Limiter &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.limiter(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_LimiterCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_LimiterCopyWith(RustPlayerEvent_Limiter value,
          $Res Function(RustPlayerEvent_Limiter) _then) =
      _$RustPlayerEvent_LimiterCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_LimiterCopyWithImpl<$Res>
    implements $RustPlayerEvent_LimiterCopyWith<$Res> {
  _$RustPlayerEvent_LimiterCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Limiter _self;
  final $Res Function(RustPlayerEvent_Limiter) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Limiter(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Error extends RustPlayerEvent {
  const RustPlayerEvent_Error({required this.message, required this.code})
      : super._();

  final String message;
  final int code;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_ErrorCopyWith<RustPlayerEvent_Error> get copyWith =>
      _$RustPlayerEvent_ErrorCopyWithImpl<RustPlayerEvent_Error>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Error &&
            (identical(other.message, message) || other.message == message) &&
            (identical(other.code, code) || other.code == code));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, message, code);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.error(message: $message, code: $code)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_ErrorCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_ErrorCopyWith(RustPlayerEvent_Error value,
          $Res Function(RustPlayerEvent_Error) _then) =
      _$RustPlayerEvent_ErrorCopyWithImpl;
  @useResult
  $Res call({String message, int code});
}

/// @nodoc
class _$RustPlayerEvent_ErrorCopyWithImpl<$Res>
    implements $RustPlayerEvent_ErrorCopyWith<$Res> {
  _$RustPlayerEvent_ErrorCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Error _self;
  final $Res Function(RustPlayerEvent_Error) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? message = null,
    Object? code = null,
  }) {
    return _then(RustPlayerEvent_Error(
      message: null == message
          ? _self.message
          : message // ignore: cast_nullable_to_non_nullable
              as String,
      code: null == code
          ? _self.code
          : code // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

// dart format on
