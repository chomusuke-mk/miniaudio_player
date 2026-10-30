//! Pure Rust port of the Sonic time-stretching and pitch-shifting algorithm by Bill Cox.
//! Implements PICOLA / WSOLA with equal-power crossfade and windowed sinc resampling.

use std::f32::consts::PI;

pub const SONIC_MIN_PITCH: usize = 22;
pub const SONIC_MAX_PITCH: usize = 400;
pub const SONIC_AMDF_FREQ: usize = 4000;

pub const SONIC_MIN_SPEED: f32 = 0.05;
pub const SONIC_MAX_SPEED: f32 = 20.0;
pub const SONIC_MIN_PITCH_SETTING: f32 = 0.05;
pub const SONIC_MAX_PITCH_SETTING: f32 = 20.0;
pub const SONIC_MIN_RATE: f32 = 0.05;
pub const SONIC_MAX_RATE: f32 = 20.0;

const SINC_FILTER_POINTS: usize = 12;
const SINC_TABLE_SIZE: usize = 601;

static SINC_TABLE: [i16; SINC_TABLE_SIZE] = [
    0, 0, 0, 0, 0, 0, 0, -1, -1, -2, -2,
    -3, -4, -6, -7, -9, -10, -12, -14, -17, -19, -21,
    -24, -26, -29, -32, -34, -37, -40, -42, -44, -47, -48,
    -50, -51, -52, -53, -53, -53, -52, -50, -48, -46, -43,
    -39, -34, -29, -22, -16, -8, 0, 9, 19, 29, 41,
    53, 65, 79, 92, 107, 121, 137, 152, 168, 184, 200,
    215, 231, 247, 262, 276, 291, 304, 317, 328, 339, 348,
    357, 363, 369, 372, 374, 375, 373, 369, 363, 355, 345,
    332, 318, 300, 281, 259, 234, 208, 178, 147, 113, 77,
    39, 0, -41, -85, -130, -177, -225, -274, -324, -375, -426,
    -478, -530, -581, -632, -682, -731, -779, -825, -870, -912, -951,
    -989, -1023, -1053, -1080, -1104, -1123, -1138, -1149, -1154, -1155, -1151,
    -1141, -1125, -1105, -1078, -1046, -1007, -963, -913, -857, -796, -728,
    -655, -576, -492, -403, -309, -210, -107, 0, 111, 225, 342,
    462, 584, 708, 833, 958, 1084, 1209, 1333, 1455, 1575, 1693,
    1807, 1916, 2022, 2122, 2216, 2304, 2384, 2457, 2522, 2579, 2625,
    2663, 2689, 2706, 2711, 2705, 2687, 2657, 2614, 2559, 2491, 2411,
    2317, 2211, 2092, 1960, 1815, 1658, 1489, 1308, 1115, 912, 698,
    474, 241, 0, -249, -506, -769, -1037, -1310, -1586, -1864, -2144,
    -2424, -2703, -2980, -3254, -3523, -3787, -4043, -4291, -4529, -4757, -4972,
    -5174, -5360, -5531, -5685, -5819, -5935, -6029, -6101, -6150, -6175, -6175,
    -6149, -6096, -6015, -5905, -5767, -5599, -5401, -5172, -4912, -4621, -4298,
    -3944, -3558, -3141, -2693, -2214, -1705, -1166, -597, 0, 625, 1277,
    1955, 2658, 3386, 4135, 4906, 5697, 6506, 7332, 8173, 9027, 9893,
    10769, 11654, 12544, 13439, 14335, 15232, 16128, 17019, 17904, 18782, 19649,
    20504, 21345, 22170, 22977, 23763, 24527, 25268, 25982, 26669, 27327, 27953,
    28547, 29107, 29632, 30119, 30569, 30979, 31349, 31678, 31964, 32208, 32408,
    32565, 32677, 32744, 32767, 32744, 32677, 32565, 32408, 32208, 31964, 31678,
    31349, 30979, 30569, 30119, 29632, 29107, 28547, 27953, 27327, 26669, 25982,
    25268, 24527, 23763, 22977, 22170, 21345, 20504, 19649, 18782, 17904, 17019,
    16128, 15232, 14335, 13439, 12544, 11654, 10769, 9893, 9027, 8173, 7332,
    6506, 5697, 4906, 4135, 3386, 2658, 1955, 1277, 625, 0, -597,
    -1166, -1705, -2214, -2693, -3141, -3558, -3944, -4298, -4621, -4912, -5172,
    -5401, -5599, -5767, -5905, -6015, -6096, -6149, -6175, -6175, -6150, -6101,
    -6029, -5935, -5819, -5685, -5531, -5360, -5174, -4972, -4757, -4529, -4291,
    -4043, -3787, -3523, -3254, -2980, -2703, -2424, -2144, -1864, -1586, -1310,
    -1037, -769, -506, -249, 0, 241, 474, 698, 912, 1115, 1308,
    1489, 1658, 1815, 1960, 2092, 2211, 2317, 2411, 2491, 2559, 2614,
    2657, 2687, 2705, 2711, 2706, 2689, 2663, 2625, 2579, 2522, 2457,
    2384, 2304, 2216, 2122, 2022, 1916, 1807, 1693, 1575, 1455, 1333,
    1209, 1084, 958, 833, 708, 584, 462, 342, 225, 111, 0,
    -107, -210, -309, -403, -492, -576, -655, -728, -796, -857, -913,
    -963, -1007, -1046, -1078, -1105, -1125, -1141, -1151, -1155, -1154, -1149,
    -1138, -1123, -1104, -1080, -1053, -1023, -989, -951, -912, -870, -825,
    -779, -731, -682, -632, -581, -530, -478, -426, -375, -324, -274,
    -225, -177, -130, -85, -41, 0, 39, 77, 113, 147, 178,
    208, 234, 259, 281, 300, 318, 332, 345, 355, 363, 369,
    373, 375, 374, 372, 369, 363, 357, 348, 339, 328, 317,
    304, 291, 276, 262, 247, 231, 215, 200, 184, 168, 152,
    137, 121, 107, 92, 79, 65, 53, 41, 29, 19, 9,
    0, -8, -16, -22, -29, -34, -39, -43, -46, -48, -50,
    -52, -53, -53, -53, -52, -51, -50, -48, -47, -44, -42,
    -40, -37, -34, -32, -29, -26, -24, -21, -19, -17, -14,
    -12, -10, -9, -7, -6, -4, -3, -2, -2, -1, -1,
    0, 0, 0, 0, 0, 0, 0,
];

