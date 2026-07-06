//! Structural LIR tests for post-check wrapper inlining.

const std = @import("std");
const base = @import("base");
const check = @import("check");
const eval = @import("eval");
const lir = @import("lir");
const postcheck = @import("postcheck");
const helpers = eval.test_helpers;

const Allocator = std.mem.Allocator;
const LIR = lir.LIR;
const layout_mod = @import("layout");
const LayoutIdx = layout_mod.Idx;
const MonoAst = postcheck.Monotype.Ast;
const MonoLower = postcheck.Monotype.Lower;
const MonoType = postcheck.Monotype.Type;

const TestError = helpers.TestHelperError || eval.BuiltinModules.InitError || error{
    TestExpectedEqual,
    TestUnexpectedResult,
    MissingRootProcedure,
    MissingProcSpec,
    MissingCallable,
    MissingDbgRoot,
    MissingIterCollectWorker,
    MissingSpecializedWorker,
};

var shared_test_builtins: ?eval.BuiltinModules = null;
var shared_test_builtins_mutex: std.Io.Mutex = .init;

const LoweredSource = struct {
    resources: helpers.ParsedResources,
    lowered: lir.CheckedPipeline.LoweredProgram,

    fn deinit(self: *LoweredSource, allocator: Allocator) void {
        self.lowered.deinit();
        helpers.cleanupParseAndCanonical(allocator, self.resources);
    }
};

const LiftedSource = struct {
    resources: helpers.ParsedResources,
    lifted: postcheck.MonotypeLifted.Ast.Program,

    fn deinit(self: *LiftedSource, allocator: Allocator) void {
        self.lifted.deinit();
        helpers.cleanupParseAndCanonical(allocator, self.resources);
    }
};

const MonotypeSource = struct {
    resources: helpers.ParsedResources,
    mono: postcheck.Monotype.Ast.Program,

    fn deinit(self: *MonotypeSource, allocator: Allocator) void {
        self.mono.deinit();
        helpers.cleanupParseAndCanonical(allocator, self.resources);
    }
};

fn sharedPrePublishedBuiltin() TestError!helpers.PrePublishedBuiltin {
    shared_test_builtins_mutex.lockUncancelable(std.testing.io);
    defer shared_test_builtins_mutex.unlock(std.testing.io);

    if (shared_test_builtins == null) {
        shared_test_builtins = try eval.BuiltinModules.init(std.heap.page_allocator);
    }

    return .{
        .env = shared_test_builtins.?.builtin_module.env,
        .indices = shared_test_builtins.?.builtin_indices,
        .artifact = &shared_test_builtins.?.checked_artifact,
    };
}

fn lowerModule(
    allocator: Allocator,
    source: []const u8,
    inline_mode: lir.CheckedPipeline.InlineMode,
) TestError!LoweredSource {
    return lowerModuleWithOptions(allocator, source, inline_mode, .{});
}

const LowerModuleOptions = struct {
    checked_module_state: lir.CheckedPipeline.CheckedModuleState = .complete,
    inline_expects: lir.CheckedPipeline.InlineExpectMode = .run,
    proc_debug_names: bool = false,
    tag_reachability: bool = false,
    imports: []const helpers.ModuleSource = &.{},
};

fn lowerModuleWithOptions(
    allocator: Allocator,
    source: []const u8,
    inline_mode: lir.CheckedPipeline.InlineMode,
    options: LowerModuleOptions,
) TestError!LoweredSource {
    var resources = try helpers.parseAndCanonicalizeProgramWithBuiltin(allocator, .module, source, options.imports, try sharedPrePublishedBuiltin());
    errdefer helpers.cleanupParseAndCanonical(allocator, resources);

    const import_count = resources.import_artifacts.len + if (resources.borrowed_builtin_artifact == null) @as(usize, 0) else 1;
    const import_views = try allocator.alloc(check.CheckedArtifact.ImportedModuleView, import_count);
    defer allocator.free(import_views);

    var view_index: usize = 0;
    if (resources.borrowed_builtin_artifact) |builtin_artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(builtin_artifact);
        view_index += 1;
    }
    for (resources.import_artifacts) |*artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(artifact);
        view_index += 1;
    }

    var lowered = try lir.CheckedPipeline.lowerCheckedModulesToLir(
        allocator,
        .{
            .root = check.CheckedArtifact.loweringView(&resources.checked_artifact),
            .imports = import_views,
        },
        .{ .requests = resources.checked_artifact.root_requests.requests },
        .{
            .target_usize = base.target.TargetUsize.native,
            .checked_module_state = options.checked_module_state,
            .inline_mode = inline_mode,
            .inline_expects = options.inline_expects,
            .proc_debug_names = options.proc_debug_names,
            .tag_reachability = options.tag_reachability,
        },
    );
    errdefer lowered.deinit();

    return .{
        .resources = resources,
        .lowered = lowered,
    };
}

fn monotypeCountersForModule(
    allocator: Allocator,
    source: []const u8,
) TestError!postcheck.Monotype.Lower.SpecializationCounters {
    return monotypeCountersForModuleWithImports(allocator, source, &.{});
}

fn lowerMonotypeModule(
    allocator: Allocator,
    source: []const u8,
) TestError!MonotypeSource {
    return lowerMonotypeModuleWithOptions(allocator, source, .{});
}

const LowerMonotypeOptions = struct {
    specialization_cache: MonoLower.SpecializationCacheControl = .{},
    loaded_specialization_shards: []const MonoLower.LoadedSpecializationShard = &.{},
    specialization_counters: ?*MonoLower.SpecializationCounters = null,
};

fn lowerMonotypeModuleWithOptions(
    allocator: Allocator,
    source: []const u8,
    options: LowerMonotypeOptions,
) TestError!MonotypeSource {
    var resources = try helpers.parseAndCanonicalizeProgramWithBuiltin(allocator, .module, source, &.{}, try sharedPrePublishedBuiltin());
    errdefer helpers.cleanupParseAndCanonical(allocator, resources);

    const import_count = resources.import_artifacts.len + if (resources.borrowed_builtin_artifact == null) @as(usize, 0) else 1;
    const import_views = try allocator.alloc(check.CheckedArtifact.ImportedModuleView, import_count);
    defer allocator.free(import_views);

    var view_index: usize = 0;
    if (resources.borrowed_builtin_artifact) |builtin_artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(builtin_artifact);
        view_index += 1;
    }
    for (resources.import_artifacts) |*artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(artifact);
        view_index += 1;
    }

    var mono = try postcheck.Monotype.Lower.run(
        allocator,
        .{
            .root = check.CheckedArtifact.loweringView(&resources.checked_artifact),
            .imports = import_views,
        },
        .{ .requests = resources.checked_artifact.root_requests.requests },
        .{
            .specialization_cache = options.specialization_cache,
            .loaded_specialization_shards = options.loaded_specialization_shards,
            .specialization_counters = options.specialization_counters,
        },
    );
    errdefer mono.deinit();

    return .{
        .resources = resources,
        .mono = mono,
    };
}

fn monotypeCountersForModuleWithImports(
    allocator: Allocator,
    source: []const u8,
    imports: []const helpers.ModuleSource,
) TestError!postcheck.Monotype.Lower.SpecializationCounters {
    var resources = try helpers.parseAndCanonicalizeProgramWithBuiltin(allocator, .module, source, imports, try sharedPrePublishedBuiltin());
    defer helpers.cleanupParseAndCanonical(allocator, resources);

    const import_count = resources.import_artifacts.len + if (resources.borrowed_builtin_artifact == null) @as(usize, 0) else 1;
    const import_views = try allocator.alloc(check.CheckedArtifact.ImportedModuleView, import_count);
    defer allocator.free(import_views);

    var view_index: usize = 0;
    if (resources.borrowed_builtin_artifact) |builtin_artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(builtin_artifact);
        view_index += 1;
    }
    for (resources.import_artifacts) |*artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(artifact);
        view_index += 1;
    }

    var counters: postcheck.Monotype.Lower.SpecializationCounters = .{};
    var mono = try postcheck.Monotype.Lower.run(
        allocator,
        .{
            .root = check.CheckedArtifact.loweringView(&resources.checked_artifact),
            .imports = import_views,
        },
        .{ .requests = resources.checked_artifact.root_requests.requests },
        .{ .specialization_counters = &counters },
    );
    defer mono.deinit();

    return counters;
}

fn expectEquivalentMonotypeProgramViews(lhs: postcheck.Monotype.Ast.ProgramView, rhs: postcheck.Monotype.Ast.ProgramView) error{TestExpectedEqual}!void {
    try std.testing.expectEqual(lhs.next_symbol, rhs.next_symbol);

    try std.testing.expectEqualSlices(postcheck.Monotype.Type.Content, lhs.types.types, rhs.types.types);
    try std.testing.expectEqualSlices(?check.CheckedNames.TypeDigest, lhs.types.type_digests, rhs.types.type_digests);
    try std.testing.expectEqualSlices(postcheck.Monotype.Type.TypeId, lhs.types.spans, rhs.types.spans);
    try std.testing.expectEqualSlices(postcheck.Monotype.Type.Field, lhs.types.fields, rhs.types.fields);
    try std.testing.expectEqualSlices(postcheck.Monotype.Type.Tag, lhs.types.tags, rhs.types.tags);
    try std.testing.expectEqualSlices(postcheck.Monotype.Type.DeclaredField, lhs.types.declared_fields, rhs.types.declared_fields);

    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.SpecRecord, lhs.specs, rhs.specs);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.ImportedFn, lhs.imported_fns, rhs.imported_fns);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.Fn, lhs.fns, rhs.fns);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.Def, lhs.defs, rhs.defs);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.NestedDef, lhs.nested_defs, rhs.nested_defs);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.Expr, lhs.exprs, rhs.exprs);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.Pat, lhs.pats, rhs.pats);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.Stmt, lhs.stmts, rhs.stmts);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.Local, lhs.locals, rhs.locals);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.ExprId, lhs.expr_ids, rhs.expr_ids);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.PatId, lhs.pat_ids, rhs.pat_ids);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.TypedLocal, lhs.typed_locals, rhs.typed_locals);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.StmtId, lhs.stmt_ids, rhs.stmt_ids);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.FieldExpr, lhs.field_exprs, rhs.field_exprs);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.RecordDestruct, lhs.record_destructs, rhs.record_destructs);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.StrPatternStep, lhs.str_pattern_steps, rhs.str_pattern_steps);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.Branch, lhs.branches, rhs.branches);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.IfBranch, lhs.if_branches, rhs.if_branches);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.Root, lhs.roots, rhs.roots);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.LayoutRequest, lhs.layout_requests, rhs.layout_requests);
    try std.testing.expectEqualSlices(postcheck.Monotype.Ast.RuntimeSchemaRequest, lhs.runtime_schema_requests, rhs.runtime_schema_requests);
    try std.testing.expectEqualSlices(base.SourceLoc, lhs.expr_locs, rhs.expr_locs);
    try std.testing.expectEqualSlices(base.Region, lhs.expr_regions, rhs.expr_regions);
    try std.testing.expectEqualSlices(base.SourceLoc, lhs.stmt_locs, rhs.stmt_locs);
    try std.testing.expectEqualSlices(base.Region, lhs.stmt_regions, rhs.stmt_regions);
}

const DurableTypeSnapshot = struct {
    view: MonoType.DurableView,
    type_digests: []check.CheckedNames.TypeDigest,

    fn deinit(self: DurableTypeSnapshot, allocator: Allocator) void {
        allocator.free(self.type_digests);
    }
};

fn durableTypeSnapshot(allocator: Allocator, program: *const MonoAst.Program) Allocator.Error!DurableTypeSnapshot {
    const store_view = program.types.view();
    const type_digests = try allocator.alloc(check.CheckedNames.TypeDigest, store_view.types.len);
    errdefer allocator.free(type_digests);

    for (type_digests, 0..) |*digest, index| {
        digest.* = store_view.type_digests[index] orelse
            program.types.typeDigest(&program.names, @enumFromInt(@as(u32, @intCast(index))));
    }

    return .{
        .view = .{
            .types = store_view.types,
            .type_digests = type_digests,
            .spans = store_view.spans,
            .fields = store_view.fields,
            .tags = store_view.tags,
            .declared_fields = store_view.declared_fields,
        },
        .type_digests = type_digests,
    };
}

fn digestBytesEqual(lhs: check.CheckedNames.TypeDigest, rhs: check.CheckedNames.TypeDigest) bool {
    return std.mem.eql(u8, lhs.bytes[0..], rhs.bytes[0..]);
}

fn specRecordMatches(
    allocator: Allocator,
    name_store: *const check.CheckedNames.NameStore,
    candidate_types: anytype,
    candidate: MonoAst.SpecRecord,
    expected_types: anytype,
    expected: MonoAst.SpecRecord,
) Allocator.Error!bool {
    if (!std.meta.eql(candidate.identity.callable, expected.identity.callable)) return false;
    if (!digestBytesEqual(candidate.identity.source_fn_ty_digest, expected.identity.source_fn_ty_digest)) return false;
    if (!digestBytesEqual(candidate.identity.mono_fn_ty_digest, expected.identity.mono_fn_ty_digest)) return false;
    return try MonoType.typeEqlAcrossStores(
        allocator,
        name_store,
        candidate_types,
        candidate.identity.mono_fn_ty,
        expected_types,
        expected.identity.mono_fn_ty,
    );
}

fn specCoveredByLocalOrLoaded(
    allocator: Allocator,
    cached: MonoAst.ProgramView,
    loaded: MonoLower.LoadedSpecializationShard,
    expected_types: anytype,
    expected: MonoAst.SpecRecord,
) Allocator.Error!bool {
    for (cached.specs) |candidate| {
        if (try specRecordMatches(allocator, cached.names, cached.types, candidate, expected_types, expected)) return true;
    }

    for (loaded.specs) |candidate| {
        if (try specRecordMatches(allocator, cached.names, loaded.types, candidate, expected_types, expected)) return true;
    }

    return false;
}

fn expectSpecsCoveredByCachedOrLoaded(
    allocator: Allocator,
    no_cache: MonoAst.ProgramView,
    cached: MonoAst.ProgramView,
    loaded: MonoLower.LoadedSpecializationShard,
) TestError!void {
    for (no_cache.specs) |expected| {
        if (!try specCoveredByLocalOrLoaded(allocator, cached, loaded, no_cache.types, expected)) {
            return error.MissingProcSpec;
        }
    }
}

fn isUnaryPrimitiveFnSpec(view: MonoAst.ProgramView, record: MonoAst.SpecRecord, primitive: MonoType.Primitive) bool {
    const func = switch (view.types.get(record.identity.mono_fn_ty)) {
        .func => |func| func,
        else => return false,
    };
    const args = view.types.span(func.args);
    if (args.len != 1) return false;
    const arg_matches = switch (view.types.get(args[0])) {
        .primitive => |arg| arg == primitive,
        else => false,
    };
    const ret_matches = switch (view.types.get(func.ret)) {
        .primitive => |ret| ret == primitive,
        else => false,
    };
    return arg_matches and ret_matches;
}

fn lowerModuleWithInlineExpects(
    allocator: Allocator,
    source: []const u8,
    inline_mode: lir.CheckedPipeline.InlineMode,
    inline_expects: lir.CheckedPipeline.InlineExpectMode,
) TestError!LoweredSource {
    return lowerModuleWithOptions(allocator, source, inline_mode, .{ .inline_expects = inline_expects });
}

fn lowerModuleWithProcDebugNames(
    allocator: Allocator,
    source: []const u8,
    inline_mode: lir.CheckedPipeline.InlineMode,
    proc_debug_names: bool,
) TestError!LoweredSource {
    return lowerModuleWithOptions(allocator, source, inline_mode, .{ .proc_debug_names = proc_debug_names });
}

fn mainProcArgLayouts(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
) TestError![]LayoutIdx {
    const proc = lowered.lir_result.store.getProcSpec(try rootProc(lowered));
    const arg_locals = lowered.lir_result.store.getLocalSpan(proc.args);
    const arg_layouts = try allocator.alloc(LayoutIdx, arg_locals.len);
    errdefer allocator.free(arg_layouts);

    for (arg_locals, 0..) |local_id, index| {
        arg_layouts[index] = lowered.lir_result.store.getLocal(local_id).layout_idx;
    }

    return arg_layouts;
}

fn runLoweredWithHostEvents(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
) TestError!eval.RuntimeHostEnv.RecordedRun {
    var runtime_env = eval.RuntimeHostEnv.init(allocator);
    defer runtime_env.deinit();

    var interpreter = try eval.Interpreter.init(
        allocator,
        &lowered.lir_result.store,
        &lowered.lir_result.layouts,
        runtime_env.get_ops(),
    );
    defer interpreter.deinit();

    const arg_layouts = try mainProcArgLayouts(allocator, lowered);
    defer allocator.free(arg_layouts);

    const result = interpreter.eval(.{
        .proc_id = try rootProc(lowered),
        .arg_layouts = arg_layouts,
    }) catch |err| switch (err) {
        error.Crash => return runtime_env.snapshot(allocator),
        else => return err,
    };
    switch (result) {
        .value => {},
    }

    return runtime_env.snapshot(allocator);
}

fn expectOptimizedDbgEvents(source: []const u8, expected: []const []const u8) TestError!void {
    const allocator = std.testing.allocator;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var run = try runLoweredWithHostEvents(allocator, &optimized.lowered);
    defer run.deinit(allocator);

    try std.testing.expectEqual(eval.RuntimeHostEnv.Termination.returned, run.termination);
    try std.testing.expectEqual(expected.len, run.events.len);
    for (expected, run.events) |expected_event, actual_event| {
        switch (actual_event) {
            .dbg => |msg| try std.testing.expectEqualStrings(expected_event, msg),
            else => return error.TestUnexpectedResult,
        }
    }
}

const DebugEffectCounts = struct {
    debug: usize = 0,
    expect: usize = 0,
};

fn countDebugEffectStmts(lowered: *const lir.CheckedPipeline.LoweredProgram) DebugEffectCounts {
    var counts = DebugEffectCounts{};
    for (lowered.lir_result.store.cf_stmts.items) |stmt| {
        switch (stmt) {
            .debug => counts.debug += 1,
            .expect => counts.expect += 1,
            else => {},
        }
    }
    return counts;
}

test "optimized inline expect lowering omits expects and keeps dbg" {
    const allocator = std.testing.allocator;
    const source =
        \\main : I64
        \\main = {
        \\    dbg 1
        \\    expect False
        \\    expect 1 == 1
        \\    2
        \\}
    ;

    var run_effects = try lowerModuleWithInlineExpects(allocator, source, .wrappers, .run);
    defer run_effects.deinit(allocator);

    const run_counts = countDebugEffectStmts(&run_effects.lowered);
    try std.testing.expect(run_counts.debug > 0);
    try std.testing.expect(run_counts.expect > 0);

    var omitted_effects = try lowerModuleWithInlineExpects(allocator, source, .wrappers, .omit);
    defer omitted_effects.deinit(allocator);

    const omitted_counts = countDebugEffectStmts(&omitted_effects.lowered);
    try std.testing.expect(omitted_counts.debug > 0);
    try std.testing.expectEqual(@as(usize, 0), omitted_counts.expect);
}

test "nominal record lays out fields in declared order" {
    const allocator = std.testing.allocator;
    // The unnamed `_ : {}` field opts this nominal record into declared-order
    // layout, so { z: U16, y: U16, x: U32 } is kept verbatim. Without the marker
    // it would sort structurally and hoist the U32 to offset 0.
    const source =
        \\Account := { z : U16, y : U16, x : U32, _ : {} }
        \\
        \\main : Account -> Account
        \\main = |account| account
    ;

    var lowered_source = try lowerModule(allocator, source, .wrappers);
    defer lowered_source.deinit(allocator);
    const lowered = &lowered_source.lowered;

    const proc = lowered.lir_result.store.getProcSpec(try rootProc(lowered));
    const layout_val = lowered.lir_result.layouts.getLayout(proc.ret_layout);
    try std.testing.expectEqual(layout_mod.LayoutTag.struct_, layout_val.tag);

    const struct_idx = layout_val.getStruct().idx;
    // Field at memory position 0 is the first declared field z (U16); an
    // alphabetical or alignment layout would put the U32 (x) there instead.
    try std.testing.expectEqual(LayoutIdx.u16, lowered.lir_result.layouts.getStructFieldLayout(struct_idx, 0));
    // z (original/lexicographic field index 2) at offset 0, x (index 0) at 4.
    try std.testing.expectEqual(@as(u32, 0), lowered.lir_result.layouts.getStructFieldOffsetByOriginalIndex(struct_idx, 2));
    try std.testing.expectEqual(@as(u32, 4), lowered.lir_result.layouts.getStructFieldOffsetByOriginalIndex(struct_idx, 0));
    try std.testing.expectEqual(@as(u32, 8), lowered.lir_result.layouts.getStructSize(struct_idx));
}

test "imported nominal record lays out fields in declared order" {
    const allocator = std.testing.allocator;
    const acct_module =
        \\Account := { z : U16, y : U16, x : U32, _ : {} }
    ;
    // An imported nominal record must lay out identically to a local one, or
    // values would be read with the wrong offsets across module boundaries.
    const source =
        \\import Acct exposing [Account]
        \\
        \\main : Account -> Account
        \\main = |account| account
    ;

    var lowered_source = try lowerModuleWithOptions(allocator, source, .wrappers, .{
        .imports = &.{.{ .name = "Acct", .source = acct_module }},
    });
    defer lowered_source.deinit(allocator);
    const lowered = &lowered_source.lowered;

    const proc = lowered.lir_result.store.getProcSpec(try rootProc(lowered));
    const layout_val = lowered.lir_result.layouts.getLayout(proc.ret_layout);
    try std.testing.expectEqual(layout_mod.LayoutTag.struct_, layout_val.tag);

    const struct_idx = layout_val.getStruct().idx;
    try std.testing.expectEqual(LayoutIdx.u16, lowered.lir_result.layouts.getStructFieldLayout(struct_idx, 0));
    try std.testing.expectEqual(@as(u32, 8), lowered.lir_result.layouts.getStructSize(struct_idx));
}

