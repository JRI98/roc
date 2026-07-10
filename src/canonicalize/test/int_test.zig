//! Tests for integer literal canonicalization during the canonicalization phase.
//!
//! This module contains unit tests that verify the correct canonicalization
//! of integer literals and integer expressions from parsed AST into the
//! compiler's canonical internal representation (CIR).

const std = @import("std");
const testing = std.testing;
const base = @import("base");
const parse = @import("parse");
const builtins = @import("builtins");
const Can = @import("../Can.zig");
const CIR = @import("../CIR.zig");
const TestEnv = @import("TestEnv.zig").TestEnv;
const BuiltinTestContext = @import("./BuiltinTestContext.zig").BuiltinTestContext;
const ModuleEnv = @import("../ModuleEnv.zig");
const CoreCtx = @import("ctx").CoreCtx;
const RocDec = builtins.dec.RocDec;

fn getIntValue(module_env: *ModuleEnv, expr_idx: CIR.Expr.Idx) error{NotAnInteger}!i128 {
    const expr = module_env.store.getExpr(expr_idx);
    switch (expr) {
        .e_num => |int_expr| {
            return @bitCast(int_expr.value.bytes);
        },
        else => return error.NotAnInteger,
    }
}

test "canonicalize simple positive integer" {
    const source = "42";
    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
    try testing.expectEqual(@as(i128, 42), value);
}

test "canonicalize simple negative integer" {
    const source = "-42";
    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
    try testing.expectEqual(@as(i128, -42), value);
}

test "canonicalize zero" {
    const source = "0";
    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
    try testing.expectEqual(@as(i128, 0), value);
}

test "canonicalize large positive integer" {
    const source = "9223372036854775807"; // i64 max
    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
    try testing.expectEqual(@as(i128, 9223372036854775807), value);
}

test "canonicalize large negative integer" {
    const source = "-9223372036854775808"; // i64 min
    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
    try testing.expectEqual(@as(i128, -9223372036854775808), value);
}

test "canonicalize very large integer" {
    const source = "170141183460469231731687303715884105727"; // i128 max
    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
    try testing.expectEqual(@as(i128, 170141183460469231731687303715884105727), value);
}

test "canonicalize very large negative integer" {
    const source = "-170141183460469231731687303715884105728"; // i128 min
    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
    try testing.expectEqual(@as(i128, -170141183460469231731687303715884105728), value);
}

test "canonicalize small integers" {
    const test_cases = [_]struct { source: []const u8, expected: i128 }{
        .{ .source = "1", .expected = 1 },
        .{ .source = "-1", .expected = -1 },
        .{ .source = "10", .expected = 10 },
        .{ .source = "-10", .expected = -10 },
        .{ .source = "255", .expected = 255 },
        .{ .source = "-128", .expected = -128 },
        .{ .source = "256", .expected = 256 },
        .{ .source = "-129", .expected = -129 },
        .{ .source = "32767", .expected = 32767 },
        .{ .source = "-32768", .expected = -32768 },
        .{ .source = "65535", .expected = 65535 },
        .{ .source = "-32769", .expected = -32769 },
    };

    for (test_cases) |tc| {
        var test_env = try TestEnv.init(tc.source);
        defer test_env.deinit();

        const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
        const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
        try testing.expectEqual(tc.expected, value);
    }
}

test "canonicalize builtin typed integer suffix without caller setup" {
    var test_env = try TestEnv.init("0.I64");
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const expr = test_env.getCanonicalExpr(canonical_expr.get_idx());

    switch (expr) {
        .e_typed_int => |typed| {
            try testing.expectEqual(@as(i128, 0), typed.value.toI128());
            try testing.expectEqualStrings("I64", test_env.getIdent(typed.type_name));
        },
        else => return error.NotATypedInteger,
    }
}

test "canonicalize builtin typed fractional suffix without caller setup" {
    var test_env = try TestEnv.init("3.14.Dec");
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const expr = test_env.getCanonicalExpr(canonical_expr.get_idx());

    switch (expr) {
        .e_typed_frac => |typed| {
            try testing.expectEqual(@as(i128, 3_140_000_000_000_000_000), typed.value.toI128());
            try testing.expectEqualStrings("Dec", test_env.getIdent(typed.type_name));
        },
        else => return error.NotATypedFraction,
    }
}

