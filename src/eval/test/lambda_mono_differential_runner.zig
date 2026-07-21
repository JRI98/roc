//! Differential harness for the direct solved-to-LIR lowering's statement
//! bodies.
//!
//! For each corpus program, the harness compiles once (Debug pipeline,
//! specialization cache disabled, in-place List.map off) while capturing the
//! Debug verifier's materialized Lambda Mono program, then executes the
//! program twice:
//!
//!   - the LIR interpreter runs the direct lowering's LIR output;
//!   - a tree-walking evaluator (`postcheck.LambdaMono.Eval`) runs the
//!     materialized Lambda Mono tree, a derivation that shares no lowering
//!     code with the direct path.
//!
//! The two executions must agree on the final inspect string, the abort kind
//! and message, the ordered dbg transcript, and the expect-failure transcript.
//! A divergence localizes a body-lowering bug (or an oracle/evaluator bug) to
//! a concrete program with both results in hand. Constructs the tree
//! evaluator does not support are counted and reported per reason — never
//! silently skipped.
//!
//! Generated corpus cases additionally run under the dev JIT backend and must
//! agree with the interpreter (cross-backend agreement on the sweep corpus).
//!
//! The harness only works in Debug builds: release builds never materialize
//! the Lambda Mono tree.

const std = @import("std");
const builtin = @import("builtin");
const eval = @import("eval");
const collections = @import("collections");
const postcheck = @import("postcheck");
const test_harness = @import("test_harness");
const build_options = @import("build_options");

const helpers = eval.test_helpers;
const eval_tests = @import("eval_tests.zig");
const generated = @import("lambda_mono_generated_corpus.zig");
const LambdaMonoEval = postcheck.LambdaMono.Eval;
const LambdaMonoProgram = postcheck.LambdaMono.Ast.Program;

/// Errors the runner's entry point can surface.
const RunnerError = std.mem.Allocator.Error || test_harness.Timer.Error || std.fmt.ParseIntError || error{
    RequiresDebugBuild,
    InvalidArgument,
    Diverged,
    NothingExecuted,
    UnexpectedChildFailure,
    Unexpected,
};

const CaseOrigin = enum { corpus, generated };

const Case = struct {
    name: []const u8,
    source: []const u8,
    source_kind: helpers.SourceKind = .expr,
    imports: []const helpers.ModuleSource = &.{},
    origin: CaseOrigin,
    /// Generated case that is expected to panic the compiler (a known,
    /// pre-existing bug tracked in the generated corpus). Such a child
    /// failure is reported but does not fail the run.
    known_panic: bool = false,
};

const CaseStatus = enum {
    /// Both executions agreed.
    pass,
    /// The two executions disagreed — a body-lowering (or evaluator) bug.
    diverged,
    /// The tree evaluator does not support a construct in this program.
    unsupported,
    /// The program did not compile in this harness configuration.
    compile_skip,
    /// The interpreter reference run failed outside the abort protocol.
    interpreter_error,
    /// The dev backend disagreed with the interpreter on a generated case.
    dev_diverged,
    /// The isolated child process died (compiler panic, signal, or timeout).
    child_failed,
};

const CaseResult = struct {
    status: CaseStatus,
    /// Owned detail text for diverged/unsupported/interpreter_error.
    detail: ?[]u8 = null,
};

const Totals = struct {
    pass: usize = 0,
    diverged: usize = 0,
    unsupported: usize = 0,
    compile_skip: usize = 0,
    interpreter_error: usize = 0,
    dev_diverged: usize = 0,
    child_failed: usize = 0,
    unexpected_child_failed: usize = 0,
};

const UnsupportedEntry = struct {
    count: usize,
    examples: [3][]const u8,
    example_count: usize,
};

