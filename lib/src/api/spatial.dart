import 'dart:math' as math;

import '../rust/api/types.dart';
import 'logger.dart';

/// 3D Cartesian vector with double-precision floating-point coordinates.
class Vector3 {
  /// The X Cartesian coordinate.
  final double x;

  /// The Y Cartesian coordinate.
  final double y;

  /// The Z Cartesian coordinate.
  final double z;

  /// Creates a [Vector3] with [x], [y], and [z] coordinates.
  const Vector3(this.x, this.y, this.z);

  /// Zero vector `(0.0, 0.0, 0.0)`.
  static const Vector3 zero = Vector3(0.0, 0.0, 0.0);

  /// Unit forward vector `(0.0, 0.0, -1.0)`.
  static const Vector3 forward = Vector3(0.0, 0.0, -1.0);

  /// Unit up vector `(0.0, 1.0, 0.0)`.
  static const Vector3 up = Vector3(0.0, 1.0, 0.0);

  /// Unit right vector `(1.0, 0.0, 0.0)`.
  static const Vector3 right = Vector3(1.0, 0.0, 0.0);

  /// Adds [other] component-wise to this vector.
  Vector3 operator +(Vector3 other) =>
      Vector3(x + other.x, y + other.y, z + other.z);

  /// Subtracts [other] component-wise from this vector.
  Vector3 operator -(Vector3 other) =>
      Vector3(x - other.x, y - other.y, z - other.z);

  /// Scales this vector by [scalar].
  Vector3 operator *(double scalar) =>
      Vector3(x * scalar, y * scalar, z * scalar);

  /// Returns the component-wise negation of this vector.
  Vector3 operator -() => Vector3(-x, -y, -z);

  /// Computes the dot product of this vector and [other].
  double dot(Vector3 other) => x * other.x + y * other.y + z * other.z;

  /// Computes the cross product of this vector and [other].
  Vector3 cross(Vector3 other) => Vector3(
        y * other.z - z * other.y,
        z * other.x - x * other.z,
        x * other.y - y * other.x,
      );

  /// The squared Euclidean length of this vector.
  double get lengthSquared => x * x + y * y + z * z;

  /// The Euclidean length of this vector.
  double get length => math.sqrt(lengthSquared);

  /// Returns a unit vector in the same direction, or [Vector3.zero] if degenerate.
  ///
  /// Vectors with a length smaller than `1e-12` are treated as zero-length to
  /// avoid division-by-zero instability.
  Vector3 get normalized {
    final len = length;
    if (len < 1e-12) return Vector3.zero;
    final inv = 1.0 / len;
    return Vector3(x * inv, y * inv, z * inv);
  }

  /// Computes the Euclidean distance between this vector and [other].
  double distanceTo(Vector3 other) => (this - other).length;

  /// Linearly interpolates between this vector and [other] by factor [t].
  Vector3 lerp(Vector3 other, double t) => Vector3(
      x + (other.x - x) * t, y + (other.y - y) * t, z + (other.z - z) * t);

  /// Converts this vector to its native [RustVector3] representation.
  RustVector3 toRust() => RustVector3(x: x, y: y, z: z);

  /// Constructs a [Vector3] from a native [RustVector3] value [rust].
  factory Vector3.fromRust(RustVector3 rust) => Vector3(rust.x, rust.y, rust.z);

  /// Returns `true` if [other] is a [Vector3] with identical coordinates.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Vector3 &&
          runtimeType == other.runtimeType &&
          x == other.x &&
          y == other.y &&
          z == other.z;

  /// Returns a hash code derived from [x], [y], and [z].
  @override
  int get hashCode => Object.hash(x, y, z);

  /// Returns a human-readable string representation of this [Vector3].
  @override
  String toString() => 'Vector3($x, $y, $z)';
}

/// Distance attenuation model applied to spatial audio emitters.
enum DistanceModel {
  /// Standard OpenAL and WebAudio inverse distance attenuation.
  ///
  /// Computed as `1 / (1 + rolloff * (dist - min) / min)`.
  inverse,

  /// Linear attenuation dropping to `0.0` at maximum distance.
  linear,

  /// Exponential attenuation dropping off sharply by distance power.
  exponential;

  /// Converts this model to its native [RustDistanceModel] representation.
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

  /// Resolves a [DistanceModel] from a native [RustDistanceModel] value [rust].
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

/// 3D spatial audio listener state representing the player, camera, or ears in space.
class SpatialListener {
  /// The position in world-space coordinates.
  final Vector3 position;

  /// The velocity vector in meters per second used for Doppler calculations.
  final Vector3 velocity;

  /// The unit forward orientation vector.
  final Vector3 forward;

  /// The unit up orientation vector.
  final Vector3 up;

  /// Creates a [SpatialListener] with the given spatial parameters.
  ///
  /// Initializes [position], [velocity], [forward], and [up] with standard
  /// right-handed defaults.
  const SpatialListener({
    this.position = Vector3.zero,
    this.velocity = Vector3.zero,
    this.forward = Vector3.forward,
    this.up = Vector3.up,
  });

