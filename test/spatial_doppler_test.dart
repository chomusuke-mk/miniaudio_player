import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/src/rust/api/types.dart';

void main() {
  group('3D Spatial Audio & Doppler - Vector3 Math', () {
    test('Vector3 basic operations and constants', () {
      expect(Vector3.zero, const Vector3(0, 0, 0));
      expect(Vector3.forward, const Vector3(0, 0, -1));
      expect(Vector3.up, const Vector3(0, 1, 0));
      expect(Vector3.right, const Vector3(1, 0, 0));

      const v1 = Vector3(1, 2, 3);
      const v2 = Vector3(4, 5, 6);

      expect(v1 + v2, const Vector3(5, 7, 9));
      expect(v2 - v1, const Vector3(3, 3, 3));
      expect(v1 * 2.0, const Vector3(2, 4, 6));
      expect(-v1, const Vector3(-1, -2, -3));
    });

    test('Vector3 dot and cross product', () {
      const v1 = Vector3(1, 0, 0);
      const v2 = Vector3(0, 1, 0);

      expect(v1.dot(v2), 0.0);
      expect(v1.cross(v2), const Vector3(0, 0, 1));

      const v3 = Vector3(2, 3, 4);
      const v4 = Vector3(5, 6, 7);
      // dot: 2*5 + 3*6 + 4*7 = 10 + 18 + 28 = 56
      expect(v3.dot(v4), 56.0);
    });

    test('Vector3 length and normalization', () {
      const v = Vector3(3, 4, 0);
      expect(v.lengthSquared, 25.0);
      expect(v.length, 5.0);

      final norm = v.normalized;
      expect(norm.x, closeTo(0.6, 1e-6));
      expect(norm.y, closeTo(0.8, 1e-6));
      expect(norm.z, 0.0);
      expect(norm.length, closeTo(1.0, 1e-6));

      expect(Vector3.zero.normalized, Vector3.zero);
    });

    test('Vector3 distanceTo and lerp', () {
      const a = Vector3(0, 0, 0);
      const b = Vector3(0, 10, 0);

      expect(a.distanceTo(b), 10.0);
      expect(a.lerp(b, 0.5), const Vector3(0, 5, 0));
      expect(a.lerp(b, 0.2), const Vector3(0, 2, 0));
    });

    test('Vector3 Rust bridge round-trip', () {
      const v = Vector3(12.5, -45.0, 100.25);
      final rustV = v.toRust();
      expect(rustV.x, 12.5);
      expect(rustV.y, -45.0);
      expect(rustV.z, 100.25);

      final roundTrip = Vector3.fromRust(rustV);
      expect(roundTrip, v);
    });
  });

  group('3D Spatial Audio & Doppler - Listener and Emitter Models', () {
    test('SpatialListener defaults and copyWith', () {
      const listener = SpatialListener();
      expect(listener.position, Vector3.zero);
      expect(listener.velocity, Vector3.zero);
      expect(listener.forward, Vector3.forward);
      expect(listener.up, Vector3.up);

      final updated = listener.copyWith(
        position: const Vector3(10, 0, 5),
        velocity: const Vector3(0, 0, 20),
      );
      expect(updated.position, const Vector3(10, 0, 5));
      expect(updated.velocity, const Vector3(0, 0, 20));
      expect(updated.forward, Vector3.forward);
      expect(updated.up, Vector3.up);
    });

    test('SpatialListener Rust bridge round-trip', () {
      const listener = SpatialListener(
        position: Vector3(1, 2, 3),
        velocity: Vector3(4, 5, 6),
        forward: Vector3(0, 0, -1),
        up: Vector3(0, 1, 0),
      );
      final rust = listener.toRust();
      final roundTrip = SpatialListener.fromRust(rust);
      expect(roundTrip, listener);
    });

    test('SpatialEmitter defaults, copyWith and Rust round-trip', () {
      const emitter = SpatialEmitter(
        position: Vector3(5, 0, 0),
        velocity: Vector3(30, 0, 0),
        minDistance: 2.0,
        maxDistance: 500.0,
        rolloff: 1.5,
        dopplerFactor: 1.2,
        distanceModel: DistanceModel.linear,
      );

      expect(emitter.position, const Vector3(5, 0, 0));
      expect(emitter.velocity, const Vector3(30, 0, 0));
      expect(emitter.rolloff, 1.5);
      expect(emitter.rolloffFactor, 1.5);
      expect(emitter.distanceModel, DistanceModel.linear);

      final rust = emitter.toRust();
      expect(rust.rolloffFactor, 1.5);
      expect(rust.distanceModel, RustDistanceModel.linear);

      final roundTrip = SpatialEmitter.fromRust(rust);
      expect(roundTrip.position, emitter.position);
      expect(roundTrip.velocity, emitter.velocity);
      expect(roundTrip.rolloffFactor, emitter.rolloffFactor);
      expect(roundTrip.dopplerFactor, emitter.dopplerFactor);
      expect(roundTrip.distanceModel, emitter.distanceModel);
    });
  });

  group('3D Spatial Audio & Doppler - SpatialController', () {
    test('Controller handles state changes and validation', () {
      bool setEnabledCalled = false;
      SpatialListener? lastListener;
      SpatialEmitter? lastEmitter;
      double? lastDopplerFactor;
      double? lastSpeedOfSound;

      final controller = SpatialController(
        setEnabled: (e) => setEnabledCalled = e,
        setListener: (l) => lastListener = l,
        setEmitter: (em) => lastEmitter = em,
        setDopplerFactor: (f) => lastDopplerFactor = f,
        setSpeedOfSound: (s) => lastSpeedOfSound = s,
      );

      expect(controller.isEnabled, false);
      controller.setEnabled(true);
      expect(controller.isEnabled, true);
      expect(setEnabledCalled, true);

      controller.setListener(
        position: const Vector3(0, 0, 0),
        velocity: const Vector3(0, 0, 5),
      );
      expect(lastListener?.position, const Vector3(0, 0, 0));
      expect(lastListener?.velocity, const Vector3(0, 0, 5));

      controller.setEmitter(
        position: const Vector3(100, 0, 0),
        velocity: const Vector3(-50, 0, 0),
        dopplerFactor: 1.5,
      );
      expect(lastEmitter?.position, const Vector3(100, 0, 0));
      expect(lastEmitter?.velocity, const Vector3(-50, 0, 0));
      expect(lastEmitter?.dopplerFactor, 1.5);

      controller.setDopplerFactor(2.0);
      expect(controller.dopplerFactor, 2.0);
      expect(lastDopplerFactor, 2.0);

      controller.setSpeedOfSound(340.0);
      expect(controller.speedOfSound, 340.0);
      expect(lastSpeedOfSound, 340.0);

      // Validation errors
      expect(() => controller.setDopplerFactor(-0.5), throwsArgumentError);
      expect(() => controller.setDopplerFactor(double.nan), throwsArgumentError);
      expect(() => controller.setSpeedOfSound(0.0), throwsArgumentError);
      expect(() => controller.setSpeedOfSound(-10.0), throwsArgumentError);
    });
  });
}
