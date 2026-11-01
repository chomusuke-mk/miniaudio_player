import 'dart:io';
import 'dart:typed_data' hide Uint64List;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Uint64List;

import '../platform/native/native_backend.dart';
import '../rust/api/game.dart';
import '../rust/api/types.dart';
import 'spatial.dart';

/// Eviction policy used when all voices in the pool are active and a new sound is triggered.
enum VoiceStealingPolicy {
  /// Steal the voice with the lowest user-assigned priority.
  lowestPriority,

  /// Steal the voice that has been playing the longest.
  oldest,

  /// Steal the voice with the lowest effective calculated volume/gain.
  quietest,

  /// Steal the voice that is spatially farthest from the listener.
  farthest;

  RustVoiceStealingPolicy toRust() {
    switch (this) {
      case VoiceStealingPolicy.lowestPriority:
        return RustVoiceStealingPolicy.lowestPriority;
      case VoiceStealingPolicy.oldest:
        return RustVoiceStealingPolicy.oldest;
      case VoiceStealingPolicy.quietest:
        return RustVoiceStealingPolicy.quietest;
      case VoiceStealingPolicy.farthest:
        return RustVoiceStealingPolicy.farthest;
    }
  }

  static VoiceStealingPolicy fromRust(RustVoiceStealingPolicy rust) {
    switch (rust) {
      case RustVoiceStealingPolicy.lowestPriority:
        return VoiceStealingPolicy.lowestPriority;
      case RustVoiceStealingPolicy.oldest:
        return VoiceStealingPolicy.oldest;
      case RustVoiceStealingPolicy.quietest:
        return VoiceStealingPolicy.quietest;
      case RustVoiceStealingPolicy.farthest:
        return VoiceStealingPolicy.farthest;
    }
  }
}

/// Pre-decoded PCM audio buffer held resident in RAM for instant, zero-latency playback.
class SoundBuffer {
  /// Unique numeric identifier assigned to this buffer in native memory.
  final BigInt id;

  /// Sampling rate of the buffer (e.g. 44100, 48000).
  final int sampleRate;

  /// Number of interleaved channels (1 for mono, 2 for stereo).
  final int channels;

  /// Total duration of the audio clip.
  final Duration duration;

  /// Total number of PCM sample frames in the buffer.
  final int frameCount;

  const SoundBuffer({
    required this.id,
    required this.sampleRate,
    required this.channels,
    required this.duration,
    required this.frameCount,
  });

  factory SoundBuffer.fromRust(RustSoundBufferInfo info) {
    return SoundBuffer(
      id: info.id,
      sampleRate: info.sampleRate,
      channels: info.channels,
      duration: Duration(milliseconds: info.durationMs.toInt()),
      frameCount: info.frameCount.toInt(),
    );
  }

  @override
  String toString() =>
      'SoundBuffer(id: $id, sampleRate: $sampleRate, channels: $channels, duration: $duration, frames: $frameCount)';
}

/// Polyphonic voice pool and game audio manager.
///
/// Features:
/// - Up to 64 concurrent hardware-mixed voices with zero heap allocations in the audio thread.
/// - Dynamic voice stealing policies (LowestPriority, Oldest, Quietest, Farthest).
/// - Instant one-shot audio triggers with random pitch and volume jitter (anti-machine-gun fatigue).
/// - Anti-click 5 ms linear fade-out when voices are stolen or stopped.
/// - 3D spatial audio with Doppler effect and distance attenuation models.
/// - Bullet-time / slow-motion TimeScale multiplier.
/// - Synchronous stems / vertical layering playback.
class MiniaudioVoicePool {
  final RustVoicePool _rust;
  bool _isDisposed = false;

  MiniaudioVoicePool._(this._rust);

  /// Initializes and starts a new hardware-accelerated [MiniaudioVoicePool].
  static Future<MiniaudioVoicePool> create({
    int sampleRate = 44100,
    int channels = 2,
    int periodSize = 1024,
    String? playbackDeviceId,
    int maxVoices = 64,
  }) async {
    await NativePlayerBackend.ensureRustInitialized();
    final rust = RustVoicePool(
      sampleRate: sampleRate,
      channels: channels,
      periodSize: periodSize,
      playbackDeviceId: playbackDeviceId,
      maxVoices: BigInt.from(maxVoices),
    );
    return MiniaudioVoicePool._(rust);
  }

  /// Decodes and loads any supported audio format (MP3, WAV, OGG, FLAC, AAC, etc.)
  /// from an in-memory byte slice into a RAM-resident [SoundBuffer].
  Future<SoundBuffer> loadSound(Uint8List bytes) async {
    _ensureNotDisposed();
    final info = await _rust.loadSound(bytes: bytes);
    return SoundBuffer.fromRust(info);
  }

  /// Loads an audio file from the file system into a RAM-resident [SoundBuffer].
  Future<SoundBuffer> loadSoundFromFile(String filePath) async {
    _ensureNotDisposed();
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    return loadSound(bytes);
  }