/// Aggregates per-case results into totals and printed reporting. `record`
/// takes ownership of `result.detail`.
const Report = struct {
    gpa: std.mem.Allocator,
    totals: *Totals,
    unsupported_reasons: *std.StringHashMap(UnsupportedEntry),
    divergences: *std.ArrayList([]u8),
    total_cases: usize,
    executed: usize = 0,
    saw_failure: bool = false,

    fn record(self: *Report, case: Case, result: *CaseResult) std.mem.Allocator.Error!void {
        const gpa = self.gpa;
        self.executed += 1;
        if (!verbose_logging and self.executed % 200 == 0) {
            std.debug.print("... {d}/{d} cases\n", .{ self.executed, self.total_cases });
        }
        switch (result.status) {
            .pass => {
                self.totals.pass += 1;
                logVerbose("PASS       {s}\n", .{case.name});
                if (result.detail) |detail| gpa.free(detail);
            },
            .diverged, .dev_diverged => {
                if (result.status == .diverged) self.totals.diverged += 1 else self.totals.dev_diverged += 1;
                self.saw_failure = true;
                const detail = result.detail orelse try gpa.dupe(u8, "(no detail)");
                result.detail = null;
                std.debug.print("DIVERGED   {s}\n{s}\n", .{ case.name, detail });
                try self.divergences.append(gpa, detail);
            },
            .unsupported => {
                self.totals.unsupported += 1;
                const reason = result.detail orelse try gpa.dupe(u8, "(unknown construct)");
                logVerbose("UNSUPPORTED {s}: {s}\n", .{ case.name, reason });
                const entry = try self.unsupported_reasons.getOrPut(reason);
                if (entry.found_existing) {
                    gpa.free(reason);
                    entry.value_ptr.count += 1;
                    if (entry.value_ptr.example_count < entry.value_ptr.examples.len) {
                        entry.value_ptr.examples[entry.value_ptr.example_count] = case.name;
                        entry.value_ptr.example_count += 1;
                    }
                } else {
                    entry.value_ptr.* = .{
                        .count = 1,
                        .examples = .{ case.name, undefined, undefined },
                        .example_count = 1,
                    };
                }
            },
            .compile_skip => {
                self.totals.compile_skip += 1;
                logVerbose("NO-COMPILE {s}\n", .{case.name});
                if (result.detail) |detail| gpa.free(detail);
            },
            .interpreter_error => {
                self.totals.interpreter_error += 1;
                if (result.detail) |detail| {
                    std.debug.print("INTERP-ERR {s}: {s}\n", .{ case.name, detail });
                    gpa.free(detail);
                }
            },
            .child_failed => {
                self.totals.child_failed += 1;
                // A generated case that panics unexpectedly is a regression;
                // known-panic cases and corpus-origin failures are reported
                // without failing the run.
                if (case.origin == .generated and !case.known_panic) {
                    self.totals.unexpected_child_failed += 1;
                    self.saw_failure = true;
                }
                std.debug.print("CHILD-FAIL {s}{s}: {s}\n", .{
                    case.name,
                    if (case.known_panic) " (known panic)" else "",
                    result.detail orelse "(no detail)",
                });
                if (result.detail) |detail| gpa.free(detail);
            },
        }
    }
};

var verbose_logging: bool = false;

fn logVerbose(comptime fmt: []const u8, args: anytype) void {
    if (verbose_logging) {
        std.debug.print(fmt, args);
    }
}

const posix = std.posix;
const has_fork = builtin.os.tag != .windows;

/// Wire status bytes for the child-to-parent result protocol.
fn statusByte(status: CaseStatus) u8 {
    return switch (status) {
        .pass => 'P',
        .diverged => 'D',
        .dev_diverged => 'V',
        .unsupported => 'U',
        .compile_skip => 'C',
        .interpreter_error => 'I',
        .child_failed => 'F',
    };
}

fn statusFromByte(byte: u8) ?CaseStatus {
    return switch (byte) {
        'P' => .pass,
        'D' => .diverged,
        'V' => .dev_diverged,
        'U' => .unsupported,
        'C' => .compile_skip,
        'I' => .interpreter_error,
        'F' => .child_failed,
        else => null,
    };
}

