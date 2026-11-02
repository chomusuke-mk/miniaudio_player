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
mixin _$RustEngineEvent {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is RustEngineEvent);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'RustEngineEvent()';
  }
}

/// @nodoc
class $RustEngineEventCopyWith<$Res> {
  $RustEngineEventCopyWith(
      RustEngineEvent _, $Res Function(RustEngineEvent) __);
}

/// Adds pattern-matching-related methods to [RustEngineEvent].
extension RustEngineEventPatterns on RustEngineEvent {
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
    TResult Function(RustEngineEvent_Phase value)? phase,
    TResult Function(RustEngineEvent_State value)? state,
    TResult Function(RustEngineEvent_Position value)? position,
    TResult Function(RustEngineEvent_Duration value)? duration,
    TResult Function(RustEngineEvent_IsPlaying value)? isPlaying,
    TResult Function(RustEngineEvent_IsBuffering value)? isBuffering,
    TResult Function(RustEngineEvent_IsCompleted value)? isCompleted,
    TResult Function(RustEngineEvent_CurrentIndex value)? currentIndex,
    TResult Function(RustEngineEvent_QueueChanged value)? queueChanged,
    TResult Function(RustEngineEvent_NeedMoreTracks value)? needMoreTracks,
    TResult Function(RustEngineEvent_Volume value)? volume,
    TResult Function(RustEngineEvent_Rate value)? rate,
    TResult Function(RustEngineEvent_Pitch value)? pitch,
    TResult Function(RustEngineEvent_Bitrate value)? bitrate,
    TResult Function(RustEngineEvent_BufferSize value)? bufferSize,
    TResult Function(RustEngineEvent_Device value)? device,
    TResult Function(RustEngineEvent_Visualizer value)? visualizer,
    TResult Function(RustEngineEvent_VisualizerEnabled value)?
        visualizerEnabled,
    TResult Function(RustEngineEvent_BufferedRange value)? bufferedRange,
    TResult Function(RustEngineEvent_Equalizer value)? equalizer,
    TResult Function(RustEngineEvent_Preamp value)? preamp,
    TResult Function(RustEngineEvent_ReplayGain value)? replayGain,
    TResult Function(RustEngineEvent_Balance value)? balance,
    TResult Function(RustEngineEvent_Mono value)? mono,
    TResult Function(RustEngineEvent_Crossfeed value)? crossfeed,
    TResult Function(RustEngineEvent_Spatializer value)? spatializer,
    TResult Function(RustEngineEvent_Reverb value)? reverb,
    TResult Function(RustEngineEvent_Limiter value)? limiter,
    TResult Function(RustEngineEvent_CrossfadeConfig value)? crossfadeConfig,
    TResult Function(RustEngineEvent_LoopMode value)? loopMode,
    TResult Function(RustEngineEvent_Shuffle value)? shuffle,
    TResult Function(RustEngineEvent_MetaBytes value)? metaBytes,
    TResult Function(RustEngineEvent_Error value)? error,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustEngineEvent_Phase() when phase != null:
        return phase(_that);
      case RustEngineEvent_State() when state != null:
        return state(_that);
      case RustEngineEvent_Position() when position != null:
        return position(_that);
      case RustEngineEvent_Duration() when duration != null:
        return duration(_that);
      case RustEngineEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that);
      case RustEngineEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that);
      case RustEngineEvent_IsCompleted() when isCompleted != null:
        return isCompleted(_that);
      case RustEngineEvent_CurrentIndex() when currentIndex != null:
        return currentIndex(_that);
      case RustEngineEvent_QueueChanged() when queueChanged != null:
        return queueChanged(_that);
      case RustEngineEvent_NeedMoreTracks() when needMoreTracks != null:
        return needMoreTracks(_that);
      case RustEngineEvent_Volume() when volume != null:
        return volume(_that);
      case RustEngineEvent_Rate() when rate != null:
        return rate(_that);
      case RustEngineEvent_Pitch() when pitch != null:
        return pitch(_that);
      case RustEngineEvent_Bitrate() when bitrate != null:
        return bitrate(_that);
      case RustEngineEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that);
      case RustEngineEvent_Device() when device != null:
        return device(_that);
      case RustEngineEvent_Visualizer() when visualizer != null:
        return visualizer(_that);
      case RustEngineEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that);
      case RustEngineEvent_BufferedRange() when bufferedRange != null:
        return bufferedRange(_that);
      case RustEngineEvent_Equalizer() when equalizer != null:
        return equalizer(_that);
      case RustEngineEvent_Preamp() when preamp != null:
        return preamp(_that);
      case RustEngineEvent_ReplayGain() when replayGain != null:
        return replayGain(_that);
      case RustEngineEvent_Balance() when balance != null:
        return balance(_that);
      case RustEngineEvent_Mono() when mono != null:
        return mono(_that);
      case RustEngineEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that);
      case RustEngineEvent_Spatializer() when spatializer != null:
        return spatializer(_that);
      case RustEngineEvent_Reverb() when reverb != null:
        return reverb(_that);
      case RustEngineEvent_Limiter() when limiter != null:
        return limiter(_that);
      case RustEngineEvent_CrossfadeConfig() when crossfadeConfig != null:
        return crossfadeConfig(_that);
      case RustEngineEvent_LoopMode() when loopMode != null:
        return loopMode(_that);
      case RustEngineEvent_Shuffle() when shuffle != null:
        return shuffle(_that);
      case RustEngineEvent_MetaBytes() when metaBytes != null:
        return metaBytes(_that);
      case RustEngineEvent_Error() when error != null:
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
    required TResult Function(RustEngineEvent_Phase value) phase,
    required TResult Function(RustEngineEvent_State value) state,
    required TResult Function(RustEngineEvent_Position value) position,
    required TResult Function(RustEngineEvent_Duration value) duration,
    required TResult Function(RustEngineEvent_IsPlaying value) isPlaying,
    required TResult Function(RustEngineEvent_IsBuffering value) isBuffering,
    required TResult Function(RustEngineEvent_IsCompleted value) isCompleted,
    required TResult Function(RustEngineEvent_CurrentIndex value) currentIndex,
    required TResult Function(RustEngineEvent_QueueChanged value) queueChanged,
    required TResult Function(RustEngineEvent_NeedMoreTracks value)
        needMoreTracks,
    required TResult Function(RustEngineEvent_Volume value) volume,
    required TResult Function(RustEngineEvent_Rate value) rate,
    required TResult Function(RustEngineEvent_Pitch value) pitch,
    required TResult Function(RustEngineEvent_Bitrate value) bitrate,
    required TResult Function(RustEngineEvent_BufferSize value) bufferSize,
    required TResult Function(RustEngineEvent_Device value) device,
    required TResult Function(RustEngineEvent_Visualizer value) visualizer,
    required TResult Function(RustEngineEvent_VisualizerEnabled value)
        visualizerEnabled,
    required TResult Function(RustEngineEvent_BufferedRange value)
        bufferedRange,
    required TResult Function(RustEngineEvent_Equalizer value) equalizer,
    required TResult Function(RustEngineEvent_Preamp value) preamp,
    required TResult Function(RustEngineEvent_ReplayGain value) replayGain,
    required TResult Function(RustEngineEvent_Balance value) balance,
    required TResult Function(RustEngineEvent_Mono value) mono,
    required TResult Function(RustEngineEvent_Crossfeed value) crossfeed,
    required TResult Function(RustEngineEvent_Spatializer value) spatializer,
    required TResult Function(RustEngineEvent_Reverb value) reverb,
    required TResult Function(RustEngineEvent_Limiter value) limiter,
    required TResult Function(RustEngineEvent_CrossfadeConfig value)
        crossfadeConfig,
    required TResult Function(RustEngineEvent_LoopMode value) loopMode,
    required TResult Function(RustEngineEvent_Shuffle value) shuffle,
    required TResult Function(RustEngineEvent_MetaBytes value) metaBytes,
    required TResult Function(RustEngineEvent_Error value) error,
  }) {
    final _that = this;
    switch (_that) {
      case RustEngineEvent_Phase():
        return phase(_that);
      case RustEngineEvent_State():
        return state(_that);
      case RustEngineEvent_Position():
        return position(_that);
      case RustEngineEvent_Duration():
        return duration(_that);
      case RustEngineEvent_IsPlaying():
        return isPlaying(_that);
      case RustEngineEvent_IsBuffering():
        return isBuffering(_that);
      case RustEngineEvent_IsCompleted():
        return isCompleted(_that);
      case RustEngineEvent_CurrentIndex():
        return currentIndex(_that);
      case RustEngineEvent_QueueChanged():
        return queueChanged(_that);
      case RustEngineEvent_NeedMoreTracks():
        return needMoreTracks(_that);
      case RustEngineEvent_Volume():
        return volume(_that);
      case RustEngineEvent_Rate():
        return rate(_that);
      case RustEngineEvent_Pitch():
        return pitch(_that);
      case RustEngineEvent_Bitrate():
        return bitrate(_that);
      case RustEngineEvent_BufferSize():
        return bufferSize(_that);
      case RustEngineEvent_Device():
        return device(_that);
      case RustEngineEvent_Visualizer():
        return visualizer(_that);
      case RustEngineEvent_VisualizerEnabled():
        return visualizerEnabled(_that);
      case RustEngineEvent_BufferedRange():
        return bufferedRange(_that);
      case RustEngineEvent_Equalizer():
        return equalizer(_that);
      case RustEngineEvent_Preamp():
        return preamp(_that);
      case RustEngineEvent_ReplayGain():
        return replayGain(_that);
      case RustEngineEvent_Balance():
        return balance(_that);
      case RustEngineEvent_Mono():
        return mono(_that);
      case RustEngineEvent_Crossfeed():
        return crossfeed(_that);
      case RustEngineEvent_Spatializer():
        return spatializer(_that);
      case RustEngineEvent_Reverb():
        return reverb(_that);
      case RustEngineEvent_Limiter():
        return limiter(_that);
      case RustEngineEvent_CrossfadeConfig():
        return crossfadeConfig(_that);
      case RustEngineEvent_LoopMode():
        return loopMode(_that);
      case RustEngineEvent_Shuffle():
        return shuffle(_that);
      case RustEngineEvent_MetaBytes():
        return metaBytes(_that);
      case RustEngineEvent_Error():
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
    TResult? Function(RustEngineEvent_Phase value)? phase,
    TResult? Function(RustEngineEvent_State value)? state,
    TResult? Function(RustEngineEvent_Position value)? position,
    TResult? Function(RustEngineEvent_Duration value)? duration,
    TResult? Function(RustEngineEvent_IsPlaying value)? isPlaying,
    TResult? Function(RustEngineEvent_IsBuffering value)? isBuffering,
    TResult? Function(RustEngineEvent_IsCompleted value)? isCompleted,
    TResult? Function(RustEngineEvent_CurrentIndex value)? currentIndex,
    TResult? Function(RustEngineEvent_QueueChanged value)? queueChanged,
    TResult? Function(RustEngineEvent_NeedMoreTracks value)? needMoreTracks,
    TResult? Function(RustEngineEvent_Volume value)? volume,
    TResult? Function(RustEngineEvent_Rate value)? rate,
    TResult? Function(RustEngineEvent_Pitch value)? pitch,
    TResult? Function(RustEngineEvent_Bitrate value)? bitrate,
    TResult? Function(RustEngineEvent_BufferSize value)? bufferSize,
    TResult? Function(RustEngineEvent_Device value)? device,
    TResult? Function(RustEngineEvent_Visualizer value)? visualizer,
    TResult? Function(RustEngineEvent_VisualizerEnabled value)?
        visualizerEnabled,
    TResult? Function(RustEngineEvent_BufferedRange value)? bufferedRange,
    TResult? Function(RustEngineEvent_Equalizer value)? equalizer,
    TResult? Function(RustEngineEvent_Preamp value)? preamp,
    TResult? Function(RustEngineEvent_ReplayGain value)? replayGain,
    TResult? Function(RustEngineEvent_Balance value)? balance,
    TResult? Function(RustEngineEvent_Mono value)? mono,
    TResult? Function(RustEngineEvent_Crossfeed value)? crossfeed,
    TResult? Function(RustEngineEvent_Spatializer value)? spatializer,
    TResult? Function(RustEngineEvent_Reverb value)? reverb,
    TResult? Function(RustEngineEvent_Limiter value)? limiter,
    TResult? Function(RustEngineEvent_CrossfadeConfig value)? crossfadeConfig,
    TResult? Function(RustEngineEvent_LoopMode value)? loopMode,
    TResult? Function(RustEngineEvent_Shuffle value)? shuffle,
    TResult? Function(RustEngineEvent_MetaBytes value)? metaBytes,
    TResult? Function(RustEngineEvent_Error value)? error,
  }) {
    final _that = this;
    switch (_that) {
      case RustEngineEvent_Phase() when phase != null:
        return phase(_that);
      case RustEngineEvent_State() when state != null:
        return state(_that);
      case RustEngineEvent_Position() when position != null:
        return position(_that);
      case RustEngineEvent_Duration() when duration != null:
        return duration(_that);
      case RustEngineEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that);
      case RustEngineEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that);
      case RustEngineEvent_IsCompleted() when isCompleted != null:
        return isCompleted(_that);
      case RustEngineEvent_CurrentIndex() when currentIndex != null:
        return currentIndex(_that);
      case RustEngineEvent_QueueChanged() when queueChanged != null:
        return queueChanged(_that);
      case RustEngineEvent_NeedMoreTracks() when needMoreTracks != null:
        return needMoreTracks(_that);
      case RustEngineEvent_Volume() when volume != null:
        return volume(_that);
      case RustEngineEvent_Rate() when rate != null:
        return rate(_that);
      case RustEngineEvent_Pitch() when pitch != null:
        return pitch(_that);
      case RustEngineEvent_Bitrate() when bitrate != null:
        return bitrate(_that);
      case RustEngineEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that);
      case RustEngineEvent_Device() when device != null:
        return device(_that);
      case RustEngineEvent_Visualizer() when visualizer != null:
        return visualizer(_that);
      case RustEngineEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that);
      case RustEngineEvent_BufferedRange() when bufferedRange != null:
        return bufferedRange(_that);
      case RustEngineEvent_Equalizer() when equalizer != null:
        return equalizer(_that);
      case RustEngineEvent_Preamp() when preamp != null:
        return preamp(_that);
      case RustEngineEvent_ReplayGain() when replayGain != null:
        return replayGain(_that);
      case RustEngineEvent_Balance() when balance != null:
        return balance(_that);
      case RustEngineEvent_Mono() when mono != null:
        return mono(_that);
      case RustEngineEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that);
      case RustEngineEvent_Spatializer() when spatializer != null:
        return spatializer(_that);
      case RustEngineEvent_Reverb() when reverb != null:
        return reverb(_that);
      case RustEngineEvent_Limiter() when limiter != null:
        return limiter(_that);
      case RustEngineEvent_CrossfadeConfig() when crossfadeConfig != null:
        return crossfadeConfig(_that);
      case RustEngineEvent_LoopMode() when loopMode != null:
        return loopMode(_that);
      case RustEngineEvent_Shuffle() when shuffle != null:
        return shuffle(_that);
      case RustEngineEvent_MetaBytes() when metaBytes != null:
        return metaBytes(_that);
      case RustEngineEvent_Error() when error != null:
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
    TResult Function(int field0)? phase,
    TResult Function(int field0)? state,
    TResult Function(PlatformInt64 field0)? position,
    TResult Function(PlatformInt64 field0)? duration,
    TResult Function(bool field0)? isPlaying,
    TResult Function(bool field0)? isBuffering,
    TResult Function(bool field0)? isCompleted,
    TResult Function(int field0)? currentIndex,
    TResult Function(List<RustAudioSource> field0)? queueChanged,
    TResult Function(PlatformInt64 currentTrackId, BigInt remainingTracks)?
        needMoreTracks,
    TResult Function(double field0)? volume,
    TResult Function(double field0)? rate,
    TResult Function(double field0)? pitch,
    TResult Function(int field0)? bitrate,
    TResult Function(int field0)? bufferSize,
    TResult Function(RustAudioDevice field0)? device,
    TResult Function(RustVisualizerData field0)? visualizer,
    TResult Function(bool field0)? visualizerEnabled,
    TResult Function(RustBufferedRange field0)? bufferedRange,
    TResult Function(RustEqualizerParams field0)? equalizer,
    TResult Function(double field0)? preamp,
    TResult Function(RustReplayGainConfig field0)? replayGain,
    TResult Function(double field0)? balance,
    TResult Function(bool field0)? mono,
    TResult Function(int field0)? crossfeed,
    TResult Function(bool enabled, double width)? spatializer,
    TResult Function(RustReverbParams field0)? reverb,
    TResult Function(bool field0)? limiter,
    TResult Function(RustCrossfadeConfig field0)? crossfadeConfig,
    TResult Function(int field0)? loopMode,
    TResult Function(bool field0)? shuffle,
    TResult Function(Uint8List field0)? metaBytes,
    TResult Function(String message, int code)? error,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustEngineEvent_Phase() when phase != null:
        return phase(_that.field0);
      case RustEngineEvent_State() when state != null:
        return state(_that.field0);
      case RustEngineEvent_Position() when position != null:
        return position(_that.field0);
      case RustEngineEvent_Duration() when duration != null:
        return duration(_that.field0);
      case RustEngineEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that.field0);
      case RustEngineEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that.field0);
      case RustEngineEvent_IsCompleted() when isCompleted != null:
        return isCompleted(_that.field0);
      case RustEngineEvent_CurrentIndex() when currentIndex != null:
        return currentIndex(_that.field0);
      case RustEngineEvent_QueueChanged() when queueChanged != null:
        return queueChanged(_that.field0);
      case RustEngineEvent_NeedMoreTracks() when needMoreTracks != null:
        return needMoreTracks(_that.currentTrackId, _that.remainingTracks);
      case RustEngineEvent_Volume() when volume != null:
        return volume(_that.field0);
      case RustEngineEvent_Rate() when rate != null:
        return rate(_that.field0);
      case RustEngineEvent_Pitch() when pitch != null:
        return pitch(_that.field0);
      case RustEngineEvent_Bitrate() when bitrate != null:
        return bitrate(_that.field0);
      case RustEngineEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that.field0);
      case RustEngineEvent_Device() when device != null:
        return device(_that.field0);
      case RustEngineEvent_Visualizer() when visualizer != null:
        return visualizer(_that.field0);
      case RustEngineEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that.field0);
      case RustEngineEvent_BufferedRange() when bufferedRange != null:
        return bufferedRange(_that.field0);
      case RustEngineEvent_Equalizer() when equalizer != null:
        return equalizer(_that.field0);
      case RustEngineEvent_Preamp() when preamp != null:
        return preamp(_that.field0);
      case RustEngineEvent_ReplayGain() when replayGain != null:
        return replayGain(_that.field0);
      case RustEngineEvent_Balance() when balance != null:
        return balance(_that.field0);
      case RustEngineEvent_Mono() when mono != null:
        return mono(_that.field0);
      case RustEngineEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that.field0);
      case RustEngineEvent_Spatializer() when spatializer != null:
        return spatializer(_that.enabled, _that.width);
      case RustEngineEvent_Reverb() when reverb != null:
        return reverb(_that.field0);
      case RustEngineEvent_Limiter() when limiter != null:
        return limiter(_that.field0);
      case RustEngineEvent_CrossfadeConfig() when crossfadeConfig != null:
        return crossfadeConfig(_that.field0);
      case RustEngineEvent_LoopMode() when loopMode != null:
        return loopMode(_that.field0);
      case RustEngineEvent_Shuffle() when shuffle != null:
        return shuffle(_that.field0);
      case RustEngineEvent_MetaBytes() when metaBytes != null:
        return metaBytes(_that.field0);
      case RustEngineEvent_Error() when error != null:
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
    required TResult Function(int field0) phase,
    required TResult Function(int field0) state,
    required TResult Function(PlatformInt64 field0) position,
    required TResult Function(PlatformInt64 field0) duration,
    required TResult Function(bool field0) isPlaying,
    required TResult Function(bool field0) isBuffering,
    required TResult Function(bool field0) isCompleted,
    required TResult Function(int field0) currentIndex,
    required TResult Function(List<RustAudioSource> field0) queueChanged,
    required TResult Function(
            PlatformInt64 currentTrackId, BigInt remainingTracks)
        needMoreTracks,
    required TResult Function(double field0) volume,
    required TResult Function(double field0) rate,
    required TResult Function(double field0) pitch,
    required TResult Function(int field0) bitrate,
    required TResult Function(int field0) bufferSize,
    required TResult Function(RustAudioDevice field0) device,
    required TResult Function(RustVisualizerData field0) visualizer,
    required TResult Function(bool field0) visualizerEnabled,
    required TResult Function(RustBufferedRange field0) bufferedRange,
    required TResult Function(RustEqualizerParams field0) equalizer,
    required TResult Function(double field0) preamp,
    required TResult Function(RustReplayGainConfig field0) replayGain,
    required TResult Function(double field0) balance,
    required TResult Function(bool field0) mono,
    required TResult Function(int field0) crossfeed,
    required TResult Function(bool enabled, double width) spatializer,
    required TResult Function(RustReverbParams field0) reverb,
    required TResult Function(bool field0) limiter,
    required TResult Function(RustCrossfadeConfig field0) crossfadeConfig,
    required TResult Function(int field0) loopMode,
    required TResult Function(bool field0) shuffle,
    required TResult Function(Uint8List field0) metaBytes,
    required TResult Function(String message, int code) error,
  }) {
    final _that = this;
    switch (_that) {
      case RustEngineEvent_Phase():
        return phase(_that.field0);
      case RustEngineEvent_State():
        return state(_that.field0);
      case RustEngineEvent_Position():
        return position(_that.field0);
      case RustEngineEvent_Duration():
        return duration(_that.field0);
      case RustEngineEvent_IsPlaying():
        return isPlaying(_that.field0);
      case RustEngineEvent_IsBuffering():
        return isBuffering(_that.field0);
      case RustEngineEvent_IsCompleted():
        return isCompleted(_that.field0);
      case RustEngineEvent_CurrentIndex():
        return currentIndex(_that.field0);
      case RustEngineEvent_QueueChanged():
        return queueChanged(_that.field0);
      case RustEngineEvent_NeedMoreTracks():
        return needMoreTracks(_that.currentTrackId, _that.remainingTracks);
      case RustEngineEvent_Volume():
        return volume(_that.field0);
      case RustEngineEvent_Rate():
        return rate(_that.field0);
      case RustEngineEvent_Pitch():
        return pitch(_that.field0);
      case RustEngineEvent_Bitrate():
        return bitrate(_that.field0);
      case RustEngineEvent_BufferSize():
        return bufferSize(_that.field0);
      case RustEngineEvent_Device():
        return device(_that.field0);
      case RustEngineEvent_Visualizer():
        return visualizer(_that.field0);
      case RustEngineEvent_VisualizerEnabled():
        return visualizerEnabled(_that.field0);
      case RustEngineEvent_BufferedRange():
        return bufferedRange(_that.field0);
      case RustEngineEvent_Equalizer():
        return equalizer(_that.field0);
      case RustEngineEvent_Preamp():
        return preamp(_that.field0);
      case RustEngineEvent_ReplayGain():
        return replayGain(_that.field0);
      case RustEngineEvent_Balance():
        return balance(_that.field0);
      case RustEngineEvent_Mono():
        return mono(_that.field0);
      case RustEngineEvent_Crossfeed():
        return crossfeed(_that.field0);
      case RustEngineEvent_Spatializer():
        return spatializer(_that.enabled, _that.width);
      case RustEngineEvent_Reverb():
        return reverb(_that.field0);
      case RustEngineEvent_Limiter():
        return limiter(_that.field0);
      case RustEngineEvent_CrossfadeConfig():
        return crossfadeConfig(_that.field0);
      case RustEngineEvent_LoopMode():
        return loopMode(_that.field0);
      case RustEngineEvent_Shuffle():
        return shuffle(_that.field0);
      case RustEngineEvent_MetaBytes():
        return metaBytes(_that.field0);
      case RustEngineEvent_Error():
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
    TResult? Function(int field0)? phase,
    TResult? Function(int field0)? state,
    TResult? Function(PlatformInt64 field0)? position,
    TResult? Function(PlatformInt64 field0)? duration,
    TResult? Function(bool field0)? isPlaying,
    TResult? Function(bool field0)? isBuffering,
    TResult? Function(bool field0)? isCompleted,
    TResult? Function(int field0)? currentIndex,
    TResult? Function(List<RustAudioSource> field0)? queueChanged,
    TResult? Function(PlatformInt64 currentTrackId, BigInt remainingTracks)?
        needMoreTracks,
    TResult? Function(double field0)? volume,
    TResult? Function(double field0)? rate,
    TResult? Function(double field0)? pitch,
    TResult? Function(int field0)? bitrate,
    TResult? Function(int field0)? bufferSize,
    TResult? Function(RustAudioDevice field0)? device,
    TResult? Function(RustVisualizerData field0)? visualizer,
    TResult? Function(bool field0)? visualizerEnabled,
    TResult? Function(RustBufferedRange field0)? bufferedRange,
    TResult? Function(RustEqualizerParams field0)? equalizer,
    TResult? Function(double field0)? preamp,
    TResult? Function(RustReplayGainConfig field0)? replayGain,
    TResult? Function(double field0)? balance,
    TResult? Function(bool field0)? mono,
    TResult? Function(int field0)? crossfeed,
    TResult? Function(bool enabled, double width)? spatializer,
    TResult? Function(RustReverbParams field0)? reverb,
    TResult? Function(bool field0)? limiter,
    TResult? Function(RustCrossfadeConfig field0)? crossfadeConfig,
    TResult? Function(int field0)? loopMode,
    TResult? Function(bool field0)? shuffle,
    TResult? Function(Uint8List field0)? metaBytes,
    TResult? Function(String message, int code)? error,
  }) {
    final _that = this;
    switch (_that) {
      case RustEngineEvent_Phase() when phase != null:
        return phase(_that.field0);
      case RustEngineEvent_State() when state != null:
        return state(_that.field0);
      case RustEngineEvent_Position() when position != null:
        return position(_that.field0);
      case RustEngineEvent_Duration() when duration != null:
        return duration(_that.field0);
      case RustEngineEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that.field0);
      case RustEngineEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that.field0);
      case RustEngineEvent_IsCompleted() when isCompleted != null:
        return isCompleted(_that.field0);
      case RustEngineEvent_CurrentIndex() when currentIndex != null:
        return currentIndex(_that.field0);
      case RustEngineEvent_QueueChanged() when queueChanged != null:
        return queueChanged(_that.field0);
      case RustEngineEvent_NeedMoreTracks() when needMoreTracks != null:
        return needMoreTracks(_that.currentTrackId, _that.remainingTracks);
      case RustEngineEvent_Volume() when volume != null:
        return volume(_that.field0);
      case RustEngineEvent_Rate() when rate != null:
        return rate(_that.field0);
      case RustEngineEvent_Pitch() when pitch != null:
        return pitch(_that.field0);
      case RustEngineEvent_Bitrate() when bitrate != null:
        return bitrate(_that.field0);
      case RustEngineEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that.field0);
      case RustEngineEvent_Device() when device != null:
        return device(_that.field0);
      case RustEngineEvent_Visualizer() when visualizer != null:
        return visualizer(_that.field0);
      case RustEngineEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that.field0);
      case RustEngineEvent_BufferedRange() when bufferedRange != null:
        return bufferedRange(_that.field0);
      case RustEngineEvent_Equalizer() when equalizer != null:
        return equalizer(_that.field0);
      case RustEngineEvent_Preamp() when preamp != null:
        return preamp(_that.field0);
      case RustEngineEvent_ReplayGain() when replayGain != null:
        return replayGain(_that.field0);
      case RustEngineEvent_Balance() when balance != null:
        return balance(_that.field0);
      case RustEngineEvent_Mono() when mono != null:
        return mono(_that.field0);
      case RustEngineEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that.field0);
      case RustEngineEvent_Spatializer() when spatializer != null:
        return spatializer(_that.enabled, _that.width);
      case RustEngineEvent_Reverb() when reverb != null:
        return reverb(_that.field0);
      case RustEngineEvent_Limiter() when limiter != null:
        return limiter(_that.field0);
      case RustEngineEvent_CrossfadeConfig() when crossfadeConfig != null:
        return crossfadeConfig(_that.field0);
      case RustEngineEvent_LoopMode() when loopMode != null:
        return loopMode(_that.field0);
      case RustEngineEvent_Shuffle() when shuffle != null:
        return shuffle(_that.field0);
      case RustEngineEvent_MetaBytes() when metaBytes != null:
        return metaBytes(_that.field0);
      case RustEngineEvent_Error() when error != null:
        return error(_that.message, _that.code);
      case _:
        return null;
    }
  }
}

