import 'dart:math' as math;

import '../rust/api/types.dart';

/// 3D Cartesian vector with single-precision floating point coordinates.
class Vector3 {
  final double x;
  final double y;
  final double z;

  const Vector3(this.x, this.y, this.z);

  static const Vector3 zero = Vector3(0.0, 0.0, 0.0);
  static const Vector3 forward = Vector3(0.0, 0.0, -1.0);
  static const Vector3 up = Vector3(0.0, 1.0, 0.0);
  static const Vector3 right = Vector3(1.0, 0.0, 0.0);

  Vector3 operator +(Vector3 other) =>
      Vector3(x + other.x, y + other.y, z + other.z);

  Vector3 operator -(Vector3 other) =>
      Vector3(x - other.x, y - other.y, z - other.z);

  Vector3 operator *(double scalar) =>
      Vector3(x * scalar, y * scalar, z * scalar);

  Vector3 operator -() => Vector3(-x, -y, -z);

  double dot(Vector3 other) => x * other.x + y * other.y + z * other.z;

  Vector3 cross(Vector3 other) => Vector3(
        y * other.z - z * other.y,
        z * other.x - x * other.z,
        x * other.y - y * other.x,
      );

  double get lengthSquared => x * x + y * y + z * z;

  double get length => math.sqrt(lengthSquared);

  Vector3 get normalized {
    final len = length;
    if (len < 1e-12) return Vector3.zero;
    final inv = 1.0 / len;
    return Vector3(x * inv, y * inv, z * inv);
  }

  double distanceTo(Vector3 other) => (this - other).length;

  Vector3 lerp(Vector3 other, double t) =>
      Vector3(x + (other.x - x) * t, y + (other.y - y) * t, z + (other.z - z) * t);

  RustVector3 toRust() => RustVector3(x: x, y: y, z: z);

  factory Vector3.fromRust(RustVector3 rust) =>
      Vector3(rust.x, rust.y, rust.z);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Vector3 &&
          runtimeType == other.runtimeType &&
          x == other.x &&
          y == other.y &&
          z == other.z;

  @override
  int get hashCode => x.hashCode ^ y.hashCode ^ z.hashCode;

  @override
  String toString() => 'Vector3($x, $y, $z)';
}

/// Distance attenuation model applied to spatial audio emitters.
enum DistanceModel {
  /// Standard OpenAL / WebAudio inverse distance attenuation (1 / (1 + rolloff * (dist - min) / min)).
  inverse,

  /// Linear attenuation dropping to 0 at max distance.
  linear,

  /// Exponential attenuation dropping off sharply by distance power.
  exponential;

  RustDistanceModel toRust() {
    switch (this) {
      case DistanceModel.inverse:
        return RustDistanceModel.inverse;
      case DistanceModel.linear:
        return RustDistanceModel.linear;
      case DistanceModel.exponential:
        return RustDistanceModel.exponential;
    }
  }

  static DistanceModel fromRust(RustDistanceModel rust) {
    switch (rust) {
      case RustDistanceModel.inverse:
        return DistanceModel.inverse;
      case RustDistanceModel.linear:
        return DistanceModel.linear;
      case RustDistanceModel.exponential:
        return DistanceModel.exponential;
    }
  }
}

/// 3D Spatial Audio Listener state representing the player/camera/ears in space.
class SpatialListener {
  /// Position in world space coordinates.
  final Vector3 position;

  /// Velocity vector in meters per second (used for Doppler calculations).
  final Vector3 velocity;

  /// Unit forward orientation vector.
  final Vector3 forward;

  /// Unit up orientation vector.
  final Vector3 up;

  const SpatialListener({
    this.position = Vector3.zero,
    this.velocity = Vector3.zero,
    this.forward = Vector3.forward,
    this.up = Vector3.up,
  });

  SpatialListener copyWith({
    Vector3? position,
    Vector3? velocity,
    Vector3? forward,
    Vector3? up,
  }) {
    return SpatialListener(
      position: position ?? this.position,
      velocity: velocity ?? this.velocity,
      forward: forward ?? this.forward,
      up: up ?? this.up,
    );
  }

  RustSpatialListener toRust() => RustSpatialListener(
        position: position.toRust(),
        velocity: velocity.toRust(),
        forward: forward.toRust(),
        up: up.toRust(),
      );

  factory SpatialListener.fromRust(RustSpatialListener rust) => SpatialListener(
        position: Vector3.fromRust(rust.position),
        velocity: Vector3.fromRust(rust.velocity),
        forward: Vector3.fromRust(rust.forward),
        up: Vector3.fromRust(rust.up),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpatialListener &&
          runtimeType == other.runtimeType &&
          position == other.position &&
          velocity == other.velocity &&
          forward == other.forward &&
          up == other.up;

  @override
  int get hashCode =>
      position.hashCode ^ velocity.hashCode ^ forward.hashCode ^ up.hashCode;

  @override
  String toString() =>
      'SpatialListener(pos: $position, vel: $velocity, fwd: $forward, up: $up)';
}

/// 3D Spatial Audio Emitter state representing the sound source in space.
class SpatialEmitter {
  /// Position in world space coordinates.
  final Vector3 position;