test "nominal record reserves unnamed padding fields without inflating alignment" {
    const allocator = std.testing.allocator;
    // Mirrors a C `struct { uint8_t a; char pad[3]; uint32_t b; }`: the three
    // unnamed bytes hold the explicit padding so `b` lands at offset 4 without
    // the compiler inserting alignment padding of its own.
    const source =
        \\Padded := { a : U8, _ : U8, _ : U8, _ : U8, b : U32 }
        \\
        \\main : Padded -> Padded
        \\main = |padded| padded
    ;

    var lowered_source = try lowerModule(allocator, source, .wrappers);
    defer lowered_source.deinit(allocator);
    const lowered = &lowered_source.lowered;

    const proc = lowered.lir_result.store.getProcSpec(try rootProc(lowered));
    const layout_val = lowered.lir_result.layouts.getLayout(proc.ret_layout);
    try std.testing.expectEqual(layout_mod.LayoutTag.struct_, layout_val.tag);

    const struct_idx = layout_val.getStruct().idx;
    // The committed struct keeps the named fields plus three padding spacers.
    try std.testing.expectEqual(@as(u16, 5), lowered.lir_result.layouts.getStructData(struct_idx).fields.count);
    // Named field a (lexicographic index 0) at offset 0, b (index 1) at offset 4.
    try std.testing.expectEqual(@as(u32, 0), lowered.lir_result.layouts.getStructFieldOffsetByOriginalIndex(struct_idx, 0));
    try std.testing.expectEqual(@as(u32, 4), lowered.lir_result.layouts.getStructFieldOffsetByOriginalIndex(struct_idx, 1));
    // Total size 8 and alignment 4 (padding bytes are alignment 1, so they do
    // not raise the struct's alignment above the U32's).
    try std.testing.expectEqual(@as(u32, 8), lowered.lir_result.layouts.getStructSize(struct_idx));
    try std.testing.expectEqual(@as(u64, 4), layout_val.alignment(.u64).toByteUnits());
}

test "generic nominal record instantiates unnamed padding to the argument's size" {
    const allocator = std.testing.allocator;
    // A type-parameterized unnamed field (`_ : a`) must reserve the *instantiated*
    // size, exactly like a named field of the same type: `Foo(U64)` is 16 bytes
    // (x:U64 @0 plus 8 bytes of padding), just as `{ x : a, y : a }(U64)` would be.
    const source =
        \\Foo(a) := { x : a, _ : a }
        \\
        \\main : Foo(U64) -> Foo(U64)
        \\main = |foo| foo
    ;

    var lowered_source = try lowerModule(allocator, source, .wrappers);
    defer lowered_source.deinit(allocator);
    const lowered = &lowered_source.lowered;

    const proc = lowered.lir_result.store.getProcSpec(try rootProc(lowered));
    const layout_val = lowered.lir_result.layouts.getLayout(proc.ret_layout);
    try std.testing.expectEqual(layout_mod.LayoutTag.struct_, layout_val.tag);

    const struct_idx = layout_val.getStruct().idx;
    // x (the only named field) at offset 0; padding reserves the instantiated
    // sizeof(U64) = 8 bytes, so the whole struct is 16 bytes (not 8).
    try std.testing.expectEqual(@as(u16, 2), lowered.lir_result.layouts.getStructData(struct_idx).fields.count);
    try std.testing.expectEqual(@as(u32, 0), lowered.lir_result.layouts.getStructFieldOffsetByOriginalIndex(struct_idx, 0));
    try std.testing.expectEqual(@as(u32, 16), lowered.lir_result.layouts.getStructSize(struct_idx));
}

test "nominal record with a parenthesized backing still honors declared order and padding" {
    const allocator = std.testing.allocator;
    // The backing record is wrapped in parentheses. Parens are transparent here:
    // the unnamed field must still be accepted and the layout must match the
    // unparenthesized form (a@0, b@4, size 8, with three padding spacers).
    const source =
        \\Padded := ({ a : U8, _ : U8, _ : U8, _ : U8, b : U32 })
        \\
        \\main : Padded -> Padded
        \\main = |padded| padded
    ;

    var lowered_source = try lowerModule(allocator, source, .wrappers);
    defer lowered_source.deinit(allocator);
    const lowered = &lowered_source.lowered;

    const proc = lowered.lir_result.store.getProcSpec(try rootProc(lowered));
    const layout_val = lowered.lir_result.layouts.getLayout(proc.ret_layout);
    try std.testing.expectEqual(layout_mod.LayoutTag.struct_, layout_val.tag);

    const struct_idx = layout_val.getStruct().idx;
    try std.testing.expectEqual(@as(u16, 5), lowered.lir_result.layouts.getStructData(struct_idx).fields.count);
    try std.testing.expectEqual(@as(u32, 0), lowered.lir_result.layouts.getStructFieldOffsetByOriginalIndex(struct_idx, 0));
    try std.testing.expectEqual(@as(u32, 4), lowered.lir_result.layouts.getStructFieldOffsetByOriginalIndex(struct_idx, 1));
    try std.testing.expectEqual(@as(u32, 8), lowered.lir_result.layouts.getStructSize(struct_idx));
}

fn liftModuleAfterSpecConstr(
    allocator: Allocator,
    source: []const u8,
) TestError!LiftedSource {
    var resources = try helpers.parseAndCanonicalizeProgramWithBuiltin(allocator, .module, source, &.{}, try sharedPrePublishedBuiltin());
    errdefer helpers.cleanupParseAndCanonical(allocator, resources);

    const import_count = resources.import_artifacts.len + if (resources.borrowed_builtin_artifact == null) @as(usize, 0) else 1;
    const import_views = try allocator.alloc(check.CheckedArtifact.ImportedModuleView, import_count);
    defer allocator.free(import_views);

    var view_index: usize = 0;
    if (resources.borrowed_builtin_artifact) |builtin_artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(builtin_artifact);
        view_index += 1;
    }
    for (resources.import_artifacts) |*artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(artifact);
        view_index += 1;
    }

    var mono = try postcheck.Monotype.Lower.run(
        allocator,
        .{
            .root = check.CheckedArtifact.loweringView(&resources.checked_artifact),
            .imports = import_views,
        },
        .{ .requests = resources.checked_artifact.root_requests.requests },
        .{},
    );
    var mono_owned = true;
    errdefer if (mono_owned) mono.deinit();

    var lifted = try postcheck.MonotypeLifted.Lift.run(allocator, mono);
    mono_owned = false;
    mono = undefined;
    errdefer lifted.deinit();

    try postcheck.MonotypeLifted.SpecConstr.run(allocator, &lifted);

    return .{
        .resources = resources,
        .lifted = lifted,
    };
}

fn expectInlinePlanDecision(
    source: []const u8,
    fn_name: []const u8,
    expected: bool,
) TestError!void {
    const allocator = std.testing.allocator;
    var resources = try helpers.parseAndCanonicalizeProgramWithBuiltin(allocator, .module, source, &.{}, try sharedPrePublishedBuiltin());
    defer helpers.cleanupParseAndCanonical(allocator, resources);

    const import_count = resources.import_artifacts.len + if (resources.borrowed_builtin_artifact == null) @as(usize, 0) else 1;
    const import_views = try allocator.alloc(check.CheckedArtifact.ImportedModuleView, import_count);
    defer allocator.free(import_views);

    var view_index: usize = 0;
    if (resources.borrowed_builtin_artifact) |builtin_artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(builtin_artifact);
        view_index += 1;
    }
    for (resources.import_artifacts) |*artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(artifact);
        view_index += 1;
    }

    var mono = try postcheck.Monotype.Lower.run(
        allocator,
        .{
            .root = check.CheckedArtifact.loweringView(&resources.checked_artifact),
            .imports = import_views,
        },
        .{ .requests = resources.checked_artifact.root_requests.requests },
        .{ .proc_debug_names = true },
    );
    var mono_owned = true;
    errdefer if (mono_owned) mono.deinit();

    var lifted = try postcheck.MonotypeLifted.Lift.run(allocator, mono);
    mono_owned = false;
    mono = undefined;
    var lifted_owned = true;
    errdefer if (lifted_owned) lifted.deinit();

    var solved = try postcheck.LambdaSolved.Solve.run(allocator, lifted);
    lifted_owned = false;
    lifted = undefined;
    defer solved.deinit();

    var inline_plan = try postcheck.SolvedInline.analyze(allocator, .wrappers, &solved);
    defer inline_plan.deinit();
    const plan = inline_plan.view();

    var found = false;
    for (solved.lifted.fns.items, 0..) |fn_, index| {
        const name_id = solved.lifted.procDebugName(fn_.symbol) orelse continue;
        const actual_name = solved.lifted.names.exportNameText(name_id);
        if (!std.mem.eql(u8, actual_name, fn_name)) continue;

        found = true;
        const fn_id: postcheck.MonotypeLifted.Ast.FnId = @enumFromInt(@as(u32, @intCast(index)));
        try std.testing.expectEqual(expected, plan.bodyForFn(fn_id) != null);
    }

    try std.testing.expect(found);
}

fn rootProc(lowered: *const lir.CheckedPipeline.LoweredProgram) TestError!LIR.LirProcSpecId {
    try std.testing.expectEqual(@as(usize, 1), lowered.lir_result.root_procs.items.len);
    return lowered.lir_result.root_procs.items[0];
}

fn collectAssignCallProcs(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    proc_id: LIR.LirProcSpecId,
) TestError![]LIR.LirProcSpecId {
    const proc = lowered.lir_result.store.getProcSpec(proc_id);
    const body = proc.body orelse return allocator.alloc(LIR.LirProcSpecId, 0);

    var calls = std.ArrayList(LIR.LirProcSpecId).empty;
    errdefer calls.deinit(allocator);

    var work = std.ArrayList(LIR.CFStmtId).empty;
    defer work.deinit(allocator);
    try work.append(allocator, body);

    var visited = std.AutoHashMap(LIR.CFStmtId, void).init(allocator);
    defer visited.deinit();

    while (work.pop()) |stmt_id| {
        const visited_entry = try visited.getOrPut(stmt_id);
        if (visited_entry.found_existing) continue;

        switch (lowered.lir_result.store.getCFStmt(stmt_id)) {
            .assign_ref => |stmt| try work.append(allocator, stmt.next),
            .assign_literal => |stmt| try work.append(allocator, stmt.next),
            .init_uninitialized => |stmt| try work.append(allocator, stmt.next),
            .store_struct => |stmt| try work.append(allocator, stmt.next),
            .store_tag => |stmt| try work.append(allocator, stmt.next),
            .assign_call => |stmt| {
                try calls.append(allocator, stmt.proc);
                try work.append(allocator, stmt.next);
            },
            .assign_call_erased => |stmt| try work.append(allocator, stmt.next),
            .assign_packed_erased_fn => |stmt| try work.append(allocator, stmt.next),
            .assign_low_level => |stmt| try work.append(allocator, stmt.next),
            .assign_list => |stmt| try work.append(allocator, stmt.next),
            .assign_struct => |stmt| try work.append(allocator, stmt.next),
            .assign_tag => |stmt| try work.append(allocator, stmt.next),
            .set_local => |stmt| try work.append(allocator, stmt.next),
            .debug => |stmt| try work.append(allocator, stmt.next),
            .expect => |stmt| try work.append(allocator, stmt.next),
            .comptime_branch_taken => |stmt| try work.append(allocator, stmt.next),
            .incref => |stmt| try work.append(allocator, stmt.next),
            .decref => |stmt| try work.append(allocator, stmt.next),
            .decref_if_initialized => |stmt| try work.append(allocator, stmt.next),
            .free => |stmt| try work.append(allocator, stmt.next),
            .switch_stmt => |stmt| {
                if (stmt.continuation) |continuation| try work.append(allocator, continuation);
                try work.append(allocator, stmt.default_branch);
                for (lowered.lir_result.store.getCFSwitchBranches(stmt.branches)) |branch| {
                    try work.append(allocator, branch.body);
                }
            },
            .switch_initialized_payload => |stmt| {
                try work.append(allocator, stmt.initialized_branch);
                try work.append(allocator, stmt.uninitialized_branch);
            },
            .str_match => |stmt| {
                try work.append(allocator, stmt.on_match);
                try work.append(allocator, stmt.on_miss);
            },
            .str_match_set => |stmt| {
                for (lowered.lir_result.store.getStrMatchArms(stmt.arms)) |arm| {
                    try work.append(allocator, arm.on_match);
                }
                try work.append(allocator, stmt.on_miss);
            },
            .join => |stmt| {
                try work.append(allocator, stmt.body);
                try work.append(allocator, stmt.remainder);
            },
            .runtime_error,
            .comptime_exhaustiveness_failed,
            .loop_continue,
            .loop_break,
            .jump,
            .ret,
            .crash,
            .expect_err,
            => {},
        }
    }

    return try calls.toOwnedSlice(allocator);
}

const ProcShape = struct {
    arg_count: usize,
    direct_call_count: usize = 0,
    erased_call_count: usize = 0,
    packed_erased_fn_count: usize = 0,
    low_level_count: usize = 0,
    list_len_count: usize = 0,
    list_get_unsafe_count: usize = 0,
    list_with_capacity_count: usize = 0,
    list_append_unsafe_count: usize = 0,
    list_reserve_count: usize = 0,
    str_count_utf8_bytes_count: usize = 0,
    str_concat_count: usize = 0,
    box_box_count: usize = 0,
    box_unbox_count: usize = 0,
    box_prepare_update_count: usize = 0,
    ptr_cast_count: usize = 0,
    ptr_load_count: usize = 0,
    ptr_store_count: usize = 0,
    self_call_count: usize = 0,
    switch_count: usize = 0,
    str_match_set_count: usize = 0,
    join_count: usize = 0,
    max_join_param_count: usize = 0,
    jump_count: usize = 0,
    struct_assign_count: usize = 0,
    tag_assign_count: usize = 0,
    store_struct_count: usize = 0,
    store_tag_count: usize = 0,
};

fn collectProcShape(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    proc_id: LIR.LirProcSpecId,
) TestError!ProcShape {
    return collectLirResultProcShape(allocator, &lowered.lir_result, proc_id);
}

const IterCollectShape = enum {
    specialized,
    generic,
};

fn procShapeMatchesIterCollect(shape: ProcShape, wanted: IterCollectShape) bool {
    // Fingerprints of the `Iter.collect` -> `List.from_iter` worker over a range.
    // `from_iter` branches on the iterator's length: a Known length reserves the
    // whole allocation up front and writes each item with the unchecked append,
    // while an Unknown length grows with the reserving append. That per-element
    // branch (the inner `match length`) is the extra switch/join/jump over the
    // earlier single-append loop. Spec constr specializes the worker for the
    // concrete element type, and because ranges carry a Known length (via each
    // numeric type's `steps_between`) the specialized worker threads that count
    // as a third arg (`with_capacity` preallocation).
    return switch (wanted) {
        .specialized => shape.arg_count == 3 and
            shape.direct_call_count >= 5 and
            shape.switch_count >= 10 and
            shape.join_count >= 16 and
            shape.jump_count >= 20,
        .generic => shape.arg_count == 1 and
            shape.direct_call_count == 4 and
            shape.switch_count == 8 and
            shape.join_count == 11 and
            shape.jump_count == 15 and
            shape.struct_assign_count >= 2,
    };
}

fn reachableIterCollectShape(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    wanted: IterCollectShape,
) TestError!bool {
    var work = std.ArrayList(LIR.LirProcSpecId).empty;
    defer work.deinit(allocator);
    try work.append(allocator, try rootProc(lowered));

    var visited = std.AutoHashMap(LIR.LirProcSpecId, void).init(allocator);
    defer visited.deinit();

    while (work.pop()) |proc_id| {
        const visited_entry = try visited.getOrPut(proc_id);
        if (visited_entry.found_existing) continue;

        const shape = try collectProcShape(allocator, lowered, proc_id);
        if (procShapeMatchesIterCollect(shape, wanted)) return true;

        const calls = try collectAssignCallProcs(allocator, lowered, proc_id);
        defer allocator.free(calls);
        for (calls) |call| try work.append(allocator, call);
    }
    return false;
}

fn reachableProcShapeCount(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    comptime matches: fn (ProcShape) bool,
) TestError!usize {
    var work = std.ArrayList(LIR.LirProcSpecId).empty;
    defer work.deinit(allocator);
    try work.append(allocator, try rootProc(lowered));

    var visited = std.AutoHashMap(LIR.LirProcSpecId, void).init(allocator);
    defer visited.deinit();

    var count: usize = 0;
    while (work.pop()) |proc_id| {
        const visited_entry = try visited.getOrPut(proc_id);
        if (visited_entry.found_existing) continue;

        const shape = try collectProcShape(allocator, lowered, proc_id);
        if (matches(shape)) count += 1;

        const calls = try collectAssignCallProcs(allocator, lowered, proc_id);
        defer allocator.free(calls);
        for (calls) |call| try work.append(allocator, call);
    }
    return count;
}

fn reachableProcShape(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    comptime matches: fn (ProcShape) bool,
) TestError!bool {
    return (try reachableProcShapeCount(allocator, lowered, matches)) > 0;
}

fn markReachableLiftedExpr(
    program: *const postcheck.MonotypeLifted.Ast.Program,
    expr_id: postcheck.MonotypeLifted.Ast.ExprId,
    reachable: []bool,
) void {
    const index = @intFromEnum(expr_id);
    if (reachable[index]) return;
    reachable[index] = true;

    switch (program.exprs.items[index].data) {
        .local,
        .unit,
        .int_lit,
        .frac_f32_lit,
        .frac_f64_lit,
        .dec_lit,
        .str_lit,
        .bytes_lit,
        .crash,
        .comptime_exhaustiveness_failed,
        .uninitialized,
        .uninitialized_payload,
        => {},
        .fn_ref => |fn_ref| {
            for (program.captureOperandSpan(fn_ref.captures)) |operand| {
                markReachableLiftedExpr(program, operand.value, reachable);
            }
        },
        .list,
        .tuple,
        => |items| for (program.exprSpan(items)) |child| markReachableLiftedExpr(program, child, reachable),
        .record => |fields| for (program.fieldExprSpan(fields)) |field| markReachableLiftedExpr(program, field.value, reachable),
        .tag => |tag| for (program.exprSpan(tag.payloads)) |payload| markReachableLiftedExpr(program, payload, reachable),
        .nominal,
        .dbg,
        .expect,
        => |child| markReachableLiftedExpr(program, child, reachable),
        .return_ => |ret| markReachableLiftedExpr(program, ret.value, reachable),
        .expect_err => |expect_err| markReachableLiftedExpr(program, expect_err.msg, reachable),
        .comptime_branch_taken => |taken| markReachableLiftedExpr(program, taken.body, reachable),
        .if_initialized_payload => |switch_| {
            markReachableLiftedExpr(program, switch_.cond, reachable);
            markReachableLiftedExpr(program, switch_.initialized, reachable);
            markReachableLiftedExpr(program, switch_.uninitialized, reachable);
        },
        .try_sequence => |sequence| {
            markReachableLiftedExpr(program, sequence.try_expr, reachable);
            markReachableLiftedExpr(program, sequence.ok_body, reachable);
        },
        .try_record_sequence => |sequence| {
            markReachableLiftedExpr(program, sequence.try_expr, reachable);
            markReachableLiftedExpr(program, sequence.ok_body, reachable);
        },
        .let_ => |let_| {
            markReachableLiftedExpr(program, let_.value, reachable);
            markReachableLiftedExpr(program, let_.rest, reachable);
        },
        .lambda,
        .def_ref,
        .fn_def,
        => {},
        .call_value => |call| {
            markReachableLiftedExpr(program, call.callee, reachable);
            for (program.exprSpan(call.args)) |arg| markReachableLiftedExpr(program, arg, reachable);
        },
        .call_proc => |call| {
            for (program.exprSpan(call.args)) |arg| markReachableLiftedExpr(program, arg, reachable);
            for (program.captureOperandSpan(call.captures)) |operand| markReachableLiftedExpr(program, operand.value, reachable);
        },
        .low_level => |call| for (program.exprSpan(call.args)) |arg| markReachableLiftedExpr(program, arg, reachable),
        .field_access => |field| markReachableLiftedExpr(program, field.receiver, reachable),
        .tuple_access => |access| markReachableLiftedExpr(program, access.tuple, reachable),
        .structural_eq => |eq| {
            markReachableLiftedExpr(program, eq.lhs, reachable);
            markReachableLiftedExpr(program, eq.rhs, reachable);
        },
        .structural_hash => |h| {
            markReachableLiftedExpr(program, h.value, reachable);
            markReachableLiftedExpr(program, h.hasher, reachable);
        },
        .match_ => |match| {
            markReachableLiftedExpr(program, match.scrutinee, reachable);
            for (program.branchSpan(match.branches)) |branch| {
                if (branch.guard) |guard| markReachableLiftedExpr(program, guard, reachable);
                markReachableLiftedExpr(program, branch.body, reachable);
            }
        },
        .if_ => |if_| {
            for (program.ifBranchSpan(if_.branches)) |branch| {
                markReachableLiftedExpr(program, branch.cond, reachable);
                markReachableLiftedExpr(program, branch.body, reachable);
            }
            markReachableLiftedExpr(program, if_.final_else, reachable);
        },
        .block => |block| {
            for (program.stmtSpan(block.statements)) |stmt| markReachableLiftedStmt(program, stmt, reachable);
            markReachableLiftedExpr(program, block.final_expr, reachable);
        },
        .loop_ => |loop| {
            for (program.exprSpan(loop.initial_values)) |initial| markReachableLiftedExpr(program, initial, reachable);
            markReachableLiftedExpr(program, loop.body, reachable);
        },
        .break_ => |maybe| if (maybe) |value| markReachableLiftedExpr(program, value, reachable),
        .continue_ => |continue_| for (program.exprSpan(continue_.values)) |value| markReachableLiftedExpr(program, value, reachable),
    }
}