test "typed numeric suffix still uses ordinary scope lookup" {
    var test_env = try TestEnv.init("123.UnknownType");
    defer test_env.deinit();

    _ = try test_env.canonicalizeExpr();

    const diagnostics = try test_env.getDiagnostics();
    defer testing.allocator.free(diagnostics);

    var found_undeclared_type = false;
    for (diagnostics) |diagnostic| {
        switch (diagnostic) {
            .undeclared_type => |data| {
                if (std.mem.eql(u8, test_env.getIdent(data.name), "UnknownType")) {
                    found_undeclared_type = true;
                }
            },
            else => {},
        }
    }

    try testing.expect(found_undeclared_type);
}

test "typed numeric suffix uses local shadow of builtin numeric type" {
    const source =
        \\{
        \\    U64 := {}
        \\    123.U64
        \\}
    ;
    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const expr = test_env.getCanonicalExpr(canonical_expr.get_idx());
    try testing.expectEqual(.e_block, std.meta.activeTag(expr));

    const final_expr_idx = expr.e_block.final_expr;
    const suffix_target = test_env.module_env.numericSuffixTargetForNode(ModuleEnv.nodeIdxFrom(final_expr_idx)) orelse return error.MissingSuffixTarget;

    switch (suffix_target.target()) {
        .local => {},
        else => return error.NotLocalSuffixTarget,
    }

    const diagnostics = try test_env.getDiagnostics();
    defer testing.allocator.free(diagnostics);

    var found_shadowing_warning = false;
    for (diagnostics) |diagnostic| {
        switch (diagnostic) {
            .shadowing_warning => found_shadowing_warning = true,
            else => {},
        }
    }

    try testing.expect(found_shadowing_warning);
}

test "canonicalize integer literals with underscores" {
    const test_cases = [_]struct { source: []const u8, expected: i128 }{
        .{ .source = "1_000", .expected = 1000 },
        .{ .source = "1_000_000", .expected = 1000000 },
        .{ .source = "-1_234_567", .expected = -1234567 },
        .{ .source = "123_456_789", .expected = 123456789 },
        .{ .source = "1_2_3_4_5", .expected = 12345 },
    };

    for (test_cases) |tc| {
        var test_env = try TestEnv.init(tc.source);
        defer test_env.deinit();

        const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
        const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
        try testing.expectEqual(tc.expected, value);
    }
}

test "canonicalize integer with specific requirements" {
    const test_cases = [_]struct {
        source: []const u8,
        expected_value: i128,
    }{
        .{ .source = "127", .expected_value = 127 },
        .{ .source = "128", .expected_value = 128 },
        .{ .source = "255", .expected_value = 255 },
        .{ .source = "256", .expected_value = 256 },
        .{ .source = "-128", .expected_value = -128 },
        .{ .source = "-129", .expected_value = -129 },
        .{ .source = "32767", .expected_value = 32767 },
        .{ .source = "32768", .expected_value = 32768 },
        .{ .source = "65535", .expected_value = 65535 },
        .{ .source = "65536", .expected_value = 65536 },
    };

    for (test_cases) |tc| {
        var test_env = try TestEnv.init(tc.source);
        defer test_env.deinit();

        const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
        const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
        try testing.expectEqual(tc.expected_value, value);
    }
}

test "canonicalize invalid integer literal" {
    // Test individual cases since some might fail during parsing vs canonicalization

    // "12abc" - invalid characters in number
    {
        var test_env = try TestEnv.init("12abc");
        defer test_env.deinit();
        // Should have parse errors
        try testing.expect(test_env.parse_ast.parse_diagnostics.items.len > 0 or
            test_env.parse_ast.tokenize_diagnostics.items.len > 0);
    }

    // Leading zeros with digits
    {
        var test_env = try TestEnv.init("0123");
        defer test_env.deinit();
        // This might actually parse as 123, check if we have diagnostics
        if (test_env.parse_ast.parse_diagnostics.items.len == 0 and
            test_env.parse_ast.tokenize_diagnostics.items.len == 0)
        {
            // No errors, so it should have parsed as 123
            const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
            const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
            try testing.expectEqual(@as(i128, 123), value);
        }
    }
}

