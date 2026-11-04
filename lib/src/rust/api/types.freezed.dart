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
mixin _$RustAudioOutput {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is RustAudioOutput);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'RustAudioOutput()';
  }
}

/// @nodoc
class $RustAudioOutputCopyWith<$Res> {
  $RustAudioOutputCopyWith(
      RustAudioOutput _, $Res Function(RustAudioOutput) __);
}

/// Adds pattern-matching-related methods to [RustAudioOutput].
extension RustAudioOutputPatterns on RustAudioOutput {
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
    TResult Function(RustAudioOutput_Speaker value)? speaker,
    TResult Function(RustAudioOutput_Device value)? device,
    TResult Function(RustAudioOutput_Cue value)? cue,
    TResult Function(RustAudioOutput_File value)? file,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustAudioOutput_Speaker() when speaker != null:
        return speaker(_that);
      case RustAudioOutput_Device() when device != null:
        return device(_that);
      case RustAudioOutput_Cue() when cue != null:
        return cue(_that);
      case RustAudioOutput_File() when file != null:
        return file(_that);
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
    required TResult Function(RustAudioOutput_Speaker value) speaker,
    required TResult Function(RustAudioOutput_Device value) device,
    required TResult Function(RustAudioOutput_Cue value) cue,
    required TResult Function(RustAudioOutput_File value) file,
  }) {
    final _that = this;
    switch (_that) {
      case RustAudioOutput_Speaker():
        return speaker(_that);
      case RustAudioOutput_Device():
        return device(_that);
      case RustAudioOutput_Cue():
        return cue(_that);
      case RustAudioOutput_File():
        return file(_that);
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
    TResult? Function(RustAudioOutput_Speaker value)? speaker,
    TResult? Function(RustAudioOutput_Device value)? device,
    TResult? Function(RustAudioOutput_Cue value)? cue,
    TResult? Function(RustAudioOutput_File value)? file,
  }) {
    final _that = this;
    switch (_that) {
      case RustAudioOutput_Speaker() when speaker != null:
        return speaker(_that);
      case RustAudioOutput_Device() when device != null:
        return device(_that);
      case RustAudioOutput_Cue() when cue != null:
        return cue(_that);
      case RustAudioOutput_File() when file != null:
        return file(_that);
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
    TResult Function(bool exclusiveMode)? speaker,
    TResult Function(String deviceId, bool exclusiveMode)? device,
    TResult Function(String deviceId, int source)? cue,
    TResult Function(String path, int format)? file,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustAudioOutput_Speaker() when speaker != null:
        return speaker(_that.exclusiveMode);
      case RustAudioOutput_Device() when device != null:
        return device(_that.deviceId, _that.exclusiveMode);
      case RustAudioOutput_Cue() when cue != null:
        return cue(_that.deviceId, _that.source);
      case RustAudioOutput_File() when file != null:
        return file(_that.path, _that.format);
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
    required TResult Function(bool exclusiveMode) speaker,
    required TResult Function(String deviceId, bool exclusiveMode) device,
    required TResult Function(String deviceId, int source) cue,
    required TResult Function(String path, int format) file,
  }) {
    final _that = this;
    switch (_that) {
      case RustAudioOutput_Speaker():
        return speaker(_that.exclusiveMode);
      case RustAudioOutput_Device():
        return device(_that.deviceId, _that.exclusiveMode);
      case RustAudioOutput_Cue():
        return cue(_that.deviceId, _that.source);
      case RustAudioOutput_File():
        return file(_that.path, _that.format);
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
    TResult? Function(bool exclusiveMode)? speaker,
    TResult? Function(String deviceId, bool exclusiveMode)? device,
    TResult? Function(String deviceId, int source)? cue,
    TResult? Function(String path, int format)? file,
  }) {
    final _that = this;
    switch (_that) {
      case RustAudioOutput_Speaker() when speaker != null:
        return speaker(_that.exclusiveMode);
      case RustAudioOutput_Device() when device != null:
        return device(_that.deviceId, _that.exclusiveMode);
      case RustAudioOutput_Cue() when cue != null:
        return cue(_that.deviceId, _that.source);
      case RustAudioOutput_File() when file != null:
        return file(_that.path, _that.format);
      case _:
        return null;
    }
  }
}

/// @nodoc

class RustAudioOutput_Speaker extends RustAudioOutput {
  const RustAudioOutput_Speaker({required this.exclusiveMode}) : super._();

  final bool exclusiveMode;

  /// Create a copy of RustAudioOutput
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustAudioOutput_SpeakerCopyWith<RustAudioOutput_Speaker> get copyWith =>
      _$RustAudioOutput_SpeakerCopyWithImpl<RustAudioOutput_Speaker>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustAudioOutput_Speaker &&
            (identical(other.exclusiveMode, exclusiveMode) ||
                other.exclusiveMode == exclusiveMode));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, exclusiveMode);
  }

  @override
  String toString() {
    return 'RustAudioOutput.speaker(exclusiveMode: $exclusiveMode)';
  }
}

/// @nodoc
abstract mixin class $RustAudioOutput_SpeakerCopyWith<$Res>
    implements $RustAudioOutputCopyWith<$Res> {
  factory $RustAudioOutput_SpeakerCopyWith(RustAudioOutput_Speaker value,
          $Res Function(RustAudioOutput_Speaker) _then) =
      _$RustAudioOutput_SpeakerCopyWithImpl;
  @useResult
  $Res call({bool exclusiveMode});
}

