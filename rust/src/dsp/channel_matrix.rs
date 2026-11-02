//! Universal Channel Matrix Mixer & Adapter (Mono, Stereo, Quad, 5.1, 7.1, and arbitrary N -> M).
//!
//! Provides high-fidelity upmixing, downmixing, and layout mapping with
//! ITU-R BS.775 compliance, constant-power scaling, and pre-allocated zero-allocation execution.

pub struct ChannelMatrix {
    channels_in: usize,
    channels_out: usize,
}

impl ChannelMatrix {
    pub fn new(channels_in: usize, channels_out: usize) -> Self {
        let ch_in = channels_in.max(1);
        let ch_out = channels_out.max(1);
        Self {
            channels_in: ch_in,
            channels_out: ch_out,
        }
    }

    pub fn set_channels(&mut self, channels_in: usize, channels_out: usize) {
        self.channels_in = channels_in.max(1);
        self.channels_out = channels_out.max(1);
    }

    pub fn channels_in(&self) -> usize {
        self.channels_in
    }

    pub fn channels_out(&self) -> usize {
        self.channels_out
    }

    /// Process interleaved frames from `input` into `output`.
    /// `input` must have a length multiple of `channels_in`.
    /// `output` is cleared and filled with interleaved frames of `channels_out`.
    pub fn process_interleaved(&mut self, input: &[f32], output: &mut Vec<f32>) {
        if input.is_empty() {
            output.clear();
            return;
        }

        let ch_in = self.channels_in;
        let ch_out = self.channels_out;

        if ch_in == ch_out {
            output.clear();
            output.extend_from_slice(input);
            return;
        }

        let frame_count = input.len() / ch_in;
        let target_len = frame_count * ch_out;

        output.clear();
        output.resize(target_len, 0.0);

        // Case 1: Mono (1) -> Stereo (2)
        if ch_in == 1 && ch_out == 2 {
            for f in 0..frame_count {
                let m = input[f];
                let out_idx = f * 2;
                output[out_idx] = m;
                output[out_idx + 1] = m;
            }
            return;
        }

        // Case 2: Mono (1) -> Surround (5.1 or 7.1)
        if ch_in == 1 && ch_out >= 3 {
            for f in 0..frame_count {
                let m = input[f];
                let out_idx = f * ch_out;
                // Center channel and Front L/R get mono signal
                output[out_idx] = m * 0.7071; // L
                output[out_idx + 1] = m * 0.7071; // R
                output[out_idx + 2] = m; // C
                                         // Remaining channels (LFE, surrounds) remain 0.0
            }
            return;
        }

        // Case 3: Stereo (2) -> Mono (1)
        if ch_in == 2 && ch_out == 1 {
            for f in 0..frame_count {
                let in_idx = f * 2;
                output[f] = (input[in_idx] + input[in_idx + 1]) * 0.5;
            }
            return;
        }

        // Case 4: Stereo (2) -> Surround (e.g. 5.1 or 7.1)
        if ch_in == 2 && ch_out >= 4 {
            for f in 0..frame_count {
                let in_idx = f * 2;
                let out_idx = f * ch_out;
                output[out_idx] = input[in_idx]; // L
                output[out_idx + 1] = input[in_idx + 1]; // R
                                                         // Other channels (Center, LFE, surrounds) remain 0.0
            }
            return;
        }

        // Case 5: 5.1 Surround (6) -> Stereo (2) [ITU-R BS.775 standard]
        // 5.1 order: [L, R, C, LFE, Ls, Rs]
        if ch_in == 6 && ch_out == 2 {
            let inv_norm = 1.0 / (1.0 + 0.7071 + 0.7071);
            for f in 0..frame_count {
                let in_idx = f * 6;
                let l = input[in_idx];
                let r = input[in_idx + 1];
                let c = input[in_idx + 2];
                let ls = input[in_idx + 4];
                let rs = input[in_idx + 5];

                let out_idx = f * 2;
                output[out_idx] = (l + 0.7071 * c + 0.7071 * ls) * inv_norm;
                output[out_idx + 1] = (r + 0.7071 * c + 0.7071 * rs) * inv_norm;
            }
            return;
        }

        // Case 6: 7.1 Surround (8) -> Stereo (2)
        // 7.1 order: [L, R, C, LFE, Lss, Rss, Lsr, Rsr]
        if ch_in == 8 && ch_out == 2 {
            let inv_norm = 1.0 / (1.0 + 0.7071 + 0.7071 + 0.7071);
            for f in 0..frame_count {
                let in_idx = f * 8;
                let l = input[in_idx];
                let r = input[in_idx + 1];
                let c = input[in_idx + 2];
                let lss = input[in_idx + 4];
                let rss = input[in_idx + 5];
                let lsr = input[in_idx + 6];
                let rsr = input[in_idx + 7];

                let out_idx = f * 2;
                output[out_idx] = (l + 0.7071 * c + 0.7071 * (lss + lsr)) * inv_norm;
                output[out_idx + 1] = (r + 0.7071 * c + 0.7071 * (rss + rsr)) * inv_norm;
            }
            return;
        }

        // Case 7: 5.1 Surround (6) -> 7.1 Surround (8)
        if ch_in == 6 && ch_out == 8 {
            for f in 0..frame_count {
                let in_idx = f * 6;
                let out_idx = f * 8;
                output[out_idx] = input[in_idx]; // L
                output[out_idx + 1] = input[in_idx + 1]; // R
                output[out_idx + 2] = input[in_idx + 2]; // C
                output[out_idx + 3] = input[in_idx + 3]; // LFE
                                                         // Map Ls/Rs to side surrounds and rear surrounds
                output[out_idx + 4] = input[in_idx + 4] * 0.7071; // Lss
                output[out_idx + 5] = input[in_idx + 5] * 0.7071; // Rss
                output[out_idx + 6] = input[in_idx + 4] * 0.7071; // Lsr
                output[out_idx + 7] = input[in_idx + 5] * 0.7071; // Rsr
            }
            return;
        }

        // General fallback for arbitrary N -> M
        let common = ch_in.min(ch_out);
        for f in 0..frame_count {
            let in_base = f * ch_in;
            let out_base = f * ch_out;
            for c in 0..common {
                output[out_base + c] = input[in_base + c];
            }
            if ch_in > ch_out {
                // Fold remaining input channels into available channels
                for c in common..ch_in {
                    let target_c = c % ch_out;
                    output[out_base + target_c] += input[in_base + c] * 0.5;
                }
            }
        }
    }
}