  /// Velocity vector in meters per second (used for Doppler calculations).
  final Vector3 velocity;

  /// Direction orientation vector for directional sound cones (null = omnidirectional).
  final Vector3? direction;

  /// Minimum distance where attenuation begins (sound is at full volume within this radius).
  final double minDistance;

  /// Maximum distance where attenuation reaches limit (clamped or zero).
  final double maxDistance;

  /// Rolloff factor scaling the distance attenuation slope (default 1.0).
  final double rolloffFactor;

  /// Alias for [rolloffFactor].
  double get rolloff => rolloffFactor;

  /// Emitter-specific Doppler factor scale (default 1.0).
  final double dopplerFactor;

  /// Inner cone angle in radians where gain is 1.0 (default 2*PI, omnidirectional).
  final double innerAngleRad;

  /// Outer cone angle in radians where gain transitions to [outerGain] (default 2*PI).
  final double outerAngleRad;

  /// Gain applied outside the outer sound cone (0.0 to 1.0).
  final double outerGain;

  /// Distance attenuation curve model.
  final DistanceModel distanceModel;

  const SpatialEmitter({
    this.position = Vector3.zero,
    this.velocity = Vector3.zero,
    this.direction,
    this.minDistance = 1.0,
    this.maxDistance = 1000.0,
    double rolloff = 1.0,
    double? rolloffFactor,
    this.dopplerFactor = 1.0,
    this.innerAngleRad = 6.283185307179586,
    this.outerAngleRad = 6.283185307179586,
    this.outerGain = 0.0,
    this.distanceModel = DistanceModel.inverse,
  }) : rolloffFactor = rolloffFactor ?? rolloff;

  SpatialEmitter copyWith({
    Vector3? position,
    Vector3? velocity,
    Vector3? direction,
    double? minDistance,
    double? maxDistance,
    double? rolloff,
    double? rolloffFactor,
    double? dopplerFactor,
    double? innerAngleRad,
    double? outerAngleRad,
    double? outerGain,
    DistanceModel? distanceModel,
  }) {
    return SpatialEmitter(
      position: position ?? this.position,
      velocity: velocity ?? this.velocity,
      direction: direction ?? this.direction,
      minDistance: minDistance ?? this.minDistance,
      maxDistance: maxDistance ?? this.maxDistance,
      rolloffFactor: rolloffFactor ?? rolloff ?? this.rolloffFactor,
      dopplerFactor: dopplerFactor ?? this.dopplerFactor,
      innerAngleRad: innerAngleRad ?? this.innerAngleRad,
      outerAngleRad: outerAngleRad ?? this.outerAngleRad,
      outerGain: outerGain ?? this.outerGain,
      distanceModel: distanceModel ?? this.distanceModel,
    );
  }

  RustSpatialEmitter toRust() => RustSpatialEmitter(
        position: position.toRust(),
        velocity: velocity.toRust(),
        direction: direction?.toRust(),
        minDistance: minDistance,
        maxDistance: maxDistance,
        rolloffFactor: rolloffFactor,
        dopplerFactor: dopplerFactor,
        innerAngleRad: innerAngleRad,
        outerAngleRad: outerAngleRad,
        outerGain: outerGain,
        distanceModel: distanceModel.toRust(),
      );

  factory SpatialEmitter.fromRust(RustSpatialEmitter rust) => SpatialEmitter(
        position: Vector3.fromRust(rust.position),
        velocity: Vector3.fromRust(rust.velocity),
        direction: rust.direction != null ? Vector3.fromRust(rust.direction!) : null,
        minDistance: rust.minDistance,
        maxDistance: rust.maxDistance,
        rolloffFactor: rust.rolloffFactor,
        dopplerFactor: rust.dopplerFactor,
        innerAngleRad: rust.innerAngleRad,
        outerAngleRad: rust.outerAngleRad,
        outerGain: rust.outerGain,
        distanceModel: DistanceModel.fromRust(rust.distanceModel),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpatialEmitter &&
          runtimeType == other.runtimeType &&
          position == other.position &&
          velocity == other.velocity &&
          direction == other.direction &&
          minDistance == other.minDistance &&
          maxDistance == other.maxDistance &&
          rolloff == other.rolloff &&
          dopplerFactor == other.dopplerFactor &&
          innerAngleRad == other.innerAngleRad &&
          outerAngleRad == other.outerAngleRad &&
          outerGain == other.outerGain &&
          distanceModel == other.distanceModel;

  @override
  int get hashCode =>
      position.hashCode ^
      velocity.hashCode ^
      direction.hashCode ^
      minDistance.hashCode ^
      maxDistance.hashCode ^
      rolloff.hashCode ^
      dopplerFactor.hashCode ^
      innerAngleRad.hashCode ^
      outerAngleRad.hashCode ^
      outerGain.hashCode ^
      distanceModel.hashCode;

  @override
  String toString() =>
      'SpatialEmitter(pos: $position, vel: $velocity, min: $minDistance, max: $maxDistance, doppler: $dopplerFactor)';
}

/// Controller providing high-performance 3D Spatial Audio and Doppler effect control.
class SpatialController {
  final void Function(bool enabled) _setEnabled;
  final void Function(SpatialListener listener) _setListener;
  final void Function(SpatialEmitter emitter) _setEmitter;
  final void Function(double factor) _setDopplerFactor;
  final void Function(double speed) _setSpeedOfSound;