/// One forked case whose result the parent has not yet collected.
const PendingChild = struct {
    case: Case,
    pid: posix.pid_t,
    fd: posix.fd_t,
    deadline_ns: u64,
    payload: std.ArrayList(u8),
};

/// Fork one case into an isolated child so a compiler panic, evaluator
/// crash, or hang is attributed to that case instead of killing the whole
/// run. The child writes one status byte plus the detail text and exits.
/// Returns null when the fork machinery is unavailable (caller runs inline).
fn spawnCase(
    gpa: std.mem.Allocator,
    io: std.Io,
    case: Case,
    timeout_ms: u64,
    siblings: []const PendingChild,
) std.mem.Allocator.Error!?PendingChild {
    if (comptime !has_fork) return null;

    const pipe_fds = test_harness.pipe() catch return null;
    const pipe_read = pipe_fds[0];
    const pipe_write = pipe_fds[1];

    const fork_result = test_harness.fork() catch {
        test_harness.closeFd(pipe_read);
        test_harness.closeFd(pipe_write);
        return null;
    };

    if (fork_result == 0) {
        // Child: close inherited pipe ends (ours and every sibling's, so
        // sibling EOFs are not held open by this process), run the case, and
        // serialize the result. The child _exit()s, so the OS reclaims all
        // memory — no deinit needed.
        test_harness.closeFd(pipe_read);
        for (siblings) |sibling| test_harness.closeFd(sibling.fd);
        _ = std.c.setsid();
        var child_arena = collections.SingleThreadArena.init(gpa);
        const result = runCase(child_arena.allocator(), io, case) catch |err| {
            test_harness.writeAll(pipe_write, &[_]u8{'E'});
            test_harness.writeAll(pipe_write, @errorName(err));
            test_harness.closeFd(pipe_write);
            std.c._exit(2);
        };
        test_harness.writeAll(pipe_write, &[_]u8{statusByte(result.status)});
        if (result.detail) |detail| test_harness.writeAll(pipe_write, detail);
        test_harness.closeFd(pipe_write);
        std.c._exit(0);
    }

    test_harness.closeFd(pipe_write);
    return .{
        .case = case,
        .pid = fork_result,
        .fd = pipe_read,
        .deadline_ns = test_harness.monotonicNs() + timeout_ms * 1_000_000,
        .payload = .empty,
    };
}

/// Reap a finished (or timed-out) child and turn its payload into a result.
/// Closes the pipe and frees the payload buffer.
fn finalizeChild(gpa: std.mem.Allocator, child: *PendingChild, timed_out: bool) std.mem.Allocator.Error!CaseResult {
    if (timed_out) {
        posix.kill(-child.pid, posix.SIG.KILL) catch {
            posix.kill(child.pid, posix.SIG.KILL) catch {};
        };
    }
    const wait_result = test_harness.waitpid(child.pid, 0);
    test_harness.closeFd(child.fd);
    defer child.payload.deinit(gpa);

    if (timed_out) {
        return CaseResult{
            .status = .child_failed,
            .detail = try gpa.dupe(u8, "timed out"),
        };
    }
    if (child.payload.items.len == 0) {
        return CaseResult{
            .status = .child_failed,
            .detail = try std.fmt.allocPrint(
                gpa,
                "child died without a result (compiler panic or signal; wait status {d})",
                .{wait_result.status},
            ),
        };
    }
    const first = child.payload.items[0];
    if (first == 'E') {
        return CaseResult{
            .status = .child_failed,
            .detail = try std.fmt.allocPrint(gpa, "child error: {s}", .{child.payload.items[1..]}),
        };
    }
    const status = statusFromByte(first) orelse {
        return CaseResult{
            .status = .child_failed,
            .detail = try std.fmt.allocPrint(gpa, "malformed child payload ({d} bytes)", .{child.payload.items.len}),
        };
    };
    const detail: ?[]u8 = if (child.payload.items.len > 1)
        try gpa.dupe(u8, child.payload.items[1..])
    else
        null;
    return CaseResult{ .status = status, .detail = detail };
}

