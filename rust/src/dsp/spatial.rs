//! 3D Spatial Audio & Doppler Effect DSP Processor.
//!
//! Provides vector math, distance attenuation models, directional sound cones,
//! azimuth stereo panning, and physical Doppler pitch shifting with anti-click smoothing.

use std::f32::consts::PI;

/// 3D Vector representing positions, velocities, and directional vectors.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
#[repr(C)]
pub struct Vector3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vector3 {
    #[inline]
    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }

    #[inline]
    pub const fn zero() -> Self {
        Self { x: 0.0, y: 0.0, z: 0.0 }
    }

    #[inline]
    pub fn dot(&self, other: &Self) -> f32 {
        self.x * other.x + self.y * other.y + self.z * other.z
    }

    #[inline]
    pub fn cross(&self, other: &Self) -> Self {
        Self {
            x: self.y * other.z - self.z * other.y,
            y: self.z * other.x - self.x * other.z,
            z: self.x * other.y - self.y * other.x,
        }
    }

    #[inline]
    pub fn length_squared(&self) -> f32 {
        self.x * self.x + self.y * self.y + self.z * self.z
    }

    #[inline]
    pub fn length(&self) -> f32 {
        self.length_squared().sqrt()
    }

    #[inline]
    pub fn normalize(&self) -> Self {
        let len = self.length();
        if len > 1e-6 {
            Self {
                x: self.x / len,
                y: self.y / len,
                z: self.z / len,
            }
        } else {
            Self::zero()
        }
    }

    #[inline]
    pub fn sub(&self, other: &Self) -> Self {
        Self {
            x: self.x - other.x,
            y: self.y - other.y,
            z: self.z - other.z,
        }
    }

    #[inline]
    pub fn add(&self, other: &Self) -> Self {
        Self {
            x: self.x + other.x,
            y: self.y + other.y,
            z: self.z + other.z,
        }
    }

    #[inline]
    pub fn scale(&self, s: f32) -> Self {
        Self {
            x: self.x * s,
            y: self.y * s,
            z: self.z * s,
        }
    }
}

/// Standard distance attenuation curve models.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(i32)]
pub enum DistanceModel {
    #[default]
    Inverse = 0,
    Linear = 1,
    Exponential = 2,
}

/// 3D Spatial Listener parameters (representing the player or camera).
#[derive(Debug, Clone, Copy)]
pub struct SpatialListener {
    pub position: Vector3,
    pub velocity: Vector3,
    pub forward: Vector3,
    pub up: Vector3,
}

impl Default for SpatialListener {
    fn default() -> Self {
        Self {
            position: Vector3::zero(),
            velocity: Vector3::zero(),
            forward: Vector3::new(0.0, 0.0, -1.0),
            up: Vector3::new(0.0, 1.0, 0.0),
        }
    }
}

/// 3D Spatial Sound Emitter parameters (source of the audio).
#[derive(Debug, Clone, Copy)]
pub struct SpatialEmitter {
    pub position: Vector3,
    pub velocity: Vector3,
    pub direction: Option<Vector3>,
    pub min_distance: f32,
    pub max_distance: f32,
    pub rolloff_factor: f32,
    pub doppler_factor: f32,
    pub inner_angle_rad: f32,
    pub outer_angle_rad: f32,
    pub outer_gain: f32,
    pub distance_model: DistanceModel,
}

impl Default for SpatialEmitter {
    fn default() -> Self {
        Self {
            position: Vector3::zero(),
            velocity: Vector3::zero(),
            direction: None,
            min_distance: 1.0,
            max_distance: 1000.0,
            rolloff_factor: 1.0,
            doppler_factor: 1.0,
            inner_angle_rad: PI * 2.0,
            outer_angle_rad: PI * 2.0,
            outer_gain: 0.0,
            distance_model: DistanceModel::Inverse,
        }
    }
}

/// Calculated target parameters for 3D spatial rendering.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SpatialEvaluation {
    /// Pitch multiplication ratio from Doppler effect (1.0 = unchanged).
    pub doppler_ratio: f32,
    /// Linear volume gain factor from distance attenuation & sound cone ([0.0, 1.0]).
    pub gain: f32,
    /// Stereo panning position between -1.0 (hard left) and +1.0 (hard right).
    pub pan: f32,
    /// Distance between emitter and listener in world units.
    pub distance: f32,
}