  bool _enabled = false;
  SpatialListener _listener = const SpatialListener();
  SpatialEmitter _emitter = const SpatialEmitter();
  double _dopplerFactor = 1.0;
  double _speedOfSound = 343.3;

  SpatialController({
    required void Function(bool enabled) setEnabled,
    required void Function(SpatialListener listener) setListener,
    required void Function(SpatialEmitter emitter) setEmitter,
    required void Function(double factor) setDopplerFactor,
    required void Function(double speed) setSpeedOfSound,
  })  : _setEnabled = setEnabled,
        _setListener = setListener,
        _setEmitter = setEmitter,
        _setDopplerFactor = setDopplerFactor,
        _setSpeedOfSound = setSpeedOfSound;

  /// Whether 3D spatial processing and Doppler shift are active.
  bool get isEnabled => _enabled;

  /// Current listener position, velocity, and orientation.
  SpatialListener get listener => _listener;

  /// Current emitter position, velocity, and parameters.
  SpatialEmitter get emitter => _emitter;

  /// Global Doppler scale factor applied to this audio stream (default 1.0, 0.0 disables Doppler).
  double get dopplerFactor => _dopplerFactor;

  /// Medium speed of sound in meters per second (default 343.3 m/s for dry air at 20°C).
  double get speedOfSound => _speedOfSound;

  /// Enables or disables 3D spatial audio and Doppler processing.
  void setEnabled(bool enabled) {
    _enabled = enabled;
    _setEnabled(enabled);
  }

  /// Updates the listener in space.
  void setListener({
    Vector3? position,
    Vector3? velocity,
    Vector3? forward,
    Vector3? up,
  }) {
    _listener = _listener.copyWith(
      position: position,
      velocity: velocity,
      forward: forward,
      up: up,
    );
    _setListener(_listener);
  }

  /// Updates the listener directly with a [SpatialListener] instance.
  void updateListener(SpatialListener listener) {
    _listener = listener;
    _setListener(_listener);
  }

  /// Updates the sound emitter in space.
  void setEmitter({
    Vector3? position,
    Vector3? velocity,
    Vector3? direction,
    double? minDistance,
    double? maxDistance,
    double? rolloff,
    double? dopplerFactor,
    double? innerAngleRad,
    double? outerAngleRad,
    double? outerGain,
    DistanceModel? distanceModel,
  }) {
    _emitter = _emitter.copyWith(
      position: position,
      velocity: velocity,
      direction: direction,
      minDistance: minDistance,
      maxDistance: maxDistance,
      rolloff: rolloff,
      dopplerFactor: dopplerFactor,
      innerAngleRad: innerAngleRad,
      outerAngleRad: outerAngleRad,
      outerGain: outerGain,
      distanceModel: distanceModel,
    );
    _setEmitter(_emitter);
  }

  /// Updates the emitter directly with a [SpatialEmitter] instance.
  void updateEmitter(SpatialEmitter emitter) {
    _emitter = emitter;
    _setEmitter(_emitter);
  }

  /// Sets the Doppler effect exaggeration/reduction scale factor (default 1.0, 0.0 disables shift).
  void setDopplerFactor(double factor) {
    if (factor < 0.0 || factor.isNaN || factor.isInfinite) {
      throw ArgumentError.value(
        factor,
        'factor',
        'Doppler factor must be non-negative and finite',
      );
    }
    _dopplerFactor = factor;
    _setDopplerFactor(factor);
  }

  /// Sets the medium speed of sound in m/s (default 343.3 m/s).
  void setSpeedOfSound(double speed) {
    if (speed <= 0.0 || speed.isNaN || speed.isInfinite) {
      throw ArgumentError.value(
        speed,
        'speed',
        'Speed of sound must be positive and finite',
      );
    }
    _speedOfSound = speed;
    _setSpeedOfSound(speed);
  }
}