pub struct SonicStream {
    input_buffer: Vec<i16>,
    output_buffer: Vec<i16>,
    pitch_buffer: Vec<i16>,
    down_sample_buffer: Vec<i16>,

    speed: f32,
    volume: f32,
    pitch: f32,
    rate: f32,

    old_rate_position: usize,
    new_rate_position: usize,
    quality: i32,

    num_channels: usize,
    sample_rate: usize,
    sample_period: f64,

    min_period: usize,
    max_period: usize,
    max_required: usize,

    prev_period: usize,
    prev_min_diff: usize,

    num_input_samples: usize,
    num_output_samples: usize,
    num_pitch_samples: usize,

    input_play_time: f64,
    time_error: f64,
}

impl SonicStream {
    pub fn new(sample_rate: u32, num_channels: usize) -> Self {
        let sr = (sample_rate as usize).clamp(8000, 192000);
        let ch = num_channels.clamp(1, 8);

        let min_period = sr / SONIC_MAX_PITCH;
        let max_period = sr / SONIC_MIN_PITCH;
        let max_required = 2 * max_period;

        let initial_cap = 65536.max(max_required + (max_required >> 2));

        Self {
            input_buffer: vec![0; initial_cap * ch],
            output_buffer: vec![0; initial_cap * ch],
            pitch_buffer: vec![0; initial_cap * ch],
            down_sample_buffer: vec![0; max_required],

            speed: 1.0,
            volume: 1.0,
            pitch: 1.0,
            rate: 1.0,

            old_rate_position: 0,
            new_rate_position: 0,
            quality: 0,

            num_channels: ch,
            sample_rate: sr,
            sample_period: 1.0 / sr as f64,

            min_period,
            max_period,
            max_required,

            prev_period: 0,
            prev_min_diff: 0,

            num_input_samples: 0,
            num_output_samples: 0,
            num_pitch_samples: 0,

            input_play_time: 0.0,
            time_error: 0.0,
        }
    }