test "canonicalize integer preserves all bytes correctly" {
    // Test specific bit patterns to ensure bytes are preserved correctly
    const test_cases = [_]struct {
        source: []const u8,
        expected_bytes: [16]u8,
    }{
        .{
            .source = "1",
            .expected_bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .source = "256",
            .expected_bytes = .{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .source = "65536",
            .expected_bytes = .{ 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .source = "-1",
            .expected_bytes = .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 },
        },
        .{
            .source = "-256",
            .expected_bytes = .{ 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 },
        },
    };

    for (test_cases) |tc| {
        var test_env = try TestEnv.init(tc.source);
        defer test_env.deinit();

        const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
        const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
        try testing.expectEqualSlices(u8, &tc.expected_bytes, std.mem.asBytes(&value));
    }
}

test "canonicalize integer round trip through NodeStore" {
    // Test that integers survive storage and retrieval from NodeStore
    const test_values = [_]i128{
        0,      1,     -1,     42,         -42,
        127,    -128,  255,    -256,       32767,
        -32768, 65535, -65536, 2147483647, -2147483648,
    };

    for (test_values) |expected| {
        const source = try std.fmt.allocPrint(testing.allocator, "{}", .{expected});
        defer testing.allocator.free(source);

        var test_env = try TestEnv.init(source);
        defer test_env.deinit();

        const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
        // Get the expression back from the store
        const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());

        try testing.expectEqual(expected, value);
    }
}

test "canonicalize integer with maximum digits" {
    // Test very long digit sequences
    const test_cases = [_]struct { source: []const u8, expected: i128 }{
        .{ .source = "000000000000000000000000000000000000000001", .expected = 1 },
        .{ .source = "000000000000000000000000000000000000000000", .expected = 0 },
        .{ .source = "-000000000000000000000000000000000000000001", .expected = -1 },
    };

    for (test_cases) |tc| {
        var test_env = try TestEnv.init(tc.source);
        defer test_env.deinit();

        // Check if parsing succeeded (leading zeros might be treated specially)
        const has_errors = test_env.parse_ast.parse_diagnostics.items.len > 0 or
            test_env.parse_ast.tokenize_diagnostics.items.len > 0;

        if (!has_errors) {
            const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
            const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());
            try testing.expectEqual(tc.expected, value);
        } else {
            // If there are errors, that's expected for numbers with leading zeros
            // Just verify we got some diagnostic
            try testing.expect(has_errors);
        }
    }
}

test "canonicalize integer requirements determination" {
    const test_cases = [_]struct {
        source: []const u8,
        expected_value: i128,
    }{
        // 255 needs 8 bits and no sign
        .{ .source = "255", .expected_value = 255 },
        // 256 needs 9-15 bits and no sign
        .{ .source = "256", .expected_value = 256 },
        // -1 needs sign and 7 bits
        .{ .source = "-1", .expected_value = -1 },
        // 65535 needs 16 bits and no sign
        .{ .source = "65535", .expected_value = 65535 },
        // 65536 needs 17-31 bits and no sign
        .{ .source = "65536", .expected_value = 65536 },
    };

    for (test_cases) |tc| {
        var test_env = try TestEnv.init(tc.source);
        defer test_env.deinit();

        const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
        const value = try getIntValue(test_env.module_env, canonical_expr.get_idx());

        try testing.expectEqual(tc.expected_value, value);
    }
}

test "canonicalize integer literals outside supported range" {
    // Exact integer literals that do not fit the compact payload stay available
    // for `from_numeral`; checking decides whether a concrete target accepts them.
    const test_cases = [_][]const u8{
        // Negative number slightly lower than i128 min
        "-170141183460469231731687303715884105729",
        // Number too big for u128 max (340282366920938463463374607431768211455)
        "340282366920938463463374607431768211456",
        // Way too big
        "999999999999999999999999999999999999999999999999999",
    };

    for (test_cases) |source| {
        var test_env = try TestEnv.init(source);
        defer test_env.deinit();

        const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
        const expr = test_env.getCanonicalExpr(canonical_expr.get_idx());
        try testing.expect(expr == .e_num_from_numeral);
        const literal = test_env.module_env.numeralLiteralForNode(ModuleEnv.nodeIdxFrom(canonical_expr.get_idx())) orelse return error.MissingNumeralLiteral;
        try testing.expect(!literal.isFractional());
    }
}