fn markReachableLiftedStmt(
    program: *const postcheck.MonotypeLifted.Ast.Program,
    stmt_id: postcheck.MonotypeLifted.Ast.StmtId,
    reachable: []bool,
) void {
    switch (program.stmts.items[@intFromEnum(stmt_id)]) {
        .let_ => |let_| markReachableLiftedExpr(program, let_.value, reachable),
        .expr,
        .expect,
        .dbg,
        => |expr| markReachableLiftedExpr(program, expr, reachable),
        .return_ => |ret| markReachableLiftedExpr(program, ret.value, reachable),
        .crash => {},
        .uninitialized => {},
    }
}

fn countUnreachableLiftedDirectCalls(
    allocator: Allocator,
    program: *const postcheck.MonotypeLifted.Ast.Program,
) TestError!usize {
    const reachable = try allocator.alloc(bool, program.exprs.items.len);
    defer allocator.free(reachable);
    @memset(reachable, false);

    for (program.fns.items) |fn_| {
        switch (fn_.body) {
            .roc => |body| markReachableLiftedExpr(program, body, reachable),
            .hosted => {},
        }
    }

    var count: usize = 0;
    for (program.exprs.items, reachable) |expr, is_reachable| {
        if (!is_reachable and expr.data == .call_proc) count += 1;
    }
    return count;
}

fn directRecordWorkerIsSpecialized(shape: ProcShape) bool {
    return shape.arg_count == 2 and
        shape.self_call_count == 0 and
        shape.jump_count >= 1 and
        shape.struct_assign_count == 0;
}

fn directRecordWorkerIsGeneric(shape: ProcShape) bool {
    return shape.arg_count == 1 and
        shape.self_call_count == 0 and
        shape.jump_count >= 1 and
        shape.struct_assign_count >= 1;
}

fn whileRecordStateWorkerIsSpecialized(shape: ProcShape) bool {
    return shape.arg_count == 1 and
        shape.self_call_count == 0 and
        shape.join_count >= 1 and
        shape.max_join_param_count == 2 and
        shape.jump_count >= 2;
}

fn whileRecordStateWorkerIsGeneric(shape: ProcShape) bool {
    return shape.arg_count == 1 and
        shape.self_call_count == 0 and
        shape.join_count >= 1 and
        shape.max_join_param_count == 1 and
        shape.jump_count >= 2;
}

fn directTupleWorkerIsSpecialized(shape: ProcShape) bool {
    return shape.arg_count == 2 and
        shape.self_call_count == 0 and
        shape.jump_count >= 1 and
        shape.struct_assign_count == 0;
}

fn directTupleWorkerIsGeneric(shape: ProcShape) bool {
    return shape.arg_count == 1 and
        shape.self_call_count == 0 and
        shape.jump_count >= 1 and
        shape.struct_assign_count >= 1;
}

fn unusedStateWorkerIsSpecialized(shape: ProcShape) bool {
    return shape.arg_count == 2 and
        shape.self_call_count == 0 and
        shape.jump_count >= 1 and
        shape.struct_assign_count == 0;
}

fn unusedStateWorkerIsGeneric(shape: ProcShape) bool {
    return shape.arg_count == 2 and
        shape.self_call_count == 0 and
        shape.jump_count >= 1 and
        shape.struct_assign_count >= 1;
}

fn taggedStepWorkerIsSpecialized(shape: ProcShape) bool {
    return shape.arg_count == 2 and
        shape.self_call_count == 0 and
        shape.jump_count >= 1 and
        shape.tag_assign_count == 0;
}

fn taggedStepWorkerIsGeneric(shape: ProcShape) bool {
    return shape.arg_count == 2 and
        shape.self_call_count == 0 and
        shape.jump_count >= 1 and
        shape.tag_assign_count >= 1;
}

fn multiTupleWorkerIsFullySpecialized(shape: ProcShape) bool {
    return shape.arg_count == 5 and
        shape.self_call_count == 0 and
        shape.jump_count >= 1 and
        shape.struct_assign_count == 0;
}

fn multiTupleWorkerIsGeneric(shape: ProcShape) bool {
    return shape.arg_count == 3 and
        shape.self_call_count == 0 and
        shape.jump_count >= 1 and
        shape.struct_assign_count >= 2;
}

fn opaqueLetCallWorkerDoesNotDuplicateCall(shape: ProcShape) bool {
    return shape.arg_count == 1 and
        shape.direct_call_count == 0 and
        shape.low_level_count == 2 and
        shape.struct_assign_count == 0;
}

fn opaqueLetCallWorkerDuplicatesCall(shape: ProcShape) bool {
    return shape.arg_count == 1 and
        shape.low_level_count > 2 and
        shape.struct_assign_count == 0;
}

fn hasGroupedStrMatchSet(shape: ProcShape) bool {
    return shape.str_match_set_count == 1;
}

fn rootDirectCallTarget(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
) TestError!LIR.LirProcSpecId {
    const root = try rootProc(lowered);
    const root_calls = try collectAssignCallProcs(allocator, lowered, root);
    defer allocator.free(root_calls);

    try std.testing.expectEqual(@as(usize, 1), root_calls.len);
    return root_calls[0];
}

fn expectRootDirectCallCount(
    source: []const u8,
    inline_mode: lir.CheckedPipeline.InlineMode,
    expected: usize,
) TestError!void {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator, source, inline_mode);
    defer lowered_source.deinit(allocator);

    const root_calls = try collectAssignCallProcs(allocator, &lowered_source.lowered, try rootProc(&lowered_source.lowered));
    defer allocator.free(root_calls);

    try std.testing.expectEqual(expected, root_calls.len);
}

fn expectRootTargetHasCalls(
    source: []const u8,
    inline_mode: lir.CheckedPipeline.InlineMode,
) TestError!void {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator, source, inline_mode);
    defer lowered_source.deinit(allocator);

    const target = try rootDirectCallTarget(allocator, &lowered_source.lowered);
    const target_calls = try collectAssignCallProcs(allocator, &lowered_source.lowered, target);
    defer allocator.free(target_calls);

    try std.testing.expect(target_calls.len > 0);
}

fn nestedSite(def: postcheck.Monotype.Ast.NestedDef) ?postcheck.Monotype.Ast.NestedFn {
    return switch (def.fn_def.fn_def) {
        .nested => |site| site,
        else => null,
    };
}

fn sameNestedSourceSite(
    lhs: postcheck.Monotype.Ast.NestedFn,
    rhs: postcheck.Monotype.Ast.NestedFn,
) bool {
    return std.mem.eql(u8, lhs.owner.artifact.bytes[0..], rhs.owner.artifact.bytes[0..]) and
        lhs.owner.proc_base == rhs.owner.proc_base and
        lhs.owner.template == rhs.owner.template and
        lhs.site == rhs.site;
}

test "issue 9802 same-type map2 specialization counters are bounded" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\Boxed(a) := [Boxed(a)]
        \\
        \\const : a -> Boxed(a)
        \\const = |value| Boxed(value)
        \\
        \\map2 : Boxed(a), Boxed(b), (a, b -> c) -> Boxed(c)
        \\map2 = |Boxed(left), Boxed(right), f| Boxed(f(left, right))
        \\
        \\unwrap : Boxed(a) -> a
        \\unwrap = |Boxed(value)| value
        \\
        \\main : I64
        \\main = {
        \\    v0 = const(0)
        \\    v1 = map2(v0, const(1), |a, b| a + b)
        \\    v2 = map2(v1, const(2), |a, b| a + b)
        \\    v3 = map2(v2, const(3), |a, b| a + b)
        \\    v4 = map2(v3, const(4), |a, b| a + b)
        \\    v5 = map2(v4, const(5), |a, b| a + b)
        \\    v6 = map2(v5, const(6), |a, b| a + b)
        \\    v7 = map2(v6, const(7), |a, b| a + b)
        \\    v8 = map2(v7, const(8), |a, b| a + b)
        \\    unwrap(v8)
        \\}
    ;

    const counters = try monotypeCountersForModule(allocator, source);

    try std.testing.expectEqual(postcheck.Monotype.Lower.SpecializationCounters{
        .template_requests = 53,
        .template_hits = 22,
        .template_misses = 5,
        .nested_requests = 8,
        .nested_hits = 0,
        .nested_misses = 8,
        .template_lookup_candidates = 22,
        .nested_lookup_candidates = 0,
        .specialization_type_digest_requests = 75,
        .specialization_type_digest_cache_hits = 140,
        .specialization_type_digest_cache_misses = 128,
        .specialization_type_digest_nodes_visited = 128,
        .exact_type_checks = 22,
    }, counters);
}

test "issue 9802 growing-structural map2 specialization counters are bounded" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\Boxed(a) := [Boxed(a)]
        \\
        \\const : a -> Boxed(a)
        \\const = |value| Boxed(value)
        \\
        \\map2 : Boxed(a), Boxed(b), (a, b -> c) -> Boxed(c)
        \\map2 = |Boxed(left), Boxed(right), f| Boxed(f(left, right))
        \\
        \\unwrap : Boxed(a) -> a
        \\unwrap = |Boxed(value)| value
        \\
        \\main : I64
        \\main = {
        \\    v0 = const(0)
        \\    v1 = map2(v0, const(1), |acc, n| { acc, n1: n })
        \\    v2 = map2(v1, const(2), |acc, n| { acc, n2: n })
        \\    v3 = map2(v2, const(3), |acc, n| { acc, n3: n })
        \\    v4 = map2(v3, const(4), |acc, n| { acc, n4: n })
        \\    v5 = map2(v4, const(5), |acc, n| { acc, n5: n })
        \\    v6 = map2(v5, const(6), |acc, n| { acc, n6: n })
        \\    unwrap(v6).n6
        \\}
    ;

    const counters = try monotypeCountersForModule(allocator, source);

    try std.testing.expectEqual(postcheck.Monotype.Lower.SpecializationCounters{
        .template_requests = 29,
        .template_hits = 5,
        .template_misses = 10,
        .nested_requests = 6,
        .nested_hits = 0,
        .nested_misses = 6,
        .template_lookup_candidates = 5,
        .nested_lookup_candidates = 0,
        .specialization_type_digest_requests = 52,
        .specialization_type_digest_cache_hits = 245,
        .specialization_type_digest_cache_misses = 290,
        .specialization_type_digest_nodes_visited = 290,
        .exact_type_checks = 5,
    }, counters);
}

test "imported and local generic specialization counters reuse closed types" {
    const allocator = std.testing.allocator;
    const util_module =
        \\module [identity]
        \\
        \\identity : a -> a
        \\identity = |value| value
    ;
    const source =
        \\module [main]
        \\
        \\import Util exposing [identity]
        \\
        \\Boxed(a) := [Boxed(a)]
        \\
        \\local_identity : a -> a
        \\local_identity = |value| value
        \\
        \\main : { imported_a : Boxed(U64), imported_b : Boxed(U64), local_a : Boxed(U64), local_b : Boxed(U64) }
        \\main = {
        \\    value = Boxed(1)
        \\    {
        \\        imported_a: identity(value),
        \\        imported_b: identity(value),
        \\        local_a: local_identity(value),
        \\        local_b: local_identity(value),
        \\    }
        \\}
    ;

    const counters = try monotypeCountersForModuleWithImports(allocator, source, &.{
        .{ .name = "Util", .source = util_module },
    });

    try std.testing.expect(counters.template_requests >= 4);
    try std.testing.expect(counters.template_misses >= 2);
    try std.testing.expect(counters.template_hits >= 2);
    try std.testing.expect(counters.template_lookup_candidates <= counters.template_requests);
}

test "disabling monotype specialization cache does not change monotype output" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\identity : a -> a
        \\identity = |value| value
        \\
        \\main : { n : U64, flag : Bool }
        \\main = {
        \\    { n: identity(1), flag: identity(Bool.True) }
        \\}
    ;

    var default = try lowerMonotypeModule(allocator, source);
    defer default.deinit(allocator);

    var disabled = try lowerMonotypeModuleWithOptions(allocator, source, .{
        .specialization_cache = .disabled,
    });
    defer disabled.deinit(allocator);

    try expectEquivalentMonotypeProgramViews(default.mono.view(), disabled.mono.view());
}

test "monotype specialization cache read reuses loaded hits and lowers fresh misses" {
    const allocator = std.testing.allocator;
    const mixed_source =
        \\module [main]
        \\
        \\identity : a -> a
        \\identity = |value| value
        \\
        \\main : { n : U64, flag : Bool }
        \\main = {
        \\    { n: identity(1), flag: identity(Bool.True) }
        \\}
    ;

    var loaded_program = try lowerMonotypeModule(allocator, mixed_source);
    defer loaded_program.deinit(allocator);
    const loaded_program_view = loaded_program.mono.view();

    const selected_loaded_spec = for (loaded_program_view.specs) |record| {
        if (isUnaryPrimitiveFnSpec(loaded_program_view, record, .u64)) break record;
    } else return error.MissingProcSpec;
    const loaded_specs = [_]MonoAst.SpecRecord{selected_loaded_spec};

    const loaded_types = try durableTypeSnapshot(allocator, &loaded_program.mono);
    defer loaded_types.deinit(allocator);
    const loaded_shards = [_]MonoLower.LoadedSpecializationShard{.{
        .shard_id = @enumFromInt(1),
        .types = loaded_types.view,
        .specs = &loaded_specs,
    }};

    var no_cache = try lowerMonotypeModuleWithOptions(allocator, mixed_source, .{
        .specialization_cache = .disabled,
    });
    defer no_cache.deinit(allocator);

    var counters: MonoLower.SpecializationCounters = .{};
    var cached = try lowerMonotypeModuleWithOptions(allocator, mixed_source, .{
        .specialization_cache = .{},
        .loaded_specialization_shards = &loaded_shards,
        .specialization_counters = &counters,
    });
    defer cached.deinit(allocator);

    try std.testing.expect(cached.mono.view().imported_fns.len > 0);
    try std.testing.expect(cached.mono.view().specs.len < no_cache.mono.view().specs.len);
    try std.testing.expect(counters.template_hits > 0);
    try std.testing.expect(counters.template_misses > 0);
    try expectSpecsCoveredByCachedOrLoaded(allocator, no_cache.mono.view(), cached.mono.view(), loaded_shards[0]);
}

test "nested function specializations keep equal types at different sites distinct" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\first : U64 -> U64
        \\first = |n| {
        \\    id = |x| x
        \\    id(n)
        \\}
        \\
        \\second : U64 -> U64
        \\second = |n| {
        \\    id = |x| x
        \\    id(n)
        \\}
        \\
        \\main : { first : U64, second : U64 }
        \\main = { first: first(1), second: second(2) }
    ;

    var lowered = try lowerMonotypeModule(allocator, source);
    defer lowered.deinit(allocator);

    var found_distinct_sites = false;
    for (lowered.mono.nested_defs.items, 0..) |lhs, lhs_index| {
        const lhs_site = nestedSite(lhs) orelse continue;
        for (lowered.mono.nested_defs.items[lhs_index + 1 ..]) |rhs| {
            const rhs_site = nestedSite(rhs) orelse continue;
            if (!sameNestedSourceSite(lhs_site, rhs_site) and
                try lowered.mono.types.typeEql(&lowered.mono.names, lhs.fn_def.mono_fn_ty, rhs.fn_def.mono_fn_ty))
            {
                found_distinct_sites = true;
            }
        }
    }

    try std.testing.expect(found_distinct_sites);
}

test "one nested function site specializes at multiple closed function types" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\choose : a -> a
        \\choose = |value| {
        \\    id = |x| x
        \\    id(value)
        \\}
        \\
        \\main : { n : U64, s : Str }
        \\main = { n: choose(1), s: choose("hi") }
    ;

    var lowered = try lowerMonotypeModule(allocator, source);
    defer lowered.deinit(allocator);

    var found_same_site_distinct_types = false;
    for (lowered.mono.nested_defs.items, 0..) |lhs, lhs_index| {
        const lhs_site = nestedSite(lhs) orelse continue;
        for (lowered.mono.nested_defs.items[lhs_index + 1 ..]) |rhs| {
            const rhs_site = nestedSite(rhs) orelse continue;
            if (!sameNestedSourceSite(lhs_site, rhs_site)) continue;
            if (lhs.fn_def.mono_fn_ty != rhs.fn_def.mono_fn_ty) {
                found_same_site_distinct_types = true;
            }
        }
    }

    try std.testing.expect(found_same_site_distinct_types);
}

test "differently ordered source record rows produce normalized monotype rows" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\choose : Bool -> { a : U64, b : U64 }
        \\choose = |flag| if flag { b: 2, a: 1 } else { a: 3, b: 4 }
        \\
        \\main : { a : U64, b : U64 }
        \\main = choose(Bool.True)
    ;

    var resources = try helpers.parseAndCanonicalizeProgramWithBuiltin(allocator, .module, source, &.{}, try sharedPrePublishedBuiltin());
    defer helpers.cleanupParseAndCanonical(allocator, resources);

    const import_count = resources.import_artifacts.len + if (resources.borrowed_builtin_artifact == null) @as(usize, 0) else 1;
    const import_views = try allocator.alloc(check.CheckedArtifact.ImportedModuleView, import_count);
    defer allocator.free(import_views);

    var view_index: usize = 0;
    if (resources.borrowed_builtin_artifact) |builtin_artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(builtin_artifact);
        view_index += 1;
    }
    for (resources.import_artifacts) |*artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(artifact);
        view_index += 1;
    }

    var mono = try postcheck.Monotype.Lower.run(
        allocator,
        .{
            .root = check.CheckedArtifact.loweringView(&resources.checked_artifact),
            .imports = import_views,
        },
        .{ .requests = resources.checked_artifact.root_requests.requests },
        .{},
    );
    defer mono.deinit();

    try std.testing.expect(mono.specs.items.len > 0);
    for (mono.specs.items) |spec| {
        try std.testing.expectEqual(postcheck.Monotype.Ast.SpecStatus.ready, spec.status);
    }

    const a_name = try mono.names.internRecordFieldLabel("a");
    const b_name = try mono.names.internRecordFieldLabel("b");
    var normalized_rows: usize = 0;
    for (mono.types.types.items) |content| {
        const span = switch (content) {
            .record => |fields| fields,
            else => continue,
        };
        const fields = mono.types.fieldSpan(span);
        if (fields.len != 2) continue;
        if (fields[0].name == a_name and fields[1].name == b_name) {
            normalized_rows += 1;
        } else if (fields[0].name == b_name and fields[1].name == a_name) {
            return error.TestUnexpectedResult;
        }
    }

    try std.testing.expect(normalized_rows > 0);
}

test "direct call wrapper is inlined when inline mode is enabled" {
    try expectRootDirectCallCount(
        \\callee : U64 -> U64
        \\callee = |x| x + 1
        \\
        \\wrapper : U64 -> U64
        \\wrapper = |x| callee(x)
        \\
        \\main : U64
        \\main = wrapper(41)
    , .wrappers, 0);
}

test "direct call wrapper is not inlined when inline mode is none" {
    try expectRootTargetHasCalls(
        \\callee : U64 -> U64
        \\callee = |x| x + 1
        \\
        \\wrapper : U64 -> U64
        \\wrapper = |x| callee(x)
        \\
        \\main : U64
        \\main = wrapper(41)
    , .none);
}

test "zero statement block wrapper is inlined" {
    try expectRootDirectCallCount(
        \\callee : U64 -> U64
        \\callee = |x| x + 1
        \\
        \\wrapper : U64 -> U64
        \\wrapper = |x| {
        \\    callee(x)
        \\}
        \\
        \\main : U64
        \\main = wrapper(41)
    , .wrappers, 0);
}

test "low level wrapper is inlined when inline mode is enabled" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\main : Str -> U64
        \\main = |str| Str.count_utf8_bytes(str)
    , .wrappers);
    defer lowered_source.deinit(allocator);

    const shape = try collectProcShape(allocator, &lowered_source.lowered, try rootProc(&lowered_source.lowered));
    try std.testing.expectEqual(@as(usize, 0), shape.direct_call_count);
    try std.testing.expectEqual(@as(usize, 1), shape.str_count_utf8_bytes_count);
}

test "block wrapper with statements is not inlined" {
    try expectInlinePlanDecision(
        \\callee : U64 -> U64
        \\callee = |x| x + 1
        \\
        \\wrapper : U64 -> U64
        \\wrapper = |x| {
        \\    y = x
        \\    callee(y)
        \\}
        \\
        \\main : U64
        \\main = wrapper(41)
    , "wrapper", false);
}

test "call value wrapper is not inlined" {
    try expectInlinePlanDecision(
        \\callee : U64 -> U64
        \\callee = |x| x + 1
        \\
        \\apply : (U64 -> U64), U64 -> U64
        \\apply = |fn, x| fn(x)
        \\
        \\main : U64
        \\main = apply(callee, 41)
    , "apply", false);
}

test "self-recursive direct wrapper is not inlined" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\wrapper : U64 -> U64
        \\wrapper = |x| wrapper(x)
        \\
        \\main : U64 -> U64
        \\main = |x| wrapper(x)
    , .wrappers);
    defer lowered_source.deinit(allocator);

    // The root still calls the wrapper as a separate proc (not inlined). The
    // wrapper's own self-call is gone: the TRMC pass rewrote it into a tail
    // jump, recorded as a TCE transform.
    const target = try rootDirectCallTarget(allocator, &lowered_source.lowered);
    try std.testing.expectEqual(
        LIR.TailTransform.tce,
        lowered_source.lowered.lir_result.store.getProcSpec(target).tail_transform,
    );
    const target_calls = try collectAssignCallProcs(allocator, &lowered_source.lowered, target);
    defer allocator.free(target_calls);
    try std.testing.expectEqual(@as(usize, 0), target_calls.len);
}

test "mutually recursive direct wrappers are not inlined" {
    try expectRootTargetHasCalls(
        \\a : U64 -> U64
        \\a = |x| b(x)
        \\
        \\b : U64 -> U64
        \\b = |x| a(x)
        \\
        \\main : U64 -> U64
        \\main = |x| a(x)
    , .wrappers);
}