    pub fn set_speed(&mut self, speed: f32) {
        self.speed = speed.clamp(SONIC_MIN_SPEED, SONIC_MAX_SPEED);
    }

    pub fn speed(&self) -> f32 {
        self.speed
    }

    pub fn set_pitch(&mut self, pitch: f32) {
        self.pitch = pitch.clamp(SONIC_MIN_PITCH_SETTING, SONIC_MAX_PITCH_SETTING);
    }

    pub fn pitch(&self) -> f32 {
        self.pitch
    }

    pub fn set_rate(&mut self, rate: f32) {
        self.rate = rate.clamp(SONIC_MIN_RATE, SONIC_MAX_RATE);
    }

    pub fn rate(&self) -> f32 {
        self.rate
    }

    pub fn set_volume(&mut self, volume: f32) {
        self.volume = volume;
    }

    pub fn set_quality(&mut self, quality: i32) {
        self.quality = quality;
    }

    pub fn reset(&mut self) {
        self.num_input_samples = 0;
        self.num_output_samples = 0;
        self.num_pitch_samples = 0;
        self.input_play_time = 0.0;
        self.time_error = 0.0;
        self.old_rate_position = 0;
        self.new_rate_position = 0;
        self.prev_period = 0;
        self.prev_min_diff = 0;
    }

    pub fn samples_available(&self) -> usize {
        self.num_output_samples
    }

    pub fn write_float(&mut self, samples: &[f32]) -> bool {
        if samples.is_empty() {
            return true;
        }

        let num_frames = samples.len() / self.num_channels;
        self.enlarge_input_buffer(num_frames);

        let start = self.num_input_samples * self.num_channels;
        for (i, &s) in samples.iter().enumerate() {
            let clamped = s.clamp(-1.0, 1.0);
            let val = if clamped >= 0.0 {
                (clamped * 32767.0 + 0.5) as i16
            } else {
                (clamped * 32767.0 - 0.5) as i16
            };
            self.input_buffer[start + i] = val;
        }

        self.update_num_input_samples(num_frames);
        self.process_stream_input()
    }

    pub fn read_float(&mut self, out_samples: &mut [f32]) -> usize {
        if self.num_output_samples == 0 || out_samples.is_empty() {
            return 0;
        }

        let max_frames = out_samples.len() / self.num_channels;
        let num_frames = self.num_output_samples.min(max_frames);
        let total_samples = num_frames * self.num_channels;

        for i in 0..total_samples {
            out_samples[i] = self.output_buffer[i] as f32 / 32767.0;
        }

        let remaining = self.num_output_samples - num_frames;
        if remaining > 0 {
            let ch = self.num_channels;
            self.output_buffer.copy_within(total_samples..total_samples + remaining * ch, 0);
        }
        self.num_output_samples = remaining;

        num_frames
    }

    pub fn flush(&mut self) -> bool {
        let max_req = self.max_required;
        let remaining = self.num_input_samples;
        let speed = self.speed / self.pitch;
        let rate = self.rate * self.pitch;
        let expected_output = self.num_output_samples
            + (((remaining as f64 / speed as f64 + self.num_pitch_samples as f64) / rate as f64) + 0.5) as usize;

        self.enlarge_input_buffer(remaining + 2 * max_req);
        let start = remaining * self.num_channels;
        let silence_len = 2 * max_req * self.num_channels;
        self.input_buffer[start..start + silence_len].fill(0);
        self.num_input_samples += 2 * max_req;

        self.process_stream_input();

        if self.num_output_samples > expected_output {
            self.num_output_samples = expected_output;
        }
        self.num_input_samples = 0;
        self.input_play_time = 0.0;
        self.time_error = 0.0;
        self.num_pitch_samples = 0;

        true
    }