/// Run cases through a pool of forked children, collecting results as each
/// child finishes. Result ordering follows completion, not submission.
fn runPool(
    gpa: std.mem.Allocator,
    io: std.Io,
    run_list: []const Case,
    job_limit: usize,
    timeout_ms: u64,
    fail_fast: bool,
    report: *Report,
) std.mem.Allocator.Error!void {
    var pending: std.ArrayList(PendingChild) = .empty;
    defer {
        for (pending.items) |*child| {
            posix.kill(-child.pid, posix.SIG.KILL) catch {
                posix.kill(child.pid, posix.SIG.KILL) catch {};
            };
            _ = test_harness.waitpid(child.pid, 0);
            test_harness.closeFd(child.fd);
            child.payload.deinit(gpa);
        }
        pending.deinit(gpa);
    }

    var next: usize = 0;
    var read_buf: [4096]u8 = undefined;
    while (next < run_list.len or pending.items.len > 0) {
        const stop_spawning = fail_fast and report.saw_failure;
        while (next < run_list.len and pending.items.len < job_limit and !stop_spawning) {
            const case = run_list[next];
            next += 1;
            if (try spawnCase(gpa, io, case, timeout_ms, pending.items)) |child| {
                try pending.append(gpa, child);
            } else {
                var result = try runCase(gpa, io, case);
                try report.record(case, &result);
            }
        }
        if (pending.items.len == 0) {
            if (stop_spawning) break;
            continue;
        }

        const poll_fds = try gpa.alloc(posix.pollfd, pending.items.len);
        defer gpa.free(poll_fds);
        var min_deadline: u64 = std.math.maxInt(u64);
        for (pending.items, poll_fds) |child, *pfd| {
            pfd.* = .{
                .fd = child.fd,
                .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL,
                .revents = 0,
            };
            min_deadline = @min(min_deadline, child.deadline_ns);
        }
        const now_ns = test_harness.monotonicNs();
        const poll_timeout_ms: i32 = if (min_deadline <= now_ns)
            0
        else
            @intCast(@min((min_deadline - now_ns) / 1_000_000 + 1, 60_000));
        _ = posix.poll(poll_fds, poll_timeout_ms) catch {};

        // Scan with stable indices, then remove finished children from the
        // highest index down so swapRemove never disturbs a lower index.
        var finished_buf: [64]struct { index: usize, timed_out: bool } = undefined;
        var finished_count: usize = 0;
        const scan_now_ns = test_harness.monotonicNs();
        for (pending.items, poll_fds, 0..) |*child, pfd, index| {
            if (finished_count == finished_buf.len) break;
            const revents = pfd.revents;
            var eof = false;
            if (revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                const bytes_read = posix.read(child.fd, &read_buf) catch blk: {
                    eof = true;
                    break :blk 0;
                };
                if (bytes_read == 0) {
                    eof = true;
                } else {
                    try child.payload.appendSlice(gpa, read_buf[0..bytes_read]);
                }
            }
            if (eof) {
                finished_buf[finished_count] = .{ .index = index, .timed_out = false };
                finished_count += 1;
            } else if (scan_now_ns >= child.deadline_ns) {
                finished_buf[finished_count] = .{ .index = index, .timed_out = true };
                finished_count += 1;
            }
        }

        var f = finished_count;
        while (f > 0) {
            f -= 1;
            const entry = finished_buf[f];
            var child = pending.items[entry.index];
            _ = pending.swapRemove(entry.index);
            var result = try finalizeChild(gpa, &child, entry.timed_out);
            try report.record(child.case, &result);
        }
    }
}

