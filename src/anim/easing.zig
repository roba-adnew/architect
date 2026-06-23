const std = @import("std");

pub fn easeInOutCubic(t: f32) f32 {
    if (t < 0.5) {
        return 4 * t * t * t;
    }

    const p = 2 * t - 2;
    return 1 + p * p * p / 2;
}

pub fn easeOutCubic(t: f32) f32 {
    const p = t - 1.0;
    return 1.0 + p * p * p;
}

/// Gentle symmetric ease. Peak velocity is only ~1.57x the average (vs 3.0x for
/// easeInOutCubic), so large layout reflows glide instead of leaping in the
/// middle frames. Use for big position/size animations like grid resizes.
pub fn easeInOutSine(t: f32) f32 {
    return -(std.math.cos(std.math.pi * t) - 1.0) / 2.0;
}

test "easeInOutSine endpoints and midpoint" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), easeInOutSine(0.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), easeInOutSine(1.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), easeInOutSine(0.5), 1e-5);
}