    // ------------------------------------------------------------------------
    // Internal Core Engine
    // ------------------------------------------------------------------------

    fn enlarge_input_buffer(&mut self, num_frames: usize) {
        let required = (self.num_input_samples + num_frames) * self.num_channels;
        if required > self.input_buffer.len() {
            let new_cap = self.input_buffer.len() + (self.input_buffer.len() >> 1) + num_frames * self.num_channels;
            self.input_buffer.resize(new_cap, 0);
        }
    }

    fn enlarge_output_buffer(&mut self, num_frames: usize) {
        let required = (self.num_output_samples + num_frames) * self.num_channels;
        if required > self.output_buffer.len() {
            let new_cap = self.output_buffer.len() + (self.output_buffer.len() >> 1) + num_frames * self.num_channels;
            self.output_buffer.resize(new_cap, 0);
        }
    }

    fn enlarge_pitch_buffer(&mut self, num_frames: usize) {
        let required = (self.num_pitch_samples + num_frames) * self.num_channels;
        if required > self.pitch_buffer.len() {
            let new_cap = self.pitch_buffer.len() + (self.pitch_buffer.len() >> 1) + num_frames * self.num_channels;
            self.pitch_buffer.resize(new_cap, 0);
        }
    }

    fn update_num_input_samples(&mut self, num_frames: usize) {
        let speed = (self.speed / self.pitch) as f64;
        self.num_input_samples += num_frames;
        self.input_play_time += (num_frames as f64 * self.sample_period) / speed;
    }

    fn process_stream_input(&mut self) -> bool {
        let orig_output = self.num_output_samples;
        let rate = self.rate * self.pitch;

        if self.num_input_samples == 0 {
            return true;
        }

        let local_speed = if self.input_play_time <= 1e-6 || self.input_play_time.is_nan() {
            self.speed
        } else {
            let s = (self.num_input_samples as f64 * self.sample_period) / self.input_play_time;
            if s.is_nan() || s.is_infinite() {
                self.speed
            } else {
                (s as f32).clamp(SONIC_MIN_SPEED, SONIC_MAX_SPEED)
            }
        };

        if (local_speed - 1.0).abs() > 0.0001 {
            self.change_speed(local_speed);
        } else {
            self.copy_input_to_output(self.num_input_samples);
        }

        if (rate - 1.0).abs() > 0.0001 {
            self.adjust_rate(rate, orig_output);
        }

        if (self.volume - 1.0).abs() > 0.0001 {
            let ch = self.num_channels;
            for s in &mut self.output_buffer[orig_output * ch..self.num_output_samples * ch] {
                *s = (*s as f32 * self.volume).clamp(-32767.0, 32767.0) as i16;
            }
        }

        true
    }

    fn copy_input_to_output(&mut self, num_frames: usize) {
        self.enlarge_output_buffer(num_frames);
        let ch = self.num_channels;
        let dst = self.num_output_samples * ch;
        let count = num_frames * ch;
        self.output_buffer[dst..dst + count].copy_from_slice(&self.input_buffer[..count]);
        self.num_output_samples += num_frames;
        self.remove_input_samples(num_frames);
    }

    fn remove_input_samples(&mut self, position: usize) {
        let remaining = self.num_input_samples.saturating_sub(position);
        let ch = self.num_channels;
        if remaining > 0 {
            self.input_buffer.copy_within(position * ch..(position + remaining) * ch, 0);
        }
        if self.num_input_samples > 0 {
            self.input_play_time = (self.input_play_time * remaining as f64) / self.num_input_samples as f64;
        }
        self.num_input_samples = remaining;
    }