/// Entry point for the Lambda Mono differential harness.
pub fn main(init: std.process.Init) RunnerError!void {
    const io = init.io;

    if (builtin.mode != .Debug) {
        std.debug.print("lambda-mono differential harness requires a Debug build (release builds never materialize the Lambda Mono tree)\n", .{});
        return error.RequiresDebugBuild;
    }

    var gpa_impl: std.heap.DebugAllocator(.{ .stack_trace_frames = build_options.debug_gpa_stack_trace_frames }) = .init;
    defer _ = build_options.debugGpaOk(gpa_impl.deinit());
    const gpa = gpa_impl.allocator();

    var args_arena = collections.SingleThreadArena.init(gpa);
    defer args_arena.deinit();
    const cli = try test_harness.parseStandardArgs(args_arena.allocator(), init.minimal.args);

    if (cli.help_requested) {
        printHelp();
        return;
    }
    verbose_logging = cli.verbose;

    var corpus_only = false;
    var generated_only = false;
    var fail_fast = false;
    var max_cases: ?usize = null;
    for (cli.positional) |arg| {
        if (std.mem.eql(u8, arg, "corpus-only")) {
            corpus_only = true;
        } else if (std.mem.eql(u8, arg, "generated-only")) {
            generated_only = true;
        } else if (std.mem.eql(u8, arg, "fail-fast")) {
            fail_fast = true;
        } else if (std.mem.startsWith(u8, arg, "max-cases=")) {
            max_cases = try std.fmt.parseInt(usize, arg["max-cases=".len..], 10);
        } else {
            std.debug.print("unknown positional argument: {s}\n", .{arg});
            printHelp();
            return error.InvalidArgument;
        }
    }

    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(gpa);
    if (!corpus_only) {
        for (generated.cases) |case| {
            try cases.append(gpa, .{
                .name = case.name,
                .source = case.source,
                .source_kind = if (case.module) .module else .expr,
                .origin = .generated,
                .known_panic = case.known_panic,
            });
        }
    }
    if (!generated_only) {
        for (eval_tests.tests) |tc| {
            // Frontend-problem cases have nothing to execute differentially.
            switch (tc.expected) {
                .problem, .problem_and_crash => continue,
                .inspect_str, .allocations_at_most, .crash => {},
            }
            try cases.append(gpa, .{
                .name = tc.name,
                .source = tc.source,
                .source_kind = tc.source_kind,
                .imports = tc.imports,
                .origin = .corpus,
            });
        }
    }

    var totals: Totals = .{};
    var unsupported_reasons = std.StringHashMap(UnsupportedEntry).init(gpa);
    defer {
        var free_it = unsupported_reasons.iterator();
        while (free_it.next()) |entry| gpa.free(entry.key_ptr.*);
        unsupported_reasons.deinit();
    }
    var divergences: std.ArrayList([]u8) = .empty;
    defer {
        for (divergences.items) |detail| gpa.free(detail);
        divergences.deinit(gpa);
    }

    var timer = try test_harness.Timer.start();

    // Select the cases this run executes.
    var run_list: std.ArrayList(Case) = .empty;
    defer run_list.deinit(gpa);
    for (cases.items) |case| {
        if (max_cases) |limit| {
            if (run_list.items.len >= limit) break;
        }
        if (cli.filters.len > 0) {
            var matched = false;
            for (cli.filters) |pattern| {
                if (std.mem.find(u8, case.name, pattern) != null or
                    std.mem.find(u8, case.source, pattern) != null)
                {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
        }
        try run_list.append(gpa, case);
    }

    var report = Report{
        .gpa = gpa,
        .totals = &totals,
        .unsupported_reasons = &unsupported_reasons,
        .divergences = &divergences,
        .total_cases = run_list.items.len,
    };

    if (comptime has_fork) {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const default_jobs = @min(cpu_count, 12);
        const job_limit = @max(cli.max_threads orelse default_jobs, 1);
        try runPool(gpa, io, run_list.items, job_limit, cli.timeout_ms, fail_fast, &report);
    } else {
        for (run_list.items) |case| {
            var result = try runCase(gpa, io, case);
            try report.record(case, &result);
            if (fail_fast and report.saw_failure) break;
        }
    }
    const executed = report.executed;

    const elapsed_ms = timer.read() / 1_000_000;

    std.debug.print(
        "\nlambda-mono differential: {d} cases in {d} ms\n" ++
            "  agreed:              {d}\n" ++
            "  diverged:            {d}\n" ++
            "  dev-diverged:        {d}\n" ++
            "  unsupported (skip):  {d}\n" ++
            "  did not compile:     {d}\n" ++
            "  interpreter errors:  {d}\n" ++
            "  child failures:      {d}\n",
        .{
            executed,
            elapsed_ms,
            totals.pass,
            totals.diverged,
            totals.dev_diverged,
            totals.unsupported,
            totals.compile_skip,
            totals.interpreter_error,
            totals.child_failed,
        },
    );

    if (unsupported_reasons.count() > 0) {
        std.debug.print("\nunsupported constructs (stated coverage gaps):\n", .{});
        var it = unsupported_reasons.iterator();
        while (it.next()) |entry| {
            std.debug.print("  {d:>5}  {s}  (e.g.", .{ entry.value_ptr.count, entry.key_ptr.* });
            for (entry.value_ptr.examples[0..entry.value_ptr.example_count]) |example| {
                std.debug.print(" \"{s}\"", .{example});
            }
            std.debug.print(")\n", .{});
        }
    }

    if (totals.diverged > 0 or totals.dev_diverged > 0) {
        std.debug.print("\nFAILED: {d} divergence(s)\n", .{totals.diverged + totals.dev_diverged});
        return error.Diverged;
    }
    if (totals.unexpected_child_failed > 0) {
        std.debug.print(
            "\nFAILED: {d} generated case(s) died unexpectedly (compiler panic or timeout)\n",
            .{totals.unexpected_child_failed},
        );
        return error.UnexpectedChildFailure;
    }
    if (totals.pass == 0) {
        std.debug.print("\nFAILED: no case executed differentially (harness is not exercising anything)\n", .{});
        return error.NothingExecuted;
    }
    std.debug.print("\nOK\n", .{});
}

fn printHelp() void {
    std.debug.print(
        "lambda-mono differential runner\n\n" ++
            "Compares the LIR interpreter (direct solved-to-LIR lowering) against a\n" ++
            "tree-walking evaluator over the Debug-materialized Lambda Mono program.\n\n" ++
            "Options:\n" ++
            "  --filter <substr>   only run cases whose name/source matches (repeatable)\n" ++
            "  --threads <n>       number of worker processes (default: min(cpu_count, 12))\n" ++
            "  --verbose           per-case logging\n" ++
            "  corpus-only         only the checked-in eval corpus\n" ++
            "  generated-only      only the generated sweep corpus\n" ++
            "  fail-fast           stop at the first divergence\n" ++
            "  max-cases=N         stop after N cases\n",
        .{},
    );
}

fn runCase(gpa: std.mem.Allocator, io: std.Io, case: Case) std.mem.Allocator.Error!CaseResult {
    var materialized: ?LambdaMonoProgram = null;

    // On compile failure the pipeline's shared-memory arena is already gone,
    // and any captured program with it; the slot must not be deinit'd then.
    var compiled = helpers.compileInspectedProgramWithLambdaMono(
        gpa,
        io,
        case.source_kind,
        case.source,
        case.imports,
        null,
        &materialized,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return CaseResult{ .status = .compile_skip },
    };
    // LIFO defers: the materialized program (allocated from the compile's
    // shared-memory arena) is deinit'd before the arena itself unmaps.
    defer compiled.deinit(gpa);
    defer if (materialized) |*program| program.deinit();

    var transcript = helpers.lirInterpreterTranscript(gpa, &compiled.lowered) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return CaseResult{
            .status = .interpreter_error,
            .detail = try std.fmt.allocPrint(gpa, "{s}", .{@errorName(err)}),
        },
    };
    defer transcript.deinit(gpa);

    if (materialized == null) {
        // The capture slot is filled by the Debug verifier; an empty slot
        // means the pipeline did not run it.
        return CaseResult{
            .status = .interpreter_error,
            .detail = try gpa.dupe(u8, "no materialized Lambda Mono program was captured"),
        };
    }
    const program = &materialized.?;

    if (program.rootCount() == 0) {
        return CaseResult{
            .status = .interpreter_error,
            .detail = try gpa.dupe(u8, "materialized program has no roots"),
        };
    }

    var evaluator = LambdaMonoEval.Evaluator.init(gpa, program);
    defer evaluator.deinit();

    // Root 0 matches the interpreter's `mainProc()` (`root_procs.items[0]`):
    // both sides bind roots from the same checked root-request order.
    const outcome = evaluator.runRoot(0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return CaseResult{
            .status = .unsupported,
            .detail = try gpa.dupe(u8, evaluator.unsupported orelse "(unknown construct)"),
        },
    };

    if (try compareOutcomes(gpa, case, &transcript, &evaluator, outcome)) |detail| {
        return CaseResult{ .status = .diverged, .detail = detail };
    }

    // Cross-backend agreement for the sweep corpus: the dev JIT must agree
    // with the interpreter on the same compile.
    if (case.origin == .generated) {
        if (try compareDevBackend(gpa, case, &compiled.lowered, &transcript)) |detail| {
            return CaseResult{ .status = .dev_diverged, .detail = detail };
        }
    }

    return CaseResult{ .status = .pass };
}

fn compareOutcomes(
    gpa: std.mem.Allocator,
    case: Case,
    transcript: *const helpers.InterpreterTranscript,
    evaluator: *const LambdaMonoEval.Evaluator,
    outcome: LambdaMonoEval.RunOutcome,
) std.mem.Allocator.Error!?[]u8 {
    switch (transcript.outcome) {
        .output => |interp_bytes| switch (outcome) {
            .value => |value| {
                const lm_bytes = LambdaMonoEval.strBytes(value);
                if (!std.mem.eql(u8, interp_bytes, lm_bytes)) {
                    return try divergence(gpa, case, "inspect output", interp_bytes, lm_bytes);
                }
            },
            .aborted => |lm_abort| {
                const lm_text = try abortSummary(gpa, @tagName(lm_abort.kind), lm_abort.message);
                defer gpa.free(lm_text);
                return try divergence(gpa, case, "termination", interp_bytes, lm_text);
            },
        },
        .aborted => |interp_abort| switch (outcome) {
            .value => |value| {
                const interp_text = try abortSummary(gpa, @tagName(interp_abort.kind), interp_abort.message);
                defer gpa.free(interp_text);
                return try divergence(gpa, case, "termination", interp_text, LambdaMonoEval.strBytes(value));
            },
            .aborted => |lm_abort| {
                if (!std.mem.eql(u8, @tagName(interp_abort.kind), @tagName(lm_abort.kind))) {
                    const interp_text = try abortSummary(gpa, @tagName(interp_abort.kind), interp_abort.message);
                    defer gpa.free(interp_text);
                    const lm_text = try abortSummary(gpa, @tagName(lm_abort.kind), lm_abort.message);
                    defer gpa.free(lm_text);
                    return try divergence(gpa, case, "abort kind", interp_text, lm_text);
                }
                if (interp_abort.message) |interp_msg| {
                    if (!std.mem.eql(u8, interp_msg, lm_abort.message)) {
                        return try divergence(gpa, case, "abort message", interp_msg, lm_abort.message);
                    }
                }
            },
        },
    }

    if (transcript.dbg_events.len != evaluator.dbg_events.items.len) {
        return try divergenceCounts(
            gpa,
            case,
            "dbg event count",
            transcript.dbg_events.len,
            evaluator.dbg_events.items.len,
        );
    }
    for (transcript.dbg_events, evaluator.dbg_events.items) |interp_dbg, lm_dbg| {
        if (!std.mem.eql(u8, interp_dbg, lm_dbg)) {
            return try divergence(gpa, case, "dbg event", interp_dbg, lm_dbg);
        }
    }

    if (transcript.expect_failures.len != evaluator.expect_failures.items.len) {
        return try divergenceCounts(
            gpa,
            case,
            "expect-failure count",
            transcript.expect_failures.len,
            evaluator.expect_failures.items.len,
        );
    }
    for (transcript.expect_failures, evaluator.expect_failures.items) |interp_msg, lm_msg| {
        if (!std.mem.eql(u8, interp_msg, lm_msg)) {
            return try divergence(gpa, case, "expect-failure message", interp_msg, lm_msg);
        }
    }

    return null;
}

fn compareDevBackend(
    gpa: std.mem.Allocator,
    case: Case,
    lowered: *const helpers.LoweredProgram,
    transcript: *const helpers.InterpreterTranscript,
) std.mem.Allocator.Error!?[]u8 {
    const dev_output = helpers.devEvaluatorInspectedStr(gpa, lowered) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Crash => switch (transcript.outcome) {
            .aborted => return null,
            .output => |interp_bytes| return try devDivergence(gpa, case, "dev backend termination", interp_bytes, "(crash)"),
        },
        else => return try std.fmt.allocPrint(
            gpa,
            "  case: {s}\n  dev backend error: {s}\n",
            .{ case.name, @errorName(err) },
        ),
    };
    defer gpa.free(dev_output);

    switch (transcript.outcome) {
        .output => |interp_bytes| {
            if (!std.mem.eql(u8, interp_bytes, dev_output)) {
                return try devDivergence(gpa, case, "dev backend output", interp_bytes, dev_output);
            }
        },
        .aborted => |interp_abort| {
            const interp_text = try abortSummary(gpa, @tagName(interp_abort.kind), interp_abort.message);
            defer gpa.free(interp_text);
            return try devDivergence(gpa, case, "dev backend termination", interp_text, dev_output);
        },
    }
    return null;
}

