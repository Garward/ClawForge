const std = @import("std");

/// SIMD-accelerated vector math for embedding search.
/// Build with -Dcpu=native to enable AVX2/SSE on the host CPU.

/// Dot product of two f32 vectors using SIMD.
/// Falls back to scalar if vectors aren't aligned to SIMD width.
pub fn dotProduct(a: []const f32, b: []const f32) f32 {
    const len = @min(a.len, b.len);
    const simd_width = 8; // AVX2: 8 x f32

    var sum: f32 = 0.0;
    var i: usize = 0;

    // SIMD path: process 8 floats at a time
    while (i + simd_width <= len) : (i += simd_width) {
        const va: @Vector(simd_width, f32) = a[i..][0..simd_width].*;
        const vb: @Vector(simd_width, f32) = b[i..][0..simd_width].*;
        const prod = va * vb;
        sum += @reduce(.Add, prod);
    }

    // Scalar tail
    while (i < len) : (i += 1) {
        sum += a[i] * b[i];
    }

    return sum;
}

/// Cosine similarity between two f32 vectors.
/// Returns value in [-1, 1] where 1 = identical direction.
pub fn cosineSimilarity(a: []align(1) const f32, b: []align(1) const f32) f32 {
    const len = @min(a.len, b.len);
    const simd_width = 8;

    var dot: f32 = 0.0;
    var norm_a: f32 = 0.0;
    var norm_b: f32 = 0.0;
    var i: usize = 0;

    while (i + simd_width <= len) : (i += simd_width) {
        const va: @Vector(simd_width, f32) = a[i..][0..simd_width].*;
        const vb: @Vector(simd_width, f32) = b[i..][0..simd_width].*;
        dot += @reduce(.Add, va * vb);
        norm_a += @reduce(.Add, va * va);
        norm_b += @reduce(.Add, vb * vb);
    }

    while (i < len) : (i += 1) {
        dot += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }

    const denom = @sqrt(norm_a) * @sqrt(norm_b);
    if (denom == 0.0) return 0.0;
    return dot / denom;
}

/// Hamming distance between two binary vectors stored as packed u64 arrays.
/// Uses @popCount for hardware-accelerated bit counting.
/// Accepts byte-aligned slices because SQLite blobs come back as
/// `[]align(1) const u8` and `bytesAsSlice` preserves that alignment.
pub fn hammingDistance(a: []align(1) const u64, b: []align(1) const u64) u32 {
    const len = @min(a.len, b.len);
    var dist: u32 = 0;

    for (0..len) |i| {
        dist += @popCount(a[i] ^ b[i]);
    }

    return dist;
}

/// Convert an f32 vector to binary (1-bit per dimension).
/// Positive values → 1, negative → 0. Packed into u64 words.
/// Result has ceil(dims/64) u64 words.
pub fn toBinary(allocator: std.mem.Allocator, vec: []const f32) ![]u64 {
    const num_words = (vec.len + 63) / 64;
    const result = try allocator.alloc(u64, num_words);
    @memset(result, 0);

    for (vec, 0..) |val, i| {
        if (val > 0.0) {
            result[i / 64] |= @as(u64, 1) << @intCast(i % 64);
        }
    }

    return result;
}

// Tests

test "dot product basic" {
    const a = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const b = [_]f32{ 5.0, 6.0, 7.0, 8.0 };
    const result = dotProduct(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 70.0), result, 0.001);
}

test "cosine similarity identical" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const result = cosineSimilarity(&a, &a);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.001);
}

test "cosine similarity orthogonal" {
    const a = [_]f32{ 1.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0 };
    const result = cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result, 0.001);
}

test "hamming distance" {
    const a = [_]u64{0b1010};
    const b = [_]u64{0b1001};
    const result = hammingDistance(&a, &b);
    try std.testing.expectEqual(@as(u32, 2), result);
}

test "toBinary" {
    const allocator = std.testing.allocator;
    const vec = [_]f32{ 1.0, -0.5, 0.3, -0.1 };
    const binary = try toBinary(allocator, &vec);
    defer allocator.free(binary);
    // bits: 1, 0, 1, 0 = 0b0101 = 5
    try std.testing.expectEqual(@as(u64, 5), binary[0]);
}