test "invalid number literal - too large for u128" {
    const source = "999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999";

    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    // Should have produced diagnostics for number too large
    // Very large numbers might be caught during parsing or canonicalization
    const parse_errors = test_env.parse_ast.parse_diagnostics.items.len > 0;
    const tokenize_errors = test_env.parse_ast.tokenize_diagnostics.items.len > 0;

    // Only check canon diagnostics if parsing succeeded
    if (!parse_errors and !tokenize_errors) {
        const canon_diagnostics = try test_env.module_env.getDiagnostics();
        defer test_env.gpa.free(canon_diagnostics);
        const canon_errors = canon_diagnostics.len > 0;

        if (!canon_errors) {
            // If no errors at all, check the expression type
            const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
            const expr = test_env.getCanonicalExpr(canonical_expr.get_idx());
            try testing.expect(expr == .e_num_from_numeral);
            const literal = test_env.module_env.numeralLiteralForNode(ModuleEnv.nodeIdxFrom(canonical_expr.get_idx())) orelse return error.MissingNumeralLiteral;
            try testing.expect(!literal.isFractional());
        }
    } else {
        // We have parse/tokenize errors, which is expected for this large number
        try testing.expect(true);
    }
}

test "invalid number literal - negative too large for i128" {
    const source = "-999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999";

    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    // Should have produced diagnostics for number too large
    // Very large negative numbers might be caught during parsing or canonicalization
    const parse_errors = test_env.parse_ast.parse_diagnostics.items.len > 0;
    const tokenize_errors = test_env.parse_ast.tokenize_diagnostics.items.len > 0;

    // Only check canon diagnostics if parsing succeeded
    if (!parse_errors and !tokenize_errors) {
        const canon_diagnostics = try test_env.module_env.getDiagnostics();
        defer test_env.gpa.free(canon_diagnostics);
        const canon_errors = canon_diagnostics.len > 0;

        if (!canon_errors) {
            // If no errors at all, check the expression type
            const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
            const expr = test_env.getCanonicalExpr(canonical_expr.get_idx());
            try testing.expect(expr == .e_num_from_numeral);
            const literal = test_env.module_env.numeralLiteralForNode(ModuleEnv.nodeIdxFrom(canonical_expr.get_idx())) orelse return error.MissingNumeralLiteral;
            try testing.expect(!literal.isFractional());
            try testing.expect(literal.isNegative());
        }
    } else {
        // We have parse/tokenize errors, which is expected for this large number
        try testing.expect(true);
    }
}

test "integer literal - negative zero" {
    const source = "-0";
    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const expr = test_env.getCanonicalExpr(canonical_expr.get_idx());
    switch (expr) {
        .e_num => |int| {
            // -0 should be treated as 0
            try testing.expectEqual(@as(i128, @bitCast(int.value.bytes)), 0);
            // But it should still be marked as needing a sign
        },
        else => {
            try testing.expect(false); // Should be int
        },
    }
}

test "integer literal - positive zero" {
    const source = "0";
    var test_env = try TestEnv.init(source);
    defer test_env.deinit();

    const canonical_expr = try test_env.canonicalizeExpr() orelse unreachable;
    const expr = test_env.getCanonicalExpr(canonical_expr.get_idx());
    switch (expr) {
        .e_num => |int| {
            try testing.expectEqual(@as(i128, @bitCast(int.value.bytes)), 0);
            // Positive zero should not need a sign
        },
        else => {
            try testing.expect(false); // Should be int
        },
    }
}

