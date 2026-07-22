//! Deterministic, binary64-only implementation of Roc's F64 power builtin.
//!
//! The logarithm and exponential kernels are ported from Zig compiler_rt,
//! which in turn ports them from musl's MIT-licensed math implementation:
//! https://git.musl-libc.org/cgit/musl/tree/COPYRIGHT
//!
//! Every floating-point value and operation in this file is binary64. Keeping
//! the complete algorithm in Roc's builtin payload prevents a backend from
//! substituting a target libm or LLVM intrinsic with different finite bits.

const std = @import("std");

const canonical_nan: f64 = @bitCast(@as(u64, 0x7ff8_0000_0000_0000));
const positive_infinity: f64 = @bitCast(@as(u64, 0x7ff0_0000_0000_0000));

fn log(value: f64) f64 {
    const ln2_hi: f64 = 6.93147180369123816490e-01;
    const ln2_lo: f64 = 1.90821492927058770002e-10;
    const lg1: f64 = 6.666666666666735130e-01;
    const lg2: f64 = 3.999999999940941908e-01;
    const lg3: f64 = 2.857142874366239149e-01;
    const lg4: f64 = 2.222219843214978396e-01;
    const lg5: f64 = 1.818357216161805012e-01;
    const lg6: f64 = 1.531383769920937332e-01;
    const lg7: f64 = 1.479819860511658591e-01;

    var x = value;
    var bits: u64 = @bitCast(x);
    var high: u32 = @truncate(bits >> 32);
    var exponent: i32 = 0;

    if (high < 0x0010_0000 or high >> 31 != 0) {
        if (bits << 1 == 0) return -positive_infinity;
        if (high >> 31 != 0) return canonical_nan;

        exponent -= 54;
        x *= 0x1.0p54;
        bits = @bitCast(x);
        high = @truncate(bits >> 32);
    } else if (high >= 0x7ff0_0000) {
        return x;
    } else if (high == 0x3ff0_0000 and bits << 32 == 0) {
        return 0.0;
    }

    high += 0x3ff0_0000 - 0x3fe6_a09e;
    exponent += @as(i32, @intCast(high >> 20)) - 0x3ff;
    high = (high & 0x000f_ffff) + 0x3fe6_a09e;
    bits = (@as(u64, high) << 32) | (bits & 0xffff_ffff);
    x = @bitCast(bits);

    const f = x - 1.0;
    const half_square = 0.5 * f * f;
    const s = f / (2.0 + f);
    const z = s * s;
    const w = z * z;
    const even = w * (lg2 + w * (lg4 + w * lg6));
    const odd = z * (lg1 + w * (lg3 + w * (lg5 + w * lg7)));
    const approximation = odd + even;
    const float_exponent: f64 = @floatFromInt(exponent);

    return s * (half_square + approximation) + float_exponent * ln2_lo - half_square + f + float_exponent * ln2_hi;
}

fn scalePowerOfTwo(value: f64, power: i32) f64 {
    var bits: u64 = @bitCast(value);
    const sign = bits & 0x8000_0000_0000_0000;
    var exponent: i32 = @intCast((bits >> 52) & 0x7ff);
    if (exponent == 0x7ff or bits & 0x7fff_ffff_ffff_ffff == 0) return value;

    var adjusted_power = power;
    if (exponent == 0) {
        const scaled = value * 0x1.0p54;
        bits = @bitCast(scaled);
        exponent = @as(i32, @intCast((bits >> 52) & 0x7ff)) - 54;
    }

    const new_exponent = exponent + adjusted_power;
    if (new_exponent >= 0x7ff) return @bitCast(sign | 0x7ff0_0000_0000_0000);
    if (new_exponent > 0) return @bitCast((bits & 0x800f_ffff_ffff_ffff) | (@as(u64, @intCast(new_exponent)) << 52));
    if (new_exponent <= -54) return @bitCast(sign);

    adjusted_power = new_exponent + 54;
    const normal_bits = (bits & 0x800f_ffff_ffff_ffff) | (@as(u64, @intCast(adjusted_power)) << 52);
    const normal: f64 = @bitCast(normal_bits);
    return normal * 0x1.0p-54;
}