    fn change_speed(&mut self, speed: f32) {
        let num_samples = self.num_input_samples;
        let max_req = self.max_required;
        if num_samples < max_req {
            return;
        }

        let mut position = 0;

        while position + max_req <= num_samples {
            if (speed > 1.0 && speed < 2.0 && self.time_error < 0.0)
                || (speed < 1.0 && speed > 0.5 && self.time_error > 0.0)
            {
                let new_samples = self.copy_unmodified_samples(speed, position);
                if new_samples <= 0 {
                    self.time_error = 0.0;
                }
                position += new_samples.max(0) as usize;
            } else {
                let period = self.find_pitch_period(position, true);
                let new_samples = if speed > 1.0 {
                    let ns = self.skip_pitch_period(position, speed, period);
                    position += period + ns;
                    if speed < 2.0 {
                        self.time_error += ns as f64 * self.sample_period
                            - (period + ns) as f64 * self.input_play_time / self.num_input_samples as f64;
                    }
                    ns
                } else {
                    let ns = self.insert_pitch_period(position, speed, period);
                    position += ns;
                    if speed > 0.5 {
                        self.time_error += (period + ns) as f64 * self.sample_period
                            - ns as f64 * self.input_play_time / self.num_input_samples as f64;
                    }
                    ns
                };
                if new_samples == 0 {
                    break;
                }
            }
        }

        self.remove_input_samples(position);
    }

    fn copy_unmodified_samples(&mut self, speed: f32, position: usize) -> isize {
        let available = self.num_input_samples - position;
        let input_to_copy = 1.0 - self.time_error * speed as f64 / (self.sample_period * (speed as f64 - 1.0));

        let new_samples = if input_to_copy.is_nan() || input_to_copy.is_infinite() || input_to_copy < 0.0 {
            0
        } else if input_to_copy > available as f64 {
            available
        } else {
            input_to_copy as usize
        };

        if new_samples > 0 {
            self.enlarge_output_buffer(new_samples);
            let ch = self.num_channels;
            let src = position * ch;
            let dst = self.num_output_samples * ch;
            let count = new_samples * ch;
            self.output_buffer[dst..dst + count].copy_from_slice(&self.input_buffer[src..src + count]);
            self.num_output_samples += new_samples;
            self.time_error += new_samples as f64 * self.sample_period * (speed as f64 - 1.0) / speed as f64;
        }

        new_samples as isize
    }

    fn skip_pitch_period(&mut self, position: usize, speed: f32, period: usize) -> usize {
        let new_samples = if speed >= 2.0 {
            (period as f32 / (speed - 1.0)) as usize
        } else {
            period
        };

        self.enlarge_output_buffer(new_samples);
        let ch = self.num_channels;
        let out_start = self.num_output_samples * ch;
        let ramp_down_start = position * ch;
        let ramp_up_start = (position + period) * ch;

        Self::overlap_add(
            new_samples,
            ch,
            &mut self.output_buffer[out_start..out_start + new_samples * ch],
            &self.input_buffer[ramp_down_start..ramp_down_start + new_samples * ch],
            &self.input_buffer[ramp_up_start..ramp_up_start + new_samples * ch],
        );

        self.num_output_samples += new_samples;
        new_samples
    }

    fn insert_pitch_period(&mut self, position: usize, speed: f32, period: usize) -> usize {
        let new_samples = if speed <= 0.5 {
            ((period as f32 * speed) / (1.0 - speed)) as usize
        } else {
            period
        };

        self.enlarge_output_buffer(period + new_samples);
        let ch = self.num_channels;
        let src = position * ch;
        let out_start = self.num_output_samples * ch;

        // Copy period unmodified
        self.output_buffer[out_start..out_start + period * ch]
            .copy_from_slice(&self.input_buffer[src..src + period * ch]);

        // Overlap add
        let out_overlap = out_start + period * ch;
        let ramp_down_start = (position + period) * ch;
        let ramp_up_start = position * ch;

        Self::overlap_add(
            new_samples,
            ch,
            &mut self.output_buffer[out_overlap..out_overlap + new_samples * ch],
            &self.input_buffer[ramp_down_start..ramp_down_start + new_samples * ch],
            &self.input_buffer[ramp_up_start..ramp_up_start + new_samples * ch],
        );

        self.num_output_samples += period + new_samples;
        new_samples
    }