/// @nodoc
class _$RustAudioOutput_SpeakerCopyWithImpl<$Res>
    implements $RustAudioOutput_SpeakerCopyWith<$Res> {
  _$RustAudioOutput_SpeakerCopyWithImpl(this._self, this._then);

  final RustAudioOutput_Speaker _self;
  final $Res Function(RustAudioOutput_Speaker) _then;

  /// Create a copy of RustAudioOutput
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? exclusiveMode = null,
  }) {
    return _then(RustAudioOutput_Speaker(
      exclusiveMode: null == exclusiveMode
          ? _self.exclusiveMode
          : exclusiveMode // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustAudioOutput_Device extends RustAudioOutput {
  const RustAudioOutput_Device(
      {required this.deviceId, required this.exclusiveMode})
      : super._();

  final String deviceId;
  final bool exclusiveMode;

  /// Create a copy of RustAudioOutput
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustAudioOutput_DeviceCopyWith<RustAudioOutput_Device> get copyWith =>
      _$RustAudioOutput_DeviceCopyWithImpl<RustAudioOutput_Device>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustAudioOutput_Device &&
            (identical(other.deviceId, deviceId) ||
                other.deviceId == deviceId) &&
            (identical(other.exclusiveMode, exclusiveMode) ||
                other.exclusiveMode == exclusiveMode));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, deviceId, exclusiveMode);
  }

  @override
  String toString() {
    return 'RustAudioOutput.device(deviceId: $deviceId, exclusiveMode: $exclusiveMode)';
  }
}

/// @nodoc
abstract mixin class $RustAudioOutput_DeviceCopyWith<$Res>
    implements $RustAudioOutputCopyWith<$Res> {
  factory $RustAudioOutput_DeviceCopyWith(RustAudioOutput_Device value,
          $Res Function(RustAudioOutput_Device) _then) =
      _$RustAudioOutput_DeviceCopyWithImpl;
  @useResult
  $Res call({String deviceId, bool exclusiveMode});
}

/// @nodoc
class _$RustAudioOutput_DeviceCopyWithImpl<$Res>
    implements $RustAudioOutput_DeviceCopyWith<$Res> {
  _$RustAudioOutput_DeviceCopyWithImpl(this._self, this._then);

  final RustAudioOutput_Device _self;
  final $Res Function(RustAudioOutput_Device) _then;

  /// Create a copy of RustAudioOutput
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? deviceId = null,
    Object? exclusiveMode = null,
  }) {
    return _then(RustAudioOutput_Device(
      deviceId: null == deviceId
          ? _self.deviceId
          : deviceId // ignore: cast_nullable_to_non_nullable
              as String,
      exclusiveMode: null == exclusiveMode
          ? _self.exclusiveMode
          : exclusiveMode // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustAudioOutput_Cue extends RustAudioOutput {
  const RustAudioOutput_Cue({required this.deviceId, required this.source})
      : super._();

  final String deviceId;
  final int source;

  /// Create a copy of RustAudioOutput
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustAudioOutput_CueCopyWith<RustAudioOutput_Cue> get copyWith =>
      _$RustAudioOutput_CueCopyWithImpl<RustAudioOutput_Cue>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustAudioOutput_Cue &&
            (identical(other.deviceId, deviceId) ||
                other.deviceId == deviceId) &&
            (identical(other.source, source) || other.source == source));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, deviceId, source);
  }

  @override
  String toString() {
    return 'RustAudioOutput.cue(deviceId: $deviceId, source: $source)';
  }
}

/// @nodoc
abstract mixin class $RustAudioOutput_CueCopyWith<$Res>
    implements $RustAudioOutputCopyWith<$Res> {
  factory $RustAudioOutput_CueCopyWith(
          RustAudioOutput_Cue value, $Res Function(RustAudioOutput_Cue) _then) =
      _$RustAudioOutput_CueCopyWithImpl;
  @useResult
  $Res call({String deviceId, int source});
}

/// @nodoc
class _$RustAudioOutput_CueCopyWithImpl<$Res>
    implements $RustAudioOutput_CueCopyWith<$Res> {
  _$RustAudioOutput_CueCopyWithImpl(this._self, this._then);

  final RustAudioOutput_Cue _self;
  final $Res Function(RustAudioOutput_Cue) _then;

  /// Create a copy of RustAudioOutput
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? deviceId = null,
    Object? source = null,
  }) {
    return _then(RustAudioOutput_Cue(
      deviceId: null == deviceId
          ? _self.deviceId
          : deviceId // ignore: cast_nullable_to_non_nullable
              as String,
      source: null == source
          ? _self.source
          : source // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class RustAudioOutput_File extends RustAudioOutput {
  const RustAudioOutput_File({required this.path, required this.format})
      : super._();

  final String path;
  final int format;

  /// Create a copy of RustAudioOutput
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustAudioOutput_FileCopyWith<RustAudioOutput_File> get copyWith =>
      _$RustAudioOutput_FileCopyWithImpl<RustAudioOutput_File>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustAudioOutput_File &&
            (identical(other.path, path) || other.path == path) &&
            (identical(other.format, format) || other.format == format));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, path, format);
  }

  @override
  String toString() {
    return 'RustAudioOutput.file(path: $path, format: $format)';
  }
}

/// @nodoc
abstract mixin class $RustAudioOutput_FileCopyWith<$Res>
    implements $RustAudioOutputCopyWith<$Res> {
  factory $RustAudioOutput_FileCopyWith(RustAudioOutput_File value,
          $Res Function(RustAudioOutput_File) _then) =
      _$RustAudioOutput_FileCopyWithImpl;
  @useResult
  $Res call({String path, int format});
}

