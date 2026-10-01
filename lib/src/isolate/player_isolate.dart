import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../api/audio_device.dart';
import '../ffi/native_types.dart';
import 'isolate_messages.dart';
import 'throttled_emitter.dart';

/// Entry point for the dedicated secondary Dart Isolate.
@pragma('vm:entry-point')
void playerIsolateEntryPoint(dynamic message) {
  SendPort mainSendPort;
  int initialBufferSize = 0;
  int initialLogLevel = 0;
  String? initialDeviceId;

  if (message is SendPort) {
    mainSendPort = message;
  } else if (message is List && message.isNotEmpty) {
    mainSendPort = message[0] as SendPort;
    if (message.length > 1 && message[1] is int) {
      initialBufferSize = message[1] as int;
    }
    if (message.length > 2 && message[2] is int) {
      initialLogLevel = message[2] as int;
    }
    if (message.length > 3 && message[3] is String) {
      initialDeviceId = message[3] as String;
    }
  } else {
    throw ArgumentError('Invalid player isolate entry point message: $message');
  }

  final worker = PlayerIsolateWorker(
    mainSendPort: mainSendPort,
    initialBufferSize: initialBufferSize,
    initialLogLevel: initialLogLevel,
    initialDeviceId: initialDeviceId,
  );
  worker.start();
}

/// Worker engine running inside the dedicated secondary Dart Isolate.
class PlayerIsolateWorker {
  final SendPort mainSendPort;
  final int initialBufferSize;
  final int initialLogLevel;
  final String? initialDeviceId;

  late final ReceivePort _workerReceivePort;

  Pointer<native.miniaudio_player_t> _playerHandle = nullptr;
  ThrottledEmitter? _emitter;
  bool _isDisposed = false;

  PlayerIsolateWorker({
    required this.mainSendPort,
    this.initialBufferSize = 0,
    this.initialLogLevel = 0,
    this.initialDeviceId,
  });

  String? _initError;

  void start() {
    _workerReceivePort = ReceivePort();
    _workerReceivePort.listen(_handleIncomingMessage);

    // Handshake: send worker SendPort to UI isolate
    mainSendPort.send(_workerReceivePort.sendPort);

    try {
      if (initialLogLevel > 0) {
        native.miniaudio_player_set_log_level(initialLogLevel);
      }

      final outResult = calloc<Int32>();
      try {
        Pointer<Utf8>? devIdPtr;
        if (initialDeviceId != null &&
            initialDeviceId!.isNotEmpty &&
            initialDeviceId != 'auto') {
          devIdPtr = initialDeviceId!.toNativeUtf8();
        }
        final configPtr = native.miniaudio_player_config_t.$allocate(
          calloc,
          sample_rate: 0,
          channels: 0,
          period_size_in_frames: initialBufferSize > 0 ? initialBufferSize : 0,
          playback_device_id: devIdPtr != null ? devIdPtr.cast() : nullptr,
          on_completed: nullptr,
          user_data: nullptr,
        );
        try {
          _playerHandle = native.miniaudio_player_create(configPtr, outResult);
        } finally {
          if (devIdPtr != null) calloc.free(devIdPtr);
          calloc.free(configPtr);
        }
        final result = outResult.value;
        if (_playerHandle == nullptr || result != MapResult.success) {
          _initError = 'Failed to create native audio engine: code $result';
          mainSendPort.send(PlaybackErrorEvent(_initError!, errorCode: result));
          return;
        }

        final devPtr = calloc<native.miniaudio_device_info_t>();
        try {
          if (native.miniaudio_player_get_current_device(
                _playerHandle,
                devPtr,
              ) ==
              MapResult.success) {
            final activeDev = devPtr.ref.toAudioDevice();
            mainSendPort.send(AudioDeviceChangedEvent(activeDev));
          }
        } finally {
          calloc.free(devPtr);
        }
      } finally {
        calloc.free(outResult);
      }

      _emitter = ThrottledEmitter(
        playerHandle: _playerHandle,
        sendPort: mainSendPort,
        interval: const Duration(milliseconds: 50),
      );
    } catch (e, st) {
      _initError = 'Isolate worker startup failed: $e';
      mainSendPort.send(
        PlaybackErrorEvent(_initError!, details: st.toString()),
      );
    }
  }