test "capturing direct wrapper is not inlined" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\callee : U64 -> U64
        \\callee = |x| x + 1
        \\
        \\main : U64 -> U64
        \\main = |offset| {
        \\    wrapper = |x| callee(x + offset)
        \\    wrapper(41)
        \\}
    , .wrappers);
    defer lowered_source.deinit(allocator);

    const root_calls = try collectAssignCallProcs(allocator, &lowered_source.lowered, try rootProc(&lowered_source.lowered));
    defer allocator.free(root_calls);

    try std.testing.expectEqual(@as(usize, 1), root_calls.len);
    const target_shape = try collectProcShape(allocator, &lowered_source.lowered, root_calls[0]);
    try std.testing.expectEqual(@as(usize, 2), target_shape.arg_count);
}
// ─── TRMC pass outcomes through the full pipeline ───

fn expectRootTargetTailTransform(
    source: []const u8,
    expected: LIR.TailTransform,
) TestError!void {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator, source, .none);
    defer lowered_source.deinit(allocator);

    const target = try rootDirectCallTarget(allocator, &lowered_source.lowered);
    try std.testing.expectEqual(
        expected,
        lowered_source.lowered.lir_result.store.getProcSpec(target).tail_transform,
    );
}

test "trmc: recursive list builder is TRMC-transformed through the pipeline" {
    try expectRootTargetTailTransform(
        \\LinkedList := [Nil, Cons(I64, LinkedList)]
        \\
        \\repeat : I64, I64 -> LinkedList
        \\repeat = |value, n| if n <= 0.I64 LinkedList.Nil else LinkedList.Cons(value, repeat(value, n - 1))
        \\
        \\main = repeat(7.I64, 3.I64)
    , .trmc);
}

test "trmc: accumulator recursion is TCE-transformed through the pipeline" {
    try expectRootTargetTailTransform(
        \\sum_to : I64, I64 -> I64
        \\sum_to = |n, acc| if n == 0.I64 acc else sum_to(n - 1, acc + n)
        \\
        \\main = sum_to(10.I64, 0.I64)
    , .tce);
}

test "trmc: result used before the constructor is not transformed" {
    try expectRootTargetTailTransform(
        \\LinkedList := [Nil, Cons(I64, LinkedList)]
        \\
        \\length_acc : LinkedList, I64 -> I64
        \\length_acc = |list, acc| match list {
        \\    Nil => acc
        \\    Cons(_, rest) => length_acc(rest, acc + 1)
        \\}
        \\
        \\with_lengths : I64 -> LinkedList
        \\with_lengths = |n| if n <= 0.I64 LinkedList.Nil else {
        \\    rest = with_lengths(n - 1)
        \\    LinkedList.Cons(length_acc(rest, 0), rest)
        \\}
        \\
        \\main = with_lengths(4.I64)
    , .none);
}

test "known-length List.iter collect specializes without unbound locals" {
    // Regression: collecting a Known-length iterator (List.iter) under
    // optimization specializes a recursive capturing worker (List.iter's `make`
    // step). The specializer must reuse the source capture local ids; otherwise
    // a leftover direct call to the un-specialized worker references an unbound
    // capture local, which the ARC borrow certifier rejects. (Also exercises the
    // ARC use-after-realloc fix, since main's rewrite emits an owned variant.)
    const allocator = std.testing.allocator;
    var optimized = try lowerModule(allocator,
        \\main : List(I64)
        \\main =
        \\    Iter.collect(
        \\        Iter.map(List.iter([1.I64, 2, 3]), |i| i * 12),
        \\    )
    , .wrappers);
    defer optimized.deinit(allocator);
}

test "spec constr does not duplicate opaque let-bound direct calls" {
    const allocator = std.testing.allocator;
    const source =
        \\State : { n : I64 }
        \\
        \\tick : I64 -> I64
        \\tick = |n| n + 1
        \\
        \\read_twice : State -> I64
        \\read_twice = |state| {
        \\    x = tick(state.n)
        \\    x + x
        \\}
        \\
        \\main : I64
        \\main = read_twice({ n: 1 })
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, opaqueLetCallWorkerDoesNotDuplicateCall));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, opaqueLetCallWorkerDuplicatesCall));
}

test "spec constr does not duplicate opaque known-match payloads" {
    const allocator = std.testing.allocator;
    const source =
        \\State : { n : I64 }
        \\Step : [One(I64)]
        \\
        \\tick : I64 -> I64
        \\tick = |n| n + 1
        \\
        \\read_twice : State -> I64
        \\read_twice = |state|
        \\    match One(tick(state.n)) {
        \\        One(x) => x + x
        \\    }
        \\
        \\main : I64
        \\main = read_twice({ n: 1 })
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, opaqueLetCallWorkerDoesNotDuplicateCall));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, opaqueLetCallWorkerDuplicatesCall));
}

test "spec constr preserves direct call argument effect order" {
    try expectOptimizedDbgEvents(
        \\State : { n : I64 }
        \\
        \\tap : I64 -> I64
        \\tap = |n| {
        \\    dbg "arg"
        \\    n
        \\}
        \\
        \\use_after : State, I64 -> I64
        \\use_after = |state, x| {
        \\    dbg "callee-before"
        \\    state.n + x
        \\}
        \\
        \\outer : State -> I64
        \\outer = |state|
        \\    use_after({ n: state.n }, tap(state.n))
        \\
        \\main : I64
        \\main = outer({ n: 1 })
    , &.{ "\"arg\"", "\"callee-before\"" });
}

test "spec constr preserves left-to-right order for multiple unsafe call args" {
    try expectOptimizedDbgEvents(
        \\State : { n : I64 }
        \\
        \\tap_one : I64 -> I64
        \\tap_one = |n| {
        \\    dbg "arg-one"
        \\    n
        \\}
        \\
        \\tap_two : I64 -> I64
        \\tap_two = |n| {
        \\    dbg "arg-two"
        \\    n + 1
        \\}
        \\
        \\combine_after : State, I64, I64 -> I64
        \\combine_after = |state, x, y| {
        \\    dbg "callee-before"
        \\    state.n + x + y
        \\}
        \\
        \\outer : State -> I64
        \\outer = |state|
        \\    combine_after({ n: state.n }, tap_one(state.n), tap_two(state.n))
        \\
        \\main : I64
        \\main = outer({ n: 1 })
    , &.{ "\"arg-one\"", "\"arg-two\"", "\"callee-before\"" });
}

test "spec constr preserves substituted capture order before direct call args" {
    try expectOptimizedDbgEvents(
        \\State : { n : I64 }
        \\
        \\tap_capture : I64 -> I64
        \\tap_capture = |n| {
        \\    dbg "capture"
        \\    n
        \\}
        \\
        \\tap_arg : I64 -> I64
        \\tap_arg = |n| {
        \\    dbg "arg"
        \\    n
        \\}
        \\
        \\outer : State, I64 -> I64
        \\outer = |state, seed| {
        \\    inner = |next, arg| {
        \\        dbg "callee-before"
        \\        seed + next.n + arg
        \\    }
        \\    inner({ n: seed }, tap_arg(state.n))
        \\}
        \\
        \\main : I64
        \\main = outer({ n: 1 }, tap_capture(2))
    , &.{ "\"capture\"", "\"arg\"", "\"callee-before\"" });
}

test "spec constr preserves callable argument effect order" {
    try expectOptimizedDbgEvents(
        \\State : { n : I64 }
        \\
        \\tap : I64 -> I64
        \\tap = |n| {
        \\    dbg "arg"
        \\    n
        \\}
        \\
        \\call_it : State, (I64 -> I64) -> I64
        \\call_it = |state, f|
        \\    f(tap(state.n))
        \\
        \\outer : State -> I64
        \\outer = |state| {
        \\    f = |x| {
        \\        dbg "fn-before"
        \\        x
        \\    }
        \\    call_it({ n: state.n }, f)
        \\}
        \\
        \\main : I64
        \\main = outer({ n: 1 })
    , &.{ "\"arg\"", "\"fn-before\"" });
}

test "spec constr preserves known-match single-use payload effect order" {
    try expectOptimizedDbgEvents(
        \\State : { n : I64 }
        \\Step : [One(I64)]
        \\
        \\tap : I64 -> I64
        \\tap = |n| {
        \\    dbg "payload"
        \\    n
        \\}
        \\
        \\outer : State -> I64
        \\outer = |state|
        \\    match One(tap(state.n)) {
        \\        One(x) => {
        \\            dbg "branch-before"
        \\            x
        \\        }
        \\    }
        \\
        \\main : I64
        \\main = outer({ n: 1 })
    , &.{ "\"payload\"", "\"branch-before\"" });
}

test "spec constr preserves nested known-match payload effect order" {
    try expectOptimizedDbgEvents(
        \\State : { n : I64 }
        \\Step : [One({ item : I64 })]
        \\
        \\tap : I64 -> I64
        \\tap = |n| {
        \\    dbg "payload"
        \\    n
        \\}
        \\
        \\consume : State, Step -> I64
        \\consume = |state, step|
        \\    match step {
        \\        One({ item }) => {
        \\            dbg "branch-before"
        \\            state.n + item
        \\        }
        \\    }
        \\
        \\outer : State -> I64
        \\outer = |state|
        \\    consume({ n: state.n }, One({ item: tap(state.n) }))
        \\
        \\main : I64
        \\main = outer({ n: 1 })
    , &.{ "\"payload\"", "\"branch-before\"" });
}

test "spec constr writes dynamically discovered workers once" {
    const allocator = std.testing.allocator;
    const source =
        \\Step : [Start(I64), Loop(I64)]
        \\
        \\go : Step -> I64
        \\go = |step|
        \\    match step {
        \\        Start(n) => {
        \\            next = Loop(n)
        \\            go(next)
        \\        }
        \\        Loop(n) => tick(n)
        \\    }
        \\
        \\tick : I64 -> I64
        \\tick = |n| n + 1
        \\
        \\main : I64
        \\main = go(Start(1))
    ;

    var lifted = try liftModuleAfterSpecConstr(allocator, source);
    defer lifted.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), try countUnreachableLiftedDirectCalls(allocator, &lifted.lifted));
}

test "spec constr specializes recursive record state" {
    const allocator = std.testing.allocator;
    const source =
        \\State : { n : I64, acc : I64 }
        \\
        \\sum_record : State -> I64
        \\sum_record = |state|
        \\    if state.n == 0 {
        \\        state.acc
        \\    } else {
        \\        sum_record({ n: state.n - 1, acc: state.acc + state.n })
        \\    }
        \\
        \\main : I64
        \\main = sum_record({ n: 4, acc: 0 })
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    // Adapted from the GHC code base's SpecConstr examples for inspected loop state.
    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, directRecordWorkerIsSpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, directRecordWorkerIsGeneric));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, directRecordWorkerIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, directRecordWorkerIsGeneric));
}

test "spec constr specializes record state carried by while loop" {
    const allocator = std.testing.allocator;
    const source =
        \\Start : { n : I64 }
        \\State : { n : I64, acc : I64 }
        \\
        \\sum_from : Start -> I64
        \\sum_from = |start| {
        \\    var $state = { n: start.n, acc: 0 }
        \\
        \\    while $state.n != 0 {
        \\        $state = { n: $state.n - 1, acc: $state.acc + $state.n }
        \\    }
        \\
        \\    $state.acc
        \\}
        \\
        \\main : I64
        \\main = sum_from({ n: 4 })
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWorkerIsSpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWorkerIsGeneric));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWorkerIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWorkerIsGeneric));
}

test "spec constr specializes recursive tuple state" {
    const allocator = std.testing.allocator;
    const source =
        \\sum_tuple : (I64, I64) -> I64
        \\sum_tuple = |state|
        \\    match state {
        \\        (n, acc) =>
        \\            if n == 0 {
        \\                acc
        \\            } else {
        \\                sum_tuple((n - 1, acc + n))
        \\            }
        \\    }
        \\
        \\main : I64
        \\main = sum_tuple((4, 0))
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    // Adapted from the GHC code base's SpecConstr strict-tuple examples.
    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, directTupleWorkerIsSpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, directTupleWorkerIsGeneric));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, directTupleWorkerIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, directTupleWorkerIsGeneric));
}

test "spec constr leaves uninspected constructor arguments generic" {
    const allocator = std.testing.allocator;
    const source =
        \\unused_state : { n : I64 }, I64 -> I64
        \\unused_state = |state, n|
        \\    if n == 0 {
        \\        0
        \\    } else {
        \\        unused_state({ n: n }, n - 1)
        \\    }
        \\
        \\main : I64
        \\main = unused_state({ n: 0 }, 3)
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    // Adapted from the GHC code base's Note [Good arguments].
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, unusedStateWorkerIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, unusedStateWorkerIsGeneric));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, unusedStateWorkerIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, unusedStateWorkerIsGeneric));
}

test "spec constr specializes tagged recursive state" {
    const allocator = std.testing.allocator;
    const source =
        \\Step : [Done, More(I64)]
        \\
        \\count_down : Step, I64 -> I64
        \\count_down = |step, acc|
        \\    match step {
        \\        Done => acc
        \\        More(n) =>
        \\            if n == 0 {
        \\                count_down(Done, acc)
        \\            } else {
        \\                count_down(More(n - 1), acc + n)
        \\            }
        \\    }
        \\
        \\main : I64
        \\main = count_down(More(4), 0)
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    // Adapted from the GHC code base's SpecConstr constructor-call examples.
    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, taggedStepWorkerIsSpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, taggedStepWorkerIsGeneric));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, taggedStepWorkerIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, taggedStepWorkerIsGeneric));
}

test "spec constr uses fully known entry shape for multiple tuple states" {
    const allocator = std.testing.allocator;
    const source =
        \\roman : I64, (I64, I64), (I64, I64) -> I64
        \\roman = |n, p, q|
        \\    if n == 0 {
        \\        p.0 + q.0
        \\    } else if n > 2 {
        \\        roman(n - 1, (p.1, p.0), q)
        \\    } else {
        \\        roman(n - 1, p, (q.1, q.0))
        \\    }
        \\
        \\main : I64
        \\main = roman(4, (1, 2), (3, 4))
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    // Adapted from the GHC code base's testsuite/tests/eyeball/spec-constr1.hs.
    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, multiTupleWorkerIsFullySpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, multiTupleWorkerIsGeneric));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, multiTupleWorkerIsFullySpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, multiTupleWorkerIsGeneric));
}

test "LIR statements and procs carry resolved source locations" {
    const allocator = std.testing.allocator;

    const source =
        \\add2 : U64 -> U64
        \\add2 = |n| n + 2
        \\
        \\mul3 : U64 -> U64
        \\mul3 = |n| n * 3
        \\
        \\main : U64
        \\main = {
        \\    x = 40
        \\    mul3(add2(x))
        \\}
    ;

    var lowered_source = try lowerModuleWithProcDebugNames(allocator, source, .none, true);
    defer lowered_source.deinit(allocator);

    const store = &lowered_source.lowered.lir_result.store;
    try std.testing.expectEqual(store.cf_stmts.items.len, store.cf_stmt_locs.items.len);
    try std.testing.expectEqual(store.cf_stmts.items.len, store.cf_stmt_regions.items.len);
    try std.testing.expectEqual(store.proc_specs.items.len, store.proc_locs.items.len);
    try std.testing.expect(store.proc_debug_names.items.len > 0);
    for (store.proc_debug_names.items) |entry| {
        try std.testing.expect(entry.proc < store.proc_specs.items.len);
    }
    try std.testing.expect(store.sourceFileCount() >= 1);

    var located: usize = 0;
    for (store.cf_stmt_locs.items, store.cf_stmt_regions.items, store.cf_stmts.items) |loc, region, stmt| {
        const has_source = switch (stmt) {
            .incref,
            .decref,
            .decref_if_initialized,
            .free,
            => false,

            .init_uninitialized,
            .assign_ref,
            .assign_literal,
            .assign_call,
            .assign_call_erased,
            .assign_packed_erased_fn,
            .assign_low_level,
            .assign_list,
            .assign_struct,
            .assign_tag,
            .store_struct,
            .store_tag,
            .set_local,
            .debug,
            .expect,
            .expect_err,
            .runtime_error,
            .comptime_exhaustiveness_failed,
            .comptime_branch_taken,
            .switch_stmt,
            .switch_initialized_payload,
            .str_match,
            .str_match_set,
            .loop_continue,
            .loop_break,
            .join,
            .jump,
            .ret,
            .crash,
            => true,
        };
        if (!has_source) {
            try std.testing.expect(!loc.hasLocation());
            try std.testing.expect(region.isEmpty());
        }
        if (loc.hasLocation()) {
            located += 1;
            try std.testing.expect(!region.isEmpty());
            try std.testing.expect(loc.file < store.sourceFileCount());
            try std.testing.expect(loc.line >= 1);
            try std.testing.expect(loc.column >= 1);
        }
    }
    try std.testing.expect(located > 0);

    var located_procs: usize = 0;
    for (store.proc_locs.items) |loc| {
        if (loc.hasLocation()) {
            located_procs += 1;
            try std.testing.expect(loc.file < store.sourceFileCount());
        }
    }
    try std.testing.expect(located_procs > 0);

    var found_add2 = false;
    var found_mul3 = false;
    for (0..store.proc_specs.items.len) |i| {
        const name = store.procDebugName(@enumFromInt(i)) orelse continue;
        if (std.mem.eql(u8, name, "add2")) found_add2 = true;
        if (std.mem.eql(u8, name, "mul3")) found_mul3 = true;
    }
    try std.testing.expect(found_add2);
    try std.testing.expect(found_mul3);
}

test "referenced but uncalled function does not materialize a proc" {
    const allocator = std.testing.allocator;

    const source =
        \\unused : U64 -> U64
        \\unused = |n| n + 1
        \\
        \\main : U64
        \\main = {
        \\    _fn = unused
        \\    0
        \\}
    ;

    var lowered_source = try lowerModuleWithProcDebugNames(allocator, source, .none, true);
    defer lowered_source.deinit(allocator);

    const store = &lowered_source.lowered.lir_result.store;
    var found_unused = false;
    for (0..store.proc_specs.items.len) |i| {
        const name = store.procDebugName(@enumFromInt(i)) orelse continue;
        if (std.mem.eql(u8, name, "unused")) found_unused = true;
    }
    try std.testing.expect(!found_unused);
}

test "LIR statements carry source locations under optimizing inline mode" {
    const allocator = std.testing.allocator;

    const source =
        \\add2 : U64 -> U64
        \\add2 = |n| n + 2
        \\
        \\main : U64
        \\main = {
        \\    x = 40
        \\    add2(x)
        \\}
    ;

    var lowered_source = try lowerModule(allocator, source, .wrappers);
    defer lowered_source.deinit(allocator);

    const store = &lowered_source.lowered.lir_result.store;
    var located: usize = 0;
    for (store.cf_stmt_locs.items, store.cf_stmt_regions.items) |loc, region| {
        if (loc.hasLocation()) located += 1;
        if (loc.hasLocation()) try std.testing.expect(!region.isEmpty());
    }
    try std.testing.expect(located > 0);
}

test "adjacent string interpolation patterns lower to grouped LIR match set" {
    const allocator = std.testing.allocator;

    const source =
        \\classify : Str -> Str
        \\classify = |s| match s {
        \\    "a${x}z" => x
        \\    "b${y}z" => y
        \\    "${_}.txt" => "file"
        \\    _ => "miss"
        \\}
        \\
        \\main : Str
        \\main = classify("bOKz")
    ;

    var lowered_source = try lowerModule(allocator, source, .none);
    defer lowered_source.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &lowered_source.lowered, hasGroupedStrMatchSet));
}

test "LIR locals carry source-level names" {
    const allocator = std.testing.allocator;

    const source =
        \\compute : U64 -> U64
        \\compute = |n| {
        \\    first_part = n * 2
        \\    second_part = first_part + 1
        \\    second_part
        \\}
        \\
        \\main : U64
        \\main = compute(20)
    ;

    var lowered_source = try lowerModule(allocator, source, .none);
    defer lowered_source.deinit(allocator);

    const store = &lowered_source.lowered.lir_result.store;
    try std.testing.expectEqual(store.locals.items.len, store.local_names.items.len);

    var found_first = false;
    var found_second = false;
    for (0..store.locals.items.len) |i| {
        const name = store.localName(@enumFromInt(i)) orelse continue;
        if (std.mem.eql(u8, name, "first_part")) found_first = true;
        if (std.mem.eql(u8, name, "second_part")) found_second = true;
    }
    try std.testing.expect(found_first);
    try std.testing.expect(found_second);
}

test "shared callees are lifted once and never gain spurious captures" {
    // A small diamond call graph: every function calls the one below it twice.
    // Capture collection reuses each callee's solved free set instead of
    // re-walking shared callee bodies, so the closed chain lifts cleanly and no
    // function gains a closure capture. The depth here keeps the surrounding
    // monomorphization cheap while still exercising shared-callee reuse.
    const allocator = std.testing.allocator;
    const depth = 6;

    var source = std.ArrayList(u8).empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "f0 : U64 -> U64\nf0 = |n| n + 1\n\n");
    var level: usize = 1;
    while (level <= depth) : (level += 1) {
        const chunk = try std.fmt.allocPrint(
            allocator,
            "f{d} : U64 -> U64\nf{d} = |n| {{\n    a = f{d}(n)\n    b = f{d}(n)\n    a + b\n}}\n\n",
            .{ level, level, level - 1, level - 1 },
        );
        defer allocator.free(chunk);
        try source.appendSlice(allocator, chunk);
    }
    const tail = try std.fmt.allocPrint(allocator, "main : U64\nmain = f{d}(0)\n", .{depth});
    defer allocator.free(tail);
    try source.appendSlice(allocator, tail);

    var lifted = try liftModuleAfterSpecConstr(allocator, source.items);
    defer lifted.deinit(allocator);

    // The whole chain survives lifting as distinct closed functions: the diamond
    // is not collapsed, and no function gains spurious closure captures.
    try std.testing.expect(lifted.lifted.fns.items.len >= depth);
    for (lifted.lifted.fns.items) |func| {
        try std.testing.expectEqual(@as(u32, 0), func.captures.len);
    }
}

const LirProgram = lir.Program;

const ExpectedHostEvent = union(enum) {
    dbg: []const u8,
    expect_failed,
    crashed: []const u8,
};