/// @nodoc
class _$RustAudioOutput_FileCopyWithImpl<$Res>
    implements $RustAudioOutput_FileCopyWith<$Res> {
  _$RustAudioOutput_FileCopyWithImpl(this._self, this._then);

  final RustAudioOutput_File _self;
  final $Res Function(RustAudioOutput_File) _then;

  /// Create a copy of RustAudioOutput
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? path = null,
    Object? format = null,
  }) {
    return _then(RustAudioOutput_File(
      path: null == path
          ? _self.path
          : path // ignore: cast_nullable_to_non_nullable
              as String,
      format: null == format
          ? _self.format
          : format // ignore: cast_nullable_to_non_nullable
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
    TResult Function(RustPlayerEvent_PlaybackState value)? playbackState,
    TResult Function(RustPlayerEvent_State value)? state,
    TResult Function(RustPlayerEvent_Position value)? position,
    TResult Function(RustPlayerEvent_Duration value)? duration,
    TResult Function(RustPlayerEvent_IsPlaying value)? isPlaying,
    TResult Function(RustPlayerEvent_IsBuffering value)? isBuffering,
    TResult Function(RustPlayerEvent_IsCompleted value)? isCompleted,
    TResult Function(RustPlayerEvent_Buffer value)? buffer,
    TResult Function(RustPlayerEvent_Queue value)? queue,
    TResult Function(RustPlayerEvent_CurrentIndex value)? currentIndex,
    TResult Function(RustPlayerEvent_IsCrossfading value)? isCrossfading,
    TResult Function(RustPlayerEvent_CrossfadeConfig value)? crossfadeConfig,
    TResult Function(RustPlayerEvent_Visualizer value)? visualizer,
    TResult Function(RustPlayerEvent_VisualizerEnabled value)?
        visualizerEnabled,
    TResult Function(RustPlayerEvent_Volume value)? volume,
    TResult Function(RustPlayerEvent_Rate value)? rate,
    TResult Function(RustPlayerEvent_Pitch value)? pitch,
    TResult Function(RustPlayerEvent_Balance value)? balance,
    TResult Function(RustPlayerEvent_Mono value)? mono,
    TResult Function(RustPlayerEvent_Bitrate value)? bitrate,
    TResult Function(RustPlayerEvent_BufferSize value)? bufferSize,
    TResult Function(RustPlayerEvent_SilenceConfig value)? silenceConfig,
    TResult Function(RustPlayerEvent_SilenceSaved value)? silenceSaved,
    TResult Function(RustPlayerEvent_Equalizer value)? equalizer,
    TResult Function(RustPlayerEvent_Preamp value)? preamp,
    TResult Function(RustPlayerEvent_ReplayGain value)? replayGain,
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
    TResult Function(RustPlayerEvent_MetaBytes value)? metaBytes,
    TResult Function(RustPlayerEvent_MetaBytesEnabled value)? metaBytesEnabled,
    TResult Function(RustPlayerEvent_CueVolume value)? cueVolume,
    TResult Function(RustPlayerEvent_CueSource value)? cueSource,
    TResult Function(RustPlayerEvent_LoopMode value)? loopMode,
    TResult Function(RustPlayerEvent_IsShuffled value)? isShuffled,
    TResult Function(RustPlayerEvent_PauseOnDeviceChange value)?
        pauseOnDeviceChange,
    TResult Function(RustPlayerEvent_MicrophoneEnabled value)?
        microphoneEnabled,
    TResult Function(RustPlayerEvent_MicVolume value)? micVolume,
    TResult Function(RustPlayerEvent_DirectMonitoringEnabled value)?
        directMonitoringEnabled,
    TResult Function(RustPlayerEvent_OutputDevices value)? outputDevices,
    TResult Function(RustPlayerEvent_InputDevices value)? inputDevices,
    TResult Function(RustPlayerEvent_DartReadRequest value)? dartReadRequest,
    TResult Function(RustPlayerEvent_Device value)? device,
    TResult Function(RustPlayerEvent_Error value)? error,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_PlaybackState() when playbackState != null:
        return playbackState(_that);
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
      case RustPlayerEvent_Bitrate() when bitrate != null:
        return bitrate(_that);
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
      case RustPlayerEvent_MetaBytes() when metaBytes != null:
        return metaBytes(_that);
      case RustPlayerEvent_MetaBytesEnabled() when metaBytesEnabled != null:
        return metaBytesEnabled(_that);
      case RustPlayerEvent_CueVolume() when cueVolume != null:
        return cueVolume(_that);
      case RustPlayerEvent_CueSource() when cueSource != null:
        return cueSource(_that);
      case RustPlayerEvent_LoopMode() when loopMode != null:
        return loopMode(_that);
      case RustPlayerEvent_IsShuffled() when isShuffled != null:
        return isShuffled(_that);
      case RustPlayerEvent_PauseOnDeviceChange()
          when pauseOnDeviceChange != null:
        return pauseOnDeviceChange(_that);
      case RustPlayerEvent_MicrophoneEnabled() when microphoneEnabled != null:
        return microphoneEnabled(_that);
      case RustPlayerEvent_MicVolume() when micVolume != null:
        return micVolume(_that);
      case RustPlayerEvent_DirectMonitoringEnabled()
          when directMonitoringEnabled != null:
        return directMonitoringEnabled(_that);
      case RustPlayerEvent_OutputDevices() when outputDevices != null:
        return outputDevices(_that);
      case RustPlayerEvent_InputDevices() when inputDevices != null:
        return inputDevices(_that);
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that);
      case RustPlayerEvent_Device() when device != null:
        return device(_that);
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
    required TResult Function(RustPlayerEvent_PlaybackState value)
        playbackState,
    required TResult Function(RustPlayerEvent_State value) state,
    required TResult Function(RustPlayerEvent_Position value) position,
    required TResult Function(RustPlayerEvent_Duration value) duration,
    required TResult Function(RustPlayerEvent_IsPlaying value) isPlaying,
    required TResult Function(RustPlayerEvent_IsBuffering value) isBuffering,
    required TResult Function(RustPlayerEvent_IsCompleted value) isCompleted,
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
    required TResult Function(RustPlayerEvent_Volume value) volume,
    required TResult Function(RustPlayerEvent_Rate value) rate,
    required TResult Function(RustPlayerEvent_Pitch value) pitch,
    required TResult Function(RustPlayerEvent_Balance value) balance,
    required TResult Function(RustPlayerEvent_Mono value) mono,
    required TResult Function(RustPlayerEvent_Bitrate value) bitrate,
    required TResult Function(RustPlayerEvent_BufferSize value) bufferSize,
    required TResult Function(RustPlayerEvent_SilenceConfig value)
        silenceConfig,
    required TResult Function(RustPlayerEvent_SilenceSaved value) silenceSaved,
    required TResult Function(RustPlayerEvent_Equalizer value) equalizer,
    required TResult Function(RustPlayerEvent_Preamp value) preamp,
    required TResult Function(RustPlayerEvent_ReplayGain value) replayGain,
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
    required TResult Function(RustPlayerEvent_MetaBytes value) metaBytes,
    required TResult Function(RustPlayerEvent_MetaBytesEnabled value)
        metaBytesEnabled,
    required TResult Function(RustPlayerEvent_CueVolume value) cueVolume,
    required TResult Function(RustPlayerEvent_CueSource value) cueSource,
    required TResult Function(RustPlayerEvent_LoopMode value) loopMode,
    required TResult Function(RustPlayerEvent_IsShuffled value) isShuffled,
    required TResult Function(RustPlayerEvent_PauseOnDeviceChange value)
        pauseOnDeviceChange,
    required TResult Function(RustPlayerEvent_MicrophoneEnabled value)
        microphoneEnabled,
    required TResult Function(RustPlayerEvent_MicVolume value) micVolume,
    required TResult Function(RustPlayerEvent_DirectMonitoringEnabled value)
        directMonitoringEnabled,
    required TResult Function(RustPlayerEvent_OutputDevices value)
        outputDevices,
    required TResult Function(RustPlayerEvent_InputDevices value) inputDevices,
    required TResult Function(RustPlayerEvent_DartReadRequest value)
        dartReadRequest,
    required TResult Function(RustPlayerEvent_Device value) device,
    required TResult Function(RustPlayerEvent_Error value) error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_PlaybackState():
        return playbackState(_that);
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
      case RustPlayerEvent_Bitrate():
        return bitrate(_that);
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
      case RustPlayerEvent_MetaBytes():
        return metaBytes(_that);
      case RustPlayerEvent_MetaBytesEnabled():
        return metaBytesEnabled(_that);
      case RustPlayerEvent_CueVolume():
        return cueVolume(_that);
      case RustPlayerEvent_CueSource():
        return cueSource(_that);
      case RustPlayerEvent_LoopMode():
        return loopMode(_that);
      case RustPlayerEvent_IsShuffled():
        return isShuffled(_that);
      case RustPlayerEvent_PauseOnDeviceChange():
        return pauseOnDeviceChange(_that);
      case RustPlayerEvent_MicrophoneEnabled():
        return microphoneEnabled(_that);
      case RustPlayerEvent_MicVolume():
        return micVolume(_that);
      case RustPlayerEvent_DirectMonitoringEnabled():
        return directMonitoringEnabled(_that);
      case RustPlayerEvent_OutputDevices():
        return outputDevices(_that);
      case RustPlayerEvent_InputDevices():
        return inputDevices(_that);
      case RustPlayerEvent_DartReadRequest():
        return dartReadRequest(_that);
      case RustPlayerEvent_Device():
        return device(_that);
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
    TResult? Function(RustPlayerEvent_PlaybackState value)? playbackState,
    TResult? Function(RustPlayerEvent_State value)? state,
    TResult? Function(RustPlayerEvent_Position value)? position,
    TResult? Function(RustPlayerEvent_Duration value)? duration,
    TResult? Function(RustPlayerEvent_IsPlaying value)? isPlaying,
    TResult? Function(RustPlayerEvent_IsBuffering value)? isBuffering,
    TResult? Function(RustPlayerEvent_IsCompleted value)? isCompleted,
    TResult? Function(RustPlayerEvent_Buffer value)? buffer,
    TResult? Function(RustPlayerEvent_Queue value)? queue,
    TResult? Function(RustPlayerEvent_CurrentIndex value)? currentIndex,
    TResult? Function(RustPlayerEvent_IsCrossfading value)? isCrossfading,
    TResult? Function(RustPlayerEvent_CrossfadeConfig value)? crossfadeConfig,
    TResult? Function(RustPlayerEvent_Visualizer value)? visualizer,
    TResult? Function(RustPlayerEvent_VisualizerEnabled value)?
        visualizerEnabled,
    TResult? Function(RustPlayerEvent_Volume value)? volume,
    TResult? Function(RustPlayerEvent_Rate value)? rate,
    TResult? Function(RustPlayerEvent_Pitch value)? pitch,
    TResult? Function(RustPlayerEvent_Balance value)? balance,
    TResult? Function(RustPlayerEvent_Mono value)? mono,
    TResult? Function(RustPlayerEvent_Bitrate value)? bitrate,
    TResult? Function(RustPlayerEvent_BufferSize value)? bufferSize,
    TResult? Function(RustPlayerEvent_SilenceConfig value)? silenceConfig,
    TResult? Function(RustPlayerEvent_SilenceSaved value)? silenceSaved,
    TResult? Function(RustPlayerEvent_Equalizer value)? equalizer,
    TResult? Function(RustPlayerEvent_Preamp value)? preamp,
    TResult? Function(RustPlayerEvent_ReplayGain value)? replayGain,
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
    TResult? Function(RustPlayerEvent_MetaBytes value)? metaBytes,
    TResult? Function(RustPlayerEvent_MetaBytesEnabled value)? metaBytesEnabled,
    TResult? Function(RustPlayerEvent_CueVolume value)? cueVolume,
    TResult? Function(RustPlayerEvent_CueSource value)? cueSource,
    TResult? Function(RustPlayerEvent_LoopMode value)? loopMode,
    TResult? Function(RustPlayerEvent_IsShuffled value)? isShuffled,
    TResult? Function(RustPlayerEvent_PauseOnDeviceChange value)?
        pauseOnDeviceChange,
    TResult? Function(RustPlayerEvent_MicrophoneEnabled value)?
        microphoneEnabled,
    TResult? Function(RustPlayerEvent_MicVolume value)? micVolume,
    TResult? Function(RustPlayerEvent_DirectMonitoringEnabled value)?
        directMonitoringEnabled,
    TResult? Function(RustPlayerEvent_OutputDevices value)? outputDevices,
    TResult? Function(RustPlayerEvent_InputDevices value)? inputDevices,
    TResult? Function(RustPlayerEvent_DartReadRequest value)? dartReadRequest,
    TResult? Function(RustPlayerEvent_Device value)? device,
    TResult? Function(RustPlayerEvent_Error value)? error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_PlaybackState() when playbackState != null:
        return playbackState(_that);
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
      case RustPlayerEvent_Bitrate() when bitrate != null:
        return bitrate(_that);
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
      case RustPlayerEvent_MetaBytes() when metaBytes != null:
        return metaBytes(_that);
      case RustPlayerEvent_MetaBytesEnabled() when metaBytesEnabled != null:
        return metaBytesEnabled(_that);
      case RustPlayerEvent_CueVolume() when cueVolume != null:
        return cueVolume(_that);
      case RustPlayerEvent_CueSource() when cueSource != null:
        return cueSource(_that);
      case RustPlayerEvent_LoopMode() when loopMode != null:
        return loopMode(_that);
      case RustPlayerEvent_IsShuffled() when isShuffled != null:
        return isShuffled(_that);
      case RustPlayerEvent_PauseOnDeviceChange()
          when pauseOnDeviceChange != null:
        return pauseOnDeviceChange(_that);
      case RustPlayerEvent_MicrophoneEnabled() when microphoneEnabled != null:
        return microphoneEnabled(_that);
      case RustPlayerEvent_MicVolume() when micVolume != null:
        return micVolume(_that);
      case RustPlayerEvent_DirectMonitoringEnabled()
          when directMonitoringEnabled != null:
        return directMonitoringEnabled(_that);
      case RustPlayerEvent_OutputDevices() when outputDevices != null:
        return outputDevices(_that);
      case RustPlayerEvent_InputDevices() when inputDevices != null:
        return inputDevices(_that);
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that);
      case RustPlayerEvent_Device() when device != null:
        return device(_that);
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
    TResult Function(int field0)? playbackState,
    TResult Function(int field0)? state,
    TResult Function(PlatformInt64 field0)? position,
    TResult Function(PlatformInt64 field0)? duration,
    TResult Function(bool field0)? isPlaying,
    TResult Function(bool field0)? isBuffering,
    TResult Function(bool field0)? isCompleted,
    TResult Function(RustBuffer field0)? buffer,
    TResult Function(List<RustAudioSource> field0)? queue,
    TResult Function(int field0)? currentIndex,
    TResult Function(bool field0)? isCrossfading,
    TResult Function(RustCrossfadeConfig field0)? crossfadeConfig,
    TResult Function(RustVisualizerData field0)? visualizer,
    TResult Function(bool field0)? visualizerEnabled,
    TResult Function(double field0)? volume,
    TResult Function(double field0)? rate,
    TResult Function(double field0)? pitch,
    TResult Function(double field0)? balance,
    TResult Function(bool field0)? mono,
    TResult Function(int field0)? bitrate,
    TResult Function(int field0)? bufferSize,
    TResult Function(RustSilenceConfig field0)? silenceConfig,
    TResult Function(PlatformInt64 field0)? silenceSaved,
    TResult Function(RustEqualizerParams field0)? equalizer,
    TResult Function(double field0)? preamp,
    TResult Function(RustReplayGainConfig field0)? replayGain,
    TResult Function(int field0)? crossfeed,
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
    TResult Function(Uint8List field0)? metaBytes,
    TResult Function(bool field0)? metaBytesEnabled,
    TResult Function(double field0)? cueVolume,
    TResult Function(int field0)? cueSource,
    TResult Function(int field0)? loopMode,
    TResult Function(bool field0)? isShuffled,
    TResult Function(bool field0)? pauseOnDeviceChange,
    TResult Function(bool field0)? microphoneEnabled,
    TResult Function(double field0)? micVolume,
    TResult Function(bool field0)? directMonitoringEnabled,
    TResult Function(List<RustAudioDevice> field0)? outputDevices,
    TResult Function(List<RustAudioDevice> field0)? inputDevices,
    TResult Function(RustDartReadRequest field0)? dartReadRequest,
    TResult Function(RustAudioDevice field0)? device,
    TResult Function(String message, int code)? error,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_PlaybackState() when playbackState != null:
        return playbackState(_that.field0);
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
      case RustPlayerEvent_Buffer() when buffer != null:
        return buffer(_that.field0);
      case RustPlayerEvent_Queue() when queue != null:
        return queue(_that.field0);
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
      case RustPlayerEvent_Bitrate() when bitrate != null:
        return bitrate(_that.field0);
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
      case RustPlayerEvent_MetaBytes() when metaBytes != null:
        return metaBytes(_that.field0);
      case RustPlayerEvent_MetaBytesEnabled() when metaBytesEnabled != null:
        return metaBytesEnabled(_that.field0);
      case RustPlayerEvent_CueVolume() when cueVolume != null:
        return cueVolume(_that.field0);
      case RustPlayerEvent_CueSource() when cueSource != null:
        return cueSource(_that.field0);
      case RustPlayerEvent_LoopMode() when loopMode != null:
        return loopMode(_that.field0);
      case RustPlayerEvent_IsShuffled() when isShuffled != null:
        return isShuffled(_that.field0);
      case RustPlayerEvent_PauseOnDeviceChange()
          when pauseOnDeviceChange != null:
        return pauseOnDeviceChange(_that.field0);
      case RustPlayerEvent_MicrophoneEnabled() when microphoneEnabled != null:
        return microphoneEnabled(_that.field0);
      case RustPlayerEvent_MicVolume() when micVolume != null:
        return micVolume(_that.field0);
      case RustPlayerEvent_DirectMonitoringEnabled()
          when directMonitoringEnabled != null:
        return directMonitoringEnabled(_that.field0);
      case RustPlayerEvent_OutputDevices() when outputDevices != null:
        return outputDevices(_that.field0);
      case RustPlayerEvent_InputDevices() when inputDevices != null:
        return inputDevices(_that.field0);
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that.field0);
      case RustPlayerEvent_Device() when device != null:
        return device(_that.field0);
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
    required TResult Function(int field0) playbackState,
    required TResult Function(int field0) state,
    required TResult Function(PlatformInt64 field0) position,
    required TResult Function(PlatformInt64 field0) duration,
    required TResult Function(bool field0) isPlaying,
    required TResult Function(bool field0) isBuffering,
    required TResult Function(bool field0) isCompleted,
    required TResult Function(RustBuffer field0) buffer,
    required TResult Function(List<RustAudioSource> field0) queue,
    required TResult Function(int field0) currentIndex,
    required TResult Function(bool field0) isCrossfading,
    required TResult Function(RustCrossfadeConfig field0) crossfadeConfig,
    required TResult Function(RustVisualizerData field0) visualizer,
    required TResult Function(bool field0) visualizerEnabled,
    required TResult Function(double field0) volume,
    required TResult Function(double field0) rate,
    required TResult Function(double field0) pitch,
    required TResult Function(double field0) balance,
    required TResult Function(bool field0) mono,
    required TResult Function(int field0) bitrate,
    required TResult Function(int field0) bufferSize,
    required TResult Function(RustSilenceConfig field0) silenceConfig,
    required TResult Function(PlatformInt64 field0) silenceSaved,
    required TResult Function(RustEqualizerParams field0) equalizer,
    required TResult Function(double field0) preamp,
    required TResult Function(RustReplayGainConfig field0) replayGain,
    required TResult Function(int field0) crossfeed,
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
    required TResult Function(Uint8List field0) metaBytes,
    required TResult Function(bool field0) metaBytesEnabled,
    required TResult Function(double field0) cueVolume,
    required TResult Function(int field0) cueSource,
    required TResult Function(int field0) loopMode,
    required TResult Function(bool field0) isShuffled,
    required TResult Function(bool field0) pauseOnDeviceChange,
    required TResult Function(bool field0) microphoneEnabled,
    required TResult Function(double field0) micVolume,
    required TResult Function(bool field0) directMonitoringEnabled,
    required TResult Function(List<RustAudioDevice> field0) outputDevices,
    required TResult Function(List<RustAudioDevice> field0) inputDevices,
    required TResult Function(RustDartReadRequest field0) dartReadRequest,
    required TResult Function(RustAudioDevice field0) device,
    required TResult Function(String message, int code) error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_PlaybackState():
        return playbackState(_that.field0);
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
      case RustPlayerEvent_Buffer():
        return buffer(_that.field0);
      case RustPlayerEvent_Queue():
        return queue(_that.field0);
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
      case RustPlayerEvent_Bitrate():
        return bitrate(_that.field0);
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
      case RustPlayerEvent_MetaBytes():
        return metaBytes(_that.field0);
      case RustPlayerEvent_MetaBytesEnabled():
        return metaBytesEnabled(_that.field0);
      case RustPlayerEvent_CueVolume():
        return cueVolume(_that.field0);
      case RustPlayerEvent_CueSource():
        return cueSource(_that.field0);
      case RustPlayerEvent_LoopMode():
        return loopMode(_that.field0);
      case RustPlayerEvent_IsShuffled():
        return isShuffled(_that.field0);
      case RustPlayerEvent_PauseOnDeviceChange():
        return pauseOnDeviceChange(_that.field0);
      case RustPlayerEvent_MicrophoneEnabled():
        return microphoneEnabled(_that.field0);
      case RustPlayerEvent_MicVolume():
        return micVolume(_that.field0);
      case RustPlayerEvent_DirectMonitoringEnabled():
        return directMonitoringEnabled(_that.field0);
      case RustPlayerEvent_OutputDevices():
        return outputDevices(_that.field0);
      case RustPlayerEvent_InputDevices():
        return inputDevices(_that.field0);
      case RustPlayerEvent_DartReadRequest():
        return dartReadRequest(_that.field0);
      case RustPlayerEvent_Device():
        return device(_that.field0);
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
    TResult? Function(int field0)? playbackState,
    TResult? Function(int field0)? state,
    TResult? Function(PlatformInt64 field0)? position,
    TResult? Function(PlatformInt64 field0)? duration,
    TResult? Function(bool field0)? isPlaying,
    TResult? Function(bool field0)? isBuffering,
    TResult? Function(bool field0)? isCompleted,
    TResult? Function(RustBuffer field0)? buffer,
    TResult? Function(List<RustAudioSource> field0)? queue,
    TResult? Function(int field0)? currentIndex,
    TResult? Function(bool field0)? isCrossfading,
    TResult? Function(RustCrossfadeConfig field0)? crossfadeConfig,
    TResult? Function(RustVisualizerData field0)? visualizer,
    TResult? Function(bool field0)? visualizerEnabled,
    TResult? Function(double field0)? volume,
    TResult? Function(double field0)? rate,
    TResult? Function(double field0)? pitch,
    TResult? Function(double field0)? balance,
    TResult? Function(bool field0)? mono,
    TResult? Function(int field0)? bitrate,
    TResult? Function(int field0)? bufferSize,
    TResult? Function(RustSilenceConfig field0)? silenceConfig,
    TResult? Function(PlatformInt64 field0)? silenceSaved,
    TResult? Function(RustEqualizerParams field0)? equalizer,
    TResult? Function(double field0)? preamp,
    TResult? Function(RustReplayGainConfig field0)? replayGain,
    TResult? Function(int field0)? crossfeed,
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
    TResult? Function(Uint8List field0)? metaBytes,
    TResult? Function(bool field0)? metaBytesEnabled,
    TResult? Function(double field0)? cueVolume,
    TResult? Function(int field0)? cueSource,
    TResult? Function(int field0)? loopMode,
    TResult? Function(bool field0)? isShuffled,
    TResult? Function(bool field0)? pauseOnDeviceChange,
    TResult? Function(bool field0)? microphoneEnabled,
    TResult? Function(double field0)? micVolume,
    TResult? Function(bool field0)? directMonitoringEnabled,
    TResult? Function(List<RustAudioDevice> field0)? outputDevices,
    TResult? Function(List<RustAudioDevice> field0)? inputDevices,
    TResult? Function(RustDartReadRequest field0)? dartReadRequest,
    TResult? Function(RustAudioDevice field0)? device,
    TResult? Function(String message, int code)? error,
  }) {
    final _that = this;
    switch (_that) {
      case RustPlayerEvent_PlaybackState() when playbackState != null:
        return playbackState(_that.field0);
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
      case RustPlayerEvent_Buffer() when buffer != null:
        return buffer(_that.field0);
      case RustPlayerEvent_Queue() when queue != null:
        return queue(_that.field0);
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
      case RustPlayerEvent_Bitrate() when bitrate != null:
        return bitrate(_that.field0);
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
      case RustPlayerEvent_MetaBytes() when metaBytes != null:
        return metaBytes(_that.field0);
      case RustPlayerEvent_MetaBytesEnabled() when metaBytesEnabled != null:
        return metaBytesEnabled(_that.field0);
      case RustPlayerEvent_CueVolume() when cueVolume != null:
        return cueVolume(_that.field0);
      case RustPlayerEvent_CueSource() when cueSource != null:
        return cueSource(_that.field0);
      case RustPlayerEvent_LoopMode() when loopMode != null:
        return loopMode(_that.field0);
      case RustPlayerEvent_IsShuffled() when isShuffled != null:
        return isShuffled(_that.field0);
      case RustPlayerEvent_PauseOnDeviceChange()
          when pauseOnDeviceChange != null:
        return pauseOnDeviceChange(_that.field0);
      case RustPlayerEvent_MicrophoneEnabled() when microphoneEnabled != null:
        return microphoneEnabled(_that.field0);
      case RustPlayerEvent_MicVolume() when micVolume != null:
        return micVolume(_that.field0);
      case RustPlayerEvent_DirectMonitoringEnabled()
          when directMonitoringEnabled != null:
        return directMonitoringEnabled(_that.field0);
      case RustPlayerEvent_OutputDevices() when outputDevices != null:
        return outputDevices(_that.field0);
      case RustPlayerEvent_InputDevices() when inputDevices != null:
        return inputDevices(_that.field0);
      case RustPlayerEvent_DartReadRequest() when dartReadRequest != null:
        return dartReadRequest(_that.field0);
      case RustPlayerEvent_Device() when device != null:
        return device(_that.field0);
      case RustPlayerEvent_Error() when error != null:
        return error(_that.message, _that.code);
      case _:
        return null;
    }
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
  const RustPlayerEvent_Queue(List<RustAudioSource> field0)
      : _field0 = field0,
        super._();

  final List<RustAudioSource> _field0;
  List<RustAudioSource> get field0 {
    if (_field0 is EqualUnmodifiableListView) return _field0;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_field0);
  }

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
            const DeepCollectionEquality().equals(other.field0, _field0));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(_field0));
  }

  @override
  String toString() {
    return 'RustPlayerEvent.queue(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_QueueCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_QueueCopyWith(RustPlayerEvent_Queue value,
          $Res Function(RustPlayerEvent_Queue) _then) =
      _$RustPlayerEvent_QueueCopyWithImpl;
  @useResult
  $Res call({List<RustAudioSource> field0});
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
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_Queue(
      null == field0
          ? _self._field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as List<RustAudioSource>,
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

  final List<String> _ids;
  List<String> get ids {
    if (_ids is EqualUnmodifiableListView) return _ids;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_ids);
  }

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

