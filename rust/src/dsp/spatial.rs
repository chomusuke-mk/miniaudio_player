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
        Self {
            x: 0.0,
            y: 0.0,
            z: 0.0,
        }
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
            speed_of_sound: if speed_of_sound > 1.0 {
                speed_of_sound
            } else {
                343.3
            },
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
            DistanceModel::Inverse => min_d / (min_d + rolloff * (clamped_d - min_d)),
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
