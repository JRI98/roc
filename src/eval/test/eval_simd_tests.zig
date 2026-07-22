//! Full integer-SIMD differential coverage for the wasm evaluator.

const std = @import("std");
const TestCase = @import("parallel_runner.zig").TestCase;
const simd_test_sources = @import("simd_test_sources");

const oracle_source = simd_test_sources.oracle;
const differential_source_with_package_import = simd_test_sources.differential;

fn differentialSource() []const u8 {
    const package_import = "import oracle.SimdOracle";
    const direct_import = "import SimdOracle";
    const start = comptime std.mem.find(u8, differential_source_with_package_import, package_import) orelse
        @compileError("SIMD differential module no longer imports oracle.SimdOracle");
    return differential_source_with_package_import[0..start] ++
        direct_import ++
        differential_source_with_package_import[start + package_import.len ..];
}

/// The dedicated SIMD gate runs this single source through every eval backend;
/// the runtime app and its `expect` supply the standalone and CTFE lanes.
pub const tests = [_]TestCase{.{
    .name = "SIMD full differential corpus",
    .source = "SimdDifferential.run_corpus(21345817372864405881847059188222722561)",
    .imports = &.{
        .{ .name = "SimdOracle", .source = oracle_source },
        .{ .name = "SimdDifferential", .source = differentialSource() },
    },
    .expected = .{ .inspect_str = "True" },
    .opt_in = true,
}};