  /// Returns a copy of this [SpatialListener] with updated spatial parameters.
  ///
  /// Replaces [position], [velocity], [forward], and [up] when non-`null`.
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

  /// Converts this listener to its native [RustSpatialListener] representation.
  RustSpatialListener toRust() => RustSpatialListener(
        position: position.toRust(),
        velocity: velocity.toRust(),
        forward: forward.toRust(),
        up: up.toRust(),
      );

  /// Constructs a [SpatialListener] from a native [RustSpatialListener] value [rust].
  factory SpatialListener.fromRust(RustSpatialListener rust) => SpatialListener(
        position: Vector3.fromRust(rust.position),
        velocity: Vector3.fromRust(rust.velocity),
        forward: Vector3.fromRust(rust.forward),
        up: Vector3.fromRust(rust.up),
      );

  /// Returns `true` if [other] is a [SpatialListener] with identical transforms.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpatialListener &&
          runtimeType == other.runtimeType &&
          position == other.position &&
          velocity == other.velocity &&
          forward == other.forward &&
          up == other.up;

  /// Returns a hash code derived from [position], [velocity], [forward], and
  /// [up].
  @override
  int get hashCode => Object.hash(position, velocity, forward, up);

  /// Returns a human-readable string representation of this [SpatialListener].
  @override
  String toString() =>
      'SpatialListener(pos: $position, vel: $velocity, fwd: $forward, up: $up)';
}

/// 3D spatial audio emitter state representing a sound source in space.
class SpatialEmitter {
  /// The position in world-space coordinates.
  final Vector3 position;

  /// The velocity vector in meters per second used for Doppler calculations.
  final Vector3 velocity;

  /// The direction orientation vector for directional sound cones.
  ///
  /// When `null`, the emitter radiates omnidirectionally.
  final Vector3? direction;

  /// The minimum distance where attenuation begins.
  ///
  /// Sound remains at full volume within this radius.
  final double minDistance;

  /// The maximum distance where attenuation reaches its limit.
  final double maxDistance;

  /// The rolloff factor scaling the distance attenuation slope (defaults to `1.0`).
  final double rolloffFactor;

  /// The emitter-specific Doppler factor scale (defaults to `1.0`).
  final double dopplerFactor;

  /// The inner cone angle in radians where gain is `1.0` (defaults to `2 * pi`).
  final double innerAngleRad;

  /// The outer cone angle in radians where gain transitions to [outerGain] (defaults to `2 * pi`).
  final double outerAngleRad;

  /// The gain applied outside the outer sound cone (`0.0` to `1.0`).
  final double outerGain;

  /// The distance attenuation curve model.
  final DistanceModel distanceModel;

  /// Creates a [SpatialEmitter] with positioning and sound-cone parameters.
  ///
  /// Configures [position], [velocity], [direction], [minDistance],
  /// [maxDistance], [rolloffFactor], [dopplerFactor], [innerAngleRad],
  /// [outerAngleRad], [outerGain], and [distanceModel].
  const SpatialEmitter({
    this.position = Vector3.zero,
    this.velocity = Vector3.zero,
    this.direction,
    this.minDistance = 1.0,
    this.maxDistance = 1000.0,
    this.rolloffFactor = 1.0,
    this.dopplerFactor = 1.0,
    this.innerAngleRad = 6.283185307179586,
    this.outerAngleRad = 6.283185307179586,
    this.outerGain = 0.0,
    this.distanceModel = DistanceModel.inverse,
  });

  /// Returns a copy of this [SpatialEmitter] with updated parameters.
  ///
  /// Replaces [position], [velocity], [direction], [minDistance], [maxDistance],
  /// [rolloffFactor], [dopplerFactor], [innerAngleRad], [outerAngleRad],
  /// [outerGain], and [distanceModel] when non-`null`.
  SpatialEmitter copyWith({
    Vector3? position,
    Vector3? velocity,
    Vector3? direction,
    double? minDistance,
    double? maxDistance,
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
      rolloffFactor: rolloffFactor ?? this.rolloffFactor,
      dopplerFactor: dopplerFactor ?? this.dopplerFactor,
      innerAngleRad: innerAngleRad ?? this.innerAngleRad,
      outerAngleRad: outerAngleRad ?? this.outerAngleRad,
      outerGain: outerGain ?? this.outerGain,
      distanceModel: distanceModel ?? this.distanceModel,
    );
  }

  /// Converts this emitter to its native [RustSpatialEmitter] representation.
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

  /// Constructs a [SpatialEmitter] from a native [RustSpatialEmitter] value [rust].
  factory SpatialEmitter.fromRust(RustSpatialEmitter rust) => SpatialEmitter(
        position: Vector3.fromRust(rust.position),
        velocity: Vector3.fromRust(rust.velocity),
        direction:
            rust.direction != null ? Vector3.fromRust(rust.direction!) : null,
        minDistance: rust.minDistance,
        maxDistance: rust.maxDistance,
        rolloffFactor: rust.rolloffFactor,
        dopplerFactor: rust.dopplerFactor,
        innerAngleRad: rust.innerAngleRad,
        outerAngleRad: rust.outerAngleRad,
        outerGain: rust.outerGain,
        distanceModel: DistanceModel.fromRust(rust.distanceModel),
      );