fn expectOptimizedHostEvents(
    source: []const u8,
    expected_termination: eval.RuntimeHostEnv.Termination,
    expected: []const ExpectedHostEvent,
) anyerror!void {
    const allocator = std.testing.allocator;

    var optimized = try lowerModuleWithOptions(allocator, source, .wrappers, .{ .proc_debug_names = true });
    defer optimized.deinit(allocator);

    var run = try runLoweredWithHostEvents(allocator, &optimized.lowered);
    defer run.deinit(allocator);

    try std.testing.expectEqual(expected_termination, run.termination);
    try std.testing.expectEqual(expected.len, run.events.len);
    for (expected, run.events) |expected_event, actual_event| {
        switch (expected_event) {
            .dbg => |expected_msg| switch (actual_event) {
                .dbg => |actual_msg| try std.testing.expectEqualStrings(expected_msg, actual_msg),
                else => return error.TestUnexpectedResult,
            },
            .expect_failed => switch (actual_event) {
                .expect_failed => {},
                else => return error.TestUnexpectedResult,
            },
            .crashed => |expected_msg| switch (actual_event) {
                .crashed => |actual_msg| try std.testing.expectEqualStrings(expected_msg, actual_msg),
                else => return error.TestUnexpectedResult,
            },
        }
    }
}

fn expectInlinePlanDecisions(
    source: []const u8,
    fn_name: []const u8,
    expected_inline: bool,
    expected_materialize: ?bool,
) anyerror!void {
    const allocator = std.testing.allocator;
    var resources = try helpers.parseAndCanonicalizeProgramWithBuiltin(allocator, .module, source, &.{}, try sharedPrePublishedBuiltin());
    defer helpers.cleanupParseAndCanonical(allocator, resources);

    const import_count = resources.import_artifacts.len + if (resources.borrowed_builtin_artifact == null) @as(usize, 0) else 1;
    const import_views = try allocator.alloc(check.CheckedArtifact.ImportedModuleView, import_count);
    defer allocator.free(import_views);

    var view_index: usize = 0;
    if (resources.borrowed_builtin_artifact) |builtin_artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(builtin_artifact);
        view_index += 1;
    }
    for (resources.import_artifacts) |*artifact| {
        import_views[view_index] = check.CheckedArtifact.importedView(artifact);
        view_index += 1;
    }

    var mono = try postcheck.Monotype.Lower.run(
        allocator,
        .{
            .root = check.CheckedArtifact.loweringView(&resources.checked_artifact),
            .imports = import_views,
        },
        .{ .requests = resources.checked_artifact.root_requests.requests },
        .{ .proc_debug_names = true },
    );
    var mono_owned = true;
    errdefer if (mono_owned) mono.deinit();

    var lifted = try postcheck.MonotypeLifted.Lift.run(allocator, mono);
    mono_owned = false;
    mono = undefined;
    var lifted_owned = true;
    errdefer if (lifted_owned) lifted.deinit();

    var solved = try postcheck.LambdaSolved.Solve.run(allocator, lifted);
    lifted_owned = false;
    lifted = undefined;
    defer solved.deinit();

    var inline_plan = try postcheck.SolvedInline.analyze(allocator, .wrappers, &solved);
    defer inline_plan.deinit();
    const plan = inline_plan.view();

    var found = false;
    for (solved.lifted.fns.items, 0..) |fn_, index| {
        const name_id = solved.lifted.procDebugName(fn_.symbol) orelse continue;
        const actual_name = solved.lifted.names.exportNameText(name_id);
        if (!std.mem.eql(u8, actual_name, fn_name)) continue;

        found = true;
        const fn_id: postcheck.MonotypeLifted.Ast.FnId = @enumFromInt(@as(u32, @intCast(index)));
        try std.testing.expectEqual(expected_inline, plan.bodyForFn(fn_id) != null);
        if (expected_materialize) |expected| {
            try std.testing.expectEqual(expected, plan.materializeBodyForFn(fn_id) != null);
        }
    }

    try std.testing.expect(found);
}

fn collectLirResultProcShape(
    allocator: Allocator,
    result: *const LirProgram.Result,
    proc_id: LIR.LirProcSpecId,
) TestError!ProcShape {
    const proc = result.store.getProcSpec(proc_id);
    var shape = ProcShape{
        .arg_count = result.store.getLocalSpan(proc.args).len,
    };

    const body = proc.body orelse return shape;

    var work = std.ArrayList(LIR.CFStmtId).empty;
    defer work.deinit(allocator);
    try work.append(allocator, body);

    var visited = std.AutoHashMap(LIR.CFStmtId, void).init(allocator);
    defer visited.deinit();

    while (work.pop()) |stmt_id| {
        const visited_entry = try visited.getOrPut(stmt_id);
        if (visited_entry.found_existing) continue;

        switch (result.store.getCFStmt(stmt_id)) {
            .assign_ref => |stmt| try work.append(allocator, stmt.next),
            .assign_literal => |stmt| try work.append(allocator, stmt.next),
            .init_uninitialized => |stmt| try work.append(allocator, stmt.next),
            .assign_call => |stmt| {
                shape.direct_call_count += 1;
                if (stmt.proc == proc_id) shape.self_call_count += 1;
                try work.append(allocator, stmt.next);
            },
            .assign_call_erased => |stmt| {
                shape.erased_call_count += 1;
                try work.append(allocator, stmt.next);
            },
            .assign_packed_erased_fn => |stmt| {
                shape.packed_erased_fn_count += 1;
                try work.append(allocator, stmt.next);
            },
            .assign_low_level => |stmt| {
                shape.low_level_count += 1;
                switch (stmt.op) {
                    .list_len => shape.list_len_count += 1,
                    .list_get_unsafe => shape.list_get_unsafe_count += 1,
                    .list_with_capacity => shape.list_with_capacity_count += 1,
                    .list_append_unsafe => shape.list_append_unsafe_count += 1,
                    .list_reserve => shape.list_reserve_count += 1,
                    .str_count_utf8_bytes => shape.str_count_utf8_bytes_count += 1,
                    .str_concat => shape.str_concat_count += 1,
                    .box_box => shape.box_box_count += 1,
                    .box_unbox => shape.box_unbox_count += 1,
                    .box_prepare_update => shape.box_prepare_update_count += 1,
                    .ptr_cast => shape.ptr_cast_count += 1,
                    .ptr_load => shape.ptr_load_count += 1,
                    .ptr_store => shape.ptr_store_count += 1,
                    else => {},
                }
                try work.append(allocator, stmt.next);
            },
            .assign_list => |stmt| try work.append(allocator, stmt.next),
            .assign_struct => |stmt| {
                shape.struct_assign_count += 1;
                try work.append(allocator, stmt.next);
            },
            .assign_tag => |stmt| {
                shape.tag_assign_count += 1;
                try work.append(allocator, stmt.next);
            },
            .store_struct => |stmt| {
                shape.store_struct_count += 1;
                try work.append(allocator, stmt.next);
            },
            .store_tag => |stmt| {
                shape.store_tag_count += 1;
                try work.append(allocator, stmt.next);
            },
            .set_local => |stmt| try work.append(allocator, stmt.next),
            .debug => |stmt| try work.append(allocator, stmt.next),
            .expect => |stmt| try work.append(allocator, stmt.next),
            .comptime_branch_taken => |stmt| try work.append(allocator, stmt.next),
            .incref => |stmt| try work.append(allocator, stmt.next),
            .decref => |stmt| try work.append(allocator, stmt.next),
            .decref_if_initialized => |stmt| try work.append(allocator, stmt.next),
            .free => |stmt| try work.append(allocator, stmt.next),
            .switch_stmt => |stmt| {
                shape.switch_count += 1;
                if (stmt.continuation) |continuation| try work.append(allocator, continuation);
                try work.append(allocator, stmt.default_branch);
                for (result.store.getCFSwitchBranches(stmt.branches)) |branch| {
                    try work.append(allocator, branch.body);
                }
            },
            .switch_initialized_payload => |stmt| {
                shape.switch_count += 1;
                try work.append(allocator, stmt.initialized_branch);
                try work.append(allocator, stmt.uninitialized_branch);
            },
            .str_match => |stmt| {
                try work.append(allocator, stmt.on_match);
                try work.append(allocator, stmt.on_miss);
            },
            .str_match_set => |stmt| {
                shape.str_match_set_count += 1;
                for (result.store.getStrMatchArms(stmt.arms)) |arm| {
                    try work.append(allocator, arm.on_match);
                }
                try work.append(allocator, stmt.on_miss);
            },
            .join => |stmt| {
                shape.join_count += 1;
                shape.max_join_param_count = @max(
                    shape.max_join_param_count,
                    result.store.getLocalSpan(stmt.params).len,
                );
                try work.append(allocator, stmt.body);
                try work.append(allocator, stmt.remainder);
            },
            .jump => {
                shape.jump_count += 1;
            },
            .runtime_error,
            .comptime_exhaustiveness_failed,
            .loop_continue,
            .loop_break,
            .ret,
            .crash,
            .expect_err,
            => {},
        }
    }

    return shape;
}

fn reachableProcDebugName(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    expected_name: []const u8,
) anyerror!bool {
    var work = std.ArrayList(LIR.LirProcSpecId).empty;
    defer work.deinit(allocator);
    try work.append(allocator, try rootProc(lowered));

    var visited = std.AutoHashMap(LIR.LirProcSpecId, void).init(allocator);
    defer visited.deinit();

    while (work.pop()) |proc_id| {
        const visited_entry = try visited.getOrPut(proc_id);
        if (visited_entry.found_existing) continue;

        if (lowered.lir_result.store.procDebugName(proc_id)) |name| {
            if (std.mem.eql(u8, name, expected_name)) return true;
        }

        const calls = try collectAssignCallProcs(allocator, lowered, proc_id);
        defer allocator.free(calls);
        for (calls) |call| try work.append(allocator, call);
    }
    return false;
}

fn reachableProcShapeFieldTotal(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    comptime field_name: []const u8,
) anyerror!usize {
    var work = std.ArrayList(LIR.LirProcSpecId).empty;
    defer work.deinit(allocator);
    try work.append(allocator, try rootProc(lowered));

    var visited = std.AutoHashMap(LIR.LirProcSpecId, void).init(allocator);
    defer visited.deinit();

    var total: usize = 0;
    while (work.pop()) |proc_id| {
        const visited_entry = try visited.getOrPut(proc_id);
        if (visited_entry.found_existing) continue;

        const shape = try collectProcShape(allocator, lowered, proc_id);
        total += @field(shape, field_name);

        const calls = try collectAssignCallProcs(allocator, lowered, proc_id);
        defer allocator.free(calls);
        for (calls) |call| try work.append(allocator, call);
    }
    return total;
}

fn expectReachableProcShapeFieldNoGreater(
    allocator: Allocator,
    iter_lowered: *const lir.CheckedPipeline.LoweredProgram,
    list_lowered: *const lir.CheckedPipeline.LoweredProgram,
    comptime field_name: []const u8,
) anyerror!void {
    try expectReachableProcShapeFieldNoGreaterBy(allocator, iter_lowered, list_lowered, field_name, 0);
}

fn expectReachableProcShapeFieldNoGreaterBy(
    allocator: Allocator,
    iter_lowered: *const lir.CheckedPipeline.LoweredProgram,
    list_lowered: *const lir.CheckedPipeline.LoweredProgram,
    comptime field_name: []const u8,
    allowed_extra: usize,
) anyerror!void {
    const iter_total = try reachableProcShapeFieldTotal(allocator, iter_lowered, field_name);
    const list_total = try reachableProcShapeFieldTotal(allocator, list_lowered, field_name);
    try std.testing.expect(iter_total <= list_total + allowed_extra);
}

fn expectReachableProcShapeFieldEqual(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    comptime field_name: []const u8,
    expected: usize,
) anyerror!void {
    const actual = try reachableProcShapeFieldTotal(allocator, lowered, field_name);
    try std.testing.expectEqual(expected, actual);
}

fn expectStaticListIterAppendLoopAvoidsListAppendAllocation(
    iter_source: []const u8,
    list_source: []const u8,
) anyerror!void {
    const allocator = std.testing.allocator;
    var iter_optimized = try lowerModuleWithOptions(allocator, iter_source, .wrappers, .{ .tag_reachability = true });
    defer iter_optimized.deinit(allocator);
    var list_optimized = try lowerModuleWithOptions(allocator, list_source, .wrappers, .{ .tag_reachability = true });
    defer list_optimized.deinit(allocator);

    try expectReachableProcShapeFieldEqual(allocator, &iter_optimized.lowered, "erased_call_count", 0);
    try expectReachableProcShapeFieldEqual(allocator, &iter_optimized.lowered, "packed_erased_fn_count", 0);
    try expectReachableProcShapeFieldEqual(allocator, &iter_optimized.lowered, "list_with_capacity_count", 0);
    try expectReachableProcShapeFieldEqual(allocator, &iter_optimized.lowered, "list_reserve_count", 0);
    try expectReachableProcShapeFieldEqual(allocator, &iter_optimized.lowered, "list_append_unsafe_count", 0);
    try expectReachableProcShapeFieldNoGreater(allocator, &iter_optimized.lowered, &list_optimized.lowered, "list_with_capacity_count");
    try expectReachableProcShapeFieldNoGreater(allocator, &iter_optimized.lowered, &list_optimized.lowered, "list_reserve_count");
    try expectReachableProcShapeFieldNoGreater(allocator, &iter_optimized.lowered, &list_optimized.lowered, "list_append_unsafe_count");
    try expectReachableProcShapeFieldNoGreater(allocator, &iter_optimized.lowered, &list_optimized.lowered, "box_box_count");
    try expectReachableProcShapeFieldNoGreaterBy(allocator, &iter_optimized.lowered, &list_optimized.lowered, "switch_count", 1);
}

fn expectNoReachableErasedCallableLowering(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
) anyerror!void {
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, lowered, "erased_call_count"));
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, lowered, "packed_erased_fn_count"));
}

// Zero-allocation gate for iterator chains that escape their construction site
// (returned from a function, passed to a non-inlined function, chosen by a
// branch). Range sources carry no list, so a statically-known chain must lower
// to no heap allocation at all: no boxed iterator state, no erased callable
// dispatch, no list allocation. This is the static companion to the runtime
// allocations_at_most=0 gate in eval_iter_alloc_tests.zig, which cannot express
// module-level function definitions. RED on the recursive-nominal
// representation (an escaping iterator boxes its state in its constructor).
fn expectEscapingIterChainAllocatesNothing(source: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    var optimized = try lowerModuleWithOptions(allocator, source, .wrappers, .{ .tag_reachability = true });
    defer optimized.deinit(allocator);
    try expectReachableProcShapeFieldEqual(allocator, &optimized.lowered, "box_box_count", 0);
    try expectReachableProcShapeFieldEqual(allocator, &optimized.lowered, "erased_call_count", 0);
    try expectReachableProcShapeFieldEqual(allocator, &optimized.lowered, "packed_erased_fn_count", 0);
    try expectReachableProcShapeFieldEqual(allocator, &optimized.lowered, "list_with_capacity_count", 0);
}

test "iter alloc static: iterator returned from a function is zero-alloc" {
    try expectEscapingIterChainAllocatesNothing(
        \\module [main]
        \\
        \\consume : Iter(U64) -> U64
        \\consume = |it| {
        \\    var $sum = 0.U64
        \\    for x in it {
        \\        $sum = $sum + x
        \\    }
        \\    $sum
        \\}
        \\
        \\make : U64 -> Iter(U64)
        \\make = |n| Iter.map(Iter.exclusive_range(0.U64, n), |x| x + 1)
        \\
        \\main : U64
        \\main = consume(make(5))
    );
}

test "iter alloc static: iterator passed to a non-inlined function is zero-alloc" {
    try expectEscapingIterChainAllocatesNothing(
        \\module [main]
        \\
        \\consume : Iter(U64) -> U64
        \\consume = |it| {
        \\    var $sum = 0.U64
        \\    for x in it {
        \\        $sum = $sum + x
        \\    }
        \\    $sum
        \\}
        \\
        \\main : U64
        \\main = consume(Iter.map(Iter.exclusive_range(0.U64, 5), |x| x + 1))
    );
}

test "iter alloc static: branch-chosen iterator is zero-alloc" {
    try expectEscapingIterChainAllocatesNothing(
        \\module [main]
        \\
        \\consume : Iter(U64) -> U64
        \\consume = |it| {
        \\    var $sum = 0.U64
        \\    for x in it {
        \\        $sum = $sum + x
        \\    }
        \\    $sum
        \\}
        \\
        \\choose : Bool -> Iter(U64)
        \\choose = |flag|
        \\    if flag {
        \\        Iter.map(Iter.exclusive_range(0.U64, 5), |x| x + 1)
        \\    } else {
        \\        Iter.keep_if(Iter.exclusive_range(0.U64, 5), |x| x > 2)
        \\    }
        \\
        \\main : U64
        \\main = consume(choose(5.U64 > 0))
    );
}

// The base `[list].iter().fold` must lower with no boxed iterator state and no
// erased callable dispatch: the list literal may allocate its backing store, but
// the iterator itself must carry its step closure inline by value. This asserts
// only the iterator-attributable counts (box_box / erased_call / packed_erased);
// the list's own `list_with_capacity` is expected and not asserted here.
test "iter alloc static: base list fold is zero-alloc" {
    const allocator = std.testing.allocator;
    var optimized = try lowerModuleWithOptions(allocator,
        \\module [main]
        \\
        \\main : I64
        \\main = {
        \\    xs = [1.I64, 2, 3, 4, 5]
        \\    Iter.fold(xs.iter(), 0, |a, b| a + b)
        \\}
    , .wrappers, .{ .tag_reachability = true });
    defer optimized.deinit(allocator);
    try expectReachableProcShapeFieldEqual(allocator, &optimized.lowered, "box_box_count", 0);
    try expectReachableProcShapeFieldEqual(allocator, &optimized.lowered, "erased_call_count", 0);
    try expectReachableProcShapeFieldEqual(allocator, &optimized.lowered, "packed_erased_fn_count", 0);
}

fn reachableReturnSlotProcCount(
    allocator: Allocator,
    lowered: *const lir.CheckedPipeline.LoweredProgram,
) anyerror!usize {
    var work = std.ArrayList(LIR.LirProcSpecId).empty;
    defer work.deinit(allocator);
    try work.append(allocator, try rootProc(lowered));

    var visited = std.AutoHashMap(LIR.LirProcSpecId, void).init(allocator);
    defer visited.deinit();

    var count: usize = 0;
    while (work.pop()) |proc_id| {
        const visited_entry = try visited.getOrPut(proc_id);
        if (visited_entry.found_existing) continue;

        const proc = lowered.lir_result.store.getProcSpec(proc_id);
        const args = lowered.lir_result.store.getLocalSpan(proc.args);
        if (proc.ret_layout == .zst and args.len != 0) candidate: {
            const first_arg_layout = lowered.lir_result.layouts.getLayout(
                lowered.lir_result.store.getLocal(args[0]).layout_idx,
            );
            if (first_arg_layout.tag != .ptr) break :candidate;
            const result_layout = lowered.lir_result.layouts.getLayout(first_arg_layout.getIdx());
            switch (result_layout.tag) {
                .struct_, .tag_union => {},
                else => break :candidate,
            }
            const shape = try collectProcShape(allocator, lowered, proc_id);
            if (shape.ptr_store_count != 0 or shape.store_struct_count != 0 or shape.store_tag_count != 0) count += 1;
        }

        const calls = try collectAssignCallProcs(allocator, lowered, proc_id);
        defer allocator.free(calls);
        for (calls) |call| try work.append(allocator, call);
    }
    return count;
}

fn countHostedLiftedFns(program: *const postcheck.MonotypeLifted.Ast.Program) usize {
    var count: usize = 0;
    for (program.fns.items) |fn_| {
        switch (fn_.body) {
            .roc => {},
            .hosted => count += 1,
        }
    }
    return count;
}

fn localLoopStateIsSplitToTwoLeaves(shape: ProcShape) bool {
    return shape.self_call_count == 0 and
        shape.join_count >= 1 and
        shape.max_join_param_count == 2 and
        shape.jump_count >= 2;
}

fn whileRecordStateWithCallableCapturesIsSpecialized(shape: ProcShape) bool {
    return shape.self_call_count == 0 and
        shape.join_count >= 1 and
        shape.max_join_param_count == 3 and
        shape.jump_count >= 2;
}

fn whileRecordStateWithZeroCaptureCallableIsSpecialized(shape: ProcShape) bool {
    return shape.self_call_count == 0 and
        shape.join_count >= 1 and
        shape.max_join_param_count == 1 and
        shape.jump_count >= 2 and
        shape.direct_call_count == 0;
}

fn whileRecordStateWithOpaqueCallableIsSpecialized(shape: ProcShape) bool {
    return shape.self_call_count == 0 and
        shape.join_count >= 1 and
        shape.max_join_param_count == 2 and
        shape.jump_count >= 2;
}

fn branchJoinedRecordStateWorkerIsSpecialized(shape: ProcShape) bool {
    return shape.self_call_count == 0 and
        shape.join_count >= 1 and
        shape.max_join_param_count == 2 and
        shape.jump_count >= 2;
}

fn branchJoinedRecordStateWorkerIsGeneric(shape: ProcShape) bool {
    return shape.self_call_count == 0 and
        shape.join_count >= 1 and
        shape.max_join_param_count == 1 and
        shape.jump_count >= 2;
}

fn expectRangeMapCollectUsesDirectListLoop(source: []const u8, expected_append_unsafe_count: usize) anyerror!void {
    const allocator = std.testing.allocator;

    var optimized = try lowerModuleWithOptions(allocator, source, .wrappers, .{ .proc_debug_names = true });
    defer optimized.deinit(allocator);

    try std.testing.expect(!try reachableIterCollectShape(allocator, &optimized.lowered, .specialized));
    try std.testing.expect(!try reachableIterCollectShape(allocator, &optimized.lowered, .generic));
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "list_len_count"));
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "list_get_unsafe_count"));
    try std.testing.expectEqual(@as(usize, 1), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "list_with_capacity_count"));
    try std.testing.expectEqual(@as(usize, 1), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "list_reserve_count"));
    try std.testing.expectEqual(expected_append_unsafe_count, try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "list_append_unsafe_count"));
}