  void _handleIncomingMessage(dynamic message) {
    if (_isDisposed) {
      if (message is PlayerCommand) {
        mainSendPort.send(
          CommandErrorResponse(
            message.requestId,
            'Player isolate already disposed',
            errorCode: MapResult.errorInvalidState,
          ),
        );
      }
      return;
    }

    if (_playerHandle == nullptr) {
      if (message is DisposeCommand) {
        _handleDispose(message);
        return;
      }
      if (message is PlayerCommand) {
        mainSendPort.send(
          CommandErrorResponse(
            message.requestId,
            _initError ?? 'Native audio engine is not available',
            errorCode: MapResult.errorEngineInit,
          ),
        );
      }
      return;
    }

    if (message is PlayerCommand) {
      switch (message) {
        case OpenCommand():
          _handleOpen(message);
        case PlayCommand():
          _handlePlay(message);
        case PauseCommand():
          _handlePause(message);
        case StopCommand():
          _handleStop(message);
        case SeekCommand():
          _handleSeek(message);
        case SetVolumeCommand():
          _handleSetVolume(message);
        case SetRateCommand():
          _handleSetRate(message);
        case SetPitchCommand():
          _handleSetPitch(message);
        case SetBufferSizeCommand():
          _handleSetBufferSize(message);
        case SetEqualizerCommand():
          _handleSetEqualizer(message);
        case SetDeviceCommand():
          _handleSetDevice(message);
        case GetStatusCommand():
          _handleGetStatus(message);
        case DisposeCommand():
          _handleDispose(message);
      }
    }
  }

  void _handleOpen(OpenCommand cmd) {
    final pathPtr = cmd.filePath.toNativeUtf8();
    try {
      final res = native.miniaudio_player_open_file(
        _playerHandle,
        pathPtr.cast(),
      );
      if (res != MapResult.success) {
        mainSendPort.send(
          CommandErrorResponse(
            cmd.requestId,
            'Failed to open audio file: ${MapResult.describe(res)}',
            errorCode: res,
          ),
        );
        return;
      }

      final durationMs = native.miniaudio_player_get_duration_ms(_playerHandle);
      final duration = Duration(milliseconds: durationMs);

      if (cmd.autoPlay) {
        final playRes = native.miniaudio_player_play(_playerHandle);
        if (playRes == MapResult.success) {
          _emitter?.start();
        }
      }

      _emitter?.pollAndEmit(force: true);

      mainSendPort.send(CommandSuccessResponse(cmd.requestId, data: duration));
    } finally {
      calloc.free(pathPtr);
    }
  }

  void _handlePlay(PlayCommand cmd) {
    final res = native.miniaudio_player_play(_playerHandle);
    if (res != MapResult.success) {
      mainSendPort.send(
        CommandErrorResponse(
          cmd.requestId,
          'Failed to start playback: ${MapResult.describe(res)}',
          errorCode: res,
        ),
      );
      return;
    }

    _emitter?.start();
    _emitter?.pollAndEmit(force: true);
    mainSendPort.send(CommandSuccessResponse(cmd.requestId));
  }

  void _handlePause(PauseCommand cmd) {
    final res = native.miniaudio_player_pause(_playerHandle);
    if (res != MapResult.success) {
      mainSendPort.send(
        CommandErrorResponse(
          cmd.requestId,
          'Failed to pause playback: ${MapResult.describe(res)}',
          errorCode: res,
        ),
      );
      return;
    }

    _emitter?.stop();
    _emitter?.pollAndEmit(force: true);
    mainSendPort.send(CommandSuccessResponse(cmd.requestId));
  }

  void _handleStop(StopCommand cmd) {
    final res = native.miniaudio_player_stop(_playerHandle);
    if (res != MapResult.success) {
      mainSendPort.send(
        CommandErrorResponse(
          cmd.requestId,
          'Failed to stop playback: ${MapResult.describe(res)}',
          errorCode: res,
        ),
      );
      return;
    }

    _emitter?.stop();
    _emitter?.pollAndEmit(force: true);
    mainSendPort.send(CommandSuccessResponse(cmd.requestId));
  }

  void _handleSeek(SeekCommand cmd) {
    final durationMs = native.miniaudio_player_get_duration_ms(_playerHandle);
    var targetMs = cmd.position.inMilliseconds;
    if (targetMs < 0) targetMs = 0;
    if (durationMs > 0 && targetMs > durationMs) {
      targetMs = durationMs;
    }

    final res = native.miniaudio_player_seek(_playerHandle, targetMs);
    if (res != MapResult.success) {
      mainSendPort.send(
        CommandErrorResponse(
          cmd.requestId,
          'Failed to seek: ${MapResult.describe(res)}',
          errorCode: res,
        ),
      );
      return;
    }

    _emitter?.pollAndEmit(force: true);
    mainSendPort.send(CommandSuccessResponse(cmd.requestId));
  }

  void _handleSetVolume(SetVolumeCommand cmd) {
    final res = native.miniaudio_player_set_volume(_playerHandle, cmd.volume);
    if (res != MapResult.success) {
      mainSendPort.send(
        CommandErrorResponse(
          cmd.requestId,
          'Failed to set volume: ${MapResult.describe(res)}',
          errorCode: res,
        ),
      );
      return;
    }

    mainSendPort.send(VolumeChangedEvent(cmd.volume));
    mainSendPort.send(CommandSuccessResponse(cmd.requestId));
  }

  void _handleSetRate(SetRateCommand cmd) {
    final res = native.miniaudio_player_set_rate(_playerHandle, cmd.rate);
    if (res != MapResult.success) {
      mainSendPort.send(
        CommandErrorResponse(
          cmd.requestId,
          'Failed to set rate: ${MapResult.describe(res)}',
          errorCode: res,
        ),
      );
      return;
    }

    mainSendPort.send(RateChangedEvent(cmd.rate));
    mainSendPort.send(CommandSuccessResponse(cmd.requestId));
  }