  /// Returns `true` if [other] is a [SpatialEmitter] with identical properties.
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
          rolloffFactor == other.rolloffFactor &&
          dopplerFactor == other.dopplerFactor &&
          innerAngleRad == other.innerAngleRad &&
          outerAngleRad == other.outerAngleRad &&
          outerGain == other.outerGain &&
          distanceModel == other.distanceModel;

  /// Returns a hash code derived from all emitter fields.
  @override
  int get hashCode => Object.hash(
        position,
        velocity,
        direction,
        minDistance,
        maxDistance,
        rolloffFactor,
        dopplerFactor,
        innerAngleRad,
        outerAngleRad,
        outerGain,
        distanceModel,
      );

  /// Returns a human-readable string representation of this [SpatialEmitter].
  @override
  String toString() =>
      'SpatialEmitter(pos: $position, vel: $velocity, min: $minDistance, max: $maxDistance, doppler: $dopplerFactor)';
}

/// Controller providing high-performance 3D spatial audio and Doppler effect control.
class SpatialController {
  /// Callback invoked when spatial processing is enabled or disabled.
  final void Function(bool enabled) _setEnabled;

  /// Callback invoked when the listener transform changes.
  final void Function(SpatialListener listener) _setListener;

  /// Callback invoked when the emitter transform or parameters change.
  final void Function(SpatialEmitter emitter) _setEmitter;

  /// Callback invoked when the global Doppler scale factor changes.
  final void Function(double factor) _setDopplerFactor;

  /// Callback invoked when the medium speed of sound changes.
  final void Function(double speed) _setSpeedOfSound;

  /// Cached enabled flag for synchronous inspection.
  bool _enabled = false;

  /// Cached listener state for synchronous inspection.
  SpatialListener _listener = const SpatialListener();

  /// Cached emitter state for synchronous inspection.
  SpatialEmitter _emitter = const SpatialEmitter();

  /// Cached global Doppler factor.
  double _dopplerFactor = 1.0;

  /// Cached medium speed of sound in meters per second.
  double _speedOfSound = 343.3;

  /// Creates a [SpatialController] managing 3D spatial callbacks.
  ///
  /// Wires [setEnabled], [setListener], [setEmitter], [setDopplerFactor], and
  /// [setSpeedOfSound] to the underlying audio engine.
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

  /// Global Doppler scale factor applied to this audio stream.
  ///
  /// Defaults to `1.0`; `0.0` disables Doppler pitch shift.
  double get dopplerFactor => _dopplerFactor;

  /// Medium speed of sound in meters per second.
  ///
  /// Defaults to `343.3` m/s for dry air at `20°C`.
  double get speedOfSound => _speedOfSound;

  /// Sets whether 3D spatial audio and Doppler processing is [enabled].
  void setEnabled(bool enabled) {
    _enabled = enabled;
    MapLogger.debug('SpatialController.setEnabled($enabled)');
    _setEnabled(enabled);
  }

  /// Updates the active spatial [listener] state in world space.
  void setListener(SpatialListener listener) {
    _listener = listener;
    MapLogger.verbose('SpatialController.setListener($listener)');
    _setListener(_listener);
  }

  /// Updates the active spatial sound [emitter] state in world space.
  void setEmitter(SpatialEmitter emitter) {
    _emitter = emitter;
    MapLogger.verbose('SpatialController.setEmitter($emitter)');
    _setEmitter(_emitter);
  }

  /// Sets the Doppler effect scale [factor].
  ///
  /// Defaults to `1.0`, while `0.0` disables Doppler shift. Throws an
  /// [ArgumentError] if [factor] is negative, `NaN`, or infinite.
  void setDopplerFactor(double factor) {
    if (factor < 0.0 || factor.isNaN || factor.isInfinite) {
      MapLogger.error('Invalid Doppler factor rejected: $factor');
      throw ArgumentError.value(
        factor,
        'factor',
        'Doppler factor must be non-negative and finite',
      );
    }
    _dopplerFactor = factor;
    MapLogger.debug('SpatialController.setDopplerFactor($factor)');
    _setDopplerFactor(factor);
  }

  /// Sets the medium [speed] of sound in meters per second.
  ///
  /// Defaults to `343.3` m/s. Throws an [ArgumentError] if [speed] is
  /// non-positive, `NaN`, or infinite.
  void setSpeedOfSound(double speed) {
    if (speed <= 0.0 || speed.isNaN || speed.isInfinite) {
      MapLogger.error('Invalid speed of sound rejected: $speed');
      throw ArgumentError.value(
        speed,
        'speed',
        'Speed of sound must be positive and finite',
      );
    }
    _speedOfSound = speed;
    MapLogger.debug('SpatialController.setSpeedOfSound($speed)');
    _setSpeedOfSound(speed);
  }
}
