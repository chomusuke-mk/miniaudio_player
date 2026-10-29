#[inline(always)]
pub fn process_limiter_sample(x: f32) -> f32 {
    let abs_x = x.abs();
    if abs_x <= 0.95 {
        x
    } else {
        let sign = if x < 0.0 { -1.0 } else { 1.0 };
        sign * (0.95 + 0.046 * ((abs_x - 0.95) / 0.046).tanh()).min(0.996)
    }
}
