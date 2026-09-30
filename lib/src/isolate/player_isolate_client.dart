import 'dart:async';
import 'dart:isolate';

import '../api/audio_device.dart';
import 'isolate_messages.dart';
import 'player_isolate.dart';

/// Exception thrown by [MiniaudioPlayer] on native or isolate errors.
class MiniaudioPlayerException implements Exception {
  final String message;
  final int? errorCode;
  final String? details;

  const MiniaudioPlayerException(this.message, {this.errorCode, this.details});

  @override
  String toString() {
    if (errorCode != null) {
      return 'MiniaudioPlayerException(code: $errorCode): $message';
    }
    return 'MiniaudioPlayerException: $message';
  }
}

/// Client running in the UI Isolate that coordinates with the secondary Audio Worker Isolate.
class PlayerIsolateClient {
  final int initialBufferSize;
  final int initialLogLevel;
  final String? initialDeviceId;
  final void Function(PlaybackStatusEvent event) onStatus;
  final void Function(double volume) onVolume;
  final void Function(double rate) onRate;
  final void Function(double pitch) onPitch;
  final void Function(int bufferSize)? onBufferSize;
  final void Function(List<double> gainsDb) onEqualizer;
  final void Function(AudioDevice device)? onDevice;
  final void Function(String message, int? errorCode, String? details) onError;

  ReceivePort? _mainReceivePort;
  Isolate? _isolate;
  SendPort? _workerSendPort;

  final Completer<void> _initCompleter = Completer<void>();
  final Map<int, Completer<dynamic>> _pendingRequests = {};
  int _nextRequestId = 1;
  bool _isDisposed = false;

  PlayerIsolateClient({
    this.initialBufferSize = 0,
    this.initialLogLevel = 0,
    this.initialDeviceId,
    required this.onStatus,
    required this.onVolume,
    required this.onRate,
    required this.onPitch,
    this.onBufferSize,
    required this.onEqualizer,
    this.onDevice,
    required this.onError,
  });

  bool get isDisposed => _isDisposed;

  /// Initializes and spawns the secondary worker Isolate.
  Future<void> initialize() async {
    if (_isDisposed) throw StateError('Player is already disposed');
    if (_isolate != null) return _initCompleter.future;

    final receivePort = ReceivePort();
    _mainReceivePort = receivePort;
    receivePort.listen(_handleMessage);

    _isolate = await Isolate.spawn(playerIsolateEntryPoint, [
      receivePort.sendPort,
      initialBufferSize,
      initialLogLevel,
      initialDeviceId,
    ], debugName: 'MiniaudioPlayerWorker');

    return _initCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        throw const MiniaudioPlayerException(
          'Player isolate initialization timed out',
        );
      },
    );
  }

  void _handleMessage(dynamic message) {
    if (_workerSendPort == null && message is SendPort) {
      _workerSendPort = message;
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
      return;
    }

    if (message is PlayerResponse) {
      final completer = _pendingRequests.remove(message.requestId);
      if (completer != null && !completer.isCompleted) {
        switch (message) {
          case CommandSuccessResponse():
            completer.complete(message.data);
          case CommandErrorResponse():
            completer.completeError(
              MiniaudioPlayerException(
                message.message,
                errorCode: message.errorCode,
                details: message.details,
              ),
            );
          case MediaInfoResponse():
            completer.complete(message.duration);
        }
      }
      return;
    }

    if (message is PlayerEvent) {
      switch (message) {
        case PlaybackStatusEvent():
          onStatus(message);
        case VolumeChangedEvent():
          onVolume(message.volume);
        case RateChangedEvent():
          onRate(message.rate);
        case PitchChangedEvent():
          onPitch(message.pitch);
        case BufferSizeChangedEvent():
          onBufferSize?.call(message.bufferSize);
        case EqualizerChangedEvent():
          onEqualizer(message.gainsDb);
        case AudioDeviceChangedEvent():
          onDevice?.call(message.device);
        case PlaybackErrorEvent():
          onError(message.message, message.errorCode, message.details);
      }
    }
  }

  /// Sends a typed command to the worker isolate and awaits its response.
  Future<T> sendCommand<T>(
    PlayerCommand Function(int requestId) createCommand,
  ) async {
    if (_isDisposed) {
      throw StateError('Cannot send command on disposed player');
    }

    await initialize();

    final id = _nextRequestId++;
    final completer = Completer<T>();
    _pendingRequests[id] = completer;

    final command = createCommand(id);
    _workerSendPort!.send(command);

    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pendingRequests.remove(id);
        throw const MiniaudioPlayerException('Command timed out');
      },
    );
  }

  /// Disposes the client, worker isolate, and native allocations.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    try {
      if (_workerSendPort != null) {
        final id = _nextRequestId++;
        final completer = Completer<void>();
        _pendingRequests[id] = completer;
        _workerSendPort!.send(DisposeCommand(id));
        await completer.future.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => null,
        );
      }
    } catch (_) {}

    for (final c in _pendingRequests.values) {
      if (!c.isCompleted) {
        c.completeError(const MiniaudioPlayerException('Player disposed'));
      }
    }
    _pendingRequests.clear();

    _mainReceivePort?.close();
    _mainReceivePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerSendPort = null;
  }
}