fn exp(value: f64) f64 {
    const half = [_]f64{ 0.5, -0.5 };
    const ln2_hi: f64 = 6.93147180369123816490e-01;
    const ln2_lo: f64 = 1.90821492927058770002e-10;
    const inv_ln2: f64 = 1.44269504088896338700e+00;
    const p1: f64 = 1.66666666666666019037e-01;
    const p2: f64 = -2.77777777770155933842e-03;
    const p3: f64 = 6.61375632143793436117e-05;
    const p4: f64 = -1.65339022054652515390e-06;
    const p5: f64 = 4.13813679705723846039e-08;

    var x = value;
    const bits: u64 = @bitCast(x);
    var high = bits >> 32;
    const sign: usize = @intCast(high >> 31);
    high &= 0x7fff_ffff;

    if (high > 0x7ff0_0000) return canonical_nan;
    if (high >= 0x4086_232b) {
        if (x > 709.782712893383973096) return positive_infinity;
        if (x < -745.13321910194110842) return 0.0;
    }

    var power: i32 = 0;
    var reduction_high: f64 = x;
    var reduction_low: f64 = 0.0;
    if (high > 0x3fd6_2e42) {
        if (high > 0x3ff0_a2b2) {
            power = @intFromFloat(inv_ln2 * x + half[sign]);
        } else {
            power = if (sign == 0) 1 else -1;
        }
        const float_power: f64 = @floatFromInt(power);
        reduction_high = x - float_power * ln2_hi;
        reduction_low = float_power * ln2_lo;
        x = reduction_high - reduction_low;
    } else if (high <= 0x3e30_0000) {
        return 1.0 + x;
    }

    const square = x * x;
    const correction = x - square * (p1 + square * (p2 + square * (p3 + square * (p4 + square * p5))));
    const result = 1.0 + (x * correction / (2.0 - correction) - reduction_low + reduction_high);
    return if (power == 0) result else scalePowerOfTwo(result, power);
}

fn isOddInteger(value: f64) bool {
    const abs_bits = @as(u64, @bitCast(value)) & 0x7fff_ffff_ffff_ffff;
    if (abs_bits >= 0x4340_0000_0000_0000) return false;
    if (@trunc(value) != value) return false;
    const integer: i64 = @intFromFloat(value);
    return integer & 1 != 0;
}

fn integerPower(base: f64, exponent: f64) f64 {
    var remaining: u64 = @intFromFloat(@abs(exponent));
    var factor = base;
    var result: f64 = 1.0;
    while (remaining != 0) : (remaining >>= 1) {
        if (remaining & 1 != 0) result *= factor;
        factor *= factor;
    }
    return if (exponent < 0.0) 1.0 / result else result;
}

/// Returns `base` raised to `exponent`, computed entirely with binary64 operations.
pub fn pow(base: f64, exponent: f64) f64 {
    if (exponent == 0.0 or base == 1.0) return 1.0;
    const base_bits: u64 = @bitCast(base);
    const exponent_bits: u64 = @bitCast(exponent);
    const base_abs_bits = base_bits & 0x7fff_ffff_ffff_ffff;
    const exponent_abs_bits = exponent_bits & 0x7fff_ffff_ffff_ffff;
    if (base_abs_bits > 0x7ff0_0000_0000_0000 or exponent_abs_bits > 0x7ff0_0000_0000_0000) return canonical_nan;
    if (exponent == 1.0) return base;

    if (base_abs_bits == 0) {
        if (exponent < 0.0) return if (isOddInteger(exponent)) @bitCast((base_bits & 0x8000_0000_0000_0000) | 0x7ff0_0000_0000_0000) else positive_infinity;
        return if (isOddInteger(exponent)) base else 0.0;
    }

    if (exponent_abs_bits == 0x7ff0_0000_0000_0000) {
        if (base == -1.0) return 1.0;
        const tends_to_zero = (@abs(base) < 1.0) == (exponent > 0.0);
        return if (tends_to_zero) 0.0 else positive_infinity;
    }
    if (base_abs_bits == 0x7ff0_0000_0000_0000) {
        if (base_bits >> 63 != 0) {
            const reciprocal: f64 = @bitCast(base_bits & 0x8000_0000_0000_0000);
            return pow(reciprocal, -exponent);
        }
        return if (exponent < 0.0) 0.0 else positive_infinity;
    }
    if (exponent == 0.5) return @sqrt(base);
    if (exponent == -0.5) return 1.0 / @sqrt(base);

    const exponent_is_integer = @trunc(exponent) == exponent;
    if (base < 0.0 and !exponent_is_integer) return canonical_nan;
    if (exponent_is_integer and exponent_abs_bits < 0x4340_0000_0000_0000) return integerPower(base, exponent);

    var result = exp(exponent * log(@abs(base)));
    if (base < 0.0 and isOddInteger(exponent)) result = -result;
    return result;
}