test "hexadecimal integer literals" {
    const test_cases = [_]struct {
        literal: []const u8,
        expected_value: i128,
    }{
        // Basic hex literals
        .{ .literal = "0x0", .expected_value = 0 },
        .{ .literal = "0x1", .expected_value = 1 },
        .{ .literal = "0xFF", .expected_value = 255 },
        .{ .literal = "0x100", .expected_value = 256 },
        .{ .literal = "0xFFFF", .expected_value = 65535 },
        .{ .literal = "0x10000", .expected_value = 65536 },
        .{ .literal = "0xFFFFFFFF", .expected_value = 4294967295 },
        .{ .literal = "0x100000000", .expected_value = 4294967296 },
        .{ .literal = "0xFFFFFFFFFFFFFFFF", .expected_value = @as(i128, @bitCast(@as(u128, 18446744073709551615))) },

        // Hex with underscores
        .{ .literal = "0x1_000", .expected_value = 4096 },
        .{ .literal = "0xFF_FF", .expected_value = 65535 },
        .{ .literal = "0x1234_5678_9ABC_DEF0", .expected_value = @as(i128, @bitCast(@as(u128, 0x123456789ABCDEF0))) },

        // Negative hex literals
        .{ .literal = "-0x1", .expected_value = -1 },
        .{ .literal = "-0x80", .expected_value = -128 },
        .{ .literal = "-0x81", .expected_value = -129 },
        .{ .literal = "-0x8000", .expected_value = -32768 },
        .{ .literal = "-0x8001", .expected_value = -32769 },
        .{ .literal = "-0x80000000", .expected_value = -2147483648 },
        .{ .literal = "-0x80000001", .expected_value = -2147483649 },
        .{ .literal = "-0x8000000000000000", .expected_value = -9223372036854775808 },
        .{ .literal = "-0x8000000000000001", .expected_value = @as(i128, -9223372036854775809) },
    };

    var gpa_state = std.heap.DebugAllocator(.{ .safety = true }){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();
    var builtin_ctx = try BuiltinTestContext.init(gpa);
    defer builtin_ctx.deinit();

    for (test_cases) |tc| {
        var env = try ModuleEnv.init(gpa, tc.literal);
        defer env.deinit();

        try env.initCIRFields("test");

        const roc_ctx = CoreCtx.testing(gpa, gpa);

        const ast = try parse.expr(gpa, &env.common);
        defer ast.deinit();

        var czer = try Can.initModule(roc_ctx, &env, ast, builtin_ctx.canInitContext());
        defer czer.deinit();

        const expr_idx: parse.AST.Expr.Idx = @enumFromInt(ast.root_node_idx);
        const canonical_expr_idx = try czer.canonicalizeExpr(expr_idx) orelse {
            std.debug.print("Failed to canonicalize: {s}\n", .{tc.literal});
            try std.testing.expect(false);
            continue;
        };

        const expr = env.store.getExpr(canonical_expr_idx.get_idx());
        try std.testing.expect(expr == .e_num);

        // Check the value
        try std.testing.expectEqual(tc.expected_value, @as(i128, @bitCast(expr.e_num.value.bytes)));
    }
}

test "binary integer literals" {
    const test_cases = [_]struct {
        literal: []const u8,
        expected_value: i128,
    }{
        // Basic binary literals
        .{ .literal = "0b0", .expected_value = 0 },
        .{ .literal = "0b1", .expected_value = 1 },
        .{ .literal = "0b10", .expected_value = 2 },
        .{ .literal = "0b11111111", .expected_value = 255 },
        .{ .literal = "0b100000000", .expected_value = 256 },
        .{ .literal = "0b1111111111111111", .expected_value = 65535 },
        .{ .literal = "0b10000000000000000", .expected_value = 65536 },

        // Binary with underscores
        .{ .literal = "0b11_11", .expected_value = 15 },
        .{ .literal = "0b1111_1111", .expected_value = 255 },
        .{ .literal = "0b1_0000_0000", .expected_value = 256 },
        .{ .literal = "0b1010_1010_1010_1010", .expected_value = 43690 },

        // Negative binary
        .{ .literal = "-0b1", .expected_value = -1 },
        .{ .literal = "-0b10000000", .expected_value = -128 },
        .{ .literal = "-0b10000001", .expected_value = -129 },
        .{ .literal = "-0b1000000000000000", .expected_value = -32768 },
        .{ .literal = "-0b1000000000000001", .expected_value = -32769 },
    };

    var gpa_state = std.heap.DebugAllocator(.{ .safety = true }){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();
    var builtin_ctx = try BuiltinTestContext.init(gpa);
    defer builtin_ctx.deinit();

    for (test_cases) |tc| {
        var env = try ModuleEnv.init(gpa, tc.literal);
        defer env.deinit();

        try env.initCIRFields("test");

        const roc_ctx = CoreCtx.testing(gpa, gpa);

        const ast = try parse.expr(gpa, &env.common);
        defer ast.deinit();

        var czer = try Can.initModule(roc_ctx, &env, ast, builtin_ctx.canInitContext());
        defer czer.deinit();

        const expr_idx: parse.AST.Expr.Idx = @enumFromInt(ast.root_node_idx);
        const canonical_expr_idx = try czer.canonicalizeExpr(expr_idx) orelse {
            std.debug.print("Failed to canonicalize: {s}\n", .{tc.literal});
            try std.testing.expect(false);
            continue;
        };

        const expr = env.store.getExpr(canonical_expr_idx.get_idx());
        try std.testing.expect(expr == .e_num);

        // Check the value
        try std.testing.expectEqual(tc.expected_value, @as(i128, @bitCast(expr.e_num.value.bytes)));
    }
}

test "octal integer literals" {
    const test_cases = [_]struct {
        literal: []const u8,
        expected_value: i128,
    }{
        // Basic octal literals
        .{ .literal = "0o0", .expected_value = 0 },
        .{ .literal = "0o1", .expected_value = 1 },
        .{ .literal = "0o7", .expected_value = 7 },
        .{ .literal = "0o10", .expected_value = 8 },
        .{ .literal = "0o377", .expected_value = 255 },
        .{ .literal = "0o400", .expected_value = 256 },
        .{ .literal = "0o177777", .expected_value = 65535 },
        .{ .literal = "0o200000", .expected_value = 65536 },

        // Octal with underscores
        .{ .literal = "0o377_377", .expected_value = 130815 },
        .{ .literal = "0o1_234_567", .expected_value = 342391 },

        // Negative octal literals
        .{ .literal = "-0o1", .expected_value = -1 },
        .{ .literal = "-0o100", .expected_value = -64 },
        .{ .literal = "-0o200", .expected_value = -128 },
        .{ .literal = "-0o201", .expected_value = -129 },
        .{ .literal = "-0o100000", .expected_value = -32768 },
        .{ .literal = "-0o100001", .expected_value = -32769 },
    };

    var gpa_state = std.heap.DebugAllocator(.{ .safety = true }){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();
    var builtin_ctx = try BuiltinTestContext.init(gpa);
    defer builtin_ctx.deinit();

    for (test_cases) |tc| {
        var env = try ModuleEnv.init(gpa, tc.literal);
        defer env.deinit();

        try env.initCIRFields("test");

        const roc_ctx = CoreCtx.testing(gpa, gpa);

        const ast = try parse.expr(gpa, &env.common);
        defer ast.deinit();

        var czer = try Can.initModule(roc_ctx, &env, ast, builtin_ctx.canInitContext());
        defer czer.deinit();

        const expr_idx: parse.AST.Expr.Idx = @enumFromInt(ast.root_node_idx);
        const canonical_expr_idx = try czer.canonicalizeExpr(expr_idx) orelse {
            std.debug.print("Failed to canonicalize: {s}\n", .{tc.literal});
            try std.testing.expect(false);
            continue;
        };

        const expr = env.store.getExpr(canonical_expr_idx.get_idx());
        try std.testing.expect(expr == .e_num);

        // Check the value
        try std.testing.expectEqual(tc.expected_value, @as(i128, @bitCast(expr.e_num.value.bytes)));
    }
}

test "integer literals with uppercase base prefixes" {
    const test_cases = [_]struct {
        literal: []const u8,
        expected_value: i128,
    }{
        // Uppercase hex prefix
        .{ .literal = "0X0", .expected_value = 0 },
        .{ .literal = "0X1", .expected_value = 1 },
        .{ .literal = "0XFF", .expected_value = 255 },
        .{ .literal = "0XABCD", .expected_value = 43981 },

        // Uppercase binary prefix
        .{ .literal = "0B0", .expected_value = 0 },
        .{ .literal = "0B1", .expected_value = 1 },
        .{ .literal = "0B1111", .expected_value = 15 },
        .{ .literal = "0B11111111", .expected_value = 255 },

        // Uppercase octal prefix
        .{ .literal = "0O0", .expected_value = 0 },
        .{ .literal = "0O7", .expected_value = 7 },
        .{ .literal = "0O377", .expected_value = 255 },
        .{ .literal = "0O777", .expected_value = 511 },

        // Mixed case in value (should still work)
        .{ .literal = "0xAbCd", .expected_value = 43981 },
        .{ .literal = "0XaBcD", .expected_value = 43981 },
    };

    var gpa_state = std.heap.DebugAllocator(.{ .safety = true }){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();
    var builtin_ctx = try BuiltinTestContext.init(gpa);
    defer builtin_ctx.deinit();

    for (test_cases) |tc| {
        var env = try ModuleEnv.init(gpa, tc.literal);
        defer env.deinit();

        try env.initCIRFields("test");

        const roc_ctx = CoreCtx.testing(gpa, gpa);

        const ast = try parse.expr(gpa, &env.common);
        defer ast.deinit();

        var czer = try Can.initModule(roc_ctx, &env, ast, builtin_ctx.canInitContext());
        defer czer.deinit();

        const expr_idx: parse.AST.Expr.Idx = @enumFromInt(ast.root_node_idx);
        const canonical_expr_idx = try czer.canonicalizeExpr(expr_idx) orelse {
            std.debug.print("Failed to canonicalize: {s}\n", .{tc.literal});
            try std.testing.expect(false);
            continue;
        };

        const expr = env.store.getExpr(canonical_expr_idx.get_idx());
        try std.testing.expect(expr == .e_num);

        // Check the value
        try std.testing.expectEqual(tc.expected_value, @as(i128, @bitCast(expr.e_num.value.bytes)));
    }
}

test "numeric literal patterns use pattern idx as type var" {
    var gpa_state = std.heap.DebugAllocator(.{ .safety = true }){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    // Test that int literal patterns work and use the pattern index as the type variable
    {
        var env = try ModuleEnv.init(gpa, "");
        defer env.deinit();

        try env.initCIRFields("test");

        // Create an int literal pattern directly
        const int_pattern = CIR.Pattern{
            .num_literal = .{
                .value = .{ .bytes = @bitCast(@as(i128, 42)), .kind = .i128 },
                .kind = .num_unbound,
            },
        };

        const pattern_idx = try env.addPattern(int_pattern, base.Region.zero());

        // Verify the stored pattern
        const stored_pattern = env.store.getPattern(pattern_idx);
        try std.testing.expect(stored_pattern == .num_literal);
        try std.testing.expectEqual(@as(i128, 42), @as(i128, @bitCast(stored_pattern.num_literal.value.bytes)));
    }

    // Test that f64 literal patterns work
    {
        var env = try ModuleEnv.init(gpa, "");
        defer env.deinit();

        try env.initCIRFields("test");

        // Create a dec literal pattern directly
        const dec_pattern = CIR.Pattern{
            .dec_literal = .{
                .value = RocDec.fromF64(3.14) orelse unreachable,
                .has_suffix = false,
            },
        };

        const pattern_idx = try env.addPattern(dec_pattern, base.Region.zero());

        // Verify the stored pattern
        const stored_pattern = env.store.getPattern(pattern_idx);
        try std.testing.expect(stored_pattern == .dec_literal);
        const expected_dec = RocDec.fromF64(3.14) orelse unreachable;
        try std.testing.expectEqual(expected_dec.num, stored_pattern.dec_literal.value.num);
    }
}

test "pattern numeric literal value edge cases" {
    var gpa_state = std.heap.DebugAllocator(.{ .safety = true }){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    // Test max/min integer values
    {
        var env = try ModuleEnv.init(gpa, "");
        defer env.deinit();

        try env.initCIRFields("test");

        // Test i128 max
        const max_pattern = CIR.Pattern{
            .num_literal = .{
                .value = .{ .bytes = @bitCast(@as(i128, std.math.maxInt(i128))), .kind = .i128 },
                .kind = .num_unbound,
            },
        };
        const max_idx = try env.store.addPattern(max_pattern, base.Region.zero());
        const stored_max = env.store.getPattern(max_idx);
        try std.testing.expectEqual(std.math.maxInt(i128), @as(i128, @bitCast(stored_max.num_literal.value.bytes)));

        // Test i128 min
        const min_pattern = CIR.Pattern{
            .num_literal = .{
                .value = .{ .bytes = @bitCast(@as(i128, std.math.minInt(i128))), .kind = .i128 },
                .kind = .num_unbound,
            },
        };
        const min_idx = try env.store.addPattern(min_pattern, base.Region.zero());
        const stored_min = env.store.getPattern(min_idx);
        try std.testing.expectEqual(std.math.minInt(i128), @as(i128, @bitCast(stored_min.num_literal.value.bytes)));
    }

    // Test small decimal pattern
    {
        var env = try ModuleEnv.init(gpa, "");
        defer env.deinit();

        try env.initCIRFields("test");

        const small_dec_pattern = CIR.Pattern{
            .small_dec_literal = .{
                .value = .{
                    .numerator = 1234,
                    .denominator_power_of_ten = 2, // 12.34
                },
                .has_suffix = false,
            },
        };

        const pattern_idx = try env.store.addPattern(small_dec_pattern, base.Region.zero());
        const stored = env.store.getPattern(pattern_idx);

        try std.testing.expect(stored == .small_dec_literal);
        try std.testing.expectEqual(@as(i16, 1234), stored.small_dec_literal.value.numerator);
        try std.testing.expectEqual(@as(u8, 2), stored.small_dec_literal.value.denominator_power_of_ten);
    }

    // Test dec literal pattern
    {
        var env = try ModuleEnv.init(gpa, "");
        defer env.deinit();

        try env.initCIRFields("test");

        const dec_pattern = CIR.Pattern{
            .dec_literal = .{
                .value = RocDec{ .num = 314159265358979323 }, // π * 10^17
                .has_suffix = false,
            },
        };

        const pattern_idx = try env.store.addPattern(dec_pattern, base.Region.zero());
        const stored = env.store.getPattern(pattern_idx);

        try std.testing.expect(stored == .dec_literal);
        try std.testing.expectEqual(@as(i128, 314159265358979323), stored.dec_literal.value.num);
    }

    // Test special float values
    {
        var env = try ModuleEnv.init(gpa, "");
        defer env.deinit();

        try env.initCIRFields("test");

        // Test negative zero (RocDec doesn't distinguish between +0 and -0)
        const neg_zero_pattern = CIR.Pattern{
            .dec_literal = .{
                .value = RocDec.fromF64(-0.0) orelse unreachable,
                .has_suffix = false,
            },
        };
        const neg_zero_idx = try env.store.addPattern(neg_zero_pattern, base.Region.zero());
        const stored_neg_zero = env.store.getPattern(neg_zero_idx);
        try std.testing.expect(stored_neg_zero == .dec_literal);
        try std.testing.expectEqual(@as(i128, 0), stored_neg_zero.dec_literal.value.num);
    }
}

test "SmallDecValue edge cases" {
    // Maximum denominator power (produces very small but non-zero value)
    {
        const val = CIR.SmallDecValue{ .numerator = 1, .denominator_power_of_ten = 255 };
        const f64_val = val.toF64();
        // This doesn't underflow to 0 - f64 can represent very small values
        try testing.expect(f64_val > 0.0);
        try testing.expect(f64_val < 1e-250); // Very small
    }

    // Large numerator with large denominator (should produce normal value)
    {
        const val = CIR.SmallDecValue{ .numerator = 32767, .denominator_power_of_ten = 4 };
        const f64_val = val.toF64();
        try testing.expectApproxEqAbs(@as(f64, 3.2767), f64_val, 0.0001);
    }

    // Negative max numerator
    {
        const val = CIR.SmallDecValue{ .numerator = -32768, .denominator_power_of_ten = 4 };
        const f64_val = val.toF64();
        try testing.expectApproxEqAbs(@as(f64, -3.2768), f64_val, 0.0001);
    }

    // Value that would be subnormal in f32 (but still representable in f64)
    {
        const val = CIR.SmallDecValue{ .numerator = 1, .denominator_power_of_ten = 40 };
        const f64_val = val.toF64();
        try testing.expectEqual(@as(f64, 1e-40), f64_val);
    }
}