test "direct call wrapper is inlined under optimized post-check lowering" {
    try expectRootDirectCallCount(
        \\module [main]
        \\
        \\callee : U64 -> U64
        \\callee = |x| x + 1
        \\
        \\wrapper : U64 -> U64
        \\wrapper = |x| callee(x)
        \\
        \\main : U64
        \\main = wrapper(41)
    , .wrappers, 0);
}

test "direct call wrapper is not inlined under ordinary post-check lowering" {
    try expectRootTargetHasCalls(
        \\module [main]
        \\
        \\callee : U64 -> U64
        \\callee = |x| x + 1
        \\
        \\wrapper : U64 -> U64
        \\wrapper = |x| callee(x)
        \\
        \\main : U64
        \\main = wrapper(41)
    , .none);
}

test "user single wrapper can inline to builtin single iterator" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\module [main]
        \\
        \\Boxed := [Boxed].{
        \\    single : I64 -> Iter(I64)
        \\    single = |item| Iter.single(item)
        \\}
        \\
        \\main : I64
        \\main = {
        \\    var $sum = 0.I64
        \\    for item in Boxed.single(42.I64) {
        \\        $sum = $sum + item
        \\    }
        \\    $sum
        \\}
    , .wrappers);
    defer lowered_source.deinit(allocator);

    const shape = try collectProcShape(allocator, &lowered_source.lowered, try rootProc(&lowered_source.lowered));
    try std.testing.expectEqual(@as(usize, 0), shape.direct_call_count);
    try std.testing.expectEqual(@as(usize, 0), shape.tag_assign_count);
    try std.testing.expectEqual(@as(usize, 0), shape.store_tag_count);
}

test "user iter method is not recognized as builtin list cursor" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\module [main]
        \\
        \\Bag := [Bag].{
        \\    iter : Bag -> Iter(I64)
        \\    iter = |_| Iter.single(1.I64)
        \\}
        \\
        \\main : I64
        \\main = {
        \\    var $sum = 0.I64
        \\    for item in Bag.Bag {
        \\        $sum = $sum + item
        \\    }
        \\    $sum
        \\}
    , .wrappers);
    defer lowered_source.deinit(allocator);

    const shape = try collectProcShape(allocator, &lowered_source.lowered, try rootProc(&lowered_source.lowered));
    try std.testing.expectEqual(@as(usize, 0), shape.list_len_count);
    try std.testing.expectEqual(@as(usize, 0), shape.list_get_unsafe_count);
}

test "destination baseline: boxed record update reboxes a list and string payload" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\module [main]
        \\
        \\Plant : {
        \\    x : I32,
        \\    label : Str,
        \\}
        \\
        \\Model : {
        \\    tick : U64,
        \\    label : Str,
        \\    plants : List(Plant),
        \\}
        \\
        \\State : [Running(Model), Done(Str)]
        \\
        \\step : Box(State) -> Box(State)
        \\step = |boxed| {
        \\    state = Box.unbox(boxed)
        \\
        \\    next =
        \\        match state {
        \\            Running(model) => {
        \\                plants = List.append(model.plants, { x: 160, label: model.label })
        \\                Running({ ..model, tick: model.tick + 1, plants })
        \\            }
        \\
        \\            Done(msg) => Done(Str.concat(msg, "!"))
        \\        }
        \\
        \\    Box.box(next)
        \\}
        \\
        \\main : Box(State) -> Box(State)
        \\main = |boxed| step(boxed)
    , .wrappers);
    defer lowered_source.deinit(allocator);

    const step_proc = try rootDirectCallTarget(allocator, &lowered_source.lowered);
    const shape = try collectProcShape(allocator, &lowered_source.lowered, step_proc);

    try std.testing.expectEqual(@as(usize, 1), shape.box_unbox_count);
    try std.testing.expectEqual(@as(usize, 1), shape.box_box_count);
    try std.testing.expect(shape.struct_assign_count >= 2);
    try std.testing.expect(shape.tag_assign_count >= 2);
}

test "destination phase 3: direct boxed update wrapper calls a return-slot variant" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\module [main]
        \\
        \\Model : {
        \\    tick : U64,
        \\    label : Str,
        \\}
        \\
        \\update : Model -> Model
        \\update = |model| {
        \\    tick = model.tick + 1
        \\    { ..model, tick }
        \\}
        \\
        \\step : Box(Model) -> Box(Model)
        \\step = |boxed| Box.box(update(Box.unbox(boxed)))
        \\
        \\main : Box(Model) -> Box(Model)
        \\main = |boxed| step(boxed)
    , .wrappers);
    defer lowered_source.deinit(allocator);

    const root_shape = try collectProcShape(allocator, &lowered_source.lowered, try rootProc(&lowered_source.lowered));

    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &lowered_source.lowered, "box_unbox_count"));
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &lowered_source.lowered, "box_box_count"));
    try std.testing.expectEqual(@as(usize, 1), try reachableProcShapeFieldTotal(allocator, &lowered_source.lowered, "box_prepare_update_count"));
    try std.testing.expectEqual(@as(usize, 1), try reachableProcShapeFieldTotal(allocator, &lowered_source.lowered, "ptr_cast_count"));
    try std.testing.expectEqual(@as(usize, 1), try reachableProcShapeFieldTotal(allocator, &lowered_source.lowered, "ptr_load_count"));
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &lowered_source.lowered, "ptr_store_count"));
    try std.testing.expectEqual(@as(usize, 1), try reachableProcShapeFieldTotal(allocator, &lowered_source.lowered, "store_struct_count"));
    try std.testing.expectEqual(@as(usize, 0), root_shape.ptr_store_count);
    try std.testing.expectEqual(@as(usize, 1), try reachableReturnSlotProcCount(allocator, &lowered_source.lowered));
}

test "destination baseline: boxed lambda is packed then boxed" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\module [main]
        \\
        \\Formatter : U64 -> Str
        \\
        \\make : Str -> Box(Formatter)
        \\make = |prefix| Box.box(|n| Str.concat(prefix, U64.to_str(n)))
        \\
        \\main : Str -> Box(Formatter)
        \\main = |prefix| make(prefix)
    , .none);
    defer lowered_source.deinit(allocator);

    const make_proc = try rootDirectCallTarget(allocator, &lowered_source.lowered);
    const shape = try collectProcShape(allocator, &lowered_source.lowered, make_proc);

    try std.testing.expectEqual(@as(usize, 1), shape.packed_erased_fn_count);
}

test "destination baseline: large record return feeds a record update" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\module [main]
        \\
        \\Big : {
        \\    label : Str,
        \\    items : List(U64),
        \\    a : U64,
        \\    b : U64,
        \\    c : U64,
        \\    d : U64,
        \\    e : U64,
        \\}
        \\
        \\make_big : Str, U64 -> Big
        \\make_big = |label, n| {
        \\    label,
        \\    items: [n, n + 1],
        \\    a: n,
        \\    b: n + 1,
        \\    c: n + 2,
        \\    d: n + 3,
        \\    e: n + 4,
        \\}
        \\
        \\change_big : Str, U64 -> Big
        \\change_big = |label, n| { ..make_big(label, n), e: n + 5 }
        \\
        \\main : Str, U64 -> Big
        \\main = |label, n| change_big(label, n)
    , .none);
    defer lowered_source.deinit(allocator);

    const change_proc = try rootDirectCallTarget(allocator, &lowered_source.lowered);
    const shape = try collectProcShape(allocator, &lowered_source.lowered, change_proc);

    try std.testing.expect(shape.direct_call_count >= 1);
    try std.testing.expect(shape.struct_assign_count >= 1);
}

test "destination phase 6: string concat caller uses append variant" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\module [main]
        \\
        \\suffix : Str -> Str
        \\suffix = |input| {
        \\    middle = if input == "" { input } else { input }
        \\    Str.concat(middle, "!")
        \\}
        \\
        \\build : Str -> Str
        \\build = |input| {
        \\    prefix = if input == "" { "pre" } else { "pre" }
        \\    result = suffix(input)
        \\    Str.concat(prefix, result)
        \\}
        \\
        \\main : Str -> Str
        \\main = |input| {
        \\    held = input
        \\    build(held)
        \\}
    , .wrappers);
    defer lowered_source.deinit(allocator);

    const build_proc = try rootDirectCallTarget(allocator, &lowered_source.lowered);
    const build_shape = try collectProcShape(allocator, &lowered_source.lowered, build_proc);

    try std.testing.expectEqual(@as(usize, 1), build_shape.direct_call_count);
    try std.testing.expectEqual(@as(usize, 0), build_shape.str_concat_count);
    try std.testing.expectEqual(@as(usize, 2), try reachableProcShapeFieldTotal(allocator, &lowered_source.lowered, "str_concat_count"));
}

// Ported pending iterator redesign: the materialize-inline plan decision this test asserts is not part of the current inline plan.
// test "call value wrapper is optimized-inline eligible but not materialize-inline eligible" {
//     try expectInlinePlanDecisions(
//         \\module [main]
//         \\
//         \\callee : U64 -> U64
//         \\callee = |x| x + 1
//         \\
//         \\apply : (U64 -> U64), U64 -> U64
//         \\apply = |fn, x| fn(x)
//         \\
//         \\main : U64
//         \\main = apply(callee, 41)
//     , "apply", true, false);
// }

// Ported pending iterator redesign: the materialize-inline plan decision this test asserts is not part of the current inline plan.
// test "simple direct low-level wrapper is materialize-inline eligible" {
//     try expectInlinePlanDecisions(
//         \\module [main]
//         \\
//         \\callee : U64 -> U64
//         \\callee = |x| x + 1
//         \\
//         \\main : U64 -> U64
//         \\main = |x| callee(x)
//     , "callee", true, true);
// }

test "capturing direct wrapper is inlined when captures are inline inputs" {
    const allocator = std.testing.allocator;
    var lowered_source = try lowerModule(allocator,
        \\module [main]
        \\
        \\callee : U64 -> U64
        \\callee = |x| x + 1
        \\
        \\main : U64 -> U64
        \\main = |offset| {
        \\    wrapper = |x| callee(x + offset)
        \\    wrapper(41)
        \\}
    , .wrappers);
    defer lowered_source.deinit(allocator);

    const root_calls = try collectAssignCallProcs(allocator, &lowered_source.lowered, try rootProc(&lowered_source.lowered));
    defer allocator.free(root_calls);

    try std.testing.expectEqual(@as(usize, 0), root_calls.len);
    const root_shape = try collectProcShape(allocator, &lowered_source.lowered, try rootProc(&lowered_source.lowered));
    try std.testing.expectEqual(@as(usize, 0), root_shape.direct_call_count);
}
// ─── TRMC pass outcomes through the full pipeline ───

test "plant iter pipeline collect uses direct range map list loop" {
    try expectRangeMapCollectUsesDirectListLoop(
        \\module [main]
        \\
        \\Plant : { seed : I64 }
        \\
        \\random_plant : I64 -> Plant
        \\random_plant = |seed| { seed: seed }
        \\
        \\starting_plants : () -> List(Plant)
        \\starting_plants = || {
        \\    (0.I64..=15)
        \\        .map(|i| random_plant(i * 12))
        \\        .collect()
        \\}
        \\
        \\main : () -> List(Plant)
        \\main = || starting_plants()
    , 2);
}

test "direct range map collect uses direct list loop" {
    try expectRangeMapCollectUsesDirectListLoop(
        \\module [main]
        \\
        \\Plant : { seed : I64 }
        \\
        \\random_plant : I64 -> Plant
        \\random_plant = |seed| { seed: seed }
        \\
        \\main : () -> List(Plant)
        \\main = ||
        \\    Iter.collect(
        \\        Iter.map(0.I64..=15, |i| random_plant(i * 12)),
        \\    )
    , 2);
}

test "non-inlined call list argument keeps let-bound leaves available" {
    // A boundary call cannot be inlined, so its arguments must materialize as
    // ordinary public values. A list argument whose elements are let-bound
    // locals must keep those bindings available (or substituted) when the
    // boundary materializes inside nested inlining.
    const allocator = std.testing.allocator;
    var optimized = try lowerModule(allocator,
        \\module [main]
        \\
        \\len_rec : List(U64), U64 -> U64
        \\len_rec = |bytes, acc| {
        \\    match bytes {
        \\        [] => acc
        \\        [_, .. as rest] => len_rec(rest, acc + 1)
        \\    }
        \\}
        \\
        \\countdown : U64 -> U64
        \\countdown = |x| if x == 0 1 else countdown(x - 1)
        \\
        \\save : U64 -> U64
        \\save = |frame| {
        \\    data = U64.bitwise_and(frame, 255)
        \\    other = countdown(3)
        \\    len_rec([data, other], 0)
        \\}
        \\
        \\init : { frame : U64 } -> U64
        \\init = |state| {
        \\    frame_count = state.frame
        \\    save(frame_count)
        \\}
        \\
        \\step : { frame : U64 }, U64 -> U64
        \\step = |state, mode| {
        \\    if mode == 1 {
        \\        init(state)
        \\    } else {
        \\        0
        \\    }
        \\}
        \\
        \\main : U64
        \\main = step({ frame: 9 }, 1)
    , .wrappers);
    defer optimized.deinit(allocator);
}

test "multi-use match binding emits branch bodies once" {
    // A control-flow value re-emits its branch bodies wherever it
    // materializes, so a let-bound match consumed by more than one
    // materializing use must be emitted once at its binding statement and
    // referenced; otherwise every use duplicates every branch body.
    const allocator = std.testing.allocator;
    var optimized = try lowerModule(allocator,
        \\module [main]
        \\
        \\route : U64 -> U64
        \\route = |x| {
        \\    if x > 3 {
        \\        return 0
        \\    }
        \\    x + 1
        \\}
        \\
        \\label : U64 -> Str
        \\label = |n| {
        \\    state = match route(n) {
        \\        0 => Str.concat("a", "0")
        \\        1 => Str.concat("b", "1")
        \\        2 => Str.concat("c", "2")
        \\        _ => Str.concat("d", "?")
        \\    }
        \\    Str.concat(state, state)
        \\}
        \\
        \\main : Str
        \\main = label(9)
    , .wrappers);
    defer optimized.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "str_concat_count"));
}

test "boundary field access projects private leaf branch" {
    // A record consumed only through demanded field accesses splits into a
    // sparse private product, and an if branch whose value is an opaque call
    // result is carried whole as a private leaf. A boundary argument that
    // projects a field from such an if value must project through every
    // branch — including the leaf branch, whose field is an ordinary field
    // access on the carried public value — rather than materialize the
    // sparse receiver whole.
    const allocator = std.testing.allocator;
    var optimized = try lowerModule(allocator,
        \\module [main]
        \\
        \\countdown : U64 -> U64
        \\countdown = |x| {
        \\    if x > 3 {
        \\        return 0
        \\    }
        \\    x + 1
        \\}
        \\
        \\load : U64 -> { score : U64, hi : U64, pad : U64 }
        \\load = |seed| {
        \\    if seed == 0 {
        \\        { score: 0, hi: 1, pad: 2 }
        \\    } else {
        \\        load(seed - 1)
        \\    }
        \\}
        \\
        \\use : { score : U64, hi : U64, pad : U64 }, U64 -> U64
        \\use = |state, mode| {
        \\    match countdown(state.score) {
        \\        1 => state.hi + mode
        \\        other => other
        \\    }
        \\}
        \\
        \\main : U64
        \\main = {
        \\    state = if countdown(3) == 1 {
        \\        { score: 10, hi: 20, pad: 30 }
        \\    } else {
        \\        load(7)
        \\    }
        \\    use(state, 1)
        \\}
    , .wrappers);
    defer optimized.deinit(allocator);
}

test "local iterator append loop demands step captures across states" {
    // The append step callable's appended-item capture is demanded only
    // through the step-result `item` demand observed inside the loop body.
    // That observation must reach the owning loop demand node so the state
    // key carries the capture; otherwise the state callable is reconstructed
    // without a capture its body demands.
    const allocator = std.testing.allocator;
    var optimized = try lowerModule(allocator,
        \\module [main]
        \\
        \\Point : { x : I64 }
        \\
        \\points : () -> Iter(Point)
        \\points = || [{ x: 1.I64 }, { x: 2 }].iter().append({ x: 3 })
        \\
        \\main : I64
        \\main = {
        \\    iter = points()
        \\    var $sum = 0.I64
        \\    for point in iter {
        \\        $sum = $sum + point.x
        \\    }
        \\    $sum
        \\}
    , .wrappers);
    defer optimized.deinit(allocator);

    try expectNoReachableErasedCallableLowering(allocator, &optimized.lowered);
}

test "imported iterator producer keeps finite step callables" {
    const allocator = std.testing.allocator;
    const producer_module =
        \\module [points]
        \\
        \\Point : { x : I64 }
        \\
        \\points : () -> Iter(Point)
        \\points = || [{ x: 1.I64 }, { x: 2 }].iter().append({ x: 3 })
    ;
    const source =
        \\module [main]
        \\
        \\import Points
        \\
        \\main : I64
        \\main = {
        \\    iter = Points.points()
        \\    var $sum = 0.I64
        \\    for point in iter {
        \\        $sum = $sum + point.x
        \\    }
        \\    $sum
        \\}
    ;

    var optimized = try lowerModuleWithOptions(allocator, source, .wrappers, .{
        .imports = &.{.{ .name = "Points", .source = producer_module }},
    });
    defer optimized.deinit(allocator);

    try expectNoReachableErasedCallableLowering(allocator, &optimized.lowered);
}

test "static list iter append loop eliminates public iter adapters" {
    const allocator = std.testing.allocator;
    const iter_source =
        \\module [main]
        \\
        \\Point : { x : I64, y : I64 }
        \\
        \\sum_points : U64 -> I64
        \\sum_points = |anim_index| {
        \\    base_points = [
        \\        { x: 11, y: 2 },
        \\        { x: 13, y: 3 },
        \\        { x: 3, y: 5 },
        \\        { x: 11, y: 6 },
        \\    ].iter()
        \\
        \\    collision_points =
        \\        if anim_index == 2 {
        \\            base_points.append({ x: 2, y: 1 }).append({ x: 7, y: 1 })
        \\        } else if anim_index == 1 {
        \\            base_points.append({ x: 2, y: 2 })
        \\        } else {
        \\            base_points
        \\        }
        \\
        \\    var $sum = 0
        \\    for { x, y } in collision_points {
        \\        $sum = $sum + x + y
        \\    }
        \\    $sum
        \\}
        \\
        \\main : I64
        \\main = sum_points(2)
    ;
    const list_source =
        \\module [main]
        \\
        \\Point : { x : I64, y : I64 }
        \\
        \\sum_points : U64 -> I64
        \\sum_points = |anim_index| {
        \\    base_points = [
        \\        { x: 11, y: 2 },
        \\        { x: 13, y: 3 },
        \\        { x: 3, y: 5 },
        \\        { x: 11, y: 6 },
        \\    ]
        \\
        \\    collision_points =
        \\        if anim_index == 2 {
        \\            base_points.append({ x: 2, y: 1 }).append({ x: 7, y: 1 })
        \\        } else if anim_index == 1 {
        \\            base_points.append({ x: 2, y: 2 })
        \\        } else {
        \\            base_points
        \\        }
        \\
        \\    var $sum = 0
        \\    for { x, y } in collision_points {
        \\        $sum = $sum + x + y
        \\    }
        \\    $sum
        \\}
        \\
        \\main : I64
        \\main = sum_points(2)
    ;

    var iter_optimized = try lowerModuleWithProcDebugNames(allocator, iter_source, .wrappers, true);
    defer iter_optimized.deinit(allocator);
    var list_optimized = try lowerModuleWithProcDebugNames(allocator, list_source, .wrappers, true);
    defer list_optimized.deinit(allocator);

    try std.testing.expect(!try reachableProcDebugName(allocator, &iter_optimized.lowered, "Builtin.List.iter"));
    try std.testing.expect(!try reachableProcDebugName(allocator, &iter_optimized.lowered, "Builtin.Iter.append"));
    try std.testing.expect(!try reachableProcDebugName(allocator, &iter_optimized.lowered, "iter_from_step"));
    try std.testing.expect(!try reachableProcDebugName(allocator, &list_optimized.lowered, "Builtin.Iter.append"));
}

// Ported pending iterator redesign: post_check_stats.optimized_contexts instrumentation is not part of the current pipeline.
// test "post-check lowering mode constructs optimized context only in optimized mode" {
//     const allocator = std.testing.allocator;
//     const source =
//         \\module [main]
//         \\
//         \\main : U64
//         \\main = 0
//     ;
//
//     var optimized = try lowerModule(allocator, source, .wrappers);
//     defer optimized.deinit(allocator);
//     var ordinary = try lowerModule(allocator, source, .none);
//     defer ordinary.deinit(allocator);
//
//     try std.testing.expectEqual(@as(u32, 1), optimized.lowered.post_check_stats.optimized_contexts);
//     try std.testing.expectEqual(@as(u32, 0), ordinary.lowered.post_check_stats.optimized_contexts);
// }

// Ported pending iterator redesign: post_check_stats.optimized_contexts instrumentation is not part of the current pipeline.
// test "checking finalization lowering constructs no optimized context" {
//     const allocator = std.testing.allocator;
//     const source =
//         \\module [main]
//         \\
//         \\main : U64
//         \\main = 0
//     ;
//
//     var lowered = try lowerModuleWithOptions(allocator, source, .none, .{
//         .checked_module_state = .checking_finalization,
//     });
//     defer lowered.deinit(allocator);
//
//     try std.testing.expectEqual(@as(u32, 0), lowered.lowered.post_check_stats.optimized_contexts);
// }