class RustPlayerEvent_MetaBytes extends RustPlayerEvent {
  const RustPlayerEvent_MetaBytes(this.field0) : super._();

  final Uint8List field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_MetaBytesCopyWith<RustPlayerEvent_MetaBytes> get copyWith =>
      _$RustPlayerEvent_MetaBytesCopyWithImpl<RustPlayerEvent_MetaBytes>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_MetaBytes &&
            const DeepCollectionEquality().equals(other.field0, field0));
  }

  @override
  int get hashCode {
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(field0));
  }

  @override
  String toString() {
    return 'RustPlayerEvent.metaBytes(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_MetaBytesCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_MetaBytesCopyWith(RustPlayerEvent_MetaBytes value,
          $Res Function(RustPlayerEvent_MetaBytes) _then) =
      _$RustPlayerEvent_MetaBytesCopyWithImpl;
  @useResult
  $Res call({Uint8List field0});
}

/// @nodoc
class _$RustPlayerEvent_MetaBytesCopyWithImpl<$Res>
    implements $RustPlayerEvent_MetaBytesCopyWith<$Res> {
  _$RustPlayerEvent_MetaBytesCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_MetaBytes _self;
  final $Res Function(RustPlayerEvent_MetaBytes) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_MetaBytes(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as Uint8List,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_MetaBytesEnabled extends RustPlayerEvent {
  const RustPlayerEvent_MetaBytesEnabled(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_MetaBytesEnabledCopyWith<RustPlayerEvent_MetaBytesEnabled>
      get copyWith => _$RustPlayerEvent_MetaBytesEnabledCopyWithImpl<
          RustPlayerEvent_MetaBytesEnabled>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_MetaBytesEnabled &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.metaBytesEnabled(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_MetaBytesEnabledCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_MetaBytesEnabledCopyWith(
          RustPlayerEvent_MetaBytesEnabled value,
          $Res Function(RustPlayerEvent_MetaBytesEnabled) _then) =
      _$RustPlayerEvent_MetaBytesEnabledCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_MetaBytesEnabledCopyWithImpl<$Res>
    implements $RustPlayerEvent_MetaBytesEnabledCopyWith<$Res> {
  _$RustPlayerEvent_MetaBytesEnabledCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_MetaBytesEnabled _self;
  final $Res Function(RustPlayerEvent_MetaBytesEnabled) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_MetaBytesEnabled(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_CueVolume extends RustPlayerEvent {
  const RustPlayerEvent_CueVolume(this.field0) : super._();

  final double field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_CueVolumeCopyWith<RustPlayerEvent_CueVolume> get copyWith =>
      _$RustPlayerEvent_CueVolumeCopyWithImpl<RustPlayerEvent_CueVolume>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_CueVolume &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.cueVolume(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_CueVolumeCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_CueVolumeCopyWith(RustPlayerEvent_CueVolume value,
          $Res Function(RustPlayerEvent_CueVolume) _then) =
      _$RustPlayerEvent_CueVolumeCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustPlayerEvent_CueVolumeCopyWithImpl<$Res>
    implements $RustPlayerEvent_CueVolumeCopyWith<$Res> {
  _$RustPlayerEvent_CueVolumeCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_CueVolume _self;
  final $Res Function(RustPlayerEvent_CueVolume) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_CueVolume(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_CueSource extends RustPlayerEvent {
  const RustPlayerEvent_CueSource(this.field0) : super._();

  final int field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_CueSourceCopyWith<RustPlayerEvent_CueSource> get copyWith =>
      _$RustPlayerEvent_CueSourceCopyWithImpl<RustPlayerEvent_CueSource>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_CueSource &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.cueSource(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_CueSourceCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_CueSourceCopyWith(RustPlayerEvent_CueSource value,
          $Res Function(RustPlayerEvent_CueSource) _then) =
      _$RustPlayerEvent_CueSourceCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$RustPlayerEvent_CueSourceCopyWithImpl<$Res>
    implements $RustPlayerEvent_CueSourceCopyWith<$Res> {
  _$RustPlayerEvent_CueSourceCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_CueSource _self;
  final $Res Function(RustPlayerEvent_CueSource) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_CueSource(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
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

class RustPlayerEvent_MicrophoneEnabled extends RustPlayerEvent {
  const RustPlayerEvent_MicrophoneEnabled(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_MicrophoneEnabledCopyWith<RustPlayerEvent_MicrophoneEnabled>
      get copyWith => _$RustPlayerEvent_MicrophoneEnabledCopyWithImpl<
          RustPlayerEvent_MicrophoneEnabled>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_MicrophoneEnabled &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.microphoneEnabled(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_MicrophoneEnabledCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_MicrophoneEnabledCopyWith(
          RustPlayerEvent_MicrophoneEnabled value,
          $Res Function(RustPlayerEvent_MicrophoneEnabled) _then) =
      _$RustPlayerEvent_MicrophoneEnabledCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_MicrophoneEnabledCopyWithImpl<$Res>
    implements $RustPlayerEvent_MicrophoneEnabledCopyWith<$Res> {
  _$RustPlayerEvent_MicrophoneEnabledCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_MicrophoneEnabled _self;
  final $Res Function(RustPlayerEvent_MicrophoneEnabled) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_MicrophoneEnabled(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_MicVolume extends RustPlayerEvent {
  const RustPlayerEvent_MicVolume(this.field0) : super._();

  final double field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_MicVolumeCopyWith<RustPlayerEvent_MicVolume> get copyWith =>
      _$RustPlayerEvent_MicVolumeCopyWithImpl<RustPlayerEvent_MicVolume>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_MicVolume &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.micVolume(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_MicVolumeCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_MicVolumeCopyWith(RustPlayerEvent_MicVolume value,
          $Res Function(RustPlayerEvent_MicVolume) _then) =
      _$RustPlayerEvent_MicVolumeCopyWithImpl;
  @useResult
  $Res call({double field0});
}

/// @nodoc
class _$RustPlayerEvent_MicVolumeCopyWithImpl<$Res>
    implements $RustPlayerEvent_MicVolumeCopyWith<$Res> {
  _$RustPlayerEvent_MicVolumeCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_MicVolume _self;
  final $Res Function(RustPlayerEvent_MicVolume) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_MicVolume(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as double,
    ));
  }
}

/// @nodoc

class RustPlayerEvent_DirectMonitoringEnabled extends RustPlayerEvent {
  const RustPlayerEvent_DirectMonitoringEnabled(this.field0) : super._();

  final bool field0;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RustPlayerEvent_DirectMonitoringEnabledCopyWith<
          RustPlayerEvent_DirectMonitoringEnabled>
      get copyWith => _$RustPlayerEvent_DirectMonitoringEnabledCopyWithImpl<
          RustPlayerEvent_DirectMonitoringEnabled>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RustPlayerEvent_DirectMonitoringEnabled &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, field0);
  }

  @override
  String toString() {
    return 'RustPlayerEvent.directMonitoringEnabled(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $RustPlayerEvent_DirectMonitoringEnabledCopyWith<$Res>
    implements $RustPlayerEventCopyWith<$Res> {
  factory $RustPlayerEvent_DirectMonitoringEnabledCopyWith(
          RustPlayerEvent_DirectMonitoringEnabled value,
          $Res Function(RustPlayerEvent_DirectMonitoringEnabled) _then) =
      _$RustPlayerEvent_DirectMonitoringEnabledCopyWithImpl;
  @useResult
  $Res call({bool field0});
}

/// @nodoc
class _$RustPlayerEvent_DirectMonitoringEnabledCopyWithImpl<$Res>
    implements $RustPlayerEvent_DirectMonitoringEnabledCopyWith<$Res> {
  _$RustPlayerEvent_DirectMonitoringEnabledCopyWithImpl(this._self, this._then);

  final RustPlayerEvent_DirectMonitoringEnabled _self;
  final $Res Function(RustPlayerEvent_DirectMonitoringEnabled) _then;

  /// Create a copy of RustPlayerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(RustPlayerEvent_DirectMonitoringEnabled(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as bool,
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
