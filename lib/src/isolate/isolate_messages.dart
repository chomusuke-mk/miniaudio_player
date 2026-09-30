/// IPC message protocol between UI Isolate and secondary Audio Worker Isolate.
library;

import '../api/audio_device.dart';

/// Base sealed class for all commands sent from UI isolate to Audio Worker isolate.
sealed class PlayerCommand {
  final int requestId;
  const PlayerCommand(this.requestId);
}

class OpenCommand extends PlayerCommand {
  final String filePath;
  final bool autoPlay;
  const OpenCommand(super.requestId, this.filePath, {this.autoPlay = false});
}

class PlayCommand extends PlayerCommand {
  const PlayCommand(super.requestId);
}

class PauseCommand extends PlayerCommand {
  const PauseCommand(super.requestId);
}

class StopCommand extends PlayerCommand {
  const StopCommand(super.requestId);
}

class SeekCommand extends PlayerCommand {
  final Duration position;
  const SeekCommand(super.requestId, this.position);
}

class SetVolumeCommand extends PlayerCommand {
  final double volume;
  const SetVolumeCommand(super.requestId, this.volume);
}

class SetRateCommand extends PlayerCommand {
  final double rate;
  const SetRateCommand(super.requestId, this.rate);
}

class SetPitchCommand extends PlayerCommand {
  final double pitch;
  const SetPitchCommand(super.requestId, this.pitch);
}

class SetBufferSizeCommand extends PlayerCommand {
  final int bufferSize;
  const SetBufferSizeCommand(super.requestId, this.bufferSize);
}

class SetEqualizerCommand extends PlayerCommand {
  final List<double> gainsDb;
  const SetEqualizerCommand(super.requestId, this.gainsDb);
}

class SetDeviceCommand extends PlayerCommand {
  final AudioDevice device;
  const SetDeviceCommand(super.requestId, this.device);
}

class GetStatusCommand extends PlayerCommand {
  const GetStatusCommand(super.requestId);
}

class DisposeCommand extends PlayerCommand {
  const DisposeCommand(super.requestId);
}

/// Base sealed class for all responses sent from Audio Worker isolate to UI isolate in response to a command.
sealed class PlayerResponse {
  final int requestId;
  const PlayerResponse(this.requestId);
}

class CommandSuccessResponse extends PlayerResponse {
  final dynamic data;
  const CommandSuccessResponse(super.requestId, {this.data});
}

class CommandErrorResponse extends PlayerResponse {
  final String message;
  final int? errorCode;
  final String? details;
  const CommandErrorResponse(
    super.requestId,
    this.message, {
    this.errorCode,
    this.details,
  });
}

class MediaInfoResponse extends PlayerResponse {
  final Duration duration;
  const MediaInfoResponse(super.requestId, this.duration);
}

/// Base sealed class for asynchronous unsolicited events emitted from Audio Worker isolate.
sealed class PlayerEvent {
  const PlayerEvent();
}

class PlaybackStatusEvent extends PlayerEvent {
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool isBuffering;
  final bool isCompleted;
  final int state;
  final int bitrate;

  const PlaybackStatusEvent({
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.isBuffering,
    required this.isCompleted,
    required this.state,
    this.bitrate = 0,
  });
}

class VolumeChangedEvent extends PlayerEvent {
  final double volume;
  const VolumeChangedEvent(this.volume);
}

class RateChangedEvent extends PlayerEvent {
  final double rate;
  const RateChangedEvent(this.rate);
}

class PitchChangedEvent extends PlayerEvent {
  final double pitch;
  const PitchChangedEvent(this.pitch);
}

class BufferSizeChangedEvent extends PlayerEvent {
  final int bufferSize;
  const BufferSizeChangedEvent(this.bufferSize);
}

class EqualizerChangedEvent extends PlayerEvent {
  final List<double> gainsDb;
  const EqualizerChangedEvent(this.gainsDb);
}

class AudioDeviceChangedEvent extends PlayerEvent {
  final AudioDevice device;
  const AudioDeviceChangedEvent(this.device);
}

class PlaybackErrorEvent extends PlayerEvent {
  final String message;
  final int? errorCode;
  final String? details;

  const PlaybackErrorEvent(this.message, {this.errorCode, this.details});
}