/// Real-time 3D spatial processor providing mathematical calculations and slew-rate smoothing.
#[derive(Debug, Clone)]
pub struct SpatialProcessor {
    pub speed_of_sound: f32,
    current_doppler_ratio: f32,
    current_gain: f32,
    current_pan: f32,
    enabled: bool,
}

impl Default for SpatialProcessor {
    fn default() -> Self {
        Self::new(343.3)
    }
}

impl SpatialProcessor {
    pub fn new(speed_of_sound: f32) -> Self {
        Self {
            speed_of_sound: if speed_of_sound > 1.0 { speed_of_sound } else { 343.3 },
            current_doppler_ratio: 1.0,
            current_gain: 1.0,
            current_pan: 0.0,
            enabled: false,
        }
    }

    #[inline]
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    #[inline]
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.current_doppler_ratio = 1.0;
            self.current_gain = 1.0;
            self.current_pan = 0.0;
        }
    }

    /// Evaluates exact instant 3D physical parameters without smoothing.
    pub fn evaluate(
        listener: &SpatialListener,
        emitter: &SpatialEmitter,
        speed_of_sound: f32,
    ) -> SpatialEvaluation {
        let displacement = listener.position.sub(&emitter.position);
        let distance = displacement.length();

        // 1. Direction vector from emitter to listener
        let r_hat = if distance > 1e-4 {
            displacement.normalize()
        } else {
            Vector3::zero()
        };

        // 2. Doppler Effect calculation
        let doppler_ratio = if emitter.doppler_factor > 0.0 && distance > 1e-4 {
            let c = speed_of_sound.max(10.0);
            let max_v = 0.9 * c;

            // Projection of velocities onto line of sight (emitter -> listener)
            let vl_proj = listener.velocity.dot(&r_hat).clamp(-max_v, max_v);
            let ve_proj = emitter.velocity.dot(&r_hat).clamp(-max_v, max_v);

            let raw_ratio = (c - vl_proj) / (c - ve_proj);
            let scaled = 1.0 + emitter.doppler_factor * (raw_ratio - 1.0);
            scaled.clamp(0.1, 4.0)
        } else {
            1.0
        };

        // 3. Distance Attenuation
        let min_d = emitter.min_distance.max(0.001);
        let max_d = emitter.max_distance.max(min_d);
        let clamped_d = distance.clamp(min_d, max_d);
        let rolloff = emitter.rolloff_factor.max(0.0);

        let distance_gain = match emitter.distance_model {
            DistanceModel::Inverse => {
                min_d / (min_d + rolloff * (clamped_d - min_d))
            }
            DistanceModel::Linear => {
                (1.0 - rolloff * (clamped_d - min_d) / (max_d - min_d)).clamp(0.0, 1.0)
            }
            DistanceModel::Exponential => {
                if distance <= min_d {
                    1.0
                } else {
                    (clamped_d / min_d).powf(-rolloff).clamp(0.0, 1.0)
                }
            }
        };

        // 4. Directional Cone Gain
        let cone_gain = if let Some(dir) = emitter.direction {
            let emitter_dir = dir.normalize();
            if emitter_dir.length_squared() > 1e-6 && distance > 1e-4 {
                // Vector from emitter to listener
                let to_listener = r_hat;
                let dot = emitter_dir.dot(&to_listener).clamp(-1.0, 1.0);
                let angle = dot.acos(); // in radians [0, PI]

                let inner = emitter.inner_angle_rad * 0.5;
                let outer = emitter.outer_angle_rad * 0.5;

                if angle <= inner {
                    1.0
                } else if angle >= outer {
                    emitter.outer_gain.clamp(0.0, 1.0)
                } else {
                    let t = (angle - inner) / (outer - inner).max(1e-6);
                    1.0 - (1.0 - emitter.outer_gain.clamp(0.0, 1.0)) * t
                }
            } else {
                1.0
            }
        } else {
            1.0
        };

        let total_gain = (distance_gain * cone_gain).clamp(0.0, 1.0);

        // 5. Azimuth 3D Panning
        let pan = if distance > 1e-4 {
            let fwd = listener.forward.normalize();
            let up = listener.up.normalize();
            let right = fwd.cross(&up).normalize();

            // Direction from listener to emitter
            let to_emitter = r_hat.scale(-1.0);
            to_emitter.dot(&right).clamp(-1.0, 1.0)
        } else {
            0.0
        };

        SpatialEvaluation {
            doppler_ratio,
            gain: total_gain,
            pan,
            distance,
        }
    }

    /// Smooths current state toward target evaluation via first-order filter.
    /// `dt_seconds` is typically buffer_frames / sample_rate (e.g. 512 / 48000 ≈ 0.0106s).
    pub fn update_smoothed(&mut self, target: &SpatialEvaluation, dt_seconds: f32) {
        // Time constant tau ≈ 20ms for smooth, click-free parameter transitions
        let tau = 0.020;
        let alpha = (1.0 - (-dt_seconds / tau).exp()).clamp(0.01, 1.0);

        self.current_doppler_ratio += alpha * (target.doppler_ratio - self.current_doppler_ratio);
        self.current_gain += alpha * (target.gain - self.current_gain);
        self.current_pan += alpha * (target.pan - self.current_pan);
    }

    #[inline]
    pub fn current_doppler_ratio(&self) -> f32 {
        self.current_doppler_ratio
    }

    #[inline]
    pub fn current_gain(&self) -> f32 {
        self.current_gain
    }

    #[inline]
    pub fn current_pan(&self) -> f32 {
        self.current_pan
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vector3_operations() {
        let v1 = Vector3::new(1.0, 2.0, 3.0);
        let v2 = Vector3::new(4.0, 5.0, 6.0);

        assert_eq!(v1.add(&v2), Vector3::new(5.0, 7.0, 9.0));
        assert_eq!(v2.sub(&v1), Vector3::new(3.0, 3.0, 3.0));
        assert_eq!(v1.dot(&v2), 4.0 + 10.0 + 18.0);

        let cross = Vector3::new(1.0, 0.0, 0.0).cross(&Vector3::new(0.0, 1.0, 0.0));
        assert_eq!(cross, Vector3::new(0.0, 0.0, 1.0));

        let norm = Vector3::new(3.0, 4.0, 0.0).normalize();
        assert!((norm.length() - 1.0).abs() < 1e-5);
        assert!((norm.x - 0.6).abs() < 1e-5);
        assert!((norm.y - 0.8).abs() < 1e-5);
    }

    #[test]
    fn test_doppler_stationary_is_identity() {
        let listener = SpatialListener::default();
        let mut emitter = SpatialEmitter::default();
        emitter.position = Vector3::new(0.0, 0.0, 10.0);

        let eval = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
        assert!((eval.doppler_ratio - 1.0).abs() < 1e-4);
        assert!((eval.distance - 10.0).abs() < 1e-4);
        assert!((eval.pan - 0.0).abs() < 1e-4);
    }

    #[test]
    fn test_doppler_emitter_approaching_increases_pitch() {
        let listener = SpatialListener::default(); // At (0, 0, 0), v = 0
        let mut emitter = SpatialEmitter::default();
        emitter.position = Vector3::new(0.0, 0.0, 100.0);
        // Emitter moving toward listener at 34.33 m/s (0.1 c) along -Z
        emitter.velocity = Vector3::new(0.0, 0.0, -34.33);

        let eval = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
        // Expected ratio: 343.3 / (343.3 - 34.33) = 1.0 / 0.9 ≈ 1.1111
        assert!(eval.doppler_ratio > 1.10 && eval.doppler_ratio < 1.12);
    }

    #[test]
    fn test_doppler_emitter_receding_decreases_pitch() {
        let listener = SpatialListener::default();
        let mut emitter = SpatialEmitter::default();
        emitter.position = Vector3::new(0.0, 0.0, 100.0);
        // Emitter moving away from listener at 34.33 m/s along +Z
        emitter.velocity = Vector3::new(0.0, 0.0, 34.33);

        let eval = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
        // Expected ratio: 343.3 / (343.3 + 34.33) = 1.0 / 1.1 ≈ 0.9090
        assert!(eval.doppler_ratio > 0.90 && eval.doppler_ratio < 0.92);
    }

    #[test]
    fn test_doppler_factor_zero_disables_pitch_shift() {
        let listener = SpatialListener::default();
        let mut emitter = SpatialEmitter::default();
        emitter.position = Vector3::new(0.0, 0.0, 100.0);
        emitter.velocity = Vector3::new(0.0, 0.0, -100.0);
        emitter.doppler_factor = 0.0;

        let eval = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
        assert_eq!(eval.doppler_ratio, 1.0);
    }

    #[test]
    fn test_doppler_supersonic_clamping_prevents_nan_or_inversion() {
        let listener = SpatialListener::default();
        let mut emitter = SpatialEmitter::default();
        emitter.position = Vector3::new(0.0, 0.0, 100.0);
        // Mach 2.0 approaching velocity
        emitter.velocity = Vector3::new(0.0, 0.0, -700.0);

        let eval = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
        assert!(!eval.doppler_ratio.is_nan());
        assert!(!eval.doppler_ratio.is_infinite());
        assert!(eval.doppler_ratio <= 4.0);
        assert!(eval.doppler_ratio >= 0.1);
    }

    #[test]
    fn test_azimuth_panning_left_and_right() {
        // Listener at (0, 0, 0) looking at (0, 0, -1) with Up (0, 1, 0)
        // Right vector is (1, 0, 0)
        let listener = SpatialListener::default();

        let mut emitter_right = SpatialEmitter::default();
        emitter_right.position = Vector3::new(10.0, 0.0, 0.0);
        let eval_r = SpatialProcessor::evaluate(&listener, &emitter_right, 343.3);
        assert!((eval_r.pan - 1.0).abs() < 1e-4, "Expected pan=1.0 on right, got {}", eval_r.pan);

        let mut emitter_left = SpatialEmitter::default();
        emitter_left.position = Vector3::new(-10.0, 0.0, 0.0);
        let eval_l = SpatialProcessor::evaluate(&listener, &emitter_left, 343.3);
        assert!((eval_l.pan - (-1.0)).abs() < 1e-4, "Expected pan=-1.0 on left, got {}", eval_l.pan);
    }

    #[test]
    fn test_distance_attenuation_models() {
        let listener = SpatialListener::default();
        let mut emitter = SpatialEmitter::default();
        emitter.min_distance = 10.0;
        emitter.max_distance = 100.0;
        emitter.rolloff_factor = 1.0;

        // At min_distance, all models should have gain 1.0
        emitter.position = Vector3::new(0.0, 0.0, 10.0);
        let eval_min = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
        assert!((eval_min.gain - 1.0).abs() < 1e-4);

        // At double distance (20.0), inverse model should be 10 / (10 + 1*(20-10)) = 0.5
        emitter.position = Vector3::new(0.0, 0.0, 20.0);
        let eval_inv = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
        assert!((eval_inv.gain - 0.5).abs() < 1e-4);

        // Linear model at 55.0 (midway 10..100)
        emitter.distance_model = DistanceModel::Linear;
        emitter.position = Vector3::new(0.0, 0.0, 55.0);
        let eval_lin = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
        assert!((eval_lin.gain - 0.5).abs() < 1e-3);
    }

    #[test]
    fn test_slew_rate_smoothing() {
        let mut proc = SpatialProcessor::new(343.3);
        let target = SpatialEvaluation {
            doppler_ratio: 1.5,
            gain: 0.2,
            pan: 0.8,
            distance: 50.0,
        };

        // One buffer tick of 10ms
        proc.update_smoothed(&target, 0.010);
        assert!(proc.current_doppler_ratio() > 1.0 && proc.current_doppler_ratio() < 1.5);
        assert!(proc.current_gain() < 1.0 && proc.current_gain() > 0.2);
        assert!(proc.current_pan() > 0.0 && proc.current_pan() < 0.8);

        // Many ticks -> converges to target
        for _ in 0..50 {
            proc.update_smoothed(&target, 0.010);
        }
        assert!((proc.current_doppler_ratio() - 1.5).abs() < 1e-2);
        assert!((proc.current_gain() - 0.2).abs() < 1e-2);
        assert!((proc.current_pan() - 0.8).abs() < 1e-2);
    }
}