    fn overlap_add(
        num_samples: usize,
        num_channels: usize,
        out: &mut [i16],
        ramp_down: &[i16],
        ramp_up: &[i16],
    ) {
        if num_samples == 0 {
            return;
        }

        let inv_n = 1.0 / num_samples as f32;
        for t in 0..num_samples {
            let x = t as f32 * inv_n;
            let gain_up = (0.5 * PI * x).sin();
            let gain_down = (0.5 * PI * x).cos();

            for c in 0..num_channels {
                let idx = t * num_channels + c;
                let val = ramp_down[idx] as f32 * gain_down + ramp_up[idx] as f32 * gain_up;
                let clamped = val.clamp(-32767.0, 32767.0);
                out[idx] = if clamped >= 0.0 {
                    (clamped + 0.5) as i16
                } else {
                    (clamped - 0.5) as i16
                };
            }
        }
    }

    fn find_pitch_period(&mut self, position: usize, prefer_new_period: bool) -> usize {
        let min_period = self.min_period;
        let max_period = self.max_period;
        let skip = if self.sample_rate > SONIC_AMDF_FREQ && self.quality == 0 {
            self.sample_rate / SONIC_AMDF_FREQ
        } else {
            1
        };

        let ch = self.num_channels;
        let (period, min_diff, max_diff) = if ch == 1 && skip == 1 {
            Self::find_pitch_period_in_range(&self.input_buffer[position..], min_period, max_period)
        } else {
            self.down_sample_input(position, skip);
            let (mut p, min_d, max_d) = Self::find_pitch_period_in_range(
                &self.down_sample_buffer,
                min_period / skip,
                max_period / skip,
            );
            if skip != 1 {
                p *= skip;
                let min_p = p.saturating_sub(skip << 2).max(self.min_period);
                let max_p = (p + (skip << 2)).min(self.max_period);
                if ch == 1 {
                    let (rp, rmin, rmax) = Self::find_pitch_period_in_range(
                        &self.input_buffer[position..],
                        min_p,
                        max_p,
                    );
                    (rp, rmin, rmax)
                } else {
                    self.down_sample_input(position, 1);
                    let (rp, rmin, rmax) = Self::find_pitch_period_in_range(
                        &self.down_sample_buffer,
                        min_p,
                        max_p,
                    );
                    (rp, rmin, rmax)
                }
            } else {
                (p, min_d, max_d)
            }
        };

        let ret_period = if self.prev_period_better(min_diff, max_diff, prefer_new_period) {
            self.prev_period
        } else {
            period
        };

        self.prev_min_diff = min_diff;
        self.prev_period = period;
        ret_period
    }

    fn down_sample_input(&mut self, position: usize, skip: usize) {
        let num_samples = self.max_required / skip;
        let samples_per_val = self.num_channels * skip;
        let ch = self.num_channels;

        for i in 0..num_samples {
            let mut sum: i32 = 0;
            let base = position * ch + i * samples_per_val;
            for j in 0..samples_per_val {
                sum += self.input_buffer[base + j] as i32;
            }
            self.down_sample_buffer[i] = (sum / samples_per_val as i32) as i16;
        }
    }

