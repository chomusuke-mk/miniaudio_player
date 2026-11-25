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
    TResult Function(RustPlayerEvent_AudioInfo value)? audioInfo,
    TResult Function(RustPlayerEvent_PlaybackState value)? playbackState,
    TResult Function(RustPlayerEvent_Position value)? position,
    TResult Function(RustPlayerEvent_IsPlaying value)? isPlaying,
    TResult Function(RustPlayerEvent_IsBuffering value)? isBuffering,
    TResult Function(RustPlayerEvent_Buffer value)? buffer,
    TResult Function(RustPlayerEvent_Queue value)? queue,
    TResult Function(RustPlayerEvent_CurrentIndex value)? currentIndex,
    TResult Function(RustPlayerEvent_IsCrossfading value)? isCrossfading,
    TResult Function(RustPlayerEvent_CrossfadeConfig value)? crossfadeConfig,
    TResult Function(RustPlayerEvent_Visualizer value)? visualizer,
    TResult Function(RustPlayerEvent_VisualizerEnabled value)?
        visualizerEnabled,
    TResult Function(RustPlayerEvent_VisualizerSource value)? visualizerSource,
    TResult Function(RustPlayerEvent_Volume value)? volume,
    TResult Function(RustPlayerEvent_Rate value)? rate,
    TResult Function(RustPlayerEvent_Pitch value)? pitch,
    TResult Function(RustPlayerEvent_Balance value)? balance,
    TResult Function(RustPlayerEvent_Mono value)? mono,
    TResult Function(RustPlayerEvent_BufferSize value)? bufferSize,
    TResult Function(RustPlayerEvent_SilenceConfig value)? silenceConfig,
    TResult Function(RustPlayerEvent_SilenceSaved value)? silenceSaved,
    TResult Function(RustPlayerEvent_Equalizer value)? equalizer,
    TResult Function(RustPlayerEvent_Preamp value)? preamp,
    TResult Function(RustPlayerEvent_ReplayGain value)? replayGain,
    TResult Function(RustPlayerEvent_ReplayGainMode value)? replayGainMode,
    TResult Function(RustPlayerEvent_DefaultReplayGain value)?
        defaultReplayGain,
    TResult Function(RustPlayerEvent_Crossfeed value)? crossfeed,
    TResult Function(RustPlayerEvent_Spatializer value)? spatializer,
    TResult Function(RustPlayerEvent_Reverb value)? reverb,
    TResult Function(RustPlayerEvent_Limiter value)? limiter,
    TResult Function(RustPlayerEvent_IsRecording value)? isRecording,
    TResult Function(RustPlayerEvent_RecordedDuration value)? recordedDuration,
    TResult Function(RustPlayerEvent_IsDuckingActive value)? isDuckingActive,
    TResult Function(RustPlayerEvent_MicRmsLevel value)? micRmsLevel,
    TResult Function(RustPlayerEvent_VoiceCompleted value)? voiceCompleted,
    TResult Function(RustPlayerEvent_LoadedEffects value)? loadedEffects,
    TResult Function(RustPlayerEvent_ActiveVoices value)? activeVoices,
    TResult Function(RustPlayerEvent_AudioMetadata value)? audioMetadata,
    TResult Function(RustPlayerEvent_MetadataEnabled value)? metadataEnabled,
    TResult Function(RustPlayerEvent_RecordingState value)? recordingState,
    TResult Function(RustPlayerEvent_LoopMode value)? loopMode,
    TResult Function(RustPlayerEvent_IsShuffled value)? isShuffled,
    TResult Function(RustPlayerEvent_InfiniteMix value)? infiniteMix,
    TResult Function(RustPlayerEvent_PauseOnDeviceChange value)?
        pauseOnDeviceChange,
    TResult Function(RustPlayerEvent_Inputs value)? inputs,
    TResult Function(RustPlayerEvent_OutputDevices value)? outputDevices,
    TResult Function(RustPlayerEvent_InputDevices value)? inputDevices,
    TResult Function(RustPlayerEvent_DartReadRequest value)? dartReadRequest,
    TResult Function(RustPlayerEvent_DartResolveRequest value)?
        dartResolveRequest,
    TResult Function(RustPlayerEvent_NeedMoreTracks value)? needMoreTracks,
    TResult Function(RustPlayerEvent_Outputs value)? outputs,
    TResult Function(RustPlayerEvent_Error value)? error,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_AudioInfo() when audioInfo != null:
        return audioInfo(_that);
      case RustPlayerEvent_PlaybackState() when playbackState != null:
        return playbackState(_that);
      case RustPlayerEvent_Position() when position != null:
        return position(_that);
      case RustPlayerEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that);
      case RustPlayerEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that);
      case RustPlayerEvent_Buffer() when buffer != null:
        return buffer(_that);
      case RustPlayerEvent_Queue() when queue != null:
        return queue(_that);
      case RustPlayerEvent_CurrentIndex() when currentIndex != null:
        return currentIndex(_that);
      case RustPlayerEvent_IsCrossfading() when isCrossfading != null:
        return isCrossfading(_that);
      case RustPlayerEvent_CrossfadeConfig() when crossfadeConfig != null:
        return crossfadeConfig(_that);
      case RustPlayerEvent_Visualizer() when visualizer != null:
        return visualizer(_that);
      case RustPlayerEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that);
      case RustPlayerEvent_VisualizerSource() when visualizerSource != null:
        return visualizerSource(_that);
      case RustPlayerEvent_Volume() when volume != null:
        return volume(_that);
      case RustPlayerEvent_Rate() when rate != null:
        return rate(_that);
      case RustPlayerEvent_Pitch() when pitch != null:
        return pitch(_that);
      case RustPlayerEvent_Balance() when balance != null:
        return balance(_that);
      case RustPlayerEvent_Mono() when mono != null:
        return mono(_that);
      case RustPlayerEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that);
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
      case RustPlayerEvent_ReplayGainMode() when replayGainMode != null:
        return replayGainMode(_that);
      case RustPlayerEvent_DefaultReplayGain() when defaultReplayGain != null:
        return defaultReplayGain(_that);
      case RustPlayerEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that);
      case RustPlayerEvent_Spatializer() when spatializer != null:
        return spatializer(_that);
      case RustPlayerEvent_Reverb() when reverb != null:
        return reverb(_that);
      case RustPlayerEvent_Limiter() when limiter != null:
        return limiter(_that);
      case RustPlayerEvent_IsRecording() when isRecording != null:
        return isRecording(_that);
      case RustPlayerEvent_RecordedDuration() when recordedDuration != null:
        return recordedDuration(_that);
      case RustPlayerEvent_IsDuckingActive() when isDuckingActive != null:
        return isDuckingActive(_that);
      case RustPlayerEvent_MicRmsLevel() when micRmsLevel != null:
        return micRmsLevel(_that);
      case RustPlayerEvent_VoiceCompleted() when voiceCompleted != null:
        return voiceCompleted(_that);
      case RustPlayerEvent_LoadedEffects() when loadedEffects != null:
        return loadedEffects(_that);
      case RustPlayerEvent_ActiveVoices() when activeVoices != null:
        return activeVoices(_that);
      case RustPlayerEvent_AudioMetadata() when audioMetadata != null:
        return audioMetadata(_that);
      case RustPlayerEvent_MetadataEnabled() when metadataEnabled != null:
        return metadataEnabled(_that);
      case RustPlayerEvent_RecordingState() when recordingState != null:
        return recordingState(_that);
      case RustPlayerEvent_LoopMode() when loopMode != null:
        return loopMode(_that);
      case RustPlayerEvent_IsShuffled() when isShuffled != null:
        return isShuffled(_that);
      case RustPlayerEvent_InfiniteMix() when infiniteMix != null:
        return infiniteMix(_that);
      case RustPlayerEvent_PauseOnDeviceChange()
          when pauseOnDeviceChange != null:
        return pauseOnDeviceChange(_that);
      case RustPlayerEvent_Inputs() when inputs != null:
        return inputs(_that);
      case RustPlayerEvent_OutputDevices() when outputDevices != null:
        return outputDevices(_that);
      case RustPlayerEvent_InputDevices() when inputDevices != null:
        return inputDevices(_that);
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that);
      case RustPlayerEvent_DartResolveRequest() when dartResolveRequest != null:
        return dartResolveRequest(_that);
      case RustPlayerEvent_NeedMoreTracks() when needMoreTracks != null:
        return needMoreTracks(_that);
      case RustPlayerEvent_Outputs() when outputs != null:
        return outputs(_that);
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
    required TResult Function(RustPlayerEvent_AudioInfo value) audioInfo,
    required TResult Function(RustPlayerEvent_PlaybackState value)
        playbackState,
    required TResult Function(RustPlayerEvent_Position value) position,
    required TResult Function(RustPlayerEvent_IsPlaying value) isPlaying,
    required TResult Function(RustPlayerEvent_IsBuffering value) isBuffering,
    required TResult Function(RustPlayerEvent_Buffer value) buffer,
    required TResult Function(RustPlayerEvent_Queue value) queue,
    required TResult Function(RustPlayerEvent_CurrentIndex value) currentIndex,
    required TResult Function(RustPlayerEvent_IsCrossfading value)
        isCrossfading,
    required TResult Function(RustPlayerEvent_CrossfadeConfig value)
        crossfadeConfig,
    required TResult Function(RustPlayerEvent_Visualizer value) visualizer,
    required TResult Function(RustPlayerEvent_VisualizerEnabled value)
        visualizerEnabled,
    required TResult Function(RustPlayerEvent_VisualizerSource value)
        visualizerSource,
    required TResult Function(RustPlayerEvent_Volume value) volume,
    required TResult Function(RustPlayerEvent_Rate value) rate,
    required TResult Function(RustPlayerEvent_Pitch value) pitch,
    required TResult Function(RustPlayerEvent_Balance value) balance,
    required TResult Function(RustPlayerEvent_Mono value) mono,
    required TResult Function(RustPlayerEvent_BufferSize value) bufferSize,
    required TResult Function(RustPlayerEvent_SilenceConfig value)
        silenceConfig,
    required TResult Function(RustPlayerEvent_SilenceSaved value) silenceSaved,
    required TResult Function(RustPlayerEvent_Equalizer value) equalizer,
    required TResult Function(RustPlayerEvent_Preamp value) preamp,
    required TResult Function(RustPlayerEvent_ReplayGain value) replayGain,
    required TResult Function(RustPlayerEvent_ReplayGainMode value)
        replayGainMode,
    required TResult Function(RustPlayerEvent_DefaultReplayGain value)
        defaultReplayGain,
    required TResult Function(RustPlayerEvent_Crossfeed value) crossfeed,
    required TResult Function(RustPlayerEvent_Spatializer value) spatializer,
    required TResult Function(RustPlayerEvent_Reverb value) reverb,
    required TResult Function(RustPlayerEvent_Limiter value) limiter,
    required TResult Function(RustPlayerEvent_IsRecording value) isRecording,
    required TResult Function(RustPlayerEvent_RecordedDuration value)
        recordedDuration,
    required TResult Function(RustPlayerEvent_IsDuckingActive value)
        isDuckingActive,
    required TResult Function(RustPlayerEvent_MicRmsLevel value) micRmsLevel,
    required TResult Function(RustPlayerEvent_VoiceCompleted value)
        voiceCompleted,
    required TResult Function(RustPlayerEvent_LoadedEffects value)
        loadedEffects,
    required TResult Function(RustPlayerEvent_ActiveVoices value) activeVoices,
    required TResult Function(RustPlayerEvent_AudioMetadata value)
        audioMetadata,
    required TResult Function(RustPlayerEvent_MetadataEnabled value)
        metadataEnabled,
    required TResult Function(RustPlayerEvent_RecordingState value)
        recordingState,
    required TResult Function(RustPlayerEvent_LoopMode value) loopMode,
    required TResult Function(RustPlayerEvent_IsShuffled value) isShuffled,
    required TResult Function(RustPlayerEvent_InfiniteMix value) infiniteMix,
    required TResult Function(RustPlayerEvent_PauseOnDeviceChange value)
        pauseOnDeviceChange,
    required TResult Function(RustPlayerEvent_Inputs value) inputs,
    required TResult Function(RustPlayerEvent_OutputDevices value)
        outputDevices,
    required TResult Function(RustPlayerEvent_InputDevices value) inputDevices,
    required TResult Function(RustPlayerEvent_DartReadRequest value)
        dartReadRequest,
    required TResult Function(RustPlayerEvent_DartResolveRequest value)
        dartResolveRequest,
    required TResult Function(RustPlayerEvent_NeedMoreTracks value)
        needMoreTracks,
    required TResult Function(RustPlayerEvent_Outputs value) outputs,
    required TResult Function(RustPlayerEvent_Error value) error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_AudioInfo():
        return audioInfo(_that);
      case RustPlayerEvent_PlaybackState():
        return playbackState(_that);
      case RustPlayerEvent_Position():
        return position(_that);
      case RustPlayerEvent_IsPlaying():
        return isPlaying(_that);
      case RustPlayerEvent_IsBuffering():
        return isBuffering(_that);
      case RustPlayerEvent_Buffer():
        return buffer(_that);
      case RustPlayerEvent_Queue():
        return queue(_that);
      case RustPlayerEvent_CurrentIndex():
        return currentIndex(_that);
      case RustPlayerEvent_IsCrossfading():
        return isCrossfading(_that);
      case RustPlayerEvent_CrossfadeConfig():
        return crossfadeConfig(_that);
      case RustPlayerEvent_Visualizer():
        return visualizer(_that);
      case RustPlayerEvent_VisualizerEnabled():
        return visualizerEnabled(_that);
      case RustPlayerEvent_VisualizerSource():
        return visualizerSource(_that);
      case RustPlayerEvent_Volume():
        return volume(_that);
      case RustPlayerEvent_Rate():
        return rate(_that);
      case RustPlayerEvent_Pitch():
        return pitch(_that);
      case RustPlayerEvent_Balance():
        return balance(_that);
      case RustPlayerEvent_Mono():
        return mono(_that);
      case RustPlayerEvent_BufferSize():
        return bufferSize(_that);
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
      case RustPlayerEvent_ReplayGainMode():
        return replayGainMode(_that);
      case RustPlayerEvent_DefaultReplayGain():
        return defaultReplayGain(_that);
      case RustPlayerEvent_Crossfeed():
        return crossfeed(_that);
      case RustPlayerEvent_Spatializer():
        return spatializer(_that);
      case RustPlayerEvent_Reverb():
        return reverb(_that);
      case RustPlayerEvent_Limiter():
        return limiter(_that);
      case RustPlayerEvent_IsRecording():
        return isRecording(_that);
      case RustPlayerEvent_RecordedDuration():
        return recordedDuration(_that);
      case RustPlayerEvent_IsDuckingActive():
        return isDuckingActive(_that);
      case RustPlayerEvent_MicRmsLevel():
        return micRmsLevel(_that);
      case RustPlayerEvent_VoiceCompleted():
        return voiceCompleted(_that);
      case RustPlayerEvent_LoadedEffects():
        return loadedEffects(_that);
      case RustPlayerEvent_ActiveVoices():
        return activeVoices(_that);
      case RustPlayerEvent_AudioMetadata():
        return audioMetadata(_that);
      case RustPlayerEvent_MetadataEnabled():
        return metadataEnabled(_that);
      case RustPlayerEvent_RecordingState():
        return recordingState(_that);
      case RustPlayerEvent_LoopMode():
        return loopMode(_that);
      case RustPlayerEvent_IsShuffled():
        return isShuffled(_that);
      case RustPlayerEvent_InfiniteMix():
        return infiniteMix(_that);
      case RustPlayerEvent_PauseOnDeviceChange():
        return pauseOnDeviceChange(_that);
      case RustPlayerEvent_Inputs():
        return inputs(_that);
      case RustPlayerEvent_OutputDevices():
        return outputDevices(_that);
      case RustPlayerEvent_InputDevices():
        return inputDevices(_that);
      case RustPlayerEvent_DartReadRequest():
        return dartReadRequest(_that);
      case RustPlayerEvent_DartResolveRequest():
        return dartResolveRequest(_that);
      case RustPlayerEvent_NeedMoreTracks():
        return needMoreTracks(_that);
      case RustPlayerEvent_Outputs():
        return outputs(_that);
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
    TResult? Function(RustPlayerEvent_AudioInfo value)? audioInfo,
    TResult? Function(RustPlayerEvent_PlaybackState value)? playbackState,
    TResult? Function(RustPlayerEvent_Position value)? position,
    TResult? Function(RustPlayerEvent_IsPlaying value)? isPlaying,
    TResult? Function(RustPlayerEvent_IsBuffering value)? isBuffering,
    TResult? Function(RustPlayerEvent_Buffer value)? buffer,
    TResult? Function(RustPlayerEvent_Queue value)? queue,
    TResult? Function(RustPlayerEvent_CurrentIndex value)? currentIndex,
    TResult? Function(RustPlayerEvent_IsCrossfading value)? isCrossfading,
    TResult? Function(RustPlayerEvent_CrossfadeConfig value)? crossfadeConfig,
    TResult? Function(RustPlayerEvent_Visualizer value)? visualizer,
    TResult? Function(RustPlayerEvent_VisualizerEnabled value)?
        visualizerEnabled,
    TResult? Function(RustPlayerEvent_VisualizerSource value)? visualizerSource,
    TResult? Function(RustPlayerEvent_Volume value)? volume,
    TResult? Function(RustPlayerEvent_Rate value)? rate,
    TResult? Function(RustPlayerEvent_Pitch value)? pitch,
    TResult? Function(RustPlayerEvent_Balance value)? balance,
    TResult? Function(RustPlayerEvent_Mono value)? mono,
    TResult? Function(RustPlayerEvent_BufferSize value)? bufferSize,
    TResult? Function(RustPlayerEvent_SilenceConfig value)? silenceConfig,
    TResult? Function(RustPlayerEvent_SilenceSaved value)? silenceSaved,
    TResult? Function(RustPlayerEvent_Equalizer value)? equalizer,
    TResult? Function(RustPlayerEvent_Preamp value)? preamp,
    TResult? Function(RustPlayerEvent_ReplayGain value)? replayGain,
    TResult? Function(RustPlayerEvent_ReplayGainMode value)? replayGainMode,
    TResult? Function(RustPlayerEvent_DefaultReplayGain value)?
        defaultReplayGain,
    TResult? Function(RustPlayerEvent_Crossfeed value)? crossfeed,
    TResult? Function(RustPlayerEvent_Spatializer value)? spatializer,
    TResult? Function(RustPlayerEvent_Reverb value)? reverb,
    TResult? Function(RustPlayerEvent_Limiter value)? limiter,
    TResult? Function(RustPlayerEvent_IsRecording value)? isRecording,
    TResult? Function(RustPlayerEvent_RecordedDuration value)? recordedDuration,
    TResult? Function(RustPlayerEvent_IsDuckingActive value)? isDuckingActive,
    TResult? Function(RustPlayerEvent_MicRmsLevel value)? micRmsLevel,
    TResult? Function(RustPlayerEvent_VoiceCompleted value)? voiceCompleted,
    TResult? Function(RustPlayerEvent_LoadedEffects value)? loadedEffects,
    TResult? Function(RustPlayerEvent_ActiveVoices value)? activeVoices,
    TResult? Function(RustPlayerEvent_AudioMetadata value)? audioMetadata,
    TResult? Function(RustPlayerEvent_MetadataEnabled value)? metadataEnabled,
    TResult? Function(RustPlayerEvent_RecordingState value)? recordingState,
    TResult? Function(RustPlayerEvent_LoopMode value)? loopMode,
    TResult? Function(RustPlayerEvent_IsShuffled value)? isShuffled,
    TResult? Function(RustPlayerEvent_InfiniteMix value)? infiniteMix,
    TResult? Function(RustPlayerEvent_PauseOnDeviceChange value)?
        pauseOnDeviceChange,
    TResult? Function(RustPlayerEvent_Inputs value)? inputs,
    TResult? Function(RustPlayerEvent_OutputDevices value)? outputDevices,
    TResult? Function(RustPlayerEvent_InputDevices value)? inputDevices,
    TResult? Function(RustPlayerEvent_DartReadRequest value)? dartReadRequest,
    TResult? Function(RustPlayerEvent_DartResolveRequest value)?
        dartResolveRequest,
    TResult? Function(RustPlayerEvent_NeedMoreTracks value)? needMoreTracks,
    TResult? Function(RustPlayerEvent_Outputs value)? outputs,
    TResult? Function(RustPlayerEvent_Error value)? error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_AudioInfo() when audioInfo != null:
        return audioInfo(_that);
      case RustPlayerEvent_PlaybackState() when playbackState != null:
        return playbackState(_that);
      case RustPlayerEvent_Position() when position != null:
        return position(_that);
      case RustPlayerEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that);
      case RustPlayerEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that);
      case RustPlayerEvent_Buffer() when buffer != null:
        return buffer(_that);
      case RustPlayerEvent_Queue() when queue != null:
        return queue(_that);
      case RustPlayerEvent_CurrentIndex() when currentIndex != null:
        return currentIndex(_that);
      case RustPlayerEvent_IsCrossfading() when isCrossfading != null:
        return isCrossfading(_that);
      case RustPlayerEvent_CrossfadeConfig() when crossfadeConfig != null:
        return crossfadeConfig(_that);
      case RustPlayerEvent_Visualizer() when visualizer != null:
        return visualizer(_that);
      case RustPlayerEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that);
      case RustPlayerEvent_VisualizerSource() when visualizerSource != null:
        return visualizerSource(_that);
      case RustPlayerEvent_Volume() when volume != null:
        return volume(_that);
      case RustPlayerEvent_Rate() when rate != null:
        return rate(_that);
      case RustPlayerEvent_Pitch() when pitch != null:
        return pitch(_that);
      case RustPlayerEvent_Balance() when balance != null:
        return balance(_that);
      case RustPlayerEvent_Mono() when mono != null:
        return mono(_that);
      case RustPlayerEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that);
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
      case RustPlayerEvent_ReplayGainMode() when replayGainMode != null:
        return replayGainMode(_that);
      case RustPlayerEvent_DefaultReplayGain() when defaultReplayGain != null:
        return defaultReplayGain(_that);
      case RustPlayerEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that);
      case RustPlayerEvent_Spatializer() when spatializer != null:
        return spatializer(_that);
      case RustPlayerEvent_Reverb() when reverb != null:
        return reverb(_that);
      case RustPlayerEvent_Limiter() when limiter != null:
        return limiter(_that);
      case RustPlayerEvent_IsRecording() when isRecording != null:
        return isRecording(_that);
      case RustPlayerEvent_RecordedDuration() when recordedDuration != null:
        return recordedDuration(_that);
      case RustPlayerEvent_IsDuckingActive() when isDuckingActive != null:
        return isDuckingActive(_that);
      case RustPlayerEvent_MicRmsLevel() when micRmsLevel != null:
        return micRmsLevel(_that);
      case RustPlayerEvent_VoiceCompleted() when voiceCompleted != null:
        return voiceCompleted(_that);
      case RustPlayerEvent_LoadedEffects() when loadedEffects != null:
        return loadedEffects(_that);
      case RustPlayerEvent_ActiveVoices() when activeVoices != null:
        return activeVoices(_that);
      case RustPlayerEvent_AudioMetadata() when audioMetadata != null:
        return audioMetadata(_that);
      case RustPlayerEvent_MetadataEnabled() when metadataEnabled != null:
        return metadataEnabled(_that);
      case RustPlayerEvent_RecordingState() when recordingState != null:
        return recordingState(_that);
      case RustPlayerEvent_LoopMode() when loopMode != null:
        return loopMode(_that);
      case RustPlayerEvent_IsShuffled() when isShuffled != null:
        return isShuffled(_that);
      case RustPlayerEvent_InfiniteMix() when infiniteMix != null:
        return infiniteMix(_that);
      case RustPlayerEvent_PauseOnDeviceChange()
          when pauseOnDeviceChange != null:
        return pauseOnDeviceChange(_that);
      case RustPlayerEvent_Inputs() when inputs != null:
        return inputs(_that);
      case RustPlayerEvent_OutputDevices() when outputDevices != null:
        return outputDevices(_that);
      case RustPlayerEvent_InputDevices() when inputDevices != null:
        return inputDevices(_that);
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that);
      case RustPlayerEvent_DartResolveRequest() when dartResolveRequest != null:
        return dartResolveRequest(_that);
      case RustPlayerEvent_NeedMoreTracks() when needMoreTracks != null:
        return needMoreTracks(_that);
      case RustPlayerEvent_Outputs() when outputs != null:
        return outputs(_that);
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
    TResult Function(RustAudioInfo field0)? audioInfo,
    TResult Function(int field0)? playbackState,
    TResult Function(PlatformInt64 field0)? position,
    TResult Function(bool field0)? isPlaying,
    TResult Function(bool field0)? isBuffering,
    TResult Function(RustBuffer field0)? buffer,
    TResult Function(Int64List queue, int currentIndex)? queue,
    TResult Function(int field0)? currentIndex,
    TResult Function(bool field0)? isCrossfading,
    TResult Function(RustCrossfadeConfig field0)? crossfadeConfig,
    TResult Function(RustVisualizerData field0)? visualizer,
    TResult Function(bool field0)? visualizerEnabled,
    TResult Function(int field0)? visualizerSource,
    TResult Function(double field0)? volume,
    TResult Function(double field0)? rate,
    TResult Function(double field0)? pitch,
    TResult Function(double field0)? balance,
    TResult Function(bool field0)? mono,
    TResult Function(int field0)? bufferSize,
    TResult Function(RustSilenceConfig field0)? silenceConfig,
    TResult Function(PlatformInt64 field0)? silenceSaved,
    TResult Function(RustEqualizerParams field0)? equalizer,
    TResult Function(double field0)? preamp,
    TResult Function(RustReplayGainConfig field0)? replayGain,
    TResult Function(int field0)? replayGainMode,
    TResult Function(double field0)? defaultReplayGain,
    TResult Function(RustCrossfeedConfig field0)? crossfeed,
    TResult Function(bool enabled, double width)? spatializer,
    TResult Function(RustReverbParams field0)? reverb,
    TResult Function(bool field0)? limiter,
    TResult Function(bool field0)? isRecording,
    TResult Function(BigInt field0)? recordedDuration,
    TResult Function(bool field0)? isDuckingActive,
    TResult Function(double field0)? micRmsLevel,
    TResult Function(int field0)? voiceCompleted,
    TResult Function(List<String> ids, BigInt allocatedBytes)? loadedEffects,
    TResult Function(int field0)? activeVoices,
    TResult Function(RustAudioMetadata field0)? audioMetadata,
    TResult Function(bool field0)? metadataEnabled,
    TResult Function(bool isRecording, int source)? recordingState,
    TResult Function(int field0)? loopMode,
    TResult Function(bool field0)? isShuffled,
    TResult Function(RustInfiniteMixConfig field0)? infiniteMix,
    TResult Function(bool field0)? pauseOnDeviceChange,
    TResult Function(List<RustAudioInput> field0)? inputs,
    TResult Function(List<RustAudioDevice> field0)? outputDevices,
    TResult Function(List<RustAudioDevice> field0)? inputDevices,
    TResult Function(RustDartReadRequest field0)? dartReadRequest,
    TResult Function(RustDartResolveRequest field0)? dartResolveRequest,
    TResult Function(PlatformInt64 currentTrackId, int remainingTracks)?
        needMoreTracks,
    TResult Function(List<RustAudioOutput> field0)? outputs,
    TResult Function(String message, int code)? error,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_AudioInfo() when audioInfo != null:
        return audioInfo(_that.field0);
      case RustPlayerEvent_PlaybackState() when playbackState != null:
        return playbackState(_that.field0);
      case RustPlayerEvent_Position() when position != null:
        return position(_that.field0);
      case RustPlayerEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that.field0);
      case RustPlayerEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that.field0);
      case RustPlayerEvent_Buffer() when buffer != null:
        return buffer(_that.field0);
      case RustPlayerEvent_Queue() when queue != null:
        return queue(_that.queue, _that.currentIndex);
      case RustPlayerEvent_CurrentIndex() when currentIndex != null:
        return currentIndex(_that.field0);
      case RustPlayerEvent_IsCrossfading() when isCrossfading != null:
        return isCrossfading(_that.field0);
      case RustPlayerEvent_CrossfadeConfig() when crossfadeConfig != null:
        return crossfadeConfig(_that.field0);
      case RustPlayerEvent_Visualizer() when visualizer != null:
        return visualizer(_that.field0);
      case RustPlayerEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that.field0);
      case RustPlayerEvent_VisualizerSource() when visualizerSource != null:
        return visualizerSource(_that.field0);
      case RustPlayerEvent_Volume() when volume != null:
        return volume(_that.field0);
      case RustPlayerEvent_Rate() when rate != null:
        return rate(_that.field0);
      case RustPlayerEvent_Pitch() when pitch != null:
        return pitch(_that.field0);
      case RustPlayerEvent_Balance() when balance != null:
        return balance(_that.field0);
      case RustPlayerEvent_Mono() when mono != null:
        return mono(_that.field0);
      case RustPlayerEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that.field0);
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
      case RustPlayerEvent_ReplayGainMode() when replayGainMode != null:
        return replayGainMode(_that.field0);
      case RustPlayerEvent_DefaultReplayGain() when defaultReplayGain != null:
        return defaultReplayGain(_that.field0);
      case RustPlayerEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that.field0);
      case RustPlayerEvent_Spatializer() when spatializer != null:
        return spatializer(_that.enabled, _that.width);
      case RustPlayerEvent_Reverb() when reverb != null:
        return reverb(_that.field0);
      case RustPlayerEvent_Limiter() when limiter != null:
        return limiter(_that.field0);
      case RustPlayerEvent_IsRecording() when isRecording != null:
        return isRecording(_that.field0);
      case RustPlayerEvent_RecordedDuration() when recordedDuration != null:
        return recordedDuration(_that.field0);
      case RustPlayerEvent_IsDuckingActive() when isDuckingActive != null:
        return isDuckingActive(_that.field0);
      case RustPlayerEvent_MicRmsLevel() when micRmsLevel != null:
        return micRmsLevel(_that.field0);
      case RustPlayerEvent_VoiceCompleted() when voiceCompleted != null:
        return voiceCompleted(_that.field0);
      case RustPlayerEvent_LoadedEffects() when loadedEffects != null:
        return loadedEffects(_that.ids, _that.allocatedBytes);
      case RustPlayerEvent_ActiveVoices() when activeVoices != null:
        return activeVoices(_that.field0);
      case RustPlayerEvent_AudioMetadata() when audioMetadata != null:
        return audioMetadata(_that.field0);
      case RustPlayerEvent_MetadataEnabled() when metadataEnabled != null:
        return metadataEnabled(_that.field0);
      case RustPlayerEvent_RecordingState() when recordingState != null:
        return recordingState(_that.isRecording, _that.source);
      case RustPlayerEvent_LoopMode() when loopMode != null:
        return loopMode(_that.field0);
      case RustPlayerEvent_IsShuffled() when isShuffled != null:
        return isShuffled(_that.field0);
      case RustPlayerEvent_InfiniteMix() when infiniteMix != null:
        return infiniteMix(_that.field0);
      case RustPlayerEvent_PauseOnDeviceChange()
          when pauseOnDeviceChange != null:
        return pauseOnDeviceChange(_that.field0);
      case RustPlayerEvent_Inputs() when inputs != null:
        return inputs(_that.field0);
      case RustPlayerEvent_OutputDevices() when outputDevices != null:
        return outputDevices(_that.field0);
      case RustPlayerEvent_InputDevices() when inputDevices != null:
        return inputDevices(_that.field0);
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that.field0);
      case RustPlayerEvent_DartResolveRequest() when dartResolveRequest != null:
        return dartResolveRequest(_that.field0);
      case RustPlayerEvent_NeedMoreTracks() when needMoreTracks != null:
        return needMoreTracks(_that.currentTrackId, _that.remainingTracks);
      case RustPlayerEvent_Outputs() when outputs != null:
        return outputs(_that.field0);
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
    required TResult Function(RustAudioInfo field0) audioInfo,
    required TResult Function(int field0) playbackState,
    required TResult Function(PlatformInt64 field0) position,
    required TResult Function(bool field0) isPlaying,
    required TResult Function(bool field0) isBuffering,
    required TResult Function(RustBuffer field0) buffer,
    required TResult Function(Int64List queue, int currentIndex) queue,
    required TResult Function(int field0) currentIndex,
    required TResult Function(bool field0) isCrossfading,
    required TResult Function(RustCrossfadeConfig field0) crossfadeConfig,
    required TResult Function(RustVisualizerData field0) visualizer,
    required TResult Function(bool field0) visualizerEnabled,
    required TResult Function(int field0) visualizerSource,
    required TResult Function(double field0) volume,
    required TResult Function(double field0) rate,
    required TResult Function(double field0) pitch,
    required TResult Function(double field0) balance,
    required TResult Function(bool field0) mono,
    required TResult Function(int field0) bufferSize,
    required TResult Function(RustSilenceConfig field0) silenceConfig,
    required TResult Function(PlatformInt64 field0) silenceSaved,
    required TResult Function(RustEqualizerParams field0) equalizer,
    required TResult Function(double field0) preamp,
    required TResult Function(RustReplayGainConfig field0) replayGain,
    required TResult Function(int field0) replayGainMode,
    required TResult Function(double field0) defaultReplayGain,
    required TResult Function(RustCrossfeedConfig field0) crossfeed,
    required TResult Function(bool enabled, double width) spatializer,
    required TResult Function(RustReverbParams field0) reverb,
    required TResult Function(bool field0) limiter,
    required TResult Function(bool field0) isRecording,
    required TResult Function(BigInt field0) recordedDuration,
    required TResult Function(bool field0) isDuckingActive,
    required TResult Function(double field0) micRmsLevel,
    required TResult Function(int field0) voiceCompleted,
    required TResult Function(List<String> ids, BigInt allocatedBytes)
        loadedEffects,
    required TResult Function(int field0) activeVoices,
    required TResult Function(RustAudioMetadata field0) audioMetadata,
    required TResult Function(bool field0) metadataEnabled,
    required TResult Function(bool isRecording, int source) recordingState,
    required TResult Function(int field0) loopMode,
    required TResult Function(bool field0) isShuffled,
    required TResult Function(RustInfiniteMixConfig field0) infiniteMix,
    required TResult Function(bool field0) pauseOnDeviceChange,
    required TResult Function(List<RustAudioInput> field0) inputs,
    required TResult Function(List<RustAudioDevice> field0) outputDevices,
    required TResult Function(List<RustAudioDevice> field0) inputDevices,
    required TResult Function(RustDartReadRequest field0) dartReadRequest,
    required TResult Function(RustDartResolveRequest field0) dartResolveRequest,
    required TResult Function(PlatformInt64 currentTrackId, int remainingTracks)
        needMoreTracks,
    required TResult Function(List<RustAudioOutput> field0) outputs,
    required TResult Function(String message, int code) error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_AudioInfo():
        return audioInfo(_that.field0);
      case RustPlayerEvent_PlaybackState():
        return playbackState(_that.field0);
      case RustPlayerEvent_Position():
        return position(_that.field0);
      case RustPlayerEvent_IsPlaying():
        return isPlaying(_that.field0);
      case RustPlayerEvent_IsBuffering():
        return isBuffering(_that.field0);
      case RustPlayerEvent_Buffer():
        return buffer(_that.field0);
      case RustPlayerEvent_Queue():
        return queue(_that.queue, _that.currentIndex);
      case RustPlayerEvent_CurrentIndex():
        return currentIndex(_that.field0);
      case RustPlayerEvent_IsCrossfading():
        return isCrossfading(_that.field0);
      case RustPlayerEvent_CrossfadeConfig():
        return crossfadeConfig(_that.field0);
      case RustPlayerEvent_Visualizer():
        return visualizer(_that.field0);
      case RustPlayerEvent_VisualizerEnabled():
        return visualizerEnabled(_that.field0);
      case RustPlayerEvent_VisualizerSource():
        return visualizerSource(_that.field0);
      case RustPlayerEvent_Volume():
        return volume(_that.field0);
      case RustPlayerEvent_Rate():
        return rate(_that.field0);
      case RustPlayerEvent_Pitch():
        return pitch(_that.field0);
      case RustPlayerEvent_Balance():
        return balance(_that.field0);
      case RustPlayerEvent_Mono():
        return mono(_that.field0);
      case RustPlayerEvent_BufferSize():
        return bufferSize(_that.field0);
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
      case RustPlayerEvent_ReplayGainMode():
        return replayGainMode(_that.field0);
      case RustPlayerEvent_DefaultReplayGain():
        return defaultReplayGain(_that.field0);
      case RustPlayerEvent_Crossfeed():
        return crossfeed(_that.field0);
      case RustPlayerEvent_Spatializer():
        return spatializer(_that.enabled, _that.width);
      case RustPlayerEvent_Reverb():
        return reverb(_that.field0);
      case RustPlayerEvent_Limiter():
        return limiter(_that.field0);
      case RustPlayerEvent_IsRecording():
        return isRecording(_that.field0);
      case RustPlayerEvent_RecordedDuration():
        return recordedDuration(_that.field0);
      case RustPlayerEvent_IsDuckingActive():
        return isDuckingActive(_that.field0);
      case RustPlayerEvent_MicRmsLevel():
        return micRmsLevel(_that.field0);
      case RustPlayerEvent_VoiceCompleted():
        return voiceCompleted(_that.field0);
      case RustPlayerEvent_LoadedEffects():
        return loadedEffects(_that.ids, _that.allocatedBytes);
      case RustPlayerEvent_ActiveVoices():
        return activeVoices(_that.field0);
      case RustPlayerEvent_AudioMetadata():
        return audioMetadata(_that.field0);
      case RustPlayerEvent_MetadataEnabled():
        return metadataEnabled(_that.field0);
      case RustPlayerEvent_RecordingState():
        return recordingState(_that.isRecording, _that.source);
      case RustPlayerEvent_LoopMode():
        return loopMode(_that.field0);
      case RustPlayerEvent_IsShuffled():
        return isShuffled(_that.field0);
      case RustPlayerEvent_InfiniteMix():
        return infiniteMix(_that.field0);
      case RustPlayerEvent_PauseOnDeviceChange():
        return pauseOnDeviceChange(_that.field0);
      case RustPlayerEvent_Inputs():
        return inputs(_that.field0);
      case RustPlayerEvent_OutputDevices():
        return outputDevices(_that.field0);
      case RustPlayerEvent_InputDevices():
        return inputDevices(_that.field0);
      case RustPlayerEvent_DartReadRequest():
        return dartReadRequest(_that.field0);
      case RustPlayerEvent_DartResolveRequest():
        return dartResolveRequest(_that.field0);
      case RustPlayerEvent_NeedMoreTracks():
        return needMoreTracks(_that.currentTrackId, _that.remainingTracks);
      case RustPlayerEvent_Outputs():
        return outputs(_that.field0);
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
    TResult? Function(RustAudioInfo field0)? audioInfo,
    TResult? Function(int field0)? playbackState,
    TResult? Function(PlatformInt64 field0)? position,
    TResult? Function(bool field0)? isPlaying,
    TResult? Function(bool field0)? isBuffering,
    TResult? Function(RustBuffer field0)? buffer,
    TResult? Function(Int64List queue, int currentIndex)? queue,
    TResult? Function(int field0)? currentIndex,
    TResult? Function(bool field0)? isCrossfading,
    TResult? Function(RustCrossfadeConfig field0)? crossfadeConfig,
    TResult? Function(RustVisualizerData field0)? visualizer,
    TResult? Function(bool field0)? visualizerEnabled,
    TResult? Function(int field0)? visualizerSource,
    TResult? Function(double field0)? volume,
    TResult? Function(double field0)? rate,
    TResult? Function(double field0)? pitch,
    TResult? Function(double field0)? balance,
    TResult? Function(bool field0)? mono,
    TResult? Function(int field0)? bufferSize,
    TResult? Function(RustSilenceConfig field0)? silenceConfig,
    TResult? Function(PlatformInt64 field0)? silenceSaved,
    TResult? Function(RustEqualizerParams field0)? equalizer,
    TResult? Function(double field0)? preamp,
    TResult? Function(RustReplayGainConfig field0)? replayGain,
    TResult? Function(int field0)? replayGainMode,
    TResult? Function(double field0)? defaultReplayGain,
    TResult? Function(RustCrossfeedConfig field0)? crossfeed,
    TResult? Function(bool enabled, double width)? spatializer,
    TResult? Function(RustReverbParams field0)? reverb,
    TResult? Function(bool field0)? limiter,
    TResult? Function(bool field0)? isRecording,
    TResult? Function(BigInt field0)? recordedDuration,
    TResult? Function(bool field0)? isDuckingActive,
    TResult? Function(double field0)? micRmsLevel,
    TResult? Function(int field0)? voiceCompleted,
    TResult? Function(List<String> ids, BigInt allocatedBytes)? loadedEffects,
    TResult? Function(int field0)? activeVoices,
    TResult? Function(RustAudioMetadata field0)? audioMetadata,
    TResult? Function(bool field0)? metadataEnabled,
    TResult? Function(bool isRecording, int source)? recordingState,
    TResult? Function(int field0)? loopMode,
    TResult? Function(bool field0)? isShuffled,
    TResult? Function(RustInfiniteMixConfig field0)? infiniteMix,
    TResult? Function(bool field0)? pauseOnDeviceChange,
    TResult? Function(List<RustAudioInput> field0)? inputs,
    TResult? Function(List<RustAudioDevice> field0)? outputDevices,
    TResult? Function(List<RustAudioDevice> field0)? inputDevices,
    TResult? Function(RustDartReadRequest field0)? dartReadRequest,
    TResult? Function(RustDartResolveRequest field0)? dartResolveRequest,
    TResult? Function(PlatformInt64 currentTrackId, int remainingTracks)?
        needMoreTracks,
    TResult? Function(List<RustAudioOutput> field0)? outputs,
    TResult? Function(String message, int code)? error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_AudioInfo() when audioInfo != null:
        return audioInfo(_that.field0);
      case RustPlayerEvent_PlaybackState() when playbackState != null:
        return playbackState(_that.field0);
      case RustPlayerEvent_Position() when position != null:
        return position(_that.field0);
      case RustPlayerEvent_IsPlaying() when isPlaying != null:
        return isPlaying(_that.field0);
      case RustPlayerEvent_IsBuffering() when isBuffering != null:
        return isBuffering(_that.field0);
      case RustPlayerEvent_Buffer() when buffer != null:
        return buffer(_that.field0);
      case RustPlayerEvent_Queue() when queue != null:
        return queue(_that.queue, _that.currentIndex);
      case RustPlayerEvent_CurrentIndex() when currentIndex != null:
        return currentIndex(_that.field0);
      case RustPlayerEvent_IsCrossfading() when isCrossfading != null:
        return isCrossfading(_that.field0);
      case RustPlayerEvent_CrossfadeConfig() when crossfadeConfig != null:
        return crossfadeConfig(_that.field0);
      case RustPlayerEvent_Visualizer() when visualizer != null:
        return visualizer(_that.field0);
      case RustPlayerEvent_VisualizerEnabled() when visualizerEnabled != null:
        return visualizerEnabled(_that.field0);
      case RustPlayerEvent_VisualizerSource() when visualizerSource != null:
        return visualizerSource(_that.field0);
      case RustPlayerEvent_Volume() when volume != null:
        return volume(_that.field0);
      case RustPlayerEvent_Rate() when rate != null:
        return rate(_that.field0);
      case RustPlayerEvent_Pitch() when pitch != null:
        return pitch(_that.field0);
      case RustPlayerEvent_Balance() when balance != null:
        return balance(_that.field0);
      case RustPlayerEvent_Mono() when mono != null:
        return mono(_that.field0);
      case RustPlayerEvent_BufferSize() when bufferSize != null:
        return bufferSize(_that.field0);
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
      case RustPlayerEvent_ReplayGainMode() when replayGainMode != null:
        return replayGainMode(_that.field0);
      case RustPlayerEvent_DefaultReplayGain() when defaultReplayGain != null:
        return defaultReplayGain(_that.field0);
      case RustPlayerEvent_Crossfeed() when crossfeed != null:
        return crossfeed(_that.field0);
      case RustPlayerEvent_Spatializer() when spatializer != null:
        return spatializer(_that.enabled, _that.width);
      case RustPlayerEvent_Reverb() when reverb != null:
        return reverb(_that.field0);
      case RustPlayerEvent_Limiter() when limiter != null:
        return limiter(_that.field0);
      case RustPlayerEvent_IsRecording() when isRecording != null:
        return isRecording(_that.field0);
      case RustPlayerEvent_RecordedDuration() when recordedDuration != null:
        return recordedDuration(_that.field0);
      case RustPlayerEvent_IsDuckingActive() when isDuckingActive != null:
        return isDuckingActive(_that.field0);
      case RustPlayerEvent_MicRmsLevel() when micRmsLevel != null:
        return micRmsLevel(_that.field0);
      case RustPlayerEvent_VoiceCompleted() when voiceCompleted != null:
        return voiceCompleted(_that.field0);
      case RustPlayerEvent_LoadedEffects() when loadedEffects != null:
        return loadedEffects(_that.ids, _that.allocatedBytes);
      case RustPlayerEvent_ActiveVoices() when activeVoices != null:
        return activeVoices(_that.field0);
      case RustPlayerEvent_AudioMetadata() when audioMetadata != null:
        return audioMetadata(_that.field0);
      case RustPlayerEvent_MetadataEnabled() when metadataEnabled != null:
        return metadataEnabled(_that.field0);
      case RustPlayerEvent_RecordingState() when recordingState != null:
        return recordingState(_that.isRecording, _that.source);
      case RustPlayerEvent_LoopMode() when loopMode != null:
        return loopMode(_that.field0);
      case RustPlayerEvent_IsShuffled() when isShuffled != null:
        return isShuffled(_that.field0);
      case RustPlayerEvent_InfiniteMix() when infiniteMix != null:
        return infiniteMix(_that.field0);
      case RustPlayerEvent_PauseOnDeviceChange()
          when pauseOnDeviceChange != null:
        return pauseOnDeviceChange(_that.field0);
      case RustPlayerEvent_Inputs() when inputs != null:
        return inputs(_that.field0);
      case RustPlayerEvent_OutputDevices() when outputDevices != null:
        return outputDevices(_that.field0);
      case RustPlayerEvent_InputDevices() when inputDevices != null:
        return inputDevices(_that.field0);
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that.field0);
      case RustPlayerEvent_DartResolveRequest() when dartResolveRequest != null:
        return dartResolveRequest(_that.field0);
      case RustPlayerEvent_NeedMoreTracks() when needMoreTracks != null:
        return needMoreTracks(_that.currentTrackId, _that.remainingTracks);
      case RustPlayerEvent_Outputs() when outputs != null:
        return outputs(_that.field0);
      case RustPlayerEvent_Error() when error != null:
        return error(_that.message, _that.code);
      case _:
        return null;
    }
  }
}