test "F64 power special cases" {
    const negative_infinity: f64 = @bitCast(@as(u64, 0xfff0_0000_0000_0000));
    const negative_zero: f64 = @bitCast(@as(u64, 0x8000_0000_0000_0000));

    try std.testing.expectEqual(@as(f64, 8.0), pow(2.0, 3.0));
    try std.testing.expectEqual(@as(f64, -8.0), pow(-2.0, 3.0));
    try std.testing.expectEqual(@as(f64, 16.0), pow(-2.0, 4.0));
    try std.testing.expectEqual(@as(f64, 0.25), pow(2.0, -2.0));
    try std.testing.expectEqual(@as(f64, 1.0), pow(canonical_nan, 0.0));
    try std.testing.expectEqual(@as(f64, 1.0), pow(1.0, canonical_nan));
    try std.testing.expect(std.math.isNan(pow(canonical_nan, 1.0)));
    try std.testing.expect(std.math.isNan(pow(2.0, canonical_nan)));
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(pow(negative_zero, 3.0))));
    try std.testing.expectEqual(@as(u64, 0xfff0_0000_0000_0000), @as(u64, @bitCast(pow(negative_zero, -3.0))));
    try std.testing.expectEqual(@as(u64, 0x0000_0000_0000_0000), @as(u64, @bitCast(pow(negative_zero, 2.0))));
    try std.testing.expectEqual(positive_infinity, pow(negative_zero, -2.0));
    try std.testing.expectEqual(@as(f64, 1.0), pow(-1.0, positive_infinity));
    try std.testing.expectEqual(@as(f64, 0.0), pow(0.5, positive_infinity));
    try std.testing.expectEqual(positive_infinity, pow(2.0, positive_infinity));
    try std.testing.expectEqual(positive_infinity, pow(0.5, negative_infinity));
    try std.testing.expectEqual(@as(f64, 0.0), pow(2.0, negative_infinity));
    try std.testing.expectEqual(positive_infinity, pow(positive_infinity, 2.0));
    try std.testing.expectEqual(@as(f64, 0.0), pow(positive_infinity, -2.0));
    try std.testing.expectEqual(negative_infinity, pow(negative_infinity, 3.0));
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(pow(negative_infinity, -3.0))));
    try std.testing.expect(std.math.isNan(pow(-1.0, 0.5)));
}

test "F64 power approximations" {
    try std.testing.expectApproxEqRel(@as(f64, 0.004936270901760079), pow(0.2, 3.3), 0x1p-48);
    try std.testing.expectApproxEqRel(@as(f64, 13530.513990233081), pow(17.54697502703452, 3.3204523365293763), 0x1p-48);
}

test "deterministic F64 power result bits" {
    try std.testing.expectEqual(@as(u64, 0x3f74_380e_2165_6686), @as(u64, @bitCast(pow(0.2, 3.3))));
    try std.testing.expectEqual(@as(u64, 0x40ca_6d41_ca6e_94c8), @as(u64, @bitCast(pow(17.54697502703452, 3.3204523365293763))));
}