    fn find_pitch_period_in_range(
        samples: &[i16],
        min_period: usize,
        max_period: usize,
    ) -> (usize, usize, usize) {
        let mut best_period = 0;
        let mut worst_period = 255;
        let mut min_diff: u64 = 1;
        let mut max_diff: u64 = 0;

        for period in min_period..=max_period {
            let mut diff: u64 = 0;
            for i in 0..period {
                let s_val = samples[i] as i32;
                let p_val = samples[i + period] as i32;
                diff += (s_val - p_val).unsigned_abs() as u64;
            }

            if best_period == 0 || diff * (best_period as u64) < min_diff * (period as u64) {
                min_diff = diff;
                best_period = period;
            }
            if diff * (worst_period as u64) > max_diff * (period as u64) {
                max_diff = diff;
                worst_period = period;
            }
        }

        let ret_min = (min_diff / best_period.max(1) as u64) as usize;
        let ret_max = (max_diff / worst_period.max(1) as u64) as usize;
        (best_period, ret_min, ret_max)
    }

    fn prev_period_better(&self, min_diff: usize, max_diff: usize, prefer_new: bool) -> bool {
        if min_diff == 0 || self.prev_period == 0 {
            return false;
        }
        if prefer_new {
            if max_diff > min_diff * 3 {
                return false;
            }
            if min_diff * 2 <= self.prev_min_diff * 3 {
                return false;
            }
        } else if min_diff <= self.prev_min_diff {
            return false;
        }
        true
    }

    fn adjust_rate(&mut self, rate: f32, orig_output: usize) {
        if (rate - 1.0).abs() < 1e-4 || rate <= 0.01 {
            return;
        }

        let mut new_srate = (self.sample_rate as f32 / rate) as usize;
        let mut old_srate = self.sample_rate;

        while new_srate > (1 << 14) || old_srate > (1 << 14) {
            new_srate >>= 1;
            old_srate >>= 1;
        }
        new_srate = new_srate.max(1);
        old_srate = old_srate.max(1);

        if self.num_output_samples == orig_output {
            return;
        }

        self.move_new_samples_to_pitch_buffer(orig_output);

        let ch = self.num_channels;
        let mut position = 0;
        let n = SINC_FILTER_POINTS;

        while position + n < self.num_pitch_samples {
            while (self.old_rate_position + 1) * new_srate > self.new_rate_position * old_srate {
                self.enlarge_output_buffer(1);
                let out_idx = self.num_output_samples * ch;
                let in_idx = position * ch;

                for c in 0..ch {
                    self.output_buffer[out_idx + c] =
                        self.interpolate(in_idx + c, old_srate, new_srate);
                }

                self.new_rate_position += 1;
                self.num_output_samples += 1;
            }

            self.old_rate_position += 1;
            if self.old_rate_position == old_srate {
                self.old_rate_position = 0;
                self.new_rate_position = 0;
            }
            position += 1;
        }

        self.remove_pitch_samples(position);
    }

    fn move_new_samples_to_pitch_buffer(&mut self, orig_output: usize) {
        let num_samples = self.num_output_samples - orig_output;
        if num_samples == 0 {
            return;
        }

        self.enlarge_pitch_buffer(num_samples);
        let ch = self.num_channels;
        let dst = self.num_pitch_samples * ch;
        let src = orig_output * ch;
        let count = num_samples * ch;

        self.pitch_buffer[dst..dst + count].copy_from_slice(&self.output_buffer[src..src + count]);
        self.num_output_samples = orig_output;
        self.num_pitch_samples += num_samples;
    }

    fn remove_pitch_samples(&mut self, num_samples: usize) {
        if num_samples == 0 {
            return;
        }
        let ch = self.num_channels;
        if num_samples < self.num_pitch_samples {
            let src = num_samples * ch;
            let count = (self.num_pitch_samples - num_samples) * ch;
            self.pitch_buffer.copy_within(src..src + count, 0);
        }
        self.num_pitch_samples -= num_samples;
    }