  /// Unloads a pre-decoded buffer from RAM.
  bool unloadSound(SoundBuffer buffer) {
    _ensureNotDisposed();
    return _rust.unloadSound(bufferId: buffer.id);
  }

  /// Triggers a sound in the voice pool. Returns the assigned `voiceId`.
  ///
  /// If the pool is at maximum capacity, the configured [VoiceStealingPolicy]
  /// is evaluated to recycle a voice. If stealing rejects the sound (e.g. lower priority),
  /// the method still returns a voiceId but it will be safely dropped.
  int playSound(
    SoundBuffer buffer, {
    double volume = 1.0,
    double pitch = 1.0,
    int priority = 128,
    bool looping = false,
    SpatialEmitter? emitter,
  }) {
    _ensureNotDisposed();
    return _rust.playSound(
      bufferId: buffer.id,
      volume: volume,
      pitch: pitch,
      priority: priority,
      looping: looping,
      emitter: emitter?.toRust(),
    );
  }

  /// Plays an immediate one-shot sound with optional random pitch and volume jitter.
  ///
  /// Jitter prevents repetitive audio fatigue ("machine-gun effect").
  /// E.g. `pitchJitter: 0.05` introduces $\pm 5\%$ pitch variations.
  int playOneShot(
    SoundBuffer buffer, {
    double volume = 1.0,
    double pitch = 1.0,
    double pitchJitter = 0.0,
    double volumeJitter = 0.0,
    int priority = 128,
    SpatialEmitter? emitter,
  }) {
    _ensureNotDisposed();
    return _rust.playOneShot(
      bufferId: buffer.id,
      volume: volume,
      pitch: pitch,
      pitchJitter: pitchJitter,
      volumeJitter: volumeJitter,
      priority: priority,
      emitter: emitter?.toRust(),
    );
  }

  /// Triggers synchronized stem layers (e.g. Drums, Bass, Lead, FX) starting simultaneously
  /// at exact frame cursor 0.0.
  List<int> playStems(
    List<SoundBuffer> buffers, {
    List<double>? volumes,
    bool looping = false,
  }) {
    _ensureNotDisposed();
    final bufIds = Uint64List.fromList(buffers.map((b) => b.id.toInt()).toList());
    final vols = volumes ?? List.filled(buffers.length, 1.0);
    final res = _rust.playStems(
      bufferIds: bufIds,
      volumes: vols,
      looping: looping,
    );
    return res.toList();
  }

  /// Stops an active voice gracefully with an anti-click 5 ms fade-out.
  void stopVoice(int voiceId) {
    _ensureNotDisposed();
    _rust.stopVoice(voiceId: voiceId);
  }

  /// Stops all voices immediately.
  void stopAll() {
    _ensureNotDisposed();
    _rust.stopAll();
  }

  /// Modifies the volume of an active voice dynamically (0.0 to 2.0).
  void setVoiceVolume(int voiceId, double volume) {
    _ensureNotDisposed();
    _rust.setVoiceVolume(voiceId: voiceId, volume: volume);
  }

  /// Modifies the pitch / speed of an active voice dynamically (0.1 to 4.0).
  void setVoicePitch(int voiceId, double pitch) {
    _ensureNotDisposed();
    _rust.setVoicePitch(voiceId: voiceId, pitch: pitch);
  }

  /// Updates the 3D spatial emitter of an active voice in real time.
  void setVoiceEmitter(int voiceId, SpatialEmitter? emitter) {
    _ensureNotDisposed();
    _rust.setVoiceEmitter(voiceId: voiceId, emitter: emitter?.toRust());
  }

  /// Sets the master volume multiplier for all voices (0.0 to 2.0).
  void setMasterVolume(double volume) {
    _ensureNotDisposed();
    _rust.setMasterVolume(volume: volume);
  }

  /// Sets the global time scale multiplier for the voice pool
  /// (e.g. 0.5 = bullet time / slow motion, 2.0 = fast forward).
  void setTimeScale(double scale) {
    _ensureNotDisposed();
    _rust.setTimeScale(scale: scale);
  }

  /// Sets the voice stealing eviction policy.
  void setPolicy(VoiceStealingPolicy policy) {
    _ensureNotDisposed();
    _rust.setPolicy(policy: policy.toRust());
  }

  /// Updates the 3D spatial listener (player / camera) position, velocity, and orientation.
  void setListener(SpatialListener listener) {
    _ensureNotDisposed();
    _rust.setListener(listener: listener.toRust());
  }

  /// Number of currently active (playing or fading) voices in the pool.
  int get activeVoicesCount {
    _ensureNotDisposed();
    return _rust.activeVoicesCount();
  }

  bool get isDisposed => _isDisposed;

  /// Disposes the voice pool and stops all sounds.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _rust.stopAll();
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('Cannot operate on a disposed MiniaudioVoicePool');
    }
  }
}