fn devDivergence(
    gpa: std.mem.Allocator,
    case: Case,
    what: []const u8,
    interp: []const u8,
    dev: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "  case:        {s}\n" ++
            "  differs on:  {s}\n" ++
            "  interpreter: {s}\n" ++
            "  dev backend: {s}\n" ++
            "  source:\n{s}\n",
        .{ case.name, what, interp, dev, case.source },
    );
}

fn abortSummary(gpa: std.mem.Allocator, kind_name: []const u8, message: ?[]const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}: {s}", .{ kind_name, message orelse "(no message)" });
}

fn divergence(
    gpa: std.mem.Allocator,
    case: Case,
    what: []const u8,
    interp: []const u8,
    lambda_mono: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "  case:        {s}\n" ++
            "  differs on:  {s}\n" ++
            "  interpreter: {s}\n" ++
            "  lambda mono: {s}\n" ++
            "  source:\n{s}\n",
        .{ case.name, what, interp, lambda_mono, case.source },
    );
}

fn divergenceCounts(
    gpa: std.mem.Allocator,
    case: Case,
    what: []const u8,
    interp: usize,
    lambda_mono: usize,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "  case:        {s}\n" ++
            "  differs on:  {s}\n" ++
            "  interpreter: {d}\n" ++
            "  lambda mono: {d}\n" ++
            "  source:\n{s}\n",
        .{ case.name, what, interp, lambda_mono, case.source },
    );
}