test "post-check lowering mode gates public iter adapter elimination" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\sum_points : U64 -> U64
        \\sum_points = |extra| {
        \\    base_points = [1, 2, 3].iter()
        \\
        \\    collision_points =
        \\        if extra == 0 {
        \\            base_points
        \\        } else {
        \\            base_points.append(extra)
        \\        }
        \\
        \\    var $sum = 0
        \\    for point in collision_points {
        \\        $sum = $sum + point
        \\    }
        \\    $sum
        \\}
        \\
        \\main : U64
        \\main = sum_points(4)
    ;

    var optimized = try lowerModuleWithOptions(allocator, source, .wrappers, .{ .proc_debug_names = true });
    defer optimized.deinit(allocator);
    var ordinary = try lowerModuleWithOptions(allocator, source, .none, .{ .proc_debug_names = true });
    defer ordinary.deinit(allocator);

    try std.testing.expect(!try reachableProcDebugName(allocator, &optimized.lowered, "Builtin.Iter.append"));
    try std.testing.expect(try reachableProcDebugName(allocator, &ordinary.lowered, "Builtin.Iter.append"));
}

// Ported pending iterator redesign: this test constructs state_loop/state_continue lifted IR that the current lifted AST does not define.
// test "state loop lowers to ordinary lir joins" {
//     const allocator = std.testing.allocator;
//     const source =
//         \\module [main]
//         \\
//         \\main : U64
//         \\main = 0
//     ;
//
//     var lifted_source = try liftModuleAfterSpecConstr(allocator, source);
//     defer helpers.cleanupParseAndCanonical(allocator, lifted_source.resources);
//
//     const Lifted = postcheck.MonotypeLifted.Ast;
//     var lifted = lifted_source.lifted;
//     var lifted_owned = true;
//     defer if (lifted_owned) lifted.deinit();
//     lifted_source.lifted = undefined;
//
//     try std.testing.expectEqual(@as(usize, 1), lifted.roots.items.len);
//     const root_fn_id = lifted.roots.items[0].fn_id;
//     const root_fn_index = @intFromEnum(root_fn_id);
//     const ret_ty = lifted.fns.items[root_fn_index].ret;
//     const original_body = switch (lifted.fns.items[root_fn_index].body) {
//         .roc => |body| body,
//         .hosted => return error.TestUnexpectedResult,
//     };
//
//     const empty_params = try lifted.addTypedLocalSpan(&.{});
//     const empty_values = try lifted.addExprSpan(&.{});
//     const state_start: u32 = @intCast(lifted.state_loop_states.items.len);
//     const state0_id: Lifted.StateLoopStateId = @enumFromInt(state_start);
//     const state1_id: Lifted.StateLoopStateId = @enumFromInt(state_start + 1);
//
//     const break_expr = try lifted.addExpr(.{
//         .ty = ret_ty,
//         .data = .{ .break_ = original_body },
//     });
//     const continue_expr = try lifted.addExpr(.{
//         .ty = ret_ty,
//         .data = .{ .state_continue = .{
//             .target_state = state1_id,
//             .values = empty_values,
//         } },
//     });
//     const states = [_]Lifted.StateLoopState{
//         .{
//             .params = empty_params,
//             .body = continue_expr,
//         },
//         .{
//             .params = empty_params,
//             .body = break_expr,
//         },
//     };
//     const state_span = try lifted.addStateLoopStateSpan(&states);
//     const state_loop_expr = try lifted.addExpr(.{
//         .ty = ret_ty,
//         .data = .{ .state_loop = .{
//             .entry_state = state0_id,
//             .entry_values = empty_values,
//             .states = state_span,
//         } },
//     });
//     lifted.fns.items[root_fn_index].body = .{ .roc = state_loop_expr };
//
//     var solved = try postcheck.LambdaSolved.Solve.run(allocator, lifted);
//     lifted_owned = false;
//     lifted = undefined;
//     var solved_owned = true;
//     errdefer if (solved_owned) solved.deinit();
//
//     var output = try postcheck.SolvedLirLower.run(allocator, base.target.TargetUsize.native, solved, .{});
//     solved_owned = false;
//     solved = undefined;
//     defer output.deinit();
//
//     try std.testing.expectEqual(@as(usize, 1), output.lir_result.root_procs.items.len);
//     const root_proc = output.lir_result.root_procs.items[0];
//     const shape = try collectLirResultProcShape(allocator, &output.lir_result, root_proc);
//
//     try std.testing.expectEqual(@as(usize, 2), shape.join_count);
//     try std.testing.expectEqual(@as(usize, 0), shape.max_join_param_count);
//     try std.testing.expectEqual(@as(usize, 2), shape.jump_count);
// }

test "dynamic static list iter append loop splits nested callable captures" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\Point : { x : I64, y : I64 }
        \\
        \\main : U64 -> I64
        \\main = |anim_index| {
        \\    base_points = [
        \\        { x: 11, y: 2 },
        \\        { x: 13, y: 3 },
        \\        { x: 3, y: 5 },
        \\        { x: 11, y: 6 },
        \\    ].iter()
        \\
        \\    collision_points =
        \\        if anim_index == 2 {
        \\            base_points.append({ x: 2, y: 1 }).append({ x: 7, y: 1 })
        \\        } else if anim_index == 1 {
        \\            base_points.append({ x: 2, y: 2 })
        \\        } else {
        \\            base_points
        \\        }
        \\
        \\    var $sum = 0
        \\    for { x, y } in collision_points {
        \\        $sum = $sum + x + y
        \\    }
        \\    $sum
        \\}
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);
}

test "static record list iter append loop avoids direct-list append allocation" {
    const record_iter_source =
        \\module [main]
        \\
        \\Point : { x : I64, y : I64 }
        \\
        \\main : Bool -> I64
        \\main = |use_extra| {
        \\    base_points = [
        \\        { x: 11, y: 2 },
        \\    ].iter()
        \\
        \\    collision_points =
        \\        if use_extra {
        \\            base_points.append({ x: 2, y: 1 })
        \\        } else {
        \\            base_points
        \\        }
        \\
        \\    var $sum = 0
        \\    for { x, y } in collision_points {
        \\        $sum = $sum + x + y
        \\    }
        \\    $sum
        \\}
    ;
    const record_list_source =
        \\module [main]
        \\
        \\Point : { x : I64, y : I64 }
        \\
        \\main : Bool -> I64
        \\main = |use_extra| {
        \\    base_points = [
        \\        { x: 11, y: 2 },
        \\    ]
        \\
        \\    collision_points =
        \\        if use_extra {
        \\            base_points.append({ x: 2, y: 1 })
        \\        } else {
        \\            base_points
        \\        }
        \\
        \\    var $sum = 0
        \\    for { x, y } in collision_points {
        \\        $sum = $sum + x + y
        \\    }
        \\    $sum
        \\}
    ;

    try expectStaticListIterAppendLoopAvoidsListAppendAllocation(record_iter_source, record_list_source);
}

test "static primitive list iter append loop avoids direct-list append allocation" {
    const primitive_iter_source =
        \\module [main]
        \\
        \\main : Bool -> I64
        \\main = |use_extra| {
        \\    base_points = [11.I64].iter()
        \\
        \\    collision_points =
        \\        if use_extra {
        \\            base_points.append(2)
        \\        } else {
        \\            base_points
        \\        }
        \\
        \\    var $sum = 0
        \\    for point in collision_points {
        \\        $sum = $sum + point
        \\    }
        \\    $sum
        \\}
    ;
    const primitive_list_source =
        \\module [main]
        \\
        \\main : Bool -> I64
        \\main = |use_extra| {
        \\    base_points = [11.I64]
        \\
        \\    collision_points =
        \\        if use_extra {
        \\            base_points.append(2)
        \\        } else {
        \\            base_points
        \\        }
        \\
        \\    var $sum = 0
        \\    for point in collision_points {
        \\        $sum = $sum + point
        \\    }
        \\    $sum
        \\}
    ;

    try expectStaticListIterAppendLoopAvoidsListAppendAllocation(primitive_iter_source, primitive_list_source);
}

test "stream from iterator collect keeps finite step callables" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\main : () => List(I64)
        \\main = || {
        \\    stream =
        \\        [1.I64, 2]
        \\            .iter()
        \\            .append(3)
        \\            .stream()
        \\            .map!(|n| n + 1)
        \\
        \\    Stream.collect!(stream)
        \\}
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    try expectNoReachableErasedCallableLowering(allocator, &optimized.lowered);
}

test "optimized infinite custom iterator consumes finite prefix" {
    const source =
        \\module [main]
        \\
        \\main : U64
        \\main = {
        \\    adv : ((U64, U64) -> Try((U64, (U64, U64)), [NoMore]))
        \\    adv = |(a, b)| Try.Ok((a, (b, a + b)))
        \\
        \\    fib_iter = Iter.custom((0.U64, 1.U64), Unknown, adv)
        \\
        \\    var $sum = 0.U64
        \\    for f in fib_iter.take_first(5) {
        \\        $sum = $sum + f
        \\    }
        \\    dbg $sum
        \\    $sum
        \\}
    ;

    try expectOptimizedDbgEvents(source, &.{"7"});
}

test "spec constr list filter-map loop does not produce unbound ARC locals" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\main : List(I32)
        \\main = {
        \\    var $out = []
        \\    for item in [] {
        \\        $out = $out.append(item)
        \\    }
        \\    $out
        \\}
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);
}

test "spec constr preserves known-match expect failure order" {
    try expectOptimizedHostEvents(
        \\module [main]
        \\
        \\State : { n : I64 }
        \\Step : [One({ item : I64 })]
        \\
        \\tap : I64 -> I64
        \\tap = |n| {
        \\    dbg "payload"
        \\    n
        \\}
        \\
        \\outer : State -> I64
        \\outer = |state|
        \\    match One({ item: tap(state.n) }) {
        \\        One({ item }) => {
        \\            dbg "branch-before"
        \\            expect False
        \\            item
        \\        }
        \\    }
        \\
        \\main : I64
        \\main = outer({ n: 1 })
    , .returned, &.{
        .{ .dbg = "\"payload\"" },
        .{ .dbg = "\"branch-before\"" },
        .expect_failed,
    });
}

test "spec constr preserves known-match crash order" {
    try expectOptimizedHostEvents(
        \\module [main]
        \\
        \\State : { n : I64 }
        \\Step : [One({ item : I64 })]
        \\
        \\tap : I64 -> I64
        \\tap = |n| {
        \\    dbg "payload"
        \\    n
        \\}
        \\
        \\outer : State -> I64
        \\outer = |state|
        \\    match One({ item: tap(state.n) }) {
        \\        One({ item: _ }) => {
        \\            dbg "branch-before"
        \\            crash "boom"
        \\        }
        \\    }
        \\
        \\main : I64
        \\main = outer({ n: 1 })
    , .crashed, &.{
        .{ .dbg = "\"payload\"" },
        .{ .dbg = "\"branch-before\"" },
        .{ .crashed = "boom" },
    });
}

test "spec constr specializes primitive-start record state carried by while loop" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\State : { n : I64, acc : I64 }
        \\
        \\sum_from : I64 -> I64
        \\sum_from = |start| {
        \\    var $state = { n: start, acc: 0 }
        \\
        \\    while $state.n != 0 {
        \\        $state = { n: $state.n - 1, acc: $state.acc + $state.n }
        \\    }
        \\
        \\    $state.acc
        \\}
        \\
        \\main : I64
        \\main = sum_from(4)
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWorkerIsSpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWorkerIsGeneric));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWorkerIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWorkerIsGeneric));
}

test "spec constr does not require single-field record wrapper for local loop splitting" {
    const allocator = std.testing.allocator;
    const wrapped_source =
        \\module [main]
        \\
        \\Start : { n : I64 }
        \\State : { n : I64, acc : I64 }
        \\
        \\sum_from : Start -> I64
        \\sum_from = |start| {
        \\    var $state = { n: start.n, acc: 0 }
        \\
        \\    while $state.n != 0 {
        \\        $state = { n: $state.n - 1, acc: $state.acc + $state.n }
        \\    }
        \\
        \\    $state.acc
        \\}
        \\
        \\main : I64
        \\main = sum_from({ n: 4 })
    ;
    const primitive_source =
        \\module [main]
        \\
        \\State : { n : I64, acc : I64 }
        \\
        \\sum_from : I64 -> I64
        \\sum_from = |start| {
        \\    var $state = { n: start, acc: 0 }
        \\
        \\    while $state.n != 0 {
        \\        $state = { n: $state.n - 1, acc: $state.acc + $state.n }
        \\    }
        \\
        \\    $state.acc
        \\}
        \\
        \\main : I64
        \\main = sum_from(4)
    ;

    var wrapped_optimized = try lowerModule(allocator, wrapped_source, .wrappers);
    defer wrapped_optimized.deinit(allocator);
    var primitive_optimized = try lowerModule(allocator, primitive_source, .wrappers);
    defer primitive_optimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &wrapped_optimized.lowered, localLoopStateIsSplitToTwoLeaves));
    try std.testing.expect(try reachableProcShape(allocator, &primitive_optimized.lowered, localLoopStateIsSplitToTwoLeaves));
}

test "spec constr splits loop record state with opaque callable field" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\State : { n : I64, f : I64 -> I64 }
        \\
        \\inc : I64 -> I64
        \\inc = |n| n + 1
        \\
        \\sum_from : I64 -> I64
        \\sum_from = |start| {
        \\    var $state = { n: start, f: inc }
        \\
        \\    while $state.n != 0 {
        \\        $state = { n: $state.n - 1, f: $state.f }
        \\    }
        \\
        \\    f = $state.f
        \\    f($state.n)
        \\}
        \\
        \\main : I64
        \\main = sum_from(4)
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWithZeroCaptureCallableIsSpecialized));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWorkerIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWorkerIsGeneric));
}

test "spec constr splits loop record state with direct callable captures" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\State : { n : I64, f : I64 -> I64 }
        \\
        \\sum_from : I64, I64, I64 -> I64
        \\sum_from = |start, scale, offset| {
        \\    f = |n| n * scale + offset
        \\    var $state = { n: start, f }
        \\
        \\    while $state.n != 0 {
        \\        $state = { n: $state.n - 1, f: $state.f }
        \\    }
        \\
        \\    f = $state.f
        \\    f($state.n)
        \\}
        \\
        \\main : I64
        \\main = sum_from(4, 10, 3)
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWithCallableCapturesIsSpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWithOpaqueCallableIsSpecialized));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWithCallableCapturesIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWorkerIsGeneric));
}

test "spec constr splits loop record state with returned callable captures" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\State : { n : I64, f : I64 -> I64 }
        \\
        \\make_affine = |scale, offset| |n| n * scale + offset
        \\
        \\sum_from : I64, I64, I64 -> I64
        \\sum_from = |start, scale, offset| {
        \\    var $state = { n: start, f: make_affine(scale, offset) }
        \\
        \\    while $state.n != 0 {
        \\        $state = { n: $state.n - 1, f: $state.f }
        \\    }
        \\
        \\    f = $state.f
        \\    f($state.n)
        \\}
        \\
        \\main : I64
        \\main = sum_from(4, 10, 3)
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWithCallableCapturesIsSpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWithOpaqueCallableIsSpecialized));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWithCallableCapturesIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWorkerIsGeneric));
}

test "spec constr splits loop record state with annotated returned callable captures" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\State : { n : I64, f : I64 -> I64 }
        \\
        \\make_affine : I64, I64 -> (I64 -> I64)
        \\make_affine = |scale, offset| |n| n * scale + offset
        \\
        \\sum_from : I64, I64, I64 -> I64
        \\sum_from = |start, scale, offset| {
        \\    var $state = { n: start, f: make_affine(scale, offset) }
        \\
        \\    while $state.n != 0 {
        \\        $state = { n: $state.n - 1, f: $state.f }
        \\    }
        \\
        \\    f = $state.f
        \\    f($state.n)
        \\}
        \\
        \\main : I64
        \\main = sum_from(4, 10, 3)
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWithCallableCapturesIsSpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, whileRecordStateWithOpaqueCallableIsSpecialized));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWithCallableCapturesIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, whileRecordStateWorkerIsGeneric));
}

test "spec constr exposes direct call record result for field access" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\Start : { n : I64 }
        \\State : { n : I64, acc : I64 }
        \\
        \\make_state : I64 -> State
        \\make_state = |n| { n: n, acc: n + 1 }
        \\
        \\read_acc : Start -> I64
        \\read_acc = |start| make_state(start.n).acc
        \\
        \\main : I64
        \\main = read_acc({ n: 4 })
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "direct_call_count"));
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "struct_assign_count"));

    try std.testing.expect(try reachableProcShapeFieldTotal(allocator, &unoptimized.lowered, "direct_call_count") > 0);
    try std.testing.expect(try reachableProcShapeFieldTotal(allocator, &unoptimized.lowered, "struct_assign_count") > 0);
}

test "spec constr exposes block-wrapped direct call record result for field access" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\State : { n : I64, acc : I64 }
        \\
        \\make_state : I64 -> State
        \\make_state = |n| { n: n, acc: n + 1 }
        \\
        \\main : I64
        \\main = { make_state(4) }.acc
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "direct_call_count"));
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "struct_assign_count"));

    try std.testing.expect(try reachableProcShapeFieldTotal(allocator, &unoptimized.lowered, "direct_call_count") > 0);
    try std.testing.expect(try reachableProcShapeFieldTotal(allocator, &unoptimized.lowered, "struct_assign_count") > 0);
}

test "spec constr exposes demanded direct call argument facts" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\State : { n : I64, acc : I64 }
        \\
        \\make_state : I64 -> State
        \\make_state = |n| { n: n, acc: n + 1 }
        \\
        \\copy_state : State -> State
        \\copy_state = |state| { n: state.n, acc: state.acc }
        \\
        \\main : I64
        \\main = copy_state(make_state(4)).acc
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "direct_call_count"));

    try std.testing.expect(try reachableProcShapeFieldTotal(allocator, &unoptimized.lowered, "direct_call_count") > 0);
}

test "spec constr specializes if-joined record state carried by while loop" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\Start : { n : I64 }
        \\State : { n : I64, acc : I64 }
        \\
        \\sum_from : Start, Bool -> I64
        \\sum_from = |seed, flag| {
        \\    start =
        \\        if flag {
        \\            { n: seed.n, acc: 0 }
        \\        } else {
        \\            { n: seed.n - 1, acc: 1 }
        \\        }
        \\
        \\    var $state = start
        \\
        \\    while $state.n != 0 {
        \\        $state = { n: $state.n - 1, acc: $state.acc + $state.n }
        \\    }
        \\
        \\    $state.acc
        \\}
        \\
        \\main : I64
        \\main = sum_from({ n: 4 }, True)
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, branchJoinedRecordStateWorkerIsSpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, branchJoinedRecordStateWorkerIsGeneric));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, branchJoinedRecordStateWorkerIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, branchJoinedRecordStateWorkerIsGeneric));
}

test "spec constr specializes match-joined record state carried by while loop" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\Start : { n : I64 }
        \\State : { n : I64, acc : I64 }
        \\
        \\sum_from : Start, Bool -> I64
        \\sum_from = |seed, flag| {
        \\    start =
        \\        match flag {
        \\            True => { n: seed.n, acc: 0 }
        \\            False => { n: seed.n - 1, acc: 1 }
        \\        }
        \\
        \\    var $state = start
        \\
        \\    while $state.n != 0 {
        \\        $state = { n: $state.n - 1, acc: $state.acc + $state.n }
        \\    }
        \\
        \\    $state.acc
        \\}
        \\
        \\main : I64
        \\main = sum_from({ n: 4 }, True)
    ;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var unoptimized = try lowerModule(allocator, source, .none);
    defer unoptimized.deinit(allocator);

    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, branchJoinedRecordStateWorkerIsSpecialized));
    try std.testing.expect(!try reachableProcShape(allocator, &optimized.lowered, branchJoinedRecordStateWorkerIsGeneric));

    try std.testing.expect(!try reachableProcShape(allocator, &unoptimized.lowered, branchJoinedRecordStateWorkerIsSpecialized));
    try std.testing.expect(try reachableProcShape(allocator, &unoptimized.lowered, branchJoinedRecordStateWorkerIsGeneric));
}

// ============================================================================
// Iterator-fusion differential harness (iter_fusion_design.md Phase 0).
//
// Each `iterdiff:` test lowers ONE Roc source under two inline modes and runs
// both through the interpreter against `RuntimeHostEnv`, then asserts the two
// runs are observationally identical:
//
//   * `.wrappers` is the optimized/inlined lowering (the closest proxy the tree
//     has for "fused" until real stream fusion lands; when fusion is
//     implemented it composes into this same mode, so these tests keep guarding
//     it).
//   * `.none` is the naive, un-inlined lowering ("unfused").
//
// The two runs must agree on:
//   * crash-versus-no-crash (`RecordedRun.termination`), and
//   * the full ordered host-effect trace (`RecordedRun.events`): every `dbg`,
//     `expect` failure, and crash message, in order.
//
// Result VALUES are observed through the effect trace: each pipeline `dbg`s its
// result (and, where useful, each element as it is produced). `dbg` renders a
// value structurally and pointer-independently (e.g. `[6, 8, 10, 12]`), so a
// `dbg` of the collected List/Set output is a complete, allocation-independent
// value assertion that lives inside the compared trace. Ordered per-element
// `dbg`s additionally pin element order and effect ordering (design invariants
// 4 and 5). Allocation counts are intentionally NOT compared: fusing away
// adapter objects legitimately changes how much a run allocates.
//
// A test that fails or crashes here on the current tree is a genuine
// pre-existing divergence between the optimized and naive lowerings, not a test
// bug; such cases are committed commented-out with a `// Pre-existing
// divergence:` marker rather than weakened to pass.
// ============================================================================

fn expectRecordedRunsEqual(
    expected: eval.RuntimeHostEnv.RecordedRun,
    actual: eval.RuntimeHostEnv.RecordedRun,
) TestError!void {
    // crash-versus-no-crash
    try std.testing.expectEqual(expected.termination, actual.termination);

    // full ordered effect trace (dbg values, expect failures, crash messages)
    try std.testing.expectEqual(expected.events.len, actual.events.len);
    for (expected.events, actual.events) |expected_event, actual_event| {
        try std.testing.expectEqual(
            std.meta.activeTag(expected_event),
            std.meta.activeTag(actual_event),
        );
        try std.testing.expectEqualStrings(expected_event.bytes(), actual_event.bytes());
    }
}