    fn interpolate(&self, in_offset: usize, old_srate: usize, new_srate: usize) -> i16 {
        let ch = self.num_channels;
        let position = self.new_rate_position * old_srate;
        let left_position = self.old_rate_position * new_srate;
        let right_position = (self.old_rate_position + 1) * new_srate;
        let ratio = right_position.saturating_sub(position).saturating_sub(1);
        let width = right_position.saturating_sub(left_position).max(1);

        let mut total: i64 = 0;
        for i in 0..SINC_FILTER_POINTS {
            let weight = Self::find_sinc_coeff(i, ratio, width);
            let sample_idx = in_offset + i * ch;
            let sample_val = if sample_idx < self.pitch_buffer.len() {
                self.pitch_buffer[sample_idx] as i64
            } else {
                0
            };
            total += sample_val * weight as i64;
        }

        let res = total >> 16;
        res.clamp(i16::MIN as i64, i16::MAX as i64) as i16
    }

    fn find_sinc_coeff(i: usize, ratio: usize, width: usize) -> i32 {
        if width == 0 {
            return 0;
        }
        let lobe_points = (SINC_TABLE_SIZE - 1) / SINC_FILTER_POINTS;
        let left = (i * lobe_points + (ratio * lobe_points) / width).min(SINC_TABLE_SIZE - 1);
        let right = (left + 1).min(SINC_TABLE_SIZE - 1);
        let pos = (i * lobe_points * width + ratio * lobe_points).saturating_sub(left * width);

        let left_val = SINC_TABLE[left] as i32;
        let right_val = SINC_TABLE[right] as i32;

        ((left_val * (width as i32 - pos as i32) + right_val * pos as i32) << 1) / width as i32
    }
}

// ----------------------------------------------------------------------------
// C ABI compatibility functions
// ----------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn sonicCreateStream(sample_rate: i32, num_channels: i32) -> *mut SonicStream {
    let stream = Box::new(SonicStream::new(sample_rate as u32, num_channels as usize));
    Box::into_raw(stream)
}

#[no_mangle]
pub unsafe extern "C" fn sonicDestroyStream(stream: *mut SonicStream) {
    if !stream.is_null() {
        unsafe {
            drop(Box::from_raw(stream));
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sonicSetQuality(stream: *mut SonicStream, quality: i32) {
    if !stream.is_null() {
        unsafe {
            (*stream).set_quality(quality);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sonicSetSpeed(stream: *mut SonicStream, speed: f32) {
    if !stream.is_null() {
        unsafe {
            (*stream).set_speed(speed);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sonicSetPitch(stream: *mut SonicStream, pitch: f32) {
    if !stream.is_null() {
        unsafe {
            (*stream).set_pitch(pitch);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sonicSetRate(stream: *mut SonicStream, rate: f32) {
    if !stream.is_null() {
        unsafe {
            (*stream).set_rate(rate);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sonicWriteFloatToStream(
    stream: *mut SonicStream,
    samples: *const f32,
    num_samples: i32,
) -> i32 {
    if stream.is_null() || samples.is_null() || num_samples <= 0 {
        return 0;
    }
    unsafe {
        let ch = (*stream).num_channels;
        let slice = std::slice::from_raw_parts(samples, num_samples as usize * ch);
        if (*stream).write_float(slice) { 1 } else { 0 }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sonicReadFloatFromStream(
    stream: *mut SonicStream,
    samples: *mut f32,
    max_samples: i32,
) -> i32 {
    if stream.is_null() || samples.is_null() || max_samples <= 0 {
        return 0;
    }
    unsafe {
        let ch = (*stream).num_channels;
        let slice = std::slice::from_raw_parts_mut(samples, max_samples as usize * ch);
        (*stream).read_float(slice) as i32
    }
}

#[no_mangle]
pub unsafe extern "C" fn sonicSamplesAvailable(stream: *mut SonicStream) -> i32 {
    if stream.is_null() {
        0
    } else {
        unsafe { (*stream).samples_available() as i32 }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sonicFlushStream(stream: *mut SonicStream) -> i32 {
    if stream.is_null() {
        0
    } else {
        unsafe { if (*stream).flush() { 1 } else { 0 } }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sonicResetStream(stream: *mut SonicStream) {
    if !stream.is_null() {
        unsafe {
            (*stream).reset();
        }
    }
}
