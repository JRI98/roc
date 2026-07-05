//! Zero-allocation gate for Iter/Stream.
//!
//! Every iterator case asserts `max_allocations = 0`: a statically-known
//! iterator chain must perform ZERO heap allocations, regardless of how it is
//! consumed. Range sources are used deliberately — a range's state is two
//! integers, so there is no list-build allocation to confound the measurement;
//! any allocation is the iterator machinery itself.
//!
//! The observed output is a static string literal chosen by comparing the
//! iterator's computed value to its expected value ("ok" iff correct). String
//! literals are compile-time constants, so the observation itself allocates
//! nothing — the iterator's fold is the only possible allocator. This is
//! confirmed by the two canary cases below, which must be GREEN (0 allocations).
//!
//! The iterator cases are RED on the recursive-nominal representation (the
//! iterator boxes a successor state per step). They turn GREEN only when the
//! internal representation carries a statically-known chain by value.
//! `allocations_at_most` counts cumulative roc_alloc/roc_realloc, so a per-step
//! allocate/free loop is caught even though it leaves the live heap near zero.

const TestCase = @import("parallel_runner.zig").TestCase;

pub const tests = [_]TestCase{
    // --- Canaries: prove the observation pattern (literal + arithmetic +
    // branch) allocates nothing, so a nonzero count is the iterator's fault. ---
    .{
        .name = "iter alloc canary: bare string literal is zero-alloc",
        .source = "\"ok\"",
        .expected = .{ .allocations_at_most = .{ .output = "ok", .max_allocations = 0 } },
    },
    .{
        .name = "iter alloc canary: arithmetic and branch to a literal is zero-alloc",
        .source = "if 2.U64 + 1 == 3 { \"ok\" } else { \"bad\" }",
        .expected = .{ .allocations_at_most = .{ .output = "ok", .max_allocations = 0 } },
    },

    // --- Expression sources: base + single adapters over a range ---
    .{
        .name = "iter alloc: range fold is zero-alloc",
        .source = "if Iter.fold(Iter.exclusive_range(0.U64, 5), 0.U64, |a, b| a + b) == 10 { \"ok\" } else { \"bad\" }",
        .expected = .{ .allocations_at_most = .{ .output = "ok", .max_allocations = 0 } },
    },
    .{
        .name = "iter alloc: range map fold is zero-alloc",
        .source = "if Iter.fold(Iter.map(Iter.exclusive_range(0.U64, 5), |n| n + 1), 0.U64, |a, b| a + b) == 15 { \"ok\" } else { \"bad\" }",
        .expected = .{ .allocations_at_most = .{ .output = "ok", .max_allocations = 0 } },
    },
    .{
        .name = "iter alloc: range keep_if fold is zero-alloc",
        .source = "if Iter.fold(Iter.keep_if(Iter.exclusive_range(0.U64, 6), |n| n > 2), 0.U64, |a, b| a + b) == 12 { \"ok\" } else { \"bad\" }",
        .expected = .{ .allocations_at_most = .{ .output = "ok", .max_allocations = 0 } },
    },

    // Escaping cases (iterator returned / passed / branch-merged) require
    // module-level function definitions, which the runtime allocation path does
    // not support. They are gated statically by `box_box_count == 0` over
    // reachable procs in lir_inline_test.zig ("iter alloc static: …").
};