fn expectSameObservationsAcrossInlineModes(source: []const u8) TestError!void {
    const allocator = std.testing.allocator;

    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    var naive = try lowerModule(allocator, source, .none);
    defer naive.deinit(allocator);

    var naive_run = try runLoweredWithHostEvents(allocator, &naive.lowered);
    defer naive_run.deinit(allocator);

    var optimized_run = try runLoweredWithHostEvents(allocator, &optimized.lowered);
    defer optimized_run.deinit(allocator);

    try expectRecordedRunsEqual(naive_run, optimized_run);
}

test "iterdiff: bounded list map collect agrees across inline modes" {
    // Map over a statically-known list, collected into a List, then reduced to a
    // scalar. The `dbg` of the collected list is the structural (allocation-
    // independent) value assertion; `dbg` of the scalar pins the fold result.
    try expectSameObservationsAcrossInlineModes(
        \\module [main]
        \\
        \\main : I64
        \\main = {
        \\    doubled : List(I64)
        \\    doubled =
        \\        [1.I64, 2, 3, 4, 5, 6]
        \\            .iter()
        \\            .map(|n| n * 2)
        \\            .collect()
        \\    total = List.sum(doubled)
        \\    dbg doubled
        \\    dbg total
        \\    total
        \\}
    );
}

// A filter-like adapter (`keep_if`) drives a collect loop whose loop-carried
// source iterator advances through a runtime step result. The step callable's
// successor iterator must carry the advanced inner iterator produced by the
// step, so the inner index advances every iteration and the loop terminates.
// Both lowering modes observe the same filtered list. Minimal repro:
// `[1.I64, 2, 3].iter().keep_if(|n| n > 1).collect()` returns `[2, 3]`.
test "iterdiff: bounded list map keep_if collect agrees across inline modes" {
    try expectSameObservationsAcrossInlineModes(
        \\module [main]
        \\
        \\main : I64
        \\main = {
        \\    doubled : List(I64)
        \\    doubled =
        \\        [1.I64, 2, 3, 4, 5, 6]
        \\            .iter()
        \\            .map(|n| n * 2)
        \\            .keep_if(|n| n > 5)
        \\            .collect()
        \\    total = List.sum(doubled)
        \\    dbg doubled
        \\    dbg total
        \\    total
        \\}
    );
}

test "iterdiff: if-chosen iterator chains consumed by one loop agree across inline modes" {
    try expectSameObservationsAcrossInlineModes(
        \\module [main]
        \\
        \\main : I64
        \\main = {
        \\    threshold = 4.I64
        \\    chosen : Iter(I64)
        \\    chosen =
        \\        if threshold > 3 {
        \\            [1.I64, 2, 3].iter().map(|n| n * 10)
        \\        } else {
        \\            [4.I64, 5, 6].iter().keep_if(|n| n > 4)
        \\        }
        \\    var $sum = 0.I64
        \\    for x in chosen {
        \\        dbg x
        \\        $sum = $sum + x
        \\    }
        \\    dbg $sum
        \\    $sum
        \\}
    );
}

test "iterdiff: branch-chosen append search with early return agrees across inline modes" {
    // Rocci's `on_screen_collided!` shape exactly: a zero-accumulator `for` over
    // a branch-chosen append chain of record elements that returns early on the
    // first match. The branch-append peel factors the shared base iteration out
    // and replays the per-element check over each arm's appended items (binding
    // each appended record's fields directly); the returned first-match value
    // pins the exact pull order (base elements, then appended items in append
    // order, with the early return short-circuiting). Both lowerings must return
    // the same value for every `(selector, target)` probe.
    try expectSameObservationsAcrossInlineModes(
        \\module [main]
        \\
        \\Point : { x : I64, y : I64 }
        \\
        \\find : U64, I64 -> I64
        \\find = |selector, target| {
        \\    base = [{ x: 10, y: 1 }, { x: 20, y: 2 }, { x: 30, y: 3 }].iter()
        \\    chosen =
        \\        if selector == 2 {
        \\            base.append({ x: 40, y: 4 }).append({ x: 50, y: 5 })
        \\        } else if selector == 1 {
        \\            base.append({ x: 60, y: 6 })
        \\        } else {
        \\            base
        \\        }
        \\    for { x, y } in chosen {
        \\        if x >= target {
        \\            return x + y
        \\        }
        \\    }
        \\    -1
        \\}
        \\
        \\main : I64
        \\main = {
        \\    a = find(2, 35)
        \\    b = find(2, 45)
        \\    c = find(2, 100)
        \\    d = find(1, 55)
        \\    e = find(0, 5)
        \\    f = find(0, 100)
        \\    dbg a
        \\    dbg b
        \\    dbg c
        \\    dbg d
        \\    dbg e
        \\    dbg f
        \\    a + b + c + d + e + f
        \\}
    );
}

test "iterdiff: set materialized mid-pipeline then iterated agrees across inline modes" {
    // Design invariant 4: constructing a Set from the elements really runs, so
    // its deduplication happens exactly where written; the pipeline then keeps
    // iterating over the materialized result. Both lowerings must observe the
    // same deduplicated element sequence and the same collected output.
    try expectSameObservationsAcrossInlineModes(
        \\module [main]
        \\
        \\main : I64
        \\main = {
        \\    deduped : Set(I64)
        \\    deduped = Set.from_list([3.I64, 1, 2, 2, 3, 1, 4, 3])
        \\    doubled : List(I64)
        \\    doubled =
        \\        deduped
        \\            .to_list()
        \\            .iter()
        \\            .map(|n| n * 2)
        \\            .collect()
        \\    dbg deduped.to_list()
        \\    dbg doubled
        \\    List.sum(doubled)
        \\}
    );
}

test "iterdiff: coarse custom is_eq set dedup keeps same representative across inline modes" {
    // Design invariant 6: the optimizer must never use a user `is_eq` result to
    // substitute one value for another. `Bucket.is_eq` compares only `key`, so
    // deduplication is a coarse quotient; `tag` is the representative-
    // distinguishing observer. Both lowerings must keep the SAME surviving
    // representative (identical ordered `tag` trace), never a different one the
    // quotient happens to call equal.
    try expectSameObservationsAcrossInlineModes(
        \\module [main]
        \\
        \\Bucket := { key : I64, tag : I64 }.{
        \\    is_eq : Bucket, Bucket -> Bool
        \\    is_eq = |a, b| a.key == b.key
        \\}
        \\
        \\main : I64
        \\main = {
        \\    buckets : List(Bucket)
        \\    buckets = [
        \\        { key: 1, tag: 100 },
        \\        { key: 2, tag: 200 },
        \\        { key: 1, tag: 999 },
        \\        { key: 2, tag: 888 },
        \\        { key: 3, tag: 300 },
        \\    ]
        \\    deduped : Set(Bucket)
        \\    deduped = Set.from_list(buckets)
        \\    var $tag_sum = 0.I64
        \\    for b in deduped.to_list().iter() {
        \\        dbg b.tag
        \\        $tag_sum = $tag_sum + b.tag
        \\    }
        \\    dbg $tag_sum
        \\    $tag_sum
        \\}
    );
}

test "iterdiff: stream per-element effects agree across inline modes" {
    // Design invariant 5: a Stream pipeline's observable effect trace is the
    // per-element, innermost-first pull order, and every lowering must
    // reproduce it exactly. The effectful `map!` step `dbg`s each element as it
    // is pulled, so the ordered trace pins effect order across inline modes.
    try expectSameObservationsAcrossInlineModes(
        \\module [main]
        \\
        \\main : () => List(I64)
        \\main = || {
        \\    stream =
        \\        [1.I64, 2, 3]
        \\            .iter()
        \\            .stream()
        \\            .map!(|n| {
        \\                dbg n
        \\                n * 2
        \\            })
        \\    result = Stream.collect!(stream)
        \\    dbg result
        \\    result
        \\}
    );
}

// Pre-existing divergence: a bounded prefix (`take_first`) of an infinite custom
// iterator (`Iter.custom`, the Fibonacci unfold below) diverges between the two
// lowerings, and the seed+step representation does NOT fix it: the divergence is
// an optimizer (spec_constr) miscompile, not a representation issue. The naive
// (`.none`) run yields the correct sequence 0,1,1,2,3,5,8,13; the optimized
// (`.wrappers`) run yields 0,0,0,0,0,0,0,0 (sum 0). Root cause, confirmed from
// the lowered LIR: the custom step correctly computes the advanced `next_seed`,
// but spec_constr rebuilds the successor iterator re-reading the ORIGINAL
// captured seed instead of `next_seed` (the seed's initial value is entry-known,
// so spec_constr treats a runtime-varying loop-carried field as loop-invariant
// and freezes it). The `keep_if` hang above is the same bug on a loop-carried
// iterator box. Activated as an active-failing genuine divergence per the Phase
// 1 gate (both modes disagree). See Phase 1 report for the minimized repro.
test "iterdiff: infinite custom iterator bounded prefix agrees across inline modes" {
    try expectSameObservationsAcrossInlineModes(
        \\module [main]
        \\
        \\main : U64
        \\main = {
        \\    adv : ((U64, U64) -> Try((U64, (U64, U64)), [NoMore]))
        \\    adv = |(a, b)| Try.Ok((a, (b, a + b)))
        \\    fib_iter = Iter.custom((0.U64, 1.U64), Unknown, adv)
        \\    var $sum = 0.U64
        \\    for f in fib_iter.take_first(8) {
        \\        dbg f
        \\        $sum = $sum + f
        \\    }
        \\    dbg $sum
        \\    $sum
        \\}
    );
}

// Tier-one LIR identity (iter_fusion_design.md Acceptance item 2). A bounded
// `list.iter().map(f).collect()` whose construction is statically known at its
// consuming loop fuses to the same generated-code loop as a hand-written `for`
// loop: no adapter dispatch, no per-element indirect call, one scalar loop that
// indexes the source list directly.
//
// The comparison is asserted per the principled relation rather than raw
// per-field equality across every field, because two field families cannot
// reach equality for reasons that are inherent to the compared programs, not
// missed fusion (flagged in the Slice D report):
//
//   * Consumer allocation strategy. `.collect()` on a bounded iterator knows
//     the length up front, so it pre-sizes with `list_with_capacity` and writes
//     each element with the unchecked append. A hand-written `for` + `.append`
//     is `List.append`, which reserves incrementally (`list_reserve`) and stays
//     a per-element call. This is a consumer difference, not an iterator one, so
//     `list_with_capacity`/`list_reserve`/`list_append_unsafe`/`direct_call`
//     differ by design; the relation (collect pre-sizes, manual grows) is
//     asserted instead.
//   * Adapter carried box. `map` over a list carries a nested recursive-nominal
//     iterator (map wraps the list iterator), whose loop-exit re-materialization
//     is Slice E's box (amplified to a nested pair here). The plain list-iterator
//     `for` loop carries no such box, so its exit re-materializes nothing.
test "iterdiff: tier-one map collect matches hand-written loop shape" {
    const allocator = std.testing.allocator;
    const iter_source =
        \\module [main]
        \\
        \\main : List(I64)
        \\main =
        \\    [1.I64, 2, 3, 4, 5, 6]
        \\        .iter()
        \\        .map(|n| n * 2)
        \\        .collect()
    ;
    const loop_source =
        \\module [main]
        \\
        \\main : List(I64)
        \\main = {
        \\    var $out = []
        \\    for n in [1.I64, 2, 3, 4, 5, 6] {
        \\        $out = $out.append(n * 2)
        \\    }
        \\    $out
        \\}
    ;

    var iter_lowered = try lowerModule(allocator, iter_source, .wrappers);
    defer iter_lowered.deinit(allocator);
    var loop_lowered = try lowerModule(allocator, loop_source, .wrappers);
    defer loop_lowered.deinit(allocator);

    const iter = &iter_lowered.lowered;
    const loop = &loop_lowered.lowered;

    // Tier-one guarantee: neither side dispatches through an erased adapter
    // callable. Both the fused pipeline and the fused hand-written loop drive a
    // first-order loop with no `Iter.next` indirection.
    inline for (.{ "erased_call_count", "packed_erased_fn_count" }) |field_name| {
        try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, iter, field_name));
        try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, loop, field_name));
    }

    // Same fused loop skeleton: one loop join, the same set of back/exit edges,
    // and one direct source-list index per element on each side.
    inline for (.{ "join_count", "jump_count", "list_get_unsafe_count" }) |field_name| {
        const iter_total = try reachableProcShapeFieldTotal(allocator, iter, field_name);
        const loop_total = try reachableProcShapeFieldTotal(allocator, loop, field_name);
        try std.testing.expectEqual(loop_total, iter_total);
    }

    // Consumer allocation strategy differs by design (see header): collect
    // pre-sizes, the manual loop grows.
    try std.testing.expect(try reachableProcShapeFieldTotal(allocator, iter, "list_with_capacity_count") >= 1);
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, loop, "list_with_capacity_count"));
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, iter, "list_reserve_count"));
    try std.testing.expect(try reachableProcShapeFieldTotal(allocator, loop, "list_reserve_count") >= 1);

    // Adapter carried box (Slice E): only the map-over-list pipeline
    // re-materializes its nested iterator at loop exit.
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, loop, "box_box_count"));
    try std.testing.expect(try reachableProcShapeFieldTotal(allocator, iter, "box_box_count") >= 1);
}

// Slice H aliasing guard (refcount-exactness for opportunistic mutation).
//
// Slice H turns per-element reads of a loop-carried list into borrows anchored
// on the loop join parameter, dropping the retain/release pair those reads used
// to carry. Roc's in-place mutation is refcount-exact: `List.append` mutates
// its argument in place only when the list is uniquely owned. If the elision
// ever undercounted a shared list, an append would wrongly see it as unique and
// mutate shared data. These tests alias one list into two live consumers (one
// of which would mutate it in place if it looked unique) and assert the naive
// and optimized lowerings observe identical, unmutated values.
test "iterdiff: list aliased into an append and a loop stays unmutated across inline modes" {
    // `base` feeds both an append (a would-be in-place mutation) and a loop that
    // reads it per element (the Slice H borrow pattern). Because both consumers
    // are live, `base` is shared, so the append must copy it. The per-element
    // `dbg x`, the final `dbg base`, and `dbg grown` diverge between modes if the
    // shared list is ever mutated in place.
    try expectSameObservationsAcrossInlineModes(
        \\module [main]
        \\
        \\main : I64
        \\main = {
        \\    base : List(I64)
        \\    base = [10.I64, 20, 30]
        \\    grown : List(I64)
        \\    grown = base.append(40)
        \\    var $sum = 0.I64
        \\    for x in base.iter() {
        \\        dbg x
        \\        $sum = $sum + x
        \\    }
        \\    dbg base
        \\    dbg grown
        \\    dbg $sum
        \\    $sum
        \\}
    );
}

test "iterdiff: loop-carried list appended inside its own loop stays unmutated across inline modes" {
    // The list is the loop source (carried across the join and read per element
    // as a Slice H borrow) AND is appended inside the body. It is shared for the
    // whole loop, so each append must copy it; an in-place mutation of the
    // carried source would change later iterations and the final `dbg base`.
    try expectSameObservationsAcrossInlineModes(
        \\module [main]
        \\
        \\main : U64
        \\main = {
        \\    base : List(I64)
        \\    base = [1.I64, 2, 3]
        \\    var $out = []
        \\    for x in base.iter() {
        \\        with_x : List(I64)
        \\        with_x = base.append(x)
        \\        dbg with_x
        \\        $out = $out.append(List.len(with_x))
        \\    }
        \\    dbg base
        \\    dbg $out
        \\    List.len($out)
        \\}
    );
}

test "spec constr keeps a same-binder scalar distinct from a substituted aggregate" {
    // A source pattern binder is reused across every monomorphization of its
    // binding. Here `pair` (a tuple parameter the caller passes a known tuple to,
    // so call-pattern specialization substitutes it) and `scalar` (a runtime
    // `let` local left un-inlined by a non-substitutable value) deliberately
    // share one binder at two monomorphic types. Keying binder-scoped
    // substitutions by the binder alone resolves the scalar reference to the
    // substituted tuple, materializing a tuple directly inside the result tuple.
    // The layout-carrying identity must keep them distinct.
    const allocator = std.testing.allocator;
    var mono = MonoAst.Program.init(allocator);
    var mono_consumed = false;
    errdefer if (!mono_consumed) mono.deinit();

    const shared_binder: check.CheckedModule.PatternBinderId = @enumFromInt(7);

    const u32_ty = try mono.types.add(.{ .primitive = .u32 });
    const pair_span = try mono.types.addSpan(&.{ u32_ty, u32_ty });
    const pair_ty = try mono.types.add(.{ .tuple = pair_span });
    const worker_fn_ty = try mono.types.add(.{ .func = .{
        .args = try mono.types.addSpan(&.{pair_ty}),
        .ret = pair_ty,
    } });
    const worker_fn_id = try mono.addFn(.{
        .fn_def = undefined,
        .source_fn_ty = undefined,
        .source_fn_key = .{},
        .mono_fn_ty = worker_fn_ty,
    });

    const opaque_scalar = try mono.addImportedFn(.{ .shard = @enumFromInt(1), .fn_id = @enumFromInt(1) });

    const pair_local = try mono.addLocalWithBinder(@enumFromInt(1), pair_ty, shared_binder);
    const scalar_local = try mono.addLocalWithBinder(@enumFromInt(2), u32_ty, shared_binder);

    const scalar_value = try mono.addExpr(.{ .ty = u32_ty, .data = .{ .call_proc = .{
        .callee = MonoAst.importedProcCallee(opaque_scalar),
        .args = MonoAst.Span(MonoAst.ExprId).empty(),
    } } });
    const scalar_pat = try mono.addPat(.{ .ty = u32_ty, .data = .{ .bind = scalar_local } });

    const pair_ref = try mono.addExpr(.{ .ty = pair_ty, .data = .{ .local = pair_local } });
    const pair_first = try mono.addExpr(.{ .ty = u32_ty, .data = .{ .tuple_access = .{ .tuple = pair_ref, .elem_index = 0 } } });
    const scalar_ref = try mono.addExpr(.{ .ty = u32_ty, .data = .{ .local = scalar_local } });
    const result_pair = try mono.addExpr(.{ .ty = pair_ty, .data = .{ .tuple = try mono.addExprSpan(&.{ pair_first, scalar_ref }) } });
    const worker_body = try mono.addExpr(.{ .ty = pair_ty, .data = .{ .let_ = .{
        .bind = scalar_pat,
        .value = scalar_value,
        .rest = result_pair,
    } } });

    try mono.defs.append(allocator, .{
        .symbol = @enumFromInt(10),
        .fn_id = worker_fn_id,
        .args = try mono.addTypedLocalSpan(&.{.{ .local = pair_local, .ty = pair_ty }}),
        .body = .{ .roc = worker_body },
        .ret = pair_ty,
    });

    const lit_a = try mono.addExpr(.{ .ty = u32_ty, .data = .{ .int_lit = .{ .bytes = @bitCast(@as(u128, 3)), .kind = .u128 } } });
    const lit_b = try mono.addExpr(.{ .ty = u32_ty, .data = .{ .int_lit = .{ .bytes = @bitCast(@as(u128, 4)), .kind = .u128 } } });
    const call_arg = try mono.addExpr(.{ .ty = pair_ty, .data = .{ .tuple = try mono.addExprSpan(&.{ lit_a, lit_b }) } });
    const caller_body = try mono.addExpr(.{ .ty = pair_ty, .data = .{ .call_proc = .{
        .callee = MonoAst.localProcCallee(worker_fn_id),
        .args = try mono.addExprSpan(&.{call_arg}),
    } } });
    try mono.defs.append(allocator, .{
        .symbol = @enumFromInt(11),
        .args = MonoAst.Span(MonoAst.TypedLocal).empty(),
        .body = .{ .roc = caller_body },
        .ret = pair_ty,
    });

    var lifted = try postcheck.MonotypeLifted.Lift.run(allocator, mono);
    mono_consumed = true;
    defer lifted.deinit();

    try postcheck.MonotypeLifted.SpecConstr.run(allocator, &lifted);
    try postcheck.MonotypeLifted.Lift.recomputeCaptures(allocator, &lifted);

    // The input program has no tuple nested directly inside another tuple, so a
    // nested tuple after specialization means the substituted aggregate leaked
    // into the scalar slot.
    for (lifted.exprs.items) |expr| {
        const items = switch (expr.data) {
            .tuple => |items| items,
            else => continue,
        };
        for (lifted.exprSpan(items)) |item| {
            switch (lifted.exprs.items[@intFromEnum(item)].data) {
                .tuple => return error.SubstitutedAggregateLeakedIntoScalar,
                else => {},
            }
        }
    }
}

fn bareListIterCollectLoopIsScalar(shape: ProcShape) bool {
    return shape.join_count >= 1 and
        shape.max_join_param_count >= 5 and
        shape.list_get_unsafe_count >= 1 and
        shape.list_append_unsafe_count >= 1 and
        shape.erased_call_count == 0 and
        shape.direct_call_count == 0;
}

test "bare list iter collect carries scalar list state in the loop" {
    const allocator = std.testing.allocator;
    const source =
        \\module [main]
        \\
        \\main : () -> List(I64)
        \\main = || [1.I64, 2, 3].iter().collect()
    ;
    var optimized = try lowerModule(allocator, source, .wrappers);
    defer optimized.deinit(allocator);

    // The consumer loop carries the list-iter state as scalar loop variables
    // (length payload, list, index) plus the output list, and indexes the
    // list directly per element. No reachable proc dispatches through the
    // erased step callable and no per-element call remains.
    try std.testing.expect(try reachableProcShape(allocator, &optimized.lowered, bareListIterCollectLoopIsScalar));
    try std.testing.expect(!try reachableIterCollectShape(allocator, &optimized.lowered, .generic));
    try std.testing.expect(!try reachableIterCollectShape(allocator, &optimized.lowered, .specialized));
    try expectNoReachableErasedCallableLowering(allocator, &optimized.lowered);
    // The list-iter carries its step closure inline by value, so the loop state
    // needs no boxed iterator state at all; the only allocation is the output
    // list itself.
    try std.testing.expectEqual(@as(usize, 0), try reachableProcShapeFieldTotal(allocator, &optimized.lowered, "box_box_count"));
}