/// @nodoc

class RustEngineEvent_Phase extends RustEngineEvent {
  const RustEngineEvent_Phase(this.field0) : super._();

  final int field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_PhaseCopyWith<RustEngineEvent_Phase> get copyWith =>
      _$RustEngineEvent_PhaseCopyWithImpl<RustEngineEvent_Phase>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Phase &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.phase(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_PhaseCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_PhaseCopyWith(RustEngineEvent_Phase value,
          $Res Function(RustEngineEvent_Phase) _then) =
      _$RustEngineEvent_PhaseCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustEngineEvent_PhaseCopyWithImpl<$Res>
    implements $RustEngineEvent_PhaseCopyWith<$Res> {
  _$RustEngineEvent_PhaseCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Phase _self;
  final $Res Function(RustEngineEvent_Phase) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Phase(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustEngineEvent_State extends RustEngineEvent {
  const RustEngineEvent_State(this.field0) : super._();

  final int field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_StateCopyWith<RustEngineEvent_State> get copyWith =>
      _$RustEngineEvent_StateCopyWithImpl<RustEngineEvent_State>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_State &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.state(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_StateCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_StateCopyWith(RustEngineEvent_State value,
          $Res Function(RustEngineEvent_State) _then) =
      _$RustEngineEvent_StateCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustEngineEvent_StateCopyWithImpl<$Res>
    implements $RustEngineEvent_StateCopyWith<$Res> {
  _$RustEngineEvent_StateCopyWithImpl(this._self, this._then);

  final RustEngineEvent_State _self;
  final $Res Function(RustEngineEvent_State) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_State(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Position extends RustEngineEvent {
  const RustEngineEvent_Position(this.field0) : super._();

  final PlatformInt64 field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_PositionCopyWith<RustEngineEvent_Position> get copyWith =>
      _$RustEngineEvent_PositionCopyWithImpl<RustEngineEvent_Position>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Position &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.position(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_PositionCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_PositionCopyWith(RustEngineEvent_Position value,
          $Res Function(RustEngineEvent_Position) _then) =
      _$RustEngineEvent_PositionCopyWithImpl;
  @useResult
  $Res call({PlatformInt64 field0});
}

/// @nodoc
class _$RustEngineEvent_PositionCopyWithImpl<$Res>
    implements $RustEngineEvent_PositionCopyWith<$Res> {
  _$RustEngineEvent_PositionCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Position _self;
  final $Res Function(RustEngineEvent_Position) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Position(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Duration extends RustEngineEvent {
  const RustEngineEvent_Duration(this.field0) : super._();

  final PlatformInt64 field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_DurationCopyWith<RustEngineEvent_Duration> get copyWith =>
      _$RustEngineEvent_DurationCopyWithImpl<RustEngineEvent_Duration>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Duration &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.duration(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_DurationCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_DurationCopyWith(RustEngineEvent_Duration value,
          $Res Function(RustEngineEvent_Duration) _then) =
      _$RustEngineEvent_DurationCopyWithImpl;
  @useResult
  $Res call({PlatformInt64 field0});
}

/// @nodoc
class _$RustEngineEvent_DurationCopyWithImpl<$Res>
    implements $RustEngineEvent_DurationCopyWith<$Res> {
  _$RustEngineEvent_DurationCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Duration _self;
  final $Res Function(RustEngineEvent_Duration) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Duration(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
    ));
  }
}

/// @nodoc

class RustEngineEvent_IsPlaying extends RustEngineEvent {
  const RustEngineEvent_IsPlaying(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_IsPlayingCopyWith<RustEngineEvent_IsPlaying> get copyWith =>
      _$RustEngineEvent_IsPlayingCopyWithImpl<RustEngineEvent_IsPlaying>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_IsPlaying &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.isPlaying(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_IsPlayingCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_IsPlayingCopyWith(RustEngineEvent_IsPlaying value,
          $Res Function(RustEngineEvent_IsPlaying) _then) =
      _$RustEngineEvent_IsPlayingCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustEngineEvent_IsPlayingCopyWithImpl<$Res>
    implements $RustEngineEvent_IsPlayingCopyWith<$Res> {
  _$RustEngineEvent_IsPlayingCopyWithImpl(this._self, this._then);

  final RustEngineEvent_IsPlaying _self;
  final $Res Function(RustEngineEvent_IsPlaying) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_IsPlaying(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustEngineEvent_IsBuffering extends RustEngineEvent {
  const RustEngineEvent_IsBuffering(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_IsBufferingCopyWith<RustEngineEvent_IsBuffering>
      get copyWith => _$RustEngineEvent_IsBufferingCopyWithImpl<
          RustEngineEvent_IsBuffering>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_IsBuffering &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.isBuffering(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_IsBufferingCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_IsBufferingCopyWith(
          RustEngineEvent_IsBuffering value,
          $Res Function(RustEngineEvent_IsBuffering) _then) =
      _$RustEngineEvent_IsBufferingCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustEngineEvent_IsBufferingCopyWithImpl<$Res>
    implements $RustEngineEvent_IsBufferingCopyWith<$Res> {
  _$RustEngineEvent_IsBufferingCopyWithImpl(this._self, this._then);

  final RustEngineEvent_IsBuffering _self;
  final $Res Function(RustEngineEvent_IsBuffering) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_IsBuffering(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustEngineEvent_IsCompleted extends RustEngineEvent {
  const RustEngineEvent_IsCompleted(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_IsCompletedCopyWith<RustEngineEvent_IsCompleted>
      get copyWith => _$RustEngineEvent_IsCompletedCopyWithImpl<
          RustEngineEvent_IsCompleted>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_IsCompleted &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.isCompleted(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_IsCompletedCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_IsCompletedCopyWith(
          RustEngineEvent_IsCompleted value,
          $Res Function(RustEngineEvent_IsCompleted) _then) =
      _$RustEngineEvent_IsCompletedCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustEngineEvent_IsCompletedCopyWithImpl<$Res>
    implements $RustEngineEvent_IsCompletedCopyWith<$Res> {
  _$RustEngineEvent_IsCompletedCopyWithImpl(this._self, this._then);

  final RustEngineEvent_IsCompleted _self;
  final $Res Function(RustEngineEvent_IsCompleted) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_IsCompleted(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustEngineEvent_CurrentIndex extends RustEngineEvent {
  const RustEngineEvent_CurrentIndex(this.field0) : super._();

  final int field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_CurrentIndexCopyWith<RustEngineEvent_CurrentIndex>
      get copyWith => _$RustEngineEvent_CurrentIndexCopyWithImpl<
          RustEngineEvent_CurrentIndex>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_CurrentIndex &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.currentIndex(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_CurrentIndexCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_CurrentIndexCopyWith(
          RustEngineEvent_CurrentIndex value,
          $Res Function(RustEngineEvent_CurrentIndex) _then) =
      _$RustEngineEvent_CurrentIndexCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustEngineEvent_CurrentIndexCopyWithImpl<$Res>
    implements $RustEngineEvent_CurrentIndexCopyWith<$Res> {
  _$RustEngineEvent_CurrentIndexCopyWithImpl(this._self, this._then);

  final RustEngineEvent_CurrentIndex _self;
  final $Res Function(RustEngineEvent_CurrentIndex) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_CurrentIndex(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustEngineEvent_QueueChanged extends RustEngineEvent {
  const RustEngineEvent_QueueChanged(List<RustAudioSource> field0)
      : _field0 = field0,
        super._();

  final List<RustAudioSource> _field0;
  List<RustAudioSource> get field0 {
    if (_field0 is EqualUnmodifiableListView) return _field0;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_field0);
  }

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_QueueChangedCopyWith<RustEngineEvent_QueueChanged>
      get copyWith => _$RustEngineEvent_QueueChangedCopyWithImpl<
          RustEngineEvent_QueueChanged>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_QueueChanged &&
            const DeepCollectionEquality().equals(other.field0, _field0));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(_field0));
  }

  @override
  String toString() {
    return 'RustEngineEvent.queueChanged(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_QueueChangedCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_QueueChangedCopyWith(
          RustEngineEvent_QueueChanged value,
          $Res Function(RustEngineEvent_QueueChanged) _then) =
      _$RustEngineEvent_QueueChangedCopyWithImpl;
  @useResult
  $Res call({List<RustAudioSource> field0});
}

/// @nodoc
class _$RustEngineEvent_QueueChangedCopyWithImpl<$Res>
    implements $RustEngineEvent_QueueChangedCopyWith<$Res> {
  _$RustEngineEvent_QueueChangedCopyWithImpl(this._self, this._then);

  final RustEngineEvent_QueueChanged _self;
  final $Res Function(RustEngineEvent_QueueChanged) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_QueueChanged(
      null == field0
          ? _self._field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as List<RustAudioSource>,
    ));
  }
}

/// @nodoc

class RustEngineEvent_NeedMoreTracks extends RustEngineEvent {
  const RustEngineEvent_NeedMoreTracks(
      {required this.currentTrackId, required this.remainingTracks})
      : super._();

  final PlatformInt64 currentTrackId;
  final BigInt remainingTracks;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_NeedMoreTracksCopyWith<RustEngineEvent_NeedMoreTracks>
      get copyWith => _$RustEngineEvent_NeedMoreTracksCopyWithImpl<
          RustEngineEvent_NeedMoreTracks>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_NeedMoreTracks &&
            (identical(other.currentTrackId, currentTrackId) ||
                other.currentTrackId == currentTrackId) &&
            (identical(other.remainingTracks, remainingTracks) ||
                other.remainingTracks == remainingTracks));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, currentTrackId, remainingTracks);
  }

  @override
  String toString() {
    return 'RustEngineEvent.needMoreTracks(currentTrackId: $currentTrackId, remainingTracks: $remainingTracks)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_NeedMoreTracksCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_NeedMoreTracksCopyWith(
          RustEngineEvent_NeedMoreTracks value,
          $Res Function(RustEngineEvent_NeedMoreTracks) _then) =
      _$RustEngineEvent_NeedMoreTracksCopyWithImpl;
  @useResult
  $Res call({PlatformInt64 currentTrackId, BigInt remainingTracks});
}

/// @nodoc
class _$RustEngineEvent_NeedMoreTracksCopyWithImpl<$Res>
    implements $RustEngineEvent_NeedMoreTracksCopyWith<$Res> {
  _$RustEngineEvent_NeedMoreTracksCopyWithImpl(this._self, this._then);

  final RustEngineEvent_NeedMoreTracks _self;
  final $Res Function(RustEngineEvent_NeedMoreTracks) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? currentTrackId = null,
    Object? remainingTracks = null,
  }) {
    return _then(RustEngineEvent_NeedMoreTracks(
      currentTrackId: null == currentTrackId
          ? _self.currentTrackId
          : currentTrackId // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
      remainingTracks: null == remainingTracks
          ? _self.remainingTracks
          : remainingTracks // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Volume extends RustEngineEvent {
  const RustEngineEvent_Volume(this.field0) : super._();

  final double field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_VolumeCopyWith<RustEngineEvent_Volume> get copyWith =>
      _$RustEngineEvent_VolumeCopyWithImpl<RustEngineEvent_Volume>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Volume &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.volume(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_VolumeCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_VolumeCopyWith(RustEngineEvent_Volume value,
          $Res Function(RustEngineEvent_Volume) _then) =
      _$RustEngineEvent_VolumeCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustEngineEvent_VolumeCopyWithImpl<$Res>
    implements $RustEngineEvent_VolumeCopyWith<$Res> {
  _$RustEngineEvent_VolumeCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Volume _self;
  final $Res Function(RustEngineEvent_Volume) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Volume(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Rate extends RustEngineEvent {
  const RustEngineEvent_Rate(this.field0) : super._();

  final double field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_RateCopyWith<RustEngineEvent_Rate> get copyWith =>
      _$RustEngineEvent_RateCopyWithImpl<RustEngineEvent_Rate>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Rate &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.rate(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_RateCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_RateCopyWith(RustEngineEvent_Rate value,
          $Res Function(RustEngineEvent_Rate) _then) =
      _$RustEngineEvent_RateCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustEngineEvent_RateCopyWithImpl<$Res>
    implements $RustEngineEvent_RateCopyWith<$Res> {
  _$RustEngineEvent_RateCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Rate _self;
  final $Res Function(RustEngineEvent_Rate) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Rate(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Pitch extends RustEngineEvent {
  const RustEngineEvent_Pitch(this.field0) : super._();

  final double field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_PitchCopyWith<RustEngineEvent_Pitch> get copyWith =>
      _$RustEngineEvent_PitchCopyWithImpl<RustEngineEvent_Pitch>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Pitch &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.pitch(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_PitchCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_PitchCopyWith(RustEngineEvent_Pitch value,
          $Res Function(RustEngineEvent_Pitch) _then) =
      _$RustEngineEvent_PitchCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustEngineEvent_PitchCopyWithImpl<$Res>
    implements $RustEngineEvent_PitchCopyWith<$Res> {
  _$RustEngineEvent_PitchCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Pitch _self;
  final $Res Function(RustEngineEvent_Pitch) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Pitch(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Bitrate extends RustEngineEvent {
  const RustEngineEvent_Bitrate(this.field0) : super._();

  final int field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_BitrateCopyWith<RustEngineEvent_Bitrate> get copyWith =>
      _$RustEngineEvent_BitrateCopyWithImpl<RustEngineEvent_Bitrate>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Bitrate &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.bitrate(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_BitrateCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_BitrateCopyWith(RustEngineEvent_Bitrate value,
          $Res Function(RustEngineEvent_Bitrate) _then) =
      _$RustEngineEvent_BitrateCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustEngineEvent_BitrateCopyWithImpl<$Res>
    implements $RustEngineEvent_BitrateCopyWith<$Res> {
  _$RustEngineEvent_BitrateCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Bitrate _self;
  final $Res Function(RustEngineEvent_Bitrate) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Bitrate(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustEngineEvent_BufferSize extends RustEngineEvent {
  const RustEngineEvent_BufferSize(this.field0) : super._();

  final int field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_BufferSizeCopyWith<RustEngineEvent_BufferSize>
      get copyWith =>
          _$RustEngineEvent_BufferSizeCopyWithImpl<RustEngineEvent_BufferSize>(
              this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_BufferSize &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.bufferSize(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_BufferSizeCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_BufferSizeCopyWith(RustEngineEvent_BufferSize value,
          $Res Function(RustEngineEvent_BufferSize) _then) =
      _$RustEngineEvent_BufferSizeCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustEngineEvent_BufferSizeCopyWithImpl<$Res>
    implements $RustEngineEvent_BufferSizeCopyWith<$Res> {
  _$RustEngineEvent_BufferSizeCopyWithImpl(this._self, this._then);

  final RustEngineEvent_BufferSize _self;
  final $Res Function(RustEngineEvent_BufferSize) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_BufferSize(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Device extends RustEngineEvent {
  const RustEngineEvent_Device(this.field0) : super._();

  final RustAudioDevice field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_DeviceCopyWith<RustEngineEvent_Device> get copyWith =>
      _$RustEngineEvent_DeviceCopyWithImpl<RustEngineEvent_Device>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Device &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.device(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_DeviceCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_DeviceCopyWith(RustEngineEvent_Device value,
          $Res Function(RustEngineEvent_Device) _then) =
      _$RustEngineEvent_DeviceCopyWithImpl;
  @useResult
  $Res call({RustAudioDevice field0});
}

/// @nodoc
class _$RustEngineEvent_DeviceCopyWithImpl<$Res>
    implements $RustEngineEvent_DeviceCopyWith<$Res> {
  _$RustEngineEvent_DeviceCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Device _self;
  final $Res Function(RustEngineEvent_Device) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Device(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustAudioDevice,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Visualizer extends RustEngineEvent {
  const RustEngineEvent_Visualizer(this.field0) : super._();

  final RustVisualizerData field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_VisualizerCopyWith<RustEngineEvent_Visualizer>
      get copyWith =>
          _$RustEngineEvent_VisualizerCopyWithImpl<RustEngineEvent_Visualizer>(
              this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Visualizer &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.visualizer(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_VisualizerCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_VisualizerCopyWith(RustEngineEvent_Visualizer value,
          $Res Function(RustEngineEvent_Visualizer) _then) =
      _$RustEngineEvent_VisualizerCopyWithImpl;
  @useResult
  $Res call({RustVisualizerData field0});
}

/// @nodoc
class _$RustEngineEvent_VisualizerCopyWithImpl<$Res>
    implements $RustEngineEvent_VisualizerCopyWith<$Res> {
  _$RustEngineEvent_VisualizerCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Visualizer _self;
  final $Res Function(RustEngineEvent_Visualizer) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Visualizer(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustVisualizerData,
    ));
  }
}

/// @nodoc

class RustEngineEvent_VisualizerEnabled extends RustEngineEvent {
  const RustEngineEvent_VisualizerEnabled(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_VisualizerEnabledCopyWith<RustEngineEvent_VisualizerEnabled>
      get copyWith => _$RustEngineEvent_VisualizerEnabledCopyWithImpl<
          RustEngineEvent_VisualizerEnabled>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_VisualizerEnabled &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.visualizerEnabled(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_VisualizerEnabledCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_VisualizerEnabledCopyWith(
          RustEngineEvent_VisualizerEnabled value,
          $Res Function(RustEngineEvent_VisualizerEnabled) _then) =
      _$RustEngineEvent_VisualizerEnabledCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustEngineEvent_VisualizerEnabledCopyWithImpl<$Res>
    implements $RustEngineEvent_VisualizerEnabledCopyWith<$Res> {
  _$RustEngineEvent_VisualizerEnabledCopyWithImpl(this._self, this._then);

  final RustEngineEvent_VisualizerEnabled _self;
  final $Res Function(RustEngineEvent_VisualizerEnabled) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_VisualizerEnabled(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustEngineEvent_BufferedRange extends RustEngineEvent {
  const RustEngineEvent_BufferedRange(this.field0) : super._();

  final RustBufferedRange field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_BufferedRangeCopyWith<RustEngineEvent_BufferedRange>
      get copyWith => _$RustEngineEvent_BufferedRangeCopyWithImpl<
          RustEngineEvent_BufferedRange>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_BufferedRange &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.bufferedRange(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_BufferedRangeCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_BufferedRangeCopyWith(
          RustEngineEvent_BufferedRange value,
          $Res Function(RustEngineEvent_BufferedRange) _then) =
      _$RustEngineEvent_BufferedRangeCopyWithImpl;
  @useResult
  $Res call({RustBufferedRange field0});
}

/// @nodoc
class _$RustEngineEvent_BufferedRangeCopyWithImpl<$Res>
    implements $RustEngineEvent_BufferedRangeCopyWith<$Res> {
  _$RustEngineEvent_BufferedRangeCopyWithImpl(this._self, this._then);

  final RustEngineEvent_BufferedRange _self;
  final $Res Function(RustEngineEvent_BufferedRange) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_BufferedRange(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustBufferedRange,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Equalizer extends RustEngineEvent {
  const RustEngineEvent_Equalizer(this.field0) : super._();

  final RustEqualizerParams field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_EqualizerCopyWith<RustEngineEvent_Equalizer> get copyWith =>
      _$RustEngineEvent_EqualizerCopyWithImpl<RustEngineEvent_Equalizer>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Equalizer &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.equalizer(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_EqualizerCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_EqualizerCopyWith(RustEngineEvent_Equalizer value,
          $Res Function(RustEngineEvent_Equalizer) _then) =
      _$RustEngineEvent_EqualizerCopyWithImpl;
  @useResult
  $Res call({RustEqualizerParams field0});
}

/// @nodoc
class _$RustEngineEvent_EqualizerCopyWithImpl<$Res>
    implements $RustEngineEvent_EqualizerCopyWith<$Res> {
  _$RustEngineEvent_EqualizerCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Equalizer _self;
  final $Res Function(RustEngineEvent_Equalizer) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Equalizer(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustEqualizerParams,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Preamp extends RustEngineEvent {
  const RustEngineEvent_Preamp(this.field0) : super._();

  final double field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_PreampCopyWith<RustEngineEvent_Preamp> get copyWith =>
      _$RustEngineEvent_PreampCopyWithImpl<RustEngineEvent_Preamp>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Preamp &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.preamp(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_PreampCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_PreampCopyWith(RustEngineEvent_Preamp value,
          $Res Function(RustEngineEvent_Preamp) _then) =
      _$RustEngineEvent_PreampCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustEngineEvent_PreampCopyWithImpl<$Res>
    implements $RustEngineEvent_PreampCopyWith<$Res> {
  _$RustEngineEvent_PreampCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Preamp _self;
  final $Res Function(RustEngineEvent_Preamp) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Preamp(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustEngineEvent_ReplayGain extends RustEngineEvent {
  const RustEngineEvent_ReplayGain(this.field0) : super._();

  final RustReplayGainConfig field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_ReplayGainCopyWith<RustEngineEvent_ReplayGain>
      get copyWith =>
          _$RustEngineEvent_ReplayGainCopyWithImpl<RustEngineEvent_ReplayGain>(
              this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_ReplayGain &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.replayGain(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_ReplayGainCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_ReplayGainCopyWith(RustEngineEvent_ReplayGain value,
          $Res Function(RustEngineEvent_ReplayGain) _then) =
      _$RustEngineEvent_ReplayGainCopyWithImpl;
  @useResult
  $Res call({RustReplayGainConfig field0});
}

/// @nodoc
class _$RustEngineEvent_ReplayGainCopyWithImpl<$Res>
    implements $RustEngineEvent_ReplayGainCopyWith<$Res> {
  _$RustEngineEvent_ReplayGainCopyWithImpl(this._self, this._then);

  final RustEngineEvent_ReplayGain _self;
  final $Res Function(RustEngineEvent_ReplayGain) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_ReplayGain(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustReplayGainConfig,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Balance extends RustEngineEvent {
  const RustEngineEvent_Balance(this.field0) : super._();

  final double field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_BalanceCopyWith<RustEngineEvent_Balance> get copyWith =>
      _$RustEngineEvent_BalanceCopyWithImpl<RustEngineEvent_Balance>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Balance &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.balance(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_BalanceCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_BalanceCopyWith(RustEngineEvent_Balance value,
          $Res Function(RustEngineEvent_Balance) _then) =
      _$RustEngineEvent_BalanceCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustEngineEvent_BalanceCopyWithImpl<$Res>
    implements $RustEngineEvent_BalanceCopyWith<$Res> {
  _$RustEngineEvent_BalanceCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Balance _self;
  final $Res Function(RustEngineEvent_Balance) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Balance(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Mono extends RustEngineEvent {
  const RustEngineEvent_Mono(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_MonoCopyWith<RustEngineEvent_Mono> get copyWith =>
      _$RustEngineEvent_MonoCopyWithImpl<RustEngineEvent_Mono>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Mono &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.mono(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_MonoCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_MonoCopyWith(RustEngineEvent_Mono value,
          $Res Function(RustEngineEvent_Mono) _then) =
      _$RustEngineEvent_MonoCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustEngineEvent_MonoCopyWithImpl<$Res>
    implements $RustEngineEvent_MonoCopyWith<$Res> {
  _$RustEngineEvent_MonoCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Mono _self;
  final $Res Function(RustEngineEvent_Mono) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Mono(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Crossfeed extends RustEngineEvent {
  const RustEngineEvent_Crossfeed(this.field0) : super._();

  final int field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_CrossfeedCopyWith<RustEngineEvent_Crossfeed> get copyWith =>
      _$RustEngineEvent_CrossfeedCopyWithImpl<RustEngineEvent_Crossfeed>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Crossfeed &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.crossfeed(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_CrossfeedCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_CrossfeedCopyWith(RustEngineEvent_Crossfeed value,
          $Res Function(RustEngineEvent_Crossfeed) _then) =
      _$RustEngineEvent_CrossfeedCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustEngineEvent_CrossfeedCopyWithImpl<$Res>
    implements $RustEngineEvent_CrossfeedCopyWith<$Res> {
  _$RustEngineEvent_CrossfeedCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Crossfeed _self;
  final $Res Function(RustEngineEvent_Crossfeed) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Crossfeed(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Spatializer extends RustEngineEvent {
  const RustEngineEvent_Spatializer(
      {required this.enabled, required this.width})
      : super._();

  final bool enabled;
  final double width;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_SpatializerCopyWith<RustEngineEvent_Spatializer>
      get copyWith => _$RustEngineEvent_SpatializerCopyWithImpl<
          RustEngineEvent_Spatializer>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Spatializer &&
            (identical(other.enabled, enabled) || other.enabled == enabled) &&
            (identical(other.width, width) || other.width == width));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, enabled, width);
  }

  @override
  String toString() {
    return 'RustEngineEvent.spatializer(enabled: $enabled, width: $width)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_SpatializerCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_SpatializerCopyWith(
          RustEngineEvent_Spatializer value,
          $Res Function(RustEngineEvent_Spatializer) _then) =
      _$RustEngineEvent_SpatializerCopyWithImpl;
  @useResult
  $Res call({bool enabled, double width});
}

/// @nodoc
class _$RustEngineEvent_SpatializerCopyWithImpl<$Res>
    implements $RustEngineEvent_SpatializerCopyWith<$Res> {
  _$RustEngineEvent_SpatializerCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Spatializer _self;
  final $Res Function(RustEngineEvent_Spatializer) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? enabled = null,
    Object? width = null,
  }) {
    return _then(RustEngineEvent_Spatializer(
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

class RustEngineEvent_Reverb extends RustEngineEvent {
  const RustEngineEvent_Reverb(this.field0) : super._();

  final RustReverbParams field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_ReverbCopyWith<RustEngineEvent_Reverb> get copyWith =>
      _$RustEngineEvent_ReverbCopyWithImpl<RustEngineEvent_Reverb>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Reverb &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.reverb(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_ReverbCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_ReverbCopyWith(RustEngineEvent_Reverb value,
          $Res Function(RustEngineEvent_Reverb) _then) =
      _$RustEngineEvent_ReverbCopyWithImpl;
  @useResult
  $Res call({RustReverbParams field0});
}

/// @nodoc
class _$RustEngineEvent_ReverbCopyWithImpl<$Res>
    implements $RustEngineEvent_ReverbCopyWith<$Res> {
  _$RustEngineEvent_ReverbCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Reverb _self;
  final $Res Function(RustEngineEvent_Reverb) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Reverb(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustReverbParams,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Limiter extends RustEngineEvent {
  const RustEngineEvent_Limiter(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_LimiterCopyWith<RustEngineEvent_Limiter> get copyWith =>
      _$RustEngineEvent_LimiterCopyWithImpl<RustEngineEvent_Limiter>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Limiter &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.limiter(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_LimiterCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_LimiterCopyWith(RustEngineEvent_Limiter value,
          $Res Function(RustEngineEvent_Limiter) _then) =
      _$RustEngineEvent_LimiterCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustEngineEvent_LimiterCopyWithImpl<$Res>
    implements $RustEngineEvent_LimiterCopyWith<$Res> {
  _$RustEngineEvent_LimiterCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Limiter _self;
  final $Res Function(RustEngineEvent_Limiter) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Limiter(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustEngineEvent_CrossfadeConfig extends RustEngineEvent {
  const RustEngineEvent_CrossfadeConfig(this.field0) : super._();

  final RustCrossfadeConfig field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_CrossfadeConfigCopyWith<RustEngineEvent_CrossfadeConfig>
      get copyWith => _$RustEngineEvent_CrossfadeConfigCopyWithImpl<
          RustEngineEvent_CrossfadeConfig>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_CrossfadeConfig &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.crossfadeConfig(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_CrossfadeConfigCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_CrossfadeConfigCopyWith(
          RustEngineEvent_CrossfadeConfig value,
          $Res Function(RustEngineEvent_CrossfadeConfig) _then) =
      _$RustEngineEvent_CrossfadeConfigCopyWithImpl;
  @useResult
  $Res call({RustCrossfadeConfig field0});
}

/// @nodoc
class _$RustEngineEvent_CrossfadeConfigCopyWithImpl<$Res>
    implements $RustEngineEvent_CrossfadeConfigCopyWith<$Res> {
  _$RustEngineEvent_CrossfadeConfigCopyWithImpl(this._self, this._then);

  final RustEngineEvent_CrossfadeConfig _self;
  final $Res Function(RustEngineEvent_CrossfadeConfig) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_CrossfadeConfig(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustCrossfadeConfig,
    ));
  }
}

/// @nodoc

class RustEngineEvent_LoopMode extends RustEngineEvent {
  const RustEngineEvent_LoopMode(this.field0) : super._();

  final int field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_LoopModeCopyWith<RustEngineEvent_LoopMode> get copyWith =>
      _$RustEngineEvent_LoopModeCopyWithImpl<RustEngineEvent_LoopMode>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_LoopMode &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.loopMode(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_LoopModeCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_LoopModeCopyWith(RustEngineEvent_LoopMode value,
          $Res Function(RustEngineEvent_LoopMode) _then) =
      _$RustEngineEvent_LoopModeCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustEngineEvent_LoopModeCopyWithImpl<$Res>
    implements $RustEngineEvent_LoopModeCopyWith<$Res> {
  _$RustEngineEvent_LoopModeCopyWithImpl(this._self, this._then);

  final RustEngineEvent_LoopMode _self;
  final $Res Function(RustEngineEvent_LoopMode) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_LoopMode(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Shuffle extends RustEngineEvent {
  const RustEngineEvent_Shuffle(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_ShuffleCopyWith<RustEngineEvent_Shuffle> get copyWith =>
      _$RustEngineEvent_ShuffleCopyWithImpl<RustEngineEvent_Shuffle>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Shuffle &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustEngineEvent.shuffle(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_ShuffleCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_ShuffleCopyWith(RustEngineEvent_Shuffle value,
          $Res Function(RustEngineEvent_Shuffle) _then) =
      _$RustEngineEvent_ShuffleCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustEngineEvent_ShuffleCopyWithImpl<$Res>
    implements $RustEngineEvent_ShuffleCopyWith<$Res> {
  _$RustEngineEvent_ShuffleCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Shuffle _self;
  final $Res Function(RustEngineEvent_Shuffle) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_Shuffle(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustEngineEvent_MetaBytes extends RustEngineEvent {
  const RustEngineEvent_MetaBytes(this.field0) : super._();

  final Uint8List field0;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_MetaBytesCopyWith<RustEngineEvent_MetaBytes> get copyWith =>
      _$RustEngineEvent_MetaBytesCopyWithImpl<RustEngineEvent_MetaBytes>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_MetaBytes &&
            const DeepCollectionEquality().equals(other.field0, field0));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(field0));
  }

  @override
  String toString() {
    return 'RustEngineEvent.metaBytes(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_MetaBytesCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_MetaBytesCopyWith(RustEngineEvent_MetaBytes value,
          $Res Function(RustEngineEvent_MetaBytes) _then) =
      _$RustEngineEvent_MetaBytesCopyWithImpl;
  @useResult
  $Res call({Uint8List field0});
}

/// @nodoc
class _$RustEngineEvent_MetaBytesCopyWithImpl<$Res>
    implements $RustEngineEvent_MetaBytesCopyWith<$Res> {
  _$RustEngineEvent_MetaBytesCopyWithImpl(this._self, this._then);

  final RustEngineEvent_MetaBytes _self;
  final $Res Function(RustEngineEvent_MetaBytes) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustEngineEvent_MetaBytes(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as Uint8List,
    ));
  }
}

/// @nodoc

class RustEngineEvent_Error extends RustEngineEvent {
  const RustEngineEvent_Error({required this.message, required this.code})
      : super._();

  final String message;
  final int code;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustEngineEvent_ErrorCopyWith<RustEngineEvent_Error> get copyWith =>
      _$RustEngineEvent_ErrorCopyWithImpl<RustEngineEvent_Error>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustEngineEvent_Error &&
            (identical(other.message, message) || other.message == message) &&
            (identical(other.code, code) || other.code == code));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, message, code);
  }

  @override
  String toString() {
    return 'RustEngineEvent.error(message: $message, code: $code)';
  }
}

/// @nodoc
abstract mixin class $RustEngineEvent_ErrorCopyWith<$Res>
    implements $RustEngineEventCopyWith<$Res> {
  factory $RustEngineEvent_ErrorCopyWith(RustEngineEvent_Error value,
          $Res Function(RustEngineEvent_Error) _then) =
      _$RustEngineEvent_ErrorCopyWithImpl;
  @useResult
  $Res call({String message, int code});
}

/// @nodoc
class _$RustEngineEvent_ErrorCopyWithImpl<$Res>
    implements $RustEngineEvent_ErrorCopyWith<$Res> {
  _$RustEngineEvent_ErrorCopyWithImpl(this._self, this._then);

  final RustEngineEvent_Error _self;
  final $Res Function(RustEngineEvent_Error) _then;

  /// Create a copy of RustEngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? message = null,
    Object? code = null,
  }) {
    return _then(RustEngineEvent_Error(
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
    TResult Function(RustPlayerEvent_DartReadRequest value)? dartReadRequest,
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
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that);
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
    required TResult Function(RustPlayerEvent_DartReadRequest value)
        dartReadRequest,
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
      case RustPlayerEvent_DartReadRequest():
        return dartReadRequest(_that);
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
    TResult? Function(RustPlayerEvent_DartReadRequest value)? dartReadRequest,
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
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that);
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
    TResult Function(RustDartReadRequest field0)? dartReadRequest,
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
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that.field0);
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
    required TResult Function(RustDartReadRequest field0) dartReadRequest,
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
      case RustPlayerEvent_DartReadRequest():
        return dartReadRequest(_that.field0);
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
    TResult? Function(RustDartReadRequest field0)? dartReadRequest,
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
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that.field0);
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

class RustPlayerEvent_DartReadRequest extends RustPlayerEvent {
  const RustPlayerEvent_DartReadRequest(this.field0) : super._();

  final RustDartReadRequest field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_DartReadRequestCopyWith<RustPlayerEvent_DartReadRequest>
      get copyWith => _$RustPlayerEvent_DartReadRequestCopyWithImpl<
          RustPlayerEvent_DartReadRequest>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_DartReadRequest &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.dartReadRequest(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_DartReadRequestCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_DartReadRequestCopyWith(
          RustPlayerEvent_DartReadRequest value,
          $Res Function(RustPlayerEvent_DartReadRequest) _then) =
      _$RustPlayerEvent_DartReadRequestCopyWithImpl;
  @useResult
  $Res call({RustDartReadRequest field0});
}

/// @nodoc
class _$RustPlayerEvent_DartReadRequestCopyWithImpl<$Res>
    implements $RustPlayerEvent_DartReadRequestCopyWith<$Res> {
  _$RustPlayerEvent_DartReadRequestCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_DartReadRequest _self;
  final $Res Function(RustPlayerEvent_DartReadRequest) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_DartReadRequest(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustDartReadRequest,
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