/// @nodoc

class RustPlayerEvent_AudioInfo extends RustPlayerEvent {
  const RustPlayerEvent_AudioInfo(this.field0) : super._();

  final RustAudioInfo field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_AudioInfoCopyWith<RustPlayerEvent_AudioInfo> get copyWith =>
      _$RustPlayerEvent_AudioInfoCopyWithImpl<RustPlayerEvent_AudioInfo>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_AudioInfo &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.audioInfo(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_AudioInfoCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_AudioInfoCopyWith(RustPlayerEvent_AudioInfo value,
          $Res Function(RustPlayerEvent_AudioInfo) _then) =
      _$RustPlayerEvent_AudioInfoCopyWithImpl;
  @useResult
  $Res call({RustAudioInfo field0});
}

/// @nodoc
class _$RustPlayerEvent_AudioInfoCopyWithImpl<$Res>
    implements $RustPlayerEvent_AudioInfoCopyWith<$Res> {
  _$RustPlayerEvent_AudioInfoCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_AudioInfo _self;
  final $Res Function(RustPlayerEvent_AudioInfo) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_AudioInfo(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustAudioInfo,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_PlaybackState extends RustPlayerEvent {
  const RustPlayerEvent_PlaybackState(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_PlaybackStateCopyWith<RustPlayerEvent_PlaybackState>
      get copyWith => _$RustPlayerEvent_PlaybackStateCopyWithImpl<
          RustPlayerEvent_PlaybackState>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_PlaybackState &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.playbackState(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_PlaybackStateCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_PlaybackStateCopyWith(
          RustPlayerEvent_PlaybackState value,
          $Res Function(RustPlayerEvent_PlaybackState) _then) =
      _$RustPlayerEvent_PlaybackStateCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_PlaybackStateCopyWithImpl<$Res>
    implements $RustPlayerEvent_PlaybackStateCopyWith<$Res> {
  _$RustPlayerEvent_PlaybackStateCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_PlaybackState _self;
  final $Res Function(RustPlayerEvent_PlaybackState) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_PlaybackState(
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

class RustPlayerEvent_Buffer extends RustPlayerEvent {
  const RustPlayerEvent_Buffer(this.field0) : super._();

  final RustBuffer field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_BufferCopyWith<RustPlayerEvent_Buffer> get copyWith =>
      _$RustPlayerEvent_BufferCopyWithImpl<RustPlayerEvent_Buffer>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Buffer &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.buffer(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_BufferCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_BufferCopyWith(RustPlayerEvent_Buffer value,
          $Res Function(RustPlayerEvent_Buffer) _then) =
      _$RustPlayerEvent_BufferCopyWithImpl;
  @useResult
  $Res call({RustBuffer field0});
}

/// @nodoc
class _$RustPlayerEvent_BufferCopyWithImpl<$Res>
    implements $RustPlayerEvent_BufferCopyWith<$Res> {
  _$RustPlayerEvent_BufferCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Buffer _self;
  final $Res Function(RustPlayerEvent_Buffer) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Buffer(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustBuffer,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Queue extends RustPlayerEvent {
  const RustPlayerEvent_Queue({required this.queue, required this.currentIndex})
      : super._();

  /// Active queue track IDs.
  final Int64List queue;

  /// Active queue index (-1 if none or uninitialized).
  final int currentIndex;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_QueueCopyWith<RustPlayerEvent_Queue> get copyWith =>
      _$RustPlayerEvent_QueueCopyWithImpl<RustPlayerEvent_Queue>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Queue &&
            const DeepCollectionEquality().equals(other.queue, queue) &&
            (identical(other.currentIndex, currentIndex) ||
                other.currentIndex == currentIndex));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(queue), currentIndex);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.queue(queue: $queue, currentIndex: $currentIndex)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_QueueCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_QueueCopyWith(RustPlayerEvent_Queue value,
          $Res Function(RustPlayerEvent_Queue) _then) =
      _$RustPlayerEvent_QueueCopyWithImpl;
  @useResult
  $Res call({Int64List queue, int currentIndex});
}

/// @nodoc
class _$RustPlayerEvent_QueueCopyWithImpl<$Res>
    implements $RustPlayerEvent_QueueCopyWith<$Res> {
  _$RustPlayerEvent_QueueCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Queue _self;
  final $Res Function(RustPlayerEvent_Queue) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? queue = null,
    Object? currentIndex = null,
  }) {
    return _then(RustPlayerEvent_Queue(
      queue: null == queue
          ? _self.queue
          : queue // ignore: cast_nullable_to_non_nullable
              as Int64List,
      currentIndex: null == currentIndex
          ? _self.currentIndex
          : currentIndex // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_CurrentIndex extends RustPlayerEvent {
  const RustPlayerEvent_CurrentIndex(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_CurrentIndexCopyWith<RustPlayerEvent_CurrentIndex>
      get copyWith => _$RustPlayerEvent_CurrentIndexCopyWithImpl<
          RustPlayerEvent_CurrentIndex>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_CurrentIndex &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.currentIndex(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_CurrentIndexCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_CurrentIndexCopyWith(
          RustPlayerEvent_CurrentIndex value,
          $Res Function(RustPlayerEvent_CurrentIndex) _then) =
      _$RustPlayerEvent_CurrentIndexCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_CurrentIndexCopyWithImpl<$Res>
    implements $RustPlayerEvent_CurrentIndexCopyWith<$Res> {
  _$RustPlayerEvent_CurrentIndexCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_CurrentIndex _self;
  final $Res Function(RustPlayerEvent_CurrentIndex) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_CurrentIndex(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_IsCrossfading extends RustPlayerEvent {
  const RustPlayerEvent_IsCrossfading(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_IsCrossfadingCopyWith<RustPlayerEvent_IsCrossfading>
      get copyWith => _$RustPlayerEvent_IsCrossfadingCopyWithImpl<
          RustPlayerEvent_IsCrossfading>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_IsCrossfading &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.isCrossfading(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_IsCrossfadingCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_IsCrossfadingCopyWith(
          RustPlayerEvent_IsCrossfading value,
          $Res Function(RustPlayerEvent_IsCrossfading) _then) =
      _$RustPlayerEvent_IsCrossfadingCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_IsCrossfadingCopyWithImpl<$Res>
    implements $RustPlayerEvent_IsCrossfadingCopyWith<$Res> {
  _$RustPlayerEvent_IsCrossfadingCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_IsCrossfading _self;
  final $Res Function(RustPlayerEvent_IsCrossfading) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_IsCrossfading(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_CrossfadeConfig extends RustPlayerEvent {
  const RustPlayerEvent_CrossfadeConfig(this.field0) : super._();

  final RustCrossfadeConfig field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_CrossfadeConfigCopyWith<RustPlayerEvent_CrossfadeConfig>
      get copyWith => _$RustPlayerEvent_CrossfadeConfigCopyWithImpl<
          RustPlayerEvent_CrossfadeConfig>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_CrossfadeConfig &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.crossfadeConfig(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_CrossfadeConfigCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_CrossfadeConfigCopyWith(
          RustPlayerEvent_CrossfadeConfig value,
          $Res Function(RustPlayerEvent_CrossfadeConfig) _then) =
      _$RustPlayerEvent_CrossfadeConfigCopyWithImpl;
  @useResult
  $Res call({RustCrossfadeConfig field0});
}

/// @nodoc
class _$RustPlayerEvent_CrossfadeConfigCopyWithImpl<$Res>
    implements $RustPlayerEvent_CrossfadeConfigCopyWith<$Res> {
  _$RustPlayerEvent_CrossfadeConfigCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_CrossfadeConfig _self;
  final $Res Function(RustPlayerEvent_CrossfadeConfig) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_CrossfadeConfig(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustCrossfadeConfig,
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

class RustPlayerEvent_VisualizerSource extends RustPlayerEvent {
  const RustPlayerEvent_VisualizerSource(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_VisualizerSourceCopyWith<RustPlayerEvent_VisualizerSource>
      get copyWith => _$RustPlayerEvent_VisualizerSourceCopyWithImpl<
          RustPlayerEvent_VisualizerSource>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_VisualizerSource &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.visualizerSource(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_VisualizerSourceCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_VisualizerSourceCopyWith(
          RustPlayerEvent_VisualizerSource value,
          $Res Function(RustPlayerEvent_VisualizerSource) _then) =
      _$RustPlayerEvent_VisualizerSourceCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_VisualizerSourceCopyWithImpl<$Res>
    implements $RustPlayerEvent_VisualizerSourceCopyWith<$Res> {
  _$RustPlayerEvent_VisualizerSourceCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_VisualizerSource _self;
  final $Res Function(RustPlayerEvent_VisualizerSource) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_VisualizerSource(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
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

class RustPlayerEvent_ReplayGainMode extends RustPlayerEvent {
  const RustPlayerEvent_ReplayGainMode(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_ReplayGainModeCopyWith<RustPlayerEvent_ReplayGainMode>
      get copyWith => _$RustPlayerEvent_ReplayGainModeCopyWithImpl<
          RustPlayerEvent_ReplayGainMode>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_ReplayGainMode &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.replayGainMode(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_ReplayGainModeCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_ReplayGainModeCopyWith(
          RustPlayerEvent_ReplayGainMode value,
          $Res Function(RustPlayerEvent_ReplayGainMode) _then) =
      _$RustPlayerEvent_ReplayGainModeCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_ReplayGainModeCopyWithImpl<$Res>
    implements $RustPlayerEvent_ReplayGainModeCopyWith<$Res> {
  _$RustPlayerEvent_ReplayGainModeCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_ReplayGainMode _self;
  final $Res Function(RustPlayerEvent_ReplayGainMode) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_ReplayGainMode(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_DefaultReplayGain extends RustPlayerEvent {
  const RustPlayerEvent_DefaultReplayGain(this.field0) : super._();

  final double field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_DefaultReplayGainCopyWith<RustPlayerEvent_DefaultReplayGain>
      get copyWith => _$RustPlayerEvent_DefaultReplayGainCopyWithImpl<
          RustPlayerEvent_DefaultReplayGain>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_DefaultReplayGain &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.defaultReplayGain(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_DefaultReplayGainCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_DefaultReplayGainCopyWith(
          RustPlayerEvent_DefaultReplayGain value,
          $Res Function(RustPlayerEvent_DefaultReplayGain) _then) =
      _$RustPlayerEvent_DefaultReplayGainCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustPlayerEvent_DefaultReplayGainCopyWithImpl<$Res>
    implements $RustPlayerEvent_DefaultReplayGainCopyWith<$Res> {
  _$RustPlayerEvent_DefaultReplayGainCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_DefaultReplayGain _self;
  final $Res Function(RustPlayerEvent_DefaultReplayGain) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_DefaultReplayGain(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Crossfeed extends RustPlayerEvent {
  const RustPlayerEvent_Crossfeed(this.field0) : super._();

  final RustCrossfeedConfig field0;

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
  $Res call({RustCrossfeedConfig field0});
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
              as RustCrossfeedConfig,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Spatializer extends RustPlayerEvent {
  const RustPlayerEvent_Spatializer(
      {required this.enabled, required this.width})
      : super._();

  /// Whether spatializer is enabled.
  final bool enabled;

  /// Stereo widening factor.
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

class RustPlayerEvent_IsRecording extends RustPlayerEvent {
  const RustPlayerEvent_IsRecording(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_IsRecordingCopyWith<RustPlayerEvent_IsRecording>
      get copyWith => _$RustPlayerEvent_IsRecordingCopyWithImpl<
          RustPlayerEvent_IsRecording>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_IsRecording &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.isRecording(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_IsRecordingCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_IsRecordingCopyWith(
          RustPlayerEvent_IsRecording value,
          $Res Function(RustPlayerEvent_IsRecording) _then) =
      _$RustPlayerEvent_IsRecordingCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_IsRecordingCopyWithImpl<$Res>
    implements $RustPlayerEvent_IsRecordingCopyWith<$Res> {
  _$RustPlayerEvent_IsRecordingCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_IsRecording _self;
  final $Res Function(RustPlayerEvent_IsRecording) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_IsRecording(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_RecordedDuration extends RustPlayerEvent {
  const RustPlayerEvent_RecordedDuration(this.field0) : super._();

  final BigInt field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_RecordedDurationCopyWith<RustPlayerEvent_RecordedDuration>
      get copyWith => _$RustPlayerEvent_RecordedDurationCopyWithImpl<
          RustPlayerEvent_RecordedDuration>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_RecordedDuration &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.recordedDuration(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_RecordedDurationCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_RecordedDurationCopyWith(
          RustPlayerEvent_RecordedDuration value,
          $Res Function(RustPlayerEvent_RecordedDuration) _then) =
      _$RustPlayerEvent_RecordedDurationCopyWithImpl;
  @useResult
  $Res call({BigInt field0});
}

/// @nodoc
class _$RustPlayerEvent_RecordedDurationCopyWithImpl<$Res>
    implements $RustPlayerEvent_RecordedDurationCopyWith<$Res> {
  _$RustPlayerEvent_RecordedDurationCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_RecordedDuration _self;
  final $Res Function(RustPlayerEvent_RecordedDuration) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_RecordedDuration(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_IsDuckingActive extends RustPlayerEvent {
  const RustPlayerEvent_IsDuckingActive(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_IsDuckingActiveCopyWith<RustPlayerEvent_IsDuckingActive>
      get copyWith => _$RustPlayerEvent_IsDuckingActiveCopyWithImpl<
          RustPlayerEvent_IsDuckingActive>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_IsDuckingActive &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.isDuckingActive(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_IsDuckingActiveCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_IsDuckingActiveCopyWith(
          RustPlayerEvent_IsDuckingActive value,
          $Res Function(RustPlayerEvent_IsDuckingActive) _then) =
      _$RustPlayerEvent_IsDuckingActiveCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_IsDuckingActiveCopyWithImpl<$Res>
    implements $RustPlayerEvent_IsDuckingActiveCopyWith<$Res> {
  _$RustPlayerEvent_IsDuckingActiveCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_IsDuckingActive _self;
  final $Res Function(RustPlayerEvent_IsDuckingActive) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_IsDuckingActive(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_MicRmsLevel extends RustPlayerEvent {
  const RustPlayerEvent_MicRmsLevel(this.field0) : super._();

  final double field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_MicRmsLevelCopyWith<RustPlayerEvent_MicRmsLevel>
      get copyWith => _$RustPlayerEvent_MicRmsLevelCopyWithImpl<
          RustPlayerEvent_MicRmsLevel>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_MicRmsLevel &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.micRmsLevel(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_MicRmsLevelCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_MicRmsLevelCopyWith(
          RustPlayerEvent_MicRmsLevel value,
          $Res Function(RustPlayerEvent_MicRmsLevel) _then) =
      _$RustPlayerEvent_MicRmsLevelCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustPlayerEvent_MicRmsLevelCopyWithImpl<$Res>
    implements $RustPlayerEvent_MicRmsLevelCopyWith<$Res> {
  _$RustPlayerEvent_MicRmsLevelCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_MicRmsLevel _self;
  final $Res Function(RustPlayerEvent_MicRmsLevel) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_MicRmsLevel(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_VoiceCompleted extends RustPlayerEvent {
  const RustPlayerEvent_VoiceCompleted(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_VoiceCompletedCopyWith<RustPlayerEvent_VoiceCompleted>
      get copyWith => _$RustPlayerEvent_VoiceCompletedCopyWithImpl<
          RustPlayerEvent_VoiceCompleted>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_VoiceCompleted &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.voiceCompleted(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_VoiceCompletedCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_VoiceCompletedCopyWith(
          RustPlayerEvent_VoiceCompleted value,
          $Res Function(RustPlayerEvent_VoiceCompleted) _then) =
      _$RustPlayerEvent_VoiceCompletedCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_VoiceCompletedCopyWithImpl<$Res>
    implements $RustPlayerEvent_VoiceCompletedCopyWith<$Res> {
  _$RustPlayerEvent_VoiceCompletedCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_VoiceCompleted _self;
  final $Res Function(RustPlayerEvent_VoiceCompleted) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_VoiceCompleted(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_LoadedEffects extends RustPlayerEvent {
  const RustPlayerEvent_LoadedEffects(
      {required List<String> ids, required this.allocatedBytes})
      : _ids = ids,
        super._();

  /// Identifiers of loaded sound effects.
  final List<String> _ids;

  /// Identifiers of loaded sound effects.
  List<String> get ids {
    if (_ids is EqualUnmodifiableListView) return _ids;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_ids);
  }

  /// Total RAM bytes occupied by decoded effect samples.
  final BigInt allocatedBytes;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_LoadedEffectsCopyWith<RustPlayerEvent_LoadedEffects>
      get copyWith => _$RustPlayerEvent_LoadedEffectsCopyWithImpl<
          RustPlayerEvent_LoadedEffects>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_LoadedEffects &&
            const DeepCollectionEquality().equals(other.ids, _ids) &&
            (identical(other.allocatedBytes, allocatedBytes) ||
                other.allocatedBytes == allocatedBytes));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(_ids), allocatedBytes);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.loadedEffects(ids: $ids, allocatedBytes: $allocatedBytes)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_LoadedEffectsCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_LoadedEffectsCopyWith(
          RustPlayerEvent_LoadedEffects value,
          $Res Function(RustPlayerEvent_LoadedEffects) _then) =
      _$RustPlayerEvent_LoadedEffectsCopyWithImpl;
  @useResult
  $Res call({List<String> ids, BigInt allocatedBytes});
}

/// @nodoc
class _$RustPlayerEvent_LoadedEffectsCopyWithImpl<$Res>
    implements $RustPlayerEvent_LoadedEffectsCopyWith<$Res> {
  _$RustPlayerEvent_LoadedEffectsCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_LoadedEffects _self;
  final $Res Function(RustPlayerEvent_LoadedEffects) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? ids = null,
    Object? allocatedBytes = null,
  }) {
    return _then(RustPlayerEvent_LoadedEffects(
      ids: null == ids
          ? _self._ids
          : ids // ignore: cast_nullable_to_non_nullable
              as List<String>,
      allocatedBytes: null == allocatedBytes
          ? _self.allocatedBytes
          : allocatedBytes // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_ActiveVoices extends RustPlayerEvent {
  const RustPlayerEvent_ActiveVoices(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_ActiveVoicesCopyWith<RustPlayerEvent_ActiveVoices>
      get copyWith => _$RustPlayerEvent_ActiveVoicesCopyWithImpl<
          RustPlayerEvent_ActiveVoices>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_ActiveVoices &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.activeVoices(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_ActiveVoicesCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_ActiveVoicesCopyWith(
          RustPlayerEvent_ActiveVoices value,
          $Res Function(RustPlayerEvent_ActiveVoices) _then) =
      _$RustPlayerEvent_ActiveVoicesCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_ActiveVoicesCopyWithImpl<$Res>
    implements $RustPlayerEvent_ActiveVoicesCopyWith<$Res> {
  _$RustPlayerEvent_ActiveVoicesCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_ActiveVoices _self;
  final $Res Function(RustPlayerEvent_ActiveVoices) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_ActiveVoices(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_AudioMetadata extends RustPlayerEvent {
  const RustPlayerEvent_AudioMetadata(this.field0) : super._();

  final RustAudioMetadata field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_AudioMetadataCopyWith<RustPlayerEvent_AudioMetadata>
      get copyWith => _$RustPlayerEvent_AudioMetadataCopyWithImpl<
          RustPlayerEvent_AudioMetadata>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_AudioMetadata &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.audioMetadata(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_AudioMetadataCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_AudioMetadataCopyWith(
          RustPlayerEvent_AudioMetadata value,
          $Res Function(RustPlayerEvent_AudioMetadata) _then) =
      _$RustPlayerEvent_AudioMetadataCopyWithImpl;
  @useResult
  $Res call({RustAudioMetadata field0});
}

/// @nodoc
class _$RustPlayerEvent_AudioMetadataCopyWithImpl<$Res>
    implements $RustPlayerEvent_AudioMetadataCopyWith<$Res> {
  _$RustPlayerEvent_AudioMetadataCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_AudioMetadata _self;
  final $Res Function(RustPlayerEvent_AudioMetadata) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_AudioMetadata(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustAudioMetadata,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_MetadataEnabled extends RustPlayerEvent {
  const RustPlayerEvent_MetadataEnabled(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_MetadataEnabledCopyWith<RustPlayerEvent_MetadataEnabled>
      get copyWith => _$RustPlayerEvent_MetadataEnabledCopyWithImpl<
          RustPlayerEvent_MetadataEnabled>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_MetadataEnabled &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.metadataEnabled(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_MetadataEnabledCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_MetadataEnabledCopyWith(
          RustPlayerEvent_MetadataEnabled value,
          $Res Function(RustPlayerEvent_MetadataEnabled) _then) =
      _$RustPlayerEvent_MetadataEnabledCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_MetadataEnabledCopyWithImpl<$Res>
    implements $RustPlayerEvent_MetadataEnabledCopyWith<$Res> {
  _$RustPlayerEvent_MetadataEnabledCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_MetadataEnabled _self;
  final $Res Function(RustPlayerEvent_MetadataEnabled) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_MetadataEnabled(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_RecordingState extends RustPlayerEvent {
  const RustPlayerEvent_RecordingState(
      {required this.isRecording, required this.source})
      : super._();

  /// Whether file recording is currently running.
  final bool isRecording;

  /// Audio signal source captured (0: All, 1: MusicMix, 2: ActiveTrack, 3: StandbyTrack).
  final int source;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_RecordingStateCopyWith<RustPlayerEvent_RecordingState>
      get copyWith => _$RustPlayerEvent_RecordingStateCopyWithImpl<
          RustPlayerEvent_RecordingState>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_RecordingState &&
            (identical(other.isRecording, isRecording) ||
                other.isRecording == isRecording) &&
            (identical(other.source, source) || other.source == source));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, isRecording, source);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.recordingState(isRecording: $isRecording, source: $source)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_RecordingStateCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_RecordingStateCopyWith(
          RustPlayerEvent_RecordingState value,
          $Res Function(RustPlayerEvent_RecordingState) _then) =
      _$RustPlayerEvent_RecordingStateCopyWithImpl;
  @useResult
  $Res call({bool isRecording, int source});
}

/// @nodoc
class _$RustPlayerEvent_RecordingStateCopyWithImpl<$Res>
    implements $RustPlayerEvent_RecordingStateCopyWith<$Res> {
  _$RustPlayerEvent_RecordingStateCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_RecordingState _self;
  final $Res Function(RustPlayerEvent_RecordingState) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? isRecording = null,
    Object? source = null,
  }) {
    return _then(RustPlayerEvent_RecordingState(
      isRecording: null == isRecording
          ? _self.isRecording
          : isRecording // ignore: cast_nullable_to_non_nullable
              as bool,
      source: null == source
          ? _self.source
          : source // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_LoopMode extends RustPlayerEvent {
  const RustPlayerEvent_LoopMode(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_LoopModeCopyWith<RustPlayerEvent_LoopMode> get copyWith =>
      _$RustPlayerEvent_LoopModeCopyWithImpl<RustPlayerEvent_LoopMode>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_LoopMode &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.loopMode(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_LoopModeCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_LoopModeCopyWith(RustPlayerEvent_LoopMode value,
          $Res Function(RustPlayerEvent_LoopMode) _then) =
      _$RustPlayerEvent_LoopModeCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_LoopModeCopyWithImpl<$Res>
    implements $RustPlayerEvent_LoopModeCopyWith<$Res> {
  _$RustPlayerEvent_LoopModeCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_LoopMode _self;
  final $Res Function(RustPlayerEvent_LoopMode) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_LoopMode(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_IsShuffled extends RustPlayerEvent {
  const RustPlayerEvent_IsShuffled(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_IsShuffledCopyWith<RustPlayerEvent_IsShuffled>
      get copyWith =>
          _$RustPlayerEvent_IsShuffledCopyWithImpl<RustPlayerEvent_IsShuffled>(
              this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_IsShuffled &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.isShuffled(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_IsShuffledCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_IsShuffledCopyWith(RustPlayerEvent_IsShuffled value,
          $Res Function(RustPlayerEvent_IsShuffled) _then) =
      _$RustPlayerEvent_IsShuffledCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_IsShuffledCopyWithImpl<$Res>
    implements $RustPlayerEvent_IsShuffledCopyWith<$Res> {
  _$RustPlayerEvent_IsShuffledCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_IsShuffled _self;
  final $Res Function(RustPlayerEvent_IsShuffled) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_IsShuffled(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_InfiniteMix extends RustPlayerEvent {
  const RustPlayerEvent_InfiniteMix(this.field0) : super._();

  final RustInfiniteMixConfig field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_InfiniteMixCopyWith<RustPlayerEvent_InfiniteMix>
      get copyWith => _$RustPlayerEvent_InfiniteMixCopyWithImpl<
          RustPlayerEvent_InfiniteMix>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_InfiniteMix &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.infiniteMix(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_InfiniteMixCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_InfiniteMixCopyWith(
          RustPlayerEvent_InfiniteMix value,
          $Res Function(RustPlayerEvent_InfiniteMix) _then) =
      _$RustPlayerEvent_InfiniteMixCopyWithImpl;
  @useResult
  $Res call({RustInfiniteMixConfig field0});
}

/// @nodoc
class _$RustPlayerEvent_InfiniteMixCopyWithImpl<$Res>
    implements $RustPlayerEvent_InfiniteMixCopyWith<$Res> {
  _$RustPlayerEvent_InfiniteMixCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_InfiniteMix _self;
  final $Res Function(RustPlayerEvent_InfiniteMix) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_InfiniteMix(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustInfiniteMixConfig,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_PauseOnDeviceChange extends RustPlayerEvent {
  const RustPlayerEvent_PauseOnDeviceChange(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_PauseOnDeviceChangeCopyWith<
          RustPlayerEvent_PauseOnDeviceChange>
      get copyWith => _$RustPlayerEvent_PauseOnDeviceChangeCopyWithImpl<
          RustPlayerEvent_PauseOnDeviceChange>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_PauseOnDeviceChange &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.pauseOnDeviceChange(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_PauseOnDeviceChangeCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_PauseOnDeviceChangeCopyWith(
          RustPlayerEvent_PauseOnDeviceChange value,
          $Res Function(RustPlayerEvent_PauseOnDeviceChange) _then) =
      _$RustPlayerEvent_PauseOnDeviceChangeCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_PauseOnDeviceChangeCopyWithImpl<$Res>
    implements $RustPlayerEvent_PauseOnDeviceChangeCopyWith<$Res> {
  _$RustPlayerEvent_PauseOnDeviceChangeCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_PauseOnDeviceChange _self;
  final $Res Function(RustPlayerEvent_PauseOnDeviceChange) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_PauseOnDeviceChange(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Inputs extends RustPlayerEvent {
  const RustPlayerEvent_Inputs(List<RustAudioInput> field0)
      : _field0 = field0,
        super._();

  final List<RustAudioInput> _field0;
  List<RustAudioInput> get field0 {
    if (_field0 is EqualUnmodifiableListView) return _field0;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_field0);
  }

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_InputsCopyWith<RustPlayerEvent_Inputs> get copyWith =>
      _$RustPlayerEvent_InputsCopyWithImpl<RustPlayerEvent_Inputs>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Inputs &&
            const DeepCollectionEquality().equals(other.field0, _field0));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(_field0));
  }

  @override
  String toString() {
    return 'RustPlayerEvent.inputs(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_InputsCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_InputsCopyWith(RustPlayerEvent_Inputs value,
          $Res Function(RustPlayerEvent_Inputs) _then) =
      _$RustPlayerEvent_InputsCopyWithImpl;
  @useResult
  $Res call({List<RustAudioInput> field0});
}

/// @nodoc
class _$RustPlayerEvent_InputsCopyWithImpl<$Res>
    implements $RustPlayerEvent_InputsCopyWith<$Res> {
  _$RustPlayerEvent_InputsCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Inputs _self;
  final $Res Function(RustPlayerEvent_Inputs) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Inputs(
      null == field0
          ? _self._field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as List<RustAudioInput>,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_OutputDevices extends RustPlayerEvent {
  const RustPlayerEvent_OutputDevices(List<RustAudioDevice> field0)
      : _field0 = field0,
        super._();

  final List<RustAudioDevice> _field0;
  List<RustAudioDevice> get field0 {
    if (_field0 is EqualUnmodifiableListView) return _field0;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_field0);
  }

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_OutputDevicesCopyWith<RustPlayerEvent_OutputDevices>
      get copyWith => _$RustPlayerEvent_OutputDevicesCopyWithImpl<
          RustPlayerEvent_OutputDevices>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_OutputDevices &&
            const DeepCollectionEquality().equals(other.field0, _field0));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(_field0));
  }

  @override
  String toString() {
    return 'RustPlayerEvent.outputDevices(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_OutputDevicesCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_OutputDevicesCopyWith(
          RustPlayerEvent_OutputDevices value,
          $Res Function(RustPlayerEvent_OutputDevices) _then) =
      _$RustPlayerEvent_OutputDevicesCopyWithImpl;
  @useResult
  $Res call({List<RustAudioDevice> field0});
}

/// @nodoc
class _$RustPlayerEvent_OutputDevicesCopyWithImpl<$Res>
    implements $RustPlayerEvent_OutputDevicesCopyWith<$Res> {
  _$RustPlayerEvent_OutputDevicesCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_OutputDevices _self;
  final $Res Function(RustPlayerEvent_OutputDevices) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_OutputDevices(
      null == field0
          ? _self._field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as List<RustAudioDevice>,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_InputDevices extends RustPlayerEvent {
  const RustPlayerEvent_InputDevices(List<RustAudioDevice> field0)
      : _field0 = field0,
        super._();

  final List<RustAudioDevice> _field0;
  List<RustAudioDevice> get field0 {
    if (_field0 is EqualUnmodifiableListView) return _field0;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_field0);
  }

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_InputDevicesCopyWith<RustPlayerEvent_InputDevices>
      get copyWith => _$RustPlayerEvent_InputDevicesCopyWithImpl<
          RustPlayerEvent_InputDevices>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_InputDevices &&
            const DeepCollectionEquality().equals(other.field0, _field0));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(_field0));
  }

  @override
  String toString() {
    return 'RustPlayerEvent.inputDevices(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_InputDevicesCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_InputDevicesCopyWith(
          RustPlayerEvent_InputDevices value,
          $Res Function(RustPlayerEvent_InputDevices) _then) =
      _$RustPlayerEvent_InputDevicesCopyWithImpl;
  @useResult
  $Res call({List<RustAudioDevice> field0});
}

/// @nodoc
class _$RustPlayerEvent_InputDevicesCopyWithImpl<$Res>
    implements $RustPlayerEvent_InputDevicesCopyWith<$Res> {
  _$RustPlayerEvent_InputDevicesCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_InputDevices _self;
  final $Res Function(RustPlayerEvent_InputDevices) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_InputDevices(
      null == field0
          ? _self._field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as List<RustAudioDevice>,
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

class RustPlayerEvent_DartResolveRequest extends RustPlayerEvent {
  const RustPlayerEvent_DartResolveRequest(this.field0) : super._();

  final RustDartResolveRequest field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_DartResolveRequestCopyWith<
          RustPlayerEvent_DartResolveRequest>
      get copyWith => _$RustPlayerEvent_DartResolveRequestCopyWithImpl<
          RustPlayerEvent_DartResolveRequest>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_DartResolveRequest &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.dartResolveRequest(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_DartResolveRequestCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_DartResolveRequestCopyWith(
          RustPlayerEvent_DartResolveRequest value,
          $Res Function(RustPlayerEvent_DartResolveRequest) _then) =
      _$RustPlayerEvent_DartResolveRequestCopyWithImpl;
  @useResult
  $Res call({RustDartResolveRequest field0});
}

/// @nodoc
class _$RustPlayerEvent_DartResolveRequestCopyWithImpl<$Res>
    implements $RustPlayerEvent_DartResolveRequestCopyWith<$Res> {
  _$RustPlayerEvent_DartResolveRequestCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_DartResolveRequest _self;
  final $Res Function(RustPlayerEvent_DartResolveRequest) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_DartResolveRequest(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as RustDartResolveRequest,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_NeedMoreTracks extends RustPlayerEvent {
  const RustPlayerEvent_NeedMoreTracks(
      {required this.currentTrackId, required this.remainingTracks})
      : super._();

  /// ID of the current playing track.
  final PlatformInt64 currentTrackId;

  /// Remaining number of tracks ahead in the playlist queue.
  final int remainingTracks;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_NeedMoreTracksCopyWith<RustPlayerEvent_NeedMoreTracks>
      get copyWith => _$RustPlayerEvent_NeedMoreTracksCopyWithImpl<
          RustPlayerEvent_NeedMoreTracks>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_NeedMoreTracks &&
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
    return 'RustPlayerEvent.needMoreTracks(currentTrackId: $currentTrackId, remainingTracks: $remainingTracks)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_NeedMoreTracksCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_NeedMoreTracksCopyWith(
          RustPlayerEvent_NeedMoreTracks value,
          $Res Function(RustPlayerEvent_NeedMoreTracks) _then) =
      _$RustPlayerEvent_NeedMoreTracksCopyWithImpl;
  @useResult
  $Res call({PlatformInt64 currentTrackId, int remainingTracks});
}

/// @nodoc
class _$RustPlayerEvent_NeedMoreTracksCopyWithImpl<$Res>
    implements $RustPlayerEvent_NeedMoreTracksCopyWith<$Res> {
  _$RustPlayerEvent_NeedMoreTracksCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_NeedMoreTracks _self;
  final $Res Function(RustPlayerEvent_NeedMoreTracks) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? currentTrackId = null,
    Object? remainingTracks = null,
  }) {
    return _then(RustPlayerEvent_NeedMoreTracks(
      currentTrackId: null == currentTrackId
          ? _self.currentTrackId
          : currentTrackId // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
      remainingTracks: null == remainingTracks
          ? _self.remainingTracks
          : remainingTracks // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Outputs extends RustPlayerEvent {
  const RustPlayerEvent_Outputs(List<RustAudioOutput> field0)
      : _field0 = field0,
        super._();

  final List<RustAudioOutput> _field0;
  List<RustAudioOutput> get field0 {
    if (_field0 is EqualUnmodifiableListView) return _field0;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_field0);
  }

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_OutputsCopyWith<RustPlayerEvent_Outputs> get copyWith =>
      _$RustPlayerEvent_OutputsCopyWithImpl<RustPlayerEvent_Outputs>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_Outputs &&
            const DeepCollectionEquality().equals(other.field0, _field0));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(_field0));
  }

  @override
  String toString() {
    return 'RustPlayerEvent.outputs(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_OutputsCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_OutputsCopyWith(RustPlayerEvent_Outputs value,
          $Res Function(RustPlayerEvent_Outputs) _then) =
      _$RustPlayerEvent_OutputsCopyWithImpl;
  @useResult
  $Res call({List<RustAudioOutput> field0});
}

/// @nodoc
class _$RustPlayerEvent_OutputsCopyWithImpl<$Res>
    implements $RustPlayerEvent_OutputsCopyWith<$Res> {
  _$RustPlayerEvent_OutputsCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_Outputs _self;
  final $Res Function(RustPlayerEvent_Outputs) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Outputs(
      null == field0
          ? _self._field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as List<RustAudioOutput>,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_Error extends RustPlayerEvent {
  const RustPlayerEvent_Error({required this.message, required this.code})
      : super._();

  /// Detailed human-readable error description.
  final String message;

  /// Numeric error categorization code.
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

/// @nodoc
mixin _$RustResolvedSource {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is RustResolvedSource);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'RustResolvedSource()';
  }
}

/// @nodoc
class $RustResolvedSourceCopyWith<$Res> {
  $RustResolvedSourceCopyWith(
      RustResolvedSource _, $Res Function(RustResolvedSource) __);
}

/// Adds pattern-matching-related methods to [RustResolvedSource].
extension RustResolvedSourcePatterns on RustResolvedSource {
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
    TResult Function(RustResolvedSource_Path value)? path,
    TResult Function(RustResolvedSource_Url value)? url,
    TResult Function(RustResolvedSource_Fd value)? fd,
    TResult Function(RustResolvedSource_Bytes value)? bytes,
    TResult Function(RustResolvedSource_CustomStream value)? customStream,
    TResult Function(RustResolvedSource_Error value)? error,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustResolvedSource_Path() when path != null:
        return path(_that);
      case RustResolvedSource_Url() when url != null:
        return url(_that);
      case RustResolvedSource_Fd() when fd != null:
        return fd(_that);
      case RustResolvedSource_Bytes() when bytes != null:
        return bytes(_that);
      case RustResolvedSource_CustomStream() when customStream != null:
        return customStream(_that);
      case RustResolvedSource_Error() when error != null:
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
    required TResult Function(RustResolvedSource_Path value) path,
    required TResult Function(RustResolvedSource_Url value) url,
    required TResult Function(RustResolvedSource_Fd value) fd,
    required TResult Function(RustResolvedSource_Bytes value) bytes,
    required TResult Function(RustResolvedSource_CustomStream value)
        customStream,
    required TResult Function(RustResolvedSource_Error value) error,
  }) {
    final _that = this;
    switch (_that) {
      case RustResolvedSource_Path():
        return path(_that);
      case RustResolvedSource_Url():
        return url(_that);
      case RustResolvedSource_Fd():
        return fd(_that);
      case RustResolvedSource_Bytes():
        return bytes(_that);
      case RustResolvedSource_CustomStream():
        return customStream(_that);
      case RustResolvedSource_Error():
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
    TResult? Function(RustResolvedSource_Path value)? path,
    TResult? Function(RustResolvedSource_Url value)? url,
    TResult? Function(RustResolvedSource_Fd value)? fd,
    TResult? Function(RustResolvedSource_Bytes value)? bytes,
    TResult? Function(RustResolvedSource_CustomStream value)? customStream,
    TResult? Function(RustResolvedSource_Error value)? error,
  }) {
    final _that = this;
    switch (_that) {
      case RustResolvedSource_Path() when path != null:
        return path(_that);
      case RustResolvedSource_Url() when url != null:
        return url(_that);
      case RustResolvedSource_Fd() when fd != null:
        return fd(_that);
      case RustResolvedSource_Bytes() when bytes != null:
        return bytes(_that);
      case RustResolvedSource_CustomStream() when customStream != null:
        return customStream(_that);
      case RustResolvedSource_Error() when error != null:
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
    TResult Function(String path)? path,
    TResult Function(String url)? url,
    TResult Function(int fd, BigInt offset, BigInt? length, String? hintExt)?
        fd,
    TResult Function(Uint8List data, String? hintExt)? bytes,
    TResult Function(int streamId, BigInt? totalBytes, String? hintExt)?
        customStream,
    TResult Function(int code, String message)? error,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustResolvedSource_Path() when path != null:
        return path(_that.path);
      case RustResolvedSource_Url() when url != null:
        return url(_that.url);
      case RustResolvedSource_Fd() when fd != null:
        return fd(_that.fd, _that.offset, _that.length, _that.hintExt);
      case RustResolvedSource_Bytes() when bytes != null:
        return bytes(_that.data, _that.hintExt);
      case RustResolvedSource_CustomStream() when customStream != null:
        return customStream(_that.streamId, _that.totalBytes, _that.hintExt);
      case RustResolvedSource_Error() when error != null:
        return error(_that.code, _that.message);
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
    required TResult Function(String path) path,
    required TResult Function(String url) url,
    required TResult Function(
            int fd, BigInt offset, BigInt? length, String? hintExt)
        fd,
    required TResult Function(Uint8List data, String? hintExt) bytes,
    required TResult Function(int streamId, BigInt? totalBytes, String? hintExt)
        customStream,
    required TResult Function(int code, String message) error,
  }) {
    final _that = this;
    switch (_that) {
      case RustResolvedSource_Path():
        return path(_that.path);
      case RustResolvedSource_Url():
        return url(_that.url);
      case RustResolvedSource_Fd():
        return fd(_that.fd, _that.offset, _that.length, _that.hintExt);
      case RustResolvedSource_Bytes():
        return bytes(_that.data, _that.hintExt);
      case RustResolvedSource_CustomStream():
        return customStream(_that.streamId, _that.totalBytes, _that.hintExt);
      case RustResolvedSource_Error():
        return error(_that.code, _that.message);
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
    TResult? Function(String path)? path,
    TResult? Function(String url)? url,
    TResult? Function(int fd, BigInt offset, BigInt? length, String? hintExt)?
        fd,
    TResult? Function(Uint8List data, String? hintExt)? bytes,
    TResult? Function(int streamId, BigInt? totalBytes, String? hintExt)?
        customStream,
    TResult? Function(int code, String message)? error,
  }) {
    final _that = this;
    switch (_that) {
      case RustResolvedSource_Path() when path != null:
        return path(_that.path);
      case RustResolvedSource_Url() when url != null:
        return url(_that.url);
      case RustResolvedSource_Fd() when fd != null:
        return fd(_that.fd, _that.offset, _that.length, _that.hintExt);
      case RustResolvedSource_Bytes() when bytes != null:
        return bytes(_that.data, _that.hintExt);
      case RustResolvedSource_CustomStream() when customStream != null:
        return customStream(_that.streamId, _that.totalBytes, _that.hintExt);
      case RustResolvedSource_Error() when error != null:
        return error(_that.code, _that.message);
      case _:
        return null;
    }
  }
}

/// @nodoc

class RustResolvedSource_Path extends RustResolvedSource {
  const RustResolvedSource_Path({required this.path}) : super._();

  /// Local filesystem path to the audio asset.
  final String path;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustResolvedSource_PathCopyWith<RustResolvedSource_Path> get copyWith =>
      _$RustResolvedSource_PathCopyWithImpl<RustResolvedSource_Path>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustResolvedSource_Path &&
            (identical(other.path, path) || other.path == path));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, path);
  }

  @override
  String toString() {
    return 'RustResolvedSource.path(path: $path)';
  }
}

/// @nodoc
abstract mixin class $RustResolvedSource_PathCopyWith<$Res>
    implements $RustResolvedSourceCopyWith<$Res> {
  factory $RustResolvedSource_PathCopyWith(RustResolvedSource_Path value,
          $Res Function(RustResolvedSource_Path) _then) =
      _$RustResolvedSource_PathCopyWithImpl;
  @useResult
  $Res call({String path});
}

/// @nodoc
class _$RustResolvedSource_PathCopyWithImpl<$Res>
    implements $RustResolvedSource_PathCopyWith<$Res> {
  _$RustResolvedSource_PathCopyWithImpl(this._self, this._then);

  final RustResolvedSource_Path _self;
  final $Res Function(RustResolvedSource_Path) _then;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? path = null,
  }) {
    return _then(RustResolvedSource_Path(
      path: null == path
          ? _self.path
          : path // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class RustResolvedSource_Url extends RustResolvedSource {
  const RustResolvedSource_Url({required this.url}) : super._();

  /// Resolved HTTP or HTTPS URL.
  final String url;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustResolvedSource_UrlCopyWith<RustResolvedSource_Url> get copyWith =>
      _$RustResolvedSource_UrlCopyWithImpl<RustResolvedSource_Url>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustResolvedSource_Url &&
            (identical(other.url, url) || other.url == url));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, url);
  }

  @override
  String toString() {
    return 'RustResolvedSource.url(url: $url)';
  }
}

/// @nodoc
abstract mixin class $RustResolvedSource_UrlCopyWith<$Res>
    implements $RustResolvedSourceCopyWith<$Res> {
  factory $RustResolvedSource_UrlCopyWith(RustResolvedSource_Url value,
          $Res Function(RustResolvedSource_Url) _then) =
      _$RustResolvedSource_UrlCopyWithImpl;
  @useResult
  $Res call({String url});
}

/// @nodoc
class _$RustResolvedSource_UrlCopyWithImpl<$Res>
    implements $RustResolvedSource_UrlCopyWith<$Res> {
  _$RustResolvedSource_UrlCopyWithImpl(this._self, this._then);

  final RustResolvedSource_Url _self;
  final $Res Function(RustResolvedSource_Url) _then;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? url = null,
  }) {
    return _then(RustResolvedSource_Url(
      url: null == url
          ? _self.url
          : url // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class RustResolvedSource_Fd extends RustResolvedSource {
  const RustResolvedSource_Fd(
      {required this.fd, required this.offset, this.length, this.hintExt})
      : super._();

  /// Detached POSIX file descriptor whose ownership transfers to Rust.
  final int fd;

  /// Starting byte offset within the file descriptor.
  final BigInt offset;

  /// Optional byte length of the audio slice.
  final BigInt? length;

  /// Optional format or file extension hint (e.g. `"mp3"`).
  final String? hintExt;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustResolvedSource_FdCopyWith<RustResolvedSource_Fd> get copyWith =>
      _$RustResolvedSource_FdCopyWithImpl<RustResolvedSource_Fd>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustResolvedSource_Fd &&
            (identical(other.fd, fd) || other.fd == fd) &&
            (identical(other.offset, offset) || other.offset == offset) &&
            (identical(other.length, length) || other.length == length) &&
            (identical(other.hintExt, hintExt) || other.hintExt == hintExt));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, fd, offset, length, hintExt);
  }

  @override
  String toString() {
    return 'RustResolvedSource.fd(fd: $fd, offset: $offset, length: $length, hintExt: $hintExt)';
  }
}

/// @nodoc
abstract mixin class $RustResolvedSource_FdCopyWith<$Res>
    implements $RustResolvedSourceCopyWith<$Res> {
  factory $RustResolvedSource_FdCopyWith(RustResolvedSource_Fd value,
          $Res Function(RustResolvedSource_Fd) _then) =
      _$RustResolvedSource_FdCopyWithImpl;
  @useResult
  $Res call({int fd, BigInt offset, BigInt? length, String? hintExt});
}

/// @nodoc
class _$RustResolvedSource_FdCopyWithImpl<$Res>
    implements $RustResolvedSource_FdCopyWith<$Res> {
  _$RustResolvedSource_FdCopyWithImpl(this._self, this._then);

  final RustResolvedSource_Fd _self;
  final $Res Function(RustResolvedSource_Fd) _then;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? fd = null,
    Object? offset = null,
    Object? length = freezed,
    Object? hintExt = freezed,
  }) {
    return _then(RustResolvedSource_Fd(
      fd: null == fd
          ? _self.fd
          : fd // ignore: cast_nullable_to_non_nullable
              as int,
      offset: null == offset
          ? _self.offset
          : offset // ignore: cast_nullable_to_non_nullable
              as BigInt,
      length: freezed == length
          ? _self.length
          : length // ignore: cast_nullable_to_non_nullable
              as BigInt?,
      hintExt: freezed == hintExt
          ? _self.hintExt
          : hintExt // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class RustResolvedSource_Bytes extends RustResolvedSource {
  const RustResolvedSource_Bytes({required this.data, this.hintExt})
      : super._();

  /// Raw encoded audio bytes.
  final Uint8List data;

  /// Optional format or file extension hint (e.g. `"flac"`).
  final String? hintExt;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustResolvedSource_BytesCopyWith<RustResolvedSource_Bytes> get copyWith =>
      _$RustResolvedSource_BytesCopyWithImpl<RustResolvedSource_Bytes>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustResolvedSource_Bytes &&
            const DeepCollectionEquality().equals(other.data, data) &&
            (identical(other.hintExt, hintExt) || other.hintExt == hintExt));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(data), hintExt);
  }

  @override
  String toString() {
    return 'RustResolvedSource.bytes(data: $data, hintExt: $hintExt)';
  }
}

/// @nodoc
abstract mixin class $RustResolvedSource_BytesCopyWith<$Res>
    implements $RustResolvedSourceCopyWith<$Res> {
  factory $RustResolvedSource_BytesCopyWith(RustResolvedSource_Bytes value,
          $Res Function(RustResolvedSource_Bytes) _then) =
      _$RustResolvedSource_BytesCopyWithImpl;
  @useResult
  $Res call({Uint8List data, String? hintExt});
}

/// @nodoc
class _$RustResolvedSource_BytesCopyWithImpl<$Res>
    implements $RustResolvedSource_BytesCopyWith<$Res> {
  _$RustResolvedSource_BytesCopyWithImpl(this._self, this._then);

  final RustResolvedSource_Bytes _self;
  final $Res Function(RustResolvedSource_Bytes) _then;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? data = null,
    Object? hintExt = freezed,
  }) {
    return _then(RustResolvedSource_Bytes(
      data: null == data
          ? _self.data
          : data // ignore: cast_nullable_to_non_nullable
              as Uint8List,
      hintExt: freezed == hintExt
          ? _self.hintExt
          : hintExt // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class RustResolvedSource_CustomStream extends RustResolvedSource {
  const RustResolvedSource_CustomStream(
      {required this.streamId, this.totalBytes, this.hintExt})
      : super._();

  /// Identifier of the registered custom byte stream.
  final int streamId;

  /// Total byte length of the stream when known.
  final BigInt? totalBytes;

  /// Optional format or file extension hint (e.g. `"ogg"`).
  final String? hintExt;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustResolvedSource_CustomStreamCopyWith<RustResolvedSource_CustomStream>
      get copyWith => _$RustResolvedSource_CustomStreamCopyWithImpl<
          RustResolvedSource_CustomStream>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustResolvedSource_CustomStream &&
            (identical(other.streamId, streamId) ||
                other.streamId == streamId) &&
            (identical(other.totalBytes, totalBytes) ||
                other.totalBytes == totalBytes) &&
            (identical(other.hintExt, hintExt) || other.hintExt == hintExt));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, streamId, totalBytes, hintExt);
  }

  @override
  String toString() {
    return 'RustResolvedSource.customStream(streamId: $streamId, totalBytes: $totalBytes, hintExt: $hintExt)';
  }
}

/// @nodoc
abstract mixin class $RustResolvedSource_CustomStreamCopyWith<$Res>
    implements $RustResolvedSourceCopyWith<$Res> {
  factory $RustResolvedSource_CustomStreamCopyWith(
          RustResolvedSource_CustomStream value,
          $Res Function(RustResolvedSource_CustomStream) _then) =
      _$RustResolvedSource_CustomStreamCopyWithImpl;
  @useResult
  $Res call({int streamId, BigInt? totalBytes, String? hintExt});
}

/// @nodoc
class _$RustResolvedSource_CustomStreamCopyWithImpl<$Res>
    implements $RustResolvedSource_CustomStreamCopyWith<$Res> {
  _$RustResolvedSource_CustomStreamCopyWithImpl(this._self, this._then);

  final RustResolvedSource_CustomStream _self;
  final $Res Function(RustResolvedSource_CustomStream) _then;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? streamId = null,
    Object? totalBytes = freezed,
    Object? hintExt = freezed,
  }) {
    return _then(RustResolvedSource_CustomStream(
      streamId: null == streamId
          ? _self.streamId
          : streamId // ignore: cast_nullable_to_non_nullable
              as int,
      totalBytes: freezed == totalBytes
          ? _self.totalBytes
          : totalBytes // ignore: cast_nullable_to_non_nullable
              as BigInt?,
      hintExt: freezed == hintExt
          ? _self.hintExt
          : hintExt // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class RustResolvedSource_Error extends RustResolvedSource {
  const RustResolvedSource_Error({required this.code, required this.message})
      : super._();

  /// Numeric error code describing the failure reason.
  final int code;

  /// Human-readable error message.
  final String message;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustResolvedSource_ErrorCopyWith<RustResolvedSource_Error> get copyWith =>
      _$RustResolvedSource_ErrorCopyWithImpl<RustResolvedSource_Error>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustResolvedSource_Error &&
            (identical(other.code, code) || other.code == code) &&
            (identical(other.message, message) || other.message == message));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, code, message);
  }

  @override
  String toString() {
    return 'RustResolvedSource.error(code: $code, message: $message)';
  }
}

/// @nodoc
abstract mixin class $RustResolvedSource_ErrorCopyWith<$Res>
    implements $RustResolvedSourceCopyWith<$Res> {
  factory $RustResolvedSource_ErrorCopyWith(RustResolvedSource_Error value,
          $Res Function(RustResolvedSource_Error) _then) =
      _$RustResolvedSource_ErrorCopyWithImpl;
  @useResult
  $Res call({int code, String message});
}

/// @nodoc
class _$RustResolvedSource_ErrorCopyWithImpl<$Res>
    implements $RustResolvedSource_ErrorCopyWith<$Res> {
  _$RustResolvedSource_ErrorCopyWithImpl(this._self, this._then);

  final RustResolvedSource_Error _self;
  final $Res Function(RustResolvedSource_Error) _then;

  /// Create a copy of RustResolvedSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? code = null,
    Object? message = null,
  }) {
    return _then(RustResolvedSource_Error(
      code: null == code
          ? _self.code
          : code // ignore: cast_nullable_to_non_nullable
              as int,
      message: null == message
          ? _self.message
          : message // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

// dart format on