  void _handleSetPitch(SetPitchCommand cmd) {
    final res = native.miniaudio_player_set_pitch(_playerHandle, cmd.pitch);
    if (res != MapResult.success) {
      mainSendPort.send(
        CommandErrorResponse(
          cmd.requestId,
          'Failed to set pitch: ${MapResult.describe(res)}',
          errorCode: res,
        ),
      );
      return;
    }

    mainSendPort.send(PitchChangedEvent(cmd.pitch));
    mainSendPort.send(CommandSuccessResponse(cmd.requestId));
  }

  void _handleSetBufferSize(SetBufferSizeCommand cmd) {
    final res = native.miniaudio_player_set_buffer_size(
      _playerHandle,
      cmd.bufferSize,
    );
    if (res != MapResult.success) {
      mainSendPort.send(
        CommandErrorResponse(
          cmd.requestId,
          'Failed to set buffer size: ${MapResult.describe(res)}',
          errorCode: res,
        ),
      );
      return;
    }

    mainSendPort.send(BufferSizeChangedEvent(cmd.bufferSize));
    mainSendPort.send(CommandSuccessResponse(cmd.requestId));
  }

  void _handleSetEqualizer(SetEqualizerCommand cmd) {
    final g = cmd.gainsDb;
    final eqPtr = native.miniaudio_player_equalizer_params_t.$allocate(
      calloc,
      hz60: g[0],
      hz170: g[1],
      hz310: g[2],
      hz600: g[3],
      hz1k: g[4],
      hz3k: g[5],
      hz6k: g[6],
      hz12k: g[7],
      hz14k: g[8],
      hz16k: g[9],
    );
    try {
      final res = native.miniaudio_player_set_equalizer(_playerHandle, eqPtr);
      if (res != MapResult.success) {
        mainSendPort.send(
          CommandErrorResponse(
            cmd.requestId,
            'Failed to set equalizer: ${MapResult.describe(res)}',
            errorCode: res,
          ),
        );
        return;
      }

      mainSendPort.send(EqualizerChangedEvent(cmd.gainsDb));
      mainSendPort.send(CommandSuccessResponse(cmd.requestId));
    } finally {
      calloc.free(eqPtr);
    }
  }

  void _handleSetDevice(SetDeviceCommand cmd) {
    final isAutoTarget = cmd.device.isAuto ||
        cmd.device.id.isEmpty ||
        cmd.device.id == 'auto' ||
        cmd.device.id == 'default' ||
        cmd.device.id == '0';
    Pointer<Utf8>? devIdPtr;
    if (!isAutoTarget) {
      devIdPtr = cmd.device.id.toNativeUtf8();
    }
    try {
      final res = native.miniaudio_player_set_device(
        _playerHandle,
        devIdPtr != null ? devIdPtr.cast() : nullptr,
      );
      final devPtr = calloc<native.miniaudio_device_info_t>();
      bool success = res == MapResult.success;
      try {
        if (native.miniaudio_player_get_current_device(_playerHandle, devPtr) ==
            MapResult.success) {
          final activeDev = devPtr.ref.toAudioDevice();
          var eventDev = activeDev;
          if (!isAutoTarget &&
              activeDev.id == cmd.device.id &&
              cmd.device.name.isNotEmpty) {
            eventDev = AudioDevice(
              id: activeDev.id,
              name: cmd.device.name,
              isDefault: cmd.device.isDefault,
              isAuto: false,
              type: cmd.device.type,
            );
          }
          mainSendPort.send(AudioDeviceChangedEvent(eventDev));
          if (isAutoTarget) {
            success = activeDev.isAuto;
          } else {
            success = !activeDev.isAuto && activeDev.id == cmd.device.id;
          }
        } else if (!success) {
          mainSendPort.send(
            CommandErrorResponse(
              cmd.requestId,
              'Failed to set audio device: ${MapResult.describe(res)}',
              errorCode: res,
            ),
          );
          return;
        }
      } finally {
        calloc.free(devPtr);
      }
      mainSendPort.send(CommandSuccessResponse(cmd.requestId, data: success));
    } finally {
      if (devIdPtr != null) calloc.free(devIdPtr);
    }
  }

  void _handleGetStatus(GetStatusCommand cmd) {
    _emitter?.pollAndEmit(force: true);
    mainSendPort.send(CommandSuccessResponse(cmd.requestId));
  }

  void _handleDispose(DisposeCommand cmd) {
    if (_isDisposed) {
      mainSendPort.send(CommandSuccessResponse(cmd.requestId));
      return;
    }

    _isDisposed = true;
    _emitter?.dispose();
    _emitter = null;

    if (_playerHandle != nullptr) {
      native.miniaudio_player_destroy(_playerHandle);
      _playerHandle = nullptr;
    }

    mainSendPort.send(CommandSuccessResponse(cmd.requestId));
    _workerReceivePort.close();
  }
}
