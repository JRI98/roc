//! Make calls cheaper when they pass values with known values to code that
//! immediately takes those values apart.
//!
//! The most obvious case is a freshly created tag union value that immediately
//! gets pattern-matched. The same idea also applies to records and tuples whose
//! fields are read right away, and to `Stream` values that carry a known step
//! function after inlining. This shows up in recursive helpers, `Iter`/`Stream`
//! pipelines, and loops that appear after inlining. This pass turns those calls
//! into calls to workers that take the useful pieces directly.
//!
//! Here is the smallest version of the idea:
//!
//! ```roc
//! Start : { n : I64 }
//! SumState : { n : I64, acc : I64 }
//!
//! sum : Start -> I64
//! sum = |start| {
//!     var $state = { n: start.n, acc: 0 }
//!
//!     while $state.n != 0 {
//!         $state = { n: $state.n - 1, acc: $state.acc + $state.n }
//!     }
//!
//!     $state.acc
//! }
//!
//! main = sum({ n: 4 })
//! ```
//!
//! The call to `sum` passes a known `Start` record, and the loop state is always
//! a `SumState`. The function reads `start.n`, then the loop immediately reads
//! `$state.n` and `$state.acc`. This pass rewrites the call and loop so they
//! carry the useful fields directly:
//!
//! ```roc
//! sum_worker : I64 -> I64
//! sum_worker = |start_n| {
//!     var $n = start_n
//!     var $acc = 0
//!
//!     while $n != 0 {
//!         $acc = $acc + $n
//!         $n = $n - 1
//!     }
//!
//!     $acc
//! }
//!
//! main = sum_worker(4)
//! ```
//!
//! That is faster for plain, practical reasons:
//!
//! - each loop iteration carries two `I64`s directly;
//! - the loop uses `n` and `acc` directly instead of reading record fields;
//! - later compiler stages have simple values to keep in registers.
//!
//! This is Roc's version of the optimization described in
//! "Call-pattern Specialisation for Haskell Programs" by Simon Peyton Jones:
//!
//! https://www.microsoft.com/en-us/research/wp-content/uploads/2016/07/spec-constr.pdf
//!
//! The important Roc case is collection from `Iter` and `Stream`. Source code is
//! compact:
//!
//! ```roc
//! Plant : { seed : I64 }
//!
//! random_plant! : I64 => Plant
//! random_plant! = |seed| { seed }
//!
//! starting_plants! : () => List(Plant)
//! starting_plants! = || {
//!     (0.I64..=15)
//!         .stream()
//!         .map(|i| random_plant!(i * 12))
//!         .collect!()
//! }
//! ```
//!
//! After wrapper inlining exposes the `Stream` operations, the lifted program has
//! the same known_value as this Roc code. The range is wrapped in a stream record; map
//! wraps that stream in another stream record; collect loops over that mapped
//! stream by calling the carried step thunk:
//!
//! ```roc
//! starting_plants! = || {
//!     range_iter = 0.I64..=15
//!
//!     source_stream = {
//!         len_if_known: Known(16),
//!         step!: ||
//!             match Iter.next(range_iter) {
//!                 Done => Done
//!                 Skip({ rest }) =>
//!                     Skip({ rest: Stream.from_iter(rest) })
//!                 One({ item, rest }) =>
//!                     One({ item, rest: Stream.from_iter(rest) })
//!             },
//!     }
//!
//!     mapped_stream = {
//!         len_if_known: source_stream.len_if_known,
//!         step!: ||
//!             match source_stream.step!() {
//!                 Done => Done
//!                 Skip({ rest }) =>
//!                     Skip({ rest: Stream.map(rest, |i| random_plant!(i * 12)) })
//!                 One({ item, rest }) =>
//!                     One({
//!                         item: random_plant!(item * 12),
//!                         rest: Stream.map(rest, |i| random_plant!(i * 12)),
//!                     })
//!             },
//!     }
//!
//!     cap = match mapped_stream.len_if_known {
//!         Known(n) => n
//!         Unknown => 0
//!     }
//!
//!     var $list = List.with_capacity(cap)
//!     var $rest = mapped_stream
//!
//!     while Bool.True {
//!         match $rest.step!() {
//!             Done => break
//!             Skip({ rest }) => {
//!                 $rest = rest
//!             }
//!             One({ item, rest }) => {
//!                 $list = list_append_unsafe($list, item)
//!                 $rest = rest
//!             }
//!         }
//!     }
//!
//!     $list
//! }
//! ```
//!
//! In that inlined form, the loop state `$rest` has a known constructor known_value:
//! it is a `Stream` record whose `step!` field is the lifted function created by
//! `Stream.map`, with captures for the source step thunk and the mapping
//! function. Each `One` or `Skip` branch constructs the same mapped stream known_value
//! for the next iteration. Without this pass, the compiler lowers that as a loop
//! over a single stream value, repacking stream fields and rebuilding the step
//! closure before immediately reading them again.
//!
//! This pass specializes the collect worker for the known stream known_value. Written
//! in pure Roc terms, the optimized known_value is:
//!
//! ```roc
//! starting_plants! = || {
//!     var $list = List.with_capacity(16)
//!     var $current = 0.I64
//!     var $last = 15.I64
//!
//!     while Bool.True {
//!         if $current > $last {
//!             break
//!         }
//!
//!         item = random_plant!($current * 12)
//!         $list = list_append_unsafe($list, item)
//!         $current = $current + 1
//!     }
//!
//!     $list
//! }
//! ```
//!
//! The real lifted IR is more explicit than that source sketch: lambdas have
//! function ids, captures are separate locals, and branches still have explicit
//! tags until later lowering. The essential change is that the reachable collect
//! worker no longer receives one `Stream(Plant)` argument. It receives the
//! stream's known fields and callable captures directly, and recursive loop
//! updates pass those fields forward instead of re-forming a stream value.
//!
//! The implementation has four parts:
//!
//! 1. Scan original lifted functions and mark argument positions read by
//!    `match`, field access, or tuple access. Direct calls propagate those marks
//!    to the caller's corresponding arguments.
//! 2. Rewrite each original Roc body with the same value-environment clone used
//!    for workers, while preserving that original function's ABI. This base-body
//!    rewrite can specialize local loop state even when the function was called
//!    with only primitive arguments.
//! 3. While cloning a base body or worker, record direct-call patterns as soon as
//!    known-value arguments reach a callee that reads them. Recording a pattern
//!    immediately reserves a worker id and pushes a worker job.
//! 4. Drain the worker worklist by cloning each source body into the reserved
//!    worker. Known constructor arguments are split into leaves; ordinary
//!    arguments stay as normal worker arguments. Calls matching a recorded
//!    pattern are redirected during the containing clone, so there is no later
//!    cleanup walk over already-written bodies.
//!
//! Cloning with a value environment is where the simplifications happen: known
//! records simplify field reads, known tuples simplify tuple reads, known tags
//! simplify matches, known callable values inline direct calls, and loop state is
//! split when every `continue` value can provide the same leaves.
//!
//! Callable identity is part of a call pattern. A lifted callable matches only
//! the same function id, or a specialized clone whose stored source function
//! template is the same. That keeps dispatch static while allowing this pass's
//! own callable workers to match the patterns that created them.

const std = @import("std");

const SourceLoc = @import("base").SourceLoc;
const Region = @import("base").Region;
const Common = @import("../common.zig");
const Ast = @import("ast.zig");
const can = @import("can");
const Mono = @import("../monotype/ast.zig");
const Type = @import("../monotype/type.zig");
const Solved = @import("../lambda_solved/ast.zig");
const SolvedType = @import("../lambda_solved/type.zig");
const check = @import("check");
const names = check.CheckedNames;

const Allocator = std.mem.Allocator;

/// Specialize recursive direct calls whose arguments are known constructor known_values.
pub fn run(allocator: Allocator, program: *Ast.Program) Common.LowerError!void {
    var pass = try Pass.init(allocator, program, null);
    defer pass.deinit();
    try pass.run();
}

/// Specialize with Lambda Solved type data available for checked-call known_values.
pub fn runWithSolved(allocator: Allocator, solved: *Solved.Program) Common.LowerError!void {
    var pass = try Pass.init(allocator, &solved.lifted, solved);
    defer pass.deinit();
    try pass.run();
}

const KnownValue = union(enum) {
    any: Type.TypeId,
    leaf: Type.TypeId,
    tag: KnownTag,
    record: KnownRecord,
    tuple: KnownTuple,
    nominal: KnownNominal,
    callable: KnownCallable,
    finite_tags: KnownTags,
    finite_callables: KnownCallables,
};

const KnownTag = struct {
    ty: Type.TypeId,
    name: names.TagNameId,
    payloads: []const KnownValue,
};

const KnownField = struct {
    name: names.RecordFieldNameId,
    known_value: KnownValue,
};

const KnownRecord = struct {
    ty: Type.TypeId,
    fields: []const KnownField,
};

const KnownTuple = struct {
    ty: Type.TypeId,
    items: []const KnownValue,
};

const KnownNominal = struct {
    ty: Type.TypeId,
    backing: *const KnownValue,
};

const KnownCallable = struct {
    ty: Type.TypeId,
    fn_id: Ast.FnId,
    captures: []const KnownValue,
};

const KnownTags = struct {
    ty: Type.TypeId,
    alternatives: []const KnownTag,
};

const KnownCallables = struct {
    ty: Type.TypeId,
    alternatives: []const KnownCallable,
};

const DemandedKnownValue = union(enum) {
    any: Type.TypeId,
    leaf: Type.TypeId,
    tag: DemandedKnownTag,
    record: DemandedKnownRecord,
    tuple: DemandedKnownTuple,
    nominal: DemandedKnownNominal,
    callable: DemandedKnownCallable,
    finite_tags: DemandedKnownTags,
    finite_callables: DemandedKnownCallables,
};

const DemandedKnownTag = struct {
    ty: Type.TypeId,
    name: names.TagNameId,
    payloads: []const DemandedKnownIndexedValue,
};

const DemandedKnownField = struct {
    name: names.RecordFieldNameId,
    known_value: DemandedKnownValue,
};

const DemandedKnownRecord = struct {
    ty: Type.TypeId,
    fields: []const DemandedKnownField,
};

const DemandedKnownTuple = struct {
    ty: Type.TypeId,
    items: []const DemandedKnownIndexedValue,
};

const DemandedKnownNominal = struct {
    ty: Type.TypeId,
    backing: ?*const DemandedKnownValue,
};

const DemandedKnownCallable = struct {
    ty: Type.TypeId,
    fn_id: Ast.FnId,
    captures: []const DemandedKnownIndexedValue,
};

const DemandedKnownTags = struct {
    ty: Type.TypeId,
    alternatives: []const DemandedKnownTag,
};

const DemandedKnownCallables = struct {
    ty: Type.TypeId,
    alternatives: []const DemandedKnownCallable,
};

const DemandedKnownIndexedValue = struct {
    index: u32,
    known_value: DemandedKnownValue,
};

const PrivateStateValue = union(enum) {
    leaf: PrivateStateLeaf,
    tag: PrivateStateTag,
    record: PrivateStateRecord,
    tuple: PrivateStateTuple,
    nominal: PrivateStateNominal,
    callable: PrivateStateCallable,
    finite_tags: PrivateStateFiniteTags,
    finite_callables: PrivateStateFiniteCallables,
};

const PrivateStateLeaf = struct {
    ty: Type.TypeId,
    expr: Ast.ExprId,
};

const PrivateStateTag = struct {
    ty: Type.TypeId,
    name: names.TagNameId,
    payloads: []const PrivateStateIndexedValue,
};

const PrivateStateField = struct {
    name: names.RecordFieldNameId,
    value: PrivateStateValue,
};

const PrivateStateRecord = struct {
    ty: Type.TypeId,
    fields: []const PrivateStateField,
};

const PrivateStateTuple = struct {
    ty: Type.TypeId,
    items: []const PrivateStateIndexedValue,
};

const PrivateStateNominal = struct {
    ty: Type.TypeId,
    backing: ?*const PrivateStateValue,
};

const PrivateStateCallable = struct {
    ty: Type.TypeId,
    fn_id: Ast.FnId,
    captures: []const PrivateStateIndexedValue,
};

const PrivateStateFiniteTags = struct {
    ty: Type.TypeId,
    selector: Ast.ExprId,
    alternatives: []const PrivateStateTag,
};

const PrivateStateFiniteCallables = struct {
    ty: Type.TypeId,
    selector: Ast.ExprId,
    alternatives: []const PrivateStateCallable,
};

const PrivateStateIndexedValue = struct {
    index: u32,
    value: PrivateStateValue,
};

const KnownMatchMode = enum {
    strict,
    speculative,
};

const Value = union(enum) {
    expr: Ast.ExprId,
    expr_with_known_value: ExprWithKnownValue,
    let_: LetValue,
    if_: IfValue,
    match_: MatchValue,
    tag: TagValue,
    record: RecordValue,
    tuple: TupleValue,
    nominal: NominalValue,
    callable: CallableValue,
    finite_tags: FiniteTagsValue,
    finite_callables: FiniteCallablesValue,
    private_state: PrivateStateValue,
};

const ExprWithKnownValue = struct {
    expr: Ast.ExprId,
    known_value: KnownValue,
    value: ?*const Value = null,
};

const LetValue = struct {
    lets: []const PendingLet,
    body: *const Value,
};

const IfValueBranch = struct {
    cond: Ast.ExprId,
    body: Value,
};

const IfValue = struct {
    ty: Type.TypeId,
    branches: []const IfValueBranch,
    final_else: *const Value,
};

const MatchValueBranch = struct {
    pat: Ast.PatId,
    guard: ?Ast.ExprId,
    body: Value,
    source: ?MatchValueBranchSource = null,
};

const MatchValueBranchSource = struct {
    scrutinee: Ast.ExprId,
    pat: Ast.PatId,
    guard: ?Ast.ExprId,
    body: Ast.ExprId,
    scrutinee_known_value: ?KnownValue,
    scrutinee_value: ?*const Value,
    bindings: []const SavedBinding,
    read: MatchValueBranchSourceRead = .none,
};

const MatchValueBranchSourceRead = union(enum) {
    none,
    callable_capture: MatchValueCallableCaptureRead,
};

const MatchValueCallableCaptureRead = struct {
    callable: DemandedKnownCallable,
    capture_index: u32,
};

const MatchValue = struct {
    ty: Type.TypeId,
    scrutinee: Ast.ExprId,
    branches: []const MatchValueBranch,
    comptime_site: ?Ast.ComptimeSiteId,
};

const TagValue = struct {
    ty: Type.TypeId,
    name: names.TagNameId,
    payloads: []const Value,
};

const FieldValue = struct {
    name: names.RecordFieldNameId,
    value: Value,
};

const RecordValue = struct {
    ty: Type.TypeId,
    fields: []const FieldValue,
};

const TupleValue = struct {
    ty: Type.TypeId,
    items: []const Value,
};

const NominalValue = struct {
    ty: Type.TypeId,
    backing: *const Value,
};

const CallableValue = struct {
    ty: Type.TypeId,
    fn_id: Ast.FnId,
    captures: []const Value,
};

const FiniteTagsValue = struct {
    ty: Type.TypeId,
    selector: Ast.ExprId,
    alternatives: []const TagValue,
};

const FiniteCallablesValue = struct {
    ty: Type.TypeId,
    selector: Ast.ExprId,
    alternatives: []const CallableValue,
};

const CallPattern = struct {
    args: []const KnownValue,
};

const ValueDemand = union(enum) {
    none,
    materialize,
    loop_param: usize,
    record: []const FieldDemand,
    tuple: []const ItemDemand,
    tag: TagDemand,
    nominal: *const ValueDemand,
    callable: CallableDemand,
};

const FieldDemand = struct {
    name: names.RecordFieldNameId,
    demand: *const ValueDemand,
};

const ItemDemand = struct {
    index: u32,
    demand: *const ValueDemand,
};

const TagDemand = struct {
    payloads: []const ItemDemand,
};

const CallableDemand = struct {
    captures: []const ValueDemand,
    result: ?*const ValueDemand = null,
};

const Spec = struct {
    pattern: CallPattern,
    fn_id: ?Ast.FnId = null,
    written: bool = false,
};

const FnPlan = struct {
    used_args: []bool,
    arg_demands: []ValueDemand,
    used_captures: []bool,
    capture_demands: []ValueDemand,
    specs: std.ArrayList(Spec),

    fn deinit(self: *FnPlan, allocator: Allocator) void {
        allocator.free(self.capture_demands);
        allocator.free(self.used_captures);
        allocator.free(self.arg_demands);
        allocator.free(self.used_args);
        self.specs.deinit(allocator);
    }
};

const WorkerJob = struct {
    source_fn: Ast.FnId,
    spec_index: usize,
};

const CallableSpecialization = struct {
    source_fn: Ast.FnId,
    captures: []const ?DemandedKnownValue,
    fn_id: Ast.FnId,
};

const BindingTarget = union(enum) {
    local: Ast.LocalId,
};

const BindingChange = struct {
    key: BindingTarget,
    previous: ?Value,
};

const SavedBinding = struct {
    local: Ast.LocalId,
    value: Value,
};

const PendingLetValue = union(enum) {
    source: Ast.ExprId,
    cloned: Ast.ExprId,
};

const PendingLet = struct {
    local: Ast.LocalId,
    ty: Type.TypeId,
    value: PendingLetValue,
    known_value: ?KnownValue = null,
    structured_value: ?*const Value = null,
};

const BlockTail = struct {
    statements: []const Ast.StmtId,
    final_expr: Ast.ExprId,
};

const LoopPattern = struct {
    params: []const Ast.TypedLocal,
    values: []const KnownValue,
    source_values: ?[]const Value = null,
    refinements: []?KnownValue,
    demands: []ValueDemand,
    result_demand: ValueDemand,
    provenance: *std.ArrayList(LoopLocalProvenance),
};

const LoopLocalProvenance = struct {
    local: Ast.LocalId,
    source_local: Ast.LocalId,
    path: []const DemandPathStep,
};

const DemandPathStep = union(enum) {
    record_field: names.RecordFieldNameId,
    tuple_item: u32,
    tag_payload: u32,
    nominal_backing,
    callable_capture: u32,
};

const SparseStateLoopPattern = struct {
    states: *std.ArrayList(SparseStateLoopState),
    demands: []const ValueDemand,
    result_demand: ValueDemand,
    compact_result: ?CompactLoopResult,
};

const SparseStateLoopState = struct {
    id: Ast.StateLoopStateId,
    values: []const DemandedKnownValue,
};

const CompactLoopResult = struct {
    known_value: DemandedKnownValue,
    ty: Type.TypeId,
    leaf_tys: []const Type.TypeId,
};

const ActiveInline = struct {
    fn_id: Ast.FnId,
    args: ?[]const KnownValue = null,
};

const ActiveDemand = struct {
    fn_id: Ast.FnId,
    result: ?ValueDemand = null,
    captures: ?[]ValueDemand = null,
};

const LocalDemandFrame = struct {
    local: Ast.LocalId,
    expr: Ast.ExprId,
    context: ValueDemand,
};

const Pass = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    program: *Ast.Program,
    solved: ?*const Solved.Program,
    plans: []FnPlan,
    original_bodies: []const ?Ast.ExprId,
    worker_worklist: std.ArrayList(WorkerJob),
    callable_specializations: std.ArrayList(CallableSpecialization),
    symbols: Common.SymbolGen,

    fn init(allocator: Allocator, program: *Ast.Program, solved: ?*const Solved.Program) Allocator.Error!Pass {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const plans = try allocator.alloc(FnPlan, program.fns.items.len);
        errdefer allocator.free(plans);

        for (plans, 0..) |*plan, index| {
            const fn_ = program.fns.items[index];
            const args = program.typedLocalSpan(fn_.args);
            const used_args = try allocator.alloc(bool, args.len);
            errdefer allocator.free(used_args);
            @memset(used_args, false);
            const arg_demands = try allocator.alloc(ValueDemand, args.len);
            errdefer allocator.free(arg_demands);
            @memset(arg_demands, .none);

            const captures = program.typedLocalSpan(fn_.captures);
            const used_captures = try allocator.alloc(bool, captures.len);
            errdefer allocator.free(used_captures);
            @memset(used_captures, false);
            const capture_demands = try allocator.alloc(ValueDemand, captures.len);
            errdefer allocator.free(capture_demands);
            @memset(capture_demands, .none);

            plan.* = .{
                .used_args = used_args,
                .arg_demands = arg_demands,
                .used_captures = used_captures,
                .capture_demands = capture_demands,
                .specs = .empty,
            };
        }

        return .{
            .allocator = allocator,
            .arena = arena,
            .program = program,
            .solved = solved,
            .plans = plans,
            .original_bodies = &.{},
            .worker_worklist = .empty,
            .callable_specializations = .empty,
            .symbols = .{ .next = program.next_symbol },
        };
    }

    fn deinit(self: *Pass) void {
        self.callable_specializations.deinit(self.allocator);
        self.worker_worklist.deinit(self.allocator);
        for (self.plans) |*plan| plan.deinit(self.allocator);
        self.allocator.free(self.plans);
        self.arena.deinit();
    }

    fn solvedSingleCallableMember(self: *const Pass, expr_id: Ast.ExprId) ?SolvedType.FnMember {
        const solved = self.solved orelse return null;
        const raw = @intFromEnum(expr_id);
        if (raw >= solved.expr_tys.items.len) return null;
        return self.solvedSingleCallableMemberFromType(solved.expr_tys.items[raw]);
    }

    fn solvedSingleCallableMemberFromType(self: *const Pass, ty: SolvedType.TypeVarId) ?SolvedType.FnMember {
        const solved = self.solved orelse return null;
        const callable_ty = switch (solved.types.rootContent(ty)) {
            .func => |func| func.callable,
            .lambda_set => ty,
            else => return null,
        };
        const members = switch (solved.types.rootContent(callable_ty)) {
            .lambda_set => |members| members,
            else => return null,
        };
        const member_items = solved.types.memberSpan(members);
        if (member_items.len == 0) return null;
        if (member_items.len != 1 and !self.solvedCallableMembersAreEquivalent(member_items)) return null;
        return member_items[0];
    }

    fn solvedCallableMembersAreEquivalent(self: *const Pass, members: []const SolvedType.FnMember) bool {
        if (members.len <= 1) return true;

        const first_fn_id = self.fnWithSymbol(members[0].lambda) orelse return false;
        const solved = self.solved orelse return false;
        const first_captures = solved.types.captureSpan(members[0].captures);

        for (members[1..]) |member| {
            const fn_id = self.fnWithSymbol(member.lambda) orelse return false;
            if (!callableTargetMatches(self.program, first_fn_id, fn_id)) return false;

            const captures = solved.types.captureSpan(member.captures);
            if (captures.len != first_captures.len) return false;
            for (first_captures, captures) |first_capture, capture| {
                if (first_capture.local != capture.local) return false;
            }
        }

        return true;
    }

    fn fnWithSymbol(self: *const Pass, symbol: Common.Symbol) ?Ast.FnId {
        for (self.program.fns.items, 0..) |fn_, index| {
            if (fn_.symbol == symbol) return @enumFromInt(@as(u32, @intCast(index)));
        }
        return null;
    }

    fn primitiveType(self: *Pass, primitive: Type.Primitive) Allocator.Error!Type.TypeId {
        return try self.program.types.add(.{ .primitive = primitive });
    }

    fn run(self: *Pass) Common.LowerError!void {
        const original_fn_count = self.plans.len;
        const original_bodies = try self.captureOriginalBodies(original_fn_count);
        defer self.allocator.free(original_bodies);
        self.original_bodies = original_bodies;

        try self.collectArgUses(original_fn_count);
        try self.rewriteBaseBodies(original_bodies);
        try self.createSpecializations(original_bodies);

        self.original_bodies = &.{};
        self.program.next_symbol = self.symbols.next;
    }

    fn originalBody(self: *const Pass, fn_id: Ast.FnId) ?Ast.ExprId {
        const index = @intFromEnum(fn_id);
        if (index >= self.original_bodies.len) return null;
        return self.original_bodies[index];
    }

    fn copyProcDebugName(self: *Pass, source_symbol: Common.Symbol, target_symbol: Common.Symbol) Allocator.Error!void {
        if (self.program.procDebugName(source_symbol)) |name| {
            try self.program.setProcDebugName(target_symbol, name);
        }
    }

    fn captureOriginalBodies(self: *Pass, original_fn_count: usize) Allocator.Error![]?Ast.ExprId {
        const original_bodies = try self.allocator.alloc(?Ast.ExprId, original_fn_count);
        for (self.program.fns.items[0..original_fn_count], original_bodies) |fn_, *body_slot| {
            body_slot.* = switch (fn_.body) {
                .roc => |body| body,
                .hosted => null,
            };
        }
        return original_bodies;
    }

    fn collectArgUses(self: *Pass, original_fn_count: usize) Allocator.Error!void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.program.fns.items[0..original_fn_count], 0..) |fn_, index| {
                const body = switch (fn_.body) {
                    .roc => |body| body,
                    .hosted => continue,
                };
                const fn_id: Ast.FnId = @enumFromInt(@as(u32, @intCast(index)));
                try self.markArgUsesInExpr(fn_id, body, &changed);
            }
        }
    }

    fn rewriteBaseBodies(self: *Pass, original_bodies: []const ?Ast.ExprId) Common.LowerError!void {
        for (original_bodies, 0..) |maybe_body, index| {
            const body_expr = maybe_body orelse continue;
            const fn_id: Ast.FnId = @enumFromInt(@as(u32, @intCast(index)));

            var cloner = Cloner.initForBaseBody(self, fn_id);
            defer cloner.deinit();

            try cloner.inline_stack.append(self.allocator, .{ .fn_id = fn_id });
            defer {
                const popped = cloner.inline_stack.pop() orelse Common.invariant("base body inline stack underflow");
                if (popped.fn_id != fn_id) Common.invariant("base body inline stack was corrupted");
            }

            const cloned_body = try cloner.cloneExpr(body_expr);
            self.program.fns.items[index].body = .{ .roc = cloned_body };
        }
    }

    fn createSpecializations(self: *Pass, original_bodies: []const ?Ast.ExprId) Common.LowerError!void {
        while (self.worker_worklist.pop()) |job| {
            const source_index = @intFromEnum(job.source_fn);
            const source_body = original_bodies[source_index] orelse
                Common.invariant("hosted function had a call-pattern specialization");
            if (self.plans[source_index].specs.items[job.spec_index].written) continue;

            self.plans[source_index].specs.items[job.spec_index].written = true;
            try self.writeSpecialization(job.source_fn, job.spec_index, source_body);
        }
    }

    fn markArgUsesInExpr(self: *Pass, fn_id: Ast.FnId, expr_id: Ast.ExprId, changed: *bool) Allocator.Error!void {
        const expr = self.program.exprs.items[@intFromEnum(expr_id)];
        switch (expr.data) {
            .local => try self.markArgUseIfLocal(fn_id, expr_id, changed),
            .unit,
            .int_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .dec_lit,
            .str_lit,
            .static_data,
            .crash,
            .comptime_exhaustiveness_failed,
            .uninitialized,
            .uninitialized_payload,
            => {},
            .fn_ref => |target| {
                const target_fn = self.program.fns.items[@intFromEnum(target)];
                const target_captures = self.program.typedLocalSpan(target_fn.captures);
                const target_raw = @intFromEnum(target);
                const target_plan = if (target_raw < self.plans.len and target_fn.body == .roc)
                    self.plans[target_raw]
                else
                    null;
                for (target_captures, 0..) |capture, index| {
                    const capture_demand = if (target_plan) |plan|
                        if (index < plan.used_captures.len and plan.used_captures[index])
                            plan.capture_demands[index]
                        else
                            .none
                    else
                        .materialize;
                    try self.markArgDemandForLocal(fn_id, capture.local, capture_demand, changed);
                }
            },
            .static_data_candidate => |candidate| try self.markArgUsesInExpr(fn_id, candidate.fallback, changed),
            .list,
            .tuple,
            => |items| for (self.program.exprSpan(items)) |child| try self.markArgUsesInExpr(fn_id, child, changed),
            .record => |fields| for (self.program.fieldExprSpan(fields)) |field| try self.markArgUsesInExpr(fn_id, field.value, changed),
            .tag => |tag| for (self.program.exprSpan(tag.payloads)) |payload| try self.markArgUsesInExpr(fn_id, payload, changed),
            .nominal,
            .return_,
            .dbg,
            .expect,
            => |child| try self.markArgUsesInExpr(fn_id, child, changed),
            .expect_err => |expect_err| try self.markArgUsesInExpr(fn_id, expect_err.msg, changed),
            .comptime_branch_taken => |taken| try self.markArgUsesInExpr(fn_id, taken.body, changed),
            .let_ => |let_| {
                try self.markArgUsesInExpr(fn_id, let_.value, changed);
                try self.markArgUsesInExpr(fn_id, let_.rest, changed);
            },
            .lambda,
            .def_ref,
            .fn_def,
            => Common.invariant("pre-lift function expression reached call-pattern specialization"),
            .call_value => |call| {
                try self.markArgDemandInExpr(fn_id, call.callee, .{ .callable = .{
                    .captures = &.{},
                    .result = try self.storedDemand(.materialize),
                } }, changed);
                for (self.program.exprSpan(call.args)) |arg| try self.markArgUsesInExpr(fn_id, arg, changed);
            },
            .call_proc => |call| {
                const args = self.program.exprSpan(call.args);
                for (args) |arg| try self.markArgUsesInExpr(fn_id, arg, changed);
                const callee = Ast.callProcCallee(call);
                const callee_raw = @intFromEnum(callee);
                if (callee_raw < self.plans.len) {
                    const callee_uses = self.plans[callee_raw].used_args;
                    if (args.len != callee_uses.len) Common.invariant("direct call arity differed from lifted function arity while propagating argument uses");
                    const callee_demands = self.plans[callee_raw].arg_demands;
                    for (args, callee_uses, callee_demands) |arg, callee_uses_arg, callee_demand| {
                        if (callee_uses_arg) try self.markArgDemandIfLocal(fn_id, arg, callee_demand, changed);
                    }
                }
            },
            .low_level => |call| {
                for (self.program.exprSpan(call.args)) |arg| try self.markArgUsesInExpr(fn_id, arg, changed);
            },
            .field_access => |field| {
                try self.markArgDemandInExpr(
                    fn_id,
                    field.receiver,
                    try self.demandRecordField(field.field, .materialize),
                    changed,
                );
            },
            .tuple_access => |access| {
                try self.markArgDemandInExpr(
                    fn_id,
                    access.tuple,
                    try self.demandTupleItem(access.elem_index, .materialize),
                    changed,
                );
            },
            .structural_eq => |eq| {
                try self.markArgUsesInExpr(fn_id, eq.lhs, changed);
                try self.markArgUsesInExpr(fn_id, eq.rhs, changed);
            },
            .structural_hash => |h| {
                try self.markArgUsesInExpr(fn_id, h.value, changed);
                try self.markArgUsesInExpr(fn_id, h.hasher, changed);
            },
            .match_ => |match| {
                try self.markArgUseIfLocal(fn_id, match.scrutinee, changed);
                try self.markArgUsesInExpr(fn_id, match.scrutinee, changed);
                for (self.program.branchSpan(match.branches)) |branch| {
                    if (branch.guard) |guard| try self.markArgUsesInExpr(fn_id, guard, changed);
                    try self.markArgUsesInExpr(fn_id, branch.body, changed);
                }
            },
            .if_ => |if_| {
                for (self.program.ifBranchSpan(if_.branches)) |branch| {
                    try self.markArgUsesInExpr(fn_id, branch.cond, changed);
                    try self.markArgUsesInExpr(fn_id, branch.body, changed);
                }
                try self.markArgUsesInExpr(fn_id, if_.final_else, changed);
            },
            .block => |block| {
                for (self.program.stmtSpan(block.statements)) |stmt| try self.markArgUsesInStmt(fn_id, stmt, changed);
                try self.markArgUsesInExpr(fn_id, block.final_expr, changed);
            },
            .loop_ => |loop| {
                for (self.program.exprSpan(loop.initial_values)) |initial| try self.markArgUsesInExpr(fn_id, initial, changed);
                try self.markArgUsesInExpr(fn_id, loop.body, changed);
            },
            .state_loop => |state_loop| {
                for (self.program.exprSpan(state_loop.entry_values)) |initial| try self.markArgUsesInExpr(fn_id, initial, changed);
                for (self.program.stateLoopStateSpan(state_loop.states)) |state| {
                    try self.markArgUsesInExpr(fn_id, state.body, changed);
                }
            },
            .break_ => |maybe| if (maybe) |value| try self.markArgUsesInExpr(fn_id, value, changed),
            .continue_ => |continue_| for (self.program.exprSpan(continue_.values)) |value| try self.markArgUsesInExpr(fn_id, value, changed),
            .state_continue => |continue_| for (self.program.exprSpan(continue_.values)) |value| try self.markArgUsesInExpr(fn_id, value, changed),
            .if_initialized_payload => |payload_switch| {
                try self.markArgUsesInExpr(fn_id, payload_switch.cond, changed);
                try self.markArgUsesInExpr(fn_id, payload_switch.initialized, changed);
                try self.markArgUsesInExpr(fn_id, payload_switch.uninitialized, changed);
            },
            .try_sequence => |sequence| {
                try self.markArgUsesInExpr(fn_id, sequence.try_expr, changed);
                try self.markArgUsesInExpr(fn_id, sequence.ok_body, changed);
            },
            .try_record_sequence => |sequence| {
                try self.markArgUsesInExpr(fn_id, sequence.try_expr, changed);
                try self.markArgUsesInExpr(fn_id, sequence.ok_body, changed);
            },
        }
    }

    fn markArgUsesInStmt(self: *Pass, fn_id: Ast.FnId, stmt_id: Ast.StmtId, changed: *bool) Allocator.Error!void {
        switch (self.program.stmts.items[@intFromEnum(stmt_id)]) {
            .let_ => |let_| try self.markArgUsesInExpr(fn_id, let_.value, changed),
            .expr,
            .expect,
            .dbg,
            .return_,
            => |expr| try self.markArgUsesInExpr(fn_id, expr, changed),
            .uninitialized, .crash => {},
        }
    }

    fn markArgUseIfLocal(self: *Pass, fn_id: Ast.FnId, expr_id: Ast.ExprId, changed: *bool) Allocator.Error!void {
        try self.markArgDemandIfLocal(fn_id, expr_id, .materialize, changed);
    }

    fn markArgDemandInExpr(
        self: *Pass,
        fn_id: Ast.FnId,
        expr_id: Ast.ExprId,
        demand: ValueDemand,
        changed: *bool,
    ) Allocator.Error!void {
        if (demand == .none) return;
        const expr = self.program.exprs.items[@intFromEnum(expr_id)];
        switch (expr.data) {
            .local => try self.markArgDemandIfLocal(fn_id, expr_id, demand, changed),
            .field_access => |field| try self.markArgDemandInExpr(
                fn_id,
                field.receiver,
                try self.demandRecordField(field.field, demand),
                changed,
            ),
            .tuple_access => |access| try self.markArgDemandInExpr(
                fn_id,
                access.tuple,
                try self.demandTupleItem(access.elem_index, demand),
                changed,
            ),
            .comptime_branch_taken => |taken| try self.markArgDemandInExpr(fn_id, taken.body, demand, changed),
            else => try self.markArgUsesInExpr(fn_id, expr_id, changed),
        }
    }

    fn markArgDemandIfLocal(
        self: *Pass,
        fn_id: Ast.FnId,
        expr_id: Ast.ExprId,
        demand: ValueDemand,
        changed: *bool,
    ) Allocator.Error!void {
        if (demand == .none) return;
        const local = localExpr(self.program, expr_id) orelse return;
        try self.markArgDemandForLocal(fn_id, local, demand, changed);
    }

    fn markArgDemandForLocal(
        self: *Pass,
        fn_id: Ast.FnId,
        local: Ast.LocalId,
        demand: ValueDemand,
        changed: *bool,
    ) Allocator.Error!void {
        if (demand == .none) return;
        const args = self.program.typedLocalSpan(self.program.fns.items[@intFromEnum(fn_id)].args);
        for (args, 0..) |arg, index| {
            if (arg.local == local) {
                const used = &self.plans[@intFromEnum(fn_id)].used_args[index];
                if (!used.*) {
                    used.* = true;
                    changed.* = true;
                }
                const merged = try self.mergeValueDemand(self.plans[@intFromEnum(fn_id)].arg_demands[index], demand);
                if (!valueDemandEql(self.plans[@intFromEnum(fn_id)].arg_demands[index], merged)) {
                    self.plans[@intFromEnum(fn_id)].arg_demands[index] = merged;
                    changed.* = true;
                }
                return;
            }
        }

        const captures = self.program.typedLocalSpan(self.program.fns.items[@intFromEnum(fn_id)].captures);
        for (captures, 0..) |capture, index| {
            if (capture.local == local) {
                const used = &self.plans[@intFromEnum(fn_id)].used_captures[index];
                if (!used.*) {
                    used.* = true;
                    changed.* = true;
                }
                const merged = try self.mergeValueDemand(self.plans[@intFromEnum(fn_id)].capture_demands[index], demand);
                if (!valueDemandEql(self.plans[@intFromEnum(fn_id)].capture_demands[index], merged)) {
                    self.plans[@intFromEnum(fn_id)].capture_demands[index] = merged;
                    changed.* = true;
                }
                return;
            }
        }
    }

    fn storedDemand(self: *Pass, demand: ValueDemand) Allocator.Error!*const ValueDemand {
        const stored = try self.arena.allocator().create(ValueDemand);
        stored.* = demand;
        return stored;
    }

    fn demandRecordField(self: *Pass, field: names.RecordFieldNameId, demand: ValueDemand) Allocator.Error!ValueDemand {
        const fields = try self.arena.allocator().alloc(FieldDemand, 1);
        fields[0] = .{
            .name = field,
            .demand = try self.storedDemand(demand),
        };
        return .{ .record = fields };
    }

    fn demandTupleItem(self: *Pass, index: u32, demand: ValueDemand) Allocator.Error!ValueDemand {
        const items = try self.arena.allocator().alloc(ItemDemand, 1);
        items[0] = .{
            .index = index,
            .demand = try self.storedDemand(demand),
        };
        return .{ .tuple = items };
    }

    fn mergeValueDemand(self: *Pass, existing: ValueDemand, incoming: ValueDemand) Allocator.Error!ValueDemand {
        if (existing == .materialize or incoming == .materialize) return .materialize;
        if (existing == .none) return incoming;
        if (incoming == .none) return existing;
        if (std.meta.activeTag(existing) != std.meta.activeTag(incoming)) return .materialize;

        return switch (existing) {
            .none, .materialize => unreachable,
            .loop_param => |existing_index| if (existing_index == incoming.loop_param) existing else .materialize,
            .record => try self.mergeRecordDemand(existing.record, incoming.record),
            .tuple => try self.mergeTupleDemand(existing.tuple, incoming.tuple),
            .tag => blk: {
                const payloads = try self.mergeTupleDemand(existing.tag.payloads, incoming.tag.payloads);
                break :blk ValueDemand{ .tag = .{ .payloads = payloads.tuple } };
            },
            .nominal => blk: {
                const merged = try self.mergeValueDemand(existing.nominal.*, incoming.nominal.*);
                break :blk ValueDemand{ .nominal = try self.storedDemand(merged) };
            },
            .callable => |existing_callable| blk: {
                const incoming_callable = incoming.callable;
                const captures_len = @max(existing_callable.captures.len, incoming_callable.captures.len);
                const captures = try self.arena.allocator().alloc(ValueDemand, captures_len);
                for (captures, 0..) |*out, index| {
                    const existing_capture = if (index < existing_callable.captures.len) existing_callable.captures[index] else .none;
                    const incoming_capture = if (index < incoming_callable.captures.len) incoming_callable.captures[index] else .none;
                    out.* = try self.mergeValueDemand(existing_capture, incoming_capture);
                }
                const result = if (existing_callable.result) |existing_result| result: {
                    if (incoming_callable.result) |incoming_result| {
                        const merged = try self.mergeValueDemand(existing_result.*, incoming_result.*);
                        break :result try self.storedDemand(merged);
                    }
                    break :result existing_result;
                } else incoming_callable.result;
                break :blk ValueDemand{ .callable = .{ .captures = captures, .result = result } };
            },
        };
    }

    fn mergeRecordDemand(
        self: *Pass,
        existing: []const FieldDemand,
        incoming: []const FieldDemand,
    ) Allocator.Error!ValueDemand {
        var fields = std.ArrayList(FieldDemand).empty;
        defer fields.deinit(self.allocator);
        try fields.appendSlice(self.allocator, existing);

        for (incoming) |incoming_field| {
            for (fields.items) |*field| {
                if (field.name != incoming_field.name) continue;
                const merged = try self.mergeValueDemand(field.demand.*, incoming_field.demand.*);
                field.demand = try self.storedDemand(merged);
                break;
            } else {
                try fields.append(self.allocator, incoming_field);
            }
        }

        return .{ .record = try self.arena.allocator().dupe(FieldDemand, fields.items) };
    }

    fn mergeTupleDemand(
        self: *Pass,
        existing: []const ItemDemand,
        incoming: []const ItemDemand,
    ) Allocator.Error!ValueDemand {
        var items = std.ArrayList(ItemDemand).empty;
        defer items.deinit(self.allocator);
        try items.appendSlice(self.allocator, existing);

        for (incoming) |incoming_item| {
            for (items.items) |*item| {
                if (item.index != incoming_item.index) continue;
                const merged = try self.mergeValueDemand(item.demand.*, incoming_item.demand.*);
                item.demand = try self.storedDemand(merged);
                break;
            } else {
                try items.append(self.allocator, incoming_item);
            }
        }

        return .{ .tuple = try self.arena.allocator().dupe(ItemDemand, items.items) };
    }

    fn valueDemandFromDemandedKnownValue(self: *Pass, known_value: DemandedKnownValue) Allocator.Error!ValueDemand {
        return switch (known_value) {
            .any,
            .leaf,
            => .materialize,
            .record => |record| blk: {
                const fields = try self.arena.allocator().alloc(FieldDemand, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    out.* = .{
                        .name = field.name,
                        .demand = try self.storedDemand(try self.valueDemandFromDemandedKnownValue(field.known_value)),
                    };
                }
                break :blk ValueDemand{ .record = fields };
            },
            .tuple => |tuple| blk: {
                const items = try self.valueDemandItemsFromDemandedKnownIndexedValues(tuple.items);
                break :blk ValueDemand{ .tuple = items };
            },
            .tag => |tag| blk: {
                const payloads = try self.valueDemandItemsFromDemandedKnownIndexedValues(tag.payloads);
                break :blk ValueDemand{ .tag = .{ .payloads = payloads } };
            },
            .nominal => |nominal| blk: {
                const backing = nominal.backing orelse break :blk .materialize;
                break :blk ValueDemand{ .nominal = try self.storedDemand(try self.valueDemandFromDemandedKnownValue(backing.*)) };
            },
            .callable => |callable| try self.valueDemandFromDemandedKnownCallable(callable),
            .finite_tags => |finite_tags| blk: {
                var demand: ValueDemand = .none;
                for (finite_tags.alternatives) |alternative| {
                    demand = try self.mergeValueDemand(demand, try self.valueDemandFromDemandedKnownValue(.{ .tag = alternative }));
                }
                break :blk demand;
            },
            .finite_callables => |finite_callables| blk: {
                var demand: ValueDemand = .none;
                for (finite_callables.alternatives) |alternative| {
                    demand = try self.mergeValueDemand(demand, try self.valueDemandFromDemandedKnownValue(.{ .callable = alternative }));
                }
                break :blk demand;
            },
        };
    }

    fn valueDemandItemsFromDemandedKnownIndexedValues(
        self: *Pass,
        indexed: []const DemandedKnownIndexedValue,
    ) Allocator.Error![]const ItemDemand {
        const items = try self.arena.allocator().alloc(ItemDemand, indexed.len);
        for (indexed, items) |item, *out| {
            out.* = .{
                .index = item.index,
                .demand = try self.storedDemand(try self.valueDemandFromDemandedKnownValue(item.known_value)),
            };
        }
        return items;
    }

    fn valueDemandFromDemandedKnownCallable(self: *Pass, callable: DemandedKnownCallable) Allocator.Error!ValueDemand {
        var captures_len: usize = 0;
        for (callable.captures) |capture| {
            captures_len = @max(captures_len, @as(usize, capture.index) + 1);
        }

        const captures = try self.arena.allocator().alloc(ValueDemand, captures_len);
        @memset(captures, .none);
        for (callable.captures) |capture| {
            captures[capture.index] = try self.valueDemandFromDemandedKnownValue(capture.known_value);
        }
        return .{ .callable = .{ .captures = captures } };
    }

    fn ensureCallPatternForValues(self: *Pass, fn_id: Ast.FnId, values: []const Value) Common.LowerError!void {
        const raw = @intFromEnum(fn_id);
        if (raw >= self.plans.len) return;

        const fn_args = self.program.typedLocalSpan(self.program.fns.items[raw].args);
        if (values.len != fn_args.len) Common.invariant("direct call arity differed from lifted function arity");

        const known_values = try self.arena.allocator().alloc(KnownValue, values.len);
        var has_constructor = false;
        for (values, 0..) |value, index| {
            if (self.plans[raw].used_args[index]) {
                if (try self.knownValueFromValue(value)) |known_value| {
                    known_values[index] = known_value;
                    has_constructor = true;
                    continue;
                }
            }
            known_values[index] = .{ .any = valueType(self.program, value) };
        }
        if (!has_constructor) return;

        const pattern: CallPattern = .{ .args = known_values };
        for (self.plans[raw].specs.items) |spec| {
            if (patternEql(self.program, spec.pattern, pattern)) return;
        }

        const spec_index = self.plans[raw].specs.items.len;
        try self.plans[raw].specs.append(self.allocator, .{ .pattern = pattern });
        try self.reserveWorker(@enumFromInt(@as(u32, @intCast(raw))), spec_index);
    }

    fn reserveWorker(self: *Pass, source_fn_id: Ast.FnId, spec_index: usize) Allocator.Error!void {
        const source_index = @intFromEnum(source_fn_id);
        const spec = &self.plans[source_index].specs.items[spec_index];
        if (spec.fn_id != null) Common.invariant("call-pattern specialization id was assigned twice");

        try self.program.fns.ensureUnusedCapacity(self.allocator, 1);
        try self.worker_worklist.ensureUnusedCapacity(self.allocator, 1);

        const source_fn = self.program.fns.items[source_index];
        const fn_id_reserved: Ast.FnId = @enumFromInt(@as(u32, @intCast(self.program.fns.items.len)));
        const symbol = self.symbols.fresh();
        spec.fn_id = fn_id_reserved;
        self.program.fns.appendAssumeCapacity(.{
            .symbol = symbol,
            .source = source_fn.source,
            .args = .empty(),
            .captures = source_fn.captures,
            .body = .hosted,
            .ret = source_fn.ret,
        });
        self.worker_worklist.appendAssumeCapacity(.{
            .source_fn = source_fn_id,
            .spec_index = spec_index,
        });
        try self.copyProcDebugName(source_fn.symbol, symbol);
    }

    fn writeSpecialization(self: *Pass, source_fn_id: Ast.FnId, spec_index: usize, source_body: Ast.ExprId) Common.LowerError!void {
        const source_fn = self.program.fns.items[@intFromEnum(source_fn_id)];
        const spec = &self.plans[@intFromEnum(source_fn_id)].specs.items[spec_index];

        const spec_fn_id = spec.fn_id orelse Common.invariant("call-pattern specialization id was not assigned before cloning");
        const symbol = self.program.fns.items[@intFromEnum(spec_fn_id)].symbol;

        var cloner = Cloner.init(self, source_fn_id, spec.pattern);
        defer cloner.deinit();

        try cloner.inline_stack.append(self.allocator, .{ .fn_id = source_fn_id });
        defer {
            const popped = cloner.inline_stack.pop() orelse Common.invariant("call-pattern inline stack underflow while writing specialization");
            if (popped.fn_id != source_fn_id) Common.invariant("call-pattern inline stack was corrupted while writing specialization");
        }

        const args = try cloner.buildArgs();
        const body: Ast.FnBody = .{ .roc = try cloner.cloneExpr(source_body) };

        self.program.fns.items[@intFromEnum(spec_fn_id)] = .{
            .symbol = symbol,
            .source = source_fn.source,
            .args = args,
            .captures = source_fn.captures,
            .body = body,
            .ret = source_fn.ret,
        };
        try self.copyProcDebugName(source_fn.symbol, symbol);
    }

    fn constructorKnownValue(self: *Pass, expr_id: Ast.ExprId) Allocator.Error!?KnownValue {
        const expr = self.program.exprs.items[@intFromEnum(expr_id)];
        return switch (expr.data) {
            .unit,
            .int_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .dec_lit,
            .str_lit,
            .static_data,
            .list,
            => KnownValue{ .leaf = expr.ty },
            .tag => |tag| blk: {
                const payloads = self.program.exprSpan(tag.payloads);
                const known_values = try self.arena.allocator().alloc(KnownValue, payloads.len);
                for (payloads, 0..) |payload, index| {
                    known_values[index] = (try self.constructorKnownValue(payload)) orelse
                        .{ .any = self.program.exprs.items[@intFromEnum(payload)].ty };
                }
                break :blk KnownValue{ .tag = .{
                    .ty = expr.ty,
                    .name = tag.name,
                    .payloads = known_values,
                } };
            },
            .record => |fields_span| blk: {
                const fields = self.program.fieldExprSpan(fields_span);
                const known_values = try self.arena.allocator().alloc(KnownField, fields.len);
                for (fields, 0..) |field, index| {
                    known_values[index] = .{
                        .name = field.name,
                        .known_value = (try self.constructorKnownValue(field.value)) orelse
                            .{ .any = self.program.exprs.items[@intFromEnum(field.value)].ty },
                    };
                }
                break :blk KnownValue{ .record = .{
                    .ty = expr.ty,
                    .fields = known_values,
                } };
            },
            .tuple => |items_span| blk: {
                const items = self.program.exprSpan(items_span);
                const known_values = try self.arena.allocator().alloc(KnownValue, items.len);
                for (items, 0..) |item, index| {
                    known_values[index] = (try self.constructorKnownValue(item)) orelse
                        .{ .any = self.program.exprs.items[@intFromEnum(item)].ty };
                }
                break :blk KnownValue{ .tuple = .{
                    .ty = expr.ty,
                    .items = known_values,
                } };
            },
            .nominal => |backing| blk: {
                const backing_known_value = (try self.constructorKnownValue(backing)) orelse break :blk null;
                const stored = try self.arena.allocator().create(KnownValue);
                stored.* = backing_known_value;
                break :blk KnownValue{ .nominal = .{
                    .ty = expr.ty,
                    .backing = stored,
                } };
            },
            .fn_ref => |fn_id| blk: {
                const fn_ = self.program.fns.items[@intFromEnum(fn_id)];
                const captures = self.program.typedLocalSpan(fn_.captures);
                const capture_known_values = try self.arena.allocator().alloc(KnownValue, captures.len);
                for (captures, 0..) |capture, index| {
                    capture_known_values[index] = .{ .any = capture.ty };
                }
                break :blk KnownValue{ .callable = .{
                    .ty = expr.ty,
                    .fn_id = fn_id,
                    .captures = capture_known_values,
                } };
            },
            else => null,
        };
    }

    fn knownValueFromValue(self: *Pass, value: Value) Allocator.Error!?KnownValue {
        return switch (value) {
            .expr => |expr| try self.constructorKnownValue(expr),
            .expr_with_known_value => |known_value_expr| known_value_expr.known_value,
            .let_ => |let_value| try self.knownValueFromValue(let_value.body.*),
            .if_ => |if_value| blk: {
                var joined: ?KnownValue = null;
                for (if_value.branches) |branch| {
                    const branch_known_value = (try self.knownValueFromValue(branch.body)) orelse break :blk null;
                    joined = if (joined) |existing|
                        (try joinKnownValuesInArena(self.program, self.arena.allocator(), existing, branch_known_value)) orelse break :blk null
                    else
                        branch_known_value;
                }
                const final_known_value = (try self.knownValueFromValue(if_value.final_else.*)) orelse break :blk null;
                break :blk if (joined) |existing|
                    (try joinKnownValuesInArena(self.program, self.arena.allocator(), existing, final_known_value)) orelse null
                else
                    final_known_value;
            },
            .match_ => |match_value| blk: {
                var joined: ?KnownValue = null;
                for (match_value.branches) |branch| {
                    const branch_known_value = (try self.knownValueFromValue(branch.body)) orelse break :blk null;
                    joined = if (joined) |existing|
                        (try joinKnownValuesInArena(self.program, self.arena.allocator(), existing, branch_known_value)) orelse break :blk null
                    else
                        branch_known_value;
                }
                break :blk joined;
            },
            .tag => |tag| blk: {
                const payloads = try self.arena.allocator().alloc(KnownValue, tag.payloads.len);
                for (tag.payloads, 0..) |payload, index| {
                    payloads[index] = (try self.knownValueFromValue(payload)) orelse
                        .{ .any = valueType(self.program, payload) };
                }
                break :blk KnownValue{ .tag = .{
                    .ty = tag.ty,
                    .name = tag.name,
                    .payloads = payloads,
                } };
            },
            .record => |record| blk: {
                const fields = try self.arena.allocator().alloc(KnownField, record.fields.len);
                for (record.fields, 0..) |field, index| {
                    fields[index] = .{
                        .name = field.name,
                        .known_value = (try self.knownValueFromValue(field.value)) orelse
                            .{ .any = valueType(self.program, field.value) },
                    };
                }
                break :blk KnownValue{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| blk: {
                const items = try self.arena.allocator().alloc(KnownValue, tuple.items.len);
                for (tuple.items, 0..) |item, index| {
                    items[index] = (try self.knownValueFromValue(item)) orelse
                        .{ .any = valueType(self.program, item) };
                }
                break :blk KnownValue{ .tuple = .{
                    .ty = tuple.ty,
                    .items = items,
                } };
            },
            .nominal => |nominal| blk: {
                const backing_known_value = (try self.knownValueFromValue(nominal.backing.*)) orelse break :blk null;
                const stored = try self.arena.allocator().create(KnownValue);
                stored.* = backing_known_value;
                break :blk KnownValue{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = stored,
                } };
            },
            .callable => |callable| blk: {
                const captures = try self.arena.allocator().alloc(KnownValue, callable.captures.len);
                for (callable.captures, 0..) |capture, index| {
                    captures[index] = (try self.knownValueFromValue(capture)) orelse
                        (try leafKnownValueFromValue(self.program, capture)) orelse
                        .{ .any = valueType(self.program, capture) };
                }
                break :blk KnownValue{ .callable = .{
                    .ty = callable.ty,
                    .fn_id = callable.fn_id,
                    .captures = captures,
                } };
            },
            .finite_tags => |finite_tags| blk: {
                const alternatives = try self.arena.allocator().alloc(KnownTag, finite_tags.alternatives.len);
                for (finite_tags.alternatives, alternatives) |alternative, *out| {
                    const payloads = try self.arena.allocator().alloc(KnownValue, alternative.payloads.len);
                    for (alternative.payloads, payloads) |payload, *payload_out| {
                        payload_out.* = (try self.knownValueFromValue(payload)) orelse
                            .{ .any = valueType(self.program, payload) };
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .name = alternative.name,
                        .payloads = payloads,
                    };
                }
                break :blk KnownValue{ .finite_tags = .{
                    .ty = finite_tags.ty,
                    .alternatives = alternatives,
                } };
            },
            .finite_callables => |finite_callables| blk: {
                const alternatives = try self.arena.allocator().alloc(KnownCallable, finite_callables.alternatives.len);
                for (finite_callables.alternatives, alternatives) |alternative, *out| {
                    const captures = try self.arena.allocator().alloc(KnownValue, alternative.captures.len);
                    for (alternative.captures, captures) |capture, *capture_out| {
                        capture_out.* = (try self.knownValueFromValue(capture)) orelse
                            (try leafKnownValueFromValue(self.program, capture)) orelse
                            .{ .any = valueType(self.program, capture) };
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .fn_id = alternative.fn_id,
                        .captures = captures,
                    };
                }
                break :blk KnownValue{ .finite_callables = .{
                    .ty = finite_callables.ty,
                    .alternatives = alternatives,
                } };
            },
            .private_state => |private_state| try knownValueFromPrivateState(self.program, self.arena.allocator(), private_state),
        };
    }
};

const Cloner = struct {
    pass: *Pass,
    source_fn: Ast.FnId,
    pattern: CallPattern,
    subst: std.AutoHashMap(Ast.LocalId, Value),
    state_loop_state_map: std.AutoHashMap(Ast.StateLoopStateId, Ast.StateLoopStateId),
    changes: std.ArrayList(BindingChange),
    inline_stack: std.ArrayList(ActiveInline),
    demand_stack: std.ArrayList(ActiveDemand),
    local_demand_stack: std.ArrayList(LocalDemandFrame),
    loop_stack: std.ArrayList(LoopPattern),
    state_loop_stack: std.ArrayList(SparseStateLoopPattern),
    inline_direct_calls: bool,
    inline_direct_requires_known_arg: bool,
    record_call_patterns: bool,
    source_arg_locals_in_scope: bool,
    current_loc: SourceLoc,
    current_region: Region,

    fn init(pass: *Pass, source_fn: Ast.FnId, pattern: CallPattern) Cloner {
        return .{
            .pass = pass,
            .source_fn = source_fn,
            .pattern = pattern,
            .subst = std.AutoHashMap(Ast.LocalId, Value).init(pass.allocator),
            .state_loop_state_map = std.AutoHashMap(Ast.StateLoopStateId, Ast.StateLoopStateId).init(pass.allocator),
            .changes = .empty,
            .inline_stack = .empty,
            .demand_stack = .empty,
            .local_demand_stack = .empty,
            .loop_stack = .empty,
            .state_loop_stack = .empty,
            .inline_direct_calls = true,
            .inline_direct_requires_known_arg = true,
            .record_call_patterns = true,
            .source_arg_locals_in_scope = false,
            .current_loc = SourceLoc.none,
            .current_region = Region.zero(),
        };
    }

    fn initForBaseClone(pass: *Pass) Cloner {
        return .{
            .pass = pass,
            .source_fn = undefined, // Base-body cloning never calls buildArgs, which is the only reader.
            .pattern = .{ .args = &.{} },
            .subst = std.AutoHashMap(Ast.LocalId, Value).init(pass.allocator),
            .state_loop_state_map = std.AutoHashMap(Ast.StateLoopStateId, Ast.StateLoopStateId).init(pass.allocator),
            .changes = .empty,
            .inline_stack = .empty,
            .demand_stack = .empty,
            .local_demand_stack = .empty,
            .loop_stack = .empty,
            .state_loop_stack = .empty,
            .inline_direct_calls = true,
            .inline_direct_requires_known_arg = false,
            .record_call_patterns = true,
            .source_arg_locals_in_scope = false,
            .current_loc = SourceLoc.none,
            .current_region = Region.zero(),
        };
    }

    fn initForBaseBody(pass: *Pass, source_fn: Ast.FnId) Cloner {
        var cloner = Cloner.initForBaseClone(pass);
        cloner.source_fn = source_fn;
        cloner.inline_direct_requires_known_arg = true;
        cloner.source_arg_locals_in_scope = true;
        return cloner;
    }

    fn deinit(self: *Cloner) void {
        self.state_loop_stack.deinit(self.pass.allocator);
        self.local_demand_stack.deinit(self.pass.allocator);
        self.demand_stack.deinit(self.pass.allocator);
        self.inline_stack.deinit(self.pass.allocator);
        self.loop_stack.deinit(self.pass.allocator);
        self.changes.deinit(self.pass.allocator);
        self.state_loop_state_map.deinit();
        self.subst.deinit();
    }

    fn buildArgs(self: *Cloner) Allocator.Error!Ast.Span(Ast.TypedLocal) {
        const source_fn = self.pass.program.fns.items[@intFromEnum(self.source_fn)];
        const source_args = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.args));
        defer self.pass.allocator.free(source_args);
        if (source_args.len != self.pattern.args.len) Common.invariant("call-pattern argument count differed from source function arity");
        const saved_loc = self.current_loc;
        defer self.current_loc = saved_loc;
        const saved_region = self.current_region;
        defer self.current_region = saved_region;
        self.current_loc = switch (source_fn.body) {
            .roc => |body| self.pass.program.exprLoc(body),
            .hosted => SourceLoc.none,
        };
        self.current_region = switch (source_fn.body) {
            .roc => |body| self.pass.program.exprRegion(body),
            .hosted => Region.zero(),
        };

        var args = std.ArrayList(Ast.TypedLocal).empty;
        defer args.deinit(self.pass.allocator);

        for (source_args, self.pattern.args) |source_arg, known_value| {
            const value = try self.valueFromKnownValueArgs(known_value, &args);
            try self.putSubst(source_arg.local, value);
        }

        return try self.pass.program.addTypedLocalSpan(args.items);
    }

    fn valueFromKnownValueArgs(self: *Cloner, known_value: KnownValue, args: *std.ArrayList(Ast.TypedLocal)) Allocator.Error!Value {
        switch (known_value) {
            .any => |ty| {
                const local = try self.pass.program.addLocal(self.pass.symbols.fresh(), ty);
                try args.append(self.pass.allocator, .{ .local = local, .ty = ty });
                return .{ .expr = try self.addExpr(.{
                    .ty = ty,
                    .data = .{ .local = local },
                }) };
            },
            .leaf => |ty| {
                const local = try self.pass.program.addLocal(self.pass.symbols.fresh(), ty);
                try args.append(self.pass.allocator, .{ .local = local, .ty = ty });
                return .{ .expr = try self.addExpr(.{
                    .ty = ty,
                    .data = .{ .local = local },
                }) };
            },
            .tag => |tag| {
                const payloads = try self.pass.arena.allocator().alloc(Value, tag.payloads.len);
                for (tag.payloads, 0..) |payload, index| {
                    payloads[index] = try self.valueFromKnownValueArgs(payload, args);
                }
                return .{ .tag = .{
                    .ty = tag.ty,
                    .name = tag.name,
                    .payloads = payloads,
                } };
            },
            .record => |record| {
                const fields = try self.pass.arena.allocator().alloc(FieldValue, record.fields.len);
                for (record.fields, 0..) |field, index| {
                    fields[index] = .{
                        .name = field.name,
                        .value = try self.valueFromKnownValueArgs(field.known_value, args),
                    };
                }
                return .{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| {
                const items = try self.pass.arena.allocator().alloc(Value, tuple.items.len);
                for (tuple.items, 0..) |item, index| {
                    items[index] = try self.valueFromKnownValueArgs(item, args);
                }
                return .{ .tuple = .{
                    .ty = tuple.ty,
                    .items = items,
                } };
            },
            .nominal => |nominal| {
                const backing = try self.pass.arena.allocator().create(Value);
                backing.* = try self.valueFromKnownValueArgs(nominal.backing.*, args);
                return .{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = backing,
                } };
            },
            .callable => |callable| {
                const captures = try self.pass.arena.allocator().alloc(Value, callable.captures.len);
                for (callable.captures, 0..) |capture, index| {
                    captures[index] = try self.valueFromKnownValueArgs(capture, args);
                }
                return .{ .callable = .{
                    .ty = callable.ty,
                    .fn_id = callable.fn_id,
                    .captures = captures,
                } };
            },
            .finite_tags => |finite_tags| {
                const selector_ty = try self.pass.primitiveType(.u64);
                const selector_local = try self.pass.program.addLocal(self.pass.symbols.fresh(), selector_ty);
                try args.append(self.pass.allocator, .{ .local = selector_local, .ty = selector_ty });
                const selector = try self.addExpr(.{
                    .ty = selector_ty,
                    .data = .{ .local = selector_local },
                });

                const alternatives = try self.pass.arena.allocator().alloc(TagValue, finite_tags.alternatives.len);
                for (finite_tags.alternatives, alternatives) |alternative, *out| {
                    const payloads = try self.pass.arena.allocator().alloc(Value, alternative.payloads.len);
                    for (alternative.payloads, payloads) |payload_known_value, *payload_out| {
                        payload_out.* = try self.valueFromKnownValueArgs(payload_known_value, args);
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .name = alternative.name,
                        .payloads = payloads,
                    };
                }

                return .{ .finite_tags = .{
                    .ty = finite_tags.ty,
                    .selector = selector,
                    .alternatives = alternatives,
                } };
            },
            .finite_callables => |finite_callables| {
                const selector_ty = try self.pass.primitiveType(.u64);
                const selector_local = try self.pass.program.addLocal(self.pass.symbols.fresh(), selector_ty);
                try args.append(self.pass.allocator, .{ .local = selector_local, .ty = selector_ty });
                const selector = try self.addExpr(.{
                    .ty = selector_ty,
                    .data = .{ .local = selector_local },
                });

                const alternatives = try self.pass.arena.allocator().alloc(CallableValue, finite_callables.alternatives.len);
                for (finite_callables.alternatives, alternatives) |alternative, *out| {
                    const captures = try self.pass.arena.allocator().alloc(Value, alternative.captures.len);
                    for (alternative.captures, captures) |capture_known_value, *capture_out| {
                        capture_out.* = try self.valueFromKnownValueArgs(capture_known_value, args);
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .fn_id = alternative.fn_id,
                        .captures = captures,
                    };
                }

                return .{ .finite_callables = .{
                    .ty = finite_callables.ty,
                    .selector = selector,
                    .alternatives = alternatives,
                } };
            },
        }
    }

    fn appendLoopSplitLocal(
        self: *Cloner,
        provenance: *std.ArrayList(LoopLocalProvenance),
        local: Ast.LocalId,
        source_local: Ast.LocalId,
        path: []const DemandPathStep,
    ) Allocator.Error!void {
        try provenance.append(self.pass.allocator, .{
            .local = local,
            .source_local = source_local,
            .path = try self.pass.arena.allocator().dupe(DemandPathStep, path),
        });
    }

    fn valueFromKnownValueLoopParamArgs(
        self: *Cloner,
        known_value: KnownValue,
        args: *std.ArrayList(Ast.TypedLocal),
        source_local: Ast.LocalId,
        path: *std.ArrayList(DemandPathStep),
        provenance: *std.ArrayList(LoopLocalProvenance),
    ) Allocator.Error!Value {
        switch (known_value) {
            .any => |ty| {
                const local = try self.pass.program.addLocal(self.pass.symbols.fresh(), ty);
                try args.append(self.pass.allocator, .{ .local = local, .ty = ty });
                try self.appendLoopSplitLocal(provenance, local, source_local, path.items);
                return .{ .expr = try self.addExpr(.{
                    .ty = ty,
                    .data = .{ .local = local },
                }) };
            },
            .leaf => |ty| {
                const local = try self.pass.program.addLocal(self.pass.symbols.fresh(), ty);
                try args.append(self.pass.allocator, .{ .local = local, .ty = ty });
                try self.appendLoopSplitLocal(provenance, local, source_local, path.items);
                return .{ .expr = try self.addExpr(.{
                    .ty = ty,
                    .data = .{ .local = local },
                }) };
            },
            .tag => |tag| {
                const payloads = try self.pass.arena.allocator().alloc(Value, tag.payloads.len);
                for (tag.payloads, 0..) |payload, index| {
                    try path.append(self.pass.allocator, .{ .tag_payload = @intCast(index) });
                    defer _ = path.pop();
                    payloads[index] = try self.valueFromKnownValueLoopParamArgs(payload, args, source_local, path, provenance);
                }
                return .{ .tag = .{
                    .ty = tag.ty,
                    .name = tag.name,
                    .payloads = payloads,
                } };
            },
            .record => |record| {
                const fields = try self.pass.arena.allocator().alloc(FieldValue, record.fields.len);
                for (record.fields, 0..) |field, index| {
                    try path.append(self.pass.allocator, .{ .record_field = field.name });
                    defer _ = path.pop();
                    fields[index] = .{
                        .name = field.name,
                        .value = try self.valueFromKnownValueLoopParamArgs(field.known_value, args, source_local, path, provenance),
                    };
                }
                return .{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| {
                const items = try self.pass.arena.allocator().alloc(Value, tuple.items.len);
                for (tuple.items, 0..) |item, index| {
                    try path.append(self.pass.allocator, .{ .tuple_item = @intCast(index) });
                    defer _ = path.pop();
                    items[index] = try self.valueFromKnownValueLoopParamArgs(item, args, source_local, path, provenance);
                }
                return .{ .tuple = .{
                    .ty = tuple.ty,
                    .items = items,
                } };
            },
            .nominal => |nominal| {
                try path.append(self.pass.allocator, .nominal_backing);
                defer _ = path.pop();
                const backing = try self.pass.arena.allocator().create(Value);
                backing.* = try self.valueFromKnownValueLoopParamArgs(nominal.backing.*, args, source_local, path, provenance);
                return .{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = backing,
                } };
            },
            .callable => |callable| {
                const captures = try self.pass.arena.allocator().alloc(Value, callable.captures.len);
                for (callable.captures, 0..) |capture, index| {
                    try path.append(self.pass.allocator, .{ .callable_capture = @intCast(index) });
                    defer _ = path.pop();
                    captures[index] = try self.valueFromKnownValueLoopParamArgs(capture, args, source_local, path, provenance);
                }
                return .{ .callable = .{
                    .ty = callable.ty,
                    .fn_id = callable.fn_id,
                    .captures = captures,
                } };
            },
            .finite_tags => |finite_tags| {
                const selector_ty = try self.pass.primitiveType(.u64);
                const selector_local = try self.pass.program.addLocal(self.pass.symbols.fresh(), selector_ty);
                try args.append(self.pass.allocator, .{ .local = selector_local, .ty = selector_ty });
                try self.appendLoopSplitLocal(provenance, selector_local, source_local, path.items);
                const selector = try self.addExpr(.{
                    .ty = selector_ty,
                    .data = .{ .local = selector_local },
                });

                const alternatives = try self.pass.arena.allocator().alloc(TagValue, finite_tags.alternatives.len);
                for (finite_tags.alternatives, alternatives) |alternative, *out| {
                    const payloads = try self.pass.arena.allocator().alloc(Value, alternative.payloads.len);
                    for (alternative.payloads, payloads) |payload_known_value, *payload_out| {
                        payload_out.* = try self.valueFromKnownValueLoopParamArgs(payload_known_value, args, source_local, path, provenance);
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .name = alternative.name,
                        .payloads = payloads,
                    };
                }

                return .{ .finite_tags = .{
                    .ty = finite_tags.ty,
                    .selector = selector,
                    .alternatives = alternatives,
                } };
            },
            .finite_callables => |finite_callables| {
                const selector_ty = try self.pass.primitiveType(.u64);
                const selector_local = try self.pass.program.addLocal(self.pass.symbols.fresh(), selector_ty);
                try args.append(self.pass.allocator, .{ .local = selector_local, .ty = selector_ty });
                try self.appendLoopSplitLocal(provenance, selector_local, source_local, path.items);
                const selector = try self.addExpr(.{
                    .ty = selector_ty,
                    .data = .{ .local = selector_local },
                });

                const alternatives = try self.pass.arena.allocator().alloc(CallableValue, finite_callables.alternatives.len);
                for (finite_callables.alternatives, alternatives) |alternative, *out| {
                    const captures = try self.pass.arena.allocator().alloc(Value, alternative.captures.len);
                    for (alternative.captures, captures) |capture_known_value, *capture_out| {
                        capture_out.* = try self.valueFromKnownValueLoopParamArgs(capture_known_value, args, source_local, path, provenance);
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .fn_id = alternative.fn_id,
                        .captures = captures,
                    };
                }

                return .{ .finite_callables = .{
                    .ty = finite_callables.ty,
                    .selector = selector,
                    .alternatives = alternatives,
                } };
            },
        }
    }

    fn privateStateValueFromDemandedKnownValueArgs(
        self: *Cloner,
        known_value: DemandedKnownValue,
        args: *std.ArrayList(Ast.TypedLocal),
    ) Allocator.Error!PrivateStateValue {
        return switch (known_value) {
            .any,
            .leaf,
            => |ty| blk: {
                const local = try self.pass.program.addLocal(self.pass.symbols.fresh(), ty);
                try args.append(self.pass.allocator, .{ .local = local, .ty = ty });
                break :blk PrivateStateValue{ .leaf = .{
                    .ty = ty,
                    .expr = try self.addExpr(.{
                        .ty = ty,
                        .data = .{ .local = local },
                    }),
                } };
            },
            .tag => |tag| .{ .tag = .{
                .ty = tag.ty,
                .name = tag.name,
                .payloads = try self.privateStateIndexedValuesFromDemandedKnownValues(tag.payloads, args),
            } },
            .record => |record| blk: {
                const fields = try self.pass.arena.allocator().alloc(PrivateStateField, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    out.* = .{
                        .name = field.name,
                        .value = try self.privateStateValueFromDemandedKnownValueArgs(field.known_value, args),
                    };
                }
                break :blk PrivateStateValue{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| .{ .tuple = .{
                .ty = tuple.ty,
                .items = try self.privateStateIndexedValuesFromDemandedKnownValues(tuple.items, args),
            } },
            .nominal => |nominal| blk: {
                const backing = if (nominal.backing) |backing_known_value| backing: {
                    const stored = try self.pass.arena.allocator().create(PrivateStateValue);
                    stored.* = try self.privateStateValueFromDemandedKnownValueArgs(backing_known_value.*, args);
                    break :backing stored;
                } else null;
                break :blk PrivateStateValue{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = backing,
                } };
            },
            .callable => |callable| .{ .callable = .{
                .ty = callable.ty,
                .fn_id = callable.fn_id,
                .captures = try self.privateStateIndexedValuesFromDemandedKnownValues(callable.captures, args),
            } },
            .finite_tags,
            .finite_callables,
            => Common.invariant("finite demanded state reached private state value construction before expansion"),
        };
    }

    fn privateStateIndexedValuesFromDemandedKnownValues(
        self: *Cloner,
        known_values: []const DemandedKnownIndexedValue,
        args: *std.ArrayList(Ast.TypedLocal),
    ) Allocator.Error![]const PrivateStateIndexedValue {
        const values = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, known_values.len);
        for (known_values, values) |known_value, *out| {
            out.* = .{
                .index = known_value.index,
                .value = try self.privateStateValueFromDemandedKnownValueArgs(known_value.known_value, args),
            };
        }
        return values;
    }

    fn privateStateValueFromDemandedKnownValueLoopParamArgs(
        self: *Cloner,
        known_value: DemandedKnownValue,
        args: *std.ArrayList(Ast.TypedLocal),
        source_local: Ast.LocalId,
        path: *std.ArrayList(DemandPathStep),
        provenance: *std.ArrayList(LoopLocalProvenance),
    ) Allocator.Error!PrivateStateValue {
        return switch (known_value) {
            .any,
            .leaf,
            => |ty| blk: {
                const local = try self.pass.program.addLocal(self.pass.symbols.fresh(), ty);
                try args.append(self.pass.allocator, .{ .local = local, .ty = ty });
                try self.appendLoopSplitLocal(provenance, local, source_local, path.items);
                break :blk PrivateStateValue{ .leaf = .{
                    .ty = ty,
                    .expr = try self.addExpr(.{
                        .ty = ty,
                        .data = .{ .local = local },
                    }),
                } };
            },
            .tag => |tag| blk: {
                const payloads = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, tag.payloads.len);
                for (tag.payloads, payloads) |payload, *out| {
                    try path.append(self.pass.allocator, .{ .tag_payload = payload.index });
                    defer _ = path.pop();
                    out.* = .{
                        .index = payload.index,
                        .value = try self.privateStateValueFromDemandedKnownValueLoopParamArgs(
                            payload.known_value,
                            args,
                            source_local,
                            path,
                            provenance,
                        ),
                    };
                }
                break :blk PrivateStateValue{ .tag = .{
                    .ty = tag.ty,
                    .name = tag.name,
                    .payloads = payloads,
                } };
            },
            .record => |record| blk: {
                const fields = try self.pass.arena.allocator().alloc(PrivateStateField, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    try path.append(self.pass.allocator, .{ .record_field = field.name });
                    defer _ = path.pop();
                    out.* = .{
                        .name = field.name,
                        .value = try self.privateStateValueFromDemandedKnownValueLoopParamArgs(
                            field.known_value,
                            args,
                            source_local,
                            path,
                            provenance,
                        ),
                    };
                }
                break :blk PrivateStateValue{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| blk: {
                const items = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, tuple.items.len);
                for (tuple.items, items) |item, *out| {
                    try path.append(self.pass.allocator, .{ .tuple_item = item.index });
                    defer _ = path.pop();
                    out.* = .{
                        .index = item.index,
                        .value = try self.privateStateValueFromDemandedKnownValueLoopParamArgs(
                            item.known_value,
                            args,
                            source_local,
                            path,
                            provenance,
                        ),
                    };
                }
                break :blk PrivateStateValue{ .tuple = .{
                    .ty = tuple.ty,
                    .items = items,
                } };
            },
            .nominal => |nominal| blk: {
                const backing = if (nominal.backing) |backing_known_value| backing: {
                    try path.append(self.pass.allocator, .nominal_backing);
                    defer _ = path.pop();
                    const stored = try self.pass.arena.allocator().create(PrivateStateValue);
                    stored.* = try self.privateStateValueFromDemandedKnownValueLoopParamArgs(
                        backing_known_value.*,
                        args,
                        source_local,
                        path,
                        provenance,
                    );
                    break :backing stored;
                } else null;
                break :blk PrivateStateValue{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = backing,
                } };
            },
            .callable => |callable| blk: {
                const captures = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, callable.captures.len);
                for (callable.captures, captures) |capture, *out| {
                    try path.append(self.pass.allocator, .{ .callable_capture = capture.index });
                    defer _ = path.pop();
                    out.* = .{
                        .index = capture.index,
                        .value = try self.privateStateValueFromDemandedKnownValueLoopParamArgs(
                            capture.known_value,
                            args,
                            source_local,
                            path,
                            provenance,
                        ),
                    };
                }
                break :blk PrivateStateValue{ .callable = .{
                    .ty = callable.ty,
                    .fn_id = callable.fn_id,
                    .captures = captures,
                } };
            },
            .finite_tags,
            .finite_callables,
            => Common.invariant("finite demanded state reached private loop-param construction before expansion"),
        };
    }

    fn cloneExpr(self: *Cloner, expr_id: Ast.ExprId) Common.LowerError!Ast.ExprId {
        const saved_loc = self.current_loc;
        defer self.current_loc = saved_loc;
        const saved_region = self.current_region;
        defer self.current_region = saved_region;
        self.current_loc = self.pass.program.exprLoc(expr_id);
        self.current_region = self.pass.program.exprRegion(expr_id);
        return try self.materialize(try self.cloneExprValueWithDemand(expr_id, .materialize));
    }

    fn cloneExprValue(self: *Cloner, expr_id: Ast.ExprId) Common.LowerError!Value {
        const saved_loc = self.current_loc;
        defer self.current_loc = saved_loc;
        const saved_region = self.current_region;
        defer self.current_region = saved_region;
        self.current_loc = self.pass.program.exprLoc(expr_id);
        self.current_region = self.pass.program.exprRegion(expr_id);

        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        switch (expr.data) {
            .local => |local| {
                if (self.subst.get(local)) |value| return value;
                if (try self.solvedSingleCallable(expr_id)) |callable| return callable;
                return .{ .expr = try self.addExpr(.{ .ty = expr.ty, .data = .{ .local = local } }) };
            },
            .fn_ref => |fn_id| return try self.callableValue(expr.ty, fn_id),
            .tag => |tag| {
                const payload_exprs = try self.pass.allocator.dupe(Ast.ExprId, self.pass.program.exprSpan(tag.payloads));
                defer self.pass.allocator.free(payload_exprs);
                const payloads = try self.pass.arena.allocator().alloc(Value, payload_exprs.len);
                for (payload_exprs, 0..) |payload, index| {
                    payloads[index] = try self.cloneExprValueDemandingKnownValue(payload);
                }
                return .{ .tag = .{
                    .ty = expr.ty,
                    .name = tag.name,
                    .payloads = payloads,
                } };
            },
            .record => |fields_span| {
                const source_fields = try self.pass.allocator.dupe(Ast.FieldExpr, self.pass.program.fieldExprSpan(fields_span));
                defer self.pass.allocator.free(source_fields);
                const fields = try self.pass.arena.allocator().alloc(FieldValue, source_fields.len);
                for (source_fields, 0..) |field, index| {
                    fields[index] = .{
                        .name = field.name,
                        .value = try self.cloneExprValueDemandingKnownValue(field.value),
                    };
                }
                return .{ .record = .{
                    .ty = expr.ty,
                    .fields = fields,
                } };
            },
            .tuple => |items_span| {
                const source_items = try self.pass.allocator.dupe(Ast.ExprId, self.pass.program.exprSpan(items_span));
                defer self.pass.allocator.free(source_items);
                const items = try self.pass.arena.allocator().alloc(Value, source_items.len);
                for (source_items, 0..) |item, index| {
                    items[index] = try self.cloneExprValueDemandingKnownValue(item);
                }
                return .{ .tuple = .{
                    .ty = expr.ty,
                    .items = items,
                } };
            },
            .nominal => |backing| {
                const backing_value = try self.cloneExprValueDemandingKnownValue(backing);
                return .{ .nominal = .{
                    .ty = expr.ty,
                    .backing = try self.copyValue(backing_value),
                } };
            },
            .let_ => |let_| return try self.cloneLetValue(let_),
            .field_access => |field| {
                try self.noteLoopDemandIfLocalExpr(
                    field.receiver,
                    try self.pass.demandRecordField(field.field, .materialize),
                );
                const receiver = try self.cloneExprValueDemandingKnownValue(field.receiver);
                if (try self.fieldFromKnownValue(receiver, field.field)) |value| return value;
                if (try self.solvedSingleCallable(expr_id)) |callable| return callable;
                return .{ .expr = try self.addExpr(.{ .ty = expr.ty, .data = .{ .field_access = .{
                    .receiver = try self.materialize(receiver),
                    .field = field.field,
                } } }) };
            },
            .tuple_access => |access| {
                try self.noteLoopDemandIfLocalExpr(
                    access.tuple,
                    try self.pass.demandTupleItem(access.elem_index, .materialize),
                );
                const receiver = try self.cloneExprValueDemandingKnownValue(access.tuple);
                if (try self.itemFromKnownValue(receiver, access.elem_index)) |value| return value;
                if (try self.solvedSingleCallable(expr_id)) |callable| return callable;
                return .{ .expr = try self.addExpr(.{ .ty = expr.ty, .data = .{ .tuple_access = .{
                    .tuple = try self.materialize(receiver),
                    .elem_index = access.elem_index,
                } } }) };
            },
            .match_ => |match| {
                const scrutinee = try self.cloneMatchScrutineeValue(match, .materialize);
                if (try self.simplifyKnownMatchValue(expr.ty, scrutinee, match.branches)) |value| return value;
                if (scrutinee == .if_) return try self.cloneMatchIfValue(expr.ty, scrutinee.if_, match);
                if (scrutinee == .match_) return try self.cloneMatchMatchValue(expr.ty, scrutinee.match_, match);
                const scrutinee_expr = try self.materialize(scrutinee);
                if (try self.cloneCaseOfCaseValue(expr.ty, scrutinee_expr, match.branches)) |value| return value;
                const scrutinee_known_value = try self.pass.knownValueFromValue(scrutinee);
                return try self.cloneMatchJoinedValue(expr.ty, scrutinee_expr, match, scrutinee_known_value, scrutinee);
            },
            .if_ => |if_| return try self.cloneIfValue(expr.ty, if_),
            .block => |block| return try self.cloneBlockValue(expr.ty, block),
            .call_value => |call| {
                const callee_demand = try self.callableDemandForCalleeExpr(call.callee);
                try self.noteLoopDemandIfLocalExpr(call.callee, callee_demand);
                const callee = try self.cloneExprValueWithDemand(call.callee, callee_demand);
                return try self.callKnownValue(expr.ty, callee, call.args, false);
            },
            .call_proc => |call| {
                if (call.is_cold) return .{ .expr = try self.cloneExprPlain(expr_id) };
                if (!self.inline_direct_calls) return .{ .expr = try self.cloneExprPlain(expr_id) };
                const has_known_value_arg = try self.directCallHasKnownValueArg(call.args);
                if (self.inline_direct_requires_known_arg and !has_known_value_arg) {
                    return .{ .expr = try self.cloneExprPlain(expr_id) };
                }
                return try self.inlineDirectCallValue(
                    Ast.callProcCallee(call),
                    call.args,
                    expr_id,
                    false,
                );
            },
            else => return .{ .expr = try self.cloneExprPlain(expr_id) },
        }
    }

    fn cloneExprValueDemandingKnownValue(self: *Cloner, expr_id: Ast.ExprId) Common.LowerError!Value {
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        const value = blk: switch (expr.data) {
            .call_value => |call| {
                const callee_demand = try self.callableDemandForCalleeExprWithResultDemand(call.callee, .materialize);
                try self.noteLoopDemandIfLocalExpr(call.callee, callee_demand);
                const callee = try self.cloneExprValueWithDemand(call.callee, callee_demand);
                break :blk try self.callKnownValue(expr.ty, callee, call.args, true);
            },
            .call_proc => |call| {
                if (call.is_cold) break :blk try self.cloneExprValue(expr_id);
                if (!self.inline_direct_calls) break :blk try self.cloneExprValue(expr_id);
                break :blk try self.inlineDirectCallValueWithDemand(
                    Ast.callProcCallee(call),
                    call.args,
                    expr_id,
                    .materialize,
                );
            },
            .block => |block| break :blk try self.cloneBlockValueDemandingKnownValue(expr.ty, block),
            .comptime_branch_taken => |taken| break :blk try self.cloneExprValueDemandingKnownValue(taken.body),
            else => break :blk try self.cloneExprValue(expr_id),
        };
        return try self.ensureDemandedKnownValue(value);
    }

    fn activeBreakResultDemand(self: *Cloner, fallback: ValueDemand) ValueDemand {
        if (self.loop_stack.getLastOrNull()) |loop| return loop.result_demand;
        if (self.state_loop_stack.getLastOrNull()) |state_loop| return state_loop.result_demand;
        return fallback;
    }

    fn activeCompactBreakResult(self: *Cloner) ?CompactLoopResult {
        if (self.loop_stack.items.len != 0) return null;
        const state_loop = self.state_loop_stack.getLastOrNull() orelse return null;
        return state_loop.compact_result;
    }

    fn cloneBreakPayloadExpr(self: *Cloner, value: Ast.ExprId, fallback_demand: ValueDemand) Common.LowerError!Ast.ExprId {
        const payload_demand = self.activeBreakResultDemand(fallback_demand);
        const payload = try self.cloneExprValueWithDemand(value, payload_demand);
        if (self.activeCompactBreakResult()) |result| return try self.compactLoopResultExpr(result, payload);
        return try self.materialize(payload);
    }

    fn cloneExprValueWithDemand(self: *Cloner, expr_id: Ast.ExprId, demand: ValueDemand) Common.LowerError!Value {
        const resolved_demand = self.resolveLoopDemandRef(demand);
        return switch (resolved_demand) {
            .none => try self.cloneExprValue(expr_id),
            .materialize => try self.cloneExprValueDemandingKnownValue(expr_id),
            .loop_param => Common.invariant("loop demand reference did not resolve before expression cloning"),
            else => blk: {
                const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
                switch (expr.data) {
                    .local => |local| {
                        if (self.subst.get(local)) |value| break :blk try self.applyValueDemand(value, resolved_demand);
                        break :blk try self.cloneExprValueDemandingKnownValue(expr_id);
                    },
                    .call_proc => |call| {
                        if (call.is_cold) break :blk try self.cloneExprValueDemandingKnownValue(expr_id);
                        if (!self.inline_direct_calls) break :blk try self.cloneExprValueDemandingKnownValue(expr_id);
                        break :blk try self.inlineDirectCallValueWithDemand(
                            Ast.callProcCallee(call),
                            call.args,
                            expr_id,
                            resolved_demand,
                        );
                    },
                    .call_value => |call| {
                        const callee_demand = try self.callableDemandForCalleeExprWithResultDemand(call.callee, resolved_demand);
                        try self.noteLoopDemandIfLocalExpr(call.callee, callee_demand);
                        const callee = try self.cloneExprValueWithDemand(call.callee, callee_demand);
                        break :blk try self.callKnownValueWithDemand(expr.ty, callee, call.args, resolved_demand);
                    },
                    .field_access => |field| break :blk try self.cloneFieldAccessValueWithDemand(expr.ty, field, resolved_demand),
                    .tuple_access => |access| break :blk try self.cloneTupleAccessValueWithDemand(expr.ty, access, resolved_demand),
                    .tag => |tag| break :blk try self.cloneTagValueWithDemand(expr.ty, tag, resolved_demand),
                    .record => |fields_span| break :blk try self.cloneRecordValueWithDemand(expr.ty, fields_span, resolved_demand),
                    .let_ => |let_| break :blk try self.cloneLetValueWithDemand(let_, resolved_demand),
                    .block => |block| break :blk try self.cloneBlockValueWithDemand(expr.ty, block, resolved_demand),
                    .if_ => |if_| break :blk try self.cloneIfValueWithDemand(expr.ty, if_, resolved_demand),
                    .match_ => |match| break :blk try self.cloneMatchValueWithDemand(expr.ty, match, resolved_demand),
                    .loop_ => |loop| break :blk try self.cloneLoopValueWithDemand(expr.ty, loop, resolved_demand),
                    .break_ => |maybe_value| break :blk .{ .expr = try self.addExpr(.{ .ty = expr.ty, .data = .{
                        .break_ = if (maybe_value) |value| try self.cloneBreakPayloadExpr(value, resolved_demand) else null,
                    } }) },
                    .return_ => |value| break :blk .{ .expr = try self.addExpr(.{ .ty = expr.ty, .data = .{
                        .return_ = try self.materialize(try self.cloneExprValueWithDemand(value, resolved_demand)),
                    } }) },
                    .comptime_branch_taken => |taken| break :blk try self.cloneExprValueWithDemand(taken.body, resolved_demand),
                    else => break :blk try self.cloneExprValueDemandingKnownValue(expr_id),
                }
            },
        };
    }

    fn callableDemandForCalleeExpr(self: *Cloner, expr_id: Ast.ExprId) Allocator.Error!ValueDemand {
        if (try self.exprSubstitutedValueNoInline(expr_id)) |value| {
            if (try self.callableDemandForValue(value)) |demand| return demand;
        }

        const known_value = (try self.exprKnownValueNoInline(expr_id)) orelse
            return .{ .callable = .{ .captures = &.{} } };
        return try self.callableDemandForKnownValue(known_value);
    }

    fn callableDemandForCalleeExprWithResultDemand(
        self: *Cloner,
        expr_id: Ast.ExprId,
        result_demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        if (try self.exprSubstitutedValueNoInline(expr_id)) |value| {
            if (try self.callableDemandForValueWithResultDemand(value, result_demand)) |demand| return demand;
        }

        const known_value = (try self.exprKnownValueNoInline(expr_id)) orelse
            return try self.callableDemandWithResult(&.{}, result_demand);
        return try self.callableDemandForKnownValueWithResultDemand(known_value, result_demand);
    }

    fn callableDemandForValue(self: *Cloner, value: Value) Allocator.Error!?ValueDemand {
        return switch (value) {
            .callable => |callable| try self.callableDemandForFn(callable.fn_id, callable.captures.len),
            .finite_callables => |finite_callables| blk: {
                var demand: ValueDemand = .{ .callable = .{ .captures = &.{} } };
                for (finite_callables.alternatives) |alternative| {
                    demand = try self.pass.mergeValueDemand(
                        demand,
                        try self.callableDemandForFn(alternative.fn_id, alternative.captures.len),
                    );
                }
                break :blk demand;
            },
            .private_state => |private_state| try self.callableDemandForPrivateStateValue(private_state),
            else => null,
        };
    }

    fn callableDemandForValueWithResultDemand(
        self: *Cloner,
        value: Value,
        result_demand: ValueDemand,
    ) Allocator.Error!?ValueDemand {
        return switch (value) {
            .callable => |callable| try self.callableDemandForCallableValueWithResultDemand(callable, result_demand),
            .finite_callables => |finite_callables| blk: {
                var demand: ValueDemand = .{ .callable = .{ .captures = &.{} } };
                for (finite_callables.alternatives) |alternative| {
                    demand = try self.pass.mergeValueDemand(
                        demand,
                        try self.callableDemandForCallableValueWithResultDemand(alternative, result_demand),
                    );
                }
                break :blk demand;
            },
            .private_state => |private_state| try self.callableDemandForPrivateStateValueWithResultDemand(private_state, result_demand),
            else => null,
        };
    }

    fn callableDemandForPrivateStateValue(self: *Cloner, value: PrivateStateValue) Allocator.Error!?ValueDemand {
        if (privateStateCallable(value)) |callable| {
            const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
            return try self.callableDemandForFn(callable.fn_id, self.pass.program.typedLocalSpan(source_fn.captures).len);
        }

        if (privateStateFiniteCallables(value)) |finite_callables| {
            var demand: ValueDemand = .{ .callable = .{ .captures = &.{} } };
            for (finite_callables.alternatives) |alternative| {
                const source_fn = self.pass.program.fns.items[@intFromEnum(alternative.fn_id)];
                demand = try self.pass.mergeValueDemand(
                    demand,
                    try self.callableDemandForFn(alternative.fn_id, self.pass.program.typedLocalSpan(source_fn.captures).len),
                );
            }
            return demand;
        }

        return null;
    }

    fn callableDemandForPrivateStateValueWithResultDemand(
        self: *Cloner,
        value: PrivateStateValue,
        result_demand: ValueDemand,
    ) Allocator.Error!?ValueDemand {
        if (privateStateCallable(value)) |callable| {
            return try self.callableDemandForPrivateStateCallableWithResultDemand(callable, result_demand);
        }

        if (privateStateFiniteCallables(value)) |finite_callables| {
            var demand: ValueDemand = .{ .callable = .{ .captures = &.{} } };
            for (finite_callables.alternatives) |alternative| {
                demand = try self.pass.mergeValueDemand(
                    demand,
                    try self.callableDemandForPrivateStateCallableWithResultDemand(alternative, result_demand),
                );
            }
            return demand;
        }

        return null;
    }

    fn callableDemandWithResult(
        self: *Cloner,
        captures: []const ValueDemand,
        result_demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        const result = if (result_demand == .none) null else try self.pass.storedDemand(result_demand);
        return .{ .callable = .{ .captures = captures, .result = result } };
    }

    fn callableDemandForCallableValueWithResultDemand(
        self: *Cloner,
        callable: CallableValue,
        result_demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(source_fn.captures);
        if (source_captures.len != callable.captures.len) {
            Common.invariant("callable value capture count differed from lifted function capture count while computing callable demand");
        }
        if (source_captures.len == 0) return try self.callableDemandWithResult(&.{}, result_demand);

        if (try self.activeCallableDemand(callable.fn_id, result_demand)) |active_demand| return active_demand;
        if (self.demandStackContains(callable.fn_id)) {
            return try self.callableDemandForFnWithResultDemand(callable.fn_id, source_captures.len, result_demand);
        }

        const body = self.demandBody(callable.fn_id) orelse
            return try self.callableDemandForFnWithResultDemand(callable.fn_id, source_captures.len, result_demand);

        const captures = try self.pass.arena.allocator().alloc(ValueDemand, source_captures.len);
        @memset(captures, .none);

        try self.demand_stack.append(self.pass.allocator, .{
            .fn_id = callable.fn_id,
            .result = result_demand,
            .captures = captures,
        });
        defer _ = self.demand_stack.pop();

        while (true) {
            const change_start = self.changes.items.len;
            defer self.restore(change_start);

            for (source_captures, callable.captures) |source_capture, capture| {
                try self.putSubst(source_capture.local, capture);
            }

            var changed = false;
            for (source_captures, captures) |source_capture, *capture_demand| {
                const observed = try self.localDemandInExpr(source_capture.local, body, result_demand);
                const merged = try self.pass.mergeValueDemand(capture_demand.*, observed);
                if (!valueDemandEql(capture_demand.*, merged)) {
                    capture_demand.* = merged;
                    changed = true;
                }
            }

            if (!changed) break;
        }

        var has_capture_demand = false;
        for (captures) |capture_demand| {
            if (capture_demand != .none) {
                has_capture_demand = true;
                break;
            }
        }
        if (!has_capture_demand) return try self.callableDemandWithResult(&.{}, result_demand);
        return try self.callableDemandWithResult(captures, result_demand);
    }

    fn callableDemandForPrivateStateCallableWithResultDemand(
        self: *Cloner,
        callable: PrivateStateCallable,
        result_demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(source_fn.captures);
        if (source_captures.len == 0) return try self.callableDemandWithResult(&.{}, result_demand);

        if (try self.activeCallableDemand(callable.fn_id, result_demand)) |active_demand| return active_demand;
        if (self.demandStackContains(callable.fn_id)) {
            return try self.callableDemandForFnWithResultDemand(callable.fn_id, source_captures.len, result_demand);
        }

        const body = self.demandBody(callable.fn_id) orelse
            return try self.callableDemandForFnWithResultDemand(callable.fn_id, source_captures.len, result_demand);

        const captures = try self.pass.arena.allocator().alloc(ValueDemand, source_captures.len);
        @memset(captures, .none);

        try self.demand_stack.append(self.pass.allocator, .{
            .fn_id = callable.fn_id,
            .result = result_demand,
            .captures = captures,
        });
        defer _ = self.demand_stack.pop();

        while (true) {
            const change_start = self.changes.items.len;
            defer self.restore(change_start);

            for (callable.captures) |capture| {
                if (capture.index >= source_captures.len) Common.invariant("private callable capture index exceeded lifted function capture count");
                try self.putSubst(source_captures[capture.index].local, .{ .private_state = capture.value });
            }

            var changed = false;
            for (source_captures, captures) |source_capture, *capture_demand| {
                const observed = try self.localDemandInExpr(source_capture.local, body, result_demand);
                const merged = try self.pass.mergeValueDemand(capture_demand.*, observed);
                if (!valueDemandEql(capture_demand.*, merged)) {
                    capture_demand.* = merged;
                    changed = true;
                }
            }

            if (!changed) break;
        }

        var has_capture_demand = false;
        for (captures) |capture_demand| {
            if (capture_demand != .none) {
                has_capture_demand = true;
                break;
            }
        }
        if (!has_capture_demand) return try self.callableDemandWithResult(&.{}, result_demand);
        return try self.callableDemandWithResult(captures, result_demand);
    }

    fn callableDemandForKnownValue(self: *Cloner, known_value: KnownValue) Allocator.Error!ValueDemand {
        return switch (known_value) {
            .callable => |callable| try self.callableDemandForFn(callable.fn_id, callable.captures.len),
            .finite_callables => |finite_callables| blk: {
                var demand: ValueDemand = .{ .callable = .{ .captures = &.{} } };
                for (finite_callables.alternatives) |alternative| {
                    demand = try self.pass.mergeValueDemand(
                        demand,
                        try self.callableDemandForFn(alternative.fn_id, alternative.captures.len),
                    );
                }
                break :blk demand;
            },
            else => .materialize,
        };
    }

    fn callableDemandForKnownValueWithResultDemand(
        self: *Cloner,
        known_value: KnownValue,
        result_demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        return switch (known_value) {
            .callable => |callable| try self.callableDemandForFnWithResultDemand(
                callable.fn_id,
                callable.captures.len,
                result_demand,
            ),
            .finite_callables => |finite_callables| blk: {
                var demand: ValueDemand = .{ .callable = .{ .captures = &.{} } };
                for (finite_callables.alternatives) |alternative| {
                    demand = try self.pass.mergeValueDemand(
                        demand,
                        try self.callableDemandForFnWithResultDemand(
                            alternative.fn_id,
                            alternative.captures.len,
                            result_demand,
                        ),
                    );
                }
                break :blk demand;
            },
            else => try self.callableDemandWithResult(&.{}, result_demand),
        };
    }

    fn callableDemandForFnWithResultDemand(
        self: *Cloner,
        fn_id: Ast.FnId,
        capture_count: usize,
        result_demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        const source_fn = self.pass.program.fns.items[@intFromEnum(fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(source_fn.captures);
        const captures = try self.pass.arena.allocator().alloc(ValueDemand, capture_count);
        var has_capture_demand = false;
        for (captures, 0..) |*out, index| {
            if (index < source_captures.len) {
                out.* = try self.functionLocalDemand(fn_id, source_captures[index].local, result_demand);
            } else {
                out.* = .none;
            }
            if (out.* != .none) has_capture_demand = true;
        }
        if (!has_capture_demand) return try self.callableDemandWithResult(&.{}, result_demand);
        return try self.callableDemandWithResult(captures, result_demand);
    }

    fn functionLocalDemand(
        self: *Cloner,
        fn_id: Ast.FnId,
        local: Ast.LocalId,
        result_demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        if (result_demand == .none) return .none;
        for (self.demand_stack.items) |active| {
            if (active.fn_id != fn_id) continue;
            if (active.captures) |captures| {
                if (active.result) |active_result| {
                    if (valueDemandEql(active_result, result_demand)) {
                        return self.activeCaptureDemand(fn_id, local, captures) orelse .none;
                    }
                }
            }
            return self.plannedLocalDemand(fn_id, local);
        }
        const body = self.demandBody(fn_id) orelse return .materialize;

        try self.demand_stack.append(self.pass.allocator, .{ .fn_id = fn_id });
        defer _ = self.demand_stack.pop();

        return try self.localDemandInExpr(local, body, result_demand);
    }

    fn activeCallableDemand(
        self: *Cloner,
        fn_id: Ast.FnId,
        result_demand: ValueDemand,
    ) Allocator.Error!?ValueDemand {
        for (self.demand_stack.items) |active| {
            if (active.fn_id != fn_id) continue;
            const captures = active.captures orelse continue;
            const active_result = active.result orelse continue;
            if (!valueDemandEql(active_result, result_demand)) continue;
            return try self.callableDemandWithResult(captures, result_demand);
        }
        return null;
    }

    fn activeCaptureDemand(
        self: *Cloner,
        fn_id: Ast.FnId,
        local: Ast.LocalId,
        captures: []const ValueDemand,
    ) ?ValueDemand {
        const source_fn = self.pass.program.fns.items[@intFromEnum(fn_id)];
        for (self.pass.program.typedLocalSpan(source_fn.captures), 0..) |capture, index| {
            if (capture.local != local) continue;
            return if (index < captures.len) captures[index] else .none;
        }
        return null;
    }

    fn plannedLocalDemand(self: *Cloner, fn_id: Ast.FnId, local: Ast.LocalId) ValueDemand {
        const raw = @intFromEnum(fn_id);
        if (raw >= self.pass.plans.len) return .materialize;

        const plan = self.pass.plans[raw];
        const fn_ = self.pass.program.fns.items[raw];

        for (self.pass.program.typedLocalSpan(fn_.args), 0..) |arg, index| {
            if (arg.local != local) continue;
            if (index < plan.used_args.len and plan.used_args[index]) return plan.arg_demands[index];
            return .none;
        }

        for (self.pass.program.typedLocalSpan(fn_.captures), 0..) |capture, index| {
            if (capture.local != local) continue;
            if (index < plan.used_captures.len and plan.used_captures[index]) return plan.capture_demands[index];
            return .none;
        }

        return .none;
    }

    fn demandBody(self: *Cloner, fn_id: Ast.FnId) ?Ast.ExprId {
        const source_fn = self.pass.program.fns.items[@intFromEnum(fn_id)];
        const body = self.pass.originalBody(fn_id) orelse switch (source_fn.body) {
            .roc => |body| body,
            .hosted => return null,
        };
        if (exprContainsReturn(self.pass.program, body)) return null;
        return body;
    }

    fn callableDemandForFn(self: *Cloner, fn_id: Ast.FnId, capture_count: usize) Allocator.Error!ValueDemand {
        const raw = @intFromEnum(fn_id);
        if (raw >= self.pass.plans.len) return .{ .callable = .{ .captures = &.{} } };

        const plan = self.pass.plans[raw];
        var has_capture_demand = false;
        const captures = try self.pass.arena.allocator().alloc(ValueDemand, capture_count);
        for (captures, 0..) |*out, index| {
            if (index < plan.used_captures.len and plan.used_captures[index]) {
                out.* = plan.capture_demands[index];
                has_capture_demand = true;
            } else {
                out.* = .none;
            }
        }

        if (!has_capture_demand) return .{ .callable = .{ .captures = &.{} } };
        return .{ .callable = .{ .captures = captures } };
    }

    fn applyValueDemand(self: *Cloner, value: Value, demand: ValueDemand) Common.LowerError!Value {
        const resolved_demand = self.resolveLoopDemandRef(demand);
        return switch (resolved_demand) {
            .none => value,
            .materialize => try self.ensureDemandedKnownValue(value),
            .loop_param => Common.invariant("loop demand reference did not resolve before value demand application"),
            .record,
            .tuple,
            .tag,
            .nominal,
            .callable,
            => blk: {
                switch (value) {
                    .if_ => |if_value| {
                        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
                        for (if_value.branches, branches) |branch, *out| {
                            out.* = .{
                                .cond = branch.cond,
                                .body = try self.applyValueDemand(branch.body, demand),
                            };
                        }
                        const final_else = try self.pass.arena.allocator().create(Value);
                        final_else.* = try self.applyValueDemand(if_value.final_else.*, demand);
                        break :blk Value{ .if_ = .{
                            .ty = if_value.ty,
                            .branches = branches,
                            .final_else = final_else,
                        } };
                    },
                    .match_ => |match_value| {
                        const branches = try self.pass.arena.allocator().alloc(MatchValueBranch, match_value.branches.len);
                        for (match_value.branches, branches) |branch, *out| {
                            out.* = .{
                                .pat = branch.pat,
                                .guard = branch.guard,
                                .body = try self.cloneMatchValueBranchBodyWithDemand(branch, demand),
                                .source = branch.source,
                            };
                        }
                        break :blk Value{ .match_ = .{
                            .ty = match_value.ty,
                            .scrutinee = match_value.scrutinee,
                            .branches = branches,
                            .comptime_site = match_value.comptime_site,
                        } };
                    },
                    else => {},
                }
                var pending_lets = std.ArrayList(PendingLet).empty;
                defer pending_lets.deinit(self.pass.allocator);
                const private_state = (try self.privateStateValueFromValueDemandCollectingLets(value, resolved_demand, &pending_lets)) orelse
                    return try self.ensureDemandedKnownValue(value);
                break :blk try self.wrapPendingLets(.{ .private_state = private_state }, pending_lets.items, true);
            },
        };
    }

    fn cloneMatchValueBranchBodyWithDemand(
        self: *Cloner,
        branch: MatchValueBranch,
        demand: ValueDemand,
    ) Common.LowerError!Value {
        const source = branch.source orelse return try self.applyValueDemand(branch.body, demand);

        const change_start = self.changes.items.len;
        defer self.restore(change_start);

        for (source.bindings) |binding| {
            try self.putSubst(binding.local, binding.value);
        }

        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        const demand_context: ValueDemand = if (demand == .none) .materialize else demand;
        const source_body_demand = try self.matchSourceBodyDemand(source, demand_context);
        var scrutinee_demand = try self.patternDemandInExpr(source.pat, source.body, source_body_demand);
        if (source.guard) |guard| {
            scrutinee_demand = try self.pass.mergeValueDemand(scrutinee_demand, try self.patternDemandInExpr(source.pat, guard, .materialize));
        }
        const demanded_scrutinee = try self.cloneExprValueWithDemand(source.scrutinee, scrutinee_demand);
        const unsafe_count = self.unsafeLeafCount(demanded_scrutinee);
        if (try self.bindPatToMatchValue(source.pat, demanded_scrutinee, source.body, source_body_demand, unsafe_count, &pending_lets) == null) {
            const known_value = (try self.pass.knownValueFromValue(demanded_scrutinee)) orelse source.scrutinee_known_value orelse
                return try self.applyValueDemand(branch.body, demand);
            _ = try self.bindPatToExprWithKnownValueAndValue(source.pat, known_value, demanded_scrutinee);
        }

        const result = try self.cloneMatchSourceBodyReadWithDemand(source, demand);
        return try self.wrapPendingLets(result, pending_lets.items, demand != .none);
    }

    fn matchSourceBodyDemand(
        self: *Cloner,
        source: MatchValueBranchSource,
        demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        return switch (source.read) {
            .none => demand,
            .callable_capture => |capture_read| try self.callableCaptureDemand(capture_read.capture_index, demand),
        };
    }

    fn cloneMatchSourceBodyReadWithDemand(
        self: *Cloner,
        source: MatchValueBranchSource,
        demand: ValueDemand,
    ) Common.LowerError!Value {
        return switch (source.read) {
            .none => try self.cloneExprValueWithDemand(source.body, demand),
            .callable_capture => |capture_read| blk: {
                const capture_demand: ValueDemand = if (demand == .none) .materialize else demand;
                const callable_demand = try self.callableCaptureDemand(capture_read.capture_index, capture_demand);
                const body_value = try self.cloneExprValueWithDemand(source.body, callable_demand);
                break :blk (try self.callableCaptureFromValue(body_value, capture_read.callable, capture_read.capture_index)) orelse
                    Common.invariant("callable capture source read did not produce requested capture");
            },
        };
    }

    fn privateStateValueFromValueDemand(
        self: *Cloner,
        value: Value,
        demand: ValueDemand,
    ) Common.LowerError!?PrivateStateValue {
        return try self.privateStateValueFromValueDemandCollectingLets(value, demand, null);
    }

    fn privateStateValueFromValueDemandCollectingLets(
        self: *Cloner,
        value: Value,
        demand: ValueDemand,
        pending_lets: ?*std.ArrayList(PendingLet),
    ) Common.LowerError!?PrivateStateValue {
        const resolved_demand = self.resolveLoopDemandRef(demand);
        if (value == .let_) {
            const let_value = value.let_;
            const body_private_state = if (pending_lets) |lets| body: {
                try self.appendPendingLetsUnique(lets, let_value.lets);
                break :body (try self.privateStateValueFromValueDemandCollectingLets(let_value.body.*, resolved_demand, lets)) orelse return null;
            } else body: {
                break :body (try self.privateStateValueFromValueDemandCollectingLets(let_value.body.*, resolved_demand, null)) orelse return null;
            };
            if (pending_lets != null) return body_private_state;
            return try self.wrapPendingLetsInPrivateState(body_private_state, let_value.lets);
        }
        if (value == .if_) {
            if (try self.privateStateValueFromIfDemand(value.if_, resolved_demand, pending_lets)) |private_state| return private_state;
        }
        if (value == .match_) {
            if (try self.privateStateValueFromMatchDemand(value.match_, resolved_demand, pending_lets)) |private_state| return private_state;
        }

        return switch (resolved_demand) {
            .none => null,
            .materialize => if (value == .private_state)
                if (privateStateCanMaterializePublic(self.pass.program, value.private_state)) value.private_state else null
            else
                try self.privateStateLeafFromValue(value),
            .loop_param => Common.invariant("loop demand reference did not resolve before private-state construction"),
            .record => |field_demands| blk: {
                var fields = std.ArrayList(PrivateStateField).empty;
                defer fields.deinit(self.pass.allocator);
                for (field_demands) |field_demand| {
                    if (field_demand.demand.* == .none) continue;
                    const field_ty = recordFieldType(self.pass.program, valueType(self.pass.program, value), field_demand.name) orelse
                        break :blk try self.privateStateLeafFromValue(value);
                    const field_value = (try self.fieldFromKnownValue(value, field_demand.name)) orelse
                        fieldFromValue(value, field_demand.name) orelse
                        (try self.fieldFromPatternValue(value, field_demand.name, field_ty)) orelse
                        break :blk try self.privateStateLeafFromValue(value);
                    const field_private_state = (try self.privateStateValueFromValueDemandOrLeafCollectingLets(field_value, field_demand.demand.*, pending_lets)) orelse
                        break :blk try self.privateStateLeafFromValue(value);
                    try fields.append(self.pass.allocator, .{
                        .name = field_demand.name,
                        .value = field_private_state,
                    });
                }
                break :blk PrivateStateValue{ .record = .{
                    .ty = valueType(self.pass.program, value),
                    .fields = try self.pass.arena.allocator().dupe(PrivateStateField, fields.items),
                } };
            },
            .tuple => |item_demands| blk: {
                var items = std.ArrayList(PrivateStateIndexedValue).empty;
                defer items.deinit(self.pass.allocator);
                for (item_demands) |item_demand| {
                    if (item_demand.demand.* == .none) continue;
                    const item_ty = tupleItemType(self.pass.program, valueType(self.pass.program, value), item_demand.index) orelse
                        break :blk try self.privateStateLeafFromValue(value);
                    const item_value = (try self.itemFromKnownValue(value, item_demand.index)) orelse
                        itemFromValue(value, item_demand.index) orelse
                        (try self.itemFromPatternValue(value, item_demand.index, item_ty)) orelse
                        break :blk try self.privateStateLeafFromValue(value);
                    const item_private_state = (try self.privateStateValueFromValueDemandOrLeafCollectingLets(item_value, item_demand.demand.*, pending_lets)) orelse
                        break :blk try self.privateStateLeafFromValue(value);
                    try items.append(self.pass.allocator, .{
                        .index = item_demand.index,
                        .value = item_private_state,
                    });
                }
                break :blk PrivateStateValue{ .tuple = .{
                    .ty = valueType(self.pass.program, value),
                    .items = try self.pass.arena.allocator().dupe(PrivateStateIndexedValue, items.items),
                } };
            },
            .tag => |tag_demand| blk: {
                if (value == .private_state) {
                    if (privateStateFiniteTags(value.private_state)) |finite_tags| {
                        const alternatives = try self.pass.arena.allocator().alloc(PrivateStateTag, finite_tags.alternatives.len);
                        for (finite_tags.alternatives, alternatives) |alternative, *out| {
                            var payloads = std.ArrayList(PrivateStateIndexedValue).empty;
                            defer payloads.deinit(self.pass.allocator);
                            for (tag_demand.payloads) |payload_demand| {
                                if (payload_demand.demand.* == .none) continue;
                                const payload = privateStateIndexedValueByIndex(alternative.payloads, payload_demand.index) orelse break :blk null;
                                const payload_private_state = (try self.privateStateValueFromValueDemandOrLeafCollectingLets(.{ .private_state = payload }, payload_demand.demand.*, pending_lets)) orelse break :blk null;
                                try payloads.append(self.pass.allocator, .{
                                    .index = payload_demand.index,
                                    .value = payload_private_state,
                                });
                            }
                            out.* = .{
                                .ty = alternative.ty,
                                .name = alternative.name,
                                .payloads = try self.pass.arena.allocator().dupe(PrivateStateIndexedValue, payloads.items),
                            };
                        }
                        break :blk PrivateStateValue{ .finite_tags = .{
                            .ty = finite_tags.ty,
                            .selector = finite_tags.selector,
                            .alternatives = alternatives,
                        } };
                    }
                }

                if (value == .finite_tags) {
                    const finite_tags = value.finite_tags;
                    const alternatives = try self.pass.arena.allocator().alloc(PrivateStateTag, finite_tags.alternatives.len);
                    for (finite_tags.alternatives, alternatives) |alternative, *out| {
                        var payloads = std.ArrayList(PrivateStateIndexedValue).empty;
                        defer payloads.deinit(self.pass.allocator);
                        for (tag_demand.payloads) |payload_demand| {
                            if (payload_demand.demand.* == .none) continue;
                            if (payload_demand.index >= alternative.payloads.len) break :blk null;
                            const payload_private_state = (try self.privateStateValueFromValueDemandOrLeafCollectingLets(alternative.payloads[payload_demand.index], payload_demand.demand.*, pending_lets)) orelse break :blk null;
                            try payloads.append(self.pass.allocator, .{
                                .index = payload_demand.index,
                                .value = payload_private_state,
                            });
                        }
                        out.* = .{
                            .ty = alternative.ty,
                            .name = alternative.name,
                            .payloads = try self.pass.arena.allocator().dupe(PrivateStateIndexedValue, payloads.items),
                        };
                    }
                    break :blk PrivateStateValue{ .finite_tags = .{
                        .ty = finite_tags.ty,
                        .selector = finite_tags.selector,
                        .alternatives = alternatives,
                    } };
                }

                const tag = tagFromValue(value) orelse break :blk null;
                var payloads = std.ArrayList(PrivateStateIndexedValue).empty;
                defer payloads.deinit(self.pass.allocator);
                for (tag_demand.payloads) |payload_demand| {
                    if (payload_demand.demand.* == .none) continue;
                    if (payload_demand.index >= tag.payloads.len) break :blk null;
                    const payload_private_state = (try self.privateStateValueFromValueDemandOrLeafCollectingLets(tag.payloads[payload_demand.index], payload_demand.demand.*, pending_lets)) orelse break :blk null;
                    try payloads.append(self.pass.allocator, .{
                        .index = payload_demand.index,
                        .value = payload_private_state,
                    });
                }
                break :blk PrivateStateValue{ .tag = .{
                    .ty = tag.ty,
                    .name = tag.name,
                    .payloads = try self.pass.arena.allocator().dupe(PrivateStateIndexedValue, payloads.items),
                } };
            },
            .nominal => |backing_demand| blk: {
                const nominal_ty = switch (value) {
                    .nominal => |nominal| nominal.ty,
                    .private_state => |private_state| switch (private_state) {
                        .nominal => |nominal| nominal.ty,
                        else => break :blk null,
                    },
                    else => break :blk null,
                };
                const backing_value = switch (value) {
                    .nominal => |value_nominal| value_nominal.backing.*,
                    .private_state => switch (value.private_state) {
                        .nominal => |private_nominal| if (private_nominal.backing) |backing| Value{ .private_state = backing.* } else break :blk null,
                        else => break :blk null,
                    },
                    else => break :blk null,
                };
                const backing_private_state = (try self.privateStateValueFromValueDemandOrLeafCollectingLets(backing_value, backing_demand.*, pending_lets)) orelse break :blk null;
                const backing = try self.pass.arena.allocator().create(PrivateStateValue);
                backing.* = backing_private_state;
                break :blk PrivateStateValue{ .nominal = .{
                    .ty = nominal_ty,
                    .backing = backing,
                } };
            },
            .callable => |callable_demand| blk: {
                var effective_callable_demand = callable_demand;
                if (callable_demand.result) |result_demand| {
                    const concrete_demand = switch (value) {
                        .callable => |callable| try self.callableDemandForCallableValueWithResultDemand(callable, result_demand.*),
                        .finite_callables => |finite_callables| concrete: {
                            var alternative_demand: ValueDemand = .{ .callable = .{ .captures = &.{} } };
                            for (finite_callables.alternatives) |alternative| {
                                alternative_demand = try self.pass.mergeValueDemand(
                                    alternative_demand,
                                    try self.callableDemandForCallableValueWithResultDemand(alternative, result_demand.*),
                                );
                            }
                            break :concrete alternative_demand;
                        },
                        .private_state => |private_state| try self.callableDemandForPrivateStateValueWithResultDemand(
                            private_state,
                            result_demand.*,
                        ) orelse null,
                        else => null,
                    };
                    if (concrete_demand) |concrete| {
                        const merged = try self.pass.mergeValueDemand(.{ .callable = callable_demand }, concrete);
                        if (merged == .callable) effective_callable_demand = merged.callable;
                    }

                    if (value == .private_state) {
                        if (privateStateCallable(value.private_state)) |private_callable| {
                            if (private_callable.captures.len > 0) {
                                const carry_demand = try self.valueDemandFromPrivateCallableShape(private_callable);
                                if (carry_demand == .callable) {
                                    const merged = try self.pass.mergeValueDemand(.{ .callable = effective_callable_demand }, carry_demand);
                                    if (merged == .callable) effective_callable_demand = merged.callable;
                                }
                            }
                        }
                    }
                    if (value == .callable) {
                        if (value.callable.captures.len > 0) {
                            const carry_demand = try self.valueDemandFromCallableValueShape(value.callable);
                            if (carry_demand == .callable) {
                                const merged = try self.pass.mergeValueDemand(.{ .callable = effective_callable_demand }, carry_demand);
                                if (merged == .callable) effective_callable_demand = merged.callable;
                            }
                        }
                    }
                    if (value == .finite_callables) {
                        const carry_demand = try self.valueDemandFromValueShape(value);
                        if (carry_demand == .callable) {
                            const merged = try self.pass.mergeValueDemand(.{ .callable = effective_callable_demand }, carry_demand);
                            if (merged == .callable) effective_callable_demand = merged.callable;
                        }
                    }
                }

                if (value == .private_state) {
                    if (privateStateLeafExpr(value.private_state) != null) break :blk value.private_state;
                    if (privateStateFiniteCallables(value.private_state)) |finite_callables| {
                        const alternatives = try self.pass.arena.allocator().alloc(PrivateStateCallable, finite_callables.alternatives.len);
                        for (finite_callables.alternatives, alternatives) |alternative, *out| {
                            var captures = std.ArrayList(PrivateStateIndexedValue).empty;
                            defer captures.deinit(self.pass.allocator);
                            for (effective_callable_demand.captures, 0..) |capture_demand, index| {
                                if (capture_demand == .none) continue;
                                const capture_value = (try self.privateStateCallableCaptureValue(alternative, index)) orelse {
                                    break :blk null;
                                };
                                const capture_private_state = (try self.privateStateValueFromValueDemandOrLeafCollectingLets(capture_value, capture_demand, pending_lets)) orelse {
                                    break :blk null;
                                };
                                try captures.append(self.pass.allocator, .{
                                    .index = @intCast(index),
                                    .value = capture_private_state,
                                });
                            }
                            out.* = .{
                                .ty = alternative.ty,
                                .fn_id = alternative.fn_id,
                                .captures = try self.pass.arena.allocator().dupe(PrivateStateIndexedValue, captures.items),
                            };
                        }
                        break :blk PrivateStateValue{ .finite_callables = .{
                            .ty = finite_callables.ty,
                            .selector = finite_callables.selector,
                            .alternatives = alternatives,
                        } };
                    }
                }

                if (value == .finite_callables) {
                    const finite_callables = value.finite_callables;
                    const alternatives = try self.pass.arena.allocator().alloc(PrivateStateCallable, finite_callables.alternatives.len);
                    for (finite_callables.alternatives, alternatives) |alternative, *out| {
                        var captures = std.ArrayList(PrivateStateIndexedValue).empty;
                        defer captures.deinit(self.pass.allocator);
                        for (alternative.captures, 0..) |capture_value, index| {
                            const capture_demand = if (index < effective_callable_demand.captures.len)
                                effective_callable_demand.captures[index]
                            else
                                .none;
                            if (capture_demand == .none) continue;
                            const capture_private_state = (try self.privateStateValueFromValueDemandOrLeafCollectingLets(capture_value, capture_demand, pending_lets)) orelse break :blk null;
                            try captures.append(self.pass.allocator, .{
                                .index = @intCast(index),
                                .value = capture_private_state,
                            });
                        }
                        out.* = .{
                            .ty = alternative.ty,
                            .fn_id = alternative.fn_id,
                            .captures = try self.pass.arena.allocator().dupe(PrivateStateIndexedValue, captures.items),
                        };
                    }
                    break :blk PrivateStateValue{ .finite_callables = .{
                        .ty = finite_callables.ty,
                        .selector = finite_callables.selector,
                        .alternatives = alternatives,
                    } };
                }

                const callable_ty = switch (value) {
                    .callable => |callable| callable.ty,
                    .private_state => |private_state| (privateStateCallable(private_state) orelse break :blk null).ty,
                    else => break :blk null,
                };
                const callable_fn_id = switch (value) {
                    .callable => |callable| callable.fn_id,
                    .private_state => |private_state| (privateStateCallable(private_state) orelse break :blk null).fn_id,
                    else => break :blk null,
                };
                var captures = std.ArrayList(PrivateStateIndexedValue).empty;
                defer captures.deinit(self.pass.allocator);
                const capture_count = switch (value) {
                    .callable => |callable_value| callable_value.captures.len,
                    .private_state => |private_state| if (privateStateCallable(private_state)) |private_callable| self.pass.program.typedLocalSpan(self.pass.program.fns.items[@intFromEnum(private_callable.fn_id)].captures).len else 0,
                    else => 0,
                };
                var index: usize = 0;
                while (index < capture_count) : (index += 1) {
                    const capture_demand = if (index < effective_callable_demand.captures.len)
                        effective_callable_demand.captures[index]
                    else
                        .none;
                    if (capture_demand == .none) continue;
                    const capture_value = switch (value) {
                        .callable => |callable_value| callable_value.captures[index],
                        .private_state => |private_state| blk_capture: {
                            const private_callable = privateStateCallable(private_state) orelse break :blk null;
                            break :blk_capture (try self.privateStateCallableCaptureValue(private_callable, index)) orelse {
                                break :blk null;
                            };
                        },
                        else => break :blk null,
                    };
                    const capture_private_state = (try self.privateStateValueFromValueDemandOrLeafCollectingLets(capture_value, capture_demand, pending_lets)) orelse {
                        break :blk null;
                    };
                    try captures.append(self.pass.allocator, .{
                        .index = @intCast(index),
                        .value = capture_private_state,
                    });
                }
                const private_captures = try self.pass.arena.allocator().dupe(PrivateStateIndexedValue, captures.items);
                break :blk PrivateStateValue{ .callable = .{
                    .ty = callable_ty,
                    .fn_id = callable_fn_id,
                    .captures = private_captures,
                } };
            },
        };
    }

    fn valueDemandFromPrivateCallableShape(
        self: *Cloner,
        callable: PrivateStateCallable,
    ) Allocator.Error!ValueDemand {
        var captures_len: usize = 0;
        for (callable.captures) |capture| {
            captures_len = @max(captures_len, @as(usize, capture.index) + 1);
        }

        const captures = try self.pass.arena.allocator().alloc(ValueDemand, captures_len);
        @memset(captures, .none);
        for (callable.captures) |capture| {
            captures[capture.index] = try self.valueDemandFromPrivateStateShape(capture.value);
        }

        return .{ .callable = .{ .captures = captures } };
    }

    fn valueDemandFromPrivateStateShape(
        self: *Cloner,
        value: PrivateStateValue,
    ) Allocator.Error!ValueDemand {
        return switch (value) {
            .leaf => .materialize,
            .record => |record| blk: {
                const fields = try self.pass.arena.allocator().alloc(FieldDemand, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    out.* = .{
                        .name = field.name,
                        .demand = try self.pass.storedDemand(try self.valueDemandFromPrivateStateShape(field.value)),
                    };
                }
                break :blk ValueDemand{ .record = fields };
            },
            .tuple => |tuple| blk: {
                const items = try self.pass.arena.allocator().alloc(ItemDemand, tuple.items.len);
                for (tuple.items, items) |item, *out| {
                    out.* = .{
                        .index = item.index,
                        .demand = try self.pass.storedDemand(try self.valueDemandFromPrivateStateShape(item.value)),
                    };
                }
                break :blk ValueDemand{ .tuple = items };
            },
            .tag => |tag| blk: {
                const payloads = try self.pass.arena.allocator().alloc(ItemDemand, tag.payloads.len);
                for (tag.payloads, payloads) |payload, *out| {
                    out.* = .{
                        .index = payload.index,
                        .demand = try self.pass.storedDemand(try self.valueDemandFromPrivateStateShape(payload.value)),
                    };
                }
                break :blk ValueDemand{ .tag = .{ .payloads = payloads } };
            },
            .nominal => |nominal| if (nominal.backing) |backing|
                ValueDemand{ .nominal = try self.pass.storedDemand(try self.valueDemandFromPrivateStateShape(backing.*)) }
            else
                .materialize,
            .callable => |callable| try self.valueDemandFromPrivateCallableShape(callable),
            .finite_tags => |finite_tags| blk: {
                var demand: ValueDemand = .none;
                for (finite_tags.alternatives) |alternative| {
                    demand = try self.mergeValueDemand(demand, try self.valueDemandFromPrivateStateShape(.{ .tag = alternative }));
                }
                break :blk demand;
            },
            .finite_callables => |finite_callables| blk: {
                var demand: ValueDemand = .none;
                for (finite_callables.alternatives) |alternative| {
                    demand = try self.mergeValueDemand(demand, try self.valueDemandFromPrivateStateShape(.{ .callable = alternative }));
                }
                break :blk demand;
            },
        };
    }

    fn privateStateValueFromValueDemandOrLeafCollectingLets(
        self: *Cloner,
        value: Value,
        demand: ValueDemand,
        pending_lets: ?*std.ArrayList(PendingLet),
    ) Common.LowerError!?PrivateStateValue {
        if (try self.privateStateValueFromValueDemandCollectingLets(value, demand, pending_lets)) |private_state| return private_state;
        return try self.privateStateLeafFromValue(value);
    }

    fn privateStateCallableCaptureValue(
        self: *Cloner,
        callable: PrivateStateCallable,
        index: usize,
    ) Common.LowerError!?Value {
        if (privateStateIndexedValueByIndex(callable.captures, @intCast(index))) |capture| {
            return Value{ .private_state = capture };
        }

        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(source_fn.captures);
        if (index >= source_captures.len) {
            Common.invariant("private callable capture index exceeded lifted function capture count");
        }

        return self.subst.get(source_captures[index].local);
    }

    fn wrapPendingLetsInPrivateState(
        self: *Cloner,
        value: PrivateStateValue,
        pending_lets: []const PendingLet,
    ) Common.LowerError!PrivateStateValue {
        if (pending_lets.len == 0) return value;

        return switch (value) {
            .leaf => |leaf| .{ .leaf = .{
                .ty = leaf.ty,
                .expr = try self.wrapPendingLetsAroundExpr(leaf.ty, leaf.expr, pending_lets),
            } },
            .tag => |tag| blk: {
                const payloads = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, tag.payloads.len);
                for (tag.payloads, payloads) |payload, *out| {
                    out.* = .{
                        .index = payload.index,
                        .value = try self.wrapPendingLetsInPrivateState(payload.value, pending_lets),
                    };
                }
                break :blk PrivateStateValue{ .tag = .{
                    .ty = tag.ty,
                    .name = tag.name,
                    .payloads = payloads,
                } };
            },
            .record => |record| blk: {
                const fields = try self.pass.arena.allocator().alloc(PrivateStateField, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    out.* = .{
                        .name = field.name,
                        .value = try self.wrapPendingLetsInPrivateState(field.value, pending_lets),
                    };
                }
                break :blk PrivateStateValue{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| blk: {
                const items = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, tuple.items.len);
                for (tuple.items, items) |item, *out| {
                    out.* = .{
                        .index = item.index,
                        .value = try self.wrapPendingLetsInPrivateState(item.value, pending_lets),
                    };
                }
                break :blk PrivateStateValue{ .tuple = .{
                    .ty = tuple.ty,
                    .items = items,
                } };
            },
            .nominal => |nominal| blk: {
                const backing = if (nominal.backing) |backing_value| backing: {
                    const stored = try self.pass.arena.allocator().create(PrivateStateValue);
                    stored.* = try self.wrapPendingLetsInPrivateState(backing_value.*, pending_lets);
                    break :backing stored;
                } else null;
                break :blk PrivateStateValue{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = backing,
                } };
            },
            .callable => |callable| blk: {
                const captures = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, callable.captures.len);
                for (callable.captures, captures) |capture, *out| {
                    out.* = .{
                        .index = capture.index,
                        .value = try self.wrapPendingLetsInPrivateState(capture.value, pending_lets),
                    };
                }
                break :blk PrivateStateValue{ .callable = .{
                    .ty = callable.ty,
                    .fn_id = callable.fn_id,
                    .captures = captures,
                } };
            },
            .finite_tags => |finite_tags| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(PrivateStateTag, finite_tags.alternatives.len);
                for (finite_tags.alternatives, alternatives) |alternative, *out| {
                    const payloads = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, alternative.payloads.len);
                    for (alternative.payloads, payloads) |payload, *payload_out| {
                        payload_out.* = .{
                            .index = payload.index,
                            .value = try self.wrapPendingLetsInPrivateState(payload.value, pending_lets),
                        };
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .name = alternative.name,
                        .payloads = payloads,
                    };
                }
                break :blk PrivateStateValue{ .finite_tags = .{
                    .ty = finite_tags.ty,
                    .selector = try self.wrapPendingLetsAroundExpr(try self.pass.primitiveType(.u64), finite_tags.selector, pending_lets),
                    .alternatives = alternatives,
                } };
            },
            .finite_callables => |finite_callables| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(PrivateStateCallable, finite_callables.alternatives.len);
                for (finite_callables.alternatives, alternatives) |alternative, *out| {
                    const captures = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, alternative.captures.len);
                    for (alternative.captures, captures) |capture, *capture_out| {
                        capture_out.* = .{
                            .index = capture.index,
                            .value = try self.wrapPendingLetsInPrivateState(capture.value, pending_lets),
                        };
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .fn_id = alternative.fn_id,
                        .captures = captures,
                    };
                }
                break :blk PrivateStateValue{ .finite_callables = .{
                    .ty = finite_callables.ty,
                    .selector = try self.wrapPendingLetsAroundExpr(try self.pass.primitiveType(.u64), finite_callables.selector, pending_lets),
                    .alternatives = alternatives,
                } };
            },
        };
    }

    fn privateStateLeafFromValue(self: *Cloner, value: Value) Common.LowerError!?PrivateStateValue {
        if (value == .private_state) {
            const expr = privateStateLeafExpr(value.private_state) orelse return null;
            return .{ .leaf = .{
                .ty = privateStateValueType(value.private_state),
                .expr = expr,
            } };
        }
        switch (value) {
            .let_,
            .if_,
            .match_,
            => return null,
            else => {},
        }

        const ty = valueType(self.pass.program, value);
        return .{ .leaf = .{
            .ty = ty,
            .expr = try self.materializePublic(value),
        } };
    }

    fn cloneFieldAccessValueWithDemand(self: *Cloner, ty: Type.TypeId, field: anytype, demand: ValueDemand) Common.LowerError!Value {
        const receiver_demand = try self.pass.demandRecordField(field.field, demand);
        const receiver = try self.cloneExprValueWithDemand(field.receiver, receiver_demand);
        if (try self.fieldFromKnownValue(receiver, field.field)) |value| return try self.applyValueDemand(value, demand);
        if (try self.fieldFromPatternValue(receiver, field.field, ty)) |value| return try self.applyValueDemand(value, demand);
        return try self.cloneExprValueDemandingKnownValue(try self.addExpr(.{ .ty = ty, .data = .{ .field_access = .{
            .receiver = try self.materialize(receiver),
            .field = field.field,
        } } }));
    }

    fn cloneTupleAccessValueWithDemand(self: *Cloner, ty: Type.TypeId, access: anytype, demand: ValueDemand) Common.LowerError!Value {
        const receiver_demand = try self.pass.demandTupleItem(access.elem_index, demand);
        const receiver = try self.cloneExprValueWithDemand(access.tuple, receiver_demand);
        if (try self.itemFromKnownValue(receiver, access.elem_index)) |value| return try self.applyValueDemand(value, demand);
        if (try self.itemFromPatternValue(receiver, access.elem_index, ty)) |value| return try self.applyValueDemand(value, demand);
        return try self.cloneExprValueDemandingKnownValue(try self.addExpr(.{ .ty = ty, .data = .{ .tuple_access = .{
            .tuple = try self.materialize(receiver),
            .elem_index = access.elem_index,
        } } }));
    }

    fn cloneTagValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        tag: anytype,
        demand: ValueDemand,
    ) Common.LowerError!Value {
        const tag_demand = switch (demand) {
            .tag => |tag_demand| tag_demand,
            else => return try self.cloneExprValueDemandingKnownValue(try self.addExpr(.{ .ty = ty, .data = .{
                .tag = tag,
            } })),
        };

        const source_payloads = try self.pass.allocator.dupe(Ast.ExprId, self.pass.program.exprSpan(tag.payloads));
        defer self.pass.allocator.free(source_payloads);

        for (source_payloads, 0..) |payload, index| {
            if (itemDemandByIndex(tag_demand.payloads, @intCast(index)) != null) continue;
            if (!discardedExprIsEffectFree(self.pass.program, payload)) {
                return try self.cloneExprValueDemandingKnownValue(try self.addExpr(.{ .ty = ty, .data = .{
                    .tag = tag,
                } }));
            }
        }

        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        var payloads = std.ArrayList(PrivateStateIndexedValue).empty;
        defer payloads.deinit(self.pass.allocator);
        for (tag_demand.payloads) |payload_demand| {
            if (payload_demand.demand.* == .none) continue;
            if (payload_demand.index >= source_payloads.len) continue;
            const payload_value = try self.cloneExprValueWithDemand(source_payloads[payload_demand.index], payload_demand.demand.*);
            const payload_private_state = (try self.privateStateValueFromValueDemandCollectingLets(payload_value, payload_demand.demand.*, &pending_lets)) orelse
                return try self.cloneExprValueDemandingKnownValue(try self.addExpr(.{ .ty = ty, .data = .{
                    .tag = tag,
                } }));
            try payloads.append(self.pass.allocator, .{
                .index = payload_demand.index,
                .value = payload_private_state,
            });
        }

        return try self.wrapPendingLets(.{ .private_state = .{ .tag = .{
            .ty = ty,
            .name = tag.name,
            .payloads = try self.pass.arena.allocator().dupe(PrivateStateIndexedValue, payloads.items),
        } } }, pending_lets.items, true);
    }

    fn cloneRecordValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        fields_span: Ast.Span(Ast.FieldExpr),
        demand: ValueDemand,
    ) Common.LowerError!Value {
        const field_demands = switch (demand) {
            .record => |field_demands| field_demands,
            else => return try self.cloneExprValueDemandingKnownValue(try self.addExpr(.{ .ty = ty, .data = .{
                .record = fields_span,
            } })),
        };

        const source_fields = try self.pass.allocator.dupe(Ast.FieldExpr, self.pass.program.fieldExprSpan(fields_span));
        defer self.pass.allocator.free(source_fields);

        for (source_fields) |field| {
            if (fieldDemandByName(field_demands, field.name) != null) continue;
            if (!discardedExprIsEffectFree(self.pass.program, field.value)) {
                return try self.cloneExprValueDemandingKnownValue(try self.addExpr(.{ .ty = ty, .data = .{
                    .record = fields_span,
                } }));
            }
        }

        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        var fields = std.ArrayList(PrivateStateField).empty;
        defer fields.deinit(self.pass.allocator);
        for (source_fields) |field| {
            const field_demand = fieldDemandByName(field_demands, field.name) orelse continue;
            if (field_demand.demand.* == .none) continue;
            const field_value = try self.cloneExprValueWithDemand(field.value, field_demand.demand.*);
            const field_private_state = (try self.privateStateValueFromValueDemandOrLeafCollectingLets(field_value, field_demand.demand.*, &pending_lets)) orelse {
                return try self.cloneExprValueDemandingKnownValue(try self.addExpr(.{ .ty = ty, .data = .{
                    .record = fields_span,
                } }));
            };
            try fields.append(self.pass.allocator, .{
                .name = field.name,
                .value = field_private_state,
            });
        }

        return try self.wrapPendingLets(.{ .private_state = .{ .record = .{
            .ty = ty,
            .fields = try self.pass.arena.allocator().dupe(PrivateStateField, fields.items),
        } } }, pending_lets.items, true);
    }

    fn cloneLetValueWithDemand(self: *Cloner, let_: anytype, demand: ValueDemand) Common.LowerError!Value {
        const value_demand = try self.patternDemandInExpr(let_.bind, let_.rest, demand);
        const raw_value = try self.cloneExprValueWithDemand(let_.value, value_demand);
        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        const pending_change_start = self.changes.items.len;
        var value = raw_value;
        while (value == .let_) {
            try pending_lets.appendSlice(self.pass.allocator, value.let_.lets);
            try self.bindPendingLetKnownValues(value.let_.lets);
            value = value.let_.body.*;
        }

        const reusable = try self.makeReusableForMatch(value, &pending_lets);
        const bind_change_start = self.changes.items.len;
        if (try self.bindPatToReusableValue(let_.bind, reusable)) {
            const rest = try self.cloneExprValueWithDemand(let_.rest, demand);
            self.restore(pending_change_start);
            return try self.wrapPendingLets(rest, pending_lets.items, demand != .none);
        }
        self.restore(bind_change_start);

        if (try self.bindPatToSingleUseRestValue(let_.bind, value, let_.rest)) {
            const rest = try self.cloneExprValueWithDemand(let_.rest, demand);
            self.restore(pending_change_start);
            return try self.wrapPendingLets(rest, pending_lets.items, demand != .none);
        }
        self.restore(pending_change_start);

        const value_expr = try self.materialize(raw_value);
        const change_start = self.changes.items.len;
        if (try self.bindPatToMaterializedKnownValue(let_.bind, raw_value)) {
            const rest_value = try self.cloneExprValueWithDemand(let_.rest, demand);
            const rest = try self.materialize(rest_value);
            self.restore(change_start);
            return .{ .expr = try self.addExpr(.{ .ty = self.pass.program.exprs.items[@intFromEnum(let_.rest)].ty, .data = .{ .let_ = .{
                .bind = try self.clonePat(let_.bind),
                .value = value_expr,
                .rest = rest,
                .comptime_site = let_.comptime_site,
            } } }) };
        }
        self.restore(change_start);
        return .{ .expr = try self.addExpr(.{ .ty = self.pass.program.exprs.items[@intFromEnum(let_.rest)].ty, .data = .{ .let_ = .{
            .bind = try self.clonePat(let_.bind),
            .value = value_expr,
            .rest = try self.cloneExpr(let_.rest),
            .comptime_site = let_.comptime_site,
        } } }) };
    }

    fn cloneBlockValueWithDemand(self: *Cloner, ty: Type.TypeId, block: anytype, demand: ValueDemand) Common.LowerError!Value {
        const change_start = self.changes.items.len;
        defer self.restore(change_start);
        const provenance_start = self.loopProvenanceLen();
        defer self.restoreLoopProvenance(provenance_start);

        const source = try self.pass.allocator.dupe(Ast.StmtId, self.pass.program.stmtSpan(block.statements));
        defer self.pass.allocator.free(source);

        var statements = std.ArrayList(Ast.StmtId).empty;
        defer statements.deinit(self.pass.allocator);
        for (source, 0..) |stmt, index| {
            try self.cloneStmtInto(stmt, &statements, .{
                .statements = source[index + 1 ..],
                .final_expr = block.final_expr,
            }, demand);
        }

        const final_value = try self.cloneExprValueWithDemand(block.final_expr, demand);
        if (statements.items.len == 0) return final_value;

        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);
        if (try self.appendPendingLetsFromStatements(statements.items, &pending_lets)) {
            return try self.wrapPendingLets(final_value, pending_lets.items, demand != .none);
        }

        const final_expr = try self.materialize(final_value);
        return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .block = .{
            .statements = try self.pass.program.addStmtSpan(statements.items),
            .final_expr = final_expr,
        } } }) };
    }

    fn cloneIfValueWithDemand(self: *Cloner, ty: Type.TypeId, if_: anytype, demand: ValueDemand) Common.LowerError!Value {
        const source_branches = try self.pass.allocator.dupe(Ast.IfBranch, self.pass.program.ifBranchSpan(if_.branches));
        defer self.pass.allocator.free(source_branches);

        return try self.cloneIfValueWithDemandFromBranches(ty, source_branches, 0, if_.final_else, demand);
    }

    fn cloneIfValueWithDemandFromBranches(
        self: *Cloner,
        ty: Type.TypeId,
        source_branches: []const Ast.IfBranch,
        index: usize,
        final_else_expr: Ast.ExprId,
        demand: ValueDemand,
    ) Common.LowerError!Value {
        if (index == source_branches.len) {
            return try self.cloneExprValueWithDemand(final_else_expr, demand);
        }

        const branch = source_branches[index];
        const cond_value = try self.cloneExprValueDemandingKnownValue(branch.cond);
        if (knownIfConditionBoolTag(self.pass.program, cond_value)) |cond| {
            if (cond) return try self.cloneScopedExprValueWithDemand(branch.body, demand);
            return try self.cloneIfValueWithDemandFromBranches(ty, source_branches, index + 1, final_else_expr, demand);
        }
        if (finiteBoolTagsValue(self.pass.program, cond_value)) |finite_bool| {
            const true_value = try self.cloneScopedExprValueWithDemand(branch.body, demand);
            const false_value = try self.cloneIfValueWithDemandFromBranches(ty, source_branches, index + 1, final_else_expr, demand);
            return try self.selectFiniteBoolValue(ty, finite_bool, true_value, false_value);
        }

        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, 1);
        branches[0] = .{
            .cond = try self.materialize(cond_value),
            .body = try self.cloneScopedExprValueWithDemand(branch.body, demand),
        };
        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = try self.cloneIfValueWithDemandFromBranches(ty, source_branches, index + 1, final_else_expr, demand);
        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn cloneScopedExprValueWithDemand(self: *Cloner, expr_id: Ast.ExprId, demand: ValueDemand) Common.LowerError!Value {
        const change_start = self.changes.items.len;
        const value = try self.cloneExprValueWithDemand(expr_id, demand);
        self.restore(change_start);
        return value;
    }

    fn ensureDemandedKnownValue(self: *Cloner, value: Value) Common.LowerError!Value {
        if ((try self.pass.knownValueFromValue(value)) != null) return value;
        return switch (value) {
            .expr => |expr| blk: {
                const ty = self.pass.program.exprs.items[@intFromEnum(expr)].ty;
                if (try typeMayContainRefcounted(self.pass.program, ty)) break :blk value;
                break :blk Value{ .expr_with_known_value = .{
                    .expr = expr,
                    .known_value = .{ .leaf = ty },
                } };
            },
            .let_ => |let_value| blk: {
                const body = try self.ensureDemandedKnownValue(let_value.body.*);
                break :blk Value{ .let_ = .{
                    .lets = let_value.lets,
                    .body = try self.copyValue(body),
                } };
            },
            else => value,
        };
    }

    fn directCallHasKnownValueArg(self: *Cloner, args_span: Ast.Span(Ast.ExprId)) Allocator.Error!bool {
        for (self.pass.program.exprSpan(args_span)) |arg| {
            if (try self.exprHasKnownValue(arg)) return true;
        }
        return false;
    }

    fn directCallActiveArgKnownValues(self: *Cloner, args_span: Ast.Span(Ast.ExprId)) Allocator.Error![]const KnownValue {
        const args = self.pass.program.exprSpan(args_span);
        const known_values = try self.pass.arena.allocator().alloc(KnownValue, args.len);
        for (args, 0..) |arg, index| {
            known_values[index] = (try self.exprKnownValueNoInline(arg)) orelse .{
                .any = self.pass.program.exprs.items[@intFromEnum(arg)].ty,
            };
        }
        return known_values;
    }

    fn exprKnownValueNoInline(self: *Cloner, expr_id: Ast.ExprId) Allocator.Error!?KnownValue {
        if (try self.exprSubstitutedValueNoInline(expr_id)) |value| {
            if (try self.pass.knownValueFromValue(value)) |known_value| return known_value;
        }

        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        return switch (expr.data) {
            .local => null,
            .fn_ref => |fn_id| try self.knownCallable(expr.ty, fn_id),
            .tag,
            .record,
            .tuple,
            .nominal,
            .unit,
            .int_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .dec_lit,
            .str_lit,
            .static_data,
            .list,
            => try self.pass.constructorKnownValue(expr_id),
            .comptime_branch_taken => |taken| try self.exprKnownValueNoInline(taken.body),
            else => null,
        };
    }

    fn exprSubstitutedValueNoInline(self: *Cloner, expr_id: Ast.ExprId) Allocator.Error!?Value {
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        return switch (expr.data) {
            .local => |local| self.subst.get(local),
            .field_access => |field| blk: {
                const receiver = (try self.exprSubstitutedValueNoInline(field.receiver)) orelse break :blk null;
                break :blk fieldFromValue(receiver, field.field);
            },
            .tuple_access => |access| blk: {
                const tuple = (try self.exprSubstitutedValueNoInline(access.tuple)) orelse break :blk null;
                break :blk itemFromValue(tuple, access.elem_index);
            },
            .comptime_branch_taken => |taken| try self.exprSubstitutedValueNoInline(taken.body),
            else => null,
        };
    }

    fn exprValueForDemandNoInline(self: *Cloner, expr_id: Ast.ExprId) Allocator.Error!Value {
        if (try self.exprSubstitutedValueNoInline(expr_id)) |value| return value;
        if (try self.exprKnownValueNoInline(expr_id)) |known_value| {
            return .{ .expr_with_known_value = .{
                .expr = expr_id,
                .known_value = known_value,
            } };
        }
        return .{ .expr = expr_id };
    }

    fn demandStackContains(self: *Cloner, fn_id: Ast.FnId) bool {
        for (self.demand_stack.items) |active| {
            if (active.fn_id == fn_id) return true;
        }
        return false;
    }

    fn exprHasKnownValue(self: *Cloner, expr_id: Ast.ExprId) Allocator.Error!bool {
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        return switch (expr.data) {
            .local => |local| if (self.subst.get(local)) |value|
                (try self.pass.knownValueFromValue(value)) != null
            else
                false,
            .fn_ref => true,
            .tag,
            .record,
            .tuple,
            .nominal,
            .unit,
            .int_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .dec_lit,
            .str_lit,
            .static_data,
            .list,
            => (try self.pass.constructorKnownValue(expr_id)) != null,
            .static_data_candidate => true,
            .field_access => |field| blk: {
                const receiver_local = localExpr(self.pass.program, field.receiver) orelse break :blk false;
                const receiver = self.subst.get(receiver_local) orelse break :blk false;
                const value = fieldFromValue(receiver, field.field) orelse break :blk false;
                break :blk (try self.pass.knownValueFromValue(value)) != null;
            },
            .tuple_access => |access| blk: {
                const tuple_local = localExpr(self.pass.program, access.tuple) orelse break :blk false;
                const tuple = self.subst.get(tuple_local) orelse break :blk false;
                const value = itemFromValue(tuple, access.elem_index) orelse break :blk false;
                break :blk (try self.pass.knownValueFromValue(value)) != null;
            },
            .comptime_branch_taken => |taken| try self.exprHasKnownValue(taken.body),
            .comptime_exhaustiveness_failed => false,
            else => false,
        };
    }

    fn valueCanSubstitute(self: *Cloner, value: Value) bool {
        return switch (value) {
            .expr => |expr| self.exprCanSubstitute(expr),
            .let_ => false,
            .if_ => |if_value| blk: {
                for (if_value.branches) |branch| {
                    if (!self.exprCanSubstitute(branch.cond) or !self.valueCanSubstitute(branch.body)) break :blk false;
                }
                break :blk self.valueCanSubstitute(if_value.final_else.*);
            },
            .match_ => |match_value| blk: {
                if (!self.exprCanSubstitute(match_value.scrutinee)) break :blk false;
                for (match_value.branches) |branch| {
                    if (branch.guard) |guard| {
                        if (!self.exprCanSubstitute(guard)) break :blk false;
                    }
                    if (!self.valueCanSubstitute(branch.body)) break :blk false;
                }
                break :blk true;
            },
            .tag => |tag| blk: {
                for (tag.payloads) |payload| {
                    if (!self.valueCanSubstitute(payload)) break :blk false;
                }
                break :blk true;
            },
            .record => |record| blk: {
                for (record.fields) |field| {
                    if (!self.valueCanSubstitute(field.value)) break :blk false;
                }
                break :blk true;
            },
            .tuple => |tuple| blk: {
                for (tuple.items) |item| {
                    if (!self.valueCanSubstitute(item)) break :blk false;
                }
                break :blk true;
            },
            .nominal => |nominal| self.valueCanSubstitute(nominal.backing.*),
            .callable => |callable| blk: {
                for (callable.captures) |capture| {
                    if (!self.valueCanSubstitute(capture)) break :blk false;
                }
                break :blk true;
            },
            .finite_tags => |finite_tags| blk: {
                if (!self.exprCanSubstitute(finite_tags.selector)) break :blk false;
                for (finite_tags.alternatives) |alternative| {
                    for (alternative.payloads) |payload| {
                        if (!self.valueCanSubstitute(payload)) break :blk false;
                    }
                }
                break :blk true;
            },
            .finite_callables => |finite_callables| blk: {
                if (!self.exprCanSubstitute(finite_callables.selector)) break :blk false;
                for (finite_callables.alternatives) |alternative| {
                    for (alternative.captures) |capture| {
                        if (!self.valueCanSubstitute(capture)) break :blk false;
                    }
                }
                break :blk true;
            },
            .expr_with_known_value => |known_value_expr| self.exprCanSubstitute(known_value_expr.expr),
            .private_state => true,
        };
    }

    fn privateStateCanSubstitute(self: *Cloner, value: PrivateStateValue) bool {
        return switch (value) {
            .leaf => |leaf| self.exprCanSubstitute(leaf.expr),
            .tag => |tag| blk: {
                for (tag.payloads) |payload| {
                    if (!self.privateStateCanSubstitute(payload.value)) break :blk false;
                }
                break :blk true;
            },
            .record => |record| blk: {
                for (record.fields) |field| {
                    if (!self.privateStateCanSubstitute(field.value)) break :blk false;
                }
                break :blk true;
            },
            .tuple => |tuple| blk: {
                for (tuple.items) |item| {
                    if (!self.privateStateCanSubstitute(item.value)) break :blk false;
                }
                break :blk true;
            },
            .nominal => |nominal| if (nominal.backing) |backing| self.privateStateCanSubstitute(backing.*) else true,
            .callable => |callable| blk: {
                for (callable.captures) |capture| {
                    if (!self.privateStateCanSubstitute(capture.value)) break :blk false;
                }
                break :blk true;
            },
            .finite_tags => |finite_tags| blk: {
                if (!self.exprCanSubstitute(finite_tags.selector)) break :blk false;
                for (finite_tags.alternatives) |alternative| {
                    for (alternative.payloads) |payload| {
                        if (!self.privateStateCanSubstitute(payload.value)) break :blk false;
                    }
                }
                break :blk true;
            },
            .finite_callables => |finite_callables| blk: {
                if (!self.exprCanSubstitute(finite_callables.selector)) break :blk false;
                for (finite_callables.alternatives) |alternative| {
                    for (alternative.captures) |capture| {
                        if (!self.privateStateCanSubstitute(capture.value)) break :blk false;
                    }
                }
                break :blk true;
            },
        };
    }

    fn valueContainsEscapingControlTransfer(self: *Cloner, value: Value) bool {
        return switch (value) {
            .expr => |expr| exprContainsEscapingControlTransfer(self.pass.program, expr),
            .expr_with_known_value => |known_value_expr| exprContainsEscapingControlTransfer(self.pass.program, known_value_expr.expr),
            .let_ => |let_value| blk: {
                for (let_value.lets) |pending| {
                    if (pendingLetValueContainsEscapingControlTransfer(self.pass.program, pending.value)) break :blk true;
                }
                break :blk self.valueContainsEscapingControlTransfer(let_value.body.*);
            },
            .if_ => |if_value| blk: {
                for (if_value.branches) |branch| {
                    if (exprContainsEscapingControlTransfer(self.pass.program, branch.cond) or
                        self.valueContainsEscapingControlTransfer(branch.body))
                    {
                        break :blk true;
                    }
                }
                break :blk self.valueContainsEscapingControlTransfer(if_value.final_else.*);
            },
            .match_ => |match_value| blk: {
                if (exprContainsEscapingControlTransfer(self.pass.program, match_value.scrutinee)) break :blk true;
                for (match_value.branches) |branch| {
                    if (branch.guard) |guard| {
                        if (exprContainsEscapingControlTransfer(self.pass.program, guard)) break :blk true;
                    }
                    if (self.valueContainsEscapingControlTransfer(branch.body)) break :blk true;
                }
                break :blk false;
            },
            .tag => |tag| blk: {
                for (tag.payloads) |payload| {
                    if (self.valueContainsEscapingControlTransfer(payload)) break :blk true;
                }
                break :blk false;
            },
            .record => |record| blk: {
                for (record.fields) |field| {
                    if (self.valueContainsEscapingControlTransfer(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple => |tuple| blk: {
                for (tuple.items) |item| {
                    if (self.valueContainsEscapingControlTransfer(item)) break :blk true;
                }
                break :blk false;
            },
            .nominal => |nominal| self.valueContainsEscapingControlTransfer(nominal.backing.*),
            .callable => |callable| blk: {
                for (callable.captures) |capture| {
                    if (self.valueContainsEscapingControlTransfer(capture)) break :blk true;
                }
                break :blk false;
            },
            .finite_tags => |finite_tags| blk: {
                if (exprContainsEscapingControlTransfer(self.pass.program, finite_tags.selector)) break :blk true;
                for (finite_tags.alternatives) |alternative| {
                    for (alternative.payloads) |payload| {
                        if (self.valueContainsEscapingControlTransfer(payload)) break :blk true;
                    }
                }
                break :blk false;
            },
            .finite_callables => |finite_callables| blk: {
                if (exprContainsEscapingControlTransfer(self.pass.program, finite_callables.selector)) break :blk true;
                for (finite_callables.alternatives) |alternative| {
                    for (alternative.captures) |capture| {
                        if (self.valueContainsEscapingControlTransfer(capture)) break :blk true;
                    }
                }
                break :blk false;
            },
            .private_state => false,
        };
    }

    fn exprCanSubstitute(self: *Cloner, expr_id: Ast.ExprId) bool {
        return switch (self.pass.program.exprs.items[@intFromEnum(expr_id)].data) {
            .local => |local| self.localCanBeReferencedDirectly(local),
            .unit,
            .int_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .dec_lit,
            .str_lit,
            .static_data,
            .fn_ref,
            => true,
            .field_access => |field| self.exprCanSubstitute(field.receiver),
            .tuple_access => |access| self.exprCanSubstitute(access.tuple),
            else => false,
        };
    }

    fn callableValue(self: *Cloner, ty: Type.TypeId, fn_id: Ast.FnId) Common.LowerError!Value {
        const fn_ = self.pass.program.fns.items[@intFromEnum(fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(fn_.captures);
        const captures = try self.pass.arena.allocator().alloc(Value, source_captures.len);
        for (source_captures, 0..) |capture, index| {
            if (self.subst.get(capture.local)) |value| {
                captures[index] = value;
            } else if (try self.scopedLocalValue(capture)) |value| {
                captures[index] = value;
            } else {
                return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .fn_ref = fn_id } }) };
            }
        }
        return .{ .callable = .{
            .ty = ty,
            .fn_id = fn_id,
            .captures = captures,
        } };
    }

    fn knownCallable(self: *Cloner, ty: Type.TypeId, fn_id: Ast.FnId) Allocator.Error!KnownValue {
        const fn_ = self.pass.program.fns.items[@intFromEnum(fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(fn_.captures);
        const captures = try self.pass.arena.allocator().alloc(KnownValue, source_captures.len);
        for (source_captures, 0..) |capture, index| {
            captures[index] = if (self.subst.get(capture.local)) |value|
                (try self.pass.knownValueFromValue(value)) orelse .{ .any = valueType(self.pass.program, value) }
            else
                .{ .any = capture.ty };
        }
        return .{ .callable = .{
            .ty = ty,
            .fn_id = fn_id,
            .captures = captures,
        } };
    }

    fn solvedSingleCallable(self: *Cloner, expr_id: Ast.ExprId) Allocator.Error!?Value {
        const solved = self.pass.solved orelse return null;
        const member = self.pass.solvedSingleCallableMember(expr_id) orelse return null;
        const fn_id = self.pass.fnWithSymbol(member.lambda) orelse return null;
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        const solved_captures = solved.types.captureSpan(member.captures);
        const source_fn = self.pass.program.fns.items[@intFromEnum(fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(source_fn.captures);
        if (solved_captures.len != source_captures.len) {
            Common.invariant("Lambda Solved callable member capture count differed from lifted function captures");
        }

        const captures = try self.pass.arena.allocator().alloc(Value, solved_captures.len);
        for (solved_captures, 0..) |capture, index| {
            if (capture.local != source_captures[index].local) {
                Common.invariant("Lambda Solved callable member captures differed from lifted function capture order");
            }
            captures[index] = if (self.subst.get(capture.local)) |value|
                value
            else if (try self.scopedLocalValue(source_captures[index])) |value|
                value
            else
                return null;
        }
        return .{ .callable = .{
            .ty = expr.ty,
            .fn_id = fn_id,
            .captures = captures,
        } };
    }

    fn cloneExprPlain(self: *Cloner, expr_id: Ast.ExprId) Common.LowerError!Ast.ExprId {
        const saved_loc = self.current_loc;
        defer self.current_loc = saved_loc;
        const saved_region = self.current_region;
        defer self.current_region = saved_region;
        self.current_loc = self.pass.program.exprLoc(expr_id);
        self.current_region = self.pass.program.exprRegion(expr_id);

        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        const data: Ast.ExprData = switch (expr.data) {
            .local => |local| .{ .local = local },
            .unit => .unit,
            .uninitialized => .uninitialized,
            .uninitialized_payload => |payload| .{ .uninitialized_payload = payload },
            .int_lit => |value| .{ .int_lit = value },
            .frac_f32_lit => |value| .{ .frac_f32_lit = value },
            .frac_f64_lit => |value| .{ .frac_f64_lit = value },
            .dec_lit => |value| .{ .dec_lit = value },
            .str_lit => |value| .{ .str_lit = value },
            .static_data => |value| .{ .static_data = value },
            .static_data_candidate => |candidate| .{ .static_data_candidate = .{
                .static_data = candidate.static_data,
                .fallback = try self.cloneExpr(candidate.fallback),
            } },
            .list => |items| .{ .list = try self.cloneExprSpan(items) },
            .tuple => |items| .{ .tuple = try self.cloneExprSpan(items) },
            .record => |fields| .{ .record = try self.cloneFieldExprSpan(fields) },
            .tag => |tag| .{ .tag = .{
                .name = tag.name,
                .payloads = try self.cloneExprSpan(tag.payloads),
            } },
            .nominal => |backing| .{ .nominal = try self.cloneExpr(backing) },
            .let_ => |let_| try self.cloneLet(let_),
            .lambda,
            .def_ref,
            .fn_def,
            => Common.invariant("pre-lift function expression reached call-pattern specialization"),
            .fn_ref => |target| .{ .fn_ref = target },
            .call_value => |call| .{ .call_value = .{
                .callee = try self.cloneExpr(call.callee),
                .args = try self.cloneExprSpan(call.args),
            } },
            .call_proc => |call| return try self.cloneCallProcExpr(expr.ty, call),
            .low_level => |call| .{ .low_level = .{
                .op = call.op,
                .args = try self.cloneExprSpan(call.args),
            } },
            .field_access => |field| return try self.cloneFieldAccess(expr.ty, field),
            .tuple_access => |access| return try self.cloneTupleAccess(expr.ty, access),
            .structural_eq => |eq| .{ .structural_eq = .{
                .lhs = try self.cloneExpr(eq.lhs),
                .rhs = try self.cloneExpr(eq.rhs),
                .negated = eq.negated,
            } },
            .structural_hash => |h| .{ .structural_hash = .{
                .value = try self.cloneExpr(h.value),
                .hasher = try self.cloneExpr(h.hasher),
            } },
            .match_ => |match| return try self.cloneMatch(expr.ty, match),
            .if_ => |if_| .{ .if_ = .{
                .branches = try self.cloneIfBranchSpan(if_.branches),
                .final_else = try self.cloneExpr(if_.final_else),
            } },
            .block => |block| return try self.cloneBlock(expr.ty, block),
            .loop_ => |loop| return try self.cloneLoop(expr.ty, loop),
            .state_loop => |state_loop| blk: {
                const states = try self.cloneStateLoopStateSpan(state_loop.states);
                break :blk .{ .state_loop = .{
                    .entry_state = self.cloneStateLoopStateId(state_loop.entry_state),
                    .entry_values = try self.cloneExprSpan(state_loop.entry_values),
                    .states = states,
                } };
            },
            .break_ => |maybe| .{ .break_ = if (maybe) |value| try self.cloneBreakPayloadExpr(value, .materialize) else null },
            .continue_ => |continue_| try self.cloneContinue(expr.ty, continue_),
            .state_continue => |continue_| .{ .state_continue = .{
                .target_state = self.cloneStateLoopStateId(continue_.target_state),
                .values = try self.cloneExprSpan(continue_.values),
            } },
            .if_initialized_payload => |payload_switch| .{ .if_initialized_payload = .{
                .cond = try self.cloneExpr(payload_switch.cond),
                .cond_mask = payload_switch.cond_mask,
                .payload = payload_switch.payload,
                .uninitialized_is_cold = payload_switch.uninitialized_is_cold,
                .initialized = try self.cloneExpr(payload_switch.initialized),
                .uninitialized = try self.cloneExpr(payload_switch.uninitialized),
            } },
            .try_sequence => |sequence| .{ .try_sequence = .{
                .try_expr = try self.cloneExpr(sequence.try_expr),
                .ok_local = sequence.ok_local,
                .err_is_cold = sequence.err_is_cold,
                .ok_body = try self.cloneExpr(sequence.ok_body),
            } },
            .try_record_sequence => |sequence| .{ .try_record_sequence = .{
                .try_expr = try self.cloneExpr(sequence.try_expr),
                .value_local = sequence.value_local,
                .value_field = sequence.value_field,
                .rest_local = sequence.rest_local,
                .rest_field = sequence.rest_field,
                .err_is_cold = sequence.err_is_cold,
                .ok_body = try self.cloneExpr(sequence.ok_body),
            } },
            .return_ => |value| .{ .return_ = try self.cloneExpr(value) },
            .crash => |msg| .{ .crash = msg },
            .comptime_branch_taken => |taken| .{ .comptime_branch_taken = .{
                .site = taken.site,
                .branch_index = taken.branch_index,
                .body = try self.cloneExpr(taken.body),
            } },
            .comptime_exhaustiveness_failed => |site| .{ .comptime_exhaustiveness_failed = site },
            .dbg => |child| .{ .dbg = try self.cloneExpr(child) },
            .expect_err => |expect_err| .{ .expect_err = .{
                .msg = try self.cloneExpr(expect_err.msg),
                .region = expect_err.region,
            } },
            .expect => |child| .{ .expect = try self.cloneExpr(child) },
        };
        return try self.addExpr(.{ .ty = expr.ty, .data = data });
    }

    fn cloneLetValue(self: *Cloner, let_: anytype) Common.LowerError!Value {
        const raw_value = try self.cloneExprValueDemandingKnownValue(let_.value);
        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        const pending_change_start = self.changes.items.len;
        var value = raw_value;
        while (value == .let_) {
            try pending_lets.appendSlice(self.pass.allocator, value.let_.lets);
            try self.bindPendingLetKnownValues(value.let_.lets);
            value = value.let_.body.*;
        }

        const reusable = try self.makeReusableForMatch(value, &pending_lets);
        const bind_change_start = self.changes.items.len;
        if (try self.bindPatToReusableValue(let_.bind, reusable)) {
            const rest = try self.cloneExprValue(let_.rest);
            self.restore(pending_change_start);
            return try self.wrapPendingLets(rest, pending_lets.items, true);
        }
        self.restore(bind_change_start);

        if (try self.bindPatToSingleUseRestValue(let_.bind, value, let_.rest)) {
            const rest = try self.cloneExprValue(let_.rest);
            self.restore(pending_change_start);
            return try self.wrapPendingLets(rest, pending_lets.items, true);
        }
        self.restore(pending_change_start);

        const value_expr = try self.materialize(raw_value);
        const change_start = self.changes.items.len;
        if (try self.bindPatToMaterializedKnownValue(let_.bind, raw_value)) {
            const rest_value = try self.cloneExprValue(let_.rest);
            const rest = try self.materialize(rest_value);
            self.restore(change_start);
            return .{ .expr = try self.addExpr(.{ .ty = self.pass.program.exprs.items[@intFromEnum(let_.rest)].ty, .data = .{ .let_ = .{
                .bind = try self.clonePat(let_.bind),
                .value = value_expr,
                .rest = rest,
                .comptime_site = let_.comptime_site,
            } } }) };
        }
        self.restore(change_start);
        return .{ .expr = try self.addExpr(.{ .ty = self.pass.program.exprs.items[@intFromEnum(let_.rest)].ty, .data = .{ .let_ = .{
            .bind = try self.clonePat(let_.bind),
            .value = value_expr,
            .rest = try self.cloneExpr(let_.rest),
            .comptime_site = let_.comptime_site,
        } } }) };
    }

    fn cloneLet(self: *Cloner, let_: anytype) Common.LowerError!Ast.ExprData {
        const value = try self.cloneExprValue(let_.value);
        const value_expr = try self.materialize(value);
        const change_start = self.changes.items.len;
        const bound = try self.bindPatToReusableValue(let_.bind, value);
        const rest = if (bound) blk: {
            const cloned = try self.cloneExpr(let_.rest);
            self.restore(change_start);
            break :blk cloned;
        } else if (try self.bindPatToSingleUseRestValue(let_.bind, value, let_.rest)) blk: {
            const cloned = try self.cloneExpr(let_.rest);
            self.restore(change_start);
            break :blk cloned;
        } else blk: {
            if (try self.bindPatToMaterializedKnownValue(let_.bind, value)) {
                const cloned = try self.cloneExpr(let_.rest);
                self.restore(change_start);
                break :blk cloned;
            }
            self.restore(change_start);
            if (try self.cloneLetOfCase(let_, value_expr)) |data| return data;
            break :blk try self.cloneExpr(let_.rest);
        };
        return .{ .let_ = .{
            .bind = try self.clonePat(let_.bind),
            .value = value_expr,
            .rest = rest,
            .comptime_site = let_.comptime_site,
        } };
    }

    fn cloneLetOfCase(self: *Cloner, let_: anytype, value_expr: Ast.ExprId) Common.LowerError!?Ast.ExprData {
        const value_data = self.pass.program.exprs.items[@intFromEnum(value_expr)].data;
        const match = switch (value_data) {
            .match_ => |match| match,
            else => return null,
        };

        const branches = try self.pass.allocator.dupe(Ast.Branch, self.pass.program.branchSpan(match.branches));
        defer self.pass.allocator.free(branches);

        var rewritten = try self.pass.allocator.alloc(Ast.Branch, branches.len);
        defer self.pass.allocator.free(rewritten);

        for (branches, 0..) |branch, index| {
            const body = (try self.cloneLetCaseBranchBody(let_, branch.body)) orelse return null;
            rewritten[index] = .{
                .pat = branch.pat,
                .guard = branch.guard,
                .body = body,
            };
        }

        return .{ .match_ = .{
            .scrutinee = match.scrutinee,
            .branches = try self.pass.program.addBranchSpan(rewritten),
            .comptime_site = match.comptime_site,
        } };
    }

    fn cloneLetCaseBranchBody(self: *Cloner, let_: anytype, branch_body: Ast.ExprId) Common.LowerError!?Ast.ExprId {
        const branch_expr = self.pass.program.exprs.items[@intFromEnum(branch_body)];
        switch (branch_expr.data) {
            .block => |block| {
                const change_start = self.changes.items.len;

                const source = try self.pass.allocator.dupe(Ast.StmtId, self.pass.program.stmtSpan(block.statements));
                defer self.pass.allocator.free(source);

                var statements = std.ArrayList(Ast.StmtId).empty;
                defer statements.deinit(self.pass.allocator);
                for (source, 0..) |stmt, stmt_index| {
                    try self.cloneStmtInto(stmt, &statements, .{
                        .statements = source[stmt_index + 1 ..],
                        .final_expr = block.final_expr,
                    }, .materialize);
                }

                const final_value = try self.cloneExprValue(block.final_expr);
                const rest_ty = self.pass.program.exprs.items[@intFromEnum(let_.rest)].ty;
                if (!try self.bindPatToReusableValue(let_.bind, final_value)) {
                    if (try self.cloneDivergentAtType(block.final_expr, rest_ty)) |divergent| {
                        self.restore(change_start);
                        return try self.addExpr(.{ .ty = rest_ty, .data = .{ .block = .{
                            .statements = try self.pass.program.addStmtSpan(statements.items),
                            .final_expr = divergent,
                        } } });
                    }
                    self.restore(change_start);
                    return null;
                }

                const rest = try self.cloneExpr(let_.rest);
                self.restore(change_start);

                return try self.addExpr(.{ .ty = rest_ty, .data = .{ .block = .{
                    .statements = try self.pass.program.addStmtSpan(statements.items),
                    .final_expr = rest,
                } } });
            },
            else => {
                const branch_value = try self.cloneExprValue(branch_body);
                const change_start = self.changes.items.len;
                if (!try self.bindPatToReusableValue(let_.bind, branch_value)) {
                    self.restore(change_start);
                    return null;
                }
                const rest = try self.cloneExpr(let_.rest);
                self.restore(change_start);
                return rest;
            },
        }
    }

    fn cloneDivergentAtType(self: *Cloner, expr_id: Ast.ExprId, ty: Type.TypeId) Common.LowerError!?Ast.ExprId {
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        return switch (expr.data) {
            .crash => |msg| try self.addExpr(.{ .ty = ty, .data = .{ .crash = msg } }),
            .comptime_exhaustiveness_failed => |site| try self.addExpr(.{ .ty = ty, .data = .{ .comptime_exhaustiveness_failed = site } }),
            .return_ => |value| try self.addExpr(.{ .ty = ty, .data = .{ .return_ = try self.cloneExpr(value) } }),
            else => null,
        };
    }

    fn scopedLocalValue(self: *Cloner, local: Ast.TypedLocal) Common.LowerError!?Value {
        if (!self.localCanBeReferencedDirectly(local.local)) return null;
        return .{ .expr = try self.addExpr(.{
            .ty = local.ty,
            .data = .{ .local = local.local },
        }) };
    }

    fn localCanBeReferencedDirectly(self: *Cloner, local: Ast.LocalId) bool {
        const current_fn = self.pass.program.fns.items[@intFromEnum(self.source_fn)];
        if (localInTypedLocalSpan(self.pass.program.typedLocalSpan(current_fn.captures), local)) return true;
        if (localInTypedLocalSpan(self.pass.program.typedLocalSpan(current_fn.args), local)) {
            return self.source_arg_locals_in_scope;
        }

        for (self.inline_stack.items) |active| {
            if (active.fn_id == self.source_fn) continue;
            const active_fn = self.pass.program.fns.items[@intFromEnum(active.fn_id)];
            if (localInTypedLocalSpan(self.pass.program.typedLocalSpan(active_fn.args), local)) return false;
            if (localInTypedLocalSpan(self.pass.program.typedLocalSpan(active_fn.captures), local)) return false;
        }

        return false;
    }

    fn cloneLoop(self: *Cloner, ty: Type.TypeId, loop: anytype) Common.LowerError!Ast.ExprId {
        return try self.cloneLoopWithDemand(ty, loop, .materialize);
    }

    fn cloneLoopWithDemand(self: *Cloner, ty: Type.TypeId, loop: anytype, result_demand: ValueDemand) Common.LowerError!Ast.ExprId {
        return try self.materialize(try self.cloneLoopValueWithDemand(ty, loop, result_demand));
    }

    fn cloneLoopValueWithDemand(self: *Cloner, ty: Type.TypeId, loop: anytype, result_demand: ValueDemand) Common.LowerError!Value {
        const params = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(loop.params));
        defer self.pass.allocator.free(params);
        const initial_values = try self.pass.allocator.dupe(Ast.ExprId, self.pass.program.exprSpan(loop.initial_values));
        defer self.pass.allocator.free(initial_values);
        if (params.len != initial_values.len) Common.invariant("loop parameter count differed from initial value count");

        const values = try self.pass.allocator.alloc(Value, initial_values.len);
        defer self.pass.allocator.free(values);
        for (initial_values, 0..) |initial, index| {
            values[index] = try self.cloneExprValueDemandingKnownValue(initial);
        }
        return try self.cloneLoopFromInitialValues(ty, loop, params, values, result_demand);
    }

    fn cloneLoopFromInitialValues(
        self: *Cloner,
        ty: Type.TypeId,
        loop: anytype,
        params: []const Ast.TypedLocal,
        values: []const Value,
        result_demand: ValueDemand,
    ) Common.LowerError!Value {
        if (try self.cloneLoopUnwrappedLet(ty, loop, params, values, result_demand)) |unwrapped| return .{ .expr = unwrapped };
        if (try self.cloneLoopDistributedIf(ty, loop, params, values, result_demand)) |distributed| return .{ .expr = distributed };

        const known_values = try self.pass.arena.allocator().alloc(KnownValue, values.len);
        var has_constructor = false;
        for (values, 0..) |value, index| {
            const initial_value_ty = valueType(self.pass.program, value);
            if (try self.pass.knownValueFromValue(value)) |known_value| {
                if (try self.projectableLoopKnownValueForValue(known_value, value)) |loop_known_value| {
                    known_values[index] = loop_known_value;
                    has_constructor = true;
                } else {
                    known_values[index] = .{ .any = initial_value_ty };
                }
            } else {
                known_values[index] = .{ .any = initial_value_ty };
            }
        }
        if (!has_constructor) {
            var needs_private_state = false;
            for (values) |value| {
                if (!self.valueCanMaterializePublic(value)) {
                    needs_private_state = true;
                    break;
                }
            }

            if (!needs_private_state) {
                const initial_span = try self.valuesToExprSpan(values);
                return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .loop_ = .{
                    .params = loop.params,
                    .initial_values = initial_span,
                    .body = try self.cloneExpr(loop.body),
                } } }) };
            }

            const demands = try self.pass.arena.allocator().alloc(ValueDemand, values.len);
            const demanded_known_values = try self.pass.arena.allocator().alloc(DemandedKnownValue, values.len);
            for (values, demands, demanded_known_values) |value, *demand_out, *known_out| {
                const inferred_demand = try self.valueDemandFromValueShape(value);
                demand_out.* = inferred_demand;
                known_out.* = (try self.demandedKnownValueFromValueDemand(value, inferred_demand)) orelse
                    DemandedKnownValue{ .any = valueType(self.pass.program, value) };
            }

            try self.stabilizeLoopDemandsFromDemandedStateBodies(loop, params, values, demanded_known_values, demands, result_demand);
            return try self.cloneStateLoopFromDemandedKnownValues(ty, loop, params, values, demanded_known_values, demands, result_demand);
        }

        while (true) {
            const change_start = self.changes.items.len;
            defer self.restore(change_start);

            var new_params = std.ArrayList(Ast.TypedLocal).empty;
            defer new_params.deinit(self.pass.allocator);

            var provenance = std.ArrayList(LoopLocalProvenance).empty;
            defer provenance.deinit(self.pass.allocator);

            for (params, known_values) |param, known_value| {
                var path = std.ArrayList(DemandPathStep).empty;
                defer path.deinit(self.pass.allocator);
                const param_value = try self.valueFromKnownValueLoopParamArgs(known_value, &new_params, param.local, &path, &provenance);
                try self.putSubst(param.local, param_value);
            }
            const refinements = try self.pass.allocator.alloc(?KnownValue, known_values.len);
            defer self.pass.allocator.free(refinements);
            @memset(refinements, null);

            const demands = try self.pass.allocator.alloc(ValueDemand, known_values.len);
            defer self.pass.allocator.free(demands);
            @memset(demands, .none);

            try self.loop_stack.append(self.pass.allocator, .{
                .params = params,
                .values = known_values,
                .refinements = refinements,
                .demands = demands,
                .result_demand = result_demand,
                .provenance = &provenance,
            });
            while (true) {
                var demand_changed = false;
                for (params, 0..) |param, index| {
                    const observed = try self.localDemandInExpr(param.local, loop.body, result_demand);
                    const merged = try self.mergeLoopParamDemand(known_values[index], demands[index], observed);
                    if (!valueDemandEql(demands[index], merged)) {
                        demands[index] = merged;
                        demand_changed = true;
                    }
                }
                if (!demand_changed) break;
            }
            if (valueDemandsRequirePrivateState(demands)) {
                try self.stabilizeLoopDemandsFromStateBodies(loop, params, known_values, demands, result_demand);
                _ = self.loop_stack.pop();
                const demanded_known_values = try self.pass.arena.allocator().alloc(DemandedKnownValue, known_values.len);
                for (known_values, demands, demanded_known_values) |known_value, demand, *out| {
                    out.* = (try demandedKnownValueFromDemand(self, self.pass.program, self.pass.arena.allocator(), known_value, demand)) orelse
                        DemandedKnownValue{ .any = known_valueType(known_value) };
                }
                self.restore(change_start);
                return try self.cloneStateLoopFromDemandedKnownValues(ty, loop, params, values, demanded_known_values, demands, result_demand);
            }
            const body = try self.cloneExpr(loop.body);
            _ = self.loop_stack.pop();

            if (valueDemandsRequirePrivateState(demands)) {
                const demanded_known_values = try self.pass.arena.allocator().alloc(DemandedKnownValue, known_values.len);
                for (known_values, demands, demanded_known_values) |known_value, demand, *out| {
                    out.* = (try demandedKnownValueFromDemand(self, self.pass.program, self.pass.arena.allocator(), known_value, demand)) orelse
                        DemandedKnownValue{ .any = known_valueType(known_value) };
                }
                self.restore(change_start);
                return try self.cloneStateLoopFromDemandedKnownValues(ty, loop, params, values, demanded_known_values, demands, result_demand);
            }

            var refined = false;
            for (known_values, refinements, 0..) |*known_value, maybe_refinement, index| {
                const refinement = maybe_refinement orelse continue;
                if (known_valueEql(self.pass.program, known_value.*, refinement)) continue;
                known_values[index] = refinement;
                refined = true;
            }
            if (refined) continue;

            if (knownValuesContainFiniteState(known_values) or valueDemandsRequirePrivateState(demands)) {
                try self.stabilizeLoopDemandsFromStateBodies(loop, params, known_values, demands, result_demand);
                const demanded_known_values = try self.pass.arena.allocator().alloc(DemandedKnownValue, known_values.len);
                for (known_values, demands, demanded_known_values) |known_value, demand, *out| {
                    out.* = (try demandedKnownValueFromDemand(self, self.pass.program, self.pass.arena.allocator(), known_value, demand)) orelse
                        DemandedKnownValue{ .any = known_valueType(known_value) };
                }
                if (demandedKnownValuesContainFiniteState(demanded_known_values) or valueDemandsRequirePrivateState(demands)) {
                    self.restore(change_start);
                    return try self.cloneStateLoopFromDemandedKnownValues(ty, loop, params, values, demanded_known_values, demands, result_demand);
                }
            }

            var new_initials = std.ArrayList(Ast.ExprId).empty;
            defer new_initials.deinit(self.pass.allocator);

            var pending_lets = std.ArrayList(PendingLet).empty;
            defer pending_lets.deinit(self.pass.allocator);

            var initial_split_failed = false;
            for (known_values, values, 0..) |*known_value, value, index| {
                if (!try self.appendFieldReadExprsFromValueCollectingLets(known_value.*, value, &new_initials, &pending_lets)) {
                    const downgrade_ty = known_valueType(known_value.*);
                    if (known_value.* == .any and sameType(self.pass.program, known_value.any, downgrade_ty)) {
                        Common.invariant("loop initial split failed without progress");
                    }
                    known_values[index] = .{ .any = downgrade_ty };
                    initial_split_failed = true;
                    break;
                }
            }
            if (initial_split_failed) continue;

            const loop_expr = try self.addExpr(.{ .ty = ty, .data = .{ .loop_ = .{
                .params = try self.pass.program.addTypedLocalSpan(new_params.items),
                .initial_values = try self.pass.program.addExprSpan(new_initials.items),
                .body = body,
            } } });
            return .{ .expr = try self.wrapPendingLetsAroundExpr(ty, loop_expr, pending_lets.items) };
        }
    }

    fn stabilizeLoopDemandsFromStateBodies(
        self: *Cloner,
        loop: anytype,
        params: []const Ast.TypedLocal,
        known_values: []const KnownValue,
        demands: []ValueDemand,
        result_demand: ValueDemand,
    ) Common.LowerError!void {
        while (true) {
            var changed = false;

            const demanded_known_values = try self.pass.allocator.alloc(DemandedKnownValue, known_values.len);
            defer self.pass.allocator.free(demanded_known_values);
            for (known_values, demands, demanded_known_values) |known_value, demand, *out| {
                out.* = (try demandedKnownValueFromDemand(self, self.pass.program, self.pass.arena.allocator(), known_value, demand)) orelse
                    DemandedKnownValue{ .any = known_valueType(known_value) };
            }

            const state_keys = try demandedKnownValueProducts(self.pass.allocator, self.pass.arena.allocator(), demanded_known_values);
            for (state_keys) |state_values| {
                if (state_values.len != params.len) Common.invariant("state demand key arity differed from loop params");

                const change_start = self.changes.items.len;

                var state_params = std.ArrayList(Ast.TypedLocal).empty;
                defer {
                    self.restore(change_start);
                    state_params.deinit(self.pass.allocator);
                }

                for (params, state_values) |param, state_value| {
                    const private_state = try self.privateStateValueFromDemandedKnownValueArgs(state_value, &state_params);
                    try self.putSubst(param.local, .{ .private_state = private_state });
                }

                for (params, 0..) |param, index| {
                    const observed = try self.localDemandInExpr(param.local, loop.body, result_demand);
                    const merged = try self.mergeLoopParamDemand(known_values[index], demands[index], observed);
                    if (!valueDemandEql(demands[index], merged)) {
                        demands[index] = merged;
                        changed = true;
                    }
                }
            }

            if (!changed) return;
        }
    }

    fn stabilizeLoopDemandsFromDemandedStateBodies(
        self: *Cloner,
        loop: anytype,
        params: []const Ast.TypedLocal,
        values: []const Value,
        demanded_known_values: []DemandedKnownValue,
        demands: []ValueDemand,
        result_demand: ValueDemand,
    ) Common.LowerError!void {
        const loop_known_values = try self.pass.allocator.alloc(KnownValue, values.len);
        defer self.pass.allocator.free(loop_known_values);
        for (values, loop_known_values) |value, *known_value| {
            known_value.* = .{ .any = valueType(self.pass.program, value) };
        }

        const refinements = try self.pass.allocator.alloc(?KnownValue, values.len);
        defer self.pass.allocator.free(refinements);
        @memset(refinements, null);

        var provenance = std.ArrayList(LoopLocalProvenance).empty;
        defer provenance.deinit(self.pass.allocator);

        try self.loop_stack.append(self.pass.allocator, .{
            .params = params,
            .values = loop_known_values,
            .source_values = values,
            .refinements = refinements,
            .demands = demands,
            .result_demand = result_demand,
            .provenance = &provenance,
        });
        defer _ = self.loop_stack.pop();

        while (true) {
            var changed = false;
            const state_keys = try demandedKnownValueProducts(self.pass.allocator, self.pass.arena.allocator(), demanded_known_values);

            for (state_keys) |state_values| {
                if (state_values.len != params.len) Common.invariant("state demand key arity differed from loop params");

                const change_start = self.changes.items.len;
                const provenance_start = self.loopProvenanceLen();

                var state_params = std.ArrayList(Ast.TypedLocal).empty;
                defer {
                    self.restoreLoopProvenance(provenance_start);
                    self.restore(change_start);
                    state_params.deinit(self.pass.allocator);
                }

                for (params, state_values) |param, state_value| {
                    var path = std.ArrayList(DemandPathStep).empty;
                    defer path.deinit(self.pass.allocator);
                    const private_state = try self.privateStateValueFromDemandedKnownValueLoopParamArgs(
                        state_value,
                        &state_params,
                        param.local,
                        &path,
                        &provenance,
                    );
                    try self.putSubst(param.local, .{ .private_state = private_state });
                }

                for (params, values, 0..) |param, value, index| {
                    const observed = try self.localDemandInExpr(param.local, loop.body, result_demand);
                    const merged = try self.mergeLoopValueParamDemand(value, demands[index], observed);
                    if (!valueDemandEql(demands[index], merged)) {
                        demands[index] = merged;
                        changed = true;
                    }
                }
            }

            if (!changed) return;
            try self.refreshDemandedKnownValuesFromValueDemands(values, demands, demanded_known_values);
        }
    }

    fn cloneCompactLoopBodyExpr(
        self: *Cloner,
        expr_id: Ast.ExprId,
        result: CompactLoopResult,
        demand: ValueDemand,
    ) Common.LowerError!Ast.ExprId {
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        if (try self.cloneDivergentAtType(expr_id, result.ty)) |divergent| return divergent;

        return switch (expr.data) {
            .break_ => |maybe_value| try self.addExpr(.{ .ty = result.ty, .data = .{ .break_ = if (maybe_value) |value| blk: {
                const payload = try self.cloneExprValueWithDemand(value, demand);
                break :blk try self.compactLoopResultExpr(result, payload);
            } else blk: {
                if (result.leaf_tys.len != 0) Common.invariant("non-unit compact loop result had empty break");
                break :blk null;
            } } }),
            .continue_ => |continue_| try self.addExpr(.{
                .ty = result.ty,
                .data = try self.cloneContinue(result.ty, continue_),
            }),
            .state_continue => |continue_| try self.addExpr(.{ .ty = result.ty, .data = .{ .state_continue = .{
                .target_state = self.cloneStateLoopStateId(continue_.target_state),
                .values = try self.cloneExprSpan(continue_.values),
            } } }),
            .return_ => |value| try self.addExpr(.{ .ty = result.ty, .data = .{ .return_ = try self.cloneExpr(value) } }),
            .comptime_branch_taken => |taken| try self.cloneCompactLoopBodyExpr(taken.body, result, demand),
            .block => |block| try self.cloneCompactLoopBlockExpr(block, result, demand),
            .if_ => |if_| try self.cloneCompactLoopIfExpr(if_, result, demand),
            .match_ => |match| try self.cloneCompactLoopMatchExpr(match, result, demand),
            .let_ => |let_| try self.cloneCompactLoopLetExpr(let_, result, demand),
            else => try self.compactLoopResultExpr(result, try self.cloneExprValueWithDemand(expr_id, demand)),
        };
    }

    fn cloneCompactLoopBlockExpr(
        self: *Cloner,
        block: anytype,
        result: CompactLoopResult,
        demand: ValueDemand,
    ) Common.LowerError!Ast.ExprId {
        const change_start = self.changes.items.len;
        defer self.restore(change_start);
        const provenance_start = self.loopProvenanceLen();
        defer self.restoreLoopProvenance(provenance_start);

        const source = try self.pass.allocator.dupe(Ast.StmtId, self.pass.program.stmtSpan(block.statements));
        defer self.pass.allocator.free(source);

        var statements = std.ArrayList(Ast.StmtId).empty;
        defer statements.deinit(self.pass.allocator);
        for (source, 0..) |stmt, index| {
            if (stmtAlwaysEscapesControlTransfer(self.pass.program, stmt)) {
                const final_expr = try self.cloneCompactLoopStmtAsFinalExpr(stmt, result, demand);
                if (statements.items.len == 0) return final_expr;

                return try self.addExpr(.{ .ty = result.ty, .data = .{ .block = .{
                    .statements = try self.pass.program.addStmtSpan(statements.items),
                    .final_expr = final_expr,
                } } });
            }

            try self.cloneCompactLoopStmtInto(stmt, &statements, .{
                .statements = source[index + 1 ..],
                .final_expr = block.final_expr,
            }, result, demand);
        }

        const final_expr = try self.cloneCompactLoopBodyExpr(block.final_expr, result, demand);
        if (statements.items.len == 0) return final_expr;

        return try self.addExpr(.{ .ty = result.ty, .data = .{ .block = .{
            .statements = try self.pass.program.addStmtSpan(statements.items),
            .final_expr = final_expr,
        } } });
    }

    fn cloneCompactLoopStmtAsFinalExpr(
        self: *Cloner,
        stmt_id: Ast.StmtId,
        result: CompactLoopResult,
        demand: ValueDemand,
    ) Common.LowerError!Ast.ExprId {
        const stmt = self.pass.program.stmts.items[@intFromEnum(stmt_id)];
        return switch (stmt) {
            .expr => |expr| try self.cloneCompactLoopBodyExpr(expr, result, demand),
            .let_ => |let_| try self.cloneCompactLoopBodyExpr(let_.value, result, demand),
            .return_ => |expr| try self.addExpr(.{ .ty = result.ty, .data = .{ .return_ = try self.cloneExpr(expr) } }),
            .dbg => |expr| try self.addExpr(.{ .ty = result.ty, .data = .{ .dbg = try self.cloneCompactLoopBodyExpr(expr, result, demand) } }),
            .expect => |expr| try self.addExpr(.{ .ty = result.ty, .data = .{ .expect = try self.cloneCompactLoopBodyExpr(expr, result, demand) } }),
            .crash => |msg| try self.addExpr(.{ .ty = result.ty, .data = .{ .crash = msg } }),
            .uninitialized => Common.invariant("uninitialized statement was classified as definitely escaping"),
        };
    }

    fn cloneCompactLoopStmtInto(
        self: *Cloner,
        stmt_id: Ast.StmtId,
        out: *std.ArrayList(Ast.StmtId),
        tail: BlockTail,
        result: CompactLoopResult,
        demand: ValueDemand,
    ) Common.LowerError!void {
        const stmt = self.pass.program.stmts.items[@intFromEnum(stmt_id)];
        switch (stmt) {
            .expr => try self.cloneStmtInto(stmt_id, out, tail, demand),
            .let_ => |let_| {
                if (exprAlwaysEscapesControlTransferDepth(self.pass.program, let_.value, 0, 0)) {
                    try out.append(self.pass.allocator, try self.addStmt(.{ .let_ = .{
                        .pat = try self.clonePat(let_.pat),
                        .value = try self.cloneCompactLoopBodyExpr(let_.value, result, demand),
                        .recursive = let_.recursive,
                        .comptime_site = let_.comptime_site,
                    } }));
                } else {
                    try self.cloneStmtInto(stmt_id, out, tail, demand);
                }
            },
            .return_ => |expr| try out.append(self.pass.allocator, try self.addStmt(.{
                .return_ = try self.cloneExpr(expr),
            })),
            else => try self.cloneStmtInto(stmt_id, out, tail, demand),
        }
    }

    fn cloneCompactLoopIfExpr(
        self: *Cloner,
        if_: anytype,
        result: CompactLoopResult,
        demand: ValueDemand,
    ) Common.LowerError!Ast.ExprId {
        const source_branches = try self.pass.allocator.dupe(Ast.IfBranch, self.pass.program.ifBranchSpan(if_.branches));
        defer self.pass.allocator.free(source_branches);

        const branches = try self.pass.allocator.alloc(Ast.IfBranch, source_branches.len);
        defer self.pass.allocator.free(branches);
        for (source_branches, branches) |branch, *out| {
            out.* = .{
                .cond = try self.cloneExpr(branch.cond),
                .body = try self.cloneCompactLoopBodyExpr(branch.body, result, demand),
            };
        }

        return try self.addExpr(.{ .ty = result.ty, .data = .{ .if_ = .{
            .branches = try self.pass.program.addIfBranchSpan(branches),
            .final_else = try self.cloneCompactLoopBodyExpr(if_.final_else, result, demand),
        } } });
    }

    fn cloneCompactLoopMatchExpr(
        self: *Cloner,
        match: anytype,
        result: CompactLoopResult,
        demand: ValueDemand,
    ) Common.LowerError!Ast.ExprId {
        const scrutinee_demand = try self.matchScrutineeDemand(match.branches, demand);
        const scrutinee = try self.materialize(try self.cloneMatchScrutineeValue(match, scrutinee_demand));

        const source_branches = try self.pass.allocator.dupe(Ast.Branch, self.pass.program.branchSpan(match.branches));
        defer self.pass.allocator.free(source_branches);
        const branches = try self.pass.allocator.alloc(Ast.Branch, source_branches.len);
        defer self.pass.allocator.free(branches);
        for (source_branches, branches) |branch, *out| {
            out.* = .{
                .pat = try self.clonePat(branch.pat),
                .guard = if (branch.guard) |guard| try self.cloneExpr(guard) else null,
                .body = try self.cloneCompactLoopBodyExpr(branch.body, result, demand),
            };
        }

        return try self.addExpr(.{ .ty = result.ty, .data = .{ .match_ = .{
            .scrutinee = scrutinee,
            .branches = try self.pass.program.addBranchSpan(branches),
            .comptime_site = match.comptime_site,
        } } });
    }

    fn cloneCompactLoopLetExpr(
        self: *Cloner,
        let_: anytype,
        result: CompactLoopResult,
        demand: ValueDemand,
    ) Common.LowerError!Ast.ExprId {
        if (exprAlwaysEscapesControlTransferDepth(self.pass.program, let_.value, 0, 0)) {
            return try self.cloneCompactLoopBodyExpr(let_.value, result, demand);
        }
        if (exprContainsEscapingControlTransfer(self.pass.program, let_.value)) {
            return try self.addExpr(.{ .ty = result.ty, .data = .{ .let_ = .{
                .bind = try self.clonePat(let_.bind),
                .value = try self.cloneExpr(let_.value),
                .rest = try self.cloneCompactLoopBodyExpr(let_.rest, result, demand),
                .comptime_site = let_.comptime_site,
            } } });
        }

        const let_value = try self.cloneLetValueWithDemand(let_, demand);
        return try self.compactLoopResultExpr(result, let_value);
    }

    fn compactLoopResult(
        self: *Cloner,
        ty: Type.TypeId,
        demand: ValueDemand,
    ) Common.LowerError!?CompactLoopResult {
        return switch (demand) {
            .none,
            .materialize,
            => null,
            .loop_param => Common.invariant("loop result demand reference did not resolve before compact loop result construction"),
            else => {
                const demanded = (try demandedKnownValueFromDemand(
                    self,
                    self.pass.program,
                    self.pass.arena.allocator(),
                    .{ .any = ty },
                    demand,
                )) orelse return null;

                var leaf_tys = std.ArrayList(Type.TypeId).empty;
                defer leaf_tys.deinit(self.pass.allocator);
                try self.appendDemandedKnownValueLeafTypes(demanded, &leaf_tys);

                const stored_leaf_tys = try self.pass.arena.allocator().dupe(Type.TypeId, leaf_tys.items);
                return CompactLoopResult{
                    .known_value = demanded,
                    .ty = try self.compactLeafTupleType(stored_leaf_tys),
                    .leaf_tys = stored_leaf_tys,
                };
            },
        };
    }

    fn appendDemandedKnownValueLeafTypes(
        self: *Cloner,
        known_value: DemandedKnownValue,
        out: *std.ArrayList(Type.TypeId),
    ) Allocator.Error!void {
        switch (known_value) {
            .any,
            .leaf,
            => |ty| try out.append(self.pass.allocator, ty),
            .tag => |tag| {
                for (tag.payloads) |payload| try self.appendDemandedKnownValueLeafTypes(payload.known_value, out);
            },
            .record => |record| {
                for (record.fields) |field| try self.appendDemandedKnownValueLeafTypes(field.known_value, out);
            },
            .tuple => |tuple| {
                for (tuple.items) |item| try self.appendDemandedKnownValueLeafTypes(item.known_value, out);
            },
            .nominal => |nominal| {
                if (nominal.backing) |backing| try self.appendDemandedKnownValueLeafTypes(backing.*, out);
            },
            .callable => |callable| {
                for (callable.captures) |capture| try self.appendDemandedKnownValueLeafTypes(capture.known_value, out);
            },
            .finite_tags => |finite_tags| {
                try out.append(self.pass.allocator, try self.pass.primitiveType(.u64));
                for (finite_tags.alternatives) |alternative| {
                    for (alternative.payloads) |payload| try self.appendDemandedKnownValueLeafTypes(payload.known_value, out);
                }
            },
            .finite_callables => |finite_callables| {
                try out.append(self.pass.allocator, try self.pass.primitiveType(.u64));
                for (finite_callables.alternatives) |alternative| {
                    for (alternative.captures) |capture| try self.appendDemandedKnownValueLeafTypes(capture.known_value, out);
                }
            },
        }
    }

    fn compactLeafTupleType(self: *Cloner, leaf_tys: []const Type.TypeId) Allocator.Error!Type.TypeId {
        return switch (leaf_tys.len) {
            0 => try self.unitType(),
            1 => leaf_tys[0],
            else => try self.pass.program.types.add(.{
                .tuple = try self.pass.program.types.addSpan(leaf_tys),
            }),
        };
    }

    fn unitType(self: *Cloner) Allocator.Error!Type.TypeId {
        return try self.pass.program.types.add(.{ .record = .empty() });
    }

    fn compactLoopResultExpr(
        self: *Cloner,
        result: CompactLoopResult,
        value: Value,
    ) Common.LowerError!Ast.ExprId {
        var leaf_exprs = std.ArrayList(Ast.ExprId).empty;
        defer leaf_exprs.deinit(self.pass.allocator);
        if (!try self.appendExprsFromDemandedKnownValue(result.known_value, value, &leaf_exprs)) {
            Common.invariant("optimized loop result could not be split into compact result leaves");
        }
        if (leaf_exprs.items.len != result.leaf_tys.len) {
            Common.invariant("optimized loop result split produced the wrong leaf count");
        }
        return try self.compactLeafTupleExpr(result.ty, leaf_exprs.items);
    }

    fn compactLeafTupleExpr(
        self: *Cloner,
        ty: Type.TypeId,
        leaf_exprs: []const Ast.ExprId,
    ) Common.LowerError!Ast.ExprId {
        return switch (leaf_exprs.len) {
            0 => try self.addExpr(.{ .ty = ty, .data = .unit }),
            1 => leaf_exprs[0],
            else => try self.addExpr(.{ .ty = ty, .data = .{
                .tuple = try self.pass.program.addExprSpan(leaf_exprs),
            } }),
        };
    }

    fn privateStateValueFromCompactLoopResult(
        self: *Cloner,
        result: CompactLoopResult,
        compact_expr: Ast.ExprId,
    ) Common.LowerError!PrivateStateValue {
        var leaf_exprs = std.ArrayList(Ast.ExprId).empty;
        defer leaf_exprs.deinit(self.pass.allocator);

        switch (result.leaf_tys.len) {
            0 => {},
            1 => try leaf_exprs.append(self.pass.allocator, compact_expr),
            else => for (result.leaf_tys, 0..) |leaf_ty, index| {
                try leaf_exprs.append(self.pass.allocator, try self.addExpr(.{ .ty = leaf_ty, .data = .{ .tuple_access = .{
                    .tuple = compact_expr,
                    .elem_index = @intCast(index),
                } } }));
            },
        }

        var index: usize = 0;
        const private_state = try self.privateStateValueFromDemandedKnownValueExprs(result.known_value, leaf_exprs.items, &index);
        if (index != leaf_exprs.items.len) {
            Common.invariant("compact loop result reconstruction did not consume every leaf");
        }
        return private_state;
    }

    fn privateStateValueFromDemandedKnownValueExprs(
        self: *Cloner,
        known_value: DemandedKnownValue,
        exprs: []const Ast.ExprId,
        index: *usize,
    ) Common.LowerError!PrivateStateValue {
        return switch (known_value) {
            .any,
            .leaf,
            => |ty| blk: {
                if (index.* >= exprs.len) Common.invariant("compact loop result reconstruction ran out of leaves");
                const expr = exprs[index.*];
                index.* += 1;
                break :blk PrivateStateValue{ .leaf = .{
                    .ty = ty,
                    .expr = expr,
                } };
            },
            .tag => |tag| .{ .tag = .{
                .ty = tag.ty,
                .name = tag.name,
                .payloads = try self.privateStateIndexedValuesFromDemandedKnownValueExprs(tag.payloads, exprs, index),
            } },
            .record => |record| blk: {
                const fields = try self.pass.arena.allocator().alloc(PrivateStateField, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    out.* = .{
                        .name = field.name,
                        .value = try self.privateStateValueFromDemandedKnownValueExprs(field.known_value, exprs, index),
                    };
                }
                break :blk PrivateStateValue{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| .{ .tuple = .{
                .ty = tuple.ty,
                .items = try self.privateStateIndexedValuesFromDemandedKnownValueExprs(tuple.items, exprs, index),
            } },
            .nominal => |nominal| blk: {
                const backing = if (nominal.backing) |backing_known_value| backing: {
                    const stored = try self.pass.arena.allocator().create(PrivateStateValue);
                    stored.* = try self.privateStateValueFromDemandedKnownValueExprs(backing_known_value.*, exprs, index);
                    break :backing stored;
                } else null;
                break :blk PrivateStateValue{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = backing,
                } };
            },
            .callable => |callable| .{ .callable = .{
                .ty = callable.ty,
                .fn_id = callable.fn_id,
                .captures = try self.privateStateIndexedValuesFromDemandedKnownValueExprs(callable.captures, exprs, index),
            } },
            .finite_tags => |finite_tags| blk: {
                if (index.* >= exprs.len) Common.invariant("compact loop finite tag result had no selector leaf");
                const selector = exprs[index.*];
                index.* += 1;
                const alternatives = try self.pass.arena.allocator().alloc(PrivateStateTag, finite_tags.alternatives.len);
                for (finite_tags.alternatives, alternatives) |alternative, *out| {
                    out.* = .{
                        .ty = alternative.ty,
                        .name = alternative.name,
                        .payloads = try self.privateStateIndexedValuesFromDemandedKnownValueExprs(alternative.payloads, exprs, index),
                    };
                }
                break :blk PrivateStateValue{ .finite_tags = .{
                    .ty = finite_tags.ty,
                    .selector = selector,
                    .alternatives = alternatives,
                } };
            },
            .finite_callables => |finite_callables| blk: {
                if (index.* >= exprs.len) Common.invariant("compact loop finite callable result had no selector leaf");
                const selector = exprs[index.*];
                index.* += 1;
                const alternatives = try self.pass.arena.allocator().alloc(PrivateStateCallable, finite_callables.alternatives.len);
                for (finite_callables.alternatives, alternatives) |alternative, *out| {
                    out.* = .{
                        .ty = alternative.ty,
                        .fn_id = alternative.fn_id,
                        .captures = try self.privateStateIndexedValuesFromDemandedKnownValueExprs(alternative.captures, exprs, index),
                    };
                }
                break :blk PrivateStateValue{ .finite_callables = .{
                    .ty = finite_callables.ty,
                    .selector = selector,
                    .alternatives = alternatives,
                } };
            },
        };
    }

    fn privateStateIndexedValuesFromDemandedKnownValueExprs(
        self: *Cloner,
        known_values: []const DemandedKnownIndexedValue,
        exprs: []const Ast.ExprId,
        index: *usize,
    ) Common.LowerError![]const PrivateStateIndexedValue {
        const values = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, known_values.len);
        for (known_values, values) |known_value, *out| {
            out.* = .{
                .index = known_value.index,
                .value = try self.privateStateValueFromDemandedKnownValueExprs(known_value.known_value, exprs, index),
            };
        }
        return values;
    }

    fn cloneStateLoopFromDemandedKnownValues(
        self: *Cloner,
        ty: Type.TypeId,
        loop: anytype,
        params: []const Ast.TypedLocal,
        values: []const Value,
        known_values: []const DemandedKnownValue,
        demands: []const ValueDemand,
        result_demand: ValueDemand,
    ) Common.LowerError!Value {
        const compact_result = try self.compactLoopResult(ty, result_demand);
        const state_loop_ty = if (compact_result) |result| result.ty else ty;

        const state_keys = try demandedKnownValueProducts(self.pass.allocator, self.pass.arena.allocator(), known_values);
        const demanded_entry_values = try self.pass.allocator.alloc(Value, values.len);
        defer self.pass.allocator.free(demanded_entry_values);
        for (values, demands, demanded_entry_values) |value, demand, *out| {
            out.* = try self.applyValueDemand(value, demand);
        }

        var entry_state_index: ?usize = null;
        for (state_keys, 0..) |state_values, index| {
            if (!demandedKnownValuesMatchValues(self.pass.program, state_values, demanded_entry_values)) continue;
            if (entry_state_index != null) Common.invariant("state_loop edge matched multiple states");
            entry_state_index = index;
        }
        const selected_entry_state_index = entry_state_index orelse {
            if (compact_result != null) Common.invariant("optimized loop private result could not select an entry state");
            const initial_span = try self.valuesToExprSpan(values);
            return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .loop_ = .{
                .params = loop.params,
                .initial_values = initial_span,
                .body = try self.cloneExpr(loop.body),
            } } }) };
        };

        const state_start: u32 = @intCast(self.pass.program.state_loop_states.items.len);
        var states = std.ArrayList(SparseStateLoopState).empty;
        defer states.deinit(self.pass.allocator);

        for (state_keys) |state_values| {
            if (state_values.len != params.len) Common.invariant("state_loop key arity differed from loop params");
            _ = try self.appendSparseState(&states, state_values);
        }

        const entry_state = states.items[selected_entry_state_index];

        var entry_values = std.ArrayList(Ast.ExprId).empty;
        defer entry_values.deinit(self.pass.allocator);
        var entry_pending_lets = std.ArrayList(PendingLet).empty;
        defer entry_pending_lets.deinit(self.pass.allocator);
        for (entry_state.values, demanded_entry_values) |known_value, value| {
            if (!try self.appendExprsFromDemandedKnownValueCollectingLets(known_value, value, &entry_values, &entry_pending_lets)) {
                Common.invariant("state_loop initial value could not be split into entry state params");
            }
        }

        try self.state_loop_stack.append(self.pass.allocator, .{
            .states = &states,
            .demands = demands,
            .result_demand = result_demand,
            .compact_result = compact_result,
        });
        defer _ = self.state_loop_stack.pop();

        var state_index: usize = 0;
        while (state_index < states.items.len) : (state_index += 1) {
            const state = states.items[state_index];
            const change_start = self.changes.items.len;
            defer self.restore(change_start);

            var state_params = std.ArrayList(Ast.TypedLocal).empty;
            defer state_params.deinit(self.pass.allocator);

            for (params, state.values) |param, known_value| {
                const private_state = try self.privateStateValueFromDemandedKnownValueArgs(known_value, &state_params);
                try self.putSubst(param.local, .{ .private_state = private_state });
            }

            const state_params_span = try self.pass.program.addTypedLocalSpan(state_params.items);
            const state_body = if (compact_result) |result|
                try self.cloneCompactLoopBodyExpr(loop.body, result, result_demand)
            else
                try self.materialize(try self.cloneExprValueWithDemand(loop.body, result_demand));
            self.pass.program.state_loop_states.items[@intFromEnum(state.id)] = .{
                .params = state_params_span,
                .body = state_body,
            };
        }

        const state_span: Ast.Span(Ast.StateLoopState) = .{
            .start = state_start,
            .len = @intCast(states.items.len),
        };
        const state_loop_expr = try self.addExpr(.{ .ty = state_loop_ty, .data = .{ .state_loop = .{
            .entry_state = entry_state.id,
            .entry_values = try self.pass.program.addExprSpan(entry_values.items),
            .states = state_span,
        } } });
        if (compact_result) |result| {
            const result_expr = try self.wrapPendingLetsAroundExpr(state_loop_ty, state_loop_expr, entry_pending_lets.items);
            const result_local = try self.pass.program.addLocal(self.pass.symbols.fresh(), state_loop_ty);
            const result_local_expr = try self.addExpr(.{
                .ty = state_loop_ty,
                .data = .{ .local = result_local },
            });
            const private_result = try self.privateStateValueFromCompactLoopResult(result, result_local_expr);
            const pending = [_]PendingLet{.{
                .local = result_local,
                .ty = state_loop_ty,
                .value = .{ .cloned = result_expr },
            }};
            return try self.wrapPendingLets(.{ .private_state = private_result }, &pending, true);
        }
        return .{ .expr = try self.wrapPendingLetsAroundExpr(ty, state_loop_expr, entry_pending_lets.items) };
    }

    fn knownValueProducts(self: *Cloner, known_values: []const KnownValue) Allocator.Error![]const []const KnownValue {
        const options = try self.pass.allocator.alloc([]const KnownValue, known_values.len);
        defer self.pass.allocator.free(options);
        for (known_values, 0..) |known_value, index| {
            options[index] = try self.expandKnownValue(known_value);
        }

        var products = std.ArrayList([]const KnownValue).empty;
        defer products.deinit(self.pass.allocator);
        const current = try self.pass.allocator.alloc(KnownValue, known_values.len);
        defer self.pass.allocator.free(current);

        try self.appendKnownValueProducts(options, 0, current, &products);
        return try self.pass.arena.allocator().dupe([]const KnownValue, products.items);
    }

    fn appendKnownValueProducts(
        self: *Cloner,
        options: []const []const KnownValue,
        index: usize,
        current: []KnownValue,
        products: *std.ArrayList([]const KnownValue),
    ) Allocator.Error!void {
        if (index == options.len) {
            try products.append(self.pass.allocator, try self.pass.arena.allocator().dupe(KnownValue, current));
            return;
        }

        for (options[index]) |option| {
            current[index] = option;
            try self.appendKnownValueProducts(options, index + 1, current, products);
        }
    }

    fn expandKnownValue(self: *Cloner, known_value: KnownValue) Allocator.Error![]const KnownValue {
        return switch (known_value) {
            .any,
            .leaf,
            => try self.singleKnownValue(known_value),
            .tag => |tag| try self.expandKnownTag(tag),
            .record => |record| try self.expandKnownRecord(record),
            .tuple => |tuple| try self.expandKnownTuple(tuple),
            .nominal => |nominal| try self.expandKnownNominal(nominal),
            .callable => |callable| try self.expandKnownCallable(callable),
            .finite_tags => |finite_tags| try self.expandKnownTags(finite_tags),
            .finite_callables => |finite_callables| try self.expandKnownCallables(finite_callables),
        };
    }

    fn singleKnownValue(self: *Cloner, known_value: KnownValue) Allocator.Error![]const KnownValue {
        const values = try self.pass.arena.allocator().alloc(KnownValue, 1);
        values[0] = known_value;
        return values;
    }

    fn expandKnownRecord(self: *Cloner, record: KnownRecord) Allocator.Error![]const KnownValue {
        const child_values = try self.pass.allocator.alloc(KnownValue, record.fields.len);
        defer self.pass.allocator.free(child_values);
        for (record.fields, 0..) |field, index| {
            child_values[index] = field.known_value;
        }

        const products = try self.knownValueProducts(child_values);
        const alternatives = try self.pass.arena.allocator().alloc(KnownValue, products.len);
        for (products, alternatives) |product, *out| {
            const fields = try self.pass.arena.allocator().alloc(KnownField, record.fields.len);
            for (record.fields, product, fields) |field, field_known_value, *field_out| {
                field_out.* = .{
                    .name = field.name,
                    .known_value = field_known_value,
                };
            }
            out.* = .{ .record = .{
                .ty = record.ty,
                .fields = fields,
            } };
        }
        return alternatives;
    }

    fn expandKnownTuple(self: *Cloner, tuple: KnownTuple) Allocator.Error![]const KnownValue {
        const products = try self.knownValueProducts(tuple.items);
        const alternatives = try self.pass.arena.allocator().alloc(KnownValue, products.len);
        for (products, alternatives) |product, *out| {
            out.* = .{ .tuple = .{
                .ty = tuple.ty,
                .items = product,
            } };
        }
        return alternatives;
    }

    fn expandKnownNominal(self: *Cloner, nominal: KnownNominal) Allocator.Error![]const KnownValue {
        const backing_alternatives = try self.expandKnownValue(nominal.backing.*);
        const alternatives = try self.pass.arena.allocator().alloc(KnownValue, backing_alternatives.len);
        for (backing_alternatives, alternatives) |backing, *out| {
            const stored = try self.pass.arena.allocator().create(KnownValue);
            stored.* = backing;
            out.* = .{ .nominal = .{
                .ty = nominal.ty,
                .backing = stored,
            } };
        }
        return alternatives;
    }

    fn expandKnownTag(self: *Cloner, tag: KnownTag) Allocator.Error![]const KnownValue {
        const products = try self.knownValueProducts(tag.payloads);
        const alternatives = try self.pass.arena.allocator().alloc(KnownValue, products.len);
        for (products, alternatives) |product, *out| {
            out.* = .{ .tag = .{
                .ty = tag.ty,
                .name = tag.name,
                .payloads = product,
            } };
        }
        return alternatives;
    }

    fn expandKnownTags(self: *Cloner, finite_tags: KnownTags) Allocator.Error![]const KnownValue {
        var alternatives = std.ArrayList(KnownValue).empty;
        defer alternatives.deinit(self.pass.allocator);
        for (finite_tags.alternatives) |tag| {
            const expanded = try self.expandKnownTag(tag);
            try alternatives.appendSlice(self.pass.allocator, expanded);
        }
        return try self.pass.arena.allocator().dupe(KnownValue, alternatives.items);
    }

    fn expandKnownCallable(self: *Cloner, callable: KnownCallable) Allocator.Error![]const KnownValue {
        const products = try self.knownValueProducts(callable.captures);
        const alternatives = try self.pass.arena.allocator().alloc(KnownValue, products.len);
        for (products, alternatives) |product, *out| {
            out.* = .{ .callable = .{
                .ty = callable.ty,
                .fn_id = callable.fn_id,
                .captures = product,
            } };
        }
        return alternatives;
    }

    fn expandKnownCallables(self: *Cloner, finite_callables: KnownCallables) Allocator.Error![]const KnownValue {
        var alternatives = std.ArrayList(KnownValue).empty;
        defer alternatives.deinit(self.pass.allocator);
        for (finite_callables.alternatives) |callable| {
            const expanded = try self.expandKnownCallable(callable);
            try alternatives.appendSlice(self.pass.allocator, expanded);
        }
        return try self.pass.arena.allocator().dupe(KnownValue, alternatives.items);
    }

    fn stateForDemandedKnownValues(self: *Cloner, states: []const SparseStateLoopState, values: []const DemandedKnownValue) ?SparseStateLoopState {
        var found: ?SparseStateLoopState = null;
        for (states) |state| {
            if (!demandedKnownValuesEql(self.pass.program, state.values, values)) continue;
            if (found != null) Common.invariant("state_loop key matched multiple states");
            found = state;
        }
        return found;
    }

    fn appendSparseState(
        self: *Cloner,
        states: *std.ArrayList(SparseStateLoopState),
        values: []const DemandedKnownValue,
    ) Allocator.Error!SparseStateLoopState {
        const id: Ast.StateLoopStateId = @enumFromInt(@as(u32, @intCast(self.pass.program.state_loop_states.items.len)));
        try self.pass.program.state_loop_states.append(self.pass.program.allocator, undefined);
        const state = SparseStateLoopState{
            .id = id,
            .values = values,
        };
        try states.append(self.pass.allocator, state);
        return state;
    }

    fn demandedStateValuesFromValues(
        self: *Cloner,
        demands: []const ValueDemand,
        values: []const Value,
    ) Common.LowerError![]const DemandedKnownValue {
        if (demands.len != values.len) Common.invariant("state_loop demand arity differed from continue values");
        const demanded_values = try self.pass.arena.allocator().alloc(DemandedKnownValue, values.len);
        try self.refreshDemandedKnownValuesFromValueDemands(values, demands, demanded_values);
        return demanded_values;
    }

    fn refreshDemandedKnownValuesFromValueDemands(
        self: *Cloner,
        values: []const Value,
        demands: []const ValueDemand,
        out_values: []DemandedKnownValue,
    ) Common.LowerError!void {
        if (demands.len != values.len or out_values.len != values.len) {
            Common.invariant("state_loop demand/value arity differed while refreshing demanded state");
        }
        for (demands, values, out_values) |demand, value, *out| {
            const ty = valueType(self.pass.program, value);
            out.* = (try self.demandedKnownValueFromValueDemand(value, demand)) orelse blk: {
                break :blk DemandedKnownValue{ .any = ty };
            };
        }
    }

    fn demandedKnownValueFromValueDemand(
        self: *Cloner,
        value: Value,
        demand: ValueDemand,
    ) Common.LowerError!?DemandedKnownValue {
        if (value == .private_state) {
            return try self.demandedKnownValueFromPrivateStateDemand(value.private_state, demand);
        }

        switch (value) {
            .let_,
            .if_,
            .match_,
            => {
                if (try self.privateStateValueFromValueDemand(value, demand)) |private_state| {
                    if (try self.demandedKnownValueFromPrivateStateDemand(private_state, demand)) |demanded| {
                        return demanded;
                    }
                }
            },
            else => {},
        }

        if (valueDemandRequiresPrivateState(demand)) {
            if (try self.privateStateValueFromValueDemand(value, demand)) |private_state| {
                if (try self.demandedKnownValueFromPrivateStateDemand(private_state, demand)) |demanded| {
                    return demanded;
                }
            }
        }

        if (try self.pass.knownValueFromValue(value)) |known_value| {
            return try demandedKnownValueFromDemand(self, self.pass.program, self.pass.arena.allocator(), known_value, demand);
        }

        const private_state = (try self.privateStateValueFromValueDemand(value, demand)) orelse return null;
        return try self.demandedKnownValueFromPrivateStateDemand(private_state, demand);
    }

    fn demandedKnownValueFromPrivateStateDemand(
        self: *Cloner,
        value: PrivateStateValue,
        demand: ValueDemand,
    ) Common.LowerError!?DemandedKnownValue {
        const resolved_demand = self.resolveLoopDemandRef(demand);
        if (value == .leaf) {
            return switch (resolved_demand) {
                .none => null,
                else => DemandedKnownValue{ .leaf = value.leaf.ty },
            };
        }

        switch (value) {
            .nominal => |nominal| {
                const backing = nominal.backing orelse return null;
                const backing_demand = switch (resolved_demand) {
                    .nominal => |nominal_demand| nominal_demand.*,
                    else => resolved_demand,
                };
                const demanded_backing = (try self.demandedKnownValueFromPrivateStateDemand(backing.*, backing_demand)) orelse return null;
                const stored = try self.pass.arena.allocator().create(DemandedKnownValue);
                stored.* = demanded_backing;
                return .{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = stored,
                } };
            },
            else => {},
        }

        return switch (resolved_demand) {
            .none => null,
            .materialize => blk: {
                if (!privateStateCanMaterializePublic(self.pass.program, value)) break :blk null;
                const known_value = (try knownValueFromPrivateState(self.pass.program, self.pass.arena.allocator(), value)) orelse
                    Common.invariant("complete private state failed known-value conversion");
                break :blk try materializedDemandedKnownValue(self.pass.arena.allocator(), known_value);
            },
            .loop_param => Common.invariant("loop demand reference did not resolve before demanded-known private-state conversion"),
            .nominal => null,
            .record => |field_demands| blk: {
                const record = switch (value) {
                    .record => |record| record,
                    else => break :blk null,
                };

                var fields = std.ArrayList(DemandedKnownField).empty;
                defer fields.deinit(self.pass.allocator);
                for (field_demands) |field_demand| {
                    if (field_demand.demand.* == .none) continue;
                    const field_value = privateStateFieldByName(record.fields, field_demand.name) orelse break :blk null;
                    const demanded_field = (try self.demandedKnownValueFromPrivateStateDemand(field_value, field_demand.demand.*)) orelse break :blk null;
                    try fields.append(self.pass.allocator, .{
                        .name = field_demand.name,
                        .known_value = demanded_field,
                    });
                }
                if (fields.items.len == 0) break :blk null;
                break :blk DemandedKnownValue{ .record = .{
                    .ty = record.ty,
                    .fields = try self.pass.arena.allocator().dupe(DemandedKnownField, fields.items),
                } };
            },
            .tuple => |item_demands| blk: {
                const tuple = switch (value) {
                    .tuple => |tuple| tuple,
                    else => break :blk null,
                };

                const items = (try self.demandedKnownIndexedValuesFromPrivateStateItemDemands(tuple.items, item_demands)) orelse break :blk null;
                if (items.len == 0) break :blk null;
                break :blk DemandedKnownValue{ .tuple = .{
                    .ty = tuple.ty,
                    .items = items,
                } };
            },
            .tag => |tag_demand| blk: {
                if (privateStateFiniteTags(value)) |finite_tags| {
                    const alternatives = try self.pass.arena.allocator().alloc(DemandedKnownTag, finite_tags.alternatives.len);
                    for (finite_tags.alternatives, alternatives) |alternative, *out| {
                        out.* = .{
                            .ty = alternative.ty,
                            .name = alternative.name,
                            .payloads = (try self.demandedKnownIndexedValuesFromPrivateStateItemDemands(alternative.payloads, tag_demand.payloads)) orelse break :blk null,
                        };
                    }
                    break :blk DemandedKnownValue{ .finite_tags = .{
                        .ty = finite_tags.ty,
                        .alternatives = alternatives,
                    } };
                }

                const tag = switch (value) {
                    .tag => |tag| tag,
                    else => break :blk null,
                };
                break :blk DemandedKnownValue{ .tag = .{
                    .ty = tag.ty,
                    .name = tag.name,
                    .payloads = (try self.demandedKnownIndexedValuesFromPrivateStateItemDemands(tag.payloads, tag_demand.payloads)) orelse break :blk null,
                } };
            },
            .callable => |callable_demand| blk: {
                var effective_callable_demand = callable_demand;
                if (callable_demand.result) |result_demand| {
                    if (try self.callableDemandForPrivateStateValueWithResultDemand(value, result_demand.*)) |derived| {
                        const merged = try self.pass.mergeValueDemand(.{ .callable = effective_callable_demand }, derived);
                        if (merged != .callable) break :blk null;
                        effective_callable_demand = merged.callable;
                    }
                    if (privateStateCallable(value)) |private_callable| {
                        if (private_callable.captures.len > 0) {
                            const carry_demand = try self.valueDemandFromPrivateCallableShape(private_callable);
                            if (carry_demand == .callable) {
                                const merged = try self.pass.mergeValueDemand(.{ .callable = effective_callable_demand }, carry_demand);
                                if (merged != .callable) break :blk null;
                                effective_callable_demand = merged.callable;
                            }
                        }
                    }
                    if (privateStateFiniteCallables(value)) |_| {
                        const carry_demand = try self.valueDemandFromPrivateStateShape(value);
                        if (carry_demand == .callable) {
                            const merged = try self.pass.mergeValueDemand(.{ .callable = effective_callable_demand }, carry_demand);
                            if (merged != .callable) break :blk null;
                            effective_callable_demand = merged.callable;
                        }
                    }
                }

                if (privateStateFiniteCallables(value)) |finite_callables| {
                    const alternatives = try self.pass.arena.allocator().alloc(DemandedKnownCallable, finite_callables.alternatives.len);
                    for (finite_callables.alternatives, alternatives) |alternative, *out| {
                        out.* = .{
                            .ty = alternative.ty,
                            .fn_id = alternative.fn_id,
                            .captures = (try self.demandedKnownIndexedValuesFromPrivateStateCallableCaptureDemands(alternative, effective_callable_demand.captures)) orelse break :blk null,
                        };
                    }
                    break :blk DemandedKnownValue{ .finite_callables = .{
                        .ty = finite_callables.ty,
                        .alternatives = alternatives,
                    } };
                }

                const callable = switch (value) {
                    .callable => |callable| callable,
                    else => break :blk null,
                };
                break :blk DemandedKnownValue{ .callable = .{
                    .ty = callable.ty,
                    .fn_id = callable.fn_id,
                    .captures = (try self.demandedKnownIndexedValuesFromPrivateStateCallableCaptureDemands(callable, effective_callable_demand.captures)) orelse break :blk null,
                } };
            },
        };
    }

    fn demandedKnownIndexedValuesFromPrivateStateItemDemands(
        self: *Cloner,
        indexed: []const PrivateStateIndexedValue,
        demands: []const ItemDemand,
    ) Common.LowerError!?[]const DemandedKnownIndexedValue {
        var values = std.ArrayList(DemandedKnownIndexedValue).empty;
        defer values.deinit(self.pass.allocator);
        for (demands) |demand| {
            if (demand.demand.* == .none) continue;
            const child = privateStateIndexedValueByIndex(indexed, demand.index) orelse return null;
            const demanded_child = (try self.demandedKnownValueFromPrivateStateDemand(child, demand.demand.*)) orelse return null;
            try values.append(self.pass.allocator, .{
                .index = demand.index,
                .known_value = demanded_child,
            });
        }
        return try self.pass.arena.allocator().dupe(DemandedKnownIndexedValue, values.items);
    }

    fn demandedKnownIndexedValuesFromPrivateStateCallableCaptureDemands(
        self: *Cloner,
        callable: PrivateStateCallable,
        demands: []const ValueDemand,
    ) Common.LowerError!?[]const DemandedKnownIndexedValue {
        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(source_fn.captures);

        var values = std.ArrayList(DemandedKnownIndexedValue).empty;
        defer values.deinit(self.pass.allocator);

        var index: usize = 0;
        while (index < source_captures.len and index < demands.len) : (index += 1) {
            const demand = demands[index];
            if (demand == .none) continue;
            const child = privateStateIndexedValueByIndex(callable.captures, @intCast(index)) orelse return null;
            const demanded_child = (try self.demandedKnownValueFromPrivateStateDemand(child, demand)) orelse return null;
            try values.append(self.pass.allocator, .{
                .index = @intCast(index),
                .known_value = demanded_child,
            });
        }

        return try self.pass.arena.allocator().dupe(DemandedKnownIndexedValue, values.items);
    }

    fn cloneLoopUnwrappedLet(
        self: *Cloner,
        ty: Type.TypeId,
        loop: anytype,
        params: []const Ast.TypedLocal,
        values: []const Value,
        result_demand: ValueDemand,
    ) Common.LowerError!?Ast.ExprId {
        for (values, 0..) |value, value_index| {
            const let_value = switch (value) {
                .let_ => |let_value| let_value,
                else => continue,
            };

            var unwrapped_values = try self.pass.allocator.dupe(Value, values);
            defer self.pass.allocator.free(unwrapped_values);
            unwrapped_values[value_index] = let_value.body.*;

            const change_start = self.changes.items.len;
            defer self.restore(change_start);
            try self.bindPendingLetKnownValues(let_value.lets);

            const body = try self.materialize(try self.cloneLoopFromInitialValues(ty, loop, params, unwrapped_values, result_demand));
            return try self.wrapPendingLetsAroundExpr(ty, body, let_value.lets);
        }

        return null;
    }

    fn cloneLoopDistributedIf(
        self: *Cloner,
        ty: Type.TypeId,
        loop: anytype,
        params: []const Ast.TypedLocal,
        values: []const Value,
        result_demand: ValueDemand,
    ) Common.LowerError!?Ast.ExprId {
        for (values, 0..) |value, value_index| {
            const if_value = switch (value) {
                .if_ => |if_value| if_value,
                else => continue,
            };
            const branches = try self.pass.allocator.alloc(Ast.IfBranch, if_value.branches.len);
            defer self.pass.allocator.free(branches);
            var branch_values = try self.pass.allocator.dupe(Value, values);
            defer self.pass.allocator.free(branch_values);

            for (if_value.branches, 0..) |branch, branch_index| {
                branch_values[value_index] = branch.body;
                branches[branch_index] = .{
                    .cond = branch.cond,
                    .body = try self.materialize(try self.cloneLoopFromInitialValues(ty, loop, params, branch_values, result_demand)),
                };
            }

            branch_values[value_index] = if_value.final_else.*;
            const final_else = try self.materialize(try self.cloneLoopFromInitialValues(ty, loop, params, branch_values, result_demand));

            return try self.addExpr(.{ .ty = ty, .data = .{ .if_ = .{
                .branches = try self.pass.program.addIfBranchSpan(branches),
                .final_else = final_else,
            } } });
        }

        return null;
    }

    fn projectableLoopKnownValueForValue(self: *Cloner, known_value: KnownValue, value: Value) Allocator.Error!?KnownValue {
        return switch (value) {
            .record => |record_value| blk: {
                const record_known_value = switch (known_value) {
                    .record => |record| record,
                    else => break :blk null,
                };
                if (record_known_value.fields.len != record_value.fields.len) Common.invariant("record loop state changed field count before specialization");
                const fields = try self.pass.arena.allocator().alloc(KnownField, record_known_value.fields.len);
                for (record_known_value.fields, record_value.fields, 0..) |field_known_value, field_value, index| {
                    if (field_known_value.name != field_value.name) Common.invariant("record loop state changed field order before specialization");
                    const projected = try self.projectableLoopKnownValueForValue(field_known_value.known_value, field_value.value);
                    fields[index] = .{
                        .name = field_known_value.name,
                        .known_value = projected orelse .{ .any = known_valueType(field_known_value.known_value) },
                    };
                }
                break :blk KnownValue{ .record = .{
                    .ty = record_known_value.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple_value| blk: {
                const tuple_known_value = switch (known_value) {
                    .tuple => |tuple| tuple,
                    else => break :blk null,
                };
                if (tuple_known_value.items.len != tuple_value.items.len) Common.invariant("tuple loop state changed item count before specialization");
                const items = try self.pass.arena.allocator().alloc(KnownValue, tuple_known_value.items.len);
                for (tuple_known_value.items, tuple_value.items, 0..) |item_known_value, item_value, index| {
                    items[index] = (try self.projectableLoopKnownValueForValue(item_known_value, item_value)) orelse
                        .{ .any = known_valueType(item_known_value) };
                }
                break :blk KnownValue{ .tuple = .{
                    .ty = tuple_known_value.ty,
                    .items = items,
                } };
            },
            .nominal => |nominal_value| blk: {
                const nominal_known_value = switch (known_value) {
                    .nominal => |nominal| nominal,
                    else => break :blk null,
                };
                const backing = (try self.projectableLoopKnownValueForValue(nominal_known_value.backing.*, nominal_value.backing.*)) orelse break :blk null;
                const stored = try self.pass.arena.allocator().create(KnownValue);
                stored.* = backing;
                break :blk KnownValue{ .nominal = .{
                    .ty = nominal_known_value.ty,
                    .backing = stored,
                } };
            },
            .callable => |callable_value| blk: {
                const callable_known_value = switch (known_value) {
                    .callable => |callable| callable,
                    .finite_callables => |finite_callables| {
                        for (finite_callables.alternatives) |alternative| {
                            if (!sameType(self.pass.program, alternative.ty, callable_value.ty) or
                                !callableTargetMatches(self.pass.program, alternative.fn_id, callable_value.fn_id) or
                                alternative.captures.len != callable_value.captures.len)
                            {
                                continue;
                            }

                            const captures = try self.pass.arena.allocator().alloc(KnownValue, alternative.captures.len);
                            for (alternative.captures, callable_value.captures, 0..) |capture_known_value, capture_value, index| {
                                const projected = try self.projectableLoopKnownValueForValue(capture_known_value, capture_value);
                                captures[index] = projected orelse .{ .any = known_valueType(capture_known_value) };
                            }
                            break :blk KnownValue{ .callable = .{
                                .ty = alternative.ty,
                                .fn_id = alternative.fn_id,
                                .captures = captures,
                            } };
                        }
                        break :blk null;
                    },
                    else => break :blk null,
                };
                if (!sameType(self.pass.program, callable_known_value.ty, callable_value.ty) or
                    !callableTargetMatches(self.pass.program, callable_known_value.fn_id, callable_value.fn_id) or
                    callable_known_value.captures.len != callable_value.captures.len)
                {
                    break :blk null;
                }
                const captures = try self.pass.arena.allocator().alloc(KnownValue, callable_known_value.captures.len);
                for (callable_known_value.captures, callable_value.captures, 0..) |capture_known_value, capture_value, index| {
                    const projected = try self.projectableLoopKnownValueForValue(capture_known_value, capture_value);
                    captures[index] = projected orelse .{ .any = known_valueType(capture_known_value) };
                }
                break :blk KnownValue{ .callable = .{
                    .ty = callable_known_value.ty,
                    .fn_id = callable_known_value.fn_id,
                    .captures = captures,
                } };
            },
            .finite_tags => |finite_value| blk: {
                const finite_known_value = switch (known_value) {
                    .finite_tags => |finite_tags| finite_tags,
                    else => break :blk null,
                };
                if (!sameType(self.pass.program, finite_known_value.ty, finite_value.ty) or
                    finite_known_value.alternatives.len != finite_value.alternatives.len)
                {
                    break :blk null;
                }
                const alternatives = try self.pass.arena.allocator().alloc(KnownTag, finite_known_value.alternatives.len);
                for (finite_known_value.alternatives, finite_value.alternatives, 0..) |known_alternative, value_alternative, index| {
                    if (!sameType(self.pass.program, known_alternative.ty, value_alternative.ty) or
                        known_alternative.name != value_alternative.name or
                        known_alternative.payloads.len != value_alternative.payloads.len)
                    {
                        break :blk null;
                    }
                    const payloads = try self.pass.arena.allocator().alloc(KnownValue, known_alternative.payloads.len);
                    for (known_alternative.payloads, value_alternative.payloads, 0..) |payload_known_value, payload_value, payload_index| {
                        const projected = try self.projectableLoopKnownValueForValue(payload_known_value, payload_value);
                        payloads[payload_index] = projected orelse .{ .any = known_valueType(payload_known_value) };
                    }
                    alternatives[index] = .{
                        .ty = known_alternative.ty,
                        .name = known_alternative.name,
                        .payloads = payloads,
                    };
                }
                break :blk KnownValue{ .finite_tags = .{
                    .ty = finite_known_value.ty,
                    .alternatives = alternatives,
                } };
            },
            .finite_callables => |finite_value| blk: {
                const finite_known_value = switch (known_value) {
                    .finite_callables => |finite_callables| finite_callables,
                    else => break :blk null,
                };
                if (!sameType(self.pass.program, finite_known_value.ty, finite_value.ty) or
                    finite_known_value.alternatives.len != finite_value.alternatives.len)
                {
                    break :blk null;
                }
                const alternatives = try self.pass.arena.allocator().alloc(KnownCallable, finite_known_value.alternatives.len);
                for (finite_known_value.alternatives, finite_value.alternatives, 0..) |known_alternative, value_alternative, index| {
                    if (!sameType(self.pass.program, known_alternative.ty, value_alternative.ty) or
                        !callableTargetMatches(self.pass.program, known_alternative.fn_id, value_alternative.fn_id) or
                        known_alternative.captures.len != value_alternative.captures.len)
                    {
                        break :blk null;
                    }
                    const captures = try self.pass.arena.allocator().alloc(KnownValue, known_alternative.captures.len);
                    for (known_alternative.captures, value_alternative.captures, 0..) |capture_known_value, capture_value, capture_index| {
                        const projected = try self.projectableLoopKnownValueForValue(capture_known_value, capture_value);
                        captures[capture_index] = projected orelse .{ .any = known_valueType(capture_known_value) };
                    }
                    alternatives[index] = .{
                        .ty = known_alternative.ty,
                        .fn_id = known_alternative.fn_id,
                        .captures = captures,
                    };
                }
                break :blk KnownValue{ .finite_callables = .{
                    .ty = finite_known_value.ty,
                    .alternatives = alternatives,
                } };
            },
            .let_ => |let_value| try self.projectableLoopKnownValueForValue(known_value, let_value.body.*),
            .if_ => null,
            .match_ => null,
            .private_state => null,
            .expr_with_known_value => |known| if (known_valueCanProjectFromExpr(known_value))
                known_value
            else if (canReadFieldsFromExpr(self.pass.program, known.expr))
                try self.projectableLoopKnownValueFromExpr(known.known_value)
            else if (known_valueCanProjectFromExpr(known.known_value))
                known.known_value
            else
                null,
            .tag => |tag_value| switch (known_value) {
                .tag => |tag_known_value| blk: {
                    if (!sameType(self.pass.program, tag_known_value.ty, tag_value.ty) or
                        tag_known_value.name != tag_value.name or
                        tag_known_value.payloads.len != tag_value.payloads.len)
                    {
                        break :blk null;
                    }
                    const payloads = try self.pass.arena.allocator().alloc(KnownValue, tag_known_value.payloads.len);
                    for (tag_known_value.payloads, tag_value.payloads, 0..) |payload_known_value, payload_value, index| {
                        const projected = try self.projectableLoopKnownValueForValue(payload_known_value, payload_value);
                        payloads[index] = projected orelse .{ .any = known_valueType(payload_known_value) };
                    }
                    break :blk KnownValue{ .tag = .{
                        .ty = tag_known_value.ty,
                        .name = tag_known_value.name,
                        .payloads = payloads,
                    } };
                },
                .finite_tags => |finite_tags| blk: {
                    for (finite_tags.alternatives) |alternative| {
                        if (!sameType(self.pass.program, alternative.ty, tag_value.ty) or
                            alternative.name != tag_value.name or
                            alternative.payloads.len != tag_value.payloads.len)
                        {
                            continue;
                        }

                        const payloads = try self.pass.arena.allocator().alloc(KnownValue, alternative.payloads.len);
                        for (alternative.payloads, tag_value.payloads, 0..) |payload_known_value, payload_value, index| {
                            const projected = try self.projectableLoopKnownValueForValue(payload_known_value, payload_value);
                            payloads[index] = projected orelse .{ .any = known_valueType(payload_known_value) };
                        }
                        break :blk KnownValue{ .tag = .{
                            .ty = alternative.ty,
                            .name = alternative.name,
                            .payloads = payloads,
                        } };
                    }
                    break :blk null;
                },
                else => null,
            },
            .expr,
            => if (known_valueCanProjectFromExpr(known_value)) known_value else null,
        };
    }

    fn projectableLoopKnownValueFromExpr(self: *Cloner, known_value: KnownValue) Allocator.Error!?KnownValue {
        if (known_valueCanProjectFromExpr(known_value)) return known_value;

        return switch (known_value) {
            .any => known_value,
            .leaf => known_value,
            .record => |record| blk: {
                const fields = try self.pass.arena.allocator().alloc(KnownField, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    out.* = .{
                        .name = field.name,
                        .known_value = (try self.projectableLoopKnownValueFromExpr(field.known_value)) orelse
                            .{ .any = known_valueType(field.known_value) },
                    };
                }
                break :blk KnownValue{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| blk: {
                const items = try self.pass.arena.allocator().alloc(KnownValue, tuple.items.len);
                for (tuple.items, items) |item, *out| {
                    out.* = (try self.projectableLoopKnownValueFromExpr(item)) orelse
                        .{ .any = known_valueType(item) };
                }
                break :blk KnownValue{ .tuple = .{
                    .ty = tuple.ty,
                    .items = items,
                } };
            },
            .nominal => |nominal| blk: {
                const backing = (try self.projectableLoopKnownValueFromExpr(nominal.backing.*)) orelse break :blk null;
                const stored = try self.pass.arena.allocator().create(KnownValue);
                stored.* = backing;
                break :blk KnownValue{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = stored,
                } };
            },
            .tag,
            .callable,
            .finite_tags,
            .finite_callables,
            => null,
        };
    }

    fn cloneBlock(self: *Cloner, ty: Type.TypeId, block: anytype) Common.LowerError!Ast.ExprId {
        const change_start = self.changes.items.len;
        defer self.restore(change_start);

        const source = try self.pass.allocator.dupe(Ast.StmtId, self.pass.program.stmtSpan(block.statements));
        defer self.pass.allocator.free(source);

        var statements = std.ArrayList(Ast.StmtId).empty;
        defer statements.deinit(self.pass.allocator);
        for (source, 0..) |stmt, index| {
            try self.cloneStmtInto(stmt, &statements, .{
                .statements = source[index + 1 ..],
                .final_expr = block.final_expr,
            }, .materialize);
        }

        return try self.addExpr(.{ .ty = ty, .data = .{ .block = .{
            .statements = try self.pass.program.addStmtSpan(statements.items),
            .final_expr = try self.cloneExpr(block.final_expr),
        } } });
    }

    fn cloneBlockValue(self: *Cloner, ty: Type.TypeId, block: anytype) Common.LowerError!Value {
        return try self.cloneBlockValueWithFinalDemand(ty, block, false);
    }

    fn cloneBlockValueDemandingKnownValue(self: *Cloner, ty: Type.TypeId, block: anytype) Common.LowerError!Value {
        return try self.cloneBlockValueWithFinalDemand(ty, block, true);
    }

    fn cloneBlockValueWithFinalDemand(
        self: *Cloner,
        ty: Type.TypeId,
        block: anytype,
        demand_final_known_value: bool,
    ) Common.LowerError!Value {
        const change_start = self.changes.items.len;
        defer self.restore(change_start);

        const source = try self.pass.allocator.dupe(Ast.StmtId, self.pass.program.stmtSpan(block.statements));
        defer self.pass.allocator.free(source);

        var statements = std.ArrayList(Ast.StmtId).empty;
        defer statements.deinit(self.pass.allocator);
        for (source, 0..) |stmt, index| {
            try self.cloneStmtInto(stmt, &statements, .{
                .statements = source[index + 1 ..],
                .final_expr = block.final_expr,
            }, .materialize);
        }

        const final_value = if (demand_final_known_value)
            try self.cloneExprValueDemandingKnownValue(block.final_expr)
        else
            try self.cloneExprValue(block.final_expr);
        if (demand_final_known_value) {
            if (statements.items.len == 0) return final_value;

            var pending_lets = std.ArrayList(PendingLet).empty;
            defer pending_lets.deinit(self.pass.allocator);
            if (try self.appendPendingLetsFromStatements(statements.items, &pending_lets)) {
                return try self.wrapPendingLets(final_value, pending_lets.items, true);
            }
        }

        const final_expr = try self.materialize(final_value);
        const block_expr = try self.addExpr(.{ .ty = ty, .data = .{ .block = .{
            .statements = try self.pass.program.addStmtSpan(statements.items),
            .final_expr = final_expr,
        } } });

        const known_value = (try self.pass.knownValueFromValue(final_value)) orelse return .{ .expr = block_expr };
        return .{ .expr_with_known_value = .{
            .expr = block_expr,
            .known_value = known_value,
        } };
    }

    fn cloneContinue(self: *Cloner, ty: Type.TypeId, continue_: anytype) Common.LowerError!Ast.ExprData {
        const loop = self.loop_stack.getLastOrNull() orelse {
            const state_loop = self.state_loop_stack.getLastOrNull() orelse return .{ .continue_ = .{
                .values = try self.cloneExprSpan(continue_.values),
            } };
            return try self.cloneStateContinue(ty, state_loop, continue_);
        };
        const values = self.pass.program.exprSpan(continue_.values);
        const source_values = try self.pass.allocator.dupe(Ast.ExprId, values);
        defer self.pass.allocator.free(source_values);
        if (source_values.len != loop.values.len) Common.invariant("continue value count differed from active loop arity");

        var pending_statements = std.ArrayList(Ast.StmtId).empty;
        defer pending_statements.deinit(self.pass.allocator);

        const pending_change_start = self.changes.items.len;
        defer self.restore(pending_change_start);

        const continue_values = try self.pass.allocator.alloc(Value, source_values.len);
        defer self.pass.allocator.free(continue_values);

        for (source_values, 0..) |value_expr, index| {
            var value = try self.cloneExprValueDemandingKnownValue(value_expr);
            while (value == .let_) {
                try self.appendPendingLetStmts(value.let_.lets, &pending_statements);
                try self.bindPendingLetKnownValues(value.let_.lets);
                value = value.let_.body.*;
            }
            value = try self.hoistNestedLetsFromValue(value, &pending_statements);
            continue_values[index] = value;
        }

        const continue_data = try self.cloneContinueDataFromValues(ty, loop, continue_values);
        if (pending_statements.items.len == 0) return continue_data;

        const continue_expr = try self.addExpr(.{ .ty = ty, .data = continue_data });
        return .{ .block = .{
            .statements = try self.pass.program.addStmtSpan(pending_statements.items),
            .final_expr = continue_expr,
        } };
    }

    fn cloneStateContinue(self: *Cloner, ty: Type.TypeId, state_loop: SparseStateLoopPattern, continue_: anytype) Common.LowerError!Ast.ExprData {
        const values = self.pass.program.exprSpan(continue_.values);
        const source_values = try self.pass.allocator.dupe(Ast.ExprId, values);
        defer self.pass.allocator.free(source_values);
        if (state_loop.states.items.len == 0) Common.invariant("state_continue had no possible target states");

        const arity = state_loop.states.items[0].values.len;
        if (source_values.len != arity) Common.invariant("state_continue value count differed from state_loop arity");

        const continue_demands = try self.stateLoopValueDemands(state_loop, arity);
        defer self.pass.allocator.free(continue_demands);

        var pending_statements = std.ArrayList(Ast.StmtId).empty;
        defer pending_statements.deinit(self.pass.allocator);

        const pending_change_start = self.changes.items.len;
        defer self.restore(pending_change_start);

        const continue_values = try self.pass.allocator.alloc(Value, source_values.len);
        defer self.pass.allocator.free(continue_values);

        for (source_values, 0..) |value_expr, index| {
            var value = try self.cloneExprValueWithDemand(value_expr, continue_demands[index]);
            while (value == .let_) {
                try self.appendPendingLetStmts(value.let_.lets, &pending_statements);
                try self.bindPendingLetKnownValues(value.let_.lets);
                value = value.let_.body.*;
            }
            value = try self.hoistNestedLetsFromValue(value, &pending_statements);
            continue_values[index] = value;
        }

        const continue_data = try self.cloneStateContinueDataFromValues(ty, state_loop, continue_values);
        if (pending_statements.items.len == 0) return continue_data;

        const continue_expr = try self.addExpr(.{ .ty = ty, .data = continue_data });
        return .{ .block = .{
            .statements = try self.pass.program.addStmtSpan(pending_statements.items),
            .final_expr = continue_expr,
        } };
    }

    fn stateLoopValueDemands(self: *Cloner, state_loop: SparseStateLoopPattern, arity: usize) Allocator.Error![]ValueDemand {
        const demands = try self.pass.allocator.alloc(ValueDemand, arity);
        @memset(demands, .none);
        if (state_loop.demands.len != arity) Common.invariant("state_loop analysis demand arity differed from state arity");
        for (state_loop.demands, demands) |demand, *out| {
            out.* = demand;
        }

        for (state_loop.states.items) |state| {
            if (state.values.len != arity) Common.invariant("state_loop state arity differed while computing continue demand");
            for (state.values, 0..) |known_value, index| {
                demands[index] = try self.pass.mergeValueDemand(
                    demands[index],
                    try self.pass.valueDemandFromDemandedKnownValue(known_value),
                );
            }
        }

        return demands;
    }

    fn selectCorrelatedStateIfBranch(
        self: *Cloner,
        original_values: []const Value,
        selected_values: []Value,
        demands: []const ValueDemand,
        selected_index: usize,
        control: IfValue,
        branch_index: usize,
        final_else: bool,
    ) Common.LowerError!void {
        for (original_values, selected_values, 0..) |original, *selected, index| {
            if (index == selected_index) continue;
            const other = switch (original) {
                .if_ => |if_value| if_value,
                else => continue,
            };
            if (!ifValueControlEql(control, other)) continue;
            const branch_body = if (final_else)
                other.final_else.*
            else
                other.branches[branch_index].body;
            selected.* = try self.applyValueDemand(branch_body, demands[index]);
        }
    }

    fn selectCorrelatedIfBranch(
        original_values: []const Value,
        selected_values: []Value,
        selected_index: usize,
        control: IfValue,
        branch_index: usize,
        final_else: bool,
    ) void {
        for (original_values, selected_values, 0..) |original, *selected, index| {
            if (index == selected_index) continue;
            const other = switch (original) {
                .if_ => |if_value| if_value,
                else => continue,
            };
            if (!ifValueControlEql(control, other)) continue;
            selected.* = if (final_else)
                other.final_else.*
            else
                other.branches[branch_index].body;
        }
    }

    fn selectCorrelatedMatchBranch(
        original_values: []const Value,
        selected_values: []Value,
        selected_index: usize,
        control: MatchValue,
        branch_index: usize,
    ) void {
        for (original_values, selected_values, 0..) |original, *selected, index| {
            if (index == selected_index) continue;
            const other = switch (original) {
                .match_ => |match_value| match_value,
                else => continue,
            };
            if (!matchValueControlEql(control, other)) continue;
            selected.* = other.branches[branch_index].body;
        }
    }

    fn selectCorrelatedStateMatchBranch(
        self: *Cloner,
        original_values: []const Value,
        selected_values: []Value,
        demands: []const ValueDemand,
        selected_index: usize,
        control: MatchValue,
        branch_index: usize,
    ) Common.LowerError!void {
        for (original_values, selected_values, 0..) |original, *selected, index| {
            if (index == selected_index) continue;
            const other = switch (original) {
                .match_ => |match_value| match_value,
                else => continue,
            };
            if (!matchValueControlEql(control, other)) continue;
            selected.* = try self.cloneMatchValueBranchBodyWithDemand(other.branches[branch_index], demands[index]);
        }
    }

    fn cloneStateContinueDataFromValues(
        self: *Cloner,
        ty: Type.TypeId,
        state_loop: SparseStateLoopPattern,
        values: []const Value,
    ) Common.LowerError!Ast.ExprData {
        const demands = try self.stateLoopValueDemands(state_loop, values.len);
        defer self.pass.allocator.free(demands);

        for (values, 0..) |value, value_index| {
            const let_value = switch (value) {
                .let_ => |let_value| let_value,
                else => continue,
            };

            var unwrapped_values = try self.pass.allocator.dupe(Value, values);
            defer self.pass.allocator.free(unwrapped_values);
            unwrapped_values[value_index] = let_value.body.*;

            const change_start = self.changes.items.len;
            defer self.restore(change_start);
            try self.bindPendingLetKnownValues(let_value.lets);

            const continue_expr = try self.addExpr(.{
                .ty = ty,
                .data = try self.cloneStateContinueDataFromValues(ty, state_loop, unwrapped_values),
            });
            const wrapped = try self.wrapPendingLetsAroundExpr(ty, continue_expr, let_value.lets);
            return .{ .block = .{
                .statements = try self.pass.program.addStmtSpan(&.{}),
                .final_expr = wrapped,
            } };
        }

        for (values, 0..) |value, value_index| {
            const if_value = switch (value) {
                .if_ => |if_value| if_value,
                else => continue,
            };

            const branches = try self.pass.allocator.alloc(Ast.IfBranch, if_value.branches.len);
            defer self.pass.allocator.free(branches);
            var branch_values = try self.pass.allocator.dupe(Value, values);
            defer self.pass.allocator.free(branch_values);

            for (if_value.branches, 0..) |branch, branch_index| {
                branch_values[value_index] = try self.applyValueDemand(branch.body, demands[value_index]);
                try self.selectCorrelatedStateIfBranch(values, branch_values, demands, value_index, if_value, branch_index, false);
                branches[branch_index] = .{
                    .cond = branch.cond,
                    .body = try self.addExpr(.{
                        .ty = ty,
                        .data = try self.cloneStateContinueDataFromValues(ty, state_loop, branch_values),
                    }),
                };
            }

            branch_values[value_index] = try self.applyValueDemand(if_value.final_else.*, demands[value_index]);
            try self.selectCorrelatedStateIfBranch(values, branch_values, demands, value_index, if_value, 0, true);
            const final_else = try self.addExpr(.{
                .ty = ty,
                .data = try self.cloneStateContinueDataFromValues(ty, state_loop, branch_values),
            });

            return .{ .if_ = .{
                .branches = try self.pass.program.addIfBranchSpan(branches),
                .final_else = final_else,
            } };
        }

        for (values, 0..) |value, value_index| {
            const match_value = switch (value) {
                .match_ => |match_value| match_value,
                else => continue,
            };

            const branches = try self.pass.allocator.alloc(Ast.Branch, match_value.branches.len);
            defer self.pass.allocator.free(branches);
            var branch_values = try self.pass.allocator.dupe(Value, values);
            defer self.pass.allocator.free(branch_values);

            for (match_value.branches, 0..) |branch, branch_index| {
                branch_values[value_index] = try self.cloneMatchValueBranchBodyWithDemand(branch, demands[value_index]);
                try self.selectCorrelatedStateMatchBranch(values, branch_values, demands, value_index, match_value, branch_index);
                branches[branch_index] = .{
                    .pat = branch.pat,
                    .guard = branch.guard,
                    .body = try self.addExpr(.{
                        .ty = ty,
                        .data = try self.cloneStateContinueDataFromValues(ty, state_loop, branch_values),
                    }),
                };
            }

            return .{ .match_ = .{
                .scrutinee = match_value.scrutinee,
                .branches = try self.pass.program.addBranchSpan(branches),
                .comptime_site = match_value.comptime_site,
            } };
        }

        const state_values = try self.demandedStateValuesFromValues(demands, values);
        const target_state = self.stateForDemandedKnownValues(state_loop.states.items, state_values) orelse
            try self.appendSparseState(state_loop.states, state_values);

        var new_values = std.ArrayList(Ast.ExprId).empty;
        defer new_values.deinit(self.pass.allocator);

        for (target_state.values, values) |known_value, value| {
            if (!try self.appendExprsFromDemandedKnownValue(known_value, value, &new_values)) {
                Common.invariant("state_continue value could not be split into target state params");
            }
        }

        return .{ .state_continue = .{
            .target_state = target_state.id,
            .values = try self.pass.program.addExprSpan(new_values.items),
        } };
    }

    fn hoistNestedLetsFromValue(
        self: *Cloner,
        value: Value,
        pending_statements: *std.ArrayList(Ast.StmtId),
    ) Common.LowerError!Value {
        return switch (value) {
            .let_ => |let_value| blk: {
                try self.appendPendingLetStmts(let_value.lets, pending_statements);
                try self.bindPendingLetKnownValues(let_value.lets);
                break :blk try self.hoistNestedLetsFromValue(let_value.body.*, pending_statements);
            },
            .tag => |tag| blk: {
                const payloads = try self.pass.arena.allocator().alloc(Value, tag.payloads.len);
                for (tag.payloads, payloads) |payload, *out| {
                    out.* = try self.hoistNestedLetsFromValue(payload, pending_statements);
                }
                break :blk Value{ .tag = .{
                    .ty = tag.ty,
                    .name = tag.name,
                    .payloads = payloads,
                } };
            },
            .record => |record| blk: {
                const fields = try self.pass.arena.allocator().alloc(FieldValue, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    out.* = .{
                        .name = field.name,
                        .value = try self.hoistNestedLetsFromValue(field.value, pending_statements),
                    };
                }
                break :blk Value{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| blk: {
                const items = try self.pass.arena.allocator().alloc(Value, tuple.items.len);
                for (tuple.items, items) |item, *out| {
                    out.* = try self.hoistNestedLetsFromValue(item, pending_statements);
                }
                break :blk Value{ .tuple = .{
                    .ty = tuple.ty,
                    .items = items,
                } };
            },
            .nominal => |nominal| blk: {
                const backing = try self.pass.arena.allocator().create(Value);
                backing.* = try self.hoistNestedLetsFromValue(nominal.backing.*, pending_statements);
                break :blk Value{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = backing,
                } };
            },
            .callable => |callable| blk: {
                const captures = try self.pass.arena.allocator().alloc(Value, callable.captures.len);
                for (callable.captures, captures) |capture, *out| {
                    out.* = try self.hoistNestedLetsFromValue(capture, pending_statements);
                }
                break :blk Value{ .callable = .{
                    .ty = callable.ty,
                    .fn_id = callable.fn_id,
                    .captures = captures,
                } };
            },
            .finite_tags => |finite_tags| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(TagValue, finite_tags.alternatives.len);
                for (finite_tags.alternatives, alternatives) |alternative, *out| {
                    const payloads = try self.pass.arena.allocator().alloc(Value, alternative.payloads.len);
                    for (alternative.payloads, payloads) |payload, *payload_out| {
                        payload_out.* = try self.hoistNestedLetsFromValue(payload, pending_statements);
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .name = alternative.name,
                        .payloads = payloads,
                    };
                }
                break :blk Value{ .finite_tags = .{
                    .ty = finite_tags.ty,
                    .selector = finite_tags.selector,
                    .alternatives = alternatives,
                } };
            },
            .finite_callables => |finite_callables| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(CallableValue, finite_callables.alternatives.len);
                for (finite_callables.alternatives, alternatives) |alternative, *out| {
                    const captures = try self.pass.arena.allocator().alloc(Value, alternative.captures.len);
                    for (alternative.captures, captures) |capture, *capture_out| {
                        capture_out.* = try self.hoistNestedLetsFromValue(capture, pending_statements);
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .fn_id = alternative.fn_id,
                        .captures = captures,
                    };
                }
                break :blk Value{ .finite_callables = .{
                    .ty = finite_callables.ty,
                    .selector = finite_callables.selector,
                    .alternatives = alternatives,
                } };
            },
            .if_,
            .match_,
            .expr,
            .expr_with_known_value,
            .private_state,
            => value,
        };
    }

    fn cloneContinueDataFromValues(
        self: *Cloner,
        ty: Type.TypeId,
        loop: LoopPattern,
        values: []const Value,
    ) Common.LowerError!Ast.ExprData {
        for (values, 0..) |value, value_index| {
            const let_value = switch (value) {
                .let_ => |let_value| let_value,
                else => continue,
            };

            var unwrapped_values = try self.pass.allocator.dupe(Value, values);
            defer self.pass.allocator.free(unwrapped_values);
            unwrapped_values[value_index] = let_value.body.*;

            const change_start = self.changes.items.len;
            defer self.restore(change_start);
            try self.bindPendingLetKnownValues(let_value.lets);

            const continue_expr = try self.addExpr(.{
                .ty = ty,
                .data = try self.cloneContinueDataFromValues(ty, loop, unwrapped_values),
            });
            const wrapped = try self.wrapPendingLetsAroundExpr(ty, continue_expr, let_value.lets);
            return .{ .block = .{
                .statements = try self.pass.program.addStmtSpan(&.{}),
                .final_expr = wrapped,
            } };
        }

        for (values, 0..) |value, value_index| {
            const if_value = switch (value) {
                .if_ => |if_value| if_value,
                else => continue,
            };

            const branches = try self.pass.allocator.alloc(Ast.IfBranch, if_value.branches.len);
            defer self.pass.allocator.free(branches);
            var branch_values = try self.pass.allocator.dupe(Value, values);
            defer self.pass.allocator.free(branch_values);

            for (if_value.branches, 0..) |branch, branch_index| {
                branch_values[value_index] = branch.body;
                selectCorrelatedIfBranch(values, branch_values, value_index, if_value, branch_index, false);
                branches[branch_index] = .{
                    .cond = branch.cond,
                    .body = try self.addExpr(.{
                        .ty = ty,
                        .data = try self.cloneContinueDataFromValues(ty, loop, branch_values),
                    }),
                };
            }

            branch_values[value_index] = if_value.final_else.*;
            selectCorrelatedIfBranch(values, branch_values, value_index, if_value, 0, true);
            const final_else = try self.addExpr(.{
                .ty = ty,
                .data = try self.cloneContinueDataFromValues(ty, loop, branch_values),
            });

            return .{ .if_ = .{
                .branches = try self.pass.program.addIfBranchSpan(branches),
                .final_else = final_else,
            } };
        }

        for (values, 0..) |value, value_index| {
            const match_value = switch (value) {
                .match_ => |match_value| match_value,
                else => continue,
            };

            const branches = try self.pass.allocator.alloc(Ast.Branch, match_value.branches.len);
            defer self.pass.allocator.free(branches);
            var branch_values = try self.pass.allocator.dupe(Value, values);
            defer self.pass.allocator.free(branch_values);

            for (match_value.branches, 0..) |branch, branch_index| {
                branch_values[value_index] = branch.body;
                selectCorrelatedMatchBranch(values, branch_values, value_index, match_value, branch_index);
                branches[branch_index] = .{
                    .pat = branch.pat,
                    .guard = branch.guard,
                    .body = try self.addExpr(.{
                        .ty = ty,
                        .data = try self.cloneContinueDataFromValues(ty, loop, branch_values),
                    }),
                };
            }

            return .{ .match_ = .{
                .scrutinee = match_value.scrutinee,
                .branches = try self.pass.program.addBranchSpan(branches),
                .comptime_site = match_value.comptime_site,
            } };
        }

        var new_values = std.ArrayList(Ast.ExprId).empty;
        defer new_values.deinit(self.pass.allocator);

        for (loop.values, values, 0..) |known_value, value, index| {
            if (!knownValueMatchesValue(self.pass.program, known_value, value)) {
                if (!try self.appendFieldReadExprsFromValue(known_value, value, &new_values)) {
                    const refined = try self.refineLoopKnownValueForValue(known_value, value);
                    if (try self.noteLoopRefinement(loop, index, refined)) {
                        try self.appendUninitializedExprsForKnownValue(known_value, &new_values);
                    } else if (!try self.appendFieldReadExprsFromValue(known_value, value, &new_values)) {
                        Common.invariant("loop continue value could not be split after stable refinement");
                    }
                }
                continue;
            }
            try self.appendExprsFromValue(known_value, value, &new_values);
        }

        return .{ .continue_ = .{
            .values = try self.pass.program.addExprSpan(new_values.items),
        } };
    }

    fn noteLoopRefinement(self: *Cloner, loop: LoopPattern, index: usize, refinement: KnownValue) Allocator.Error!bool {
        if (index >= loop.refinements.len) Common.invariant("loop refinement index exceeded active loop state");
        const merged = if (loop.refinements[index]) |existing|
            try self.commonLoopKnownValue(existing, refinement)
        else
            refinement;
        if (known_valueEql(self.pass.program, loop.values[index], merged)) return false;
        loop.refinements[index] = merged;
        return true;
    }

    fn noteLoopDemandIfLocalExpr(
        self: *Cloner,
        expr_id: Ast.ExprId,
        demand: ValueDemand,
    ) Allocator.Error!void {
        const loop = self.loop_stack.getLastOrNull() orelse return;
        for (loop.params, 0..) |param, index| {
            if (index >= loop.demands.len) Common.invariant("loop demand index exceeded active loop state");
            const local_demand = try self.localDemandInExpr(param.local, expr_id, demand);
            if (local_demand == .none) continue;
            loop.demands[index] = try self.mergeActiveLoopParamDemand(loop, index, loop.demands[index], local_demand);
        }
    }

    fn mergeActiveLoopParamDemand(
        self: *Cloner,
        loop: LoopPattern,
        index: usize,
        existing: ValueDemand,
        incoming: ValueDemand,
    ) Allocator.Error!ValueDemand {
        if (loop.source_values) |source_values| {
            if (index >= source_values.len) Common.invariant("loop source-value demand index exceeded active loop arity");
            return try self.mergeLoopValueParamDemand(source_values[index], existing, incoming);
        }
        if (index >= loop.values.len) Common.invariant("loop known-value demand index exceeded active loop arity");
        return try self.mergeLoopParamDemand(loop.values[index], existing, incoming);
    }

    fn mergeLoopParamDemand(
        self: *Cloner,
        known_value: KnownValue,
        existing: ValueDemand,
        incoming: ValueDemand,
    ) Allocator.Error!ValueDemand {
        if (incoming == .loop_param) return existing;
        const merged = try self.pass.mergeValueDemand(existing, incoming);
        return try self.normalizeLoopParamDemand(known_value, merged);
    }

    fn mergeLoopValueParamDemand(
        self: *Cloner,
        value: Value,
        existing: ValueDemand,
        incoming: ValueDemand,
    ) Allocator.Error!ValueDemand {
        if (incoming == .loop_param) return existing;
        const merged = try self.pass.mergeValueDemand(existing, incoming);
        return try self.normalizeLoopValueParamDemand(value, merged);
    }

    fn normalizeLoopParamDemand(
        self: *Cloner,
        known_value: KnownValue,
        demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        switch (demand) {
            .none, .materialize => return demand,
            else => {},
        }

        const demanded = (try demandedKnownValueFromDemand(
            self,
            self.pass.program,
            self.pass.arena.allocator(),
            known_value,
            demand,
        )) orelse return demand;

        const state_shape = try self.pass.valueDemandFromDemandedKnownValue(demanded);
        return try self.pass.mergeValueDemand(demand, state_shape);
    }

    fn normalizeLoopValueParamDemand(
        self: *Cloner,
        value: Value,
        demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        switch (demand) {
            .none, .materialize => return demand,
            else => {},
        }

        const demanded = (try self.demandedKnownValueFromValueDemand(value, demand)) orelse return demand;
        const state_shape = try self.pass.valueDemandFromDemandedKnownValue(demanded);
        return try self.pass.mergeValueDemand(demand, state_shape);
    }

    fn refineLoopKnownValueForValue(self: *Cloner, known_value: KnownValue, value: Value) Common.LowerError!KnownValue {
        if (knownValueMatchesValue(self.pass.program, known_value, value)) return known_value;

        return switch (known_value) {
            .any => known_value,
            .leaf => known_value,
            .record => |record| blk: {
                if (recordFromValue(value)) |record_value| {
                    var fields = std.ArrayList(KnownField).empty;
                    defer fields.deinit(self.pass.allocator);
                    for (record_value.fields) |field_value| {
                        const field_known_value = fieldKnownValueFromKnownValue(.{ .record = record }, field_value.name) orelse
                            KnownValue{ .any = valueType(self.pass.program, field_value.value) };
                        try fields.append(self.pass.allocator, .{
                            .name = field_value.name,
                            .known_value = try self.refineLoopKnownValueForValue(field_known_value, field_value.value),
                        });
                    }
                    break :blk KnownValue{ .record = .{
                        .ty = record.ty,
                        .fields = try self.pass.arena.allocator().dupe(KnownField, fields.items),
                    } };
                }

                const receiver = projectableExprFromValue(value) orelse break :blk KnownValue{ .any = record.ty };
                if (!canReadFieldsFromExpr(self.pass.program, receiver)) break :blk KnownValue{ .any = record.ty };
                const actual_known_value = switch (value) {
                    .expr_with_known_value => |known_value_expr| known_value_expr.known_value,
                    else => null,
                };
                const fields = try self.pass.arena.allocator().alloc(KnownField, record.fields.len);
                for (record.fields, 0..) |field, index| {
                    const actual_field = if (actual_known_value) |actual|
                        fieldKnownValueFromKnownValue(actual, field.name)
                    else
                        null;
                    const field_expr = try self.addExpr(.{ .ty = known_valueType(field.known_value), .data = .{ .field_access = .{
                        .receiver = receiver,
                        .field = field.name,
                    } } });
                    const field_value = if (actual_field) |actual|
                        valueFromProjectedExpr(field_expr, actual)
                    else
                        Value{ .expr = field_expr };
                    fields[index] = .{
                        .name = field.name,
                        .known_value = try self.refineLoopKnownValueForValue(field.known_value, field_value),
                    };
                }
                break :blk KnownValue{ .record = .{ .ty = record.ty, .fields = fields } };
            },
            .tuple => |tuple| blk: {
                const items = try self.pass.arena.allocator().alloc(KnownValue, tuple.items.len);
                if (tupleFromValue(value)) |tuple_value| {
                    if (tuple.items.len != tuple_value.items.len) Common.invariant("tuple loop state changed item count");
                    for (tuple.items, tuple_value.items, 0..) |item, item_value, index| {
                        items[index] = try self.refineLoopKnownValueForValue(item, item_value);
                    }
                    break :blk KnownValue{ .tuple = .{ .ty = tuple.ty, .items = items } };
                }

                const receiver = projectableExprFromValue(value) orelse break :blk KnownValue{ .any = tuple.ty };
                if (!canReadFieldsFromExpr(self.pass.program, receiver)) break :blk KnownValue{ .any = tuple.ty };
                const actual_known_value = switch (value) {
                    .expr_with_known_value => |known_value_expr| known_value_expr.known_value,
                    else => null,
                };
                for (tuple.items, 0..) |item, index| {
                    const actual_item = if (actual_known_value) |actual|
                        itemKnownValueFromKnownValue(actual, @as(u32, @intCast(index)))
                    else
                        null;
                    const item_expr = try self.addExpr(.{ .ty = known_valueType(item), .data = .{ .tuple_access = .{
                        .tuple = receiver,
                        .elem_index = @as(u32, @intCast(index)),
                    } } });
                    const item_value = if (actual_item) |actual|
                        valueFromProjectedExpr(item_expr, actual)
                    else
                        Value{ .expr = item_expr };
                    items[index] = try self.refineLoopKnownValueForValue(item, item_value);
                }
                break :blk KnownValue{ .tuple = .{ .ty = tuple.ty, .items = items } };
            },
            .nominal => |nominal| blk: {
                const value_nominal = switch (value) {
                    .nominal => |nominal_value| nominal_value,
                    else => break :blk KnownValue{ .any = nominal.ty },
                };
                const backing = try self.pass.arena.allocator().create(KnownValue);
                backing.* = try self.refineLoopKnownValueForValue(nominal.backing.*, value_nominal.backing.*);
                break :blk KnownValue{ .nominal = .{ .ty = nominal.ty, .backing = backing } };
            },
            .tag => |tag| blk: {
                if (value == .expr_with_known_value) {
                    if (value.expr_with_known_value.value == null) break :blk KnownValue{ .any = tag.ty };
                    break :blk try self.commonLoopKnownValue(known_value, value.expr_with_known_value.known_value);
                }
                const value_tag = switch (value) {
                    .tag => |tag_value| tag_value,
                    else => break :blk KnownValue{ .any = tag.ty },
                };
                const value_known_value = (try self.pass.knownValueFromValue(.{ .tag = value_tag })) orelse break :blk KnownValue{ .any = tag.ty };
                break :blk try self.commonLoopKnownValue(known_value, value_known_value);
            },
            .callable => |callable| blk: {
                if (value == .expr_with_known_value) {
                    if (value.expr_with_known_value.value == null) break :blk KnownValue{ .any = callable.ty };
                    break :blk try self.commonLoopKnownValue(known_value, value.expr_with_known_value.known_value);
                }
                const callable_value = switch (value) {
                    .callable => |callable_value| callable_value,
                    else => break :blk KnownValue{ .any = callable.ty },
                };
                const value_known_value = (try self.pass.knownValueFromValue(.{ .callable = callable_value })) orelse break :blk KnownValue{ .any = callable.ty };
                break :blk try self.commonLoopKnownValue(known_value, value_known_value);
            },
            .finite_tags => |finite_tags| blk: {
                switch (value) {
                    .expr_with_known_value => |known_value_expr| {
                        if (known_value_expr.value == null) break :blk KnownValue{ .any = finite_tags.ty };
                        break :blk try self.commonLoopKnownValue(known_value, known_value_expr.known_value);
                    },
                    .tag => |tag_value| {
                        const value_known_value = (try self.pass.knownValueFromValue(.{ .tag = tag_value })) orelse break :blk KnownValue{ .any = finite_tags.ty };
                        break :blk try self.commonLoopKnownValue(known_value, value_known_value);
                    },
                    .finite_tags => |finite_value| {
                        const value_known_value = (try self.pass.knownValueFromValue(.{ .finite_tags = finite_value })) orelse break :blk KnownValue{ .any = finite_tags.ty };
                        break :blk try self.commonLoopKnownValue(known_value, value_known_value);
                    },
                    else => break :blk KnownValue{ .any = finite_tags.ty },
                }
            },
            .finite_callables => |finite_callables| blk: {
                switch (value) {
                    .expr_with_known_value => |known_value_expr| {
                        if (known_value_expr.value == null) break :blk KnownValue{ .any = finite_callables.ty };
                        break :blk try self.commonLoopKnownValue(known_value, known_value_expr.known_value);
                    },
                    .callable => |callable_value| {
                        const value_known_value = (try self.pass.knownValueFromValue(.{ .callable = callable_value })) orelse break :blk KnownValue{ .any = finite_callables.ty };
                        break :blk try self.commonLoopKnownValue(known_value, value_known_value);
                    },
                    .finite_callables => |finite_value| {
                        const value_known_value = (try self.pass.knownValueFromValue(.{ .finite_callables = finite_value })) orelse break :blk KnownValue{ .any = finite_callables.ty };
                        break :blk try self.commonLoopKnownValue(known_value, value_known_value);
                    },
                    else => break :blk KnownValue{ .any = finite_callables.ty },
                }
            },
        };
    }

    fn commonLoopKnownValue(self: *Cloner, lhs: KnownValue, rhs: KnownValue) Allocator.Error!KnownValue {
        if (known_valueEql(self.pass.program, lhs, rhs)) return lhs;
        const ty = known_valueType(lhs);
        if (!sameType(self.pass.program, ty, known_valueType(rhs))) Common.invariant("loop state refinement changed type");
        if (try commonKnownTags(self.pass.program, self.pass.arena.allocator(), lhs, rhs)) |finite_tags| {
            return finite_tags;
        }
        if (try commonKnownCallables(self.pass.program, self.pass.arena.allocator(), lhs, rhs)) |finite_callables| {
            return finite_callables;
        }
        if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return .{ .any = ty };

        return switch (lhs) {
            .any => .{ .any = ty },
            .leaf => .{ .leaf = ty },
            .record => |lhs_record| blk: {
                const rhs_record = rhs.record;
                if (lhs_record.fields.len != rhs_record.fields.len) break :blk KnownValue{ .any = ty };
                const fields = try self.pass.arena.allocator().alloc(KnownField, lhs_record.fields.len);
                for (lhs_record.fields, rhs_record.fields, 0..) |lhs_field, rhs_field, index| {
                    if (lhs_field.name != rhs_field.name) break :blk KnownValue{ .any = ty };
                    fields[index] = .{
                        .name = lhs_field.name,
                        .known_value = try self.commonLoopKnownValue(lhs_field.known_value, rhs_field.known_value),
                    };
                }
                break :blk KnownValue{ .record = .{ .ty = lhs_record.ty, .fields = fields } };
            },
            .tuple => |lhs_tuple| blk: {
                const rhs_tuple = rhs.tuple;
                if (lhs_tuple.items.len != rhs_tuple.items.len) break :blk KnownValue{ .any = ty };
                const items = try self.pass.arena.allocator().alloc(KnownValue, lhs_tuple.items.len);
                for (lhs_tuple.items, rhs_tuple.items, 0..) |lhs_item, rhs_item, index| {
                    items[index] = try self.commonLoopKnownValue(lhs_item, rhs_item);
                }
                break :blk KnownValue{ .tuple = .{ .ty = lhs_tuple.ty, .items = items } };
            },
            .nominal => |lhs_nominal| blk: {
                const rhs_nominal = rhs.nominal;
                const backing = try self.pass.arena.allocator().create(KnownValue);
                backing.* = try self.commonLoopKnownValue(lhs_nominal.backing.*, rhs_nominal.backing.*);
                break :blk KnownValue{ .nominal = .{ .ty = lhs_nominal.ty, .backing = backing } };
            },
            .callable => |lhs_callable| blk: {
                const rhs_callable = rhs.callable;
                if (!callableTargetMatches(self.pass.program, lhs_callable.fn_id, rhs_callable.fn_id) or
                    lhs_callable.captures.len != rhs_callable.captures.len)
                {
                    break :blk KnownValue{ .any = ty };
                }
                const captures = try self.pass.arena.allocator().alloc(KnownValue, lhs_callable.captures.len);
                for (lhs_callable.captures, rhs_callable.captures, 0..) |lhs_capture, rhs_capture, index| {
                    captures[index] = try self.commonLoopKnownValue(lhs_capture, rhs_capture);
                }
                break :blk KnownValue{ .callable = .{
                    .ty = lhs_callable.ty,
                    .fn_id = lhs_callable.fn_id,
                    .captures = captures,
                } };
            },
            .tag => .{ .any = ty },
            .finite_tags => .{ .any = ty },
            .finite_callables => .{ .any = ty },
        };
    }

    fn valuesToExprSpan(self: *Cloner, values: []const Value) Common.LowerError!Ast.Span(Ast.ExprId) {
        const exprs = try self.pass.allocator.alloc(Ast.ExprId, values.len);
        defer self.pass.allocator.free(exprs);
        for (values, 0..) |value, index| {
            exprs[index] = try self.materialize(value);
        }
        return try self.pass.program.addExprSpan(exprs);
    }

    fn cloneCallProcExpr(self: *Cloner, ty: Type.TypeId, call: @import("../monotype/ast.zig").CallProc) Common.LowerError!Ast.ExprId {
        const data = try self.cloneCallProcData(call);
        const cloned_call = switch (data) {
            .call_proc => |cloned| cloned,
            else => Common.invariant("direct call cloning produced a non-call expression"),
        };
        const call_expr = try self.addExpr(.{ .ty = ty, .data = data });
        return try self.wrapDirectCallCaptureLets(ty, Ast.callProcCallee(cloned_call), call_expr);
    }

    fn cloneCallProcData(self: *Cloner, call: @import("../monotype/ast.zig").CallProc) Common.LowerError!Ast.ExprData {
        if (call.is_cold) {
            return .{ .call_proc = .{
                .callee = call.callee,
                .args = try self.cloneExprSpan(call.args),
                .is_cold = true,
            } };
        }

        const callee = Ast.callProcCallee(call);
        const raw = @intFromEnum(callee);
        if (raw < self.pass.plans.len) {
            const source_args = self.pass.program.exprSpan(call.args);
            const args = try self.pass.allocator.dupe(Ast.ExprId, source_args);
            defer self.pass.allocator.free(args);

            const values = try self.pass.allocator.alloc(Value, args.len);
            defer self.pass.allocator.free(values);
            for (args, 0..) |arg, index| {
                values[index] = try self.cloneExprValue(arg);
            }
            if (self.record_call_patterns) {
                try self.pass.ensureCallPatternForValues(callee, values);
            }

            for (self.pass.plans[raw].specs.items) |spec| {
                const spec_fn_id = spec.fn_id orelse
                    Common.invariant("call-pattern specialization id was not assigned before cloning calls");
                var rewritten_args = std.ArrayList(Ast.ExprId).empty;
                defer rewritten_args.deinit(self.pass.allocator);

                if (try self.appendClonedCallArgs(spec.pattern, args, &rewritten_args)) {
                    return .{ .call_proc = .{
                        .callee = .{ .lifted = spec_fn_id },
                        .args = try self.pass.program.addExprSpan(rewritten_args.items),
                        .is_cold = call.is_cold,
                    } };
                }
            }
        }
        return .{ .call_proc = .{
            .callee = call.callee,
            .args = try self.cloneExprSpan(call.args),
            .is_cold = call.is_cold,
        } };
    }

    fn wrapDirectCallCaptureLets(self: *Cloner, ty: Type.TypeId, callee: Ast.FnId, call_expr: Ast.ExprId) Common.LowerError!Ast.ExprId {
        const callee_fn = self.pass.program.fns.items[@intFromEnum(callee)];
        const captures = self.pass.program.typedLocalSpan(callee_fn.captures);
        if (captures.len == 0) return call_expr;

        const values = try self.pass.allocator.alloc(?Ast.ExprId, captures.len);
        defer self.pass.allocator.free(values);
        for (captures, 0..) |capture, index| {
            const value = self.subst.get(capture.local) orelse {
                values[index] = null;
                continue;
            };
            const value_expr = try self.materialize(value);
            const value_local = localExpr(self.pass.program, value_expr);
            values[index] = if (value_local != null and value_local.? == capture.local) null else value_expr;
        }

        var result = call_expr;
        var index = values.len;
        while (index > 0) {
            index -= 1;
            const value_expr = values[index] orelse continue;
            const pat = try self.pass.program.addPat(.{
                .ty = captures[index].ty,
                .data = .{ .bind = captures[index].local },
            });
            result = try self.addExpr(.{ .ty = ty, .data = .{ .let_ = .{
                .bind = pat,
                .value = value_expr,
                .rest = result,
            } } });
        }
        return result;
    }

    fn appendClonedCallArgs(
        self: *Cloner,
        pattern: CallPattern,
        args: []const Ast.ExprId,
        out: *std.ArrayList(Ast.ExprId),
    ) Common.LowerError!bool {
        if (pattern.args.len != args.len) Common.invariant("call-pattern arity differed from direct call arity");
        for (pattern.args, args) |known_value, arg| {
            if (!try self.appendClonedExprsForKnownValue(known_value, arg, out)) return false;
        }
        return true;
    }

    fn appendClonedExprsForKnownValue(
        self: *Cloner,
        known_value: KnownValue,
        expr_id: Ast.ExprId,
        out: *std.ArrayList(Ast.ExprId),
    ) Common.LowerError!bool {
        switch (known_value) {
            .any => {
                try out.append(self.pass.allocator, try self.cloneExpr(expr_id));
                return true;
            },
            else => {
                const value = try self.valueForCallArg(expr_id);
                if (!knownValueMatchesValue(self.pass.program, known_value, value)) return false;
                try self.appendExprsFromValue(known_value, value, out);
                return true;
            },
        }
    }

    fn valueForCallArg(self: *Cloner, expr_id: Ast.ExprId) Common.LowerError!Value {
        return try self.cloneExprValueDemandingKnownValue(expr_id);
    }

    fn appendExprsFromValue(
        self: *Cloner,
        known_value: KnownValue,
        value: Value,
        out: *std.ArrayList(Ast.ExprId),
    ) Common.LowerError!void {
        if (value == .private_state) {
            try self.appendExprsFromPrivateStateKnownValue(known_value, value.private_state, out);
            return;
        }

        if (value == .expr_with_known_value) switch (known_value) {
            .any => {},
            else => {
                if (!try self.appendFieldReadExprsFromValue(known_value, value, out)) {
                    Common.invariant("known-value expression could not be split into requested known_value");
                }
                return;
            },
        };

        switch (known_value) {
            .any,
            .leaf,
            => try out.append(self.pass.allocator, try self.materializePublic(value)),
            .tag => |tag| {
                const tag_value = switch (value) {
                    .tag => |tag_value| tag_value,
                    else => Common.invariant("tag call pattern matched a non-tag value"),
                };
                for (tag.payloads, tag_value.payloads) |payload_known_value, payload| {
                    try self.appendExprsFromValue(payload_known_value, payload, out);
                }
            },
            .record => |record| {
                const record_value = switch (value) {
                    .record => |record_value| record_value,
                    else => Common.invariant("record call pattern matched a non-record value"),
                };
                for (record.fields) |field_known_value| {
                    const field_value = fieldFromRecord(record_value, field_known_value.name) orelse
                        Common.invariant("record call-pattern field was not present after matching");
                    try self.appendExprsFromValue(field_known_value.known_value, field_value, out);
                }
            },
            .tuple => |tuple| {
                const tuple_value = switch (value) {
                    .tuple => |tuple_value| tuple_value,
                    else => Common.invariant("tuple call pattern matched a non-tuple value"),
                };
                for (tuple.items, tuple_value.items) |item_known_value, item| {
                    try self.appendExprsFromValue(item_known_value, item, out);
                }
            },
            .nominal => |nominal| {
                const nominal_value = switch (value) {
                    .nominal => |nominal_value| nominal_value,
                    else => Common.invariant("nominal call pattern matched a non-nominal value"),
                };
                try self.appendExprsFromValue(nominal.backing.*, nominal_value.backing.*, out);
            },
            .callable => |callable| {
                const callable_value = switch (value) {
                    .callable => |callable_value| callable_value,
                    else => Common.invariant("callable call pattern matched a non-callable value"),
                };
                for (callable.captures, callable_value.captures) |capture_known_value, capture_value| {
                    try self.appendExprsFromValue(capture_known_value, capture_value, out);
                }
            },
            .finite_callables => |finite_callables| {
                if (value == .finite_callables) {
                    const finite_value = value.finite_callables;
                    if (!knownCallablesMatchesValue(self.pass.program, finite_callables, finite_value)) {
                        Common.invariant("finite callable known_value matched a different finite callable value");
                    }
                    try out.append(self.pass.allocator, finite_value.selector);
                    for (finite_callables.alternatives, finite_value.alternatives) |alternative_known_value, alternative_value| {
                        if (!callableTargetMatches(self.pass.program, alternative_known_value.fn_id, alternative_value.fn_id) or
                            alternative_known_value.captures.len != alternative_value.captures.len)
                        {
                            Common.invariant("finite callable value alternatives changed after matching");
                        }
                        for (alternative_known_value.captures, alternative_value.captures) |capture_known_value, capture_value| {
                            try self.appendExprsFromValue(capture_known_value, capture_value, out);
                        }
                    }
                    return;
                }

                const callable_value = switch (value) {
                    .callable => |callable_value| callable_value,
                    else => Common.invariant("finite callable call pattern matched a non-callable value"),
                };
                const active_index = finiteCallableAlternativeIndex(self.pass.program, finite_callables.alternatives, callable_value) orelse
                    Common.invariant("finite callable known_value did not contain the continued callable value");
                try out.append(self.pass.allocator, try self.selectorLiteral(@intCast(active_index)));
                for (finite_callables.alternatives, 0..) |alternative_known_value, alternative_index| {
                    if (alternative_index == active_index) {
                        for (alternative_known_value.captures, callable_value.captures) |capture_known_value, capture_value| {
                            try self.appendExprsFromValue(capture_known_value, capture_value, out);
                        }
                    } else {
                        for (alternative_known_value.captures) |capture_known_value| {
                            try self.appendUninitializedExprsForKnownValue(capture_known_value, out);
                        }
                    }
                }
            },
            .finite_tags => |finite_tags| {
                if (value == .finite_tags) {
                    const finite_value = value.finite_tags;
                    if (!knownTagsMatchesValue(self.pass.program, finite_tags, finite_value)) {
                        Common.invariant("finite tag known_value matched a different finite tag value");
                    }
                    try out.append(self.pass.allocator, finite_value.selector);
                    for (finite_tags.alternatives, finite_value.alternatives) |alternative_known_value, alternative_value| {
                        if (alternative_known_value.name != alternative_value.name or alternative_known_value.payloads.len != alternative_value.payloads.len) {
                            Common.invariant("finite tag value alternatives changed after matching");
                        }
                        for (alternative_known_value.payloads, alternative_value.payloads) |payload_known_value, payload_value| {
                            try self.appendExprsFromValue(payload_known_value, payload_value, out);
                        }
                    }
                    return;
                }

                const tag_value = switch (value) {
                    .tag => |tag_value| tag_value,
                    else => Common.invariant("finite tag call pattern matched a non-tag value"),
                };
                const active_index = finiteTagAlternativeIndex(self.pass.program, finite_tags.alternatives, tag_value) orelse
                    Common.invariant("finite tag known_value did not contain the continued tag value");
                try out.append(self.pass.allocator, try self.selectorLiteral(@intCast(active_index)));
                for (finite_tags.alternatives, 0..) |alternative_known_value, alternative_index| {
                    if (alternative_index == active_index) {
                        for (alternative_known_value.payloads, tag_value.payloads) |payload_known_value, payload_value| {
                            try self.appendExprsFromValue(payload_known_value, payload_value, out);
                        }
                    } else {
                        for (alternative_known_value.payloads) |payload_known_value| {
                            try self.appendUninitializedExprsForKnownValue(payload_known_value, out);
                        }
                    }
                }
            },
        }
    }

    fn appendExprsFromPrivateStateKnownValue(
        self: *Cloner,
        known_value: KnownValue,
        value: PrivateStateValue,
        out: *std.ArrayList(Ast.ExprId),
    ) Common.LowerError!void {
        switch (known_value) {
            .any,
            .leaf,
            => {
                if (privateStateLeafExpr(value)) |leaf_expr| {
                    try out.append(self.pass.allocator, leaf_expr);
                    return;
                }
                if (!privateStateCanMaterializePublic(self.pass.program, value)) {
                    Common.invariant("sparse private state matched a leaf known value");
                }
                try out.append(self.pass.allocator, try self.materialize(.{ .private_state = value }));
            },
            .tag => |tag| {
                const private_tag = privateStateTag(value) orelse
                    Common.invariant("tag call pattern matched non-tag private state");
                if (!sameType(self.pass.program, tag.ty, private_tag.ty) or tag.name != private_tag.name) {
                    Common.invariant("tag call pattern matched different private tag state");
                }
                for (tag.payloads, 0..) |payload_known_value, index| {
                    const payload = privateStateIndexedValueByIndex(private_tag.payloads, @intCast(index)) orelse
                        Common.invariant("private tag payload was missing after matching");
                    try self.appendExprsFromPrivateStateKnownValue(payload_known_value, payload, out);
                }
            },
            .record => |record| {
                if (!sameType(self.pass.program, record.ty, privateStateValueType(value))) {
                    Common.invariant("record call pattern matched different private state type");
                }
                for (record.fields) |field| {
                    const field_value = privateStateField(value, field.name) orelse
                        Common.invariant("private record field was missing after matching");
                    try self.appendExprsFromPrivateStateKnownValue(field.known_value, field_value, out);
                }
            },
            .tuple => |tuple| {
                if (!sameType(self.pass.program, tuple.ty, privateStateValueType(value))) {
                    Common.invariant("tuple call pattern matched different private state type");
                }
                for (tuple.items, 0..) |item_known_value, index| {
                    const item = privateStateItem(value, @intCast(index)) orelse
                        Common.invariant("private tuple item was missing after matching");
                    try self.appendExprsFromPrivateStateKnownValue(item_known_value, item, out);
                }
            },
            .nominal => |nominal| {
                const private_nominal = switch (value) {
                    .nominal => |private_nominal| private_nominal,
                    else => Common.invariant("nominal call pattern matched non-nominal private state"),
                };
                if (!sameType(self.pass.program, nominal.ty, private_nominal.ty)) {
                    Common.invariant("nominal call pattern matched different private state type");
                }
                const backing = private_nominal.backing orelse
                    Common.invariant("private nominal backing was missing after matching");
                try self.appendExprsFromPrivateStateKnownValue(nominal.backing.*, backing.*, out);
            },
            .callable => |callable| {
                const private_callable = privateStateCallable(value) orelse
                    Common.invariant("callable call pattern matched non-callable private state");
                if (!sameType(self.pass.program, callable.ty, private_callable.ty) or
                    !callableTargetMatches(self.pass.program, callable.fn_id, private_callable.fn_id))
                {
                    Common.invariant("callable call pattern matched different private callable state");
                }
                for (callable.captures, 0..) |capture_known_value, index| {
                    const capture = privateStateIndexedValueByIndex(private_callable.captures, @intCast(index)) orelse
                        Common.invariant("private callable capture was missing after matching");
                    try self.appendExprsFromPrivateStateKnownValue(capture_known_value, capture, out);
                }
            },
            .finite_tags,
            .finite_callables,
            => Common.invariant("finite known value matched private state without selector state"),
        }
    }

    fn appendUninitializedExprsForKnownValue(
        self: *Cloner,
        known_value: KnownValue,
        out: *std.ArrayList(Ast.ExprId),
    ) Common.LowerError!void {
        switch (known_value) {
            .any,
            .leaf,
            => |ty| try out.append(self.pass.allocator, try self.addExpr(.{ .ty = ty, .data = .uninitialized })),
            .tag => |tag| {
                for (tag.payloads) |payload| try self.appendUninitializedExprsForKnownValue(payload, out);
            },
            .record => |record| {
                for (record.fields) |field| try self.appendUninitializedExprsForKnownValue(field.known_value, out);
            },
            .tuple => |tuple| {
                for (tuple.items) |item| try self.appendUninitializedExprsForKnownValue(item, out);
            },
            .nominal => |nominal| try self.appendUninitializedExprsForKnownValue(nominal.backing.*, out),
            .callable => |callable| {
                for (callable.captures) |capture| try self.appendUninitializedExprsForKnownValue(capture, out);
            },
            .finite_callables => |finite_callables| {
                const selector_ty = try self.pass.primitiveType(.u64);
                try out.append(self.pass.allocator, try self.addExpr(.{ .ty = selector_ty, .data = .uninitialized }));
                for (finite_callables.alternatives) |alternative| {
                    for (alternative.captures) |capture| try self.appendUninitializedExprsForKnownValue(capture, out);
                }
            },
            .finite_tags => |finite_tags| {
                const selector_ty = try self.pass.primitiveType(.u64);
                try out.append(self.pass.allocator, try self.addExpr(.{ .ty = selector_ty, .data = .uninitialized }));
                for (finite_tags.alternatives) |alternative| {
                    for (alternative.payloads) |payload| try self.appendUninitializedExprsForKnownValue(payload, out);
                }
            },
        }
    }

    fn appendFieldReadExprsFromValue(
        self: *Cloner,
        known_value: KnownValue,
        value: Value,
        out: *std.ArrayList(Ast.ExprId),
    ) Common.LowerError!bool {
        switch (known_value) {
            .any,
            .leaf,
            => {},
            else => if (value == .expr_with_known_value) {
                if (value.expr_with_known_value.value) |structured_value| {
                    if (try self.appendFieldReadExprsFromValue(known_value, structured_value.*, out)) return true;
                }
            },
        }

        if (value != .expr_with_known_value and knownValueMatchesValue(self.pass.program, known_value, value)) {
            const demanded = try materializedDemandedKnownValue(self.pass.arena.allocator(), known_value);
            return try self.appendExprsFromDemandedKnownValue(demanded, value, out);
        }

        switch (known_value) {
            .any,
            .leaf,
            => {
                if (value == .private_state) {
                    if (privateStateLeafExpr(value.private_state)) |leaf_expr| {
                        try out.append(self.pass.allocator, leaf_expr);
                        return true;
                    }
                    if (!privateStateCanMaterializePublic(self.pass.program, value.private_state)) return false;
                    try out.append(self.pass.allocator, try self.materializePublic(value));
                    return true;
                }
                if (!self.valueCanMaterializePublic(value)) return false;
                try out.append(self.pass.allocator, try self.materializePublic(value));
                return true;
            },
            .record => |record| {
                if (recordFromValue(value)) |record_value| {
                    for (record.fields) |field_known_value| {
                        const field_value = fieldFromRecord(record_value, field_known_value.name) orelse return false;
                        if (!try self.appendFieldReadExprsFromValue(field_known_value.known_value, field_value, out)) return false;
                    }
                    return true;
                }

                const receiver = projectableExprFromValue(value) orelse return false;
                if (!canReadFieldsFromExpr(self.pass.program, receiver)) return false;
                const actual_known_value = switch (value) {
                    .expr_with_known_value => |known_value_expr| known_value_expr.known_value,
                    else => null,
                };
                for (record.fields) |field| {
                    const actual_field = if (actual_known_value) |actual|
                        fieldKnownValueFromKnownValue(actual, field.name)
                    else
                        null;
                    const field_expr = try self.addExpr(.{ .ty = known_valueType(field.known_value), .data = .{ .field_access = .{
                        .receiver = receiver,
                        .field = field.name,
                    } } });
                    const field_value = if (actual_field) |actual|
                        valueFromProjectedExpr(field_expr, actual)
                    else
                        Value{ .expr = field_expr };
                    if (!try self.appendFieldReadExprsFromValue(field.known_value, field_value, out)) return false;
                }
                return true;
            },
            .tuple => |tuple| {
                if (tupleFromValue(value)) |tuple_value| {
                    if (tuple.items.len != tuple_value.items.len) return false;
                    for (tuple.items, tuple_value.items) |item_known_value, item_value| {
                        if (!try self.appendFieldReadExprsFromValue(item_known_value, item_value, out)) return false;
                    }
                    return true;
                }

                const receiver = projectableExprFromValue(value) orelse return false;
                if (!canReadFieldsFromExpr(self.pass.program, receiver)) return false;
                const actual_known_value = switch (value) {
                    .expr_with_known_value => |known_value_expr| known_value_expr.known_value,
                    else => null,
                };
                for (tuple.items, 0..) |item, index| {
                    const actual_item = if (actual_known_value) |actual|
                        itemKnownValueFromKnownValue(actual, @as(u32, @intCast(index)))
                    else
                        null;
                    const item_expr = try self.addExpr(.{ .ty = known_valueType(item), .data = .{ .tuple_access = .{
                        .tuple = receiver,
                        .elem_index = @as(u32, @intCast(index)),
                    } } });
                    const item_value = if (actual_item) |actual|
                        valueFromProjectedExpr(item_expr, actual)
                    else
                        Value{ .expr = item_expr };
                    if (!try self.appendFieldReadExprsFromValue(item, item_value, out)) return false;
                }
                return true;
            },
            .nominal => |nominal| {
                const backing_value = switch (value) {
                    .nominal => |nominal_value| nominal_value.backing.*,
                    else => value,
                };
                return try self.appendFieldReadExprsFromValue(nominal.backing.*, backing_value, out);
            },
            .callable => |callable| {
                const callable_value = switch (value) {
                    .callable => |callable_value| callable_value,
                    else => return false,
                };
                if (!callableTargetMatches(self.pass.program, callable.fn_id, callable_value.fn_id) or
                    callable.captures.len != callable_value.captures.len)
                {
                    return false;
                }
                for (callable.captures, callable_value.captures) |capture_known_value, capture_value| {
                    if (!try self.appendFieldReadExprsFromValue(capture_known_value, capture_value, out)) return false;
                }
                return true;
            },
            .finite_callables => |finite_callables| {
                if (value == .finite_callables) {
                    const finite_value = value.finite_callables;
                    if (!knownCallablesMatchesValue(self.pass.program, finite_callables, finite_value)) return false;
                    try out.append(self.pass.allocator, finite_value.selector);
                    for (finite_callables.alternatives, finite_value.alternatives) |alternative_known_value, alternative_value| {
                        for (alternative_known_value.captures, alternative_value.captures) |capture_known_value, capture_value| {
                            if (!try self.appendFieldReadExprsFromValue(capture_known_value, capture_value, out)) return false;
                        }
                    }
                    return true;
                }
                const callable_value = switch (value) {
                    .callable => |callable_value| callable_value,
                    else => return false,
                };
                const active_index = finiteCallableAlternativeIndex(self.pass.program, finite_callables.alternatives, callable_value) orelse return false;
                try out.append(self.pass.allocator, try self.selectorLiteral(@intCast(active_index)));
                for (finite_callables.alternatives, 0..) |alternative_known_value, alternative_index| {
                    if (alternative_index == active_index) {
                        for (alternative_known_value.captures, callable_value.captures) |capture_known_value, capture_value| {
                            if (!try self.appendFieldReadExprsFromValue(capture_known_value, capture_value, out)) return false;
                        }
                    } else {
                        for (alternative_known_value.captures) |capture_known_value| {
                            try self.appendUninitializedExprsForKnownValue(capture_known_value, out);
                        }
                    }
                }
                return true;
            },
            .finite_tags => |finite_tags| {
                if (value == .finite_tags) {
                    const finite_value = value.finite_tags;
                    if (!knownTagsMatchesValue(self.pass.program, finite_tags, finite_value)) return false;
                    try out.append(self.pass.allocator, finite_value.selector);
                    for (finite_tags.alternatives, finite_value.alternatives) |alternative_known_value, alternative_value| {
                        for (alternative_known_value.payloads, alternative_value.payloads) |payload_known_value, payload_value| {
                            if (!try self.appendFieldReadExprsFromValue(payload_known_value, payload_value, out)) return false;
                        }
                    }
                    return true;
                }
                const tag_value = switch (value) {
                    .tag => |tag_value| tag_value,
                    else => return false,
                };
                const active_index = finiteTagAlternativeIndex(self.pass.program, finite_tags.alternatives, tag_value) orelse return false;
                try out.append(self.pass.allocator, try self.selectorLiteral(@intCast(active_index)));
                for (finite_tags.alternatives, 0..) |alternative_known_value, alternative_index| {
                    if (alternative_index == active_index) {
                        for (alternative_known_value.payloads, tag_value.payloads) |payload_known_value, payload_value| {
                            if (!try self.appendFieldReadExprsFromValue(payload_known_value, payload_value, out)) return false;
                        }
                    } else {
                        for (alternative_known_value.payloads) |payload_known_value| {
                            try self.appendUninitializedExprsForKnownValue(payload_known_value, out);
                        }
                    }
                }
                return true;
            },
            .tag,
            => return false,
        }
    }

    fn appendFieldReadExprsFromValueCollectingLets(
        self: *Cloner,
        known_value: KnownValue,
        value: Value,
        out: *std.ArrayList(Ast.ExprId),
        pending_lets: *std.ArrayList(PendingLet),
    ) Common.LowerError!bool {
        if (value == .let_) {
            const let_value = value.let_;
            try self.appendPendingLetsUnique(pending_lets, let_value.lets);
            return try self.appendFieldReadExprsFromValueCollectingLets(known_value, let_value.body.*, out, pending_lets);
        }
        return try self.appendFieldReadExprsFromValue(known_value, value, out);
    }

    fn appendExprsFromDemandedKnownValue(
        self: *Cloner,
        known_value: DemandedKnownValue,
        value: Value,
        out: *std.ArrayList(Ast.ExprId),
    ) Common.LowerError!bool {
        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        var extracted = std.ArrayList(Ast.ExprId).empty;
        defer extracted.deinit(self.pass.allocator);

        if (!try self.appendExprsFromDemandedKnownValueCollectingLets(known_value, value, &extracted, &pending_lets)) return false;

        for (extracted.items) |expr| {
            const expr_ty = self.pass.program.exprs.items[@intFromEnum(expr)].ty;
            try out.append(self.pass.allocator, try self.wrapPendingLetsAroundExpr(expr_ty, expr, pending_lets.items));
        }
        return true;
    }

    fn appendExprsFromDemandedKnownValueCollectingLets(
        self: *Cloner,
        known_value: DemandedKnownValue,
        value: Value,
        out: *std.ArrayList(Ast.ExprId),
        pending_lets: *std.ArrayList(PendingLet),
    ) Common.LowerError!bool {
        if (value == .let_) {
            const let_value = value.let_;
            try self.appendPendingLetsUnique(pending_lets, let_value.lets);
            return try self.appendExprsFromDemandedKnownValueCollectingLets(known_value, let_value.body.*, out, pending_lets);
        }

        switch (known_value) {
            .any,
            .leaf,
            => {
                if (value == .private_state) {
                    if (privateStateLeafExpr(value.private_state)) |leaf_expr| {
                        try out.append(self.pass.allocator, leaf_expr);
                    } else if (privateStateCanMaterializePublic(self.pass.program, value.private_state)) {
                        try out.append(self.pass.allocator, try self.materialize(.{ .private_state = value.private_state }));
                    } else {
                        return false;
                    }
                    return true;
                }
                if (!self.valueCanMaterializePublic(value)) return false;
                const expr = try self.materializePublic(value);
                try out.append(self.pass.allocator, expr);
                return true;
            },
            .record => |record| {
                if (value == .private_state) {
                    for (record.fields) |field_known_value| {
                        const field_value = privateStateField(value.private_state, field_known_value.name) orelse return false;
                        if (!try self.appendExprsFromDemandedKnownValueCollectingLets(field_known_value.known_value, .{ .private_state = field_value }, out, pending_lets)) return false;
                    }
                    return true;
                }

                if (recordFromValue(value)) |record_value| {
                    for (record.fields) |field_known_value| {
                        const field_value = fieldFromRecord(record_value, field_known_value.name) orelse return false;
                        if (!try self.appendExprsFromDemandedKnownValueCollectingLets(field_known_value.known_value, field_value, out, pending_lets)) return false;
                    }
                    return true;
                }

                var projected = true;
                for (record.fields) |field_known_value| {
                    const field_value = (try self.fieldFromKnownValue(value, field_known_value.name)) orelse {
                        projected = false;
                        break;
                    };
                    if (!try self.appendExprsFromDemandedKnownValueCollectingLets(field_known_value.known_value, field_value, out, pending_lets)) {
                        projected = false;
                        break;
                    }
                }
                if (projected) return true;

                const receiver = projectableExprFromValue(value) orelse return false;
                if (!canReadFieldsFromExpr(self.pass.program, receiver)) return false;
                for (record.fields) |field| {
                    const field_expr = try self.addExpr(.{ .ty = demandedKnownValueType(field.known_value), .data = .{ .field_access = .{
                        .receiver = receiver,
                        .field = field.name,
                    } } });
                    if (!try self.appendExprsFromDemandedKnownValueCollectingLets(field.known_value, .{ .expr = field_expr }, out, pending_lets)) return false;
                }
                return true;
            },
            .tuple => |tuple| {
                if (value == .private_state) {
                    for (tuple.items) |item_known_value| {
                        const item_value = privateStateItem(value.private_state, item_known_value.index) orelse return false;
                        if (!try self.appendExprsFromDemandedKnownValueCollectingLets(item_known_value.known_value, .{ .private_state = item_value }, out, pending_lets)) return false;
                    }
                    return true;
                }

                if (tupleFromValue(value)) |tuple_value| {
                    for (tuple.items) |item_known_value| {
                        if (item_known_value.index >= tuple_value.items.len) return false;
                        if (!try self.appendExprsFromDemandedKnownValueCollectingLets(item_known_value.known_value, tuple_value.items[item_known_value.index], out, pending_lets)) return false;
                    }
                    return true;
                }

                var projected = true;
                for (tuple.items) |item_known_value| {
                    const item_value = (try self.itemFromKnownValue(value, item_known_value.index)) orelse {
                        projected = false;
                        break;
                    };
                    if (!try self.appendExprsFromDemandedKnownValueCollectingLets(item_known_value.known_value, item_value, out, pending_lets)) {
                        projected = false;
                        break;
                    }
                }
                if (projected) return true;

                const receiver = projectableExprFromValue(value) orelse return false;
                if (!canReadFieldsFromExpr(self.pass.program, receiver)) return false;
                for (tuple.items) |item| {
                    const item_expr = try self.addExpr(.{ .ty = demandedKnownValueType(item.known_value), .data = .{ .tuple_access = .{
                        .tuple = receiver,
                        .elem_index = item.index,
                    } } });
                    if (!try self.appendExprsFromDemandedKnownValueCollectingLets(item.known_value, .{ .expr = item_expr }, out, pending_lets)) return false;
                }
                return true;
            },
            .nominal => |nominal| {
                const backing = nominal.backing orelse return true;
                if (value == .private_state) {
                    const private_nominal = switch (value.private_state) {
                        .nominal => |private_nominal| private_nominal,
                        else => return try self.appendExprsFromDemandedKnownValueCollectingLets(backing.*, value, out, pending_lets),
                    };
                    const backing_value = private_nominal.backing orelse return false;
                    return try self.appendExprsFromDemandedKnownValueCollectingLets(backing.*, .{ .private_state = backing_value.* }, out, pending_lets);
                }
                const backing_value = switch (value) {
                    .nominal => |nominal_value| nominal_value.backing.*,
                    else => value,
                };
                return try self.appendExprsFromDemandedKnownValueCollectingLets(backing.*, backing_value, out, pending_lets);
            },
            .tag => |tag| {
                if (value == .expr_with_known_value) {
                    if (!demandedKnownValueMatchesKnownValue(self.pass.program, known_value, value.expr_with_known_value.known_value)) return false;
                    return tag.payloads.len == 0;
                }
                if (value == .private_state) {
                    const private_tag = privateStateTag(value.private_state) orelse return false;
                    if (!sameType(self.pass.program, tag.ty, private_tag.ty) or tag.name != private_tag.name) return false;
                    for (tag.payloads) |payload_known_value| {
                        const payload_value = privateStateIndexedValueByIndex(private_tag.payloads, payload_known_value.index) orelse return false;
                        if (!try self.appendExprsFromDemandedKnownValueCollectingLets(payload_known_value.known_value, .{ .private_state = payload_value }, out, pending_lets)) return false;
                    }
                    return true;
                }

                const tag_value = tagFromValue(value) orelse return false;
                if (!sameType(self.pass.program, tag.ty, tag_value.ty) or tag.name != tag_value.name) return false;
                for (tag.payloads) |payload_known_value| {
                    if (payload_known_value.index >= tag_value.payloads.len) return false;
                    if (!try self.appendExprsFromDemandedKnownValueCollectingLets(payload_known_value.known_value, tag_value.payloads[payload_known_value.index], out, pending_lets)) return false;
                }
                return true;
            },
            .callable => |callable| {
                if (value == .expr_with_known_value) {
                    if (!demandedKnownValueMatchesKnownValue(self.pass.program, known_value, value.expr_with_known_value.known_value)) return false;
                    return callable.captures.len == 0;
                }
                if (value == .private_state) {
                    const private_callable = privateStateCallable(value.private_state) orelse return false;
                    if (!sameType(self.pass.program, callable.ty, private_callable.ty) or
                        !callableTargetMatches(self.pass.program, callable.fn_id, private_callable.fn_id))
                    {
                        return false;
                    }
                    for (callable.captures) |capture_known_value| {
                        const capture_value = privateStateIndexedValueByIndex(private_callable.captures, capture_known_value.index) orelse return false;
                        if (!try self.appendExprsFromDemandedKnownValueCollectingLets(capture_known_value.known_value, .{ .private_state = capture_value }, out, pending_lets)) return false;
                    }
                    return true;
                }

                if (value == .if_) {
                    if (!demandedKnownValueMatchesValue(self.pass.program, known_value, value)) return false;
                    for (callable.captures) |capture_known_value| {
                        const capture_demand = try self.pass.valueDemandFromDemandedKnownValue(capture_known_value.known_value);
                        const capture_value = (try self.callableCaptureFromIfValue(value.if_, callable, capture_known_value.index, capture_demand)) orelse return false;
                        if (!try self.appendExprsFromDemandedKnownValueCollectingLets(capture_known_value.known_value, capture_value, out, pending_lets)) return false;
                    }
                    return true;
                }

                if (value == .match_) {
                    if (!demandedKnownValueMatchesValue(self.pass.program, known_value, value)) return false;
                    for (callable.captures) |capture_known_value| {
                        const capture_demand = try self.pass.valueDemandFromDemandedKnownValue(capture_known_value.known_value);
                        const capture_value = (try self.callableCaptureFromMatchValue(value.match_, callable, capture_known_value.index, capture_demand)) orelse return false;
                        if (!try self.appendExprsFromDemandedKnownValueCollectingLets(capture_known_value.known_value, capture_value, out, pending_lets)) return false;
                    }
                    return true;
                }

                const callable_value = switch (value) {
                    .callable => |callable_value| callable_value,
                    else => return false,
                };
                if (!sameType(self.pass.program, callable.ty, callable_value.ty) or
                    !callableTargetMatches(self.pass.program, callable.fn_id, callable_value.fn_id))
                {
                    return false;
                }
                for (callable.captures) |capture_known_value| {
                    if (capture_known_value.index >= callable_value.captures.len) return false;
                    if (!try self.appendExprsFromDemandedKnownValueCollectingLets(capture_known_value.known_value, callable_value.captures[capture_known_value.index], out, pending_lets)) return false;
                }
                return true;
            },
            .finite_tags,
            => |finite_tags| {
                if (value == .private_state) {
                    const finite_value = privateStateFiniteTags(value.private_state) orelse return false;
                    if (!demandedKnownValueMatchesPrivateState(self.pass.program, known_value, value.private_state)) return false;
                    try out.append(self.pass.allocator, finite_value.selector);
                    for (finite_tags.alternatives, finite_value.alternatives) |alternative_known_value, alternative_value| {
                        for (alternative_known_value.payloads) |payload_known_value| {
                            const payload_value = privateStateIndexedValueByIndex(alternative_value.payloads, payload_known_value.index) orelse return false;
                            if (!try self.appendExprsFromDemandedKnownValueCollectingLets(payload_known_value.known_value, .{ .private_state = payload_value }, out, pending_lets)) return false;
                        }
                    }
                    return true;
                }
                if (value == .finite_tags) {
                    const finite_value = value.finite_tags;
                    if (!demandedKnownValueMatchesValue(self.pass.program, known_value, value)) return false;
                    try out.append(self.pass.allocator, finite_value.selector);
                    for (finite_tags.alternatives, finite_value.alternatives) |alternative_known_value, alternative_value| {
                        for (alternative_known_value.payloads) |payload_known_value| {
                            if (payload_known_value.index >= alternative_value.payloads.len) return false;
                            if (!try self.appendExprsFromDemandedKnownValueCollectingLets(payload_known_value.known_value, alternative_value.payloads[payload_known_value.index], out, pending_lets)) return false;
                        }
                    }
                    return true;
                }
                return false;
            },
            .finite_callables => |finite_callables| {
                if (value == .private_state) {
                    const finite_value = privateStateFiniteCallables(value.private_state) orelse return false;
                    if (!demandedKnownValueMatchesPrivateState(self.pass.program, known_value, value.private_state)) return false;
                    try out.append(self.pass.allocator, finite_value.selector);
                    for (finite_callables.alternatives, finite_value.alternatives) |alternative_known_value, alternative_value| {
                        for (alternative_known_value.captures) |capture_known_value| {
                            const capture_value = privateStateIndexedValueByIndex(alternative_value.captures, capture_known_value.index) orelse return false;
                            if (!try self.appendExprsFromDemandedKnownValueCollectingLets(capture_known_value.known_value, .{ .private_state = capture_value }, out, pending_lets)) return false;
                        }
                    }
                    return true;
                }
                if (value == .finite_callables) {
                    const finite_value = value.finite_callables;
                    if (!demandedKnownValueMatchesValue(self.pass.program, known_value, value)) return false;
                    try out.append(self.pass.allocator, finite_value.selector);
                    for (finite_callables.alternatives, finite_value.alternatives) |alternative_known_value, alternative_value| {
                        for (alternative_known_value.captures) |capture_known_value| {
                            if (capture_known_value.index >= alternative_value.captures.len) return false;
                            if (!try self.appendExprsFromDemandedKnownValueCollectingLets(capture_known_value.known_value, alternative_value.captures[capture_known_value.index], out, pending_lets)) return false;
                        }
                    }
                    return true;
                }
                return false;
            },
        }
    }

    fn callableCaptureFromIfValue(
        self: *Cloner,
        if_value: IfValue,
        callable: DemandedKnownCallable,
        capture_index: u32,
        capture_demand: ValueDemand,
    ) Common.LowerError!?Value {
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
        var capture_ty: ?Type.TypeId = null;
        const callable_demand = try self.callableCaptureDemand(capture_index, capture_demand);
        for (if_value.branches, branches) |branch, *out| {
            const branch_body = try self.applyValueDemand(branch.body, callable_demand);
            const capture = (try self.callableCaptureFromValue(branch_body, callable, capture_index)) orelse return null;
            if (capture_ty == null) capture_ty = valueType(self.pass.program, capture);
            out.* = .{
                .cond = branch.cond,
                .body = capture,
            };
        }

        const final_capture = (try self.callableCaptureFromValue(if_value.final_else.*, callable, capture_index)) orelse return null;
        if (capture_ty == null) capture_ty = valueType(self.pass.program, final_capture);
        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = final_capture;

        return Value{ .if_ = .{
            .ty = capture_ty orelse return null,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn callableCaptureFromMatchValue(
        self: *Cloner,
        match_value: MatchValue,
        callable: DemandedKnownCallable,
        capture_index: u32,
        capture_demand: ValueDemand,
    ) Common.LowerError!?Value {
        const branches = try self.pass.arena.allocator().alloc(MatchValueBranch, match_value.branches.len);
        var capture_ty: ?Type.TypeId = null;
        const callable_demand = try self.callableCaptureDemand(capture_index, capture_demand);
        for (match_value.branches, branches) |branch, *out| {
            const branch_value = try self.cloneMatchValueBranchBodyWithDemand(branch, callable_demand);
            const capture = (try self.callableCaptureFromValue(branch_value, callable, capture_index)) orelse return null;
            if (capture_ty == null) capture_ty = valueType(self.pass.program, capture);
            const source = if (branch.source) |source| source_blk: {
                break :source_blk MatchValueBranchSource{
                    .scrutinee = source.scrutinee,
                    .pat = source.pat,
                    .guard = source.guard,
                    .body = source.body,
                    .scrutinee_known_value = source.scrutinee_known_value,
                    .scrutinee_value = source.scrutinee_value,
                    .bindings = source.bindings,
                    .read = .{ .callable_capture = .{
                        .callable = callable,
                        .capture_index = capture_index,
                    } },
                };
            } else null;
            out.* = .{
                .pat = branch.pat,
                .guard = branch.guard,
                .body = capture,
                .source = source,
            };
        }

        return Value{ .match_ = .{
            .ty = capture_ty orelse return null,
            .scrutinee = match_value.scrutinee,
            .branches = branches,
            .comptime_site = match_value.comptime_site,
        } };
    }

    fn callableCaptureDemand(
        self: *Cloner,
        capture_index: u32,
        capture_demand: ValueDemand,
    ) Allocator.Error!ValueDemand {
        const captures = try self.pass.arena.allocator().alloc(ValueDemand, @as(usize, capture_index) + 1);
        @memset(captures, .none);
        captures[capture_index] = capture_demand;
        return .{ .callable = .{ .captures = captures } };
    }

    fn callableCaptureFromValue(
        self: *Cloner,
        value: Value,
        callable: DemandedKnownCallable,
        capture_index: u32,
    ) Common.LowerError!?Value {
        if (value == .let_) {
            const capture = (try self.callableCaptureFromValue(value.let_.body.*, callable, capture_index)) orelse return null;
            return try self.wrapPendingLets(capture, value.let_.lets, true);
        }

        if (value == .private_state) {
            if (privateStateCallable(value.private_state)) |private_callable| {
                if (!sameType(self.pass.program, callable.ty, private_callable.ty) or
                    !callableTargetMatches(self.pass.program, callable.fn_id, private_callable.fn_id))
                {
                    return null;
                }
                const capture = privateStateIndexedValueByIndex(private_callable.captures, capture_index) orelse return null;
                return .{ .private_state = capture };
            }

            if (privateStateFiniteCallables(value.private_state)) |finite_callables| {
                var found: ?PrivateStateValue = null;
                for (finite_callables.alternatives) |alternative| {
                    if (!sameType(self.pass.program, callable.ty, alternative.ty) or
                        !callableTargetMatches(self.pass.program, callable.fn_id, alternative.fn_id))
                    {
                        continue;
                    }
                    const capture = privateStateIndexedValueByIndex(alternative.captures, capture_index) orelse return null;
                    if (found != null) return null;
                    found = capture;
                }
                return if (found) |capture| .{ .private_state = capture } else null;
            }

            return null;
        }

        if (value == .finite_callables) {
            var found: ?Value = null;
            for (value.finite_callables.alternatives) |alternative| {
                if (!sameType(self.pass.program, callable.ty, alternative.ty) or
                    !callableTargetMatches(self.pass.program, callable.fn_id, alternative.fn_id))
                {
                    continue;
                }
                if (capture_index >= alternative.captures.len) return null;
                if (found != null) return null;
                found = alternative.captures[capture_index];
            }
            return found;
        }

        const callable_value = switch (value) {
            .callable => |callable_value| callable_value,
            else => return null,
        };
        if (!sameType(self.pass.program, callable.ty, callable_value.ty) or
            !callableTargetMatches(self.pass.program, callable.fn_id, callable_value.fn_id) or
            capture_index >= callable_value.captures.len)
        {
            return null;
        }
        return callable_value.captures[capture_index];
    }

    fn selectorLiteral(self: *Cloner, value: u64) Common.LowerError!Ast.ExprId {
        const selector_ty = try self.pass.primitiveType(.u64);
        return try self.addExpr(.{
            .ty = selector_ty,
            .data = .{ .int_lit = unsignedIntLiteral(value) },
        });
    }

    fn selectorEquals(self: *Cloner, selector: Ast.ExprId, value: u64) Common.LowerError!Ast.ExprId {
        const bool_ty = try self.pass.primitiveType(.bool);
        const literal = try self.selectorLiteral(value);
        const args = try self.pass.program.addExprSpan(&.{ selector, literal });
        return try self.addExpr(.{
            .ty = bool_ty,
            .data = .{ .low_level = .{
                .op = .num_is_eq,
                .args = args,
            } },
        });
    }

    fn cloneFieldAccess(self: *Cloner, ty: Type.TypeId, field: anytype) Common.LowerError!Ast.ExprId {
        try self.noteLoopDemandIfLocalExpr(
            field.receiver,
            try self.pass.demandRecordField(field.field, .materialize),
        );
        const receiver = try self.cloneExprValueDemandingKnownValue(field.receiver);
        if (try self.fieldFromKnownValue(receiver, field.field)) |value| return try self.materialize(value);
        return try self.addExpr(.{ .ty = ty, .data = .{ .field_access = .{
            .receiver = try self.materialize(receiver),
            .field = field.field,
        } } });
    }

    fn cloneTupleAccess(self: *Cloner, ty: Type.TypeId, access: anytype) Common.LowerError!Ast.ExprId {
        try self.noteLoopDemandIfLocalExpr(
            access.tuple,
            try self.pass.demandTupleItem(access.elem_index, .materialize),
        );
        const receiver = try self.cloneExprValueDemandingKnownValue(access.tuple);
        if (try self.itemFromKnownValue(receiver, access.elem_index)) |value| return try self.materialize(value);
        return try self.addExpr(.{ .ty = ty, .data = .{ .tuple_access = .{
            .tuple = try self.materialize(receiver),
            .elem_index = access.elem_index,
        } } });
    }

    fn fieldFromKnownValue(self: *Cloner, receiver: Value, field: names.RecordFieldNameId) Common.LowerError!?Value {
        if (receiver == .let_) {
            const let_value = receiver.let_;
            const field_value = (try self.fieldFromKnownValue(let_value.body.*, field)) orelse return null;
            return try self.wrapPendingLets(field_value, let_value.lets, true);
        }
        if (receiver == .if_) {
            const if_value = receiver.if_;
            const final_else = try self.pass.arena.allocator().create(Value);
            final_else.* = (try self.fieldFromKnownValue(if_value.final_else.*, field)) orelse return null;

            const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
            for (if_value.branches, branches) |branch, *out| {
                out.* = .{
                    .cond = branch.cond,
                    .body = (try self.fieldFromKnownValue(branch.body, field)) orelse return null,
                };
            }

            const field_ty = recordFieldType(self.pass.program, if_value.ty, field) orelse valueType(self.pass.program, final_else.*);
            return Value{ .if_ = .{
                .ty = field_ty,
                .branches = branches,
                .final_else = final_else,
            } };
        }
        if (receiver == .match_) {
            const match_value = receiver.match_;
            const branches = try self.pass.arena.allocator().alloc(MatchValueBranch, match_value.branches.len);
            var field_ty = recordFieldType(self.pass.program, match_value.ty, field);
            for (match_value.branches, branches) |branch, *out| {
                const body = (try self.fieldFromKnownValue(branch.body, field)) orelse return null;
                if (field_ty == null) field_ty = valueType(self.pass.program, body);
                const source = if (branch.source) |source| source_blk: {
                    break :source_blk MatchValueBranchSource{
                        .scrutinee = source.scrutinee,
                        .pat = source.pat,
                        .guard = source.guard,
                        .body = try self.addExpr(.{ .ty = valueType(self.pass.program, body), .data = .{ .field_access = .{
                            .receiver = source.body,
                            .field = field,
                        } } }),
                        .scrutinee_known_value = source.scrutinee_known_value,
                        .scrutinee_value = source.scrutinee_value,
                        .bindings = source.bindings,
                    };
                } else null;
                out.* = .{
                    .pat = branch.pat,
                    .guard = branch.guard,
                    .body = body,
                    .source = source,
                };
            }

            return Value{ .match_ = .{
                .ty = field_ty orelse return null,
                .scrutinee = match_value.scrutinee,
                .branches = branches,
                .comptime_site = match_value.comptime_site,
            } };
        }
        if (fieldFromValue(receiver, field)) |value| return value;

        const known_value_expr = switch (receiver) {
            .expr_with_known_value => |known_value_expr| known_value_expr,
            else => return null,
        };
        if (!canReadFieldsFromExpr(self.pass.program, known_value_expr.expr)) return null;

        const field_known_value = fieldKnownValueFromKnownValue(known_value_expr.known_value, field) orelse return null;
        const field_expr = try self.addExpr(.{ .ty = known_valueType(field_known_value), .data = .{ .field_access = .{
            .receiver = known_value_expr.expr,
            .field = field,
        } } });
        return valueFromProjectedExpr(field_expr, field_known_value);
    }

    fn itemFromKnownValue(self: *Cloner, receiver: Value, index: u32) Common.LowerError!?Value {
        if (receiver == .let_) {
            const let_value = receiver.let_;
            const item_value = (try self.itemFromKnownValue(let_value.body.*, index)) orelse return null;
            return try self.wrapPendingLets(item_value, let_value.lets, true);
        }
        if (receiver == .if_) {
            const if_value = receiver.if_;
            const final_else = try self.pass.arena.allocator().create(Value);
            final_else.* = (try self.itemFromKnownValue(if_value.final_else.*, index)) orelse return null;

            const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
            for (if_value.branches, branches) |branch, *out| {
                out.* = .{
                    .cond = branch.cond,
                    .body = (try self.itemFromKnownValue(branch.body, index)) orelse return null,
                };
            }

            const item_ty = tupleItemType(self.pass.program, if_value.ty, index) orelse valueType(self.pass.program, final_else.*);
            return Value{ .if_ = .{
                .ty = item_ty,
                .branches = branches,
                .final_else = final_else,
            } };
        }
        if (receiver == .match_) {
            const match_value = receiver.match_;
            const branches = try self.pass.arena.allocator().alloc(MatchValueBranch, match_value.branches.len);
            var item_ty = tupleItemType(self.pass.program, match_value.ty, index);
            for (match_value.branches, branches) |branch, *out| {
                const body = (try self.itemFromKnownValue(branch.body, index)) orelse return null;
                if (item_ty == null) item_ty = valueType(self.pass.program, body);
                const source = if (branch.source) |source| source_blk: {
                    break :source_blk MatchValueBranchSource{
                        .scrutinee = source.scrutinee,
                        .pat = source.pat,
                        .guard = source.guard,
                        .body = try self.addExpr(.{ .ty = valueType(self.pass.program, body), .data = .{ .tuple_access = .{
                            .tuple = source.body,
                            .elem_index = index,
                        } } }),
                        .scrutinee_known_value = source.scrutinee_known_value,
                        .scrutinee_value = source.scrutinee_value,
                        .bindings = source.bindings,
                    };
                } else null;
                out.* = .{
                    .pat = branch.pat,
                    .guard = branch.guard,
                    .body = body,
                    .source = source,
                };
            }

            return Value{ .match_ = .{
                .ty = item_ty orelse return null,
                .scrutinee = match_value.scrutinee,
                .branches = branches,
                .comptime_site = match_value.comptime_site,
            } };
        }
        if (itemFromValue(receiver, index)) |value| return value;

        const known_value_expr = switch (receiver) {
            .expr_with_known_value => |known_value_expr| known_value_expr,
            else => return null,
        };
        if (!canReadFieldsFromExpr(self.pass.program, known_value_expr.expr)) return null;

        const item_known_value = itemKnownValueFromKnownValue(known_value_expr.known_value, index) orelse return null;
        const item_expr = try self.addExpr(.{ .ty = known_valueType(item_known_value), .data = .{ .tuple_access = .{
            .tuple = known_value_expr.expr,
            .elem_index = index,
        } } });
        return valueFromProjectedExpr(item_expr, item_known_value);
    }

    fn cloneIfValue(self: *Cloner, ty: Type.TypeId, if_: anytype) Common.LowerError!Value {
        const source_branches = try self.pass.allocator.dupe(Ast.IfBranch, self.pass.program.ifBranchSpan(if_.branches));
        defer self.pass.allocator.free(source_branches);

        return try self.cloneIfValueFromBranches(ty, source_branches, 0, if_.final_else);
    }

    fn cloneIfValueFromBranches(
        self: *Cloner,
        ty: Type.TypeId,
        source_branches: []const Ast.IfBranch,
        index: usize,
        final_else: Ast.ExprId,
    ) Common.LowerError!Value {
        if (index == source_branches.len) {
            return try self.cloneExprValueDemandingKnownValue(final_else);
        }

        const branch = source_branches[index];
        const cond_value = try self.cloneExprValueDemandingKnownValue(branch.cond);
        if (knownIfConditionBoolTag(self.pass.program, cond_value)) |cond| {
            if (cond) return try self.cloneScopedExprValueDemandingKnownValue(branch.body);
            return try self.cloneIfValueFromBranches(ty, source_branches, index + 1, final_else);
        }
        if (finiteBoolTagsValue(self.pass.program, cond_value)) |finite_bool| {
            const true_value = try self.cloneScopedExprValueDemandingKnownValue(branch.body);
            const false_value = try self.cloneIfValueFromBranches(ty, source_branches, index + 1, final_else);
            return try self.selectFiniteBoolValue(ty, finite_bool, true_value, false_value);
        }

        const if_branches = try self.pass.arena.allocator().alloc(IfValueBranch, 1);
        if_branches[0] = .{
            .cond = try self.materialize(cond_value),
            .body = try self.cloneScopedExprValueDemandingKnownValue(branch.body),
        };
        const else_value = try self.pass.arena.allocator().create(Value);
        else_value.* = try self.cloneIfValueFromBranches(ty, source_branches, index + 1, final_else);
        return .{ .if_ = .{
            .ty = ty,
            .branches = if_branches,
            .final_else = else_value,
        } };
    }

    fn cloneScopedExprValueDemandingKnownValue(self: *Cloner, expr_id: Ast.ExprId) Common.LowerError!Value {
        const change_start = self.changes.items.len;
        const value = try self.cloneExprValueDemandingKnownValue(expr_id);
        self.restore(change_start);
        return value;
    }

    fn selectFiniteBoolValue(
        self: *Cloner,
        ty: Type.TypeId,
        finite_bool: FiniteTagsValue,
        true_value: Value,
        false_value: Value,
    ) Common.LowerError!Value {
        if (finite_bool.alternatives.len == 0) {
            Common.invariant("finite Bool value had no alternatives");
        }
        if (finite_bool.alternatives.len == 1) {
            const cond = boolTagValue(self.pass.program, finite_bool.alternatives[0]) orelse
                Common.invariant("finite Bool alternative was not Bool");
            return if (cond) true_value else false_value;
        }

        const branch_count = finite_bool.alternatives.len - 1;
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, branch_count);
        for (finite_bool.alternatives[0..branch_count], branches, 0..) |alternative, *out, alternative_index| {
            const cond = boolTagValue(self.pass.program, alternative) orelse
                Common.invariant("finite Bool alternative was not Bool");
            out.* = .{
                .cond = try self.selectorEquals(finite_bool.selector, @intCast(alternative_index)),
                .body = if (cond) true_value else false_value,
            };
        }

        const final_cond = boolTagValue(self.pass.program, finite_bool.alternatives[branch_count]) orelse
            Common.invariant("finite Bool final alternative was not Bool");
        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = if (final_cond) true_value else false_value;
        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn cloneMatchJoinedValue(
        self: *Cloner,
        ty: Type.TypeId,
        scrutinee_expr: Ast.ExprId,
        match: @import("../monotype/ast.zig").MatchExpr,
        scrutinee_known_value: ?KnownValue,
        scrutinee_value: ?Value,
    ) Common.LowerError!Value {
        const source_branches = try self.pass.allocator.dupe(Ast.Branch, self.pass.program.branchSpan(match.branches));
        defer self.pass.allocator.free(source_branches);

        var value_branches = std.ArrayList(MatchValueBranch).empty;
        defer value_branches.deinit(self.pass.allocator);

        for (source_branches) |branch| {
            if (scrutinee_known_value) |known_value| {
                if (patternDefinitelyExcludedByKnownValue(self.pass.program, branch.pat, known_value)) continue;
            }
            const change_start = self.changes.items.len;
            if (scrutinee_known_value) |known_value| {
                _ = try self.bindPatToExprWithKnownValueAndValue(branch.pat, known_value, scrutinee_value);
            }
            const cloned_branch = Ast.Branch{
                .pat = try self.clonePat(branch.pat),
                .guard = if (branch.guard) |guard| try self.cloneExpr(guard) else null,
                .body = undefined,
            };
            const body_value = try self.cloneExprValueDemandingKnownValue(branch.body);
            try value_branches.append(self.pass.allocator, .{
                .pat = cloned_branch.pat,
                .guard = cloned_branch.guard,
                .body = body_value,
                .source = .{
                    .scrutinee = match.scrutinee,
                    .pat = branch.pat,
                    .guard = branch.guard,
                    .body = branch.body,
                    .scrutinee_known_value = scrutinee_known_value,
                    .scrutinee_value = if (scrutinee_value) |value| try self.copyValue(value) else null,
                    .bindings = try self.snapshotSubst(),
                },
            });
            self.restore(change_start);
        }

        return .{ .match_ = .{
            .ty = ty,
            .scrutinee = scrutinee_expr,
            .branches = try self.pass.arena.allocator().dupe(MatchValueBranch, value_branches.items),
            .comptime_site = match.comptime_site,
        } };
    }

    fn cloneMatchJoinedValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        scrutinee_expr: Ast.ExprId,
        match: @import("../monotype/ast.zig").MatchExpr,
        scrutinee_known_value: ?KnownValue,
        scrutinee_value: ?Value,
        demand: ValueDemand,
    ) Common.LowerError!Value {
        const source_branches = try self.pass.allocator.dupe(Ast.Branch, self.pass.program.branchSpan(match.branches));
        defer self.pass.allocator.free(source_branches);

        var value_branches = std.ArrayList(MatchValueBranch).empty;
        defer value_branches.deinit(self.pass.allocator);

        for (source_branches) |branch| {
            if (scrutinee_known_value) |known_value| {
                if (patternDefinitelyExcludedByKnownValue(self.pass.program, branch.pat, known_value)) continue;
            }
            const change_start = self.changes.items.len;
            if (scrutinee_known_value) |known_value| {
                _ = try self.bindPatToExprWithKnownValueAndValue(branch.pat, known_value, scrutinee_value);
            }
            const cloned_branch = Ast.Branch{
                .pat = try self.clonePat(branch.pat),
                .guard = if (branch.guard) |guard| try self.cloneExpr(guard) else null,
                .body = undefined,
            };
            const body_value = try self.cloneExprValueWithDemand(branch.body, demand);
            try value_branches.append(self.pass.allocator, .{
                .pat = cloned_branch.pat,
                .guard = cloned_branch.guard,
                .body = body_value,
                .source = .{
                    .scrutinee = match.scrutinee,
                    .pat = branch.pat,
                    .guard = branch.guard,
                    .body = branch.body,
                    .scrutinee_known_value = scrutinee_known_value,
                    .scrutinee_value = if (scrutinee_value) |value| try self.copyValue(value) else null,
                    .bindings = try self.snapshotSubst(),
                },
            });
            self.restore(change_start);
        }

        return .{ .match_ = .{
            .ty = ty,
            .scrutinee = scrutinee_expr,
            .branches = try self.pass.arena.allocator().dupe(MatchValueBranch, value_branches.items),
            .comptime_site = match.comptime_site,
        } };
    }

    fn cloneMatchIfValue(
        self: *Cloner,
        ty: Type.TypeId,
        if_value: IfValue,
        match: @import("../monotype/ast.zig").MatchExpr,
    ) Common.LowerError!Value {
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
        for (if_value.branches, 0..) |branch, index| {
            branches[index] = .{
                .cond = branch.cond,
                .body = try self.cloneMatchScrutineeBranchValue(ty, branch.body, match),
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = try self.cloneMatchScrutineeBranchValue(ty, if_value.final_else.*, match);

        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn cloneMatchIfValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        if_value: IfValue,
        match: @import("../monotype/ast.zig").MatchExpr,
        demand: ValueDemand,
    ) Common.LowerError!?Value {
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
        for (if_value.branches, 0..) |branch, index| {
            const body = (try self.cloneMatchScrutineeBranchValueWithDemand(ty, branch.body, match, demand)) orelse return null;
            branches[index] = .{
                .cond = branch.cond,
                .body = body,
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = (try self.cloneMatchScrutineeBranchValueWithDemand(ty, if_value.final_else.*, match, demand)) orelse return null;

        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn cloneMatchMatchValue(
        self: *Cloner,
        ty: Type.TypeId,
        match_value: MatchValue,
        outer_match: @import("../monotype/ast.zig").MatchExpr,
    ) Common.LowerError!Value {
        const branches = try self.pass.arena.allocator().alloc(MatchValueBranch, match_value.branches.len);
        for (match_value.branches, 0..) |branch, index| {
            branches[index] = .{
                .pat = branch.pat,
                .guard = branch.guard,
                .body = try self.cloneMatchScrutineeBranchValue(ty, branch.body, outer_match),
                .source = try self.matchBranchSourceThroughMatch(branch.source, ty, outer_match.branches, outer_match.comptime_site),
            };
        }

        return .{ .match_ = .{
            .ty = ty,
            .scrutinee = match_value.scrutinee,
            .branches = branches,
            .comptime_site = match_value.comptime_site,
        } };
    }

    fn cloneMatchMatchValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        match_value: MatchValue,
        outer_match: @import("../monotype/ast.zig").MatchExpr,
        demand: ValueDemand,
    ) Common.LowerError!?Value {
        const outer_scrutinee_demand = try self.matchScrutineeDemand(outer_match.branches, demand);
        const branches = try self.pass.arena.allocator().alloc(MatchValueBranch, match_value.branches.len);
        for (match_value.branches, 0..) |branch, index| {
            const branch_body = try self.cloneMatchValueBranchBodyWithDemand(branch, outer_scrutinee_demand);
            branches[index] = .{
                .pat = branch.pat,
                .guard = branch.guard,
                .body = (try self.cloneMatchScrutineeBranchValueWithDemand(ty, branch_body, outer_match, demand)) orelse return null,
                .source = try self.matchBranchSourceThroughMatch(branch.source, ty, outer_match.branches, outer_match.comptime_site),
            };
        }

        return .{ .match_ = .{
            .ty = ty,
            .scrutinee = match_value.scrutinee,
            .branches = branches,
            .comptime_site = match_value.comptime_site,
        } };
    }

    fn cloneMatchScrutineeBranchValue(
        self: *Cloner,
        ty: Type.TypeId,
        scrutinee: Value,
        match: @import("../monotype/ast.zig").MatchExpr,
    ) Common.LowerError!Value {
        const scrutinee_demand = try self.matchScrutineeDemand(match.branches, .materialize);
        const demanded_scrutinee = try self.applyValueDemand(scrutinee, scrutinee_demand);
        if (try self.simplifyKnownMatchValueMode(ty, demanded_scrutinee, match.branches, .speculative, true)) |value| return value;
        if (demanded_scrutinee == .if_) return try self.cloneMatchIfValue(ty, demanded_scrutinee.if_, match);
        if (demanded_scrutinee == .match_) return try self.cloneMatchMatchValue(ty, demanded_scrutinee.match_, match);

        const scrutinee_expr = try self.materialize(demanded_scrutinee);
        if (try self.cloneCaseOfCaseValue(ty, scrutinee_expr, match.branches)) |value| return value;
        const scrutinee_known_value = try self.pass.knownValueFromValue(demanded_scrutinee);
        return try self.cloneMatchJoinedValue(ty, scrutinee_expr, match, scrutinee_known_value, demanded_scrutinee);
    }

    fn cloneMatchScrutineeBranchValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        scrutinee: Value,
        match: @import("../monotype/ast.zig").MatchExpr,
        demand: ValueDemand,
    ) Common.LowerError!?Value {
        const scrutinee_demand = try self.matchScrutineeDemand(match.branches, demand);
        const demanded_scrutinee = try self.applyValueDemand(scrutinee, scrutinee_demand);
        if (try self.simplifyKnownMatchValueWithDemandMode(ty, demanded_scrutinee, match.branches, demand, .speculative)) |value| return value;
        if (demanded_scrutinee == .if_) return try self.cloneMatchIfValueWithDemand(ty, demanded_scrutinee.if_, match, demand);
        if (demanded_scrutinee == .match_) return try self.cloneMatchMatchValueWithDemand(ty, demanded_scrutinee.match_, match, demand);

        if (demanded_scrutinee == .private_state and !privateStateCanMaterializePublic(self.pass.program, demanded_scrutinee.private_state)) return null;
        const scrutinee_expr = try self.materialize(demanded_scrutinee);
        const scrutinee_known_value = try self.pass.knownValueFromValue(demanded_scrutinee);
        return try self.cloneMatchJoinedValueWithDemand(ty, scrutinee_expr, match, scrutinee_known_value, demanded_scrutinee, demand);
    }

    fn matchBranchSourceThroughMatch(
        self: *Cloner,
        maybe_source: ?MatchValueBranchSource,
        ty: Type.TypeId,
        branches: Ast.Span(Ast.Branch),
        comptime_site: ?Ast.ComptimeSiteId,
    ) Common.LowerError!?MatchValueBranchSource {
        const source = maybe_source orelse return null;
        if (source.read != .none) return null;
        return MatchValueBranchSource{
            .scrutinee = source.scrutinee,
            .pat = source.pat,
            .guard = source.guard,
            .body = try self.addExpr(.{ .ty = ty, .data = .{ .match_ = .{
                .scrutinee = source.body,
                .branches = branches,
                .comptime_site = comptime_site,
            } } }),
            .scrutinee_known_value = source.scrutinee_known_value,
            .scrutinee_value = source.scrutinee_value,
            .bindings = source.bindings,
        };
    }

    fn cloneMatch(self: *Cloner, ty: Type.TypeId, match: @import("../monotype/ast.zig").MatchExpr) Common.LowerError!Ast.ExprId {
        const scrutinee = try self.cloneMatchScrutineeValue(match, .materialize);
        if (try self.simplifyKnownMatch(ty, scrutinee, match.branches)) |body| return body;

        const scrutinee_expr = try self.materialize(scrutinee);
        const scrutinee_known_value = try self.pass.knownValueFromValue(scrutinee);
        return try self.addExpr(.{ .ty = ty, .data = .{ .match_ = .{
            .scrutinee = scrutinee_expr,
            .branches = try self.cloneBranchSpanWithScrutineeKnownValue(match.branches, scrutinee_known_value),
            .comptime_site = match.comptime_site,
        } } });
    }

    fn cloneMatchValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        match: @import("../monotype/ast.zig").MatchExpr,
        demand: ValueDemand,
    ) Common.LowerError!Value {
        const scrutinee = try self.cloneMatchScrutineeValue(match, demand);
        if (try self.simplifyKnownMatchValueWithDemand(ty, scrutinee, match.branches, demand)) |value| return value;
        if (scrutinee == .if_) {
            if (try self.cloneMatchIfValueWithDemand(ty, scrutinee.if_, match, demand)) |value| return value;
        }
        if (scrutinee == .match_) {
            if (try self.cloneMatchMatchValueWithDemand(ty, scrutinee.match_, match, demand)) |value| return value;
        }

        const public_scrutinee = try self.cloneExprValueWithDemand(match.scrutinee, .materialize);
        const scrutinee_expr = try self.materialize(public_scrutinee);
        const scrutinee_known_value = try self.pass.knownValueFromValue(public_scrutinee);
        return try self.cloneMatchJoinedValueWithDemand(ty, scrutinee_expr, match, scrutinee_known_value, public_scrutinee, demand);
    }

    fn cloneMatchScrutineeValue(self: *Cloner, match: @import("../monotype/ast.zig").MatchExpr, result_demand: ValueDemand) Common.LowerError!Value {
        const demand = try self.matchScrutineeDemand(match.branches, result_demand);
        if (demand == .none) return try self.cloneExprValueDemandingKnownValue(match.scrutinee);
        return try self.cloneExprValueWithDemand(match.scrutinee, demand);
    }

    fn matchScrutineeDemand(self: *Cloner, branches_span: Ast.Span(Ast.Branch), result_demand: ValueDemand) Allocator.Error!ValueDemand {
        var demand: ValueDemand = .none;
        for (self.pass.program.branchSpan(branches_span)) |branch| {
            var branch_demand = try self.patternDemandInExpr(branch.pat, branch.body, result_demand);
            if (branch.guard) |guard| {
                branch_demand = try self.pass.mergeValueDemand(branch_demand, try self.patternDemandInExpr(branch.pat, guard, .materialize));
            }
            demand = try self.pass.mergeValueDemand(demand, branch_demand);
        }
        return demand;
    }

    fn patternDemandInExpr(self: *Cloner, pat_id: Ast.PatId, expr_id: Ast.ExprId, context: ValueDemand) Allocator.Error!ValueDemand {
        const pat = self.pass.program.pats.items[@intFromEnum(pat_id)];
        return switch (pat.data) {
            .bind => |local| blk: {
                const demand = try self.localDemandInExpr(local, expr_id, context);
                if (demand != .none) break :blk demand;
                break :blk if (localUseCountInExpr(self.pass.program, local, expr_id) == 0) .none else .materialize;
            },
            .wildcard => .none,
            .as => |as| try self.pass.mergeValueDemand(
                try self.patternDemandInExpr(as.pattern, expr_id, context),
                try self.localDemandInExpr(as.local, expr_id, context),
            ),
            .record => |fields_span| blk: {
                const fields = self.pass.program.recordDestructSpan(fields_span);
                var demands = std.ArrayList(FieldDemand).empty;
                defer demands.deinit(self.pass.allocator);
                for (fields) |field| {
                    const field_demand = try self.patternDemandInExpr(field.pattern, expr_id, context);
                    if (field_demand == .none) continue;
                    try demands.append(self.pass.allocator, .{
                        .name = field.name,
                        .demand = try self.pass.storedDemand(field_demand),
                    });
                }
                if (demands.items.len == 0) break :blk .none;
                break :blk ValueDemand{ .record = try self.pass.arena.allocator().dupe(FieldDemand, demands.items) };
            },
            .tuple => |items_span| blk: {
                const pats = self.pass.program.patSpan(items_span);
                var demands = std.ArrayList(ItemDemand).empty;
                defer demands.deinit(self.pass.allocator);
                for (pats, 0..) |child_pat, index| {
                    const item_demand = try self.patternDemandInExpr(child_pat, expr_id, context);
                    if (item_demand == .none) continue;
                    try demands.append(self.pass.allocator, .{
                        .index = @intCast(index),
                        .demand = try self.pass.storedDemand(item_demand),
                    });
                }
                if (demands.items.len == 0) break :blk .none;
                break :blk ValueDemand{ .tuple = try self.pass.arena.allocator().dupe(ItemDemand, demands.items) };
            },
            .tag => |tag_pat| blk: {
                const pats = self.pass.program.patSpan(tag_pat.payloads);
                var demands = std.ArrayList(ItemDemand).empty;
                defer demands.deinit(self.pass.allocator);
                for (pats, 0..) |child_pat, index| {
                    const payload_demand = try self.patternDemandInExpr(child_pat, expr_id, context);
                    if (payload_demand == .none) continue;
                    try demands.append(self.pass.allocator, .{
                        .index = @intCast(index),
                        .demand = try self.pass.storedDemand(payload_demand),
                    });
                }
                break :blk ValueDemand{ .tag = .{
                    .payloads = try self.pass.arena.allocator().dupe(ItemDemand, demands.items),
                } };
            },
            .nominal => |backing_pat| blk: {
                const backing_demand = try self.patternDemandInExpr(backing_pat, expr_id, context);
                if (backing_demand == .none) break :blk .none;
                break :blk ValueDemand{ .nominal = try self.pass.storedDemand(backing_demand) };
            },
            .list,
            .int_lit,
            .dec_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .str_lit,
            .str_pattern,
            => .materialize,
        };
    }

    fn localDemandInExpr(self: *Cloner, local: Ast.LocalId, expr_id: Ast.ExprId, context: ValueDemand) Allocator.Error!ValueDemand {
        var demand: ValueDemand = .none;
        try self.mergeLocalDemandInExpr(local, expr_id, context, &demand);
        return demand;
    }

    fn resolveLoopDemandRef(self: *Cloner, demand: ValueDemand) ValueDemand {
        return switch (demand) {
            .loop_param => |index| blk: {
                if (self.loop_stack.getLastOrNull()) |loop| {
                    if (index >= loop.demands.len) Common.invariant("loop demand reference index exceeded active loop arity");
                    break :blk loop.demands[index];
                }
                if (self.state_loop_stack.getLastOrNull()) |state_loop| {
                    if (index >= state_loop.demands.len) Common.invariant("state loop demand reference index exceeded active loop arity");
                    break :blk state_loop.demands[index];
                }
                Common.invariant("loop demand reference escaped active loop demand solving");
            },
            else => demand,
        };
    }

    fn mergeValueDemand(self: *Cloner, existing: ValueDemand, incoming: ValueDemand) Allocator.Error!ValueDemand {
        if (existing == .materialize or incoming == .materialize) return .materialize;
        if (existing == .none) return incoming;
        if (incoming == .none) return existing;

        if (existing == .loop_param and incoming == .loop_param) {
            return if (existing.loop_param == incoming.loop_param) existing else .materialize;
        }

        if (existing == .loop_param) {
            const loop = self.loop_stack.getLastOrNull() orelse return try self.pass.mergeValueDemand(existing, incoming);
            if (existing.loop_param >= loop.demands.len) Common.invariant("loop demand reference index exceeded active loop arity");
            const merged = try self.mergeActiveLoopParamDemand(loop, existing.loop_param, loop.demands[existing.loop_param], incoming);
            loop.demands[existing.loop_param] = merged;
            return existing;
        }

        if (incoming == .loop_param) {
            const loop = self.loop_stack.getLastOrNull() orelse return try self.pass.mergeValueDemand(existing, incoming);
            if (incoming.loop_param >= loop.demands.len) Common.invariant("loop demand reference index exceeded active loop arity");
            const merged = try self.mergeActiveLoopParamDemand(loop, incoming.loop_param, loop.demands[incoming.loop_param], existing);
            loop.demands[incoming.loop_param] = merged;
            return incoming;
        }

        return try self.pass.mergeValueDemand(existing, incoming);
    }

    fn mergeLocalDemand(self: *Cloner, out: *ValueDemand, incoming: ValueDemand) Allocator.Error!void {
        out.* = try self.mergeValueDemand(out.*, incoming);
    }

    fn demandAtPath(self: *Cloner, path: []const DemandPathStep, demand: ValueDemand) Allocator.Error!ValueDemand {
        if (demand == .none) return .none;

        var current = demand;
        var index = path.len;
        while (index > 0) {
            index -= 1;
            current = switch (path[index]) {
                .record_field => |field| try self.pass.demandRecordField(field, current),
                .tuple_item => |item_index| try self.pass.demandTupleItem(item_index, current),
                .tag_payload => |payload_index| blk: {
                    const payloads = try self.pass.arena.allocator().alloc(ItemDemand, 1);
                    payloads[0] = .{
                        .index = payload_index,
                        .demand = try self.pass.storedDemand(current),
                    };
                    break :blk ValueDemand{ .tag = .{ .payloads = payloads } };
                },
                .nominal_backing => ValueDemand{ .nominal = try self.pass.storedDemand(current) },
                .callable_capture => |capture_index| blk: {
                    const captures = try self.pass.arena.allocator().alloc(ValueDemand, @as(usize, capture_index) + 1);
                    @memset(captures, .none);
                    captures[@intCast(capture_index)] = current;
                    break :blk ValueDemand{ .callable = .{ .captures = captures } };
                },
            };
        }
        return current;
    }

    fn demandForSplitLocal(self: *Cloner, source_local: Ast.LocalId, expr_local: Ast.LocalId, context: ValueDemand) Allocator.Error!ValueDemand {
        const loop = self.loop_stack.getLastOrNull() orelse return .none;
        var demand: ValueDemand = .none;
        for (loop.provenance.items) |split_local| {
            if (split_local.local != expr_local or split_local.source_local != source_local) continue;
            demand = try self.pass.mergeValueDemand(demand, try self.demandAtPath(split_local.path, context));
        }
        return demand;
    }

    fn loopProvenanceLen(self: *Cloner) ?usize {
        const loop = self.loop_stack.getLastOrNull() orelse return null;
        return loop.provenance.items.len;
    }

    fn restoreLoopProvenance(self: *Cloner, mark: ?usize) void {
        const len = mark orelse return;
        const loop = self.loop_stack.getLastOrNull() orelse return;
        loop.provenance.shrinkRetainingCapacity(len);
    }

    fn appendDemandPath(path: *std.ArrayList(DemandPathStep), allocator: Allocator, steps: []const DemandPathStep) Allocator.Error!void {
        try path.appendSlice(allocator, steps);
    }

    fn loopDemandPathForExpr(
        self: *Cloner,
        source_local: Ast.LocalId,
        expr_id: Ast.ExprId,
        path: *std.ArrayList(DemandPathStep),
    ) Allocator.Error!bool {
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        switch (expr.data) {
            .local => |expr_local| {
                if (expr_local == source_local) return true;
                const loop = self.loop_stack.getLastOrNull() orelse return false;
                for (loop.provenance.items) |provenance| {
                    if (provenance.local != expr_local or provenance.source_local != source_local) continue;
                    try appendDemandPath(path, self.pass.allocator, provenance.path);
                    return true;
                }
                return false;
            },
            .field_access => |field| {
                if (!try self.loopDemandPathForExpr(source_local, field.receiver, path)) return false;
                try path.append(self.pass.allocator, .{ .record_field = field.field });
                return true;
            },
            .tuple_access => |access| {
                if (!try self.loopDemandPathForExpr(source_local, access.tuple, path)) return false;
                try path.append(self.pass.allocator, .{ .tuple_item = access.elem_index });
                return true;
            },
            .comptime_branch_taken => |taken| return try self.loopDemandPathForExpr(source_local, taken.body, path),
            else => return false,
        }
    }

    fn appendLoopAliasForExpr(self: *Cloner, alias_local: Ast.LocalId, expr_id: Ast.ExprId) Allocator.Error!void {
        const loop = self.loop_stack.getLastOrNull() orelse return;
        for (loop.params) |param| {
            var path = std.ArrayList(DemandPathStep).empty;
            defer path.deinit(self.pass.allocator);
            if (!try self.loopDemandPathForExpr(param.local, expr_id, &path)) continue;
            try self.appendLoopSplitLocal(loop.provenance, alias_local, param.local, path.items);
        }
    }

    fn valueIsExpr(value: Value, expr_id: Ast.ExprId) bool {
        return switch (value) {
            .expr => |value_expr| value_expr == expr_id,
            .expr_with_known_value => |known_value_expr| known_value_expr.expr == expr_id,
            else => false,
        };
    }

    fn mergeLocalDemandInPrivateStateValue(
        self: *Cloner,
        local: Ast.LocalId,
        value: PrivateStateValue,
        context: ValueDemand,
        out: *ValueDemand,
    ) Allocator.Error!void {
        var path = std.ArrayList(DemandPathStep).empty;
        defer path.deinit(self.pass.allocator);
        return self.mergeLocalDemandInPrivateStateValueAtPath(local, null, value, context, &path, out);
    }

    fn mergeMissingPrivateStateDemand(
        self: *Cloner,
        local: Ast.LocalId,
        subst_local: ?Ast.LocalId,
        path: []const DemandPathStep,
        demand: ValueDemand,
        out: *ValueDemand,
    ) Allocator.Error!void {
        const source = subst_local orelse return;
        try self.mergeLocalDemand(out, try self.demandForSplitLocal(local, source, try self.demandAtPath(path, demand)));
    }

    fn mergeLocalDemandInPrivateStateValueAtPath(
        self: *Cloner,
        local: Ast.LocalId,
        subst_local: ?Ast.LocalId,
        value: PrivateStateValue,
        context: ValueDemand,
        path: *std.ArrayList(DemandPathStep),
        out: *ValueDemand,
    ) Allocator.Error!void {
        switch (value) {
            .leaf => |leaf| try self.mergeLocalDemandInExpr(local, leaf.expr, context, out),
            .record => |record| {
                switch (context) {
                    .record => |field_demands| {
                        for (field_demands) |field_demand| {
                            try path.append(self.pass.allocator, .{ .record_field = field_demand.name });
                            defer _ = path.pop();
                            const field_value = privateStateFieldByName(record.fields, field_demand.name) orelse {
                                try self.mergeMissingPrivateStateDemand(local, subst_local, path.items, field_demand.demand.*, out);
                                continue;
                            };
                            try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, field_value, field_demand.demand.*, path, out);
                        }
                    },
                    .none => {},
                    else => for (record.fields) |field| {
                        try path.append(self.pass.allocator, .{ .record_field = field.name });
                        defer _ = path.pop();
                        try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, field.value, .materialize, path, out);
                    },
                }
            },
            .tuple => |tuple| {
                switch (context) {
                    .tuple => |item_demands| {
                        for (item_demands) |item_demand| {
                            try path.append(self.pass.allocator, .{ .tuple_item = item_demand.index });
                            defer _ = path.pop();
                            const item_value = privateStateIndexedValueByIndex(tuple.items, item_demand.index) orelse {
                                try self.mergeMissingPrivateStateDemand(local, subst_local, path.items, item_demand.demand.*, out);
                                continue;
                            };
                            try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, item_value, item_demand.demand.*, path, out);
                        }
                    },
                    .none => {},
                    else => for (tuple.items) |item| {
                        try path.append(self.pass.allocator, .{ .tuple_item = item.index });
                        defer _ = path.pop();
                        try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, item.value, .materialize, path, out);
                    },
                }
            },
            .tag => |tag| {
                switch (context) {
                    .tag => |tag_demand| {
                        for (tag_demand.payloads) |payload_demand| {
                            try path.append(self.pass.allocator, .{ .tag_payload = payload_demand.index });
                            defer _ = path.pop();
                            const payload = privateStateIndexedValueByIndex(tag.payloads, payload_demand.index) orelse {
                                try self.mergeMissingPrivateStateDemand(local, subst_local, path.items, payload_demand.demand.*, out);
                                continue;
                            };
                            try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, payload, payload_demand.demand.*, path, out);
                        }
                    },
                    .none => {},
                    else => for (tag.payloads) |payload| {
                        try path.append(self.pass.allocator, .{ .tag_payload = payload.index });
                        defer _ = path.pop();
                        try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, payload.value, .materialize, path, out);
                    },
                }
            },
            .nominal => |nominal| {
                const backing_context = switch (context) {
                    .nominal => |nominal_demand| nominal_demand.*,
                    else => context,
                };
                try path.append(self.pass.allocator, .nominal_backing);
                defer _ = path.pop();
                const backing = nominal.backing orelse {
                    try self.mergeMissingPrivateStateDemand(local, subst_local, path.items, backing_context, out);
                    return;
                };
                try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, backing.*, backing_context, path, out);
            },
            .callable => |callable| {
                switch (context) {
                    .callable => |callable_demand| {
                        var effective_context = ValueDemand{ .callable = callable_demand };
                        if (callable_demand.result) |result_demand| {
                            const derived = try self.callableDemandForPrivateStateCallableWithResultDemand(callable, result_demand.*);
                            effective_context = try self.pass.mergeValueDemand(effective_context, derived);
                        }
                        for (effective_context.callable.captures, 0..) |capture_demand, index| {
                            if (capture_demand == .none) continue;
                            try path.append(self.pass.allocator, .{ .callable_capture = @intCast(index) });
                            defer _ = path.pop();
                            const capture = privateStateIndexedValueByIndex(callable.captures, @intCast(index)) orelse {
                                try self.mergeMissingPrivateStateDemand(local, subst_local, path.items, capture_demand, out);
                                continue;
                            };
                            try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, capture, capture_demand, path, out);
                        }
                    },
                    .none => {},
                    else => for (callable.captures) |capture| {
                        try path.append(self.pass.allocator, .{ .callable_capture = capture.index });
                        defer _ = path.pop();
                        try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, capture.value, .materialize, path, out);
                    },
                }
            },
            .finite_tags => |finite_tags| {
                try self.mergeLocalDemandInExpr(local, finite_tags.selector, .materialize, out);
                switch (context) {
                    .tag => |tag_demand| {
                        for (finite_tags.alternatives) |alternative| {
                            for (tag_demand.payloads) |payload_demand| {
                                try path.append(self.pass.allocator, .{ .tag_payload = payload_demand.index });
                                defer _ = path.pop();
                                const payload = privateStateIndexedValueByIndex(alternative.payloads, payload_demand.index) orelse {
                                    try self.mergeMissingPrivateStateDemand(local, subst_local, path.items, payload_demand.demand.*, out);
                                    continue;
                                };
                                try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, payload, payload_demand.demand.*, path, out);
                            }
                        }
                    },
                    .none => {},
                    else => for (finite_tags.alternatives) |alternative| {
                        for (alternative.payloads) |payload| {
                            try path.append(self.pass.allocator, .{ .tag_payload = payload.index });
                            defer _ = path.pop();
                            try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, payload.value, .materialize, path, out);
                        }
                    },
                }
            },
            .finite_callables => |finite_callables| {
                try self.mergeLocalDemandInExpr(local, finite_callables.selector, .materialize, out);
                switch (context) {
                    .callable => |callable_demand| {
                        for (finite_callables.alternatives) |alternative| {
                            var effective_context = ValueDemand{ .callable = callable_demand };
                            if (callable_demand.result) |result_demand| {
                                const derived = try self.callableDemandForPrivateStateCallableWithResultDemand(alternative, result_demand.*);
                                effective_context = try self.pass.mergeValueDemand(effective_context, derived);
                            }
                            for (effective_context.callable.captures, 0..) |capture_demand, index| {
                                if (capture_demand == .none) continue;
                                try path.append(self.pass.allocator, .{ .callable_capture = @intCast(index) });
                                defer _ = path.pop();
                                const capture = privateStateIndexedValueByIndex(alternative.captures, @intCast(index)) orelse {
                                    try self.mergeMissingPrivateStateDemand(local, subst_local, path.items, capture_demand, out);
                                    continue;
                                };
                                try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, capture, capture_demand, path, out);
                            }
                        }
                    },
                    .none => {},
                    else => for (finite_callables.alternatives) |alternative| {
                        for (alternative.captures) |capture| {
                            try path.append(self.pass.allocator, .{ .callable_capture = capture.index });
                            defer _ = path.pop();
                            try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, capture.value, .materialize, path, out);
                        }
                    },
                }
            },
        }
    }

    fn mergeLocalDemandInSubstValue(
        self: *Cloner,
        local: Ast.LocalId,
        subst_local: Ast.LocalId,
        value: Value,
        context: ValueDemand,
        out: *ValueDemand,
    ) Allocator.Error!void {
        switch (value) {
            .private_state => |private_state| {
                var path = std.ArrayList(DemandPathStep).empty;
                defer path.deinit(self.pass.allocator);
                try self.mergeLocalDemandInPrivateStateValueAtPath(local, subst_local, private_state, context, &path, out);
            },
            else => try self.mergeLocalDemandInValue(local, value, context, out),
        }
    }

    fn mergeLocalDemandInPendingLetValue(
        self: *Cloner,
        local: Ast.LocalId,
        value: PendingLetValue,
        context: ValueDemand,
        out: *ValueDemand,
    ) Allocator.Error!void {
        const expr = switch (value) {
            .source => |expr| expr,
            .cloned => |expr| expr,
        };
        try self.mergeLocalDemandInExpr(local, expr, context, out);
    }

    fn mergeLocalDemandInValue(
        self: *Cloner,
        local: Ast.LocalId,
        value: Value,
        context: ValueDemand,
        out: *ValueDemand,
    ) Allocator.Error!void {
        switch (value) {
            .expr => |expr_id| try self.mergeLocalDemandInExpr(local, expr_id, context, out),
            .expr_with_known_value => |known_value_expr| {
                if (known_value_expr.value) |structured_value| {
                    try self.mergeLocalDemandInValue(local, structured_value.*, context, out);
                } else {
                    try self.mergeLocalDemandInExpr(local, known_value_expr.expr, context, out);
                }
            },
            .let_ => |let_value| {
                for (let_value.lets) |pending| try self.mergeLocalDemandInPendingLetValue(local, pending.value, .materialize, out);
                try self.mergeLocalDemandInValue(local, let_value.body.*, context, out);
            },
            .if_ => |if_value| {
                for (if_value.branches) |branch| {
                    try self.mergeLocalDemandInExpr(local, branch.cond, .materialize, out);
                    try self.mergeLocalDemandInValue(local, branch.body, context, out);
                }
                try self.mergeLocalDemandInValue(local, if_value.final_else.*, context, out);
            },
            .match_ => |match_value| {
                try self.mergeLocalDemandInExpr(local, match_value.scrutinee, .materialize, out);
                for (match_value.branches) |branch| {
                    if (branch.guard) |guard| try self.mergeLocalDemandInExpr(local, guard, .materialize, out);
                    try self.mergeLocalDemandInValue(local, branch.body, context, out);
                }
            },
            .tag => |tag| {
                switch (context) {
                    .tag => |tag_demand| {
                        for (tag_demand.payloads) |payload_demand| {
                            if (payload_demand.index >= tag.payloads.len) continue;
                            try self.mergeLocalDemandInValue(local, tag.payloads[payload_demand.index], payload_demand.demand.*, out);
                        }
                    },
                    .none => {},
                    else => for (tag.payloads) |payload| try self.mergeLocalDemandInValue(local, payload, .materialize, out),
                }
            },
            .record => |record| {
                switch (context) {
                    .record => |field_demands| {
                        for (field_demands) |field_demand| {
                            const field_value = fieldValueByName(record.fields, field_demand.name) orelse continue;
                            try self.mergeLocalDemandInValue(local, field_value, field_demand.demand.*, out);
                        }
                    },
                    .none => {},
                    else => for (record.fields) |field| try self.mergeLocalDemandInValue(local, field.value, .materialize, out),
                }
            },
            .tuple => |tuple| {
                switch (context) {
                    .tuple => |item_demands| {
                        for (item_demands) |item_demand| {
                            if (item_demand.index >= tuple.items.len) continue;
                            try self.mergeLocalDemandInValue(local, tuple.items[item_demand.index], item_demand.demand.*, out);
                        }
                    },
                    .none => {},
                    else => for (tuple.items) |item| try self.mergeLocalDemandInValue(local, item, .materialize, out),
                }
            },
            .nominal => |nominal| try self.mergeLocalDemandInValue(local, nominal.backing.*, switch (context) {
                .nominal => |nominal_demand| nominal_demand.*,
                else => context,
            }, out),
            .callable => |callable| {
                switch (context) {
                    .callable => |callable_demand| {
                        var effective_context = ValueDemand{ .callable = callable_demand };
                        if (callable_demand.result) |result_demand| {
                            const derived = try self.callableDemandForCallableValueWithResultDemand(callable, result_demand.*);
                            effective_context = try self.pass.mergeValueDemand(effective_context, derived);
                        }
                        if (effective_context != .callable) Common.invariant("callable demand merge produced non-callable demand");

                        for (effective_context.callable.captures, 0..) |capture_demand, index| {
                            if (index >= callable.captures.len) continue;
                            try self.mergeLocalDemandInValue(local, callable.captures[index], capture_demand, out);
                        }
                    },
                    .none => {},
                    else => for (callable.captures) |capture| try self.mergeLocalDemandInValue(local, capture, .materialize, out),
                }
            },
            .finite_tags => |finite_tags| {
                try self.mergeLocalDemandInExpr(local, finite_tags.selector, .materialize, out);
                switch (context) {
                    .tag => |tag_demand| {
                        for (finite_tags.alternatives) |alternative| {
                            for (tag_demand.payloads) |payload_demand| {
                                if (payload_demand.index >= alternative.payloads.len) continue;
                                try self.mergeLocalDemandInValue(local, alternative.payloads[payload_demand.index], payload_demand.demand.*, out);
                            }
                        }
                    },
                    .none => {},
                    else => for (finite_tags.alternatives) |alternative| {
                        for (alternative.payloads) |payload| try self.mergeLocalDemandInValue(local, payload, .materialize, out);
                    },
                }
            },
            .finite_callables => |finite_callables| {
                try self.mergeLocalDemandInExpr(local, finite_callables.selector, .materialize, out);
                switch (context) {
                    .callable => |callable_demand| {
                        for (finite_callables.alternatives) |alternative| {
                            var effective_context = ValueDemand{ .callable = callable_demand };
                            if (callable_demand.result) |result_demand| {
                                const derived = try self.callableDemandForFnWithResultDemand(
                                    alternative.fn_id,
                                    alternative.captures.len,
                                    result_demand.*,
                                );
                                effective_context = try self.pass.mergeValueDemand(effective_context, derived);
                            }
                            if (effective_context != .callable) Common.invariant("finite callable demand merge produced non-callable demand");

                            for (effective_context.callable.captures, 0..) |capture_demand, index| {
                                if (index >= alternative.captures.len) continue;
                                try self.mergeLocalDemandInValue(local, alternative.captures[index], capture_demand, out);
                            }
                        }
                    },
                    .none => {},
                    else => for (finite_callables.alternatives) |alternative| {
                        for (alternative.captures) |capture| try self.mergeLocalDemandInValue(local, capture, .materialize, out);
                    },
                }
            },
            .private_state => |private_state| try self.mergeLocalDemandInPrivateStateValue(local, private_state, context, out),
        }
    }

    fn mergeLocalDemandInExpr(
        self: *Cloner,
        local: Ast.LocalId,
        expr_id: Ast.ExprId,
        context: ValueDemand,
        out: *ValueDemand,
    ) Allocator.Error!void {
        if (context == .none) return;
        for (self.local_demand_stack.items) |frame| {
            if (frame.local == local and frame.expr == expr_id and valueDemandEql(frame.context, context)) return;
        }
        try self.local_demand_stack.append(self.pass.allocator, .{
            .local = local,
            .expr = expr_id,
            .context = context,
        });
        defer _ = self.local_demand_stack.pop();

        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        switch (expr.data) {
            .local => |expr_local| {
                if (expr_local == local) {
                    try self.mergeLocalDemand(out, context);
                    return;
                }
                if (self.subst.get(expr_local)) |value| {
                    if (!valueIsExpr(value, expr_id)) {
                        try self.mergeLocalDemandInSubstValue(local, expr_local, value, context, out);
                    }
                }
                try self.mergeLocalDemand(out, try self.demandForSplitLocal(local, expr_local, context));
            },
            .field_access => |field| {
                try self.mergeLocalDemandInExpr(
                    local,
                    field.receiver,
                    try self.pass.demandRecordField(field.field, context),
                    out,
                );
            },
            .tuple_access => |access| {
                try self.mergeLocalDemandInExpr(
                    local,
                    access.tuple,
                    try self.pass.demandTupleItem(access.elem_index, context),
                    out,
                );
            },
            .continue_ => |continue_| {
                for (self.pass.program.exprSpan(continue_.values), 0..) |value, index| {
                    try self.mergeLocalDemandInExpr(local, value, try self.continueValueDemand(index), out);
                }
            },
            .state_continue => |continue_| {
                for (self.pass.program.exprSpan(continue_.values), 0..) |value, index| {
                    try self.mergeLocalDemandInExpr(local, value, try self.continueValueDemand(index), out);
                }
            },
            .let_ => |let_| {
                const value_demand = try self.patternDemandInExpr(let_.bind, let_.rest, context);
                try self.mergeLocalDemandInExpr(local, let_.value, value_demand, out);
                try self.mergeLocalDemandInExpr(local, let_.rest, context, out);
            },
            .block => |block| {
                const statements = self.pass.program.stmtSpan(block.statements);
                for (statements, 0..) |stmt, index| {
                    try self.mergeLocalDemandInStmtTail(local, stmt, .{
                        .statements = statements[index + 1 ..],
                        .final_expr = block.final_expr,
                    }, context, out);
                }
                try self.mergeLocalDemandInExpr(local, block.final_expr, context, out);
            },
            .if_ => |if_| {
                for (self.pass.program.ifBranchSpan(if_.branches)) |branch| {
                    try self.mergeLocalDemandInExpr(local, branch.cond, .materialize, out);
                    try self.mergeLocalDemandInExpr(local, branch.body, context, out);
                }
                try self.mergeLocalDemandInExpr(local, if_.final_else, context, out);
            },
            .match_ => |match| {
                try self.mergeLocalDemandInExpr(local, match.scrutinee, try self.matchScrutineeDemand(match.branches, context), out);
                for (self.pass.program.branchSpan(match.branches)) |branch| {
                    if (branch.guard) |guard| try self.mergeLocalDemandInExpr(local, guard, .materialize, out);
                    try self.mergeLocalDemandInExpr(local, branch.body, context, out);
                }
            },
            .list,
            => |items| {
                for (self.pass.program.exprSpan(items)) |item| try self.mergeLocalDemandInExpr(local, item, .materialize, out);
            },
            .tuple => |items_span| {
                const items = self.pass.program.exprSpan(items_span);
                switch (context) {
                    .tuple => |item_demands| {
                        for (item_demands) |item_demand| {
                            if (item_demand.index >= items.len) continue;
                            try self.mergeLocalDemandInExpr(local, items[item_demand.index], item_demand.demand.*, out);
                        }
                    },
                    .none => {},
                    else => for (items) |item| try self.mergeLocalDemandInExpr(local, item, .materialize, out),
                }
            },
            .record => |fields| {
                const source_fields = self.pass.program.fieldExprSpan(fields);
                switch (context) {
                    .record => |field_demands| {
                        for (field_demands) |field_demand| {
                            for (source_fields) |field| {
                                if (field.name != field_demand.name) continue;
                                try self.mergeLocalDemandInExpr(local, field.value, field_demand.demand.*, out);
                                break;
                            }
                        }
                    },
                    .none => {},
                    else => for (source_fields) |field| try self.mergeLocalDemandInExpr(local, field.value, .materialize, out),
                }
            },
            .tag => |tag| {
                const payloads = self.pass.program.exprSpan(tag.payloads);
                switch (context) {
                    .tag => |tag_demand| {
                        for (tag_demand.payloads) |payload_demand| {
                            if (payload_demand.index >= payloads.len) continue;
                            try self.mergeLocalDemandInExpr(local, payloads[payload_demand.index], payload_demand.demand.*, out);
                        }
                    },
                    .none => {},
                    else => for (payloads) |payload| try self.mergeLocalDemandInExpr(local, payload, .materialize, out),
                }
            },
            .nominal,
            .return_,
            .dbg,
            .expect,
            => |child| try self.mergeLocalDemandInExpr(local, child, context, out),
            .break_ => |maybe_child| if (maybe_child) |child| try self.mergeLocalDemandInExpr(local, child, self.activeBreakResultDemand(context), out),
            .comptime_branch_taken => |taken| try self.mergeLocalDemandInExpr(local, taken.body, context, out),
            .call_value => |call| {
                const callee_demand = try self.callableDemandForCalleeExprWithResultDemand(call.callee, context);
                try self.mergeLocalDemandInExpr(local, call.callee, callee_demand, out);
                try self.mergeCallValueArgDemandsInExpr(local, call, context, out);
            },
            .call_proc => |call| {
                try self.mergeCallProcDemandsInExpr(local, call, context, out);
            },
            .low_level => |call| {
                for (self.pass.program.exprSpan(call.args)) |arg| try self.mergeLocalDemandInExpr(local, arg, .materialize, out);
            },
            .structural_eq => |eq| {
                try self.mergeLocalDemandInExpr(local, eq.lhs, .materialize, out);
                try self.mergeLocalDemandInExpr(local, eq.rhs, .materialize, out);
            },
            .structural_hash => |hash| {
                try self.mergeLocalDemandInExpr(local, hash.value, .materialize, out);
                try self.mergeLocalDemandInExpr(local, hash.hasher, .materialize, out);
            },
            .loop_ => |loop| {
                const loop_demands = try self.loopParamDemands(loop, context);
                defer self.pass.allocator.free(loop_demands);

                const initials = self.pass.program.exprSpan(loop.initial_values);
                if (initials.len != loop_demands.len) Common.invariant("loop initial value count differed from loop demand count");
                for (initials, loop_demands) |initial, demand| {
                    try self.mergeLocalDemandInExpr(local, initial, demand, out);
                }

                const params = self.pass.program.typedLocalSpan(loop.params);
                const loop_known_values = try self.pass.allocator.alloc(KnownValue, params.len);
                defer self.pass.allocator.free(loop_known_values);
                for (params, loop_known_values) |param, *known_value| {
                    known_value.* = .{ .any = param.ty };
                }

                const refinements = try self.pass.allocator.alloc(?KnownValue, params.len);
                defer self.pass.allocator.free(refinements);
                @memset(refinements, null);

                var provenance = std.ArrayList(LoopLocalProvenance).empty;
                defer provenance.deinit(self.pass.allocator);

                try self.loop_stack.append(self.pass.allocator, .{
                    .params = params,
                    .values = loop_known_values,
                    .refinements = refinements,
                    .demands = loop_demands,
                    .result_demand = context,
                    .provenance = &provenance,
                });
                defer _ = self.loop_stack.pop();

                try self.mergeLocalDemandInExpr(local, loop.body, context, out);
            },
            .state_loop => |state_loop| {
                for (self.pass.program.exprSpan(state_loop.entry_values)) |initial| try self.mergeLocalDemandInExpr(local, initial, .materialize, out);
                for (self.pass.program.stateLoopStateSpan(state_loop.states)) |state| {
                    try self.mergeLocalDemandInExpr(local, state.body, .materialize, out);
                }
            },
            .if_initialized_payload => |payload_switch| {
                try self.mergeLocalDemandInExpr(local, payload_switch.cond, .materialize, out);
                try self.mergeLocalDemandInExpr(local, payload_switch.initialized, context, out);
                try self.mergeLocalDemandInExpr(local, payload_switch.uninitialized, context, out);
            },
            .try_sequence => |sequence| {
                try self.mergeLocalDemandInExpr(local, sequence.try_expr, .materialize, out);
                try self.mergeLocalDemandInExpr(local, sequence.ok_body, context, out);
            },
            .try_record_sequence => |sequence| {
                try self.mergeLocalDemandInExpr(local, sequence.try_expr, .materialize, out);
                try self.mergeLocalDemandInExpr(local, sequence.ok_body, context, out);
            },
            .static_data_candidate => |candidate| try self.mergeLocalDemandInExpr(local, candidate.fallback, context, out),
            .expect_err => |expect_err| try self.mergeLocalDemandInExpr(local, expect_err.msg, .materialize, out),
            .fn_ref => |fn_id| {
                const source_fn = self.pass.program.fns.items[@intFromEnum(fn_id)];
                for (self.pass.program.typedLocalSpan(source_fn.captures), 0..) |capture, index| {
                    if (capture.local != local) continue;
                    const capture_demand = switch (context) {
                        .none => .none,
                        .callable => |callable| if (index < callable.captures.len)
                            callable.captures[index]
                        else
                            .none,
                        else => try self.functionLocalDemand(fn_id, capture.local, .materialize),
                    };
                    try self.mergeLocalDemand(out, capture_demand);
                }
            },
            .unit,
            .int_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .dec_lit,
            .str_lit,
            .static_data,
            .lambda,
            .def_ref,
            .fn_def,
            .crash,
            .comptime_exhaustiveness_failed,
            .uninitialized,
            .uninitialized_payload,
            => {},
        }
    }

    fn mergeLocalDemandInStmtTail(
        self: *Cloner,
        local: Ast.LocalId,
        stmt_id: Ast.StmtId,
        tail: BlockTail,
        context: ValueDemand,
        out: *ValueDemand,
    ) Allocator.Error!void {
        switch (self.pass.program.stmts.items[@intFromEnum(stmt_id)]) {
            .let_ => |let_| {
                const value_demand = if (let_.recursive)
                    .materialize
                else
                    try self.patternDemandInBlockTail(let_.pat, tail, context);
                try self.mergeLocalDemandInExpr(local, let_.value, value_demand, out);
            },
            .expr,
            => |expr| try self.mergeLocalDemandInExpr(local, expr, try self.stmtExprDemand(expr, context), out),
            .expect,
            .dbg,
            => |expr| try self.mergeLocalDemandInExpr(local, expr, .materialize, out),
            .return_ => |expr| try self.mergeLocalDemandInExpr(local, expr, context, out),
            .uninitialized,
            .crash,
            => {},
        }
    }

    fn stmtExprDemand(self: *Cloner, expr_id: Ast.ExprId, context: ValueDemand) Allocator.Error!ValueDemand {
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        return switch (expr.data) {
            .break_,
            .return_,
            => context,
            .comptime_branch_taken => |taken| try self.stmtExprDemand(taken.body, context),
            else => .materialize,
        };
    }

    fn patternDemandInBlockTail(
        self: *Cloner,
        pat_id: Ast.PatId,
        tail: BlockTail,
        context: ValueDemand,
    ) Allocator.Error!ValueDemand {
        const pat = self.pass.program.pats.items[@intFromEnum(pat_id)];
        return switch (pat.data) {
            .bind => |local| blk: {
                const demand = try self.localDemandInBlockTail(local, tail, context);
                if (demand != .none) break :blk demand;
                break :blk if (localUseCountInBlockTail(self.pass.program, local, tail) == 0) .none else .materialize;
            },
            .wildcard => .none,
            .as => |as| try self.pass.mergeValueDemand(
                try self.patternDemandInBlockTail(as.pattern, tail, context),
                try self.localDemandInBlockTail(as.local, tail, context),
            ),
            .record => |fields_span| blk: {
                const fields = self.pass.program.recordDestructSpan(fields_span);
                var demands = std.ArrayList(FieldDemand).empty;
                defer demands.deinit(self.pass.allocator);
                for (fields) |field| {
                    const field_demand = try self.patternDemandInBlockTail(field.pattern, tail, context);
                    if (field_demand == .none) continue;
                    try demands.append(self.pass.allocator, .{
                        .name = field.name,
                        .demand = try self.pass.storedDemand(field_demand),
                    });
                }
                if (demands.items.len == 0) break :blk .none;
                break :blk ValueDemand{ .record = try self.pass.arena.allocator().dupe(FieldDemand, demands.items) };
            },
            .tuple => |items_span| blk: {
                const pats = self.pass.program.patSpan(items_span);
                var demands = std.ArrayList(ItemDemand).empty;
                defer demands.deinit(self.pass.allocator);
                for (pats, 0..) |child_pat, index| {
                    const item_demand = try self.patternDemandInBlockTail(child_pat, tail, context);
                    if (item_demand == .none) continue;
                    try demands.append(self.pass.allocator, .{
                        .index = @intCast(index),
                        .demand = try self.pass.storedDemand(item_demand),
                    });
                }
                if (demands.items.len == 0) break :blk .none;
                break :blk ValueDemand{ .tuple = try self.pass.arena.allocator().dupe(ItemDemand, demands.items) };
            },
            .tag => |tag_pat| blk: {
                const pats = self.pass.program.patSpan(tag_pat.payloads);
                var demands = std.ArrayList(ItemDemand).empty;
                defer demands.deinit(self.pass.allocator);
                for (pats, 0..) |child_pat, index| {
                    const payload_demand = try self.patternDemandInBlockTail(child_pat, tail, context);
                    if (payload_demand == .none) continue;
                    try demands.append(self.pass.allocator, .{
                        .index = @intCast(index),
                        .demand = try self.pass.storedDemand(payload_demand),
                    });
                }
                break :blk ValueDemand{ .tag = .{
                    .payloads = try self.pass.arena.allocator().dupe(ItemDemand, demands.items),
                } };
            },
            .nominal => |backing_pat| blk: {
                const backing_demand = try self.patternDemandInBlockTail(backing_pat, tail, context);
                if (backing_demand == .none) break :blk .none;
                break :blk ValueDemand{ .nominal = try self.pass.storedDemand(backing_demand) };
            },
            .list,
            .int_lit,
            .dec_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .str_lit,
            .str_pattern,
            => .materialize,
        };
    }

    fn localDemandInBlockTail(
        self: *Cloner,
        local: Ast.LocalId,
        tail: BlockTail,
        context: ValueDemand,
    ) Allocator.Error!ValueDemand {
        var demand: ValueDemand = .none;
        for (tail.statements, 0..) |stmt, index| {
            try self.mergeLocalDemandInStmtTail(local, stmt, .{
                .statements = tail.statements[index + 1 ..],
                .final_expr = tail.final_expr,
            }, context, &demand);
        }
        try self.mergeLocalDemandInExpr(local, tail.final_expr, context, &demand);
        return demand;
    }

    fn mergeCallValueArgDemandsInExpr(
        self: *Cloner,
        local: Ast.LocalId,
        call: anytype,
        context: ValueDemand,
        out: *ValueDemand,
    ) Allocator.Error!void {
        const args = self.pass.program.exprSpan(call.args);
        const known_value = (try self.exprKnownValueNoInline(call.callee)) orelse {
            for (args) |arg| try self.mergeLocalDemandInExpr(local, arg, .materialize, out);
            return;
        };

        switch (known_value) {
            .callable => |callable| try self.mergeCallableArgDemandsInExpr(local, callable.fn_id, args, context, out),
            .finite_callables => |finite_callables| {
                for (finite_callables.alternatives) |alternative| {
                    try self.mergeCallableArgDemandsInExpr(local, alternative.fn_id, args, context, out);
                }
            },
            else => {
                for (args) |arg| try self.mergeLocalDemandInExpr(local, arg, .materialize, out);
            },
        }
    }

    fn mergeCallableArgDemandsInExpr(
        self: *Cloner,
        local: Ast.LocalId,
        fn_id: Ast.FnId,
        args: []const Ast.ExprId,
        context: ValueDemand,
        out: *ValueDemand,
    ) Allocator.Error!void {
        const source_fn = self.pass.program.fns.items[@intFromEnum(fn_id)];
        const source_args = self.pass.program.typedLocalSpan(source_fn.args);
        if (source_args.len != args.len) {
            for (args) |arg| try self.mergeLocalDemandInExpr(local, arg, .materialize, out);
            return;
        }
        for (source_args, args) |source_arg, arg| {
            try self.mergeLocalDemandInExpr(
                local,
                arg,
                try self.functionLocalDemand(fn_id, source_arg.local, context),
                out,
            );
        }
    }

    fn mergeCallProcDemandsInExpr(
        self: *Cloner,
        local: Ast.LocalId,
        call: anytype,
        context: ValueDemand,
        out: *ValueDemand,
    ) Allocator.Error!void {
        const args = self.pass.program.exprSpan(call.args);
        if (call.is_cold) {
            for (args) |arg| try self.mergeLocalDemandInExpr(local, arg, .materialize, out);
            return;
        }

        const callee = Ast.callProcCallee(call);
        const source_fn = self.pass.program.fns.items[@intFromEnum(callee)];
        const source_args = self.pass.program.typedLocalSpan(source_fn.args);
        if (source_args.len != args.len) Common.invariant("direct call arity differed from lifted function arity");

        if (!self.demandStackContains(callee)) {
            if (self.demandBody(callee)) |body| {
                const change_start = self.changes.items.len;
                const provenance_start = self.loopProvenanceLen();
                try self.demand_stack.append(self.pass.allocator, .{ .fn_id = callee });
                defer _ = self.demand_stack.pop();
                defer self.restoreLoopProvenance(provenance_start);
                defer self.restore(change_start);

                for (source_args, args) |source_arg, arg| {
                    try self.putSubst(source_arg.local, try self.exprValueForDemandNoInline(arg));
                    try self.appendLoopAliasForExpr(source_arg.local, arg);
                }

                try self.mergeLocalDemandInExpr(local, body, context, out);
                return;
            }
        }

        for (source_args, args) |source_arg, arg| {
            try self.mergeLocalDemandInExpr(
                local,
                arg,
                try self.functionLocalDemand(callee, source_arg.local, context),
                out,
            );
        }

        for (self.pass.program.typedLocalSpan(source_fn.captures)) |capture| {
            if (capture.local != local) continue;
            try self.mergeLocalDemand(out, try self.functionLocalDemand(callee, capture.local, context));
        }
    }

    fn loopParamDemands(self: *Cloner, loop: anytype, result_demand: ValueDemand) Allocator.Error![]ValueDemand {
        const params = self.pass.program.typedLocalSpan(loop.params);
        const initials = self.pass.program.exprSpan(loop.initial_values);
        if (params.len != initials.len) Common.invariant("loop parameter count differed from initial value count while computing demand");

        const demands = try self.pass.allocator.alloc(ValueDemand, params.len);
        @memset(demands, .none);

        const known_values = try self.pass.allocator.alloc(KnownValue, params.len);
        defer self.pass.allocator.free(known_values);
        for (params, known_values) |param, *known_value| {
            known_value.* = .{ .any = param.ty };
        }

        const refinements = try self.pass.allocator.alloc(?KnownValue, params.len);
        defer self.pass.allocator.free(refinements);
        @memset(refinements, null);

        while (true) {
            var changed = false;

            var provenance = std.ArrayList(LoopLocalProvenance).empty;
            defer provenance.deinit(self.pass.allocator);

            try self.loop_stack.append(self.pass.allocator, .{
                .params = params,
                .values = known_values,
                .refinements = refinements,
                .demands = demands,
                .result_demand = result_demand,
                .provenance = &provenance,
            });
            for (params, 0..) |param, index| {
                const observed = try self.localDemandInExpr(param.local, loop.body, result_demand);
                const merged = try self.mergeLoopParamDemand(known_values[index], demands[index], observed);
                if (!valueDemandEql(demands[index], merged)) {
                    demands[index] = merged;
                    changed = true;
                }
            }
            _ = self.loop_stack.pop();

            if (!changed) return demands;
        }
    }

    fn continueValueDemand(self: *Cloner, index: usize) Allocator.Error!ValueDemand {
        if (self.loop_stack.getLastOrNull()) |loop| {
            if (index >= loop.demands.len) return .materialize;
            return .{ .loop_param = index };
        }
        if (self.state_loop_stack.getLastOrNull()) |state_loop| {
            if (state_loop.states.items.len == 0 or index >= state_loop.states.items[0].values.len) return .materialize;
            const demands = try self.stateLoopValueDemands(state_loop, state_loop.states.items[0].values.len);
            defer self.pass.allocator.free(demands);
            return demands[index];
        }
        return .materialize;
    }

    fn simplifyKnownMatch(self: *Cloner, ty: Type.TypeId, scrutinee: Value, branches_span: Ast.Span(Ast.Branch)) Common.LowerError!?Ast.ExprId {
        if (try self.simplifyKnownMatchValueWithKnownValuePreservation(ty, scrutinee, branches_span, false)) |value| {
            return try self.materialize(value);
        }
        return null;
    }

    fn simplifyKnownMatchValue(self: *Cloner, ty: Type.TypeId, scrutinee: Value, branches_span: Ast.Span(Ast.Branch)) Common.LowerError!?Value {
        return try self.simplifyKnownMatchValueWithKnownValuePreservation(ty, scrutinee, branches_span, true);
    }

    fn simplifyKnownMatchValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        scrutinee: Value,
        branches_span: Ast.Span(Ast.Branch),
        demand: ValueDemand,
    ) Common.LowerError!?Value {
        return try self.simplifyKnownMatchValueWithDemandMode(ty, scrutinee, branches_span, demand, .strict);
    }

    fn simplifyKnownMatchValueWithDemandMode(
        self: *Cloner,
        ty: Type.TypeId,
        scrutinee: Value,
        branches_span: Ast.Span(Ast.Branch),
        demand: ValueDemand,
        mode: KnownMatchMode,
    ) Common.LowerError!?Value {
        switch (scrutinee) {
            .expr,
            .expr_with_known_value,
            .match_,
            => return null,
            .let_ => |let_value| {
                const change_start = self.changes.items.len;
                defer self.restore(change_start);
                try self.bindPendingLetKnownValues(let_value.lets);
                const body = (try self.simplifyKnownMatchValueWithDemandMode(ty, let_value.body.*, branches_span, demand, mode)) orelse return null;
                return try self.wrapPendingLets(body, let_value.lets, demand != .none);
            },
            .if_ => |if_value| return try self.simplifyKnownMatchIfValueWithDemand(ty, if_value, branches_span, demand),
            .finite_tags => |finite_tags| return try self.simplifyKnownMatchFiniteTagsValueWithDemand(ty, finite_tags, branches_span, demand),
            .private_state => |private_state| {
                if (privateStateLeafExpr(private_state) != null) return null;
                if (privateStateFiniteTags(private_state)) |finite_tags| {
                    return try self.simplifyKnownMatchPrivateFiniteTagsValueWithDemand(ty, finite_tags, branches_span, demand);
                }
            },
            else => {},
        }

        for (self.pass.program.branchSpan(branches_span)) |branch| {
            const demand_context: ValueDemand = if (demand == .none) .materialize else demand;
            var pending_lets = std.ArrayList(PendingLet).empty;
            defer pending_lets.deinit(self.pass.allocator);

            const change_start = self.changes.items.len;
            const unsafe_count = self.unsafeLeafCount(scrutinee);
            if (try self.bindPatToMatchValue(branch.pat, scrutinee, branch.body, demand_context, unsafe_count, &pending_lets) == null) {
                self.restore(change_start);
                continue;
            }
            if (branch.guard != null) {
                self.restore(change_start);
                return null;
            }
            const body = try self.cloneExprValueWithDemand(branch.body, demand);
            self.restore(change_start);
            return try self.wrapPendingLets(body, pending_lets.items, demand != .none);
        }

        if (scrutinee == .private_state and !privateStateCanMaterializePublic(self.pass.program, scrutinee.private_state)) {
            return null;
        }
        switch (mode) {
            .strict => Common.invariant("known constructor match had no matching branch"),
            .speculative => return null,
        }
    }

    fn simplifyKnownMatchIfValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        if_value: IfValue,
        branches_span: Ast.Span(Ast.Branch),
        demand: ValueDemand,
    ) Common.LowerError!?Value {
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
        for (if_value.branches, 0..) |branch, index| {
            const simplified = try self.simplifyKnownMatchValueWithDemandMode(ty, branch.body, branches_span, demand, .speculative);
            branches[index] = .{
                .cond = branch.cond,
                .body = simplified orelse return null,
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        const simplified_final_else = try self.simplifyKnownMatchValueWithDemandMode(ty, if_value.final_else.*, branches_span, demand, .speculative);
        final_else.* = simplified_final_else orelse return null;

        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn simplifyKnownMatchFiniteTagsValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        finite_tags: FiniteTagsValue,
        branches_span: Ast.Span(Ast.Branch),
        demand: ValueDemand,
    ) Common.LowerError!?Value {
        if (finite_tags.alternatives.len == 0) {
            Common.invariant("finite tag match had no alternatives");
        }
        if (finite_tags.alternatives.len == 1) {
            return try self.simplifyKnownMatchValueWithDemand(ty, .{ .tag = finite_tags.alternatives[0] }, branches_span, demand);
        }

        const branch_count = finite_tags.alternatives.len - 1;
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, branch_count);
        for (finite_tags.alternatives[0..branch_count], branches, 0..) |alternative, *branch, index| {
            branch.* = .{
                .cond = try self.selectorEquals(finite_tags.selector, @intCast(index)),
                .body = (try self.simplifyKnownMatchValueWithDemandMode(ty, .{ .tag = alternative }, branches_span, demand, .speculative)) orelse
                    return null,
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = (try self.simplifyKnownMatchValueWithDemandMode(ty, .{ .tag = finite_tags.alternatives[branch_count] }, branches_span, demand, .speculative)) orelse
            return null;

        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn simplifyKnownMatchPrivateFiniteTagsValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        finite_tags: PrivateStateFiniteTags,
        branches_span: Ast.Span(Ast.Branch),
        demand: ValueDemand,
    ) Common.LowerError!?Value {
        if (finite_tags.alternatives.len == 0) {
            Common.invariant("finite private tag match had no alternatives");
        }
        if (finite_tags.alternatives.len == 1) {
            return try self.simplifyKnownMatchValueWithDemand(ty, .{ .private_state = .{ .tag = finite_tags.alternatives[0] } }, branches_span, demand);
        }

        const branch_count = finite_tags.alternatives.len - 1;
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, branch_count);
        for (finite_tags.alternatives[0..branch_count], branches, 0..) |alternative, *branch, index| {
            branch.* = .{
                .cond = try self.selectorEquals(finite_tags.selector, @intCast(index)),
                .body = (try self.simplifyKnownMatchValueWithDemandMode(ty, .{ .private_state = .{ .tag = alternative } }, branches_span, demand, .speculative)) orelse
                    return null,
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = (try self.simplifyKnownMatchValueWithDemandMode(ty, .{ .private_state = .{ .tag = finite_tags.alternatives[branch_count] } }, branches_span, demand, .speculative)) orelse
            return null;

        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn simplifyKnownMatchValueWithKnownValuePreservation(
        self: *Cloner,
        ty: Type.TypeId,
        scrutinee: Value,
        branches_span: Ast.Span(Ast.Branch),
        preserve_branch_known_value: bool,
    ) Common.LowerError!?Value {
        return try self.simplifyKnownMatchValueMode(ty, scrutinee, branches_span, .strict, preserve_branch_known_value);
    }

    fn simplifyKnownMatchValueMode(
        self: *Cloner,
        ty: Type.TypeId,
        scrutinee: Value,
        branches_span: Ast.Span(Ast.Branch),
        mode: KnownMatchMode,
        preserve_branch_known_value: bool,
    ) Common.LowerError!?Value {
        switch (scrutinee) {
            .expr,
            .expr_with_known_value,
            => return null,
            .let_ => |let_value| {
                const change_start = self.changes.items.len;
                defer self.restore(change_start);
                try self.bindPendingLetKnownValues(let_value.lets);
                const body = (try self.simplifyKnownMatchValueMode(ty, let_value.body.*, branches_span, mode, preserve_branch_known_value)) orelse return null;
                return try self.wrapPendingLets(body, let_value.lets, true);
            },
            .if_ => |if_value| return try self.simplifyKnownMatchIfValue(ty, if_value, branches_span, preserve_branch_known_value),
            .match_ => |match_value| return try self.simplifyKnownMatchMatchValue(ty, match_value, branches_span, preserve_branch_known_value),
            .finite_tags => |finite_tags| return try self.simplifyKnownMatchFiniteTagsValue(ty, finite_tags, branches_span, preserve_branch_known_value),
            .private_state => |private_state| {
                if (privateStateLeafExpr(private_state) != null) return null;
                if (privateStateFiniteTags(private_state)) |finite_tags| {
                    return try self.simplifyKnownMatchPrivateFiniteTagsValue(ty, finite_tags, branches_span, preserve_branch_known_value);
                }
            },
            else => {},
        }
        for (self.pass.program.branchSpan(branches_span)) |branch| {
            var pending_lets = std.ArrayList(PendingLet).empty;
            defer pending_lets.deinit(self.pass.allocator);

            const change_start = self.changes.items.len;
            const unsafe_count = self.unsafeLeafCount(scrutinee);
            if (try self.bindPatToMatchValue(branch.pat, scrutinee, branch.body, .materialize, unsafe_count, &pending_lets) == null) {
                self.restore(change_start);
                continue;
            }
            if (branch.guard != null) {
                self.restore(change_start);
                return null;
            }
            const body = try self.cloneExprValue(branch.body);
            self.restore(change_start);
            return try self.wrapPendingLets(body, pending_lets.items, preserve_branch_known_value);
        }
        switch (mode) {
            .strict => {
                if (scrutinee == .private_state and !privateStateCanMaterializePublic(self.pass.program, scrutinee.private_state)) return null;
                Common.invariant("known constructor match had no matching branch");
            },
            .speculative => return null,
        }
    }

    fn simplifyKnownMatchIfValue(
        self: *Cloner,
        ty: Type.TypeId,
        if_value: IfValue,
        branches_span: Ast.Span(Ast.Branch),
        preserve_branch_known_value: bool,
    ) Common.LowerError!?Value {
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
        for (if_value.branches, 0..) |branch, index| {
            const simplified = try self.simplifyKnownMatchValueMode(ty, branch.body, branches_span, .speculative, preserve_branch_known_value);
            branches[index] = .{
                .cond = branch.cond,
                .body = simplified orelse return null,
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        const simplified_final_else = try self.simplifyKnownMatchValueMode(ty, if_value.final_else.*, branches_span, .speculative, preserve_branch_known_value);
        final_else.* = simplified_final_else orelse return null;

        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn simplifyKnownMatchMatchValue(
        self: *Cloner,
        ty: Type.TypeId,
        match_value: MatchValue,
        branches_span: Ast.Span(Ast.Branch),
        preserve_branch_known_value: bool,
    ) Common.LowerError!?Value {
        const branches = try self.pass.arena.allocator().alloc(MatchValueBranch, match_value.branches.len);
        for (match_value.branches, 0..) |branch, index| {
            const simplified = try self.simplifyKnownMatchValueMode(ty, branch.body, branches_span, .speculative, preserve_branch_known_value);
            branches[index] = .{
                .pat = branch.pat,
                .guard = branch.guard,
                .body = simplified orelse return null,
                .source = try self.matchBranchSourceThroughMatch(branch.source, ty, branches_span, null),
            };
        }

        return .{ .match_ = .{
            .ty = ty,
            .scrutinee = match_value.scrutinee,
            .branches = branches,
            .comptime_site = match_value.comptime_site,
        } };
    }

    fn simplifyKnownMatchFiniteTagsValue(
        self: *Cloner,
        ty: Type.TypeId,
        finite_tags: FiniteTagsValue,
        branches_span: Ast.Span(Ast.Branch),
        preserve_branch_known_value: bool,
    ) Common.LowerError!?Value {
        if (finite_tags.alternatives.len == 0) {
            Common.invariant("finite tag match had no alternatives");
        }
        if (finite_tags.alternatives.len == 1) {
            return try self.simplifyKnownMatchValueMode(ty, .{ .tag = finite_tags.alternatives[0] }, branches_span, .speculative, preserve_branch_known_value);
        }

        const branch_count = finite_tags.alternatives.len - 1;
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, branch_count);
        for (finite_tags.alternatives[0..branch_count], branches, 0..) |alternative, *branch, index| {
            branch.* = .{
                .cond = try self.selectorEquals(finite_tags.selector, @intCast(index)),
                .body = (try self.simplifyKnownMatchValueMode(ty, .{ .tag = alternative }, branches_span, .speculative, preserve_branch_known_value)) orelse
                    return null,
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = (try self.simplifyKnownMatchValueMode(ty, .{ .tag = finite_tags.alternatives[branch_count] }, branches_span, .speculative, preserve_branch_known_value)) orelse
            return null;

        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn simplifyKnownMatchPrivateFiniteTagsValue(
        self: *Cloner,
        ty: Type.TypeId,
        finite_tags: PrivateStateFiniteTags,
        branches_span: Ast.Span(Ast.Branch),
        preserve_branch_known_value: bool,
    ) Common.LowerError!?Value {
        if (finite_tags.alternatives.len == 0) {
            Common.invariant("finite private tag match had no alternatives");
        }
        if (finite_tags.alternatives.len == 1) {
            return try self.simplifyKnownMatchValueMode(ty, .{ .private_state = .{ .tag = finite_tags.alternatives[0] } }, branches_span, .speculative, preserve_branch_known_value);
        }

        const branch_count = finite_tags.alternatives.len - 1;
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, branch_count);
        for (finite_tags.alternatives[0..branch_count], branches, 0..) |alternative, *branch, index| {
            branch.* = .{
                .cond = try self.selectorEquals(finite_tags.selector, @intCast(index)),
                .body = (try self.simplifyKnownMatchValueMode(ty, .{ .private_state = .{ .tag = alternative } }, branches_span, .speculative, preserve_branch_known_value)) orelse
                    return null,
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = (try self.simplifyKnownMatchValueMode(ty, .{ .private_state = .{ .tag = finite_tags.alternatives[branch_count] } }, branches_span, .speculative, preserve_branch_known_value)) orelse
            return null;

        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn bindPatToMatchValue(
        self: *Cloner,
        pat_id: Ast.PatId,
        value: Value,
        body: Ast.ExprId,
        context: ValueDemand,
        unsafe_count: usize,
        pending_lets: *std.ArrayList(PendingLet),
    ) Common.LowerError!?Value {
        const pat = self.pass.program.pats.items[@intFromEnum(pat_id)];
        switch (pat.data) {
            .bind => |local| {
                const prepared = try self.valueForMatchLocal(local, value, body, unsafe_count, pending_lets);
                try self.putSubst(local, prepared);
                return prepared;
            },
            .wildcard => return try self.makeReusableForMatch(value, pending_lets),
            .as => |as| {
                const as_uses = localUseCountInExpr(self.pass.program, as.local, body);
                const base = if (self.valueCanSubstitute(value) or
                    (unsafe_count == 1 and as_uses == 1 and localUseBeforeEffect(self.pass.program, as.local, body)))
                    value
                else
                    try self.makeReusableForMatch(value, pending_lets);
                const prepared = (try self.bindPatToMatchValue(as.pattern, base, body, context, unsafe_count, pending_lets)) orelse return null;
                try self.putSubst(as.local, prepared);
                return prepared;
            },
            .record => |fields_span| {
                const fields = self.pass.program.recordDestructSpan(fields_span);
                if (recordFromValue(value)) |record| {
                    const prepared_fields = try self.pass.arena.allocator().alloc(FieldValue, record.fields.len);
                    for (record.fields, 0..) |field, index| {
                        if (recordPatField(fields, field.name)) |field_pat| {
                            const prepared = (try self.bindPatToMatchValue(field_pat, field.value, body, context, unsafe_count, pending_lets)) orelse return null;
                            prepared_fields[index] = .{
                                .name = field.name,
                                .value = prepared,
                            };
                        } else {
                            prepared_fields[index] = .{
                                .name = field.name,
                                .value = try self.makeReusableForMatch(field.value, pending_lets),
                            };
                        }
                    }
                    return Value{ .record = .{
                        .ty = record.ty,
                        .fields = prepared_fields,
                    } };
                }
                const projected_value = if (!self.valueCanSubstitute(value) and projectableExprFromValue(value) != null)
                    try self.makeReusableForMatch(value, pending_lets)
                else
                    value;
                for (fields) |field| {
                    const field_demand = try self.patternDemandInExpr(field.pattern, body, context);
                    const field_ty = self.pass.program.pats.items[@intFromEnum(field.pattern)].ty;
                    const field_value = (try self.fieldFromPatternValue(projected_value, field.name, field_ty)) orelse {
                        if (field_demand == .none and !patternUsedInExpr(self.pass.program, field.pattern, body)) continue;
                        return null;
                    };
                    _ = (try self.bindPatToMatchValue(field.pattern, field_value, body, context, unsafe_count, pending_lets)) orelse return null;
                }
                return try self.makeReusableForMatch(projected_value, pending_lets);
            },
            .tuple => |items_span| {
                const pats = self.pass.program.patSpan(items_span);
                if (tupleFromValue(value)) |tuple| {
                    if (pats.len != tuple.items.len) return null;
                    const items = try self.pass.arena.allocator().alloc(Value, tuple.items.len);
                    for (pats, tuple.items, 0..) |child_pat, child_value, index| {
                        items[index] = (try self.bindPatToMatchValue(child_pat, child_value, body, context, unsafe_count, pending_lets)) orelse return null;
                    }
                    return Value{ .tuple = .{
                        .ty = tuple.ty,
                        .items = items,
                    } };
                }
                const projected_value = if (!self.valueCanSubstitute(value) and projectableExprFromValue(value) != null)
                    try self.makeReusableForMatch(value, pending_lets)
                else
                    value;
                for (pats, 0..) |child_pat, index| {
                    const item_demand = try self.patternDemandInExpr(child_pat, body, context);
                    const item_ty = self.pass.program.pats.items[@intFromEnum(child_pat)].ty;
                    const item_value = (try self.itemFromPatternValue(projected_value, @intCast(index), item_ty)) orelse {
                        if (item_demand == .none and !patternUsedInExpr(self.pass.program, child_pat, body)) continue;
                        return null;
                    };
                    _ = (try self.bindPatToMatchValue(child_pat, item_value, body, context, unsafe_count, pending_lets)) orelse return null;
                }
                return try self.makeReusableForMatch(projected_value, pending_lets);
            },
            .tag => |tag_pat| {
                const pats = self.pass.program.patSpan(tag_pat.payloads);
                if (tagFromValue(value)) |tag| {
                    if (tag.name != tag_pat.name) return null;
                    if (pats.len != tag.payloads.len) return null;
                    const payloads = try self.pass.arena.allocator().alloc(Value, tag.payloads.len);
                    for (pats, tag.payloads, 0..) |child_pat, child_value, index| {
                        payloads[index] = (try self.bindPatToMatchValue(child_pat, child_value, body, context, unsafe_count, pending_lets)) orelse return null;
                    }
                    return Value{ .tag = .{
                        .ty = tag.ty,
                        .name = tag.name,
                        .payloads = payloads,
                    } };
                }

                const private_tag = switch (value) {
                    .private_state => |private_state| privateStateTag(private_state) orelse return null,
                    else => return null,
                };
                if (private_tag.name != tag_pat.name) return null;
                for (pats, 0..) |child_pat, index| {
                    const payload_demand = try self.patternDemandInExpr(child_pat, body, context);
                    const child_value = privateStateIndexedValueByIndex(private_tag.payloads, @intCast(index)) orelse {
                        if (payload_demand == .none and !patternUsedInExpr(self.pass.program, child_pat, body)) continue;
                        return null;
                    };
                    _ = (try self.bindPatToMatchValue(child_pat, .{ .private_state = child_value }, body, context, unsafe_count, pending_lets)) orelse {
                        return null;
                    };
                }
                return value;
            },
            .nominal => |backing_pat| {
                const nominal = switch (value) {
                    .nominal => |nominal| nominal,
                    else => return null,
                };
                const backing = try self.pass.arena.allocator().create(Value);
                backing.* = (try self.bindPatToMatchValue(backing_pat, nominal.backing.*, body, context, unsafe_count, pending_lets)) orelse return null;
                return Value{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = backing,
                } };
            },
            // List patterns are not statically destructured during
            // specialization; fall back to the runtime match.
            .list,
            .int_lit,
            .dec_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .str_lit,
            .str_pattern,
            => return null,
        }
    }

    fn valueForMatchLocal(
        self: *Cloner,
        local: Ast.LocalId,
        value: Value,
        body: Ast.ExprId,
        unsafe_count: usize,
        pending_lets: *std.ArrayList(PendingLet),
    ) Common.LowerError!Value {
        const uses = localUseCountInExpr(self.pass.program, local, body);
        if (self.valueCanSubstitute(value) or
            (unsafe_count == 1 and uses == 1 and localUseBeforeEffect(self.pass.program, local, body)))
        {
            return value;
        }
        return try self.makeReusableForMatch(value, pending_lets);
    }

    fn valueForInlineLocal(
        self: *Cloner,
        local: Ast.LocalId,
        value: Value,
        body: Ast.ExprId,
        pending_lets: *std.ArrayList(PendingLet),
    ) Common.LowerError!Value {
        const uses = localMaxUseCountPerPathInExpr(self.pass.program, local, body);
        if (self.valueCanSubstitute(value) or
            (uses == 1 and localUseBeforeEffect(self.pass.program, local, body)))
        {
            return value;
        }
        return try self.makeReusableForMatch(value, pending_lets);
    }

    fn unsafeLeafCount(self: *Cloner, value: Value) usize {
        return switch (value) {
            .expr => |expr| if (self.exprCanSubstitute(expr)) 0 else 1,
            .expr_with_known_value => |known_value_expr| if (self.exprCanSubstitute(known_value_expr.expr)) 0 else 1,
            .let_ => |let_value| blk: {
                var count: usize = let_value.lets.len;
                count += self.unsafeLeafCount(let_value.body.*);
                break :blk count;
            },
            .if_ => |if_value| blk: {
                var count: usize = 0;
                for (if_value.branches) |branch| {
                    if (!self.exprCanSubstitute(branch.cond)) count += 1;
                    count += self.unsafeLeafCount(branch.body);
                }
                count += self.unsafeLeafCount(if_value.final_else.*);
                break :blk count;
            },
            .match_ => |match_value| blk: {
                var count: usize = if (self.exprCanSubstitute(match_value.scrutinee)) 0 else 1;
                for (match_value.branches) |branch| {
                    if (branch.guard) |guard| {
                        if (!self.exprCanSubstitute(guard)) count += 1;
                    }
                    count += self.unsafeLeafCount(branch.body);
                }
                break :blk count;
            },
            .tag => |tag| blk: {
                var count: usize = 0;
                for (tag.payloads) |payload| count += self.unsafeLeafCount(payload);
                break :blk count;
            },
            .record => |record| blk: {
                var count: usize = 0;
                for (record.fields) |field| count += self.unsafeLeafCount(field.value);
                break :blk count;
            },
            .tuple => |tuple| blk: {
                var count: usize = 0;
                for (tuple.items) |item| count += self.unsafeLeafCount(item);
                break :blk count;
            },
            .nominal => |nominal| self.unsafeLeafCount(nominal.backing.*),
            .callable => |callable| blk: {
                var count: usize = 0;
                for (callable.captures) |capture| count += self.unsafeLeafCount(capture);
                break :blk count;
            },
            .finite_tags => |finite_tags| blk: {
                var count: usize = if (self.exprCanSubstitute(finite_tags.selector)) 0 else 1;
                for (finite_tags.alternatives) |alternative| {
                    for (alternative.payloads) |payload| count += self.unsafeLeafCount(payload);
                }
                break :blk count;
            },
            .finite_callables => |finite_callables| blk: {
                var count: usize = if (self.exprCanSubstitute(finite_callables.selector)) 0 else 1;
                for (finite_callables.alternatives) |alternative| {
                    for (alternative.captures) |capture| count += self.unsafeLeafCount(capture);
                }
                break :blk count;
            },
            .private_state => 0,
        };
    }

    fn makeReusableForMatch(self: *Cloner, value: Value, pending_lets: *std.ArrayList(PendingLet)) Common.LowerError!Value {
        if (self.valueCanSubstitute(value)) return value;
        if (self.valueContainsEscapingControlTransfer(value)) return value;
        return switch (value) {
            .expr => |expr| blk: {
                const ty = self.pass.program.exprs.items[@intFromEnum(expr)].ty;
                const local = try self.pass.program.addLocal(self.pass.symbols.fresh(), ty);
                try pending_lets.append(self.pass.allocator, .{
                    .local = local,
                    .ty = ty,
                    .value = .{ .cloned = expr },
                });
                break :blk Value{ .expr = try self.addExpr(.{
                    .ty = ty,
                    .data = .{ .local = local },
                }) };
            },
            .expr_with_known_value => |known_value_expr| blk: {
                const ty = self.pass.program.exprs.items[@intFromEnum(known_value_expr.expr)].ty;
                const local = try self.pass.program.addLocal(self.pass.symbols.fresh(), ty);
                try pending_lets.append(self.pass.allocator, .{
                    .local = local,
                    .ty = ty,
                    .value = .{ .cloned = known_value_expr.expr },
                    .known_value = known_value_expr.known_value,
                    .structured_value = known_value_expr.value,
                });
                const local_expr = try self.addExpr(.{
                    .ty = ty,
                    .data = .{ .local = local },
                });
                break :blk Value{ .expr_with_known_value = .{
                    .expr = local_expr,
                    .known_value = known_value_expr.known_value,
                    .value = known_value_expr.value,
                } };
            },
            .let_ => |let_value| blk: {
                const body = try self.makeReusableForMatch(let_value.body.*, pending_lets);
                const lets = try self.pass.arena.allocator().dupe(PendingLet, let_value.lets);
                break :blk Value{ .let_ = .{
                    .lets = lets,
                    .body = try self.copyValue(body),
                } };
            },
            .if_ => |if_value| blk: {
                const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
                for (if_value.branches, 0..) |branch, index| {
                    var branch_pending_lets = std.ArrayList(PendingLet).empty;
                    defer branch_pending_lets.deinit(self.pass.allocator);
                    const branch_body = try self.makeReusableForMatch(branch.body, &branch_pending_lets);
                    branches[index] = .{
                        .cond = try self.makeExprReusableForMatch(branch.cond, pending_lets),
                        .body = try self.wrapPendingLets(branch_body, branch_pending_lets.items, true),
                    };
                }
                const final_else = try self.pass.arena.allocator().create(Value);
                var else_pending_lets = std.ArrayList(PendingLet).empty;
                defer else_pending_lets.deinit(self.pass.allocator);
                const else_body = try self.makeReusableForMatch(if_value.final_else.*, &else_pending_lets);
                final_else.* = try self.wrapPendingLets(else_body, else_pending_lets.items, true);
                break :blk Value{ .if_ = .{
                    .ty = if_value.ty,
                    .branches = branches,
                    .final_else = final_else,
                } };
            },
            .match_ => |match_value| blk: {
                const branches = try self.pass.arena.allocator().alloc(MatchValueBranch, match_value.branches.len);
                for (match_value.branches, 0..) |branch, index| {
                    var branch_pending_lets = std.ArrayList(PendingLet).empty;
                    defer branch_pending_lets.deinit(self.pass.allocator);
                    const branch_body = try self.makeReusableForMatch(branch.body, &branch_pending_lets);
                    branches[index] = .{
                        .pat = branch.pat,
                        .guard = if (branch.guard) |guard| try self.makeExprReusableForMatch(guard, pending_lets) else null,
                        .body = try self.wrapPendingLets(branch_body, branch_pending_lets.items, true),
                        .source = branch.source,
                    };
                }
                break :blk Value{ .match_ = .{
                    .ty = match_value.ty,
                    .scrutinee = try self.makeExprReusableForMatch(match_value.scrutinee, pending_lets),
                    .branches = branches,
                    .comptime_site = match_value.comptime_site,
                } };
            },
            .tag => |tag| blk: {
                const payloads = try self.pass.arena.allocator().alloc(Value, tag.payloads.len);
                for (tag.payloads, 0..) |payload, index| {
                    payloads[index] = try self.makeReusableForMatch(payload, pending_lets);
                }
                break :blk Value{ .tag = .{
                    .ty = tag.ty,
                    .name = tag.name,
                    .payloads = payloads,
                } };
            },
            .record => |record| blk: {
                const fields = try self.pass.arena.allocator().alloc(FieldValue, record.fields.len);
                for (record.fields, 0..) |field, index| {
                    fields[index] = .{
                        .name = field.name,
                        .value = try self.makeReusableForMatch(field.value, pending_lets),
                    };
                }
                break :blk Value{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| blk: {
                const items = try self.pass.arena.allocator().alloc(Value, tuple.items.len);
                for (tuple.items, 0..) |item, index| {
                    items[index] = try self.makeReusableForMatch(item, pending_lets);
                }
                break :blk Value{ .tuple = .{
                    .ty = tuple.ty,
                    .items = items,
                } };
            },
            .nominal => |nominal| blk: {
                const backing = try self.pass.arena.allocator().create(Value);
                backing.* = try self.makeReusableForMatch(nominal.backing.*, pending_lets);
                break :blk Value{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = backing,
                } };
            },
            .callable => |callable| blk: {
                const captures = try self.pass.arena.allocator().alloc(Value, callable.captures.len);
                for (callable.captures, 0..) |capture, index| {
                    captures[index] = try self.makeReusableForMatch(capture, pending_lets);
                }
                break :blk Value{ .callable = .{
                    .ty = callable.ty,
                    .fn_id = callable.fn_id,
                    .captures = captures,
                } };
            },
            .finite_tags => |finite_tags| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(TagValue, finite_tags.alternatives.len);
                for (finite_tags.alternatives, alternatives) |alternative, *out| {
                    const payloads = try self.pass.arena.allocator().alloc(Value, alternative.payloads.len);
                    for (alternative.payloads, payloads) |payload, *payload_out| {
                        payload_out.* = try self.makeReusableForMatch(payload, pending_lets);
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .name = alternative.name,
                        .payloads = payloads,
                    };
                }
                break :blk Value{ .finite_tags = .{
                    .ty = finite_tags.ty,
                    .selector = try self.makeExprReusableForMatch(finite_tags.selector, pending_lets),
                    .alternatives = alternatives,
                } };
            },
            .finite_callables => |finite_callables| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(CallableValue, finite_callables.alternatives.len);
                for (finite_callables.alternatives, alternatives) |alternative, *out| {
                    const captures = try self.pass.arena.allocator().alloc(Value, alternative.captures.len);
                    for (alternative.captures, captures) |capture, *capture_out| {
                        capture_out.* = try self.makeReusableForMatch(capture, pending_lets);
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .fn_id = alternative.fn_id,
                        .captures = captures,
                    };
                }
                break :blk Value{ .finite_callables = .{
                    .ty = finite_callables.ty,
                    .selector = try self.makeExprReusableForMatch(finite_callables.selector, pending_lets),
                    .alternatives = alternatives,
                } };
            },
            .private_state => |private_state| Value{ .private_state = try self.makePrivateStateReusableForMatch(private_state, pending_lets) },
        };
    }

    fn makePrivateStateReusableForMatch(
        self: *Cloner,
        value: PrivateStateValue,
        pending_lets: *std.ArrayList(PendingLet),
    ) Common.LowerError!PrivateStateValue {
        return switch (value) {
            .leaf => |leaf| .{ .leaf = .{
                .ty = leaf.ty,
                .expr = try self.makeExprReusableForMatch(leaf.expr, pending_lets),
            } },
            .tag => |tag| blk: {
                const payloads = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, tag.payloads.len);
                for (tag.payloads, payloads) |payload, *out| {
                    out.* = .{
                        .index = payload.index,
                        .value = try self.makePrivateStateReusableForMatch(payload.value, pending_lets),
                    };
                }
                break :blk PrivateStateValue{ .tag = .{
                    .ty = tag.ty,
                    .name = tag.name,
                    .payloads = payloads,
                } };
            },
            .record => |record| blk: {
                const fields = try self.pass.arena.allocator().alloc(PrivateStateField, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    out.* = .{
                        .name = field.name,
                        .value = try self.makePrivateStateReusableForMatch(field.value, pending_lets),
                    };
                }
                break :blk PrivateStateValue{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| blk: {
                const items = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, tuple.items.len);
                for (tuple.items, items) |item, *out| {
                    out.* = .{
                        .index = item.index,
                        .value = try self.makePrivateStateReusableForMatch(item.value, pending_lets),
                    };
                }
                break :blk PrivateStateValue{ .tuple = .{
                    .ty = tuple.ty,
                    .items = items,
                } };
            },
            .nominal => |nominal| blk: {
                const backing = if (nominal.backing) |backing_value| backing: {
                    const stored = try self.pass.arena.allocator().create(PrivateStateValue);
                    stored.* = try self.makePrivateStateReusableForMatch(backing_value.*, pending_lets);
                    break :backing stored;
                } else null;
                break :blk PrivateStateValue{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = backing,
                } };
            },
            .callable => |callable| blk: {
                const captures = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, callable.captures.len);
                for (callable.captures, captures) |capture, *out| {
                    out.* = .{
                        .index = capture.index,
                        .value = try self.makePrivateStateReusableForMatch(capture.value, pending_lets),
                    };
                }
                break :blk PrivateStateValue{ .callable = .{
                    .ty = callable.ty,
                    .fn_id = callable.fn_id,
                    .captures = captures,
                } };
            },
            .finite_tags => |finite_tags| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(PrivateStateTag, finite_tags.alternatives.len);
                for (finite_tags.alternatives, alternatives) |alternative, *out| {
                    const payloads = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, alternative.payloads.len);
                    for (alternative.payloads, payloads) |payload, *payload_out| {
                        payload_out.* = .{
                            .index = payload.index,
                            .value = try self.makePrivateStateReusableForMatch(payload.value, pending_lets),
                        };
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .name = alternative.name,
                        .payloads = payloads,
                    };
                }
                break :blk PrivateStateValue{ .finite_tags = .{
                    .ty = finite_tags.ty,
                    .selector = try self.makeExprReusableForMatch(finite_tags.selector, pending_lets),
                    .alternatives = alternatives,
                } };
            },
            .finite_callables => |finite_callables| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(PrivateStateCallable, finite_callables.alternatives.len);
                for (finite_callables.alternatives, alternatives) |alternative, *out| {
                    const captures = try self.pass.arena.allocator().alloc(PrivateStateIndexedValue, alternative.captures.len);
                    for (alternative.captures, captures) |capture, *capture_out| {
                        capture_out.* = .{
                            .index = capture.index,
                            .value = try self.makePrivateStateReusableForMatch(capture.value, pending_lets),
                        };
                    }
                    out.* = .{
                        .ty = alternative.ty,
                        .fn_id = alternative.fn_id,
                        .captures = captures,
                    };
                }
                break :blk PrivateStateValue{ .finite_callables = .{
                    .ty = finite_callables.ty,
                    .selector = try self.makeExprReusableForMatch(finite_callables.selector, pending_lets),
                    .alternatives = alternatives,
                } };
            },
        };
    }

    fn makeExprReusableForMatch(
        self: *Cloner,
        expr: Ast.ExprId,
        pending_lets: *std.ArrayList(PendingLet),
    ) Common.LowerError!Ast.ExprId {
        if (self.exprCanSubstitute(expr)) return expr;
        if (exprContainsEscapingControlTransfer(self.pass.program, expr)) return expr;

        const ty = self.pass.program.exprs.items[@intFromEnum(expr)].ty;
        const local = try self.pass.program.addLocal(self.pass.symbols.fresh(), ty);
        try pending_lets.append(self.pass.allocator, .{
            .local = local,
            .ty = ty,
            .value = .{ .cloned = expr },
            .known_value = try self.pass.constructorKnownValue(expr),
        });
        return try self.addExpr(.{
            .ty = ty,
            .data = .{ .local = local },
        });
    }

    fn valueCanMaterializePublic(self: *Cloner, value: Value) bool {
        switch (value) {
            .expr,
            .expr_with_known_value,
            => return true,
            .let_ => |let_value| return self.valueCanMaterializePublic(let_value.body.*),
            .if_ => |if_value| {
                for (if_value.branches) |branch| {
                    if (!self.valueCanMaterializePublic(branch.body)) return false;
                }
                return self.valueCanMaterializePublic(if_value.final_else.*);
            },
            .match_ => |match_value| {
                for (match_value.branches) |branch| {
                    if (!self.valueCanMaterializePublic(branch.body)) return false;
                }
                return true;
            },
            .tag => |tag| {
                for (tag.payloads) |payload| {
                    if (!self.valueCanMaterializePublic(payload)) return false;
                }
                return true;
            },
            .record => |record| {
                for (record.fields) |field| {
                    if (!self.valueCanMaterializePublic(field.value)) return false;
                }
                return true;
            },
            .tuple => |tuple| {
                for (tuple.items) |item| {
                    if (!self.valueCanMaterializePublic(item)) return false;
                }
                return true;
            },
            .nominal => |nominal| return self.valueCanMaterializePublic(nominal.backing.*),
            .callable => |callable| {
                for (callable.captures) |capture| {
                    if (!self.valueCanMaterializePublic(capture)) return false;
                }
                return true;
            },
            .finite_tags => |finite_tags| {
                for (finite_tags.alternatives) |alternative| {
                    for (alternative.payloads) |payload| {
                        if (!self.valueCanMaterializePublic(payload)) return false;
                    }
                }
                return true;
            },
            .finite_callables => |finite_callables| {
                for (finite_callables.alternatives) |alternative| {
                    for (alternative.captures) |capture| {
                        if (!self.valueCanMaterializePublic(capture)) return false;
                    }
                }
                return true;
            },
            .private_state => |private_state| return privateStateCanMaterializePublic(self.pass.program, private_state),
        }
    }

    fn valueDemandFromValueShape(self: *Cloner, value: Value) Common.LowerError!ValueDemand {
        return switch (value) {
            .let_ => |let_value| try self.valueDemandFromValueShape(let_value.body.*),
            .if_ => |if_value| blk: {
                var demand: ValueDemand = .none;
                for (if_value.branches) |branch| {
                    demand = try self.mergeValueDemand(demand, try self.valueDemandFromValueShape(branch.body));
                }
                demand = try self.mergeValueDemand(demand, try self.valueDemandFromValueShape(if_value.final_else.*));
                break :blk demand;
            },
            .match_ => |match_value| blk: {
                var demand: ValueDemand = .none;
                for (match_value.branches) |branch| {
                    demand = try self.mergeValueDemand(demand, try self.valueDemandFromValueShape(branch.body));
                }
                break :blk demand;
            },
            .tag => |tag| blk: {
                const payloads = try self.pass.arena.allocator().alloc(ItemDemand, tag.payloads.len);
                for (tag.payloads, payloads, 0..) |payload, *out, index| {
                    out.* = .{
                        .index = @intCast(index),
                        .demand = try self.pass.storedDemand(try self.valueDemandFromValueShape(payload)),
                    };
                }
                break :blk ValueDemand{ .tag = .{ .payloads = payloads } };
            },
            .record => |record| blk: {
                const fields = try self.pass.arena.allocator().alloc(FieldDemand, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    out.* = .{
                        .name = field.name,
                        .demand = try self.pass.storedDemand(try self.valueDemandFromValueShape(field.value)),
                    };
                }
                break :blk ValueDemand{ .record = fields };
            },
            .tuple => |tuple| blk: {
                const items = try self.pass.arena.allocator().alloc(ItemDemand, tuple.items.len);
                for (tuple.items, items, 0..) |item, *out, index| {
                    out.* = .{
                        .index = @intCast(index),
                        .demand = try self.pass.storedDemand(try self.valueDemandFromValueShape(item)),
                    };
                }
                break :blk ValueDemand{ .tuple = items };
            },
            .nominal => |nominal| ValueDemand{
                .nominal = try self.pass.storedDemand(try self.valueDemandFromValueShape(nominal.backing.*)),
            },
            .callable => |callable| try self.valueDemandFromCallableValueShape(callable),
            .finite_tags => |finite_tags| blk: {
                var demand: ValueDemand = .none;
                for (finite_tags.alternatives) |alternative| {
                    demand = try self.mergeValueDemand(demand, try self.valueDemandFromValueShape(.{ .tag = alternative }));
                }
                break :blk demand;
            },
            .finite_callables => |finite_callables| blk: {
                var demand: ValueDemand = .none;
                for (finite_callables.alternatives) |alternative| {
                    demand = try self.mergeValueDemand(demand, try self.valueDemandFromValueShape(.{ .callable = alternative }));
                }
                break :blk demand;
            },
            .private_state => |private_state| try self.valueDemandFromPrivateStateShape(private_state),
            .expr,
            .expr_with_known_value,
            => .materialize,
        };
    }

    fn valueDemandFromCallableValueShape(
        self: *Cloner,
        callable: CallableValue,
    ) Common.LowerError!ValueDemand {
        const captures = try self.pass.arena.allocator().alloc(ValueDemand, callable.captures.len);
        @memset(captures, .none);
        for (callable.captures, 0..) |capture, index| {
            captures[index] = try self.valueDemandFromValueShape(capture);
        }
        return .{ .callable = .{ .captures = captures } };
    }

    fn privateStateValueFromIfDemand(
        self: *Cloner,
        if_value: IfValue,
        demand: ValueDemand,
        pending_lets: ?*std.ArrayList(PendingLet),
    ) Common.LowerError!?PrivateStateValue {
        return switch (demand) {
            .tag => try self.privateFiniteTagsFromIfDemand(if_value, demand, pending_lets),
            .callable => try self.privateFiniteCallablesFromIfDemand(if_value, demand, pending_lets),
            else => null,
        };
    }

    fn privateStateValueFromMatchDemand(
        self: *Cloner,
        match_value: MatchValue,
        demand: ValueDemand,
        pending_lets: ?*std.ArrayList(PendingLet),
    ) Common.LowerError!?PrivateStateValue {
        return switch (demand) {
            .tag => try self.privateFiniteTagsFromMatchDemand(match_value, demand, pending_lets),
            .callable => try self.privateFiniteCallablesFromMatchDemand(match_value, demand, pending_lets),
            else => null,
        };
    }

    fn privateFiniteCallablesFromIfDemand(
        self: *Cloner,
        if_value: IfValue,
        demand: ValueDemand,
        pending_lets: ?*std.ArrayList(PendingLet),
    ) Common.LowerError!?PrivateStateValue {
        const alternative_count = if_value.branches.len + 1;
        const alternatives = try self.pass.arena.allocator().alloc(PrivateStateCallable, alternative_count);
        for (if_value.branches, alternatives[0..if_value.branches.len]) |branch, *out| {
            const private_state = (try self.privateStateValueFromValueDemandCollectingLets(branch.body, demand, pending_lets)) orelse return null;
            out.* = privateStateCallable(private_state) orelse return null;
        }
        const final_private_state = (try self.privateStateValueFromValueDemandCollectingLets(if_value.final_else.*, demand, pending_lets)) orelse return null;
        alternatives[alternative_count - 1] = privateStateCallable(final_private_state) orelse return null;

        return .{ .finite_callables = .{
            .ty = if_value.ty,
            .selector = try self.selectorForIfValue(if_value),
            .alternatives = alternatives,
        } };
    }

    fn privateFiniteCallablesFromMatchDemand(
        self: *Cloner,
        match_value: MatchValue,
        demand: ValueDemand,
        pending_lets: ?*std.ArrayList(PendingLet),
    ) Common.LowerError!?PrivateStateValue {
        var alternatives = std.ArrayList(PrivateStateCallable).empty;
        defer alternatives.deinit(self.pass.allocator);

        const selector_branches = try self.pass.allocator.alloc(Ast.Branch, match_value.branches.len);
        defer self.pass.allocator.free(selector_branches);

        for (match_value.branches, selector_branches) |branch, *selector_branch| {
            const branch_value = try self.cloneMatchValueBranchBodyWithDemand(branch, demand);
            const private_state = (try self.privateStateValueFromValueDemandCollectingLets(branch_value, demand, pending_lets)) orelse {
                return null;
            };
            const selector_body = if (privateStateCallable(private_state)) |callable| body: {
                const index = alternatives.items.len;
                try alternatives.append(self.pass.allocator, callable);
                break :body try self.selectorLiteral(@intCast(index));
            } else if (privateStateFiniteCallables(private_state)) |finite_callables| body: {
                const offset = alternatives.items.len;
                try alternatives.appendSlice(self.pass.allocator, finite_callables.alternatives);
                break :body try self.selectorWithOffset(finite_callables.selector, @intCast(offset));
            } else {
                return null;
            };

            selector_branch.* = .{
                .pat = branch.pat,
                .guard = branch.guard,
                .body = selector_body,
            };
        }
        if (alternatives.items.len == 0) Common.invariant("finite callable match had no alternatives");

        return .{ .finite_callables = .{
            .ty = match_value.ty,
            .selector = try self.addExpr(.{ .ty = try self.pass.primitiveType(.u64), .data = .{ .match_ = .{
                .scrutinee = match_value.scrutinee,
                .branches = try self.pass.program.addBranchSpan(selector_branches),
                .comptime_site = match_value.comptime_site,
            } } }),
            .alternatives = try self.pass.arena.allocator().dupe(PrivateStateCallable, alternatives.items),
        } };
    }

    fn privateFiniteTagsFromIfDemand(
        self: *Cloner,
        if_value: IfValue,
        demand: ValueDemand,
        pending_lets: ?*std.ArrayList(PendingLet),
    ) Common.LowerError!?PrivateStateValue {
        const alternative_count = if_value.branches.len + 1;
        const alternatives = try self.pass.arena.allocator().alloc(PrivateStateTag, alternative_count);
        for (if_value.branches, alternatives[0..if_value.branches.len]) |branch, *out| {
            const private_state = (try self.privateStateValueFromValueDemandCollectingLets(branch.body, demand, pending_lets)) orelse return null;
            out.* = privateStateTag(private_state) orelse return null;
        }
        const final_private_state = (try self.privateStateValueFromValueDemandCollectingLets(if_value.final_else.*, demand, pending_lets)) orelse return null;
        alternatives[alternative_count - 1] = privateStateTag(final_private_state) orelse return null;

        return .{ .finite_tags = .{
            .ty = if_value.ty,
            .selector = try self.selectorForIfValue(if_value),
            .alternatives = alternatives,
        } };
    }

    fn privateFiniteTagsFromMatchDemand(
        self: *Cloner,
        match_value: MatchValue,
        demand: ValueDemand,
        pending_lets: ?*std.ArrayList(PendingLet),
    ) Common.LowerError!?PrivateStateValue {
        var alternatives = std.ArrayList(PrivateStateTag).empty;
        defer alternatives.deinit(self.pass.allocator);

        const selector_branches = try self.pass.allocator.alloc(Ast.Branch, match_value.branches.len);
        defer self.pass.allocator.free(selector_branches);

        for (match_value.branches, selector_branches) |branch, *selector_branch| {
            const branch_value = try self.cloneMatchValueBranchBodyWithDemand(branch, demand);
            const private_state = (try self.privateStateValueFromValueDemandCollectingLets(branch_value, demand, pending_lets)) orelse return null;
            const selector_body = if (privateStateTag(private_state)) |tag| body: {
                const index = alternatives.items.len;
                try alternatives.append(self.pass.allocator, tag);
                break :body try self.selectorLiteral(@intCast(index));
            } else if (privateStateFiniteTags(private_state)) |finite_tags| body: {
                const offset = alternatives.items.len;
                try alternatives.appendSlice(self.pass.allocator, finite_tags.alternatives);
                break :body try self.selectorWithOffset(finite_tags.selector, @intCast(offset));
            } else return null;

            selector_branch.* = .{
                .pat = branch.pat,
                .guard = branch.guard,
                .body = selector_body,
            };
        }
        if (alternatives.items.len == 0) Common.invariant("finite tag match had no alternatives");

        return .{ .finite_tags = .{
            .ty = match_value.ty,
            .selector = try self.addExpr(.{ .ty = try self.pass.primitiveType(.u64), .data = .{ .match_ = .{
                .scrutinee = match_value.scrutinee,
                .branches = try self.pass.program.addBranchSpan(selector_branches),
                .comptime_site = match_value.comptime_site,
            } } }),
            .alternatives = try self.pass.arena.allocator().dupe(PrivateStateTag, alternatives.items),
        } };
    }

    fn selectorWithOffset(self: *Cloner, selector: Ast.ExprId, offset: u64) Common.LowerError!Ast.ExprId {
        if (offset == 0) return selector;
        const selector_ty = try self.pass.primitiveType(.u64);
        const offset_expr = try self.selectorLiteral(offset);
        const args = try self.pass.program.addExprSpan(&.{ selector, offset_expr });
        return try self.addExpr(.{
            .ty = selector_ty,
            .data = .{ .low_level = .{
                .op = .num_plus,
                .args = args,
            } },
        });
    }

    fn selectorForIfValue(self: *Cloner, if_value: IfValue) Common.LowerError!Ast.ExprId {
        if (if_value.branches.len == 0) return try self.selectorLiteral(0);

        const selector_ty = try self.pass.primitiveType(.u64);
        const branches = try self.pass.allocator.alloc(Ast.IfBranch, if_value.branches.len);
        defer self.pass.allocator.free(branches);
        for (if_value.branches, branches, 0..) |branch, *out, index| {
            out.* = .{
                .cond = branch.cond,
                .body = try self.selectorLiteral(@intCast(index)),
            };
        }
        return try self.addExpr(.{ .ty = selector_ty, .data = .{ .if_ = .{
            .branches = try self.pass.program.addIfBranchSpan(branches),
            .final_else = try self.selectorLiteral(@intCast(if_value.branches.len)),
        } } });
    }

    fn wrapPendingLets(self: *Cloner, body: Value, pending_lets: []const PendingLet, preserve_known_value: bool) Common.LowerError!Value {
        if (pending_lets.len == 0) return body;

        const known_value = if (preserve_known_value) try self.pass.knownValueFromValue(body) else null;
        if (known_value != null or !self.valueCanMaterializePublic(body)) {
            const lets = try self.pass.arena.allocator().dupe(PendingLet, pending_lets);
            return .{ .let_ = .{
                .lets = lets,
                .body = try self.copyValue(body),
            } };
        }

        const ty = valueType(self.pass.program, body);
        var result = try self.materialize(body);
        result = try self.wrapPendingLetsAroundExpr(ty, result, pending_lets);
        return .{ .expr = result };
    }

    fn wrapPendingLetsAroundExpr(
        self: *Cloner,
        ty: Type.TypeId,
        body_expr: Ast.ExprId,
        pending_lets: []const PendingLet,
    ) Common.LowerError!Ast.ExprId {
        var result = body_expr;
        var index = pending_lets.len;
        while (index > 0) {
            index -= 1;
            const pending = pending_lets[index];
            const pat = try self.pass.program.addPat(.{
                .ty = pending.ty,
                .data = .{ .bind = pending.local },
            });
            result = try self.addExpr(.{ .ty = ty, .data = .{ .let_ = .{
                .bind = pat,
                .value = try self.pendingLetValueExpr(pending.value),
                .rest = result,
            } } });
        }
        return result;
    }

    fn pendingLetValueExpr(self: *Cloner, value: PendingLetValue) Common.LowerError!Ast.ExprId {
        return switch (value) {
            .source => |expr| try self.cloneExpr(expr),
            .cloned => |expr| expr,
        };
    }

    fn cloneCaseOfCaseValue(
        self: *Cloner,
        ty: Type.TypeId,
        scrutinee_expr: Ast.ExprId,
        outer_branches_span: Ast.Span(Ast.Branch),
    ) Common.LowerError!?Value {
        const scrutinee_data = self.pass.program.exprs.items[@intFromEnum(scrutinee_expr)].data;
        const inner_match = switch (scrutinee_data) {
            .match_ => |match| match,
            else => return null,
        };

        const outer_branches = self.pass.program.branchSpan(outer_branches_span);
        for (outer_branches) |branch| {
            if (branch.guard != null) return null;
        }

        const inner_branches = try self.pass.allocator.dupe(Ast.Branch, self.pass.program.branchSpan(inner_match.branches));
        defer self.pass.allocator.free(inner_branches);

        var rewritten = try self.pass.allocator.alloc(Ast.Branch, inner_branches.len);
        defer self.pass.allocator.free(rewritten);

        for (inner_branches, 0..) |inner_branch, index| {
            const inner_value = try self.cloneExprValue(inner_branch.body);
            const outer_value = (try self.simplifyKnownMatchValueMode(ty, inner_value, outer_branches_span, .speculative, true)) orelse return null;
            rewritten[index] = .{
                .pat = inner_branch.pat,
                .guard = inner_branch.guard,
                .body = try self.materialize(outer_value),
            };
        }

        return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .match_ = .{
            .scrutinee = inner_match.scrutinee,
            .branches = try self.pass.program.addBranchSpan(rewritten),
            .comptime_site = inner_match.comptime_site,
        } } }) };
    }

    fn inlineCallableCallValue(
        self: *Cloner,
        ty: Type.TypeId,
        callable: CallableValue,
        args_span: Ast.Span(Ast.ExprId),
        demand_result_known_value: bool,
    ) Common.LowerError!Value {
        for (self.inline_stack.items) |active| {
            if (active.fn_id == callable.fn_id) {
                return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                    .callee = try self.materialize(.{ .callable = callable }),
                    .args = try self.cloneExprSpan(args_span),
                } } }) };
            }
        }

        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const body = self.pass.originalBody(callable.fn_id) orelse switch (source_fn.body) {
            .roc => |body| body,
            .hosted => {
                return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                    .callee = try self.materialize(.{ .callable = callable }),
                    .args = try self.cloneExprSpan(args_span),
                } } }) };
            },
        };
        if (exprContainsReturn(self.pass.program, body)) {
            return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                .callee = try self.materialize(.{ .callable = callable }),
                .args = try self.cloneExprSpan(args_span),
            } } }) };
        }

        const source_args = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.args));
        defer self.pass.allocator.free(source_args);
        const args = try self.pass.allocator.dupe(Ast.ExprId, self.pass.program.exprSpan(args_span));
        defer self.pass.allocator.free(args);
        if (source_args.len != args.len) Common.invariant("callable call arity differed from lifted function arity");

        const source_captures = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.captures));
        defer self.pass.allocator.free(source_captures);
        if (source_captures.len != callable.captures.len) {
            Common.invariant("callable value capture count differed from lifted function capture count");
        }

        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        const change_start = self.changes.items.len;
        defer self.restore(change_start);

        const prepared_captures = try self.pass.allocator.alloc(Value, callable.captures.len);
        defer self.pass.allocator.free(prepared_captures);
        for (source_captures, callable.captures, 0..) |source_capture, capture_value, index| {
            prepared_captures[index] = try self.valueForInlineLocal(source_capture.local, capture_value, body, &pending_lets);
            try self.putSubst(source_capture.local, prepared_captures[index]);
        }

        const arg_values = try self.pass.allocator.alloc(Value, args.len);
        defer self.pass.allocator.free(arg_values);
        const callee_uses = if (@intFromEnum(callable.fn_id) < self.pass.plans.len)
            self.pass.plans[@intFromEnum(callable.fn_id)].used_args
        else
            &.{};
        const callee_demands = if (@intFromEnum(callable.fn_id) < self.pass.plans.len)
            self.pass.plans[@intFromEnum(callable.fn_id)].arg_demands
        else
            &.{};
        for (args, 0..) |arg_expr, index| {
            if (index < callee_uses.len and callee_uses[index]) {
                try self.noteLoopDemandIfLocalExpr(arg_expr, callee_demands[index]);
            }
            arg_values[index] = try self.cloneExprValue(arg_expr);
        }

        var unsafe_count: usize = 0;
        for (prepared_captures) |capture_value| unsafe_count += self.unsafeLeafCount(capture_value);
        for (arg_values) |arg_value| unsafe_count += self.unsafeLeafCount(arg_value);

        const prepared_args = try self.pass.allocator.alloc(Value, arg_values.len);
        defer self.pass.allocator.free(prepared_args);
        for (source_args, arg_values, 0..) |source_arg, arg_value, index| {
            prepared_args[index] = try self.valueForInlineLocal(source_arg.local, arg_value, body, &pending_lets);
        }

        try self.inline_stack.append(self.pass.allocator, .{ .fn_id = callable.fn_id });
        defer {
            const popped = self.inline_stack.pop() orelse Common.invariant("call-pattern inline stack underflow");
            if (popped.fn_id != callable.fn_id) Common.invariant("call-pattern inline stack was corrupted");
        }

        for (source_args, prepared_args, args) |source_arg, arg_value, arg_expr| {
            try self.putSubst(source_arg.local, arg_value);
            try self.appendLoopAliasForExpr(source_arg.local, arg_expr);
        }

        const body_value = if (demand_result_known_value)
            try self.cloneExprValueDemandingKnownValue(body)
        else
            try self.cloneExprValue(body);
        return try self.wrapPendingLets(body_value, pending_lets.items, demand_result_known_value);
    }

    fn callKnownValue(
        self: *Cloner,
        ty: Type.TypeId,
        callee: Value,
        args_span: Ast.Span(Ast.ExprId),
        demand_result_known_value: bool,
    ) Common.LowerError!Value {
        return switch (callee) {
            .callable => |callable| try self.inlineCallableCallValue(ty, callable, args_span, demand_result_known_value),
            .private_state => |private_state| if (privateStateCallable(private_state)) |callable|
                try self.inlinePrivateStateCallableCallValueWithDemand(ty, callable, args_span, .materialize)
            else if (privateStateFiniteCallables(private_state)) |finite_callables|
                try self.callPrivateStateFiniteCallablesValueWithDemand(ty, finite_callables, args_span, .materialize)
            else if (privateStateLeafExpr(private_state) != null)
                .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                    .callee = try self.materialize(callee),
                    .args = try self.cloneExprSpan(args_span),
                } } }) }
            else
                Common.invariant("non-callable private state reached callable call"),
            .finite_callables => |finite_callables| try self.callFiniteCallablesValue(ty, finite_callables, args_span, demand_result_known_value),
            .if_ => |if_value| try self.callIfValue(ty, if_value, args_span, demand_result_known_value),
            else => .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                .callee = try self.materialize(callee),
                .args = try self.cloneExprSpan(args_span),
            } } }) },
        };
    }

    fn callKnownValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        callee: Value,
        args_span: Ast.Span(Ast.ExprId),
        demand: ValueDemand,
    ) Common.LowerError!Value {
        return switch (callee) {
            .callable => |callable| try self.inlineCallableCallValueWithDemand(ty, callable, args_span, demand),
            .private_state => |private_state| if (privateStateCallable(private_state)) |callable|
                try self.inlinePrivateStateCallableCallValueWithDemand(ty, callable, args_span, demand)
            else if (privateStateFiniteCallables(private_state)) |finite_callables|
                try self.callPrivateStateFiniteCallablesValueWithDemand(ty, finite_callables, args_span, demand)
            else if (privateStateLeafExpr(private_state) != null)
                .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                    .callee = try self.materialize(callee),
                    .args = try self.cloneExprSpan(args_span),
                } } }) }
            else
                Common.invariant("non-callable private state reached callable call"),
            .finite_callables => |finite_callables| try self.callFiniteCallablesValueWithDemand(ty, finite_callables, args_span, demand),
            .if_ => |if_value| try self.callIfValueWithDemand(ty, if_value, args_span, demand),
            else => .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                .callee = try self.materialize(callee),
                .args = try self.cloneExprSpan(args_span),
            } } }) },
        };
    }

    fn inlinePrivateStateCallableCallValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        callable: PrivateStateCallable,
        args_span: Ast.Span(Ast.ExprId),
        demand: ValueDemand,
    ) Common.LowerError!Value {
        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const body = self.pass.originalBody(callable.fn_id) orelse switch (source_fn.body) {
            .roc => |body| body,
            .hosted => {
                if (privateStateCallableCanMaterializePublic(self.pass.program, callable)) {
                    return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                        .callee = try self.materialize(.{ .private_state = .{ .callable = callable } }),
                        .args = try self.cloneExprSpan(args_span),
                    } } }) };
                }
                Common.invariant("sparse private callable reached uninlinable hosted call");
            },
        };
        if (exprContainsReturn(self.pass.program, body)) {
            if (privateStateCallableCanMaterializePublic(self.pass.program, callable)) {
                return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                    .callee = try self.materialize(.{ .private_state = .{ .callable = callable } }),
                    .args = try self.cloneExprSpan(args_span),
                } } }) };
            }
            Common.invariant("sparse private callable reached uninlinable return-containing body");
        }

        const source_args = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.args));
        defer self.pass.allocator.free(source_args);
        const args = try self.pass.allocator.dupe(Ast.ExprId, self.pass.program.exprSpan(args_span));
        defer self.pass.allocator.free(args);
        if (source_args.len != args.len) Common.invariant("private callable call arity differed from lifted function arity");

        const source_captures = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.captures));
        defer self.pass.allocator.free(source_captures);
        for (callable.captures) |capture| {
            if (capture.index >= source_captures.len) Common.invariant("private callable capture index exceeded lifted function capture count");
        }

        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        const change_start = self.changes.items.len;
        defer self.restore(change_start);
        const provenance_start = self.loopProvenanceLen();
        defer self.restoreLoopProvenance(provenance_start);

        for (source_captures, 0..) |source_capture, index| {
            if (privateStateIndexedValueByIndex(callable.captures, @intCast(index))) |capture| {
                const prepared = try self.valueForInlineLocal(source_capture.local, .{ .private_state = capture }, body, &pending_lets);
                try self.putSubst(source_capture.local, prepared);
            } else {
                const capture_demand = if (demand == .none)
                    self.plannedLocalDemand(callable.fn_id, source_capture.local)
                else
                    try self.functionLocalDemand(callable.fn_id, source_capture.local, demand);
                if (capture_demand != .none and self.subst.get(source_capture.local) != null) continue;
                if (capture_demand != .none) {
                    Common.invariant("sparse private callable was missing a demanded capture");
                }
            }
        }

        const arg_values = try self.pass.allocator.alloc(Value, args.len);
        defer self.pass.allocator.free(arg_values);
        for (source_args, args, 0..) |source_arg, arg_expr, index| {
            const arg_demand = try self.functionLocalDemand(callable.fn_id, source_arg.local, demand);
            if (arg_demand != .none) {
                try self.noteLoopDemandIfLocalExpr(arg_expr, arg_demand);
                arg_values[index] = try self.cloneExprValueWithDemand(arg_expr, arg_demand);
            } else {
                arg_values[index] = try self.cloneExprValue(arg_expr);
            }
        }

        const prepared_args = try self.pass.allocator.alloc(Value, arg_values.len);
        defer self.pass.allocator.free(prepared_args);
        for (source_args, arg_values, 0..) |source_arg, arg_value, index| {
            prepared_args[index] = try self.valueForInlineLocal(source_arg.local, arg_value, body, &pending_lets);
        }

        try self.inline_stack.append(self.pass.allocator, .{ .fn_id = callable.fn_id });
        defer {
            const popped = self.inline_stack.pop() orelse Common.invariant("call-pattern inline stack underflow");
            if (popped.fn_id != callable.fn_id) Common.invariant("call-pattern inline stack was corrupted");
        }

        for (source_args, prepared_args, args) |source_arg, arg_value, arg_expr| {
            try self.putSubst(source_arg.local, arg_value);
            try self.appendLoopAliasForExpr(source_arg.local, arg_expr);
        }

        const body_value = try self.cloneExprValueWithDemand(body, demand);
        return try self.wrapPendingLets(body_value, pending_lets.items, demand != .none);
    }

    fn inlineCallableCallValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        callable: CallableValue,
        args_span: Ast.Span(Ast.ExprId),
        demand: ValueDemand,
    ) Common.LowerError!Value {
        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const body = self.pass.originalBody(callable.fn_id) orelse switch (source_fn.body) {
            .roc => |body| body,
            .hosted => {
                return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                    .callee = try self.materialize(.{ .callable = callable }),
                    .args = try self.cloneExprSpan(args_span),
                } } }) };
            },
        };
        if (exprContainsReturn(self.pass.program, body)) {
            return .{ .expr = try self.addExpr(.{ .ty = ty, .data = .{ .call_value = .{
                .callee = try self.materialize(.{ .callable = callable }),
                .args = try self.cloneExprSpan(args_span),
            } } }) };
        }

        const source_args = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.args));
        defer self.pass.allocator.free(source_args);
        const args = try self.pass.allocator.dupe(Ast.ExprId, self.pass.program.exprSpan(args_span));
        defer self.pass.allocator.free(args);
        if (source_args.len != args.len) Common.invariant("callable call arity differed from lifted function arity");

        const source_captures = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.captures));
        defer self.pass.allocator.free(source_captures);
        if (source_captures.len != callable.captures.len) {
            Common.invariant("callable value capture count differed from lifted function capture count");
        }

        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        const change_start = self.changes.items.len;
        defer self.restore(change_start);
        const provenance_start = self.loopProvenanceLen();
        defer self.restoreLoopProvenance(provenance_start);

        const prepared_captures = try self.pass.allocator.alloc(Value, callable.captures.len);
        defer self.pass.allocator.free(prepared_captures);
        for (source_captures, callable.captures, 0..) |source_capture, capture_value, index| {
            prepared_captures[index] = try self.valueForInlineLocal(source_capture.local, capture_value, body, &pending_lets);
            try self.putSubst(source_capture.local, prepared_captures[index]);
        }

        const arg_values = try self.pass.allocator.alloc(Value, args.len);
        defer self.pass.allocator.free(arg_values);
        for (source_args, args, 0..) |source_arg, arg_expr, index| {
            const arg_demand = try self.functionLocalDemand(callable.fn_id, source_arg.local, demand);
            if (arg_demand != .none) {
                try self.noteLoopDemandIfLocalExpr(arg_expr, arg_demand);
                arg_values[index] = try self.cloneExprValueWithDemand(arg_expr, arg_demand);
            } else {
                arg_values[index] = try self.cloneExprValue(arg_expr);
            }
        }

        const prepared_args = try self.pass.allocator.alloc(Value, arg_values.len);
        defer self.pass.allocator.free(prepared_args);
        for (source_args, arg_values, 0..) |source_arg, arg_value, index| {
            prepared_args[index] = try self.valueForInlineLocal(source_arg.local, arg_value, body, &pending_lets);
        }

        try self.inline_stack.append(self.pass.allocator, .{ .fn_id = callable.fn_id });
        defer {
            const popped = self.inline_stack.pop() orelse Common.invariant("call-pattern inline stack underflow");
            if (popped.fn_id != callable.fn_id) Common.invariant("call-pattern inline stack was corrupted");
        }

        for (source_args, prepared_args, args) |source_arg, arg_value, arg_expr| {
            try self.putSubst(source_arg.local, arg_value);
            try self.appendLoopAliasForExpr(source_arg.local, arg_expr);
        }

        const body_value = try self.cloneExprValueWithDemand(body, demand);
        return try self.wrapPendingLets(body_value, pending_lets.items, demand != .none);
    }

    fn callPrivateStateFiniteCallablesValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        finite_callables: PrivateStateFiniteCallables,
        args_span: Ast.Span(Ast.ExprId),
        demand: ValueDemand,
    ) Common.LowerError!Value {
        if (finite_callables.alternatives.len == 0) {
            Common.invariant("finite private callable value had no alternatives");
        }
        if (finite_callables.alternatives.len == 1) {
            return try self.inlinePrivateStateCallableCallValueWithDemand(ty, finite_callables.alternatives[0], args_span, demand);
        }

        const branch_count = finite_callables.alternatives.len - 1;
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, branch_count);
        for (finite_callables.alternatives[0..branch_count], branches, 0..) |alternative, *branch, index| {
            branch.* = .{
                .cond = try self.selectorEquals(finite_callables.selector, @intCast(index)),
                .body = try self.inlinePrivateStateCallableCallValueWithDemand(ty, alternative, args_span, demand),
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = try self.inlinePrivateStateCallableCallValueWithDemand(ty, finite_callables.alternatives[branch_count], args_span, demand);
        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn callFiniteCallablesValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        finite_callables: FiniteCallablesValue,
        args_span: Ast.Span(Ast.ExprId),
        demand: ValueDemand,
    ) Common.LowerError!Value {
        if (finite_callables.alternatives.len == 0) {
            Common.invariant("finite callable value had no alternatives");
        }
        if (finite_callables.alternatives.len == 1) {
            return try self.inlineCallableCallValueWithDemand(ty, finite_callables.alternatives[0], args_span, demand);
        }

        const branch_count = finite_callables.alternatives.len - 1;
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, branch_count);
        for (finite_callables.alternatives[0..branch_count], branches, 0..) |alternative, *branch, index| {
            branch.* = .{
                .cond = try self.selectorEquals(finite_callables.selector, @intCast(index)),
                .body = try self.inlineCallableCallValueWithDemand(ty, alternative, args_span, demand),
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = try self.inlineCallableCallValueWithDemand(ty, finite_callables.alternatives[branch_count], args_span, demand);
        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn callIfValueWithDemand(
        self: *Cloner,
        ty: Type.TypeId,
        if_value: IfValue,
        args_span: Ast.Span(Ast.ExprId),
        demand: ValueDemand,
    ) Common.LowerError!Value {
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
        for (if_value.branches, 0..) |branch, index| {
            branches[index] = .{
                .cond = branch.cond,
                .body = try self.callKnownValueWithDemand(ty, branch.body, args_span, demand),
            };
        }
        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = try self.callKnownValueWithDemand(ty, if_value.final_else.*, args_span, demand);
        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn privateStateCallableValue(self: *Cloner, value: PrivateStateValue) Common.LowerError!?CallableValue {
        return switch (value) {
            .callable => |callable| try self.privateStateCallableToCallableValue(callable),
            .nominal => |nominal| if (nominal.backing) |backing| try self.privateStateCallableValue(backing.*) else null,
            else => null,
        };
    }

    fn privateStateFiniteCallablesValue(self: *Cloner, value: PrivateStateValue) Common.LowerError!?FiniteCallablesValue {
        return switch (value) {
            .finite_callables => |finite_callables| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(CallableValue, finite_callables.alternatives.len);
                for (finite_callables.alternatives, alternatives) |alternative, *out| {
                    out.* = (try self.privateStateCallableToCallableValue(alternative)) orelse break :blk null;
                }
                break :blk FiniteCallablesValue{
                    .ty = finite_callables.ty,
                    .selector = finite_callables.selector,
                    .alternatives = alternatives,
                };
            },
            .nominal => |nominal| if (nominal.backing) |backing| try self.privateStateFiniteCallablesValue(backing.*) else null,
            else => null,
        };
    }

    fn privateStateCallableToCallableValue(self: *Cloner, callable: PrivateStateCallable) Common.LowerError!?CallableValue {
        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(source_fn.captures);
        const captures = try self.pass.arena.allocator().alloc(Value, source_captures.len);
        for (callable.captures) |capture| {
            if (capture.index >= source_captures.len) return null;
        }
        for (captures, 0..) |*out, index| {
            const capture = privateStateIndexedValueByIndex(callable.captures, @intCast(index)) orelse return null;
            out.* = .{ .private_state = capture };
        }
        return CallableValue{
            .ty = callable.ty,
            .fn_id = callable.fn_id,
            .captures = captures,
        };
    }

    fn privateStateIndexedValuesAsDenseValues(
        self: *Cloner,
        indexed: []const PrivateStateIndexedValue,
        expected_len: usize,
    ) Allocator.Error!?[]const Value {
        if (!privateStateIndexedValuesAreDense(indexed, expected_len)) return null;

        const values = try self.pass.arena.allocator().alloc(Value, expected_len);
        for (values, 0..) |*out, index| {
            const item = privateStateIndexedValueByIndex(indexed, @intCast(index)) orelse
                Common.invariant("dense private state index lookup failed");
            out.* = .{ .private_state = item };
        }
        return values;
    }

    fn callFiniteCallablesValue(
        self: *Cloner,
        ty: Type.TypeId,
        finite_callables: FiniteCallablesValue,
        args_span: Ast.Span(Ast.ExprId),
        demand_result_known_value: bool,
    ) Common.LowerError!Value {
        if (finite_callables.alternatives.len == 0) {
            Common.invariant("finite callable value had no alternatives");
        }
        if (finite_callables.alternatives.len == 1) {
            return try self.inlineCallableCallValue(ty, finite_callables.alternatives[0], args_span, demand_result_known_value);
        }

        const branch_count = finite_callables.alternatives.len - 1;
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, branch_count);
        for (finite_callables.alternatives[0..branch_count], branches, 0..) |alternative, *branch, index| {
            branch.* = .{
                .cond = try self.selectorEquals(finite_callables.selector, @intCast(index)),
                .body = try self.inlineCallableCallValue(ty, alternative, args_span, demand_result_known_value),
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = try self.inlineCallableCallValue(ty, finite_callables.alternatives[branch_count], args_span, demand_result_known_value);
        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn callIfValue(
        self: *Cloner,
        ty: Type.TypeId,
        if_value: IfValue,
        args_span: Ast.Span(Ast.ExprId),
        demand_result_known_value: bool,
    ) Common.LowerError!Value {
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, if_value.branches.len);
        for (if_value.branches, 0..) |branch, index| {
            branches[index] = .{
                .cond = branch.cond,
                .body = try self.callKnownValue(ty, branch.body, args_span, demand_result_known_value),
            };
        }
        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = try self.callKnownValue(ty, if_value.final_else.*, args_span, demand_result_known_value);
        return .{ .if_ = .{
            .ty = ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn inlineDirectCallValue(
        self: *Cloner,
        callee: Ast.FnId,
        args_span: Ast.Span(Ast.ExprId),
        original_expr: Ast.ExprId,
        demand_result_known_value: bool,
    ) Common.LowerError!Value {
        const active_arg_known_values = try self.directCallActiveArgKnownValues(args_span);
        for (self.inline_stack.items) |active| {
            if (active.fn_id != callee) continue;
            const active_args = active.args orelse return .{ .expr = try self.cloneExprPlain(original_expr) };
            if (!known_valuesStrictlyDescend(self.pass.program, active_args, active_arg_known_values)) {
                return .{ .expr = try self.cloneExprPlain(original_expr) };
            }
        }

        const source_fn = self.pass.program.fns.items[@intFromEnum(callee)];
        const body = self.pass.originalBody(callee) orelse switch (source_fn.body) {
            .roc => |body| body,
            .hosted => {
                return .{ .expr = try self.cloneExprPlain(original_expr) };
            },
        };
        if (exprContainsReturn(self.pass.program, body)) {
            return .{ .expr = try self.cloneExprPlain(original_expr) };
        }
        if (!self.directInlineCapturesAvailable(source_fn)) {
            return .{ .expr = try self.cloneExprPlain(original_expr) };
        }

        const source_args = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.args));
        defer self.pass.allocator.free(source_args);
        const args = try self.pass.allocator.dupe(Ast.ExprId, self.pass.program.exprSpan(args_span));
        defer self.pass.allocator.free(args);
        if (source_args.len != args.len) Common.invariant("direct call arity differed from lifted function arity");

        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        const change_start = self.changes.items.len;
        defer self.restore(change_start);
        const provenance_start = self.loopProvenanceLen();
        defer self.restoreLoopProvenance(provenance_start);

        const captures = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.captures));
        defer self.pass.allocator.free(captures);
        for (captures) |capture| {
            if (self.subst.get(capture.local)) |value| {
                try self.putSubst(capture.local, try self.makeReusableForMatch(value, &pending_lets));
            }
        }

        const arg_values = try self.pass.allocator.alloc(Value, args.len);
        defer self.pass.allocator.free(arg_values);
        const callee_uses = if (@intFromEnum(callee) < self.pass.plans.len)
            self.pass.plans[@intFromEnum(callee)].used_args
        else
            &.{};
        const callee_demands = if (@intFromEnum(callee) < self.pass.plans.len)
            self.pass.plans[@intFromEnum(callee)].arg_demands
        else
            &.{};
        for (args, 0..) |arg_expr, index| {
            if (index < callee_uses.len and callee_uses[index]) {
                try self.noteLoopDemandIfLocalExpr(arg_expr, callee_demands[index]);
            }
            arg_values[index] = if (index < callee_uses.len and callee_uses[index])
                try self.cloneExprValueDemandingKnownValue(arg_expr)
            else
                try self.cloneExprValue(arg_expr);
        }

        var unsafe_count: usize = 0;
        for (arg_values) |arg_value| unsafe_count += self.unsafeLeafCount(arg_value);
        for (captures) |capture| {
            if (self.subst.get(capture.local)) |value| unsafe_count += self.unsafeLeafCount(value);
        }

        const prepared_args = try self.pass.allocator.alloc(Value, arg_values.len);
        defer self.pass.allocator.free(prepared_args);
        for (source_args, arg_values, 0..) |source_arg, arg_value, index| {
            prepared_args[index] = try self.valueForInlineLocal(source_arg.local, arg_value, body, &pending_lets);
        }

        try self.inline_stack.append(self.pass.allocator, .{
            .fn_id = callee,
            .args = active_arg_known_values,
        });
        defer {
            const popped = self.inline_stack.pop() orelse Common.invariant("call-pattern inline stack underflow");
            if (popped.fn_id != callee) Common.invariant("call-pattern inline stack was corrupted");
        }

        for (source_args, prepared_args, args) |source_arg, arg_value, arg_expr| {
            try self.putSubst(source_arg.local, arg_value);
            try self.appendLoopAliasForExpr(source_arg.local, arg_expr);
        }

        const body_value = if (demand_result_known_value)
            try self.cloneExprValueDemandingKnownValue(body)
        else
            try self.cloneExprValue(body);
        return try self.wrapPendingLets(body_value, pending_lets.items, demand_result_known_value);
    }

    fn inlineDirectCallValueWithDemand(
        self: *Cloner,
        callee: Ast.FnId,
        args_span: Ast.Span(Ast.ExprId),
        original_expr: Ast.ExprId,
        demand: ValueDemand,
    ) Common.LowerError!Value {
        const active_arg_known_values = try self.directCallActiveArgKnownValues(args_span);
        for (self.inline_stack.items) |active| {
            if (active.fn_id != callee) continue;
            const active_args = active.args orelse return try self.directCallDemandFallback(original_expr, demand);
            if (!known_valuesStrictlyDescend(self.pass.program, active_args, active_arg_known_values)) {
                return try self.directCallDemandFallback(original_expr, demand);
            }
        }

        const source_fn = self.pass.program.fns.items[@intFromEnum(callee)];
        const body = self.pass.originalBody(callee) orelse switch (source_fn.body) {
            .roc => |body| body,
            .hosted => {
                return try self.directCallDemandFallback(original_expr, demand);
            },
        };
        if (exprContainsReturn(self.pass.program, body)) {
            return try self.directCallDemandFallback(original_expr, demand);
        }
        if (!self.directInlineCapturesAvailable(source_fn)) {
            return try self.directCallDemandFallback(original_expr, demand);
        }

        const source_args = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.args));
        defer self.pass.allocator.free(source_args);
        const args = try self.pass.allocator.dupe(Ast.ExprId, self.pass.program.exprSpan(args_span));
        defer self.pass.allocator.free(args);
        if (source_args.len != args.len) Common.invariant("direct call arity differed from lifted function arity");

        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        const change_start = self.changes.items.len;
        defer self.restore(change_start);

        const captures = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.captures));
        defer self.pass.allocator.free(captures);
        for (captures) |capture| {
            if (self.subst.get(capture.local)) |value| {
                try self.putSubst(capture.local, try self.makeReusableForMatch(value, &pending_lets));
            }
        }

        const arg_demands = try self.pass.allocator.alloc(ValueDemand, args.len);
        defer self.pass.allocator.free(arg_demands);
        @memset(arg_demands, .none);
        for (source_args, 0..) |source_arg, index| {
            arg_demands[index] = try self.functionLocalDemand(callee, source_arg.local, demand);
        }
        if (!self.demandStackContains(callee)) {
            const demand_change_start = self.changes.items.len;
            const demand_provenance_start = self.loopProvenanceLen();
            defer self.restoreLoopProvenance(demand_provenance_start);
            defer self.restore(demand_change_start);

            for (source_args, args) |source_arg, arg_expr| {
                try self.putSubst(source_arg.local, try self.exprValueForDemandNoInline(arg_expr));
                try self.appendLoopAliasForExpr(source_arg.local, arg_expr);
            }

            for (source_args, arg_demands) |source_arg, *arg_demand| {
                const observed = try self.localDemandInExpr(source_arg.local, body, demand);
                arg_demand.* = try self.pass.mergeValueDemand(arg_demand.*, observed);
            }
        }

        const arg_values = try self.pass.allocator.alloc(Value, args.len);
        defer self.pass.allocator.free(arg_values);
        for (args, 0..) |arg_expr, index| {
            const arg_demand = arg_demands[index];
            if (arg_demand != .none) {
                try self.noteLoopDemandIfLocalExpr(arg_expr, arg_demand);
                arg_values[index] = try self.cloneExprValueWithDemand(arg_expr, arg_demand);
            } else {
                arg_values[index] = try self.cloneExprValue(arg_expr);
            }
        }

        var unsafe_count: usize = 0;
        for (arg_values) |arg_value| unsafe_count += self.unsafeLeafCount(arg_value);
        for (captures) |capture| {
            if (self.subst.get(capture.local)) |value| unsafe_count += self.unsafeLeafCount(value);
        }

        const prepared_args = try self.pass.allocator.alloc(Value, arg_values.len);
        defer self.pass.allocator.free(prepared_args);
        for (source_args, arg_values, 0..) |source_arg, arg_value, index| {
            prepared_args[index] = try self.valueForInlineLocal(source_arg.local, arg_value, body, &pending_lets);
        }

        try self.inline_stack.append(self.pass.allocator, .{
            .fn_id = callee,
            .args = active_arg_known_values,
        });
        defer {
            const popped = self.inline_stack.pop() orelse Common.invariant("call-pattern inline stack underflow");
            if (popped.fn_id != callee) Common.invariant("call-pattern inline stack was corrupted");
        }

        for (source_args, prepared_args, args) |source_arg, arg_value, arg_expr| {
            try self.putSubst(source_arg.local, arg_value);
            try self.appendLoopAliasForExpr(source_arg.local, arg_expr);
        }

        const body_value = try self.cloneExprValueWithDemand(body, demand);
        return try self.wrapPendingLets(body_value, pending_lets.items, demand != .none);
    }

    fn directCallDemandFallback(
        self: *Cloner,
        original_expr: Ast.ExprId,
        demand: ValueDemand,
    ) Common.LowerError!Value {
        if (demand == .materialize) {
            return .{ .expr = try self.cloneExprPlain(original_expr) };
        }
        return try self.cloneExprValueDemandingKnownValue(original_expr);
    }

    fn directInlineCapturesAvailable(self: *Cloner, source_fn: Ast.Fn) bool {
        for (self.pass.program.typedLocalSpan(source_fn.captures)) |capture| {
            if (!self.subst.contains(capture.local)) return false;
        }
        return true;
    }

    fn fieldFromPatternValue(
        self: *Cloner,
        value: Value,
        field: names.RecordFieldNameId,
        ty: Type.TypeId,
    ) Common.LowerError!?Value {
        if (fieldFromValue(value, field)) |field_value| return field_value;
        if (value == .private_state) {
            if (privateStateField(value.private_state, field)) |field_value| {
                if (!sameType(self.pass.program, ty, privateStateValueType(field_value))) {
                    return null;
                }
                return Value{ .private_state = field_value };
            }
            if (privateStateLeafExpr(value.private_state)) |leaf_expr| {
                if (try self.fieldFromPrivateLeafExpr(leaf_expr, field)) |field_value| return field_value;
            }
        }

        const projected_from = try self.projectablePatternValue(value);
        const known_value = switch (projected_from) {
            .expr_with_known_value => |known| fieldKnownValueFromKnownValue(known.known_value, field),
            else => null,
        };
        const receiver = projectableExprFromValue(projected_from) orelse return null;
        if (!canReadFieldsFromExpr(self.pass.program, receiver)) return null;
        const field_expr = try self.addExpr(.{ .ty = ty, .data = .{ .field_access = .{
            .receiver = receiver,
            .field = field,
        } } });
        return if (known_value) |known|
            valueFromProjectedExpr(field_expr, known)
        else
            Value{ .expr = field_expr };
    }

    fn itemFromPatternValue(
        self: *Cloner,
        value: Value,
        index: u32,
        ty: Type.TypeId,
    ) Common.LowerError!?Value {
        if (itemFromValue(value, index)) |item_value| return item_value;
        if (value == .private_state) {
            if (privateStateItem(value.private_state, index)) |item_value| {
                if (!sameType(self.pass.program, ty, privateStateValueType(item_value))) return null;
                return Value{ .private_state = item_value };
            }
            if (privateStateLeafExpr(value.private_state)) |leaf_expr| {
                if (try self.itemFromPrivateLeafExpr(leaf_expr, index)) |item_value| return item_value;
            }
        }

        const projected_from = try self.projectablePatternValue(value);
        const known_value = switch (projected_from) {
            .expr_with_known_value => |known| itemKnownValueFromKnownValue(known.known_value, index),
            else => null,
        };
        const receiver = projectableExprFromValue(projected_from) orelse return null;
        if (!canReadFieldsFromExpr(self.pass.program, receiver)) return null;
        const item_expr = try self.addExpr(.{ .ty = ty, .data = .{ .tuple_access = .{
            .tuple = receiver,
            .elem_index = index,
        } } });
        return if (known_value) |known|
            valueFromProjectedExpr(item_expr, known)
        else
            Value{ .expr = item_expr };
    }

    fn projectablePatternValue(
        self: *Cloner,
        value: Value,
    ) Common.LowerError!Value {
        if (projectableExprFromValue(value)) |expr| {
            if (canReadFieldsFromExpr(self.pass.program, expr)) return value;
        }
        return value;
    }

    fn fieldFromPrivateLeafExpr(
        self: *Cloner,
        expr_id: Ast.ExprId,
        field: names.RecordFieldNameId,
    ) Common.LowerError!?Value {
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        const fields_span = switch (expr.data) {
            .record => |fields| fields,
            else => return null,
        };

        for (self.pass.program.fieldExprSpan(fields_span)) |field_expr| {
            if (field_expr.name != field) continue;
            return Value{ .private_state = .{ .leaf = .{
                .ty = self.pass.program.exprs.items[@intFromEnum(field_expr.value)].ty,
                .expr = field_expr.value,
            } } };
        }

        return null;
    }

    fn itemFromPrivateLeafExpr(
        self: *Cloner,
        expr_id: Ast.ExprId,
        index: u32,
    ) Common.LowerError!?Value {
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        const items_span = switch (expr.data) {
            .tuple => |items| items,
            else => return null,
        };
        const items = self.pass.program.exprSpan(items_span);
        if (index >= items.len) return null;
        return Value{ .private_state = .{ .leaf = .{
            .ty = self.pass.program.exprs.items[@intFromEnum(items[index])].ty,
            .expr = items[index],
        } } };
    }

    fn bindPatToValue(self: *Cloner, pat_id: Ast.PatId, value: Value) Common.LowerError!bool {
        const pat = self.pass.program.pats.items[@intFromEnum(pat_id)];
        switch (pat.data) {
            .bind => |local| {
                try self.putSubst(local, value);
                return true;
            },
            .wildcard => return true,
            .as => |as| {
                if (!try self.bindPatToValue(as.pattern, value)) return false;
                try self.putSubst(as.local, value);
                return true;
            },
            .record => |fields_span| {
                const fields = self.pass.program.recordDestructSpan(fields_span);
                if (recordFromValue(value)) |record| {
                    for (fields) |field| {
                        const field_value = fieldFromRecord(record, field.name) orelse return false;
                        if (!try self.bindPatToValue(field.pattern, field_value)) return false;
                    }
                    return true;
                }
                for (fields) |field| {
                    const field_ty = self.pass.program.pats.items[@intFromEnum(field.pattern)].ty;
                    const field_value = (try self.fieldFromPatternValue(value, field.name, field_ty)) orelse return false;
                    if (!try self.bindPatToValue(field.pattern, field_value)) return false;
                }
                return true;
            },
            .tuple => |items_span| {
                const pats = self.pass.program.patSpan(items_span);
                if (tupleFromValue(value)) |tuple| {
                    if (pats.len != tuple.items.len) return false;
                    for (pats, tuple.items) |child_pat, child_value| {
                        if (!try self.bindPatToValue(child_pat, child_value)) return false;
                    }
                    return true;
                }
                for (pats, 0..) |child_pat, index| {
                    const item_ty = self.pass.program.pats.items[@intFromEnum(child_pat)].ty;
                    const item_value = (try self.itemFromPatternValue(value, @intCast(index), item_ty)) orelse return false;
                    if (!try self.bindPatToValue(child_pat, item_value)) return false;
                }
                return true;
            },
            .tag => |tag_pat| {
                const pats = self.pass.program.patSpan(tag_pat.payloads);
                if (tagFromValue(value)) |tag| {
                    if (tag.name != tag_pat.name) return false;
                    if (pats.len != tag.payloads.len) return false;
                    for (pats, tag.payloads) |child_pat, child_value| {
                        if (!try self.bindPatToValue(child_pat, child_value)) return false;
                    }
                    return true;
                }

                const private_tag = switch (value) {
                    .private_state => |private_state| privateStateTag(private_state) orelse return false,
                    else => return false,
                };
                if (private_tag.name != tag_pat.name) {
                    return false;
                }
                for (pats, 0..) |child_pat, index| {
                    const child_value = privateStateIndexedValueByIndex(private_tag.payloads, @intCast(index)) orelse {
                        return false;
                    };
                    if (!try self.bindPatToValue(child_pat, .{ .private_state = child_value })) {
                        return false;
                    }
                }
                return true;
            },
            .nominal => |backing_pat| {
                const nominal = switch (value) {
                    .nominal => |nominal| nominal,
                    else => return false,
                };
                return try self.bindPatToValue(backing_pat, nominal.backing.*);
            },
            // List patterns are not statically bound during specialization.
            .list,
            .int_lit,
            .dec_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .str_lit,
            .str_pattern,
            => return false,
        }
    }

    fn bindPatToDemandedValue(
        self: *Cloner,
        pat_id: Ast.PatId,
        value: Value,
        demand: ValueDemand,
    ) Common.LowerError!bool {
        if (demand == .none) return true;
        if (demand == .materialize) return try self.bindPatToValue(pat_id, value);

        const pat = self.pass.program.pats.items[@intFromEnum(pat_id)];
        switch (pat.data) {
            .bind => |local| {
                try self.putSubst(local, value);
                return true;
            },
            .wildcard => return true,
            .as => |as| {
                if (!try self.bindPatToDemandedValue(as.pattern, value, demand)) return false;
                try self.putSubst(as.local, value);
                return true;
            },
            .record => |fields_span| {
                const field_demands = switch (demand) {
                    .record => |field_demands| field_demands,
                    else => return try self.bindPatToValue(pat_id, value),
                };
                for (self.pass.program.recordDestructSpan(fields_span)) |field| {
                    const field_demand = fieldDemandByName(field_demands, field.name) orelse continue;
                    const field_ty = self.pass.program.pats.items[@intFromEnum(field.pattern)].ty;
                    const field_value = (try self.fieldFromPatternValue(value, field.name, field_ty)) orelse return false;
                    if (!try self.bindPatToDemandedValue(field.pattern, field_value, field_demand.demand.*)) return false;
                }
                return true;
            },
            .tuple => |items_span| {
                const item_demands = switch (demand) {
                    .tuple => |item_demands| item_demands,
                    else => return try self.bindPatToValue(pat_id, value),
                };
                const pats = self.pass.program.patSpan(items_span);
                for (pats, 0..) |child_pat, index| {
                    const item_demand = itemDemandByIndex(item_demands, @intCast(index)) orelse continue;
                    const item_ty = self.pass.program.pats.items[@intFromEnum(child_pat)].ty;
                    const item_value = (try self.itemFromPatternValue(value, @intCast(index), item_ty)) orelse return false;
                    if (!try self.bindPatToDemandedValue(child_pat, item_value, item_demand.demand.*)) return false;
                }
                return true;
            },
            .tag => |tag_pat| {
                const tag_demand = switch (demand) {
                    .tag => |tag_demand| tag_demand,
                    else => return try self.bindPatToValue(pat_id, value),
                };
                if (!patternTagChoiceMatchesValue(self.pass.program, pat_id, value)) return false;
                const pats = self.pass.program.patSpan(tag_pat.payloads);
                for (pats, 0..) |child_pat, index| {
                    const payload_demand = itemDemandByIndex(tag_demand.payloads, @intCast(index)) orelse continue;
                    const payload_value = tagPayloadFromValue(value, @intCast(index)) orelse return false;
                    if (!try self.bindPatToDemandedValue(child_pat, payload_value, payload_demand.demand.*)) return false;
                }
                return true;
            },
            .nominal => |backing_pat| {
                const backing_demand = switch (demand) {
                    .nominal => |backing_demand| backing_demand.*,
                    else => return try self.bindPatToValue(pat_id, value),
                };
                const backing_value = switch (value) {
                    .nominal => |nominal| nominal.backing.*,
                    .private_state => |private_state| switch (private_state) {
                        .nominal => |nominal| if (nominal.backing) |backing| Value{ .private_state = backing.* } else return false,
                        else => value,
                    },
                    else => value,
                };
                return try self.bindPatToDemandedValue(backing_pat, backing_value, backing_demand);
            },
            .list,
            .int_lit,
            .dec_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .str_lit,
            .str_pattern,
            => return false,
        }
    }

    fn bindPatToReusableValue(self: *Cloner, pat_id: Ast.PatId, value: Value) Common.LowerError!bool {
        if (!self.valueCanSubstitute(value)) return false;
        return try self.bindPatToValue(pat_id, value);
    }

    fn bindPatToSingleUseTailValue(self: *Cloner, pat_id: Ast.PatId, value: Value, tail: BlockTail) Common.LowerError!bool {
        const pat = self.pass.program.pats.items[@intFromEnum(pat_id)];
        switch (pat.data) {
            .bind => |local| {
                const uses = localMaxUseCountPerPathInBlockTail(self.pass.program, local, tail);
                const before_effect = localUseBeforeEffectInBlockTail(self.pass.program, local, tail);
                if (uses != 1) return false;
                if (!before_effect) return false;
                try self.putSubst(local, value);
                return true;
            },
            .wildcard,
            .as,
            .record,
            .tuple,
            .list,
            .tag,
            .nominal,
            .int_lit,
            .dec_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .str_lit,
            .str_pattern,
            => return false,
        }
    }

    fn bindPatToSingleUseRestValue(self: *Cloner, pat_id: Ast.PatId, value: Value, rest: Ast.ExprId) Common.LowerError!bool {
        return try self.bindPatToSingleUseTailValue(pat_id, value, .{
            .statements = &.{},
            .final_expr = rest,
        });
    }

    fn bindPatToMaterializedKnownValue(self: *Cloner, pat_id: Ast.PatId, value: Value) Common.LowerError!bool {
        const known_value = (try self.pass.knownValueFromValue(value)) orelse return false;
        return try self.bindPatToExprWithKnownValueAndValue(pat_id, known_value, value);
    }

    fn bindPatToExprWithKnownValue(self: *Cloner, pat_id: Ast.PatId, known_value: KnownValue) Common.LowerError!bool {
        return try self.bindPatToExprWithKnownValueAndValue(pat_id, known_value, null);
    }

    fn bindPatToExprWithKnownValueAndValue(
        self: *Cloner,
        pat_id: Ast.PatId,
        known_value: KnownValue,
        maybe_value: ?Value,
    ) Common.LowerError!bool {
        const pat = self.pass.program.pats.items[@intFromEnum(pat_id)];
        switch (pat.data) {
            .bind => |local| {
                const local_ty = self.pass.program.locals.items[@intFromEnum(local)].ty;
                const local_expr = try self.addExpr(.{
                    .ty = local_ty,
                    .data = .{ .local = local },
                });
                try self.putSubst(local, .{ .expr_with_known_value = .{
                    .expr = local_expr,
                    .known_value = known_value,
                    .value = if (maybe_value) |value| try self.copyValue(value) else null,
                } });
                return true;
            },
            .wildcard => return true,
            .as => |as| {
                if (!try self.bindPatToExprWithKnownValueAndValue(as.pattern, known_value, maybe_value)) return false;
                const local_ty = self.pass.program.locals.items[@intFromEnum(as.local)].ty;
                const local_expr = try self.addExpr(.{
                    .ty = local_ty,
                    .data = .{ .local = as.local },
                });
                try self.putSubst(as.local, .{ .expr_with_known_value = .{
                    .expr = local_expr,
                    .known_value = known_value,
                    .value = if (maybe_value) |value| try self.copyValue(value) else null,
                } });
                return true;
            },
            .record => |fields_span| {
                const fields = self.pass.program.recordDestructSpan(fields_span);
                for (fields) |field| {
                    const field_known_value = fieldKnownValueFromKnownValue(known_value, field.name) orelse
                        KnownValue{ .any = self.pass.program.pats.items[@intFromEnum(field.pattern)].ty };
                    const field_value = if (maybe_value) |value| fieldFromValue(value, field.name) else null;
                    if (!try self.bindPatToExprWithKnownValueAndValue(field.pattern, field_known_value, field_value)) return false;
                }
                return true;
            },
            .tuple => |items_span| {
                const pats = self.pass.program.patSpan(items_span);
                for (pats, 0..) |child_pat, index| {
                    const item_known_value = itemKnownValueFromKnownValue(known_value, @as(u32, @intCast(index))) orelse
                        KnownValue{ .any = self.pass.program.pats.items[@intFromEnum(child_pat)].ty };
                    const item_value = if (maybe_value) |value| itemFromValue(value, @intCast(index)) else null;
                    if (!try self.bindPatToExprWithKnownValueAndValue(child_pat, item_known_value, item_value)) return false;
                }
                return true;
            },
            .tag => |tag_pat| {
                const pats = self.pass.program.patSpan(tag_pat.payloads);
                if (knownTagForPattern(known_value, tag_pat.name)) |tag_known_value| {
                    if (pats.len != tag_known_value.payloads.len) return false;
                    for (pats, tag_known_value.payloads, 0..) |child_pat, payload_known_value, index| {
                        const payload_value = if (maybe_value) |value| tagPayloadFromValue(value, @intCast(index)) else null;
                        if (!try self.bindPatToExprWithKnownValueAndValue(child_pat, payload_known_value, payload_value)) return false;
                    }
                } else {
                    for (pats, 0..) |child_pat, index| {
                        const payload_known_value = KnownValue{ .any = self.pass.program.pats.items[@intFromEnum(child_pat)].ty };
                        const payload_value = if (maybe_value) |value| tagPayloadFromValue(value, @intCast(index)) else null;
                        if (!try self.bindPatToExprWithKnownValueAndValue(child_pat, payload_known_value, payload_value)) return false;
                    }
                }
                return true;
            },
            .nominal => |backing_pat| {
                const backing_known_value = switch (known_value) {
                    .nominal => |nominal| nominal.backing.*,
                    else => KnownValue{ .any = self.pass.program.pats.items[@intFromEnum(backing_pat)].ty },
                };
                const backing_value = if (maybe_value) |value| switch (value) {
                    .nominal => |nominal| nominal.backing.*,
                    else => value,
                } else null;
                return try self.bindPatToExprWithKnownValueAndValue(backing_pat, backing_known_value, backing_value);
            },
            .list,
            .int_lit,
            .dec_lit,
            .frac_f32_lit,
            .frac_f64_lit,
            .str_lit,
            .str_pattern,
            => return false,
        }
    }

    fn clonePat(self: *Cloner, pat_id: Ast.PatId) Allocator.Error!Ast.PatId {
        const pat = self.pass.program.pats.items[@intFromEnum(pat_id)];
        const data: Ast.PatData = switch (pat.data) {
            .bind => |local| .{ .bind = local },
            .wildcard => .wildcard,
            .as => |as| .{ .as = .{
                .pattern = try self.clonePat(as.pattern),
                .local = as.local,
            } },
            .record => |fields| .{ .record = try self.cloneRecordDestructSpan(fields) },
            .tuple => |items| .{ .tuple = try self.clonePatSpan(items) },
            .list => |list| .{ .list = .{
                .patterns = try self.clonePatSpan(list.patterns),
                .rest = if (list.rest) |rest| .{
                    .index = rest.index,
                    .pattern = if (rest.pattern) |rest_pattern| try self.clonePat(rest_pattern) else null,
                } else null,
            } },
            .tag => |tag| .{ .tag = .{
                .name = tag.name,
                .payloads = try self.clonePatSpan(tag.payloads),
            } },
            .nominal => |backing| .{ .nominal = try self.clonePat(backing) },
            .int_lit => |value| .{ .int_lit = value },
            .dec_lit => |value| .{ .dec_lit = value },
            .frac_f32_lit => |value| .{ .frac_f32_lit = value },
            .frac_f64_lit => |value| .{ .frac_f64_lit = value },
            .str_lit => |value| .{ .str_lit = value },
            .str_pattern => |str| .{ .str_pattern = try self.cloneStrPattern(str) },
        };
        return try self.pass.program.addPat(.{ .ty = pat.ty, .data = data });
    }

    fn cloneStrPattern(self: *Cloner, str: Ast.StrPattern) Allocator.Error!Ast.StrPattern {
        const input_steps = self.pass.program.strPatternStepSpan(str.steps);
        const output_steps = try self.pass.allocator.alloc(Ast.StrPatternStep, input_steps.len);
        defer self.pass.allocator.free(output_steps);

        for (input_steps, output_steps) |input_step, *output_step| {
            output_step.* = .{
                .capture = if (input_step.capture) |capture| try self.clonePat(capture) else null,
                .delimiter = input_step.delimiter,
            };
        }

        return .{
            .prefix = str.prefix,
            .steps = try self.pass.program.addStrPatternStepSpan(output_steps),
            .end = str.end,
        };
    }

    fn cloneStmtInto(
        self: *Cloner,
        stmt_id: Ast.StmtId,
        out: *std.ArrayList(Ast.StmtId),
        tail: BlockTail,
        context: ValueDemand,
    ) Common.LowerError!void {
        const saved_loc = self.current_loc;
        defer self.current_loc = saved_loc;
        const saved_region = self.current_region;
        defer self.current_region = saved_region;
        self.current_loc = self.pass.program.stmtLoc(stmt_id);
        self.current_region = self.pass.program.stmtRegion(stmt_id);

        const stmt = self.pass.program.stmts.items[@intFromEnum(stmt_id)];
        const cloned: Ast.Stmt = switch (stmt) {
            .uninitialized => |pat| .{ .uninitialized = try self.clonePat(pat) },
            .let_ => |let_| blk: {
                const pattern_demand: ValueDemand = if (let_.recursive)
                    .materialize
                else
                    try self.patternDemandInBlockTail(let_.pat, tail, context);
                var value = if (let_.recursive)
                    try self.cloneExprValue(let_.value)
                else
                    try self.cloneExprValueWithDemand(let_.value, pattern_demand);
                if (!let_.recursive) {
                    while (value == .let_) {
                        try self.appendPendingLetStmts(value.let_.lets, out);
                        value = value.let_.body.*;
                    }

                    var pending_lets = std.ArrayList(PendingLet).empty;
                    defer pending_lets.deinit(self.pass.allocator);

                    const reusable = try self.makeReusableForMatch(value, &pending_lets);
                    const bind_change_start = self.changes.items.len;
                    if (try self.bindPatToReusableValue(let_.pat, reusable)) {
                        try self.appendPendingLetStmts(pending_lets.items, out);
                        return;
                    }
                    self.restore(bind_change_start);

                    if (try self.bindPatToSingleUseTailValue(let_.pat, value, tail)) {
                        return;
                    }
                    self.restore(bind_change_start);

                    if (try self.bindPatToDemandedValue(let_.pat, value, pattern_demand)) {
                        return;
                    }
                    self.restore(bind_change_start);
                }
                const value_expr = try self.materialize(value);
                if (!let_.recursive and try self.bindPatToReusableValue(let_.pat, value)) {
                    return;
                }
                _ = try self.bindPatToMaterializedKnownValue(let_.pat, value);
                break :blk .{ .let_ = .{
                    .pat = try self.clonePat(let_.pat),
                    .value = value_expr,
                    .recursive = let_.recursive,
                    .comptime_site = let_.comptime_site,
                } };
            },
            .expr => |expr| .{ .expr = try self.cloneStmtExpr(expr, context) },
            .expect => |expr| .{ .expect = try self.cloneExpr(expr) },
            .dbg => |expr| .{ .dbg = try self.cloneExpr(expr) },
            .return_ => |expr| .{ .return_ = try self.materialize(try self.cloneExprValueWithDemand(expr, context)) },
            .crash => |msg| .{ .crash = msg },
        };
        try out.append(self.pass.allocator, try self.addStmt(cloned));
    }

    fn cloneStmtExpr(self: *Cloner, expr_id: Ast.ExprId, context: ValueDemand) Common.LowerError!Ast.ExprId {
        const expr = self.pass.program.exprs.items[@intFromEnum(expr_id)];
        return switch (expr.data) {
            .break_,
            .return_,
            => try self.materialize(try self.cloneExprValueWithDemand(expr_id, context)),
            .comptime_branch_taken => |taken| try self.cloneStmtExpr(taken.body, context),
            else => if (exprContainsEscapingControlTransfer(self.pass.program, expr_id))
                try self.materialize(try self.cloneExprValueWithDemand(expr_id, context))
            else
                try self.cloneExpr(expr_id),
        };
    }

    fn appendPendingLetStmts(
        self: *Cloner,
        pending_lets: []const PendingLet,
        out: *std.ArrayList(Ast.StmtId),
    ) Common.LowerError!void {
        for (pending_lets) |pending| {
            const pat = try self.pass.program.addPat(.{
                .ty = pending.ty,
                .data = .{ .bind = pending.local },
            });
            try out.append(self.pass.allocator, try self.addStmt(.{ .let_ = .{
                .pat = pat,
                .value = try self.pendingLetValueExpr(pending.value),
                .recursive = false,
                .comptime_site = null,
            } }));
        }
    }

    fn bindPendingLetKnownValues(self: *Cloner, pending_lets: []const PendingLet) Common.LowerError!void {
        for (pending_lets) |pending| {
            const known_value = pending.known_value orelse continue;
            const local_expr = try self.addExpr(.{
                .ty = pending.ty,
                .data = .{ .local = pending.local },
            });
            try self.putSubst(pending.local, .{ .expr_with_known_value = .{
                .expr = local_expr,
                .known_value = known_value,
                .value = pending.structured_value,
            } });
        }
    }

    fn appendPendingLetsUnique(
        self: *Cloner,
        out: *std.ArrayList(PendingLet),
        pending_lets: []const PendingLet,
    ) Allocator.Error!void {
        for (pending_lets) |pending| {
            var seen = false;
            for (out.items) |existing| {
                if (existing.local == pending.local) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try out.append(self.pass.allocator, pending);
        }
    }

    fn appendPendingLetsFromStatements(
        self: *Cloner,
        statements: []const Ast.StmtId,
        out: *std.ArrayList(PendingLet),
    ) Allocator.Error!bool {
        for (statements) |stmt_id| {
            const stmt = self.pass.program.stmts.items[@intFromEnum(stmt_id)];
            const let_ = switch (stmt) {
                .let_ => |let_| let_,
                .expr => |expr| {
                    if (discardedExprIsEffectFree(self.pass.program, expr)) continue;
                    return false;
                },
                else => return false,
            };
            if (let_.recursive) return false;
            const pat = self.pass.program.pats.items[@intFromEnum(let_.pat)];
            const local = switch (pat.data) {
                .bind => |local| local,
                else => return false,
            };
            try out.append(self.pass.allocator, .{
                .local = local,
                .ty = pat.ty,
                .value = .{ .source = let_.value },
                .known_value = try self.pass.constructorKnownValue(let_.value),
            });
        }
        return true;
    }

    fn cloneExprSpan(self: *Cloner, span: Ast.Span(Ast.ExprId)) Common.LowerError!Ast.Span(Ast.ExprId) {
        const source = try self.pass.allocator.dupe(Ast.ExprId, self.pass.program.exprSpan(span));
        defer self.pass.allocator.free(source);

        const values = try self.pass.allocator.alloc(Ast.ExprId, source.len);
        defer self.pass.allocator.free(values);
        for (source, 0..) |expr, index| values[index] = try self.cloneExpr(expr);
        return try self.pass.program.addExprSpan(values);
    }

    fn clonePatSpan(self: *Cloner, span: Ast.Span(Ast.PatId)) Allocator.Error!Ast.Span(Ast.PatId) {
        const source = try self.pass.allocator.dupe(Ast.PatId, self.pass.program.patSpan(span));
        defer self.pass.allocator.free(source);

        const values = try self.pass.allocator.alloc(Ast.PatId, source.len);
        defer self.pass.allocator.free(values);
        for (source, 0..) |pat, index| values[index] = try self.clonePat(pat);
        return try self.pass.program.addPatSpan(values);
    }

    fn cloneFieldExprSpan(self: *Cloner, span: Ast.Span(Ast.FieldExpr)) Common.LowerError!Ast.Span(Ast.FieldExpr) {
        const source = try self.pass.allocator.dupe(Ast.FieldExpr, self.pass.program.fieldExprSpan(span));
        defer self.pass.allocator.free(source);

        const values = try self.pass.allocator.alloc(Ast.FieldExpr, source.len);
        defer self.pass.allocator.free(values);
        for (source, 0..) |field, index| {
            values[index] = .{
                .name = field.name,
                .value = try self.cloneExpr(field.value),
            };
        }
        return try self.pass.program.addFieldExprSpan(values);
    }

    fn cloneRecordDestructSpan(self: *Cloner, span: Ast.Span(Ast.RecordDestruct)) Allocator.Error!Ast.Span(Ast.RecordDestruct) {
        const source = try self.pass.allocator.dupe(Ast.RecordDestruct, self.pass.program.recordDestructSpan(span));
        defer self.pass.allocator.free(source);

        const values = try self.pass.allocator.alloc(Ast.RecordDestruct, source.len);
        defer self.pass.allocator.free(values);
        for (source, 0..) |field, index| {
            values[index] = .{
                .name = field.name,
                .pattern = try self.clonePat(field.pattern),
            };
        }
        return try self.pass.program.addRecordDestructSpan(values);
    }

    fn cloneBranchSpanWithScrutineeKnownValue(
        self: *Cloner,
        span: Ast.Span(Ast.Branch),
        scrutinee_known_value: ?KnownValue,
    ) Common.LowerError!Ast.Span(Ast.Branch) {
        const source = try self.pass.allocator.dupe(Ast.Branch, self.pass.program.branchSpan(span));
        defer self.pass.allocator.free(source);

        var values = std.ArrayList(Ast.Branch).empty;
        defer values.deinit(self.pass.allocator);
        for (source) |branch| {
            if (scrutinee_known_value) |known_value| {
                if (patternDefinitelyExcludedByKnownValue(self.pass.program, branch.pat, known_value)) continue;
            }
            const change_start = self.changes.items.len;
            if (scrutinee_known_value) |known_value| {
                _ = try self.bindPatToExprWithKnownValue(branch.pat, known_value);
            }
            try values.append(self.pass.allocator, .{
                .pat = try self.clonePat(branch.pat),
                .guard = if (branch.guard) |guard| try self.cloneExpr(guard) else null,
                .body = try self.cloneExpr(branch.body),
            });
            self.restore(change_start);
        }
        return try self.pass.program.addBranchSpan(values.items);
    }

    fn cloneIfBranchSpan(self: *Cloner, span: Ast.Span(Ast.IfBranch)) Common.LowerError!Ast.Span(Ast.IfBranch) {
        const source = try self.pass.allocator.dupe(Ast.IfBranch, self.pass.program.ifBranchSpan(span));
        defer self.pass.allocator.free(source);

        const values = try self.pass.allocator.alloc(Ast.IfBranch, source.len);
        defer self.pass.allocator.free(values);
        for (source, 0..) |branch, index| {
            const change_start = self.changes.items.len;
            values[index] = .{
                .cond = try self.cloneExpr(branch.cond),
                .body = try self.cloneExpr(branch.body),
            };
            self.restore(change_start);
        }
        return try self.pass.program.addIfBranchSpan(values);
    }

    fn cloneStateLoopStateSpan(self: *Cloner, span: Ast.Span(Ast.StateLoopState)) Common.LowerError!Ast.Span(Ast.StateLoopState) {
        const source = try self.pass.allocator.dupe(Ast.StateLoopState, self.pass.program.stateLoopStateSpan(span));
        defer self.pass.allocator.free(source);

        const start: u32 = @intCast(self.pass.program.state_loop_states.items.len);
        try self.pass.program.state_loop_states.ensureUnusedCapacity(self.pass.program.allocator, source.len);
        for (source, 0..) |_, index| {
            const old_id: Ast.StateLoopStateId = @enumFromInt(span.start + @as(u32, @intCast(index)));
            const new_id: Ast.StateLoopStateId = @enumFromInt(start + @as(u32, @intCast(index)));
            try self.state_loop_state_map.put(old_id, new_id);
            self.pass.program.state_loop_states.appendAssumeCapacity(undefined);
        }

        for (source, 0..) |state, index| {
            self.pass.program.state_loop_states.items[start + index] = .{
                .params = state.params,
                .body = try self.cloneExpr(state.body),
            };
        }

        return .{ .start = start, .len = @intCast(source.len) };
    }

    fn cloneStateLoopStateId(self: *Cloner, id: Ast.StateLoopStateId) Ast.StateLoopStateId {
        return self.state_loop_state_map.get(id) orelse
            Common.invariant("state_continue reached SpecConstr clone before its state_loop reserved the target state");
    }

    fn materialize(self: *Cloner, value: Value) Common.LowerError!Ast.ExprId {
        switch (value) {
            .expr => |expr| return expr,
            .expr_with_known_value => |known_value_expr| return known_value_expr.expr,
            .let_ => |let_value| {
                const body = try self.materialize(let_value.body.*);
                return try self.wrapPendingLetsAroundExpr(valueType(self.pass.program, let_value.body.*), body, let_value.lets);
            },
            .if_ => |if_value| {
                const branches = try self.pass.allocator.alloc(Ast.IfBranch, if_value.branches.len);
                defer self.pass.allocator.free(branches);
                for (if_value.branches, 0..) |branch, index| {
                    branches[index] = .{
                        .cond = branch.cond,
                        .body = try self.materialize(branch.body),
                    };
                }
                return try self.addExpr(.{ .ty = if_value.ty, .data = .{ .if_ = .{
                    .branches = try self.pass.program.addIfBranchSpan(branches),
                    .final_else = try self.materialize(if_value.final_else.*),
                } } });
            },
            .match_ => |match_value| {
                const branches = try self.pass.allocator.alloc(Ast.Branch, match_value.branches.len);
                defer self.pass.allocator.free(branches);
                for (match_value.branches, 0..) |branch, index| {
                    branches[index] = .{
                        .pat = branch.pat,
                        .guard = branch.guard,
                        .body = try self.materialize(branch.body),
                    };
                }
                return try self.addExpr(.{ .ty = match_value.ty, .data = .{ .match_ = .{
                    .scrutinee = match_value.scrutinee,
                    .branches = try self.pass.program.addBranchSpan(branches),
                    .comptime_site = match_value.comptime_site,
                } } });
            },
            .tag => |tag| {
                const payloads = try self.pass.allocator.alloc(Ast.ExprId, tag.payloads.len);
                defer self.pass.allocator.free(payloads);
                for (tag.payloads, 0..) |payload, index| {
                    payloads[index] = try self.materialize(payload);
                }
                return try self.addExpr(.{ .ty = tag.ty, .data = .{ .tag = .{
                    .name = tag.name,
                    .payloads = try self.pass.program.addExprSpan(payloads),
                } } });
            },
            .record => |record| {
                const fields = try self.pass.allocator.alloc(Ast.FieldExpr, record.fields.len);
                defer self.pass.allocator.free(fields);
                for (record.fields, 0..) |field, index| {
                    fields[index] = .{
                        .name = field.name,
                        .value = try self.materialize(field.value),
                    };
                }
                return try self.addExpr(.{ .ty = record.ty, .data = .{
                    .record = try self.pass.program.addFieldExprSpan(fields),
                } });
            },
            .tuple => |tuple| {
                const items = try self.pass.allocator.alloc(Ast.ExprId, tuple.items.len);
                defer self.pass.allocator.free(items);
                for (tuple.items, 0..) |item, index| {
                    items[index] = try self.materialize(item);
                }
                return try self.addExpr(.{ .ty = tuple.ty, .data = .{
                    .tuple = try self.pass.program.addExprSpan(items),
                } });
            },
            .nominal => |nominal| return try self.addExpr(.{ .ty = nominal.ty, .data = .{
                .nominal = try self.materialize(nominal.backing.*),
            } }),
            .callable => |callable| return try self.materializeCallable(callable),
            .finite_tags => |finite_tags| return try self.materialize(try self.finiteTagsAsIfValue(finite_tags)),
            .finite_callables => |finite_callables| return try self.materialize(try self.finiteCallablesAsIfValue(finite_callables)),
            .private_state => |private_state| {
                if (!privateStateCanMaterializePublic(self.pass.program, private_state)) {
                    Common.invariant("sparse private state reached materialization");
                }
                return try self.materialize(try self.publicValueFromPrivateState(private_state));
            },
        }
    }

    fn materializePublic(self: *Cloner, value: Value) Common.LowerError!Ast.ExprId {
        switch (value) {
            .expr => |expr| return expr,
            .expr_with_known_value => |known_value_expr| return known_value_expr.expr,
            .let_ => |let_value| {
                const body = try self.materializePublic(let_value.body.*);
                return try self.wrapPendingLetsAroundExpr(valueType(self.pass.program, let_value.body.*), body, let_value.lets);
            },
            .if_ => |if_value| {
                const branches = try self.pass.allocator.alloc(Ast.IfBranch, if_value.branches.len);
                defer self.pass.allocator.free(branches);
                for (if_value.branches, 0..) |branch, index| {
                    branches[index] = .{
                        .cond = branch.cond,
                        .body = try self.materializePublic(branch.body),
                    };
                }
                return try self.addExpr(.{ .ty = if_value.ty, .data = .{ .if_ = .{
                    .branches = try self.pass.program.addIfBranchSpan(branches),
                    .final_else = try self.materializePublic(if_value.final_else.*),
                } } });
            },
            .match_ => |match_value| {
                const branches = try self.pass.allocator.alloc(Ast.Branch, match_value.branches.len);
                defer self.pass.allocator.free(branches);
                for (match_value.branches, 0..) |branch, index| {
                    branches[index] = .{
                        .pat = branch.pat,
                        .guard = branch.guard,
                        .body = try self.materializePublic(branch.body),
                    };
                }
                return try self.addExpr(.{ .ty = match_value.ty, .data = .{ .match_ = .{
                    .scrutinee = match_value.scrutinee,
                    .branches = try self.pass.program.addBranchSpan(branches),
                    .comptime_site = match_value.comptime_site,
                } } });
            },
            .tag => |tag| {
                const payloads = try self.pass.allocator.alloc(Ast.ExprId, tag.payloads.len);
                defer self.pass.allocator.free(payloads);
                for (tag.payloads, 0..) |payload, index| {
                    payloads[index] = try self.materializePublic(payload);
                }
                return try self.addExpr(.{ .ty = tag.ty, .data = .{ .tag = .{
                    .name = tag.name,
                    .payloads = try self.pass.program.addExprSpan(payloads),
                } } });
            },
            .record => |record| {
                const fields = try self.pass.allocator.alloc(Ast.FieldExpr, record.fields.len);
                defer self.pass.allocator.free(fields);
                for (record.fields, 0..) |field, index| {
                    fields[index] = .{
                        .name = field.name,
                        .value = try self.materializePublic(field.value),
                    };
                }
                return try self.addExpr(.{ .ty = record.ty, .data = .{
                    .record = try self.pass.program.addFieldExprSpan(fields),
                } });
            },
            .tuple => |tuple| {
                const items = try self.pass.allocator.alloc(Ast.ExprId, tuple.items.len);
                defer self.pass.allocator.free(items);
                for (tuple.items, 0..) |item, index| {
                    items[index] = try self.materializePublic(item);
                }
                return try self.addExpr(.{ .ty = tuple.ty, .data = .{
                    .tuple = try self.pass.program.addExprSpan(items),
                } });
            },
            .nominal => |nominal| return try self.addExpr(.{ .ty = nominal.ty, .data = .{
                .nominal = try self.materializePublic(nominal.backing.*),
            } }),
            .callable => |callable| return try self.materializePublicCallable(callable),
            .finite_tags => |finite_tags| return try self.materializePublic(try self.finiteTagsAsIfValue(finite_tags)),
            .finite_callables => |finite_callables| return try self.materializePublic(try self.finiteCallablesAsIfValue(finite_callables)),
            .private_state => |private_state| return try self.materializePublic(try self.publicValueFromPrivateState(private_state)),
        }
    }

    fn publicValueFromPrivateState(self: *Cloner, private_state: PrivateStateValue) Common.LowerError!Value {
        return switch (private_state) {
            .leaf => |leaf| .{ .expr = leaf.expr },
            .tag => |tag| .{ .tag = try self.publicTagValueFromPrivateState(tag) },
            .record => |record| blk: {
                if (!privateStateRecordIsDense(self.pass.program, record)) {
                    Common.invariant("sparse private record reached public materialization");
                }
                const fields = try self.pass.arena.allocator().alloc(FieldValue, record.fields.len);
                for (record.fields, fields) |field, *out| {
                    out.* = .{
                        .name = field.name,
                        .value = .{ .private_state = field.value },
                    };
                }
                break :blk Value{ .record = .{
                    .ty = record.ty,
                    .fields = fields,
                } };
            },
            .tuple => |tuple| .{ .tuple = .{
                .ty = tuple.ty,
                .items = (try self.privateStateIndexedValuesAsDenseValues(tuple.items, tupleTypeItems(self.pass.program, tuple.ty).len)) orelse
                    Common.invariant("sparse private tuple reached public materialization"),
            } },
            .nominal => |nominal| blk: {
                const backing = nominal.backing orelse
                    Common.invariant("sparse private nominal reached public materialization");
                const value = try self.pass.arena.allocator().create(Value);
                value.* = .{ .private_state = backing.* };
                break :blk Value{ .nominal = .{
                    .ty = nominal.ty,
                    .backing = value,
                } };
            },
            .callable => |callable| .{ .callable = try self.publicCallableValueFromPrivateState(callable) },
            .finite_tags => |finite_tags| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(TagValue, finite_tags.alternatives.len);
                for (finite_tags.alternatives, alternatives) |alternative, *out| {
                    out.* = try self.publicTagValueFromPrivateState(alternative);
                }
                break :blk Value{ .finite_tags = .{
                    .ty = finite_tags.ty,
                    .selector = finite_tags.selector,
                    .alternatives = alternatives,
                } };
            },
            .finite_callables => |finite_callables| blk: {
                const alternatives = try self.pass.arena.allocator().alloc(CallableValue, finite_callables.alternatives.len);
                for (finite_callables.alternatives, alternatives) |alternative, *out| {
                    out.* = try self.publicCallableValueFromPrivateState(alternative);
                }
                break :blk Value{ .finite_callables = .{
                    .ty = finite_callables.ty,
                    .selector = finite_callables.selector,
                    .alternatives = alternatives,
                } };
            },
        };
    }

    fn publicTagValueFromPrivateState(self: *Cloner, tag: PrivateStateTag) Common.LowerError!TagValue {
        const expected_payloads = tagTypePayloads(self.pass.program, tag.ty, tag.name) orelse
            Common.invariant("private tag referenced a tag absent from its type");
        return .{
            .ty = tag.ty,
            .name = tag.name,
            .payloads = (try self.privateStateIndexedValuesAsDenseValues(tag.payloads, expected_payloads.len)) orelse
                Common.invariant("sparse private tag reached public materialization"),
        };
    }

    fn publicCallableValueFromPrivateState(self: *Cloner, callable: PrivateStateCallable) Common.LowerError!CallableValue {
        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(source_fn.captures);
        const captures = try self.pass.arena.allocator().alloc(Value, source_captures.len);
        const seen = try self.pass.allocator.alloc(bool, source_captures.len);
        defer self.pass.allocator.free(seen);
        @memset(seen, false);

        for (callable.captures) |capture| {
            if (capture.index >= source_captures.len) {
                Common.invariant("private callable capture index exceeded public capture count");
            }
            captures[capture.index] = .{ .private_state = capture.value };
            seen[capture.index] = true;
        }

        for (seen) |capture_seen| {
            if (!capture_seen) Common.invariant("sparse private callable reached public materialization");
        }

        return .{
            .ty = callable.ty,
            .fn_id = callable.fn_id,
            .captures = captures,
        };
    }

    fn materializePublicCallable(self: *Cloner, callable: CallableValue) Common.LowerError!Ast.ExprId {
        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        return try self.materializeCallableWithCaptures(
            callable.ty,
            callable.fn_id,
            source_fn.captures,
            callable.captures,
        );
    }

    fn finiteTagsAsIfValue(self: *Cloner, finite_tags: FiniteTagsValue) Common.LowerError!Value {
        if (finite_tags.alternatives.len == 0) {
            Common.invariant("finite tag value had no alternatives");
        }
        if (finite_tags.alternatives.len == 1) {
            return .{ .tag = finite_tags.alternatives[0] };
        }

        const branch_count = finite_tags.alternatives.len - 1;
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, branch_count);
        for (finite_tags.alternatives[0..branch_count], branches, 0..) |alternative, *branch, index| {
            branch.* = .{
                .cond = try self.selectorEquals(finite_tags.selector, @intCast(index)),
                .body = .{ .tag = alternative },
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = .{ .tag = finite_tags.alternatives[branch_count] };
        return .{ .if_ = .{
            .ty = finite_tags.ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn finiteCallablesAsIfValue(self: *Cloner, finite_callables: FiniteCallablesValue) Common.LowerError!Value {
        if (finite_callables.alternatives.len == 0) {
            Common.invariant("finite callable value had no alternatives");
        }
        if (finite_callables.alternatives.len == 1) {
            return .{ .callable = finite_callables.alternatives[0] };
        }

        const branch_count = finite_callables.alternatives.len - 1;
        const branches = try self.pass.arena.allocator().alloc(IfValueBranch, branch_count);
        for (finite_callables.alternatives[0..branch_count], branches, 0..) |alternative, *branch, index| {
            branch.* = .{
                .cond = try self.selectorEquals(finite_callables.selector, @intCast(index)),
                .body = .{ .callable = alternative },
            };
        }

        const final_else = try self.pass.arena.allocator().create(Value);
        final_else.* = .{ .callable = finite_callables.alternatives[branch_count] };
        return .{ .if_ = .{
            .ty = finite_callables.ty,
            .branches = branches,
            .final_else = final_else,
        } };
    }

    fn materializeCallable(self: *Cloner, callable: CallableValue) Common.LowerError!Ast.ExprId {
        const fn_ = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const captures = self.pass.program.typedLocalSpan(fn_.captures);
        if (captures.len != callable.captures.len) {
            Common.invariant("callable value capture count differed from lifted function capture count");
        }

        var all_original = true;
        for (captures, callable.captures) |capture, value| {
            const expr = switch (value) {
                .expr => |expr| expr,
                else => {
                    all_original = false;
                    break;
                },
            };
            const local = localExpr(self.pass.program, expr) orelse {
                all_original = false;
                break;
            };
            if (local != capture.local) {
                all_original = false;
                break;
            }
        }

        if (!all_original) {
            return try self.specializedCallableRef(callable);
        }

        return try self.addExpr(.{ .ty = callable.ty, .data = .{ .fn_ref = callable.fn_id } });
    }

    fn specializedCallableRef(self: *Cloner, callable: CallableValue) Common.LowerError!Ast.ExprId {
        const capture_patterns = try self.callableCapturePatterns(callable);
        if (self.existingCallableSpecialization(callable.fn_id, capture_patterns)) |existing| {
            const existing_fn = self.pass.program.fns.items[@intFromEnum(existing)];
            return try self.materializeCallableWithCapturePatterns(
                callable.ty,
                existing,
                existing_fn.captures,
                capture_patterns,
                callable.captures,
            );
        }

        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const source_body = self.pass.originalBody(callable.fn_id) orelse switch (source_fn.body) {
            .roc => |body| body,
            .hosted => Common.invariant("hosted callable value needed capture substitution"),
        };

        const source_captures = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.captures));
        defer self.pass.allocator.free(source_captures);
        if (source_captures.len != callable.captures.len) {
            Common.invariant("callable value capture count differed from lifted function capture count");
        }

        var captures = std.ArrayList(Ast.TypedLocal).empty;
        defer captures.deinit(self.pass.allocator);

        const capture_values = try self.pass.allocator.alloc(?PrivateStateValue, capture_patterns.len);
        defer self.pass.allocator.free(capture_values);
        @memset(capture_values, null);

        const change_start = self.changes.items.len;
        defer self.restore(change_start);

        for (capture_patterns, capture_values) |capture_pattern, *capture_value| {
            if (capture_pattern) |pattern| {
                capture_value.* = try self.privateStateValueFromDemandedKnownValueArgs(pattern, &captures);
            }
        }

        const captures_span = try self.pass.program.addTypedLocalSpan(captures.items);

        const source_args = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(source_fn.args));
        defer self.pass.allocator.free(source_args);
        const args = try self.pass.allocator.alloc(Ast.TypedLocal, source_args.len);
        defer self.pass.allocator.free(args);
        for (source_args, 0..) |source_arg, index| {
            const local = try self.pass.program.addLocal(self.pass.symbols.fresh(), source_arg.ty);
            args[index] = .{ .local = local, .ty = source_arg.ty };
        }
        const args_span = try self.pass.program.addTypedLocalSpan(args);

        const fn_id: Ast.FnId = @enumFromInt(@as(u32, @intCast(self.pass.program.fns.items.len)));
        const symbol = self.pass.symbols.fresh();
        try self.pass.program.fns.append(self.pass.allocator, .{
            .symbol = symbol,
            .source = source_fn.source,
            .args = args_span,
            .captures = captures_span,
            .body = .hosted,
            .ret = source_fn.ret,
        });
        try self.pass.callable_specializations.append(self.pass.allocator, .{
            .source_fn = callable.fn_id,
            .captures = capture_patterns,
            .fn_id = fn_id,
        });
        try self.pass.copyProcDebugName(source_fn.symbol, symbol);

        const result = try self.materializeCallableWithCapturePatterns(
            callable.ty,
            fn_id,
            captures_span,
            capture_patterns,
            callable.captures,
        );

        var body_cloner = Cloner.initForBaseBody(self.pass, callable.fn_id);
        defer body_cloner.deinit();

        for (source_captures, capture_values) |source_capture, capture_value| {
            if (capture_value) |value| {
                try body_cloner.putSubst(source_capture.local, .{ .private_state = value });
            }
        }

        for (source_args, args) |source_arg, arg| {
            const arg_expr = try self.addExpr(.{
                .ty = arg.ty,
                .data = .{ .local = arg.local },
            });
            try body_cloner.putSubst(source_arg.local, .{ .expr = arg_expr });
        }

        const cloned_body = try body_cloner.cloneExpr(source_body);
        self.pass.program.fns.items[@intFromEnum(fn_id)] = .{
            .symbol = symbol,
            .source = source_fn.source,
            .args = args_span,
            .captures = captures_span,
            .body = .{ .roc = cloned_body },
            .ret = source_fn.ret,
        };

        return result;
    }

    fn callableCapturePatterns(self: *Cloner, callable: CallableValue) Common.LowerError![]const ?DemandedKnownValue {
        const source_fn = self.pass.program.fns.items[@intFromEnum(callable.fn_id)];
        const source_captures = self.pass.program.typedLocalSpan(source_fn.captures);
        if (source_captures.len != callable.captures.len) {
            Common.invariant("callable value capture count differed from lifted function capture count");
        }

        const captures = try self.pass.arena.allocator().alloc(?DemandedKnownValue, callable.captures.len);
        for (source_captures, callable.captures, captures) |source_capture, capture, *out| {
            const demand = try self.functionLocalDemand(callable.fn_id, source_capture.local, .materialize);
            if (demand == .none) {
                out.* = null;
                continue;
            }

            if (try self.demandedKnownValueFromValueDemand(capture, demand)) |pattern| {
                out.* = pattern;
                continue;
            }

            if (capture == .private_state and !privateStateCanMaterializePublic(self.pass.program, capture.private_state)) {
                Common.invariant("sparse callable capture could not satisfy demanded callable specialization");
            }

            const known_value = (try self.pass.knownValueFromValue(capture)) orelse
                KnownValue{ .any = valueType(self.pass.program, capture) };
            out.* = try materializedDemandedKnownValue(self.pass.arena.allocator(), known_value);
        }
        return captures;
    }

    fn existingCallableSpecialization(
        self: *Cloner,
        source_fn: Ast.FnId,
        capture_patterns: []const ?DemandedKnownValue,
    ) ?Ast.FnId {
        for (self.pass.callable_specializations.items) |specialization| {
            if (specialization.source_fn != source_fn) continue;
            if (specialization.captures.len != capture_patterns.len) continue;
            var matches = true;
            for (specialization.captures, capture_patterns) |existing, requested| {
                if (existing == null or requested == null) {
                    if (existing != null or requested != null) {
                        matches = false;
                        break;
                    }
                    continue;
                }
                if (!demandedKnownValueEql(self.pass.program, existing.?, requested.?)) {
                    matches = false;
                    break;
                }
            }
            if (matches) return specialization.fn_id;
        }
        return null;
    }

    fn materializeCallableWithCapturePatterns(
        self: *Cloner,
        ty: Type.TypeId,
        fn_id: Ast.FnId,
        captures_span: Ast.Span(Ast.TypedLocal),
        capture_patterns: []const ?DemandedKnownValue,
        values: []const Value,
    ) Common.LowerError!Ast.ExprId {
        var flattened = std.ArrayList(Ast.ExprId).empty;
        defer flattened.deinit(self.pass.allocator);
        var pending_lets = std.ArrayList(PendingLet).empty;
        defer pending_lets.deinit(self.pass.allocator);

        if (capture_patterns.len != values.len) {
            Common.invariant("callable capture pattern count differed from capture value count");
        }
        for (capture_patterns, values) |capture_pattern, value| {
            const pattern = capture_pattern orelse continue;
            if (!try self.appendCaptureExprsFromDemandedKnownValue(pattern, value, &flattened, &pending_lets)) {
                Common.invariant("callable capture value could not be split into requested capture pattern");
            }
        }

        const captures = self.pass.program.typedLocalSpan(captures_span);
        if (captures.len != flattened.items.len) {
            Common.invariant("split callable capture count differed between specialization and materialization");
        }

        const value_exprs = try self.pass.allocator.alloc(?Ast.ExprId, flattened.items.len);
        defer self.pass.allocator.free(value_exprs);
        for (captures, flattened.items, 0..) |capture, value_expr, index| {
            const value_local = localExpr(self.pass.program, value_expr);
            value_exprs[index] = if (value_local != null and value_local.? == capture.local) null else value_expr;
        }

        var result = try self.addExpr(.{ .ty = ty, .data = .{ .fn_ref = fn_id } });
        var index = value_exprs.len;
        while (index > 0) {
            index -= 1;
            const value_expr = value_exprs[index] orelse continue;
            const pat = try self.pass.program.addPat(.{
                .ty = captures[index].ty,
                .data = .{ .bind = captures[index].local },
            });
            result = try self.addExpr(.{ .ty = ty, .data = .{ .let_ = .{
                .bind = pat,
                .value = value_expr,
                .rest = result,
            } } });
        }
        return try self.wrapPendingLetsAroundExpr(ty, result, pending_lets.items);
    }

    fn appendCaptureExprsFromDemandedKnownValue(
        self: *Cloner,
        pattern: DemandedKnownValue,
        value: Value,
        out: *std.ArrayList(Ast.ExprId),
        pending_lets: *std.ArrayList(PendingLet),
    ) Common.LowerError!bool {
        if (value == .let_) {
            const let_value = value.let_;
            try pending_lets.appendSlice(self.pass.allocator, let_value.lets);
            return try self.appendCaptureExprsFromDemandedKnownValue(pattern, let_value.body.*, out, pending_lets);
        }

        return try self.appendExprsFromDemandedKnownValueCollectingLets(pattern, value, out, pending_lets);
    }

    fn appendCaptureExprsFromValue(
        self: *Cloner,
        known_value: KnownValue,
        value: Value,
        out: *std.ArrayList(Ast.ExprId),
        pending_lets: *std.ArrayList(PendingLet),
    ) Common.LowerError!bool {
        if (value == .let_) {
            const let_value = value.let_;
            try pending_lets.appendSlice(self.pass.allocator, let_value.lets);
            return try self.appendCaptureExprsFromValue(known_value, let_value.body.*, out, pending_lets);
        }
        if (value == .private_state) {
            try self.appendExprsFromPrivateStateKnownValue(known_value, value.private_state, out);
            return true;
        }

        switch (known_value) {
            .any,
            .leaf,
            => {
                try out.append(self.pass.allocator, try self.materializePublic(value));
                return true;
            },
            .tag => |tag| {
                const tag_value = switch (value) {
                    .tag => |tag_value| tag_value,
                    else => return false,
                };
                if (!sameType(self.pass.program, tag.ty, tag_value.ty) or
                    tag.name != tag_value.name or
                    tag.payloads.len != tag_value.payloads.len)
                {
                    return false;
                }
                for (tag.payloads, tag_value.payloads) |payload_known_value, payload| {
                    if (!try self.appendCaptureExprsFromValue(payload_known_value, payload, out, pending_lets)) return false;
                }
                return true;
            },
            .record => |record| {
                if (recordFromValue(value)) |record_value| {
                    for (record.fields) |field_known_value| {
                        const field_value = fieldFromRecord(record_value, field_known_value.name) orelse return false;
                        if (!try self.appendCaptureExprsFromValue(field_known_value.known_value, field_value, out, pending_lets)) return false;
                    }
                    return true;
                }
                return try self.appendFieldReadExprsFromValue(known_value, value, out);
            },
            .tuple => |tuple| {
                if (tupleFromValue(value)) |tuple_value| {
                    if (tuple.items.len != tuple_value.items.len) return false;
                    for (tuple.items, tuple_value.items) |item_known_value, item| {
                        if (!try self.appendCaptureExprsFromValue(item_known_value, item, out, pending_lets)) return false;
                    }
                    return true;
                }
                return try self.appendFieldReadExprsFromValue(known_value, value, out);
            },
            .nominal => |nominal| {
                const backing_value = switch (value) {
                    .nominal => |nominal_value| nominal_value.backing.*,
                    else => return try self.appendFieldReadExprsFromValue(known_value, value, out),
                };
                return try self.appendCaptureExprsFromValue(nominal.backing.*, backing_value, out, pending_lets);
            },
            .callable => |callable| {
                const callable_value = switch (value) {
                    .callable => |callable_value| callable_value,
                    else => return try self.appendFieldReadExprsFromValue(known_value, value, out),
                };
                if (!callableTargetMatches(self.pass.program, callable.fn_id, callable_value.fn_id) or
                    callable.captures.len != callable_value.captures.len)
                {
                    return false;
                }
                for (callable.captures, callable_value.captures) |capture_known_value, capture_value| {
                    if (!try self.appendCaptureExprsFromValue(capture_known_value, capture_value, out, pending_lets)) return false;
                }
                return true;
            },
            .finite_callables => |finite_callables| {
                if (value == .finite_callables) {
                    const finite_value = value.finite_callables;
                    if (!knownCallablesMatchesValue(self.pass.program, finite_callables, finite_value)) return false;
                    try out.append(self.pass.allocator, finite_value.selector);
                    for (finite_callables.alternatives, finite_value.alternatives) |alternative_known_value, alternative_value| {
                        if (!callableTargetMatches(self.pass.program, alternative_known_value.fn_id, alternative_value.fn_id) or
                            alternative_known_value.captures.len != alternative_value.captures.len)
                        {
                            return false;
                        }
                        for (alternative_known_value.captures, alternative_value.captures) |capture_known_value, capture_value| {
                            if (!try self.appendCaptureExprsFromValue(capture_known_value, capture_value, out, pending_lets)) return false;
                        }
                    }
                    return true;
                }

                const callable_value = switch (value) {
                    .callable => |callable_value| callable_value,
                    else => return try self.appendFieldReadExprsFromValue(known_value, value, out),
                };
                const active_index = finiteCallableAlternativeIndex(self.pass.program, finite_callables.alternatives, callable_value) orelse return false;
                try out.append(self.pass.allocator, try self.selectorLiteral(@intCast(active_index)));
                for (finite_callables.alternatives, 0..) |alternative_known_value, alternative_index| {
                    if (alternative_index == active_index) {
                        for (alternative_known_value.captures, callable_value.captures) |capture_known_value, capture_value| {
                            if (!try self.appendCaptureExprsFromValue(capture_known_value, capture_value, out, pending_lets)) return false;
                        }
                    } else {
                        for (alternative_known_value.captures) |capture_known_value| {
                            try self.appendUninitializedExprsForKnownValue(capture_known_value, out);
                        }
                    }
                }
                return true;
            },
            .finite_tags => |finite_tags| {
                if (value == .finite_tags) {
                    const finite_value = value.finite_tags;
                    if (!knownTagsMatchesValue(self.pass.program, finite_tags, finite_value)) return false;
                    try out.append(self.pass.allocator, finite_value.selector);
                    for (finite_tags.alternatives, finite_value.alternatives) |alternative_known_value, alternative_value| {
                        if (alternative_known_value.name != alternative_value.name or
                            alternative_known_value.payloads.len != alternative_value.payloads.len)
                        {
                            return false;
                        }
                        for (alternative_known_value.payloads, alternative_value.payloads) |payload_known_value, payload_value| {
                            if (!try self.appendCaptureExprsFromValue(payload_known_value, payload_value, out, pending_lets)) return false;
                        }
                    }
                    return true;
                }

                const tag_value = switch (value) {
                    .tag => |tag_value| tag_value,
                    else => return try self.appendFieldReadExprsFromValue(known_value, value, out),
                };
                const active_index = finiteTagAlternativeIndex(self.pass.program, finite_tags.alternatives, tag_value) orelse return false;
                try out.append(self.pass.allocator, try self.selectorLiteral(@intCast(active_index)));
                for (finite_tags.alternatives, 0..) |alternative_known_value, alternative_index| {
                    if (alternative_index == active_index) {
                        for (alternative_known_value.payloads, tag_value.payloads) |payload_known_value, payload_value| {
                            if (!try self.appendCaptureExprsFromValue(payload_known_value, payload_value, out, pending_lets)) return false;
                        }
                    } else {
                        for (alternative_known_value.payloads) |payload_known_value| {
                            try self.appendUninitializedExprsForKnownValue(payload_known_value, out);
                        }
                    }
                }
                return true;
            },
        }
    }

    fn materializeCallableWithCaptures(
        self: *Cloner,
        ty: Type.TypeId,
        fn_id: Ast.FnId,
        captures_span: Ast.Span(Ast.TypedLocal),
        values: []const Value,
    ) Common.LowerError!Ast.ExprId {
        const captures = try self.pass.allocator.dupe(Ast.TypedLocal, self.pass.program.typedLocalSpan(captures_span));
        defer self.pass.allocator.free(captures);
        if (captures.len != values.len) {
            Common.invariant("callable value capture count differed from specialized function capture count");
        }

        const value_exprs = try self.pass.allocator.alloc(?Ast.ExprId, values.len);
        defer self.pass.allocator.free(value_exprs);
        for (captures, values, 0..) |capture, value, index| {
            const value_expr = try self.materializePublic(value);
            const value_local = localExpr(self.pass.program, value_expr);
            value_exprs[index] = if (value_local != null and value_local.? == capture.local) null else value_expr;
        }

        var result = try self.addExpr(.{ .ty = ty, .data = .{ .fn_ref = fn_id } });
        var index = value_exprs.len;
        while (index > 0) {
            index -= 1;
            const value_expr = value_exprs[index] orelse continue;
            const pat = try self.pass.program.addPat(.{
                .ty = captures[index].ty,
                .data = .{ .bind = captures[index].local },
            });
            result = try self.addExpr(.{ .ty = ty, .data = .{ .let_ = .{
                .bind = pat,
                .value = value_expr,
                .rest = result,
            } } });
        }
        return result;
    }

    fn copyValue(self: *Cloner, value: Value) Allocator.Error!*const Value {
        const out = try self.pass.arena.allocator().create(Value);
        out.* = value;
        return out;
    }

    fn snapshotSubst(self: *Cloner) Allocator.Error![]const SavedBinding {
        var bindings = std.ArrayList(SavedBinding).empty;
        defer bindings.deinit(self.pass.allocator);

        var iterator = self.subst.iterator();
        while (iterator.next()) |entry| {
            try bindings.append(self.pass.allocator, .{
                .local = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            });
        }

        return try self.pass.arena.allocator().dupe(SavedBinding, bindings.items);
    }

    fn putSubst(self: *Cloner, local: Ast.LocalId, value: Value) Allocator.Error!void {
        const previous = self.subst.get(local);
        try self.changes.append(self.pass.allocator, .{
            .key = .{ .local = local },
            .previous = previous,
        });
        try self.subst.put(local, value);
    }

    fn restore(self: *Cloner, start: usize) void {
        var index = self.changes.items.len;
        while (index > start) {
            index -= 1;
            const change = self.changes.items[index];
            switch (change.key) {
                .local => |local| {
                    if (change.previous) |previous| {
                        self.subst.putAssumeCapacity(local, previous);
                    } else {
                        _ = self.subst.remove(local);
                    }
                },
            }
        }
        self.changes.shrinkRetainingCapacity(start);
    }

    fn addExpr(self: *Cloner, expr: Ast.Expr) Allocator.Error!Ast.ExprId {
        const saved_loc = self.pass.program.current_loc;
        defer self.pass.program.current_loc = saved_loc;
        const saved_region = self.pass.program.current_region;
        defer self.pass.program.current_region = saved_region;
        self.pass.program.current_loc = self.current_loc;
        self.pass.program.current_region = self.current_region;
        return try self.pass.program.addExpr(expr);
    }

    fn addStmt(self: *Cloner, stmt: Ast.Stmt) Allocator.Error!Ast.StmtId {
        const saved_loc = self.pass.program.current_loc;
        defer self.pass.program.current_loc = saved_loc;
        const saved_region = self.pass.program.current_region;
        defer self.pass.program.current_region = saved_region;
        self.pass.program.current_loc = self.current_loc;
        self.pass.program.current_region = self.current_region;
        return try self.pass.program.addStmt(stmt);
    }
};

fn localExpr(program: *const Ast.Program, expr_id: Ast.ExprId) ?Ast.LocalId {
    return switch (program.exprs.items[@intFromEnum(expr_id)].data) {
        .local => |local| local,
        else => null,
    };
}

fn pendingLetValueContainsEscapingControlTransfer(program: *const Ast.Program, value: PendingLetValue) bool {
    return switch (value) {
        .source => |expr| exprContainsEscapingControlTransfer(program, expr),
        .cloned => |expr| exprContainsEscapingControlTransfer(program, expr),
    };
}

fn localInTypedLocalSpan(locals: []const Ast.TypedLocal, local: Ast.LocalId) bool {
    for (locals) |candidate| {
        if (candidate.local == local) return true;
    }
    return false;
}

/// A pending let may be cloned later in a different loop context. Control
/// transfers that escape the expression being lifted must therefore remain in
/// their original place so their target stays the same.
fn stmtAlwaysEscapesControlTransfer(program: *const Ast.Program, stmt_id: Ast.StmtId) bool {
    return stmtAlwaysEscapesControlTransferDepth(program, stmt_id, 0, 0);
}

fn stmtAlwaysEscapesControlTransferDepth(
    program: *const Ast.Program,
    stmt_id: Ast.StmtId,
    loop_depth: usize,
    state_loop_depth: usize,
) bool {
    return switch (program.stmts.items[@intFromEnum(stmt_id)]) {
        .return_ => true,
        .expr,
        .expect,
        .dbg,
        => |expr_id| exprAlwaysEscapesControlTransferDepth(program, expr_id, loop_depth, state_loop_depth),
        .let_ => |let_| exprAlwaysEscapesControlTransferDepth(program, let_.value, loop_depth, state_loop_depth),
        .crash => true,
        .uninitialized => false,
    };
}

fn exprAlwaysEscapesControlTransferDepth(
    program: *const Ast.Program,
    expr_id: Ast.ExprId,
    loop_depth: usize,
    state_loop_depth: usize,
) bool {
    return switch (program.exprs.items[@intFromEnum(expr_id)].data) {
        .return_,
        .crash,
        .comptime_exhaustiveness_failed,
        => true,
        .break_ => |maybe| loop_depth == 0 or if (maybe) |value|
            exprAlwaysEscapesControlTransferDepth(program, value, loop_depth, state_loop_depth)
        else
            false,
        .continue_ => |continue_| loop_depth == 0 or
            exprSpanAlwaysEscapesControlTransferDepth(program, continue_.values, loop_depth, state_loop_depth),
        .state_continue => |continue_| state_loop_depth == 0 or
            exprSpanAlwaysEscapesControlTransferDepth(program, continue_.values, loop_depth, state_loop_depth),
        .comptime_branch_taken => |taken| exprAlwaysEscapesControlTransferDepth(program, taken.body, loop_depth, state_loop_depth),
        .let_ => |let_| exprAlwaysEscapesControlTransferDepth(program, let_.value, loop_depth, state_loop_depth) or
            exprAlwaysEscapesControlTransferDepth(program, let_.rest, loop_depth, state_loop_depth),
        .nominal,
        .dbg,
        .expect,
        => |child| exprAlwaysEscapesControlTransferDepth(program, child, loop_depth, state_loop_depth),
        .expect_err => |expect_err| exprAlwaysEscapesControlTransferDepth(program, expect_err.msg, loop_depth, state_loop_depth),
        .block => |block| blockAlwaysEscapesControlTransferDepth(program, block.statements, block.final_expr, loop_depth, state_loop_depth),
        .if_ => |if_| blk: {
            for (program.ifBranchSpan(if_.branches)) |branch| {
                if (!exprAlwaysEscapesControlTransferDepth(program, branch.body, loop_depth, state_loop_depth)) break :blk false;
            }
            break :blk exprAlwaysEscapesControlTransferDepth(program, if_.final_else, loop_depth, state_loop_depth);
        },
        .match_ => |match| blk: {
            for (program.branchSpan(match.branches)) |branch| {
                if (!exprAlwaysEscapesControlTransferDepth(program, branch.body, loop_depth, state_loop_depth)) break :blk false;
            }
            break :blk true;
        },
        .if_initialized_payload => |payload_switch| exprAlwaysEscapesControlTransferDepth(program, payload_switch.initialized, loop_depth, state_loop_depth) and
            exprAlwaysEscapesControlTransferDepth(program, payload_switch.uninitialized, loop_depth, state_loop_depth),
        .try_sequence => |sequence| exprAlwaysEscapesControlTransferDepth(program, sequence.try_expr, loop_depth, state_loop_depth) or
            exprAlwaysEscapesControlTransferDepth(program, sequence.ok_body, loop_depth, state_loop_depth),
        .try_record_sequence => |sequence| exprAlwaysEscapesControlTransferDepth(program, sequence.try_expr, loop_depth, state_loop_depth) or
            exprAlwaysEscapesControlTransferDepth(program, sequence.ok_body, loop_depth, state_loop_depth),
        .loop_ => |loop| exprSpanAlwaysEscapesControlTransferDepth(program, loop.initial_values, loop_depth, state_loop_depth),
        .state_loop => |state_loop| exprSpanAlwaysEscapesControlTransferDepth(program, state_loop.entry_values, loop_depth, state_loop_depth),
        .local,
        .unit,
        .int_lit,
        .frac_f32_lit,
        .frac_f64_lit,
        .dec_lit,
        .str_lit,
        .static_data,
        .uninitialized,
        .uninitialized_payload,
        .fn_ref,
        .list,
        .tuple,
        .record,
        .tag,
        .lambda,
        .def_ref,
        .fn_def,
        .call_value,
        .call_proc,
        .low_level,
        .field_access,
        .tuple_access,
        .structural_eq,
        .structural_hash,
        => false,
        .static_data_candidate => |candidate| exprAlwaysEscapesControlTransferDepth(program, candidate.fallback, loop_depth, state_loop_depth),
    };
}

fn exprSpanAlwaysEscapesControlTransferDepth(
    program: *const Ast.Program,
    span: Ast.Span(Ast.ExprId),
    loop_depth: usize,
    state_loop_depth: usize,
) bool {
    for (program.exprSpan(span)) |expr_id| {
        if (exprAlwaysEscapesControlTransferDepth(program, expr_id, loop_depth, state_loop_depth)) return true;
    }
    return false;
}

fn blockAlwaysEscapesControlTransferDepth(
    program: *const Ast.Program,
    statements: Ast.Span(Ast.StmtId),
    final_expr: Ast.ExprId,
    loop_depth: usize,
    state_loop_depth: usize,
) bool {
    for (program.stmtSpan(statements)) |stmt_id| {
        if (stmtAlwaysEscapesControlTransferDepth(program, stmt_id, loop_depth, state_loop_depth)) return true;
    }
    return exprAlwaysEscapesControlTransferDepth(program, final_expr, loop_depth, state_loop_depth);
}

fn exprContainsEscapingControlTransfer(program: *const Ast.Program, expr_id: Ast.ExprId) bool {
    return exprContainsEscapingControlTransferDepth(program, expr_id, 0, 0);
}

fn exprContainsEscapingControlTransferDepth(
    program: *const Ast.Program,
    expr_id: Ast.ExprId,
    loop_depth: usize,
    state_loop_depth: usize,
) bool {
    return switch (program.exprs.items[@intFromEnum(expr_id)].data) {
        .return_ => true,
        .break_ => |maybe| loop_depth == 0 or if (maybe) |value|
            exprContainsEscapingControlTransferDepth(program, value, loop_depth, state_loop_depth)
        else
            false,
        .continue_ => |continue_| loop_depth == 0 or
            exprSpanContainsEscapingControlTransferDepth(program, continue_.values, loop_depth, state_loop_depth),
        .state_continue => |continue_| state_loop_depth == 0 or
            exprSpanContainsEscapingControlTransferDepth(program, continue_.values, loop_depth, state_loop_depth),
        .local,
        .unit,
        .int_lit,
        .frac_f32_lit,
        .frac_f64_lit,
        .dec_lit,
        .str_lit,
        .static_data,
        .uninitialized,
        .uninitialized_payload,
        .fn_ref,
        .crash,
        .comptime_exhaustiveness_failed,
        => false,
        .static_data_candidate => |candidate| exprContainsEscapingControlTransferDepth(program, candidate.fallback, loop_depth, state_loop_depth),
        .list,
        .tuple,
        => |items| exprSpanContainsEscapingControlTransferDepth(program, items, loop_depth, state_loop_depth),
        .record => |fields| blk: {
            for (program.fieldExprSpan(fields)) |field| {
                if (exprContainsEscapingControlTransferDepth(program, field.value, loop_depth, state_loop_depth)) break :blk true;
            }
            break :blk false;
        },
        .tag => |tag| exprSpanContainsEscapingControlTransferDepth(program, tag.payloads, loop_depth, state_loop_depth),
        .nominal,
        .dbg,
        .expect,
        => |child| exprContainsEscapingControlTransferDepth(program, child, loop_depth, state_loop_depth),
        .expect_err => |expect_err| exprContainsEscapingControlTransferDepth(program, expect_err.msg, loop_depth, state_loop_depth),
        .comptime_branch_taken => |taken| exprContainsEscapingControlTransferDepth(program, taken.body, loop_depth, state_loop_depth),
        .let_ => |let_| exprContainsEscapingControlTransferDepth(program, let_.value, loop_depth, state_loop_depth) or
            exprContainsEscapingControlTransferDepth(program, let_.rest, loop_depth, state_loop_depth),
        .lambda,
        .def_ref,
        .fn_def,
        => Common.invariant("pre-lift function expression reached call-pattern control-transfer scan"),
        .call_value => |call| exprContainsEscapingControlTransferDepth(program, call.callee, loop_depth, state_loop_depth) or
            exprSpanContainsEscapingControlTransferDepth(program, call.args, loop_depth, state_loop_depth),
        .call_proc => |call| exprSpanContainsEscapingControlTransferDepth(program, call.args, loop_depth, state_loop_depth),
        .low_level => |call| exprSpanContainsEscapingControlTransferDepth(program, call.args, loop_depth, state_loop_depth),
        .field_access => |field| exprContainsEscapingControlTransferDepth(program, field.receiver, loop_depth, state_loop_depth),
        .tuple_access => |access| exprContainsEscapingControlTransferDepth(program, access.tuple, loop_depth, state_loop_depth),
        .structural_eq => |eq| exprContainsEscapingControlTransferDepth(program, eq.lhs, loop_depth, state_loop_depth) or
            exprContainsEscapingControlTransferDepth(program, eq.rhs, loop_depth, state_loop_depth),
        .structural_hash => |h| exprContainsEscapingControlTransferDepth(program, h.value, loop_depth, state_loop_depth) or
            exprContainsEscapingControlTransferDepth(program, h.hasher, loop_depth, state_loop_depth),
        .match_ => |match| blk: {
            if (exprContainsEscapingControlTransferDepth(program, match.scrutinee, loop_depth, state_loop_depth)) break :blk true;
            for (program.branchSpan(match.branches)) |branch| {
                if (branch.guard) |guard| {
                    if (exprContainsEscapingControlTransferDepth(program, guard, loop_depth, state_loop_depth)) break :blk true;
                }
                if (exprContainsEscapingControlTransferDepth(program, branch.body, loop_depth, state_loop_depth)) break :blk true;
            }
            break :blk false;
        },
        .if_ => |if_| blk: {
            for (program.ifBranchSpan(if_.branches)) |branch| {
                if (exprContainsEscapingControlTransferDepth(program, branch.cond, loop_depth, state_loop_depth) or
                    exprContainsEscapingControlTransferDepth(program, branch.body, loop_depth, state_loop_depth))
                {
                    break :blk true;
                }
            }
            break :blk exprContainsEscapingControlTransferDepth(program, if_.final_else, loop_depth, state_loop_depth);
        },
        .if_initialized_payload => |payload_switch| exprContainsEscapingControlTransferDepth(program, payload_switch.cond, loop_depth, state_loop_depth) or
            exprContainsEscapingControlTransferDepth(program, payload_switch.initialized, loop_depth, state_loop_depth) or
            exprContainsEscapingControlTransferDepth(program, payload_switch.uninitialized, loop_depth, state_loop_depth),
        .try_sequence => |sequence| exprContainsEscapingControlTransferDepth(program, sequence.try_expr, loop_depth, state_loop_depth) or
            exprContainsEscapingControlTransferDepth(program, sequence.ok_body, loop_depth, state_loop_depth),
        .try_record_sequence => |sequence| exprContainsEscapingControlTransferDepth(program, sequence.try_expr, loop_depth, state_loop_depth) or
            exprContainsEscapingControlTransferDepth(program, sequence.ok_body, loop_depth, state_loop_depth),
        .block => |block| stmtSpanContainsEscapingControlTransferDepth(program, block.statements, loop_depth, state_loop_depth) or
            exprContainsEscapingControlTransferDepth(program, block.final_expr, loop_depth, state_loop_depth),
        .loop_ => |loop| exprSpanContainsEscapingControlTransferDepth(program, loop.initial_values, loop_depth, state_loop_depth) or
            exprContainsEscapingControlTransferDepth(program, loop.body, loop_depth + 1, state_loop_depth),
        .state_loop => |state_loop| blk: {
            if (exprSpanContainsEscapingControlTransferDepth(program, state_loop.entry_values, loop_depth, state_loop_depth)) break :blk true;
            for (program.stateLoopStateSpan(state_loop.states)) |state| {
                if (exprContainsEscapingControlTransferDepth(program, state.body, loop_depth, state_loop_depth + 1)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn exprSpanContainsEscapingControlTransferDepth(
    program: *const Ast.Program,
    span: Ast.Span(Ast.ExprId),
    loop_depth: usize,
    state_loop_depth: usize,
) bool {
    for (program.exprSpan(span)) |expr_id| {
        if (exprContainsEscapingControlTransferDepth(program, expr_id, loop_depth, state_loop_depth)) return true;
    }
    return false;
}

fn stmtContainsEscapingControlTransferDepth(
    program: *const Ast.Program,
    stmt_id: Ast.StmtId,
    loop_depth: usize,
    state_loop_depth: usize,
) bool {
    return switch (program.stmts.items[@intFromEnum(stmt_id)]) {
        .return_ => true,
        .let_ => |let_| exprContainsEscapingControlTransferDepth(program, let_.value, loop_depth, state_loop_depth),
        .expr,
        .expect,
        .dbg,
        => |expr_id| exprContainsEscapingControlTransferDepth(program, expr_id, loop_depth, state_loop_depth),
        .uninitialized,
        .crash,
        => false,
    };
}

fn stmtSpanContainsEscapingControlTransferDepth(
    program: *const Ast.Program,
    span: Ast.Span(Ast.StmtId),
    loop_depth: usize,
    state_loop_depth: usize,
) bool {
    for (program.stmtSpan(span)) |stmt_id| {
        if (stmtContainsEscapingControlTransferDepth(program, stmt_id, loop_depth, state_loop_depth)) return true;
    }
    return false;
}

/// A body with an early return can be cloned into a worker with the same return
/// target, but it cannot be directly inlined into a different caller body.
fn exprContainsReturn(program: *const Ast.Program, expr_id: Ast.ExprId) bool {
    return switch (program.exprs.items[@intFromEnum(expr_id)].data) {
        .return_ => true,
        .local,
        .unit,
        .int_lit,
        .frac_f32_lit,
        .frac_f64_lit,
        .dec_lit,
        .str_lit,
        .static_data,
        .uninitialized,
        .uninitialized_payload,
        .fn_ref,
        .crash,
        .comptime_exhaustiveness_failed,
        => false,
        .static_data_candidate => |candidate| exprContainsReturn(program, candidate.fallback),
        .list,
        .tuple,
        => |items| exprSpanContainsReturn(program, items),
        .record => |fields| blk: {
            for (program.fieldExprSpan(fields)) |field| {
                if (exprContainsReturn(program, field.value)) break :blk true;
            }
            break :blk false;
        },
        .tag => |tag| exprSpanContainsReturn(program, tag.payloads),
        .nominal,
        .dbg,
        .expect,
        => |child| exprContainsReturn(program, child),
        .expect_err => |expect_err| exprContainsReturn(program, expect_err.msg),
        .comptime_branch_taken => |taken| exprContainsReturn(program, taken.body),
        .let_ => |let_| exprContainsReturn(program, let_.value) or exprContainsReturn(program, let_.rest),
        .lambda,
        .def_ref,
        .fn_def,
        => Common.invariant("pre-lift function expression reached call-pattern return scan"),
        .call_value => |call| exprContainsReturn(program, call.callee) or exprSpanContainsReturn(program, call.args),
        .call_proc => |call| exprSpanContainsReturn(program, call.args),
        .low_level => |call| exprSpanContainsReturn(program, call.args),
        .field_access => |field| exprContainsReturn(program, field.receiver),
        .tuple_access => |access| exprContainsReturn(program, access.tuple),
        .structural_eq => |eq| exprContainsReturn(program, eq.lhs) or exprContainsReturn(program, eq.rhs),
        .structural_hash => |h| exprContainsReturn(program, h.value) or exprContainsReturn(program, h.hasher),
        .match_ => |match| blk: {
            if (exprContainsReturn(program, match.scrutinee)) break :blk true;
            for (program.branchSpan(match.branches)) |branch| {
                if (branch.guard) |guard| {
                    if (exprContainsReturn(program, guard)) break :blk true;
                }
                if (exprContainsReturn(program, branch.body)) break :blk true;
            }
            break :blk false;
        },
        .if_ => |if_| blk: {
            for (program.ifBranchSpan(if_.branches)) |branch| {
                if (exprContainsReturn(program, branch.cond) or exprContainsReturn(program, branch.body)) {
                    break :blk true;
                }
            }
            break :blk exprContainsReturn(program, if_.final_else);
        },
        .if_initialized_payload => |payload_switch| exprContainsReturn(program, payload_switch.cond) or
            exprContainsReturn(program, payload_switch.initialized) or
            exprContainsReturn(program, payload_switch.uninitialized),
        .try_sequence => |sequence| exprContainsReturn(program, sequence.try_expr) or
            exprContainsReturn(program, sequence.ok_body),
        .try_record_sequence => |sequence| exprContainsReturn(program, sequence.try_expr) or
            exprContainsReturn(program, sequence.ok_body),
        .block => |block| stmtSpanContainsReturn(program, block.statements) or exprContainsReturn(program, block.final_expr),
        .loop_ => |loop| exprSpanContainsReturn(program, loop.initial_values) or exprContainsReturn(program, loop.body),
        .state_loop => |state_loop| blk: {
            if (exprSpanContainsReturn(program, state_loop.entry_values)) break :blk true;
            for (program.stateLoopStateSpan(state_loop.states)) |state| {
                if (exprContainsReturn(program, state.body)) break :blk true;
            }
            break :blk false;
        },
        .break_ => |maybe| if (maybe) |value| exprContainsReturn(program, value) else false,
        .continue_ => |continue_| exprSpanContainsReturn(program, continue_.values),
        .state_continue => |continue_| exprSpanContainsReturn(program, continue_.values),
    };
}

fn exprSpanContainsReturn(program: *const Ast.Program, span: Ast.Span(Ast.ExprId)) bool {
    for (program.exprSpan(span)) |expr_id| {
        if (exprContainsReturn(program, expr_id)) return true;
    }
    return false;
}

fn stmtContainsReturn(program: *const Ast.Program, stmt_id: Ast.StmtId) bool {
    return switch (program.stmts.items[@intFromEnum(stmt_id)]) {
        .return_ => true,
        .let_ => |let_| exprContainsReturn(program, let_.value),
        .expr,
        .expect,
        .dbg,
        => |expr_id| exprContainsReturn(program, expr_id),
        .uninitialized,
        .crash,
        => false,
    };
}

fn stmtSpanContainsReturn(program: *const Ast.Program, span: Ast.Span(Ast.StmtId)) bool {
    for (program.stmtSpan(span)) |stmt_id| {
        if (stmtContainsReturn(program, stmt_id)) return true;
    }
    return false;
}

fn localUseCountInExpr(program: *const Ast.Program, local: Ast.LocalId, expr_id: Ast.ExprId) usize {
    return switch (program.exprs.items[@intFromEnum(expr_id)].data) {
        .local => |seen| if (seen == local) 1 else 0,
        .unit,
        .int_lit,
        .frac_f32_lit,
        .frac_f64_lit,
        .dec_lit,
        .str_lit,
        .static_data,
        .fn_ref,
        .crash,
        .comptime_exhaustiveness_failed,
        .uninitialized,
        .uninitialized_payload,
        => 0,
        .static_data_candidate => |candidate| localUseCountInExpr(program, local, candidate.fallback),
        .list,
        .tuple,
        => |items| localUseCountInExprSpan(program, local, items),
        .record => |fields| blk: {
            var count: usize = 0;
            for (program.fieldExprSpan(fields)) |field| count += localUseCountInExpr(program, local, field.value);
            break :blk count;
        },
        .tag => |tag| localUseCountInExprSpan(program, local, tag.payloads),
        .nominal,
        .return_,
        .dbg,
        .expect,
        => |child| localUseCountInExpr(program, local, child),
        .expect_err => |expect_err| localUseCountInExpr(program, local, expect_err.msg),
        .comptime_branch_taken => |taken| localUseCountInExpr(program, local, taken.body),
        .let_ => |let_| localUseCountInExpr(program, local, let_.value) + localUseCountInExpr(program, local, let_.rest),
        .lambda,
        .def_ref,
        .fn_def,
        => 0,
        .call_value => |call| localUseCountInExpr(program, local, call.callee) + localUseCountInExprSpan(program, local, call.args),
        .call_proc => |call| localUseCountInExprSpan(program, local, call.args),
        .low_level => |call| localUseCountInExprSpan(program, local, call.args),
        .field_access => |field| localUseCountInExpr(program, local, field.receiver),
        .tuple_access => |access| localUseCountInExpr(program, local, access.tuple),
        .structural_eq => |eq| localUseCountInExpr(program, local, eq.lhs) + localUseCountInExpr(program, local, eq.rhs),
        .structural_hash => |h| localUseCountInExpr(program, local, h.value) + localUseCountInExpr(program, local, h.hasher),
        .match_ => |match| blk: {
            var count = localUseCountInExpr(program, local, match.scrutinee);
            for (program.branchSpan(match.branches)) |branch| {
                if (branch.guard) |guard| count += localUseCountInExpr(program, local, guard);
                count += localUseCountInExpr(program, local, branch.body);
            }
            break :blk count;
        },
        .if_ => |if_| blk: {
            var count: usize = 0;
            for (program.ifBranchSpan(if_.branches)) |branch| {
                count += localUseCountInExpr(program, local, branch.cond);
                count += localUseCountInExpr(program, local, branch.body);
            }
            count += localUseCountInExpr(program, local, if_.final_else);
            break :blk count;
        },
        .block => |block| blk: {
            var count: usize = 0;
            for (program.stmtSpan(block.statements)) |stmt| count += localUseCountInStmt(program, local, stmt);
            count += localUseCountInExpr(program, local, block.final_expr);
            break :blk count;
        },
        .loop_ => |loop| localUseCountInExprSpan(program, local, loop.initial_values) + localUseCountInExpr(program, local, loop.body),
        .state_loop => |state_loop| blk: {
            var count = localUseCountInExprSpan(program, local, state_loop.entry_values);
            for (program.stateLoopStateSpan(state_loop.states)) |state| {
                count += localUseCountInExpr(program, local, state.body);
            }
            break :blk count;
        },
        .break_ => |maybe| if (maybe) |value| localUseCountInExpr(program, local, value) else 0,
        .continue_ => |continue_| localUseCountInExprSpan(program, local, continue_.values),
        .state_continue => |continue_| localUseCountInExprSpan(program, local, continue_.values),
        .if_initialized_payload => |payload_switch| localUseCountInExpr(program, local, payload_switch.cond) +
            (if (payload_switch.payload == local) @as(usize, 1) else 0) +
            localUseCountInExpr(program, local, payload_switch.initialized) +
            localUseCountInExpr(program, local, payload_switch.uninitialized),
        .try_sequence => |sequence| localUseCountInExpr(program, local, sequence.try_expr) +
            if (sequence.ok_local == local) 0 else localUseCountInExpr(program, local, sequence.ok_body),
        .try_record_sequence => |sequence| localUseCountInExpr(program, local, sequence.try_expr) +
            if (sequence.value_local == local or sequence.rest_local == local) 0 else localUseCountInExpr(program, local, sequence.ok_body),
    };
}

fn localUseCountInExprSpan(program: *const Ast.Program, local: Ast.LocalId, span: Ast.Span(Ast.ExprId)) usize {
    var count: usize = 0;
    for (program.exprSpan(span)) |expr| count += localUseCountInExpr(program, local, expr);
    return count;
}

fn localUseCountInBlockTail(program: *const Ast.Program, local: Ast.LocalId, tail: BlockTail) usize {
    var count: usize = 0;
    for (tail.statements) |stmt_id| count += localUseCountInStmt(program, local, stmt_id);
    count += localUseCountInExpr(program, local, tail.final_expr);
    return count;
}

fn patternUsedInExpr(program: *const Ast.Program, pat_id: Ast.PatId, expr_id: Ast.ExprId) bool {
    const pat = program.pats.items[@intFromEnum(pat_id)];
    return switch (pat.data) {
        .bind => |local| localUseCountInExpr(program, local, expr_id) != 0,
        .wildcard,
        .int_lit,
        .dec_lit,
        .frac_f32_lit,
        .frac_f64_lit,
        .str_lit,
        .str_pattern,
        => false,
        .as => |as| localUseCountInExpr(program, as.local, expr_id) != 0 or
            patternUsedInExpr(program, as.pattern, expr_id),
        .record => |fields_span| {
            for (program.recordDestructSpan(fields_span)) |field| {
                if (patternUsedInExpr(program, field.pattern, expr_id)) return true;
            }
            return false;
        },
        .tuple => |items_span| {
            for (program.patSpan(items_span)) |child| {
                if (patternUsedInExpr(program, child, expr_id)) return true;
            }
            return false;
        },
        .list => |list| {
            for (program.patSpan(list.patterns)) |child| {
                if (patternUsedInExpr(program, child, expr_id)) return true;
            }
            if (list.rest) |rest| {
                if (rest.pattern) |rest_pattern| {
                    if (patternUsedInExpr(program, rest_pattern, expr_id)) return true;
                }
            }
            return false;
        },
        .tag => |tag| {
            for (program.patSpan(tag.payloads)) |child| {
                if (patternUsedInExpr(program, child, expr_id)) return true;
            }
            return false;
        },
        .nominal => |backing| patternUsedInExpr(program, backing, expr_id),
    };
}

fn localMaxUseCountPerPathInExpr(program: *const Ast.Program, local: Ast.LocalId, expr_id: Ast.ExprId) usize {
    return switch (program.exprs.items[@intFromEnum(expr_id)].data) {
        .local => |seen| if (seen == local) 1 else 0,
        .unit,
        .int_lit,
        .frac_f32_lit,
        .frac_f64_lit,
        .dec_lit,
        .str_lit,
        .static_data,
        .fn_ref,
        .crash,
        .comptime_exhaustiveness_failed,
        .uninitialized,
        .uninitialized_payload,
        .lambda,
        .def_ref,
        .fn_def,
        => 0,
        .static_data_candidate => |candidate| localMaxUseCountPerPathInExpr(program, local, candidate.fallback),
        .list,
        .tuple,
        => |items| localMaxUseCountPerPathInExprSpan(program, local, items),
        .record => |fields| blk: {
            var count: usize = 0;
            for (program.fieldExprSpan(fields)) |field| count += localMaxUseCountPerPathInExpr(program, local, field.value);
            break :blk count;
        },
        .tag => |tag| localMaxUseCountPerPathInExprSpan(program, local, tag.payloads),
        .nominal,
        .return_,
        .dbg,
        .expect,
        => |child| localMaxUseCountPerPathInExpr(program, local, child),
        .expect_err => |expect_err| localMaxUseCountPerPathInExpr(program, local, expect_err.msg),
        .comptime_branch_taken => |taken| localMaxUseCountPerPathInExpr(program, local, taken.body),
        .let_ => |let_| localMaxUseCountPerPathInExpr(program, local, let_.value) +
            localMaxUseCountPerPathInExpr(program, local, let_.rest),
        .call_value => |call| localMaxUseCountPerPathInExpr(program, local, call.callee) +
            localMaxUseCountPerPathInExprSpan(program, local, call.args),
        .call_proc => |call| localMaxUseCountPerPathInExprSpan(program, local, call.args),
        .low_level => |call| localMaxUseCountPerPathInExprSpan(program, local, call.args),
        .field_access => |field| localMaxUseCountPerPathInExpr(program, local, field.receiver),
        .tuple_access => |access| localMaxUseCountPerPathInExpr(program, local, access.tuple),
        .structural_eq => |eq| localMaxUseCountPerPathInExpr(program, local, eq.lhs) +
            localMaxUseCountPerPathInExpr(program, local, eq.rhs),
        .structural_hash => |h| localMaxUseCountPerPathInExpr(program, local, h.value) +
            localMaxUseCountPerPathInExpr(program, local, h.hasher),
        .match_ => |match| blk: {
            const scrutinee_count = localMaxUseCountPerPathInExpr(program, local, match.scrutinee);
            var max_branch_count: usize = 0;
            for (program.branchSpan(match.branches)) |branch| {
                var branch_count: usize = if (branch.guard) |guard|
                    localMaxUseCountPerPathInExpr(program, local, guard)
                else
                    0;
                branch_count += localMaxUseCountPerPathInExpr(program, local, branch.body);
                max_branch_count = @max(max_branch_count, branch_count);
            }
            break :blk scrutinee_count + max_branch_count;
        },
        .if_ => |if_| blk: {
            var count: usize = 0;
            var max_branch_count: usize = 0;
            for (program.ifBranchSpan(if_.branches)) |branch| {
                count += localMaxUseCountPerPathInExpr(program, local, branch.cond);
                max_branch_count = @max(max_branch_count, localMaxUseCountPerPathInExpr(program, local, branch.body));
            }
            max_branch_count = @max(max_branch_count, localMaxUseCountPerPathInExpr(program, local, if_.final_else));
            break :blk count + max_branch_count;
        },
        .block => |block| blk: {
            var count: usize = 0;
            for (program.stmtSpan(block.statements)) |stmt| count += localMaxUseCountPerPathInStmt(program, local, stmt);
            count += localMaxUseCountPerPathInExpr(program, local, block.final_expr);
            break :blk count;
        },
        .loop_ => |loop| blk: {
            const initial_count = localMaxUseCountPerPathInExprSpan(program, local, loop.initial_values);
            const body_count = localMaxUseCountPerPathInExpr(program, local, loop.body);
            break :blk initial_count + if (body_count == 0) @as(usize, 0) else @max(body_count, 2);
        },
        .state_loop => |state_loop| blk: {
            const initial_count = localMaxUseCountPerPathInExprSpan(program, local, state_loop.entry_values);
            var max_state_count: usize = 0;
            for (program.stateLoopStateSpan(state_loop.states)) |state| {
                max_state_count = @max(max_state_count, localMaxUseCountPerPathInExpr(program, local, state.body));
            }
            break :blk initial_count + if (max_state_count == 0) @as(usize, 0) else @max(max_state_count, 2);
        },
        .break_ => |maybe| if (maybe) |value| localMaxUseCountPerPathInExpr(program, local, value) else 0,
        .continue_ => |continue_| localMaxUseCountPerPathInExprSpan(program, local, continue_.values),
        .state_continue => |continue_| localMaxUseCountPerPathInExprSpan(program, local, continue_.values),
        .if_initialized_payload => |payload_switch| localMaxUseCountPerPathInExpr(program, local, payload_switch.cond) +
            @max(
                (if (payload_switch.payload == local) @as(usize, 1) else 0) +
                    localMaxUseCountPerPathInExpr(program, local, payload_switch.initialized),
                localMaxUseCountPerPathInExpr(program, local, payload_switch.uninitialized),
            ),
        .try_sequence => |sequence| localMaxUseCountPerPathInExpr(program, local, sequence.try_expr) +
            if (sequence.ok_local == local) 0 else localMaxUseCountPerPathInExpr(program, local, sequence.ok_body),
        .try_record_sequence => |sequence| localMaxUseCountPerPathInExpr(program, local, sequence.try_expr) +
            if (sequence.value_local == local or sequence.rest_local == local) 0 else localMaxUseCountPerPathInExpr(program, local, sequence.ok_body),
    };
}

fn localMaxUseCountPerPathInExprSpan(program: *const Ast.Program, local: Ast.LocalId, span: Ast.Span(Ast.ExprId)) usize {
    var count: usize = 0;
    for (program.exprSpan(span)) |expr| count += localMaxUseCountPerPathInExpr(program, local, expr);
    return count;
}

fn discardedExprIsEffectFree(program: *const Ast.Program, expr_id: Ast.ExprId) bool {
    return switch (program.exprs.items[@intFromEnum(expr_id)].data) {
        .local,
        .unit,
        .int_lit,
        .frac_f32_lit,
        .frac_f64_lit,
        .dec_lit,
        .str_lit,
        .static_data,
        .fn_ref,
        .uninitialized,
        .uninitialized_payload,
        => true,
        .static_data_candidate => |candidate| discardedExprIsEffectFree(program, candidate.fallback),
        .list,
        .tuple,
        => |items| discardedExprSpanIsEffectFree(program, items),
        .record => |fields| blk: {
            for (program.fieldExprSpan(fields)) |field| {
                if (!discardedExprIsEffectFree(program, field.value)) break :blk false;
            }
            break :blk true;
        },
        .tag => |tag| discardedExprSpanIsEffectFree(program, tag.payloads),
        .nominal => |backing| discardedExprIsEffectFree(program, backing),
        .let_ => |let_| discardedExprIsEffectFree(program, let_.value) and discardedExprIsEffectFree(program, let_.rest),
        .field_access => |field| discardedExprIsEffectFree(program, field.receiver),
        .tuple_access => |access| discardedExprIsEffectFree(program, access.tuple),
        .comptime_branch_taken => |taken| discardedExprIsEffectFree(program, taken.body),
        .lambda,
        .def_ref,
        .fn_def,
        .call_value,
        .call_proc,
        .low_level,
        .structural_eq,
        .structural_hash,
        .match_,
        .if_,
        .block,
        .loop_,
        .state_loop,
        .break_,
        .continue_,
        .state_continue,
        .return_,
        .dbg,
        .expect,
        .expect_err,
        .crash,
        .comptime_exhaustiveness_failed,
        .if_initialized_payload,
        .try_sequence,
        .try_record_sequence,
        => false,
    };
}

fn discardedExprSpanIsEffectFree(program: *const Ast.Program, span: Ast.Span(Ast.ExprId)) bool {
    for (program.exprSpan(span)) |expr| {
        if (!discardedExprIsEffectFree(program, expr)) return false;
    }
    return true;
}

fn localUseCountInStmt(program: *const Ast.Program, local: Ast.LocalId, stmt_id: Ast.StmtId) usize {
    return switch (program.stmts.items[@intFromEnum(stmt_id)]) {
        .uninitialized => 0,
        .let_ => |let_| localUseCountInExpr(program, local, let_.value),
        .expr,
        .expect,
        .dbg,
        .return_,
        => |expr| localUseCountInExpr(program, local, expr),
        .crash => 0,
    };
}

fn localMaxUseCountPerPathInStmt(program: *const Ast.Program, local: Ast.LocalId, stmt_id: Ast.StmtId) usize {
    return switch (program.stmts.items[@intFromEnum(stmt_id)]) {
        .uninitialized => 0,
        .let_ => |let_| localMaxUseCountPerPathInExpr(program, local, let_.value),
        .expr,
        .expect,
        .dbg,
        .return_,
        => |expr| localMaxUseCountPerPathInExpr(program, local, expr),
        .crash => 0,
    };
}

fn localMaxUseCountPerPathInBlockTail(program: *const Ast.Program, local: Ast.LocalId, tail: BlockTail) usize {
    var count: usize = 0;
    for (tail.statements) |stmt| count += localMaxUseCountPerPathInStmt(program, local, stmt);
    count += localMaxUseCountPerPathInExpr(program, local, tail.final_expr);
    return count;
}

const LocalUseScan = struct {
    seen_effect: bool = false,
    found_before_effect: bool = false,
    found_after_effect: bool = false,
};

fn localUseBeforeEffectInBlockTail(program: *const Ast.Program, local: Ast.LocalId, tail: BlockTail) bool {
    var scan: LocalUseScan = .{};
    for (tail.statements) |stmt| scanLocalUseInStmt(program, local, stmt, &scan);
    scanLocalUseInExpr(program, local, tail.final_expr, &scan);
    return scan.found_before_effect and !scan.found_after_effect;
}

fn localUseBeforeEffect(program: *const Ast.Program, local: Ast.LocalId, expr_id: Ast.ExprId) bool {
    var scan: LocalUseScan = .{};
    scanLocalUseInExpr(program, local, expr_id, &scan);
    return scan.found_before_effect and !scan.found_after_effect;
}

fn scanLocalUseInExpr(program: *const Ast.Program, local: Ast.LocalId, expr_id: Ast.ExprId, scan: *LocalUseScan) void {
    const expr = program.exprs.items[@intFromEnum(expr_id)];
    switch (expr.data) {
        .local => |seen| {
            if (seen == local) {
                if (scan.seen_effect) {
                    scan.found_after_effect = true;
                } else {
                    scan.found_before_effect = true;
                }
            }
        },
        .unit,
        .int_lit,
        .frac_f32_lit,
        .frac_f64_lit,
        .dec_lit,
        .str_lit,
        .static_data,
        .fn_ref,
        .uninitialized,
        .uninitialized_payload,
        => {},
        .static_data_candidate => |candidate| scanLocalUseInExpr(program, local, candidate.fallback, scan),
        .crash, .comptime_exhaustiveness_failed => scan.seen_effect = true,
        .list,
        .tuple,
        => |items| scanLocalUseInExprSpan(program, local, items, scan),
        .record => |fields| {
            for (program.fieldExprSpan(fields)) |field| scanLocalUseInExpr(program, local, field.value, scan);
        },
        .tag => |tag| scanLocalUseInExprSpan(program, local, tag.payloads, scan),
        .nominal => |child| scanLocalUseInExpr(program, local, child, scan),
        .return_ => |child| {
            scanLocalUseInExpr(program, local, child, scan);
            scan.seen_effect = true;
        },
        .dbg,
        .expect,
        => |child| {
            scanLocalUseInExpr(program, local, child, scan);
            scan.seen_effect = true;
        },
        .expect_err => |expect_err| {
            scanLocalUseInExpr(program, local, expect_err.msg, scan);
            scan.seen_effect = true;
        },
        .comptime_branch_taken => |taken| scanLocalUseInExpr(program, local, taken.body, scan),
        .let_ => |let_| {
            scanLocalUseInExpr(program, local, let_.value, scan);
            scanLocalUseInExpr(program, local, let_.rest, scan);
        },
        .lambda,
        .def_ref,
        .fn_def,
        => {},
        .call_value => |call| {
            scanLocalUseInExpr(program, local, call.callee, scan);
            scanLocalUseInExprSpan(program, local, call.args, scan);
            scan.seen_effect = true;
        },
        .call_proc => |call| {
            scanLocalUseInExprSpan(program, local, call.args, scan);
            scan.seen_effect = true;
        },
        .low_level => |call| {
            scanLocalUseInExprSpan(program, local, call.args, scan);
            scan.seen_effect = true;
        },
        .field_access => |field| scanLocalUseInExpr(program, local, field.receiver, scan),
        .tuple_access => |access| scanLocalUseInExpr(program, local, access.tuple, scan),
        .structural_eq => |eq| {
            scanLocalUseInExpr(program, local, eq.lhs, scan);
            scanLocalUseInExpr(program, local, eq.rhs, scan);
            scan.seen_effect = true;
        },
        .structural_hash => |h| {
            scanLocalUseInExpr(program, local, h.value, scan);
            scanLocalUseInExpr(program, local, h.hasher, scan);
            scan.seen_effect = true;
        },
        .match_ => |match| {
            scanLocalUseInExpr(program, local, match.scrutinee, scan);
            const after_scrutinee = scan.*;
            var merged = after_scrutinee;
            for (program.branchSpan(match.branches)) |branch| {
                var branch_scan = after_scrutinee;
                if (branch.guard) |guard| scanLocalUseInExpr(program, local, guard, &branch_scan);
                scanLocalUseInExpr(program, local, branch.body, &branch_scan);
                merged.found_before_effect = merged.found_before_effect or branch_scan.found_before_effect;
                merged.found_after_effect = merged.found_after_effect or branch_scan.found_after_effect;
                merged.seen_effect = merged.seen_effect or branch_scan.seen_effect;
            }
            scan.* = merged;
        },
        .if_ => |if_| {
            var condition_scan = scan.*;
            var merged = condition_scan;
            for (program.ifBranchSpan(if_.branches)) |branch| {
                scanLocalUseInExpr(program, local, branch.cond, &condition_scan);
                var branch_scan = condition_scan;
                scanLocalUseInExpr(program, local, branch.body, &branch_scan);
                merged.found_before_effect = merged.found_before_effect or branch_scan.found_before_effect;
                merged.found_after_effect = merged.found_after_effect or branch_scan.found_after_effect;
                merged.seen_effect = merged.seen_effect or branch_scan.seen_effect;
            }
            var else_scan = condition_scan;
            scanLocalUseInExpr(program, local, if_.final_else, &else_scan);
            merged.found_before_effect = merged.found_before_effect or else_scan.found_before_effect;
            merged.found_after_effect = merged.found_after_effect or else_scan.found_after_effect;
            merged.seen_effect = merged.seen_effect or else_scan.seen_effect;
            scan.* = merged;
        },
        .block => |block| {
            for (program.stmtSpan(block.statements)) |stmt| scanLocalUseInStmt(program, local, stmt, scan);
            scanLocalUseInExpr(program, local, block.final_expr, scan);
        },
        .loop_ => |loop| {
            scanLocalUseInExprSpan(program, local, loop.initial_values, scan);
            scanLocalUseInExpr(program, local, loop.body, scan);
        },
        .state_loop => |state_loop| {
            scanLocalUseInExprSpan(program, local, state_loop.entry_values, scan);
            for (program.stateLoopStateSpan(state_loop.states)) |state| {
                scanLocalUseInExpr(program, local, state.body, scan);
            }
        },
        .break_ => |maybe| {
            if (maybe) |value| scanLocalUseInExpr(program, local, value, scan);
            scan.seen_effect = true;
        },
        .continue_ => |continue_| {
            scanLocalUseInExprSpan(program, local, continue_.values, scan);
            scan.seen_effect = true;
        },
        .state_continue => |continue_| {
            scanLocalUseInExprSpan(program, local, continue_.values, scan);
            scan.seen_effect = true;
        },
        .if_initialized_payload => |payload_switch| {
            scanLocalUseInExpr(program, local, payload_switch.cond, scan);

            var initialized_scan = scan.*;
            if (payload_switch.payload == local) {
                if (initialized_scan.seen_effect) {
                    initialized_scan.found_after_effect = true;
                } else {
                    initialized_scan.found_before_effect = true;
                }
            }
            scanLocalUseInExpr(program, local, payload_switch.initialized, &initialized_scan);

            var uninitialized_scan = scan.*;
            scanLocalUseInExpr(program, local, payload_switch.uninitialized, &uninitialized_scan);

            scan.found_before_effect = scan.found_before_effect or initialized_scan.found_before_effect or uninitialized_scan.found_before_effect;
            scan.found_after_effect = scan.found_after_effect or initialized_scan.found_after_effect or uninitialized_scan.found_after_effect;
            scan.seen_effect = scan.seen_effect or initialized_scan.seen_effect or uninitialized_scan.seen_effect;
        },
        .try_sequence => |sequence| {
            scanLocalUseInExpr(program, local, sequence.try_expr, scan);
            if (sequence.ok_local != local) {
                scanLocalUseInExpr(program, local, sequence.ok_body, scan);
            }
            scan.seen_effect = true;
        },
        .try_record_sequence => |sequence| {
            scanLocalUseInExpr(program, local, sequence.try_expr, scan);
            if (sequence.value_local != local and sequence.rest_local != local) {
                scanLocalUseInExpr(program, local, sequence.ok_body, scan);
            }
            scan.seen_effect = true;
        },
    }
}

fn scanLocalUseInExprSpan(
    program: *const Ast.Program,
    local: Ast.LocalId,
    span: Ast.Span(Ast.ExprId),
    scan: *LocalUseScan,
) void {
    for (program.exprSpan(span)) |expr| scanLocalUseInExpr(program, local, expr, scan);
}

fn scanLocalUseInStmt(program: *const Ast.Program, local: Ast.LocalId, stmt_id: Ast.StmtId, scan: *LocalUseScan) void {
    switch (program.stmts.items[@intFromEnum(stmt_id)]) {
        .uninitialized => {},
        .let_ => |let_| scanLocalUseInExpr(program, local, let_.value, scan),
        .expr => |expr| scanLocalUseInExpr(program, local, expr, scan),
        .expect,
        .dbg,
        => |expr| {
            scanLocalUseInExpr(program, local, expr, scan);
            scan.seen_effect = true;
        },
        .return_ => |expr| {
            scanLocalUseInExpr(program, local, expr, scan);
            scan.seen_effect = true;
        },
        .crash => scan.seen_effect = true,
    }
}

fn canReadFieldsFromExpr(program: *const Ast.Program, expr_id: Ast.ExprId) bool {
    return switch (program.exprs.items[@intFromEnum(expr_id)].data) {
        .local,
        .field_access,
        .tuple_access,
        .low_level,
        => true,
        else => false,
    };
}

fn projectableExprFromValue(value: Value) ?Ast.ExprId {
    return switch (value) {
        .expr => |expr| expr,
        .expr_with_known_value => |known_value_expr| known_value_expr.expr,
        .private_state => |private_state| privateStateLeafExpr(private_state),
        else => null,
    };
}

fn valueFromProjectedExpr(expr: Ast.ExprId, known_value: KnownValue) Value {
    return switch (known_value) {
        .any => .{ .expr = expr },
        else => .{ .expr_with_known_value = .{
            .expr = expr,
            .known_value = known_value,
        } },
    };
}

fn fieldKnownValueFromKnownValue(known_value: KnownValue, name: names.RecordFieldNameId) ?KnownValue {
    return switch (known_value) {
        .record => |record| blk: {
            for (record.fields) |field| {
                if (field.name == name) break :blk field.known_value;
            }
            break :blk null;
        },
        .nominal => |nominal| fieldKnownValueFromKnownValue(nominal.backing.*, name),
        else => null,
    };
}

fn itemKnownValueFromKnownValue(known_value: KnownValue, index: u32) ?KnownValue {
    return switch (known_value) {
        .tuple => |tuple| if (index < tuple.items.len) tuple.items[index] else null,
        .nominal => |nominal| itemKnownValueFromKnownValue(nominal.backing.*, index),
        else => null,
    };
}

fn knownTagForPattern(known_value: KnownValue, name: names.TagNameId) ?KnownTag {
    return switch (known_value) {
        .tag => |tag| if (tag.name == name) tag else null,
        .finite_tags => |finite_tags| blk: {
            for (finite_tags.alternatives) |alternative| {
                if (alternative.name == name) break :blk alternative;
            }
            break :blk null;
        },
        .nominal => |nominal| knownTagForPattern(nominal.backing.*, name),
        else => null,
    };
}

fn patternDefinitelyExcludedByKnownValue(program: *const Ast.Program, pat_id: Ast.PatId, known_value: KnownValue) bool {
    const pat = program.pats.items[@intFromEnum(pat_id)];
    return switch (pat.data) {
        .as => |as| patternDefinitelyExcludedByKnownValue(program, as.pattern, known_value),
        .nominal => |backing| switch (known_value) {
            .nominal => |nominal| patternDefinitelyExcludedByKnownValue(program, backing, nominal.backing.*),
            else => false,
        },
        .tag => |tag_pat| switch (known_value) {
            .tag,
            .finite_tags,
            => knownTagForPattern(known_value, tag_pat.name) == null,
            .nominal => |nominal| patternDefinitelyExcludedByKnownValue(program, pat_id, nominal.backing.*),
            else => false,
        },
        else => false,
    };
}

fn known_valueType(known_value: KnownValue) Type.TypeId {
    return switch (known_value) {
        .any => |ty| ty,
        .leaf => |ty| ty,
        .tag => |tag| tag.ty,
        .record => |record| record.ty,
        .tuple => |tuple| tuple.ty,
        .nominal => |nominal| nominal.ty,
        .callable => |callable| callable.ty,
        .finite_tags => |finite_tags| finite_tags.ty,
        .finite_callables => |finite_callables| finite_callables.ty,
    };
}

fn knownValueFromPrivateState(program: *const Ast.Program, arena: Allocator, value: PrivateStateValue) Allocator.Error!?KnownValue {
    return switch (value) {
        .leaf => |leaf| .{ .leaf = leaf.ty },
        .tag => |tag| blk: {
            const payload_tys = tagTypePayloads(program, tag.ty, tag.name) orelse break :blk null;
            const payloads = (try knownValuesFromPrivateStateIndexedValues(program, arena, tag.payloads, payload_tys.len)) orelse break :blk null;
            break :blk KnownValue{ .tag = .{
                .ty = tag.ty,
                .name = tag.name,
                .payloads = payloads,
            } };
        },
        .record => |record| blk: {
            const type_fields = recordTypeFields(program, record.ty);
            if (type_fields.len != record.fields.len) break :blk null;
            const fields = try arena.alloc(KnownField, type_fields.len);
            for (type_fields, fields) |type_field, *out| {
                const field = privateStateFieldByName(record.fields, type_field.name) orelse break :blk null;
                out.* = .{
                    .name = type_field.name,
                    .known_value = (try knownValueFromPrivateState(program, arena, field)) orelse break :blk null,
                };
            }
            break :blk KnownValue{ .record = .{
                .ty = record.ty,
                .fields = fields,
            } };
        },
        .tuple => |tuple| blk: {
            const type_items = tupleTypeItems(program, tuple.ty);
            const items = (try knownValuesFromPrivateStateIndexedValues(program, arena, tuple.items, type_items.len)) orelse break :blk null;
            break :blk KnownValue{ .tuple = .{
                .ty = tuple.ty,
                .items = items,
            } };
        },
        .nominal => |nominal| blk: {
            const backing = nominal.backing orelse break :blk null;
            const backing_known_value = (try knownValueFromPrivateState(program, arena, backing.*)) orelse break :blk null;
            const stored = try arena.create(KnownValue);
            stored.* = backing_known_value;
            break :blk KnownValue{ .nominal = .{
                .ty = nominal.ty,
                .backing = stored,
            } };
        },
        .callable => |callable| blk: {
            const source_fn = program.fns.items[@intFromEnum(callable.fn_id)];
            const source_captures = program.typedLocalSpan(source_fn.captures);
            const captures = (try knownValuesFromPrivateStateIndexedValues(program, arena, callable.captures, source_captures.len)) orelse break :blk null;
            break :blk KnownValue{ .callable = .{
                .ty = callable.ty,
                .fn_id = callable.fn_id,
                .captures = captures,
            } };
        },
        .finite_tags => |finite_tags| blk: {
            const alternatives = try arena.alloc(KnownTag, finite_tags.alternatives.len);
            for (finite_tags.alternatives, alternatives) |alternative, *out| {
                const payload_tys = tagTypePayloads(program, alternative.ty, alternative.name) orelse break :blk null;
                const payloads = (try knownValuesFromPrivateStateIndexedValues(program, arena, alternative.payloads, payload_tys.len)) orelse break :blk null;
                out.* = .{
                    .ty = alternative.ty,
                    .name = alternative.name,
                    .payloads = payloads,
                };
            }
            break :blk KnownValue{ .finite_tags = .{
                .ty = finite_tags.ty,
                .alternatives = alternatives,
            } };
        },
        .finite_callables => |finite_callables| blk: {
            const alternatives = try arena.alloc(KnownCallable, finite_callables.alternatives.len);
            for (finite_callables.alternatives, alternatives) |alternative, *out| {
                const source_fn = program.fns.items[@intFromEnum(alternative.fn_id)];
                const source_captures = program.typedLocalSpan(source_fn.captures);
                const captures = (try knownValuesFromPrivateStateIndexedValues(program, arena, alternative.captures, source_captures.len)) orelse break :blk null;
                out.* = .{
                    .ty = alternative.ty,
                    .fn_id = alternative.fn_id,
                    .captures = captures,
                };
            }
            break :blk KnownValue{ .finite_callables = .{
                .ty = finite_callables.ty,
                .alternatives = alternatives,
            } };
        },
    };
}

fn knownValuesFromPrivateStateIndexedValues(
    program: *const Ast.Program,
    arena: Allocator,
    indexed: []const PrivateStateIndexedValue,
    expected_len: usize,
) Allocator.Error!?[]const KnownValue {
    if (!privateStateIndexedValuesAreDense(indexed, expected_len)) return null;
    for (indexed, 0..) |value, index| {
        if (value.index != index) return null;
    }

    const known_values = try arena.alloc(KnownValue, expected_len);
    for (indexed, known_values) |value, *out| {
        out.* = (try knownValueFromPrivateState(program, arena, value.value)) orelse return null;
    }
    return known_values;
}

fn valueType(program: *const Ast.Program, value: Value) Type.TypeId {
    return switch (value) {
        .expr => |expr| program.exprs.items[@intFromEnum(expr)].ty,
        .expr_with_known_value => |known_value_expr| program.exprs.items[@intFromEnum(known_value_expr.expr)].ty,
        .let_ => |let_value| valueType(program, let_value.body.*),
        .if_ => |if_value| if_value.ty,
        .match_ => |match_value| match_value.ty,
        .tag => |tag| tag.ty,
        .record => |record| record.ty,
        .tuple => |tuple| tuple.ty,
        .nominal => |nominal| nominal.ty,
        .callable => |callable| callable.ty,
        .finite_tags => |finite_tags| finite_tags.ty,
        .finite_callables => |finite_callables| finite_callables.ty,
        .private_state => |private_state| privateStateValueType(private_state),
    };
}

fn leafKnownValueFromValue(program: *const Ast.Program, value: Value) Allocator.Error!?KnownValue {
    return switch (value) {
        .expr => |expr| switch (program.exprs.items[@intFromEnum(expr)].data) {
            .local => blk: {
                const ty = program.exprs.items[@intFromEnum(expr)].ty;
                if (try typeMayContainRefcounted(program, ty)) break :blk null;
                break :blk KnownValue{ .leaf = ty };
            },
            else => null,
        },
        else => null,
    };
}

fn typeMayContainRefcounted(program: *const Ast.Program, ty: Type.TypeId) Allocator.Error!bool {
    var stack = std.ArrayList(Type.TypeId).empty;
    defer stack.deinit(program.allocator);
    return try typeMayContainRefcountedInner(program, ty, &stack);
}

fn typeMayContainRefcountedInner(
    program: *const Ast.Program,
    ty: Type.TypeId,
    stack: *std.ArrayList(Type.TypeId),
) Allocator.Error!bool {
    for (stack.items) |active| {
        if (active == ty) return true;
    }

    try stack.append(program.allocator, ty);
    defer _ = stack.pop();

    return switch (program.types.get(ty)) {
        .primitive => |primitive| primitive == .str,
        .named => |named| if (named.backing) |backing|
            try typeMayContainRefcountedInner(program, backing.ty, stack)
        else
            true,
        .record => |fields_span| blk: {
            for (program.types.fieldSpan(fields_span)) |field| {
                if (try typeMayContainRefcountedInner(program, field.ty, stack)) break :blk true;
            }
            break :blk false;
        },
        .tuple => |items_span| blk: {
            for (program.types.span(items_span)) |item| {
                if (try typeMayContainRefcountedInner(program, item, stack)) break :blk true;
            }
            break :blk false;
        },
        .tag_union => |tags_span| blk: {
            for (program.types.tagSpan(tags_span)) |tag| {
                for (program.types.span(tag.payloads)) |payload| {
                    if (try typeMayContainRefcountedInner(program, payload, stack)) break :blk true;
                }
            }
            break :blk false;
        },
        .zst => false,
        .list,
        .box,
        .func,
        .erased,
        => true,
    };
}

/// Whether two Monotype ids denote the same type. The type store is not
/// interned: each specialization materializes its own ids, so structurally
/// identical types reached from different specializations (a call site and
/// the callee's own body) carry different ids and compare by digest.
fn sameType(program: *const Ast.Program, lhs: Type.TypeId, rhs: Type.TypeId) bool {
    if (lhs == rhs) return true;
    const lhs_digest = program.types.typeDigest(&program.names, lhs);
    const rhs_digest = program.types.typeDigest(&program.names, rhs);
    return std.mem.eql(u8, &lhs_digest.bytes, &rhs_digest.bytes);
}

fn patternEql(program: *const Ast.Program, lhs: CallPattern, rhs: CallPattern) bool {
    if (lhs.args.len != rhs.args.len) return false;
    for (lhs.args, rhs.args) |lhs_arg, rhs_arg| {
        if (!known_valueEql(program, lhs_arg, rhs_arg)) return false;
    }
    return true;
}

fn valueDemandEql(lhs: ValueDemand, rhs: ValueDemand) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .none,
        .materialize,
        => true,
        .loop_param => lhs.loop_param == rhs.loop_param,
        .record => |lhs_fields| blk: {
            const rhs_fields = rhs.record;
            if (lhs_fields.len != rhs_fields.len) break :blk false;
            for (lhs_fields) |lhs_field| {
                const rhs_field = fieldDemandByName(rhs_fields, lhs_field.name) orelse break :blk false;
                if (!valueDemandEql(lhs_field.demand.*, rhs_field.demand.*)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |lhs_items| blk: {
            const rhs_items = rhs.tuple;
            if (lhs_items.len != rhs_items.len) break :blk false;
            for (lhs_items) |lhs_item| {
                const rhs_item = itemDemandByIndex(rhs_items, lhs_item.index) orelse break :blk false;
                if (!valueDemandEql(lhs_item.demand.*, rhs_item.demand.*)) break :blk false;
            }
            break :blk true;
        },
        .tag => |lhs_tag| blk: {
            const rhs_payloads = rhs.tag.payloads;
            if (lhs_tag.payloads.len != rhs_payloads.len) break :blk false;
            for (lhs_tag.payloads) |lhs_payload| {
                const rhs_payload = itemDemandByIndex(rhs_payloads, lhs_payload.index) orelse break :blk false;
                if (!valueDemandEql(lhs_payload.demand.*, rhs_payload.demand.*)) break :blk false;
            }
            break :blk true;
        },
        .nominal => valueDemandEql(lhs.nominal.*, rhs.nominal.*),
        .callable => |lhs_callable| blk: {
            const rhs_callable = rhs.callable;
            if (lhs_callable.captures.len != rhs_callable.captures.len) break :blk false;
            for (lhs_callable.captures, rhs_callable.captures) |lhs_capture, rhs_capture| {
                if (!valueDemandEql(lhs_capture, rhs_capture)) break :blk false;
            }
            if (lhs_callable.result == null or rhs_callable.result == null) {
                if (lhs_callable.result != null or rhs_callable.result != null) break :blk false;
            } else if (!valueDemandEql(lhs_callable.result.?.*, rhs_callable.result.?.*)) {
                break :blk false;
            }
            break :blk true;
        },
    };
}

fn ifValueControlEql(lhs: IfValue, rhs: IfValue) bool {
    if (lhs.branches.len != rhs.branches.len) return false;
    for (lhs.branches, rhs.branches) |lhs_branch, rhs_branch| {
        if (lhs_branch.cond != rhs_branch.cond) return false;
    }
    return true;
}

fn matchValueControlEql(lhs: MatchValue, rhs: MatchValue) bool {
    if (lhs.scrutinee != rhs.scrutinee) return false;
    if (lhs.comptime_site != rhs.comptime_site) return false;
    if (lhs.branches.len != rhs.branches.len) return false;
    for (lhs.branches, rhs.branches) |lhs_branch, rhs_branch| {
        if (lhs_branch.pat != rhs_branch.pat) return false;
        if (lhs_branch.guard != rhs_branch.guard) return false;
    }
    return true;
}

fn fieldDemandByName(fields: []const FieldDemand, name: names.RecordFieldNameId) ?FieldDemand {
    for (fields) |field| {
        if (field.name == name) return field;
    }
    return null;
}

fn itemDemandByIndex(items: []const ItemDemand, index: u32) ?ItemDemand {
    for (items) |item| {
        if (item.index == index) return item;
    }
    return null;
}

fn joinKnownValuesInArena(
    program: *const Ast.Program,
    arena: Allocator,
    lhs: KnownValue,
    rhs: KnownValue,
) Allocator.Error!?KnownValue {
    if (known_valueEql(program, lhs, rhs)) return lhs;
    if (!sameType(program, known_valueType(lhs), known_valueType(rhs))) return null;
    if (try commonKnownTags(program, arena, lhs, rhs)) |finite_tags| return finite_tags;
    if (try commonKnownCallables(program, arena, lhs, rhs)) |finite_callables| return finite_callables;

    return switch (lhs) {
        .any => |ty| KnownValue{ .any = ty },
        .leaf => |ty| blk: {
            const rhs_ty = switch (rhs) {
                .leaf => |rhs_ty| rhs_ty,
                else => break :blk null,
            };
            break :blk if (sameType(program, ty, rhs_ty)) KnownValue{ .leaf = ty } else null;
        },
        .tag => |lhs_tag| blk: {
            const rhs_tag = switch (rhs) {
                .tag => |tag| tag,
                else => break :blk null,
            };
            if (lhs_tag.name != rhs_tag.name or lhs_tag.payloads.len != rhs_tag.payloads.len) break :blk null;
            const payloads = try arena.alloc(KnownValue, lhs_tag.payloads.len);
            for (lhs_tag.payloads, rhs_tag.payloads, 0..) |lhs_payload, rhs_payload, index| {
                payloads[index] = (try joinKnownValuesInArena(program, arena, lhs_payload, rhs_payload)) orelse
                    (joinUnknownChild(program, lhs_payload, rhs_payload) orelse break :blk null);
            }
            break :blk KnownValue{ .tag = .{
                .ty = lhs_tag.ty,
                .name = lhs_tag.name,
                .payloads = payloads,
            } };
        },
        .record => |lhs_record| blk: {
            const rhs_record = switch (rhs) {
                .record => |record| record,
                else => break :blk null,
            };
            if (lhs_record.fields.len != rhs_record.fields.len) break :blk null;
            const fields = try arena.alloc(KnownField, lhs_record.fields.len);
            for (lhs_record.fields, rhs_record.fields, 0..) |lhs_field, rhs_field, index| {
                if (lhs_field.name != rhs_field.name) break :blk null;
                fields[index] = .{
                    .name = lhs_field.name,
                    .known_value = (try joinKnownValuesInArena(program, arena, lhs_field.known_value, rhs_field.known_value)) orelse
                        (joinUnknownChild(program, lhs_field.known_value, rhs_field.known_value) orelse break :blk null),
                };
            }
            break :blk KnownValue{ .record = .{
                .ty = lhs_record.ty,
                .fields = fields,
            } };
        },
        .tuple => |lhs_tuple| blk: {
            const rhs_tuple = switch (rhs) {
                .tuple => |tuple| tuple,
                else => break :blk null,
            };
            if (lhs_tuple.items.len != rhs_tuple.items.len) break :blk null;
            const items = try arena.alloc(KnownValue, lhs_tuple.items.len);
            for (lhs_tuple.items, rhs_tuple.items, 0..) |lhs_item, rhs_item, index| {
                items[index] = (try joinKnownValuesInArena(program, arena, lhs_item, rhs_item)) orelse
                    (joinUnknownChild(program, lhs_item, rhs_item) orelse break :blk null);
            }
            break :blk KnownValue{ .tuple = .{
                .ty = lhs_tuple.ty,
                .items = items,
            } };
        },
        .nominal => |lhs_nominal| blk: {
            const rhs_nominal = switch (rhs) {
                .nominal => |nominal| nominal,
                else => break :blk null,
            };
            const backing = (try joinKnownValuesInArena(program, arena, lhs_nominal.backing.*, rhs_nominal.backing.*)) orelse break :blk null;
            const stored = try arena.create(KnownValue);
            stored.* = backing;
            break :blk KnownValue{ .nominal = .{
                .ty = lhs_nominal.ty,
                .backing = stored,
            } };
        },
        .callable => |lhs_callable| blk: {
            const rhs_callable = switch (rhs) {
                .callable => |callable| callable,
                else => break :blk null,
            };
            if (!callableTargetMatches(program, lhs_callable.fn_id, rhs_callable.fn_id) or
                lhs_callable.captures.len != rhs_callable.captures.len)
            {
                break :blk null;
            }
            const captures = try arena.alloc(KnownValue, lhs_callable.captures.len);
            for (lhs_callable.captures, rhs_callable.captures, 0..) |lhs_capture, rhs_capture, index| {
                captures[index] = (try joinKnownValuesInArena(program, arena, lhs_capture, rhs_capture)) orelse
                    (joinUnknownChild(program, lhs_capture, rhs_capture) orelse break :blk null);
            }
            break :blk KnownValue{ .callable = .{
                .ty = lhs_callable.ty,
                .fn_id = lhs_callable.fn_id,
                .captures = captures,
            } };
        },
        .finite_tags => null,
        .finite_callables => null,
    };
}

fn joinUnknownChild(program: *const Ast.Program, lhs: KnownValue, rhs: KnownValue) ?KnownValue {
    const lhs_ty = known_valueType(lhs);
    return if (sameType(program, lhs_ty, known_valueType(rhs)))
        KnownValue{ .any = lhs_ty }
    else
        null;
}

fn known_valuesStrictlyDescend(program: *const Ast.Program, active: []const KnownValue, next: []const KnownValue) bool {
    if (active.len != next.len) return false;
    var descended = false;
    for (active, next) |active_known_value, next_known_value| {
        if (known_valueEql(program, active_known_value, next_known_value)) continue;
        if (!known_valueContainsStrictSubknown_value(program, active_known_value, next_known_value)) return false;
        descended = true;
    }
    return descended;
}

fn known_valueContainsStrictSubknown_value(program: *const Ast.Program, container: KnownValue, needle: KnownValue) bool {
    return switch (container) {
        .any => false,
        .leaf => false,
        .tag => |tag| {
            for (tag.payloads) |payload| {
                if (known_valueEql(program, payload, needle) or known_valueContainsStrictSubknown_value(program, payload, needle)) return true;
            }
            return false;
        },
        .record => |record| {
            for (record.fields) |field| {
                if (known_valueEql(program, field.known_value, needle) or known_valueContainsStrictSubknown_value(program, field.known_value, needle)) return true;
            }
            return false;
        },
        .tuple => |tuple| {
            for (tuple.items) |item| {
                if (known_valueEql(program, item, needle) or known_valueContainsStrictSubknown_value(program, item, needle)) return true;
            }
            return false;
        },
        .nominal => |nominal| {
            return known_valueEql(program, nominal.backing.*, needle) or known_valueContainsStrictSubknown_value(program, nominal.backing.*, needle);
        },
        .callable => |callable| {
            for (callable.captures) |capture| {
                if (known_valueEql(program, capture, needle) or known_valueContainsStrictSubknown_value(program, capture, needle)) return true;
            }
            return false;
        },
        .finite_tags => |finite_tags| {
            for (finite_tags.alternatives) |alternative| {
                for (alternative.payloads) |payload| {
                    if (known_valueEql(program, payload, needle) or known_valueContainsStrictSubknown_value(program, payload, needle)) return true;
                }
            }
            return false;
        },
        .finite_callables => |finite_callables| {
            for (finite_callables.alternatives) |alternative| {
                for (alternative.captures) |capture| {
                    if (known_valueEql(program, capture, needle) or known_valueContainsStrictSubknown_value(program, capture, needle)) return true;
                }
            }
            return false;
        },
    };
}

fn knownValuesContainFiniteState(known_values: []const KnownValue) bool {
    for (known_values) |known_value| {
        if (knownValueContainsFiniteState(known_value)) return true;
    }
    return false;
}

fn knownValueContainsFiniteState(known_value: KnownValue) bool {
    return switch (known_value) {
        .any,
        .leaf,
        => false,
        .tag => |tag| blk: {
            for (tag.payloads) |payload| {
                if (knownValueContainsFiniteState(payload)) break :blk true;
            }
            break :blk false;
        },
        .record => |record| blk: {
            for (record.fields) |field| {
                if (knownValueContainsFiniteState(field.known_value)) break :blk true;
            }
            break :blk false;
        },
        .tuple => |tuple| blk: {
            for (tuple.items) |item| {
                if (knownValueContainsFiniteState(item)) break :blk true;
            }
            break :blk false;
        },
        .nominal => |nominal| knownValueContainsFiniteState(nominal.backing.*),
        .callable => |callable| blk: {
            for (callable.captures) |capture| {
                if (knownValueContainsFiniteState(capture)) break :blk true;
            }
            break :blk false;
        },
        .finite_tags,
        .finite_callables,
        => true,
    };
}

fn demandedKnownValueFromDemand(
    cloner: ?*Cloner,
    program: ?*const Ast.Program,
    arena: Allocator,
    known_value: KnownValue,
    demand: ValueDemand,
) Allocator.Error!?DemandedKnownValue {
    return switch (demand) {
        .none => null,
        .materialize => try materializedDemandedKnownValue(arena, known_value),
        .loop_param => blk: {
            const active_cloner = cloner orelse Common.invariant("loop demand reference had no active cloner");
            const resolved = active_cloner.resolveLoopDemandRef(demand);
            if (resolved == .loop_param) Common.invariant("loop demand reference resolved to itself");
            break :blk try demandedKnownValueFromDemand(cloner, program, arena, known_value, resolved);
        },
        .record => |field_demands| blk: {
            if (known_value == .nominal) {
                const demanded_backing = (try demandedKnownValueFromDemand(cloner, program, arena, known_value.nominal.backing.*, demand)) orelse break :blk null;
                const backing = try arena.create(DemandedKnownValue);
                backing.* = demanded_backing;
                break :blk DemandedKnownValue{ .nominal = .{
                    .ty = known_value.nominal.ty,
                    .backing = backing,
                } };
            }
            if (known_value == .any) {
                const program_ref = program orelse break :blk null;
                const ty = known_value.any;
                var fields = std.ArrayList(DemandedKnownField).empty;
                defer fields.deinit(arena);
                for (field_demands) |field_demand| {
                    const field_ty = recordFieldType(program_ref, ty, field_demand.name) orelse break :blk null;
                    const demanded_field = (try demandedKnownValueFromDemand(
                        cloner,
                        program,
                        arena,
                        .{ .any = field_ty },
                        field_demand.demand.*,
                    )) orelse continue;
                    try fields.append(arena, .{
                        .name = field_demand.name,
                        .known_value = demanded_field,
                    });
                }
                if (fields.items.len == 0) break :blk null;
                break :blk DemandedKnownValue{ .record = .{
                    .ty = ty,
                    .fields = try arena.dupe(DemandedKnownField, fields.items),
                } };
            }
            const record = switch (known_value) {
                .record => |record| record,
                else => break :blk null,
            };

            var fields = std.ArrayList(DemandedKnownField).empty;
            defer fields.deinit(arena);
            for (record.fields) |field| {
                const field_demand = fieldDemandByName(field_demands, field.name) orelse continue;
                const demanded_field = (try demandedKnownValueFromDemand(cloner, program, arena, field.known_value, field_demand.demand.*)) orelse continue;
                try fields.append(arena, .{
                    .name = field.name,
                    .known_value = demanded_field,
                });
            }
            if (fields.items.len == 0) break :blk null;
            break :blk DemandedKnownValue{ .record = .{
                .ty = record.ty,
                .fields = try arena.dupe(DemandedKnownField, fields.items),
            } };
        },
        .tuple => |item_demands| blk: {
            if (known_value == .nominal) {
                const demanded_backing = (try demandedKnownValueFromDemand(cloner, program, arena, known_value.nominal.backing.*, demand)) orelse break :blk null;
                const backing = try arena.create(DemandedKnownValue);
                backing.* = demanded_backing;
                break :blk DemandedKnownValue{ .nominal = .{
                    .ty = known_value.nominal.ty,
                    .backing = backing,
                } };
            }
            if (known_value == .any) {
                const program_ref = program orelse break :blk null;
                const ty = known_value.any;
                var items = std.ArrayList(DemandedKnownIndexedValue).empty;
                defer items.deinit(arena);
                for (item_demands) |item_demand| {
                    const item_ty = tupleItemType(program_ref, ty, item_demand.index) orelse break :blk null;
                    const demanded_item = (try demandedKnownValueFromDemand(
                        cloner,
                        program,
                        arena,
                        .{ .any = item_ty },
                        item_demand.demand.*,
                    )) orelse continue;
                    try items.append(arena, .{
                        .index = item_demand.index,
                        .known_value = demanded_item,
                    });
                }
                if (items.items.len == 0) break :blk null;
                break :blk DemandedKnownValue{ .tuple = .{
                    .ty = ty,
                    .items = try arena.dupe(DemandedKnownIndexedValue, items.items),
                } };
            }
            const tuple = switch (known_value) {
                .tuple => |tuple| tuple,
                else => break :blk null,
            };

            var items = std.ArrayList(DemandedKnownIndexedValue).empty;
            defer items.deinit(arena);
            for (tuple.items, 0..) |item, index| {
                const item_demand = itemDemandByIndex(item_demands, @intCast(index)) orelse continue;
                const demanded_item = (try demandedKnownValueFromDemand(cloner, program, arena, item, item_demand.demand.*)) orelse continue;
                try items.append(arena, .{
                    .index = @intCast(index),
                    .known_value = demanded_item,
                });
            }
            if (items.items.len == 0) break :blk null;
            break :blk DemandedKnownValue{ .tuple = .{
                .ty = tuple.ty,
                .items = try arena.dupe(DemandedKnownIndexedValue, items.items),
            } };
        },
        .tag => |tag_demand| blk: {
            if (known_value == .nominal) {
                const demanded_backing = (try demandedKnownValueFromDemand(cloner, program, arena, known_value.nominal.backing.*, demand)) orelse break :blk null;
                const backing = try arena.create(DemandedKnownValue);
                backing.* = demanded_backing;
                break :blk DemandedKnownValue{ .nominal = .{
                    .ty = known_value.nominal.ty,
                    .backing = backing,
                } };
            }

            switch (known_value) {
                .tag => |tag| {
                    var payloads = std.ArrayList(DemandedKnownIndexedValue).empty;
                    defer payloads.deinit(arena);
                    for (tag.payloads, 0..) |payload, index| {
                        const payload_demand = itemDemandByIndex(tag_demand.payloads, @intCast(index)) orelse continue;
                        const demanded_payload = (try demandedKnownValueFromDemand(cloner, program, arena, payload, payload_demand.demand.*)) orelse continue;
                        try payloads.append(arena, .{
                            .index = @intCast(index),
                            .known_value = demanded_payload,
                        });
                    }
                    break :blk DemandedKnownValue{ .tag = .{
                        .ty = tag.ty,
                        .name = tag.name,
                        .payloads = try arena.dupe(DemandedKnownIndexedValue, payloads.items),
                    } };
                },
                .finite_tags => |finite_tags| {
                    const alternatives = try arena.alloc(DemandedKnownTag, finite_tags.alternatives.len);
                    for (finite_tags.alternatives, alternatives) |alternative, *out| {
                        var payloads = std.ArrayList(DemandedKnownIndexedValue).empty;
                        defer payloads.deinit(arena);
                        for (alternative.payloads, 0..) |payload, index| {
                            const payload_demand = itemDemandByIndex(tag_demand.payloads, @intCast(index)) orelse continue;
                            const demanded_payload = (try demandedKnownValueFromDemand(cloner, program, arena, payload, payload_demand.demand.*)) orelse continue;
                            try payloads.append(arena, .{
                                .index = @intCast(index),
                                .known_value = demanded_payload,
                            });
                        }
                        out.* = .{
                            .ty = alternative.ty,
                            .name = alternative.name,
                            .payloads = try arena.dupe(DemandedKnownIndexedValue, payloads.items),
                        };
                    }
                    break :blk DemandedKnownValue{ .finite_tags = .{
                        .ty = finite_tags.ty,
                        .alternatives = alternatives,
                    } };
                },
                else => break :blk null,
            }
        },
        .nominal => |backing_demand| blk: {
            const nominal = switch (known_value) {
                .nominal => |nominal| nominal,
                else => break :blk null,
            };
            const demanded_backing = (try demandedKnownValueFromDemand(cloner, program, arena, nominal.backing.*, backing_demand.*)) orelse break :blk null;
            const backing = try arena.create(DemandedKnownValue);
            backing.* = demanded_backing;
            break :blk DemandedKnownValue{ .nominal = .{
                .ty = nominal.ty,
                .backing = backing,
            } };
        },
        .callable => |callable_demand| blk: {
            if (known_value == .nominal) {
                const demanded_backing = (try demandedKnownValueFromDemand(cloner, program, arena, known_value.nominal.backing.*, demand)) orelse break :blk null;
                const backing = try arena.create(DemandedKnownValue);
                backing.* = demanded_backing;
                break :blk DemandedKnownValue{ .nominal = .{
                    .ty = known_value.nominal.ty,
                    .backing = backing,
                } };
            }

            var effective_callable_demand = callable_demand;
            if (cloner) |active_cloner| {
                if (callable_demand.result) |result_demand| {
                    const concrete_demand = switch (known_value) {
                        .callable => |callable| try active_cloner.callableDemandForFnWithResultDemand(
                            callable.fn_id,
                            callable.captures.len,
                            result_demand.*,
                        ),
                        .finite_callables => |finite_callables| concrete: {
                            var alternative_demand: ValueDemand = .{ .callable = .{ .captures = &.{} } };
                            for (finite_callables.alternatives) |alternative| {
                                alternative_demand = try active_cloner.pass.mergeValueDemand(
                                    alternative_demand,
                                    try active_cloner.callableDemandForFnWithResultDemand(
                                        alternative.fn_id,
                                        alternative.captures.len,
                                        result_demand.*,
                                    ),
                                );
                            }
                            break :concrete alternative_demand;
                        },
                        else => null,
                    };
                    if (concrete_demand) |concrete| {
                        const merged = try active_cloner.pass.mergeValueDemand(.{ .callable = callable_demand }, concrete);
                        if (merged == .callable) effective_callable_demand = merged.callable;
                    }
                }
            }

            switch (known_value) {
                .callable => |callable| {
                    const captures = try demandedKnownCapturesFromDemand(cloner, program, arena, callable.fn_id, callable.captures, effective_callable_demand);
                    break :blk DemandedKnownValue{ .callable = .{
                        .ty = callable.ty,
                        .fn_id = callable.fn_id,
                        .captures = captures,
                    } };
                },
                .finite_callables => |finite_callables| {
                    const alternatives = try arena.alloc(DemandedKnownCallable, finite_callables.alternatives.len);
                    for (finite_callables.alternatives, alternatives) |alternative, *out| {
                        const captures = try demandedKnownCapturesFromDemand(cloner, program, arena, alternative.fn_id, alternative.captures, effective_callable_demand);
                        out.* = .{
                            .ty = alternative.ty,
                            .fn_id = alternative.fn_id,
                            .captures = captures,
                        };
                    }
                    break :blk DemandedKnownValue{ .finite_callables = .{
                        .ty = finite_callables.ty,
                        .alternatives = alternatives,
                    } };
                },
                else => break :blk null,
            }
        },
    };
}

fn materializedDemandedKnownValue(arena: Allocator, known_value: KnownValue) Allocator.Error!DemandedKnownValue {
    return switch (known_value) {
        .any => |ty| .{ .any = ty },
        .leaf => |ty| .{ .leaf = ty },
        .tag => |tag| .{ .tag = .{
            .ty = tag.ty,
            .name = tag.name,
            .payloads = try materializedDemandedKnownIndexedValues(arena, tag.payloads),
        } },
        .record => |record| blk: {
            const fields = try arena.alloc(DemandedKnownField, record.fields.len);
            for (record.fields, fields) |field, *out| {
                out.* = .{
                    .name = field.name,
                    .known_value = try materializedDemandedKnownValue(arena, field.known_value),
                };
            }
            break :blk DemandedKnownValue{ .record = .{
                .ty = record.ty,
                .fields = fields,
            } };
        },
        .tuple => |tuple| .{ .tuple = .{
            .ty = tuple.ty,
            .items = try materializedDemandedKnownIndexedValues(arena, tuple.items),
        } },
        .nominal => |nominal| blk: {
            const backing = try arena.create(DemandedKnownValue);
            backing.* = try materializedDemandedKnownValue(arena, nominal.backing.*);
            break :blk DemandedKnownValue{ .nominal = .{
                .ty = nominal.ty,
                .backing = backing,
            } };
        },
        .callable => |callable| .{ .callable = .{
            .ty = callable.ty,
            .fn_id = callable.fn_id,
            .captures = try materializedDemandedKnownIndexedValues(arena, callable.captures),
        } },
        .finite_tags => |finite_tags| blk: {
            const alternatives = try arena.alloc(DemandedKnownTag, finite_tags.alternatives.len);
            for (finite_tags.alternatives, alternatives) |alternative, *out| {
                out.* = .{
                    .ty = alternative.ty,
                    .name = alternative.name,
                    .payloads = try materializedDemandedKnownIndexedValues(arena, alternative.payloads),
                };
            }
            break :blk DemandedKnownValue{ .finite_tags = .{
                .ty = finite_tags.ty,
                .alternatives = alternatives,
            } };
        },
        .finite_callables => |finite_callables| blk: {
            const alternatives = try arena.alloc(DemandedKnownCallable, finite_callables.alternatives.len);
            for (finite_callables.alternatives, alternatives) |alternative, *out| {
                out.* = .{
                    .ty = alternative.ty,
                    .fn_id = alternative.fn_id,
                    .captures = try materializedDemandedKnownIndexedValues(arena, alternative.captures),
                };
            }
            break :blk DemandedKnownValue{ .finite_callables = .{
                .ty = finite_callables.ty,
                .alternatives = alternatives,
            } };
        },
    };
}

fn materializedDemandedKnownIndexedValues(
    arena: Allocator,
    values: []const KnownValue,
) Allocator.Error![]const DemandedKnownIndexedValue {
    const indexed = try arena.alloc(DemandedKnownIndexedValue, values.len);
    for (values, indexed, 0..) |known_value, *out, index| {
        out.* = .{
            .index = @intCast(index),
            .known_value = try materializedDemandedKnownValue(arena, known_value),
        };
    }
    return indexed;
}

fn demandedKnownCapturesFromDemand(
    cloner: ?*Cloner,
    program: ?*const Ast.Program,
    arena: Allocator,
    fn_id: Ast.FnId,
    captures: []const KnownValue,
    demand: CallableDemand,
) Allocator.Error![]const DemandedKnownIndexedValue {
    var demanded = std.ArrayList(DemandedKnownIndexedValue).empty;
    defer demanded.deinit(arena);
    for (demand.captures, 0..) |capture_demand, index| {
        if (capture_demand == .none) continue;
        const demanded_capture = if (index < captures.len)
            (try demandedKnownValueFromDemand(cloner, program, arena, captures[index], capture_demand)) orelse DemandedKnownValue{ .any = known_valueType(captures[index]) }
        else blk: {
            const program_ref = program orelse Common.invariant("missing callable capture demand had no program for source capture type");
            const source_fn = program_ref.fns.items[@intFromEnum(fn_id)];
            const source_captures = program_ref.typedLocalSpan(source_fn.captures);
            if (index >= source_captures.len) Common.invariant("callable demand capture index exceeded lifted function capture count");
            break :blk DemandedKnownValue{ .any = source_captures[index].ty };
        };
        try demanded.append(arena, .{
            .index = @intCast(index),
            .known_value = demanded_capture,
        });
    }
    return try arena.dupe(DemandedKnownIndexedValue, demanded.items);
}

fn demandedKnownValuesContainFiniteState(known_values: []const DemandedKnownValue) bool {
    for (known_values) |known_value| {
        if (demandedKnownValueContainsFiniteState(known_value)) return true;
    }
    return false;
}

fn valueDemandsRequirePrivateState(demands: []const ValueDemand) bool {
    for (demands) |demand| {
        if (valueDemandRequiresPrivateState(demand)) return true;
    }
    return false;
}

fn valueDemandRequiresPrivateState(demand: ValueDemand) bool {
    return switch (demand) {
        .none,
        .materialize,
        => false,
        .loop_param,
        .record,
        .tuple,
        .tag,
        .nominal,
        .callable,
        => true,
    };
}

fn demandedKnownValueContainsFiniteState(known_value: DemandedKnownValue) bool {
    return switch (known_value) {
        .any,
        .leaf,
        => false,
        .tag => |tag| blk: {
            for (tag.payloads) |payload| {
                if (demandedKnownValueContainsFiniteState(payload.known_value)) break :blk true;
            }
            break :blk false;
        },
        .record => |record| blk: {
            for (record.fields) |field| {
                if (demandedKnownValueContainsFiniteState(field.known_value)) break :blk true;
            }
            break :blk false;
        },
        .tuple => |tuple| blk: {
            for (tuple.items) |item| {
                if (demandedKnownValueContainsFiniteState(item.known_value)) break :blk true;
            }
            break :blk false;
        },
        .nominal => |nominal| if (nominal.backing) |backing| demandedKnownValueContainsFiniteState(backing.*) else false,
        .callable => |callable| blk: {
            for (callable.captures) |capture| {
                if (demandedKnownValueContainsFiniteState(capture.known_value)) break :blk true;
            }
            break :blk false;
        },
        .finite_tags,
        .finite_callables,
        => true,
    };
}

fn demandedKnownValueType(known_value: DemandedKnownValue) Type.TypeId {
    return switch (known_value) {
        .any => |ty| ty,
        .leaf => |ty| ty,
        .tag => |tag| tag.ty,
        .record => |record| record.ty,
        .tuple => |tuple| tuple.ty,
        .nominal => |nominal| nominal.ty,
        .callable => |callable| callable.ty,
        .finite_tags => |finite_tags| finite_tags.ty,
        .finite_callables => |finite_callables| finite_callables.ty,
    };
}

fn privateStateValueType(value: PrivateStateValue) Type.TypeId {
    return switch (value) {
        .leaf => |leaf| leaf.ty,
        .tag => |tag| tag.ty,
        .record => |record| record.ty,
        .tuple => |tuple| tuple.ty,
        .nominal => |nominal| nominal.ty,
        .callable => |callable| callable.ty,
        .finite_tags => |finite_tags| finite_tags.ty,
        .finite_callables => |finite_callables| finite_callables.ty,
    };
}

fn privateStateField(value: PrivateStateValue, name: names.RecordFieldNameId) ?PrivateStateValue {
    return switch (value) {
        .record => |record| privateStateFieldByName(record.fields, name),
        .nominal => |nominal| if (nominal.backing) |backing| privateStateField(backing.*, name) else null,
        else => null,
    };
}

fn privateStateRecordIsDense(program: *const Ast.Program, record: PrivateStateRecord) bool {
    const type_fields = recordTypeFields(program, record.ty);
    if (type_fields.len != record.fields.len) return false;
    for (type_fields) |type_field| {
        _ = privateStateFieldByName(record.fields, type_field.name) orelse return false;
    }
    return true;
}

fn privateStateCanMaterializePublic(program: *const Ast.Program, value: PrivateStateValue) bool {
    return switch (value) {
        .leaf => true,
        .record => |record| blk: {
            const type_fields = recordTypeFields(program, record.ty);
            if (type_fields.len != record.fields.len) break :blk false;
            for (type_fields) |type_field| {
                const field = privateStateFieldByName(record.fields, type_field.name) orelse break :blk false;
                if (!sameType(program, type_field.ty, privateStateValueType(field))) break :blk false;
                if (!privateStateCanMaterializePublic(program, field)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |tuple| blk: {
            const type_items = tupleTypeItems(program, tuple.ty);
            if (!privateStateIndexedValuesAreDense(tuple.items, type_items.len)) break :blk false;
            for (type_items, 0..) |item_ty, index| {
                const item = privateStateIndexedValueByIndex(tuple.items, @intCast(index)) orelse break :blk false;
                if (!sameType(program, item_ty, privateStateValueType(item))) break :blk false;
                if (!privateStateCanMaterializePublic(program, item)) break :blk false;
            }
            break :blk true;
        },
        .tag => |tag| privateStateTagCanMaterializePublic(program, tag),
        .nominal => |nominal| blk: {
            const backing = nominal.backing orelse break :blk false;
            const backing_ty = nominalBackingType(program, nominal.ty) orelse break :blk false;
            if (!sameType(program, backing_ty, privateStateValueType(backing.*))) break :blk false;
            break :blk privateStateCanMaterializePublic(program, backing.*);
        },
        .callable => |callable| privateStateCallableCanMaterializePublic(program, callable),
        .finite_tags => |finite_tags| blk: {
            for (finite_tags.alternatives) |alternative| {
                if (!privateStateTagCanMaterializePublic(program, alternative)) break :blk false;
            }
            break :blk true;
        },
        .finite_callables => |finite_callables| blk: {
            for (finite_callables.alternatives) |alternative| {
                if (!privateStateCallableCanMaterializePublic(program, alternative)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn privateStateTagCanMaterializePublic(program: *const Ast.Program, tag: PrivateStateTag) bool {
    const payload_tys = tagTypePayloads(program, tag.ty, tag.name) orelse return false;
    if (!privateStateIndexedValuesAreDense(tag.payloads, payload_tys.len)) return false;
    for (payload_tys, 0..) |payload_ty, index| {
        const payload = privateStateIndexedValueByIndex(tag.payloads, @intCast(index)) orelse return false;
        if (!sameType(program, payload_ty, privateStateValueType(payload))) return false;
        if (!privateStateCanMaterializePublic(program, payload)) return false;
    }
    return true;
}

fn privateStateCallableCanMaterializePublic(program: *const Ast.Program, callable: PrivateStateCallable) bool {
    const source_fn = program.fns.items[@intFromEnum(callable.fn_id)];
    const source_captures = program.typedLocalSpan(source_fn.captures);
    if (!privateStateIndexedValuesAreDense(callable.captures, source_captures.len)) return false;
    for (source_captures, 0..) |source_capture, index| {
        const capture = privateStateIndexedValueByIndex(callable.captures, @intCast(index)) orelse return false;
        if (!sameType(program, source_capture.ty, privateStateValueType(capture))) return false;
        if (!privateStateCanMaterializePublic(program, capture)) return false;
    }
    return true;
}

fn privateStateIndexedValuesAreDense(indexed: []const PrivateStateIndexedValue, expected_len: usize) bool {
    if (indexed.len != expected_len) return false;
    var index: usize = 0;
    while (index < expected_len) : (index += 1) {
        _ = privateStateIndexedValueByIndex(indexed, @intCast(index)) orelse return false;
    }
    return true;
}

fn recordTypeFields(program: *const Ast.Program, ty: Type.TypeId) []const Type.Field {
    return switch (program.types.get(ty)) {
        .record => |fields| program.types.fieldSpan(fields),
        .named => |named| if (named.backing) |backing| recordTypeFields(program, backing.ty) else Common.invariant("named record has no backing"),
        else => Common.invariant("record operation expected record type"),
    };
}

fn recordFieldType(program: *const Ast.Program, ty: Type.TypeId, name: names.RecordFieldNameId) ?Type.TypeId {
    const fields = switch (program.types.get(ty)) {
        .record => |fields| program.types.fieldSpan(fields),
        .named => |named| if (named.backing) |backing| recordTypeFields(program, backing.ty) else return null,
        else => return null,
    };
    for (fields) |field| {
        if (field.name == name) return field.ty;
    }
    return null;
}

fn tupleTypeItems(program: *const Ast.Program, ty: Type.TypeId) []const Type.TypeId {
    return switch (program.types.get(ty)) {
        .tuple => |items| program.types.span(items),
        .named => |named| if (named.backing) |backing| tupleTypeItems(program, backing.ty) else Common.invariant("named tuple has no backing"),
        else => Common.invariant("tuple operation expected tuple type"),
    };
}

fn tupleItemType(program: *const Ast.Program, ty: Type.TypeId, index: u32) ?Type.TypeId {
    const items = switch (program.types.get(ty)) {
        .tuple => |items| program.types.span(items),
        .named => |named| if (named.backing) |backing| tupleTypeItems(program, backing.ty) else return null,
        else => return null,
    };
    if (index >= items.len) return null;
    return items[index];
}

fn tagTypePayloads(program: *const Ast.Program, ty: Type.TypeId, name: names.TagNameId) ?[]const Type.TypeId {
    return switch (program.types.get(ty)) {
        .tag_union => |tags| blk: {
            for (program.types.tagSpan(tags)) |tag| {
                if (tag.name == name) break :blk program.types.span(tag.payloads);
            }
            break :blk null;
        },
        .named => |named| if (named.backing) |backing| tagTypePayloads(program, backing.ty, name) else Common.invariant("named tag union has no backing"),
        else => Common.invariant("tag operation expected tag union type"),
    };
}

fn nominalBackingType(program: *const Ast.Program, ty: Type.TypeId) ?Type.TypeId {
    return switch (program.types.get(ty)) {
        .named => |named| if (named.backing) |backing| backing.ty else null,
        else => null,
    };
}

fn privateStateLeafExpr(value: PrivateStateValue) ?Ast.ExprId {
    return switch (value) {
        .leaf => |leaf| leaf.expr,
        else => null,
    };
}

fn privateStateItem(value: PrivateStateValue, index: u32) ?PrivateStateValue {
    return switch (value) {
        .tuple => |tuple| privateStateIndexedValueByIndex(tuple.items, index),
        .nominal => |nominal| if (nominal.backing) |backing| privateStateItem(backing.*, index) else null,
        else => null,
    };
}

fn privateStateTagPayload(value: PrivateStateValue, index: u32) ?PrivateStateValue {
    return switch (value) {
        .tag => |tag| privateStateIndexedValueByIndex(tag.payloads, index),
        .nominal => |nominal| if (nominal.backing) |backing| privateStateTagPayload(backing.*, index) else null,
        else => null,
    };
}

fn privateStateTag(value: PrivateStateValue) ?PrivateStateTag {
    return switch (value) {
        .tag => |tag| tag,
        .nominal => |nominal| if (nominal.backing) |backing| privateStateTag(backing.*) else null,
        else => null,
    };
}

fn privateStateFiniteTags(value: PrivateStateValue) ?PrivateStateFiniteTags {
    return switch (value) {
        .finite_tags => |finite_tags| finite_tags,
        .nominal => |nominal| if (nominal.backing) |backing| privateStateFiniteTags(backing.*) else null,
        else => null,
    };
}

fn privateStateCallableCapture(value: PrivateStateValue, index: u32) ?PrivateStateValue {
    return switch (value) {
        .callable => |callable| privateStateIndexedValueByIndex(callable.captures, index),
        .nominal => |nominal| if (nominal.backing) |backing| privateStateCallableCapture(backing.*, index) else null,
        else => null,
    };
}

fn privateStateCallable(value: PrivateStateValue) ?PrivateStateCallable {
    return switch (value) {
        .callable => |callable| callable,
        .nominal => |nominal| if (nominal.backing) |backing| privateStateCallable(backing.*) else null,
        else => null,
    };
}

fn privateStateFiniteCallables(value: PrivateStateValue) ?PrivateStateFiniteCallables {
    return switch (value) {
        .finite_callables => |finite_callables| finite_callables,
        .nominal => |nominal| if (nominal.backing) |backing| privateStateFiniteCallables(backing.*) else null,
        else => null,
    };
}

fn privateStateFieldByName(fields: []const PrivateStateField, name: names.RecordFieldNameId) ?PrivateStateValue {
    for (fields) |field| {
        if (field.name == name) return field.value;
    }
    return null;
}

fn fieldValueByName(fields: []const FieldValue, name: names.RecordFieldNameId) ?Value {
    for (fields) |field| {
        if (field.name == name) return field.value;
    }
    return null;
}

fn privateStateIndexedValueByIndex(items: []const PrivateStateIndexedValue, index: u32) ?PrivateStateValue {
    for (items) |item| {
        if (item.index == index) return item.value;
    }
    return null;
}

fn demandedKnownValuePrivateStateParamCount(known_value: DemandedKnownValue) usize {
    return switch (known_value) {
        .any,
        .leaf,
        => 1,
        .tag => |tag| demandedKnownIndexedValuesPrivateStateParamCount(tag.payloads),
        .record => |record| blk: {
            var count: usize = 0;
            for (record.fields) |field| {
                count += demandedKnownValuePrivateStateParamCount(field.known_value);
            }
            break :blk count;
        },
        .tuple => |tuple| demandedKnownIndexedValuesPrivateStateParamCount(tuple.items),
        .nominal => |nominal| if (nominal.backing) |backing| demandedKnownValuePrivateStateParamCount(backing.*) else 0,
        .callable => |callable| demandedKnownIndexedValuesPrivateStateParamCount(callable.captures),
        .finite_tags => |finite_tags| blk: {
            var max_count: usize = 0;
            for (finite_tags.alternatives) |alternative| {
                max_count = @max(max_count, demandedKnownIndexedValuesPrivateStateParamCount(alternative.payloads));
            }
            break :blk max_count;
        },
        .finite_callables => |finite_callables| blk: {
            var max_count: usize = 0;
            for (finite_callables.alternatives) |alternative| {
                max_count = @max(max_count, demandedKnownIndexedValuesPrivateStateParamCount(alternative.captures));
            }
            break :blk max_count;
        },
    };
}

fn demandedKnownIndexedValuesPrivateStateParamCount(values: []const DemandedKnownIndexedValue) usize {
    var count: usize = 0;
    for (values) |value| {
        count += demandedKnownValuePrivateStateParamCount(value.known_value);
    }
    return count;
}

fn demandedKnownValueEql(program: *const Ast.Program, lhs: DemandedKnownValue, rhs: DemandedKnownValue) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .any => |lhs_ty| sameType(program, lhs_ty, rhs.any),
        .leaf => |lhs_ty| sameType(program, lhs_ty, rhs.leaf),
        .tag => |lhs_tag| demandedKnownTagEql(program, lhs_tag, rhs.tag),
        .record => |lhs_record| blk: {
            const rhs_record = rhs.record;
            if (!sameType(program, lhs_record.ty, rhs_record.ty) or lhs_record.fields.len != rhs_record.fields.len) break :blk false;
            for (lhs_record.fields) |lhs_field| {
                const rhs_field = demandedKnownFieldByName(rhs_record.fields, lhs_field.name) orelse break :blk false;
                if (!demandedKnownValueEql(program, lhs_field.known_value, rhs_field.known_value)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |lhs_tuple| blk: {
            const rhs_tuple = rhs.tuple;
            if (!sameType(program, lhs_tuple.ty, rhs_tuple.ty) or lhs_tuple.items.len != rhs_tuple.items.len) break :blk false;
            for (lhs_tuple.items) |lhs_item| {
                const rhs_item = demandedKnownIndexedValueByIndex(rhs_tuple.items, lhs_item.index) orelse break :blk false;
                if (!demandedKnownValueEql(program, lhs_item.known_value, rhs_item.known_value)) break :blk false;
            }
            break :blk true;
        },
        .nominal => |lhs_nominal| blk: {
            const rhs_nominal = rhs.nominal;
            if (!sameType(program, lhs_nominal.ty, rhs_nominal.ty)) break :blk false;
            if (lhs_nominal.backing == null or rhs_nominal.backing == null) break :blk lhs_nominal.backing == null and rhs_nominal.backing == null;
            break :blk demandedKnownValueEql(program, lhs_nominal.backing.?.*, rhs_nominal.backing.?.*);
        },
        .callable => |lhs_callable| demandedKnownCallableEql(program, lhs_callable, rhs.callable),
        .finite_tags => |lhs_finite| blk: {
            const rhs_finite = rhs.finite_tags;
            if (!sameType(program, lhs_finite.ty, rhs_finite.ty) or lhs_finite.alternatives.len != rhs_finite.alternatives.len) break :blk false;
            for (lhs_finite.alternatives) |lhs_alternative| {
                for (rhs_finite.alternatives) |rhs_alternative| {
                    if (demandedKnownTagEql(program, lhs_alternative, rhs_alternative)) break;
                } else {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .finite_callables => |lhs_finite| blk: {
            const rhs_finite = rhs.finite_callables;
            if (!sameType(program, lhs_finite.ty, rhs_finite.ty) or lhs_finite.alternatives.len != rhs_finite.alternatives.len) break :blk false;
            for (lhs_finite.alternatives) |lhs_alternative| {
                for (rhs_finite.alternatives) |rhs_alternative| {
                    if (demandedKnownCallableEql(program, lhs_alternative, rhs_alternative)) break;
                } else {
                    break :blk false;
                }
            }
            break :blk true;
        },
    };
}

fn demandedKnownTagEql(program: *const Ast.Program, lhs: DemandedKnownTag, rhs: DemandedKnownTag) bool {
    if (!sameType(program, lhs.ty, rhs.ty) or lhs.name != rhs.name or lhs.payloads.len != rhs.payloads.len) return false;
    for (lhs.payloads) |lhs_payload| {
        const rhs_payload = demandedKnownIndexedValueByIndex(rhs.payloads, lhs_payload.index) orelse return false;
        if (!demandedKnownValueEql(program, lhs_payload.known_value, rhs_payload.known_value)) return false;
    }
    return true;
}

fn demandedKnownCallableEql(program: *const Ast.Program, lhs: DemandedKnownCallable, rhs: DemandedKnownCallable) bool {
    if (!sameType(program, lhs.ty, rhs.ty) or
        !callableTargetMatches(program, lhs.fn_id, rhs.fn_id) or
        lhs.captures.len != rhs.captures.len)
    {
        return false;
    }
    for (lhs.captures) |lhs_capture| {
        const rhs_capture = demandedKnownIndexedValueByIndex(rhs.captures, lhs_capture.index) orelse return false;
        if (!demandedKnownValueEql(program, lhs_capture.known_value, rhs_capture.known_value)) return false;
    }
    return true;
}

fn demandedKnownFieldByName(fields: []const DemandedKnownField, name: names.RecordFieldNameId) ?DemandedKnownField {
    for (fields) |field| {
        if (field.name == name) return field;
    }
    return null;
}

fn demandedKnownIndexedValueByIndex(items: []const DemandedKnownIndexedValue, index: u32) ?DemandedKnownIndexedValue {
    for (items) |item| {
        if (item.index == index) return item;
    }
    return null;
}

fn demandedKnownValueProducts(
    scratch: Allocator,
    arena: Allocator,
    known_values: []const DemandedKnownValue,
) Allocator.Error![]const []const DemandedKnownValue {
    const options = try scratch.alloc([]const DemandedKnownValue, known_values.len);
    defer scratch.free(options);
    for (known_values, 0..) |known_value, index| {
        options[index] = try expandDemandedKnownValue(scratch, arena, known_value);
    }

    var products = std.ArrayList([]const DemandedKnownValue).empty;
    defer products.deinit(scratch);
    const current = try scratch.alloc(DemandedKnownValue, known_values.len);
    defer scratch.free(current);

    try appendDemandedKnownValueProducts(scratch, arena, options, 0, current, &products);
    return try arena.dupe([]const DemandedKnownValue, products.items);
}

fn appendDemandedKnownValueProducts(
    scratch: Allocator,
    arena: Allocator,
    options: []const []const DemandedKnownValue,
    index: usize,
    current: []DemandedKnownValue,
    products: *std.ArrayList([]const DemandedKnownValue),
) Allocator.Error!void {
    if (index == options.len) {
        try products.append(scratch, try arena.dupe(DemandedKnownValue, current));
        return;
    }

    for (options[index]) |option| {
        current[index] = option;
        try appendDemandedKnownValueProducts(scratch, arena, options, index + 1, current, products);
    }
}

fn expandDemandedKnownValue(
    scratch: Allocator,
    arena: Allocator,
    known_value: DemandedKnownValue,
) Allocator.Error![]const DemandedKnownValue {
    return switch (known_value) {
        .any,
        .leaf,
        => try singleDemandedKnownValue(arena, known_value),
        .tag => |tag| try expandDemandedKnownTag(scratch, arena, tag),
        .record => |record| try expandDemandedKnownRecord(scratch, arena, record),
        .tuple => |tuple| try expandDemandedKnownTuple(scratch, arena, tuple),
        .nominal => |nominal| try expandDemandedKnownNominal(scratch, arena, nominal),
        .callable => |callable| try expandDemandedKnownCallable(scratch, arena, callable),
        .finite_tags => |finite_tags| try expandDemandedKnownTags(scratch, arena, finite_tags),
        .finite_callables => |finite_callables| try expandDemandedKnownCallables(scratch, arena, finite_callables),
    };
}

fn singleDemandedKnownValue(arena: Allocator, known_value: DemandedKnownValue) Allocator.Error![]const DemandedKnownValue {
    const values = try arena.alloc(DemandedKnownValue, 1);
    values[0] = known_value;
    return values;
}

fn expandDemandedKnownRecord(
    scratch: Allocator,
    arena: Allocator,
    record: DemandedKnownRecord,
) Allocator.Error![]const DemandedKnownValue {
    const child_values = try scratch.alloc(DemandedKnownValue, record.fields.len);
    defer scratch.free(child_values);
    for (record.fields, 0..) |field, index| {
        child_values[index] = field.known_value;
    }

    const products = try demandedKnownValueProducts(scratch, arena, child_values);
    const alternatives = try arena.alloc(DemandedKnownValue, products.len);
    for (products, alternatives) |product, *out| {
        const fields = try arena.alloc(DemandedKnownField, record.fields.len);
        for (record.fields, product, fields) |field, field_known_value, *field_out| {
            field_out.* = .{
                .name = field.name,
                .known_value = field_known_value,
            };
        }
        out.* = .{ .record = .{
            .ty = record.ty,
            .fields = fields,
        } };
    }
    return alternatives;
}

fn expandDemandedKnownTuple(
    scratch: Allocator,
    arena: Allocator,
    tuple: DemandedKnownTuple,
) Allocator.Error![]const DemandedKnownValue {
    const alternatives = try expandDemandedKnownIndexedValues(scratch, arena, tuple.items);
    const values = try arena.alloc(DemandedKnownValue, alternatives.len);
    for (alternatives, values) |items, *out| {
        out.* = .{ .tuple = .{
            .ty = tuple.ty,
            .items = items,
        } };
    }
    return values;
}

fn expandDemandedKnownNominal(
    scratch: Allocator,
    arena: Allocator,
    nominal: DemandedKnownNominal,
) Allocator.Error![]const DemandedKnownValue {
    const backing = nominal.backing orelse return try singleDemandedKnownValue(arena, .{ .nominal = nominal });
    const backing_alternatives = try expandDemandedKnownValue(scratch, arena, backing.*);
    const alternatives = try arena.alloc(DemandedKnownValue, backing_alternatives.len);
    for (backing_alternatives, alternatives) |backing_alternative, *out| {
        const stored = try arena.create(DemandedKnownValue);
        stored.* = backing_alternative;
        out.* = .{ .nominal = .{
            .ty = nominal.ty,
            .backing = stored,
        } };
    }
    return alternatives;
}

fn expandDemandedKnownTag(
    scratch: Allocator,
    arena: Allocator,
    tag: DemandedKnownTag,
) Allocator.Error![]const DemandedKnownValue {
    const alternatives = try expandDemandedKnownIndexedValues(scratch, arena, tag.payloads);
    const values = try arena.alloc(DemandedKnownValue, alternatives.len);
    for (alternatives, values) |payloads, *out| {
        out.* = .{ .tag = .{
            .ty = tag.ty,
            .name = tag.name,
            .payloads = payloads,
        } };
    }
    return values;
}

fn expandDemandedKnownCallable(
    scratch: Allocator,
    arena: Allocator,
    callable: DemandedKnownCallable,
) Allocator.Error![]const DemandedKnownValue {
    const alternatives = try expandDemandedKnownIndexedValues(scratch, arena, callable.captures);
    const values = try arena.alloc(DemandedKnownValue, alternatives.len);
    for (alternatives, values) |captures, *out| {
        out.* = .{ .callable = .{
            .ty = callable.ty,
            .fn_id = callable.fn_id,
            .captures = captures,
        } };
    }
    return values;
}

fn expandDemandedKnownTags(
    scratch: Allocator,
    arena: Allocator,
    finite_tags: DemandedKnownTags,
) Allocator.Error![]const DemandedKnownValue {
    var alternatives = std.ArrayList(DemandedKnownValue).empty;
    defer alternatives.deinit(scratch);

    for (finite_tags.alternatives) |alternative| {
        const expanded = try expandDemandedKnownTag(scratch, arena, alternative);
        try alternatives.appendSlice(scratch, expanded);
    }

    return try arena.dupe(DemandedKnownValue, alternatives.items);
}

fn expandDemandedKnownCallables(
    scratch: Allocator,
    arena: Allocator,
    finite_callables: DemandedKnownCallables,
) Allocator.Error![]const DemandedKnownValue {
    var alternatives = std.ArrayList(DemandedKnownValue).empty;
    defer alternatives.deinit(scratch);

    for (finite_callables.alternatives) |alternative| {
        const expanded = try expandDemandedKnownCallable(scratch, arena, alternative);
        try alternatives.appendSlice(scratch, expanded);
    }

    return try arena.dupe(DemandedKnownValue, alternatives.items);
}

fn expandDemandedKnownIndexedValues(
    scratch: Allocator,
    arena: Allocator,
    indexed: []const DemandedKnownIndexedValue,
) Allocator.Error![]const []const DemandedKnownIndexedValue {
    const child_values = try scratch.alloc(DemandedKnownValue, indexed.len);
    defer scratch.free(child_values);
    for (indexed, 0..) |child, index| {
        child_values[index] = child.known_value;
    }

    const products = try demandedKnownValueProducts(scratch, arena, child_values);
    const alternatives = try arena.alloc([]const DemandedKnownIndexedValue, products.len);
    for (products, alternatives) |product, *out| {
        const values = try arena.alloc(DemandedKnownIndexedValue, indexed.len);
        for (indexed, product, values) |child, child_known_value, *value_out| {
            value_out.* = .{
                .index = child.index,
                .known_value = child_known_value,
            };
        }
        out.* = values;
    }
    return alternatives;
}

fn known_valueEql(program: *const Ast.Program, lhs: KnownValue, rhs: KnownValue) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .any => |lhs_ty| sameType(program, lhs_ty, rhs.any),
        .leaf => |lhs_ty| sameType(program, lhs_ty, rhs.leaf),
        .tag => |lhs_tag| blk: {
            const rhs_tag = rhs.tag;
            if (!sameType(program, lhs_tag.ty, rhs_tag.ty) or lhs_tag.name != rhs_tag.name or lhs_tag.payloads.len != rhs_tag.payloads.len) break :blk false;
            for (lhs_tag.payloads, rhs_tag.payloads) |lhs_payload, rhs_payload| {
                if (!known_valueEql(program, lhs_payload, rhs_payload)) break :blk false;
            }
            break :blk true;
        },
        .record => |lhs_record| blk: {
            const rhs_record = rhs.record;
            if (!sameType(program, lhs_record.ty, rhs_record.ty) or lhs_record.fields.len != rhs_record.fields.len) break :blk false;
            for (lhs_record.fields, rhs_record.fields) |lhs_field, rhs_field| {
                if (lhs_field.name != rhs_field.name or !known_valueEql(program, lhs_field.known_value, rhs_field.known_value)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |lhs_tuple| blk: {
            const rhs_tuple = rhs.tuple;
            if (!sameType(program, lhs_tuple.ty, rhs_tuple.ty) or lhs_tuple.items.len != rhs_tuple.items.len) break :blk false;
            for (lhs_tuple.items, rhs_tuple.items) |lhs_item, rhs_item| {
                if (!known_valueEql(program, lhs_item, rhs_item)) break :blk false;
            }
            break :blk true;
        },
        .nominal => |lhs_nominal| {
            const rhs_nominal = rhs.nominal;
            return sameType(program, lhs_nominal.ty, rhs_nominal.ty) and known_valueEql(program, lhs_nominal.backing.*, rhs_nominal.backing.*);
        },
        .callable => |lhs_callable| blk: {
            const rhs_callable = rhs.callable;
            if (!sameType(program, lhs_callable.ty, rhs_callable.ty) or
                !callableTargetMatches(program, lhs_callable.fn_id, rhs_callable.fn_id) or
                lhs_callable.captures.len != rhs_callable.captures.len)
            {
                break :blk false;
            }
            for (lhs_callable.captures, rhs_callable.captures) |lhs_capture, rhs_capture| {
                if (!known_valueEql(program, lhs_capture, rhs_capture)) break :blk false;
            }
            break :blk true;
        },
        .finite_tags => |lhs_finite| knownTagsEql(program, lhs_finite, rhs.finite_tags),
        .finite_callables => |lhs_finite| knownCallablesEql(program, lhs_finite, rhs.finite_callables),
    };
}

fn demandedKnownValuesMatchValues(program: *const Ast.Program, known_values: []const DemandedKnownValue, values: []const Value) bool {
    if (known_values.len != values.len) return false;
    for (known_values, values) |known_value, value| {
        if (!demandedKnownValueMatchesValue(program, known_value, value)) return false;
    }
    return true;
}

fn demandedKnownValuesEql(program: *const Ast.Program, lhs: []const DemandedKnownValue, rhs: []const DemandedKnownValue) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_value, rhs_value| {
        if (!demandedKnownValueEql(program, lhs_value, rhs_value)) return false;
    }
    return true;
}

fn demandedKnownValueMatchesValue(program: *const Ast.Program, known_value: DemandedKnownValue, value: Value) bool {
    if (value == .private_state) return demandedKnownValueMatchesPrivateState(program, known_value, value.private_state);
    if (value == .let_) return demandedKnownValueMatchesValue(program, known_value, value.let_.body.*);
    if (value == .if_) {
        for (value.if_.branches) |branch| {
            if (!demandedKnownValueMatchesValue(program, known_value, branch.body)) return false;
        }
        return demandedKnownValueMatchesValue(program, known_value, value.if_.final_else.*);
    }
    if (value == .match_) {
        for (value.match_.branches) |branch| {
            if (!demandedKnownValueMatchesValue(program, known_value, branch.body)) return false;
        }
        return true;
    }
    if (value == .expr_with_known_value) {
        if (value.expr_with_known_value.value) |structured_value| {
            if (demandedKnownValueMatchesValue(program, known_value, structured_value.*)) return true;
        }
        return demandedKnownValueMatchesKnownValue(program, known_value, value.expr_with_known_value.known_value);
    }

    return switch (known_value) {
        .any => |ty| sameType(program, ty, valueType(program, value)),
        .leaf => |ty| sameType(program, ty, valueType(program, value)),
        .record => |record| blk: {
            const value_record = recordFromValue(value) orelse break :blk false;
            if (!sameType(program, record.ty, value_record.ty)) break :blk false;
            for (record.fields) |field| {
                const field_value = fieldFromRecord(value_record, field.name) orelse break :blk false;
                if (!demandedKnownValueMatchesValue(program, field.known_value, field_value)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |tuple| blk: {
            const value_tuple = tupleFromValue(value) orelse break :blk false;
            if (!sameType(program, tuple.ty, value_tuple.ty)) break :blk false;
            for (tuple.items) |item| {
                if (item.index >= value_tuple.items.len) break :blk false;
                if (!demandedKnownValueMatchesValue(program, item.known_value, value_tuple.items[item.index])) break :blk false;
            }
            break :blk true;
        },
        .nominal => |nominal| blk: {
            const value_nominal = switch (value) {
                .nominal => |value_nominal| value_nominal,
                else => break :blk false,
            };
            if (!sameType(program, nominal.ty, value_nominal.ty)) break :blk false;
            const backing = nominal.backing orelse break :blk true;
            break :blk demandedKnownValueMatchesValue(program, backing.*, value_nominal.backing.*);
        },
        .tag => |tag| blk: {
            const value_tag = tagFromValue(value) orelse break :blk false;
            if (!sameType(program, tag.ty, value_tag.ty) or tag.name != value_tag.name) break :blk false;
            for (tag.payloads) |payload| {
                if (payload.index >= value_tag.payloads.len) break :blk false;
                if (!demandedKnownValueMatchesValue(program, payload.known_value, value_tag.payloads[payload.index])) break :blk false;
            }
            break :blk true;
        },
        .callable => |callable| blk: {
            const value_callable = switch (value) {
                .callable => |value_callable| value_callable,
                else => break :blk false,
            };
            if (!sameType(program, callable.ty, value_callable.ty) or
                !callableTargetMatches(program, callable.fn_id, value_callable.fn_id))
            {
                break :blk false;
            }
            for (callable.captures) |capture| {
                if (capture.index >= value_callable.captures.len) break :blk false;
                if (!demandedKnownValueMatchesValue(program, capture.known_value, value_callable.captures[capture.index])) break :blk false;
            }
            break :blk true;
        },
        .finite_tags => |finite_tags| blk: {
            for (finite_tags.alternatives) |alternative| {
                if (demandedKnownValueMatchesValue(program, .{ .tag = alternative }, value)) break :blk true;
            }
            break :blk false;
        },
        .finite_callables => |finite_callables| blk: {
            for (finite_callables.alternatives) |alternative| {
                if (demandedKnownValueMatchesValue(program, .{ .callable = alternative }, value)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn demandedKnownValueMatchesKnownValue(program: *const Ast.Program, known_value: DemandedKnownValue, value: KnownValue) bool {
    return switch (known_value) {
        .any => |ty| sameType(program, ty, known_valueType(value)),
        .leaf => |ty| sameType(program, ty, known_valueType(value)),
        .record => |record| blk: {
            if (!sameType(program, record.ty, known_valueType(value))) break :blk false;
            for (record.fields) |field| {
                const field_value = fieldKnownValueFromKnownValue(value, field.name) orelse break :blk false;
                if (!demandedKnownValueMatchesKnownValue(program, field.known_value, field_value)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |tuple| blk: {
            if (!sameType(program, tuple.ty, known_valueType(value))) break :blk false;
            for (tuple.items) |item| {
                const item_value = itemKnownValueFromKnownValue(value, item.index) orelse break :blk false;
                if (!demandedKnownValueMatchesKnownValue(program, item.known_value, item_value)) break :blk false;
            }
            break :blk true;
        },
        .nominal => |nominal| blk: {
            const value_nominal = switch (value) {
                .nominal => |value_nominal| value_nominal,
                else => break :blk false,
            };
            if (!sameType(program, nominal.ty, value_nominal.ty)) break :blk false;
            const backing = nominal.backing orelse break :blk true;
            break :blk demandedKnownValueMatchesKnownValue(program, backing.*, value_nominal.backing.*);
        },
        .tag => |tag| blk: {
            const value_tag = switch (value) {
                .tag => |value_tag| value_tag,
                else => break :blk false,
            };
            if (!sameType(program, tag.ty, value_tag.ty) or tag.name != value_tag.name) break :blk false;
            for (tag.payloads) |payload| {
                if (payload.index >= value_tag.payloads.len) break :blk false;
                if (!demandedKnownValueMatchesKnownValue(program, payload.known_value, value_tag.payloads[payload.index])) break :blk false;
            }
            break :blk true;
        },
        .callable => |callable| blk: {
            const value_callable = switch (value) {
                .callable => |value_callable| value_callable,
                else => break :blk false,
            };
            if (!sameType(program, callable.ty, value_callable.ty) or
                !callableTargetMatches(program, callable.fn_id, value_callable.fn_id))
            {
                break :blk false;
            }
            for (callable.captures) |capture| {
                if (capture.index >= value_callable.captures.len) break :blk false;
                if (!demandedKnownValueMatchesKnownValue(program, capture.known_value, value_callable.captures[capture.index])) break :blk false;
            }
            break :blk true;
        },
        .finite_tags => |finite_tags| blk: {
            for (finite_tags.alternatives) |alternative| {
                if (demandedKnownValueMatchesKnownValue(program, .{ .tag = alternative }, value)) break :blk true;
            }
            break :blk false;
        },
        .finite_callables => |finite_callables| blk: {
            for (finite_callables.alternatives) |alternative| {
                if (demandedKnownValueMatchesKnownValue(program, .{ .callable = alternative }, value)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn demandedKnownValueMatchesPrivateState(program: *const Ast.Program, known_value: DemandedKnownValue, value: PrivateStateValue) bool {
    return switch (known_value) {
        .any => |ty| blk: {
            const matches = sameType(program, ty, privateStateValueType(value));
            break :blk matches;
        },
        .leaf => |ty| blk: {
            const matches = sameType(program, ty, privateStateValueType(value));
            break :blk matches;
        },
        .record => |record| blk: {
            if (!sameType(program, record.ty, privateStateValueType(value))) break :blk false;
            for (record.fields) |field| {
                const field_value = privateStateField(value, field.name) orelse break :blk false;
                if (!demandedKnownValueMatchesPrivateState(program, field.known_value, field_value)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |tuple| blk: {
            if (!sameType(program, tuple.ty, privateStateValueType(value))) break :blk false;
            for (tuple.items) |item| {
                const item_value = privateStateItem(value, item.index) orelse break :blk false;
                if (!demandedKnownValueMatchesPrivateState(program, item.known_value, item_value)) break :blk false;
            }
            break :blk true;
        },
        .nominal => |nominal| blk: {
            const private_nominal = switch (value) {
                .nominal => |private_nominal| private_nominal,
                else => {
                    break :blk false;
                },
            };
            if (!sameType(program, nominal.ty, private_nominal.ty)) {
                break :blk false;
            }
            const backing = nominal.backing orelse break :blk true;
            const private_backing = private_nominal.backing orelse {
                break :blk false;
            };
            const matches = demandedKnownValueMatchesPrivateState(program, backing.*, private_backing.*);
            break :blk matches;
        },
        .tag => |tag| blk: {
            const private_tag = privateStateTag(value) orelse {
                break :blk false;
            };
            if (!sameType(program, tag.ty, private_tag.ty) or tag.name != private_tag.name) {
                break :blk false;
            }
            for (tag.payloads) |payload| {
                const payload_value = privateStateIndexedValueByIndex(private_tag.payloads, payload.index) orelse {
                    break :blk false;
                };
                if (!demandedKnownValueMatchesPrivateState(program, payload.known_value, payload_value)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .callable => |callable| blk: {
            const private_callable = privateStateCallable(value) orelse break :blk false;
            if (!sameType(program, callable.ty, private_callable.ty) or
                !callableTargetMatches(program, callable.fn_id, private_callable.fn_id))
            {
                break :blk false;
            }
            for (callable.captures) |capture| {
                const capture_value = privateStateIndexedValueByIndex(private_callable.captures, capture.index) orelse break :blk false;
                if (!demandedKnownValueMatchesPrivateState(program, capture.known_value, capture_value)) break :blk false;
            }
            break :blk true;
        },
        .finite_tags => |finite_tags| blk: {
            for (finite_tags.alternatives) |alternative| {
                if (demandedKnownValueMatchesPrivateState(program, .{ .tag = alternative }, value)) break :blk true;
            }
            break :blk false;
        },
        .finite_callables => |finite_callables| blk: {
            for (finite_callables.alternatives) |alternative| {
                if (demandedKnownValueMatchesPrivateState(program, .{ .callable = alternative }, value)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn knownValueMatchesValue(program: *const Ast.Program, known_value: KnownValue, value: Value) bool {
    if (value == .private_state) return knownValueMatchesPrivateState(program, known_value, value.private_state);

    if (value == .expr_with_known_value) {
        if (value.expr_with_known_value.value) |structured_value| {
            if (knownValueMatchesValue(program, known_value, structured_value.*)) return true;
        }
        if (known_value == .any) return sameType(program, known_value.any, valueType(program, value));
        if (known_value == .leaf) return sameType(program, known_value.leaf, valueType(program, value));
        if (!canReadFieldsFromExpr(program, value.expr_with_known_value.expr)) return false;
        return known_valueCanProjectFromExpr(known_value) and knownValueMatchesKnownValue(program, known_value, value.expr_with_known_value.known_value);
    }

    return switch (known_value) {
        .any => |ty| sameType(program, ty, valueType(program, value)),
        .leaf => |ty| sameType(program, ty, valueType(program, value)),
        .tag => |tag| blk: {
            const value_tag = switch (value) {
                .tag => |value_tag| value_tag,
                else => break :blk false,
            };
            if (!sameType(program, tag.ty, value_tag.ty) or tag.name != value_tag.name or tag.payloads.len != value_tag.payloads.len) break :blk false;
            for (tag.payloads, value_tag.payloads) |payload_known_value, payload_value| {
                if (!knownValueMatchesValue(program, payload_known_value, payload_value)) break :blk false;
            }
            break :blk true;
        },
        .record => |record| blk: {
            const value_record = switch (value) {
                .record => |value_record| value_record,
                else => break :blk false,
            };
            if (!sameType(program, record.ty, value_record.ty)) break :blk false;
            for (record.fields) |field_known_value| {
                const field_value = fieldFromRecord(value_record, field_known_value.name) orelse break :blk false;
                if (!knownValueMatchesValue(program, field_known_value.known_value, field_value)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |tuple| blk: {
            const value_tuple = switch (value) {
                .tuple => |value_tuple| value_tuple,
                else => break :blk false,
            };
            if (!sameType(program, tuple.ty, value_tuple.ty) or tuple.items.len != value_tuple.items.len) break :blk false;
            for (tuple.items, value_tuple.items) |item_known_value, item_value| {
                if (!knownValueMatchesValue(program, item_known_value, item_value)) break :blk false;
            }
            break :blk true;
        },
        .nominal => |nominal| blk: {
            const value_nominal = switch (value) {
                .nominal => |value_nominal| value_nominal,
                else => break :blk false,
            };
            break :blk sameType(program, nominal.ty, value_nominal.ty) and knownValueMatchesValue(program, nominal.backing.*, value_nominal.backing.*);
        },
        .callable => |callable| blk: {
            const value_callable = switch (value) {
                .callable => |value_callable| value_callable,
                else => break :blk false,
            };
            if (!sameType(program, callable.ty, value_callable.ty) or
                !callableTargetMatches(program, callable.fn_id, value_callable.fn_id) or
                callable.captures.len != value_callable.captures.len)
            {
                break :blk false;
            }
            for (callable.captures, value_callable.captures) |capture_known_value, capture_value| {
                if (!knownValueMatchesValue(program, capture_known_value, capture_value)) break :blk false;
            }
            break :blk true;
        },
        .finite_tags => |finite_tags| blk: {
            switch (value) {
                .tag => |tag| break :blk finiteTagAlternativeIndex(program, finite_tags.alternatives, tag) != null,
                .finite_tags => |finite_value| break :blk knownTagsMatchesValue(program, finite_tags, finite_value),
                else => break :blk false,
            }
        },
        .finite_callables => |finite_callables| blk: {
            switch (value) {
                .callable => |callable| break :blk finiteCallableAlternativeIndex(program, finite_callables.alternatives, callable) != null,
                .finite_callables => |finite_value| break :blk knownCallablesMatchesValue(program, finite_callables, finite_value),
                else => break :blk false,
            }
        },
    };
}

fn knownValueMatchesPrivateState(program: *const Ast.Program, known_value: KnownValue, value: PrivateStateValue) bool {
    return switch (known_value) {
        .any => |ty| sameType(program, ty, privateStateValueType(value)) and privateStateLeafExpr(value) != null,
        .leaf => |ty| sameType(program, ty, privateStateValueType(value)) and privateStateLeafExpr(value) != null,
        .tag => |tag| blk: {
            const private_tag = privateStateTag(value) orelse break :blk false;
            if (!sameType(program, tag.ty, private_tag.ty) or tag.name != private_tag.name or tag.payloads.len != private_tag.payloads.len) break :blk false;
            for (tag.payloads, 0..) |payload_known_value, index| {
                const payload_value = privateStateIndexedValueByIndex(private_tag.payloads, @intCast(index)) orelse break :blk false;
                if (!knownValueMatchesPrivateState(program, payload_known_value, payload_value)) break :blk false;
            }
            break :blk true;
        },
        .record => |record| blk: {
            if (!sameType(program, record.ty, privateStateValueType(value))) break :blk false;
            for (record.fields) |field| {
                const field_value = privateStateField(value, field.name) orelse break :blk false;
                if (!knownValueMatchesPrivateState(program, field.known_value, field_value)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |tuple| blk: {
            if (!sameType(program, tuple.ty, privateStateValueType(value))) break :blk false;
            for (tuple.items, 0..) |item_known_value, index| {
                const item_value = privateStateItem(value, @intCast(index)) orelse break :blk false;
                if (!knownValueMatchesPrivateState(program, item_known_value, item_value)) break :blk false;
            }
            break :blk true;
        },
        .nominal => |nominal| blk: {
            const private_nominal = switch (value) {
                .nominal => |private_nominal| private_nominal,
                else => break :blk false,
            };
            if (!sameType(program, nominal.ty, private_nominal.ty)) break :blk false;
            const backing = private_nominal.backing orelse break :blk false;
            break :blk knownValueMatchesPrivateState(program, nominal.backing.*, backing.*);
        },
        .callable => |callable| blk: {
            const private_callable = privateStateCallable(value) orelse break :blk false;
            if (!sameType(program, callable.ty, private_callable.ty) or
                !callableTargetMatches(program, callable.fn_id, private_callable.fn_id) or
                callable.captures.len != private_callable.captures.len)
            {
                break :blk false;
            }
            for (callable.captures, 0..) |capture_known_value, index| {
                const capture_value = privateStateIndexedValueByIndex(private_callable.captures, @intCast(index)) orelse break :blk false;
                if (!knownValueMatchesPrivateState(program, capture_known_value, capture_value)) break :blk false;
            }
            break :blk true;
        },
        .finite_tags,
        .finite_callables,
        => false,
    };
}

fn known_valueCanProjectFromExpr(known_value: KnownValue) bool {
    return switch (known_value) {
        .any => true,
        .leaf => true,
        .record => |record| blk: {
            for (record.fields) |field| {
                if (!known_valueCanProjectFromExpr(field.known_value)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |tuple| blk: {
            for (tuple.items) |item| {
                if (!known_valueCanProjectFromExpr(item)) break :blk false;
            }
            break :blk true;
        },
        .nominal => |nominal| known_valueCanProjectFromExpr(nominal.backing.*),
        .tag,
        .callable,
        .finite_tags,
        .finite_callables,
        => false,
    };
}

fn knownValueMatchesKnownValue(program: *const Ast.Program, pattern: KnownValue, actual: KnownValue) bool {
    return switch (pattern) {
        .any => |ty| sameType(program, ty, known_valueType(actual)),
        .leaf => |ty| sameType(program, ty, known_valueType(actual)),
        .tag => |pattern_tag| blk: {
            const actual_tag = switch (actual) {
                .tag => |tag| tag,
                else => break :blk false,
            };
            if (!sameType(program, pattern_tag.ty, actual_tag.ty) or
                pattern_tag.name != actual_tag.name or
                pattern_tag.payloads.len != actual_tag.payloads.len)
            {
                break :blk false;
            }
            for (pattern_tag.payloads, actual_tag.payloads) |pattern_payload, actual_payload| {
                if (!knownValueMatchesKnownValue(program, pattern_payload, actual_payload)) break :blk false;
            }
            break :blk true;
        },
        .record => |pattern_record| blk: {
            const actual_record = switch (actual) {
                .record => |record| record,
                else => break :blk false,
            };
            if (!sameType(program, pattern_record.ty, actual_record.ty)) break :blk false;
            for (pattern_record.fields) |pattern_field| {
                const actual_field = fieldKnownValueFromKnownValue(actual, pattern_field.name) orelse break :blk false;
                if (!knownValueMatchesKnownValue(program, pattern_field.known_value, actual_field)) break :blk false;
            }
            break :blk true;
        },
        .tuple => |pattern_tuple| blk: {
            const actual_tuple = switch (actual) {
                .tuple => |tuple| tuple,
                else => break :blk false,
            };
            if (!sameType(program, pattern_tuple.ty, actual_tuple.ty) or pattern_tuple.items.len != actual_tuple.items.len) break :blk false;
            for (pattern_tuple.items, actual_tuple.items) |pattern_item, actual_item| {
                if (!knownValueMatchesKnownValue(program, pattern_item, actual_item)) break :blk false;
            }
            break :blk true;
        },
        .nominal => |pattern_nominal| blk: {
            const actual_nominal = switch (actual) {
                .nominal => |nominal| nominal,
                else => break :blk false,
            };
            break :blk sameType(program, pattern_nominal.ty, actual_nominal.ty) and
                knownValueMatchesKnownValue(program, pattern_nominal.backing.*, actual_nominal.backing.*);
        },
        .callable => |pattern_callable| blk: {
            const actual_callable = switch (actual) {
                .callable => |callable| callable,
                else => break :blk false,
            };
            if (!sameType(program, pattern_callable.ty, actual_callable.ty) or
                !callableTargetMatches(program, pattern_callable.fn_id, actual_callable.fn_id) or
                pattern_callable.captures.len != actual_callable.captures.len)
            {
                break :blk false;
            }
            for (pattern_callable.captures, actual_callable.captures) |pattern_capture, actual_capture| {
                if (!knownValueMatchesKnownValue(program, pattern_capture, actual_capture)) break :blk false;
            }
            break :blk true;
        },
        .finite_tags => |pattern_finite| blk: {
            const actual_finite = switch (actual) {
                .finite_tags => |finite_tags| finite_tags,
                .tag => |tag| {
                    break :blk finiteKnownTagContainsKnownTag(program, pattern_finite, tag);
                },
                else => break :blk false,
            };
            break :blk knownTagsContainsKnownValue(program, pattern_finite, actual_finite);
        },
        .finite_callables => |pattern_finite| blk: {
            const actual_finite = switch (actual) {
                .finite_callables => |finite_callables| finite_callables,
                .callable => |callable| {
                    break :blk finiteKnownCallableContainsKnownCallable(program, pattern_finite, callable);
                },
                else => break :blk false,
            };
            break :blk knownCallablesContainsKnownValue(program, pattern_finite, actual_finite);
        },
    };
}

fn commonKnownTags(
    program: *const Ast.Program,
    arena: Allocator,
    lhs: KnownValue,
    rhs: KnownValue,
) Allocator.Error!?KnownValue {
    const ty = known_valueType(lhs);
    var alternatives = std.ArrayList(KnownTag).empty;
    defer alternatives.deinit(arena);

    if (!try appendKnownTagAlternatives(program, arena, &alternatives, lhs)) return null;
    if (!try appendKnownTagAlternatives(program, arena, &alternatives, rhs)) return null;
    if (alternatives.items.len == 0) return null;
    if (alternatives.items.len == 1) return KnownValue{ .tag = alternatives.items[0] };

    const stored = try arena.dupe(KnownTag, alternatives.items);
    return KnownValue{ .finite_tags = .{
        .ty = ty,
        .alternatives = stored,
    } };
}

fn appendKnownTagAlternatives(
    program: *const Ast.Program,
    arena: Allocator,
    out: *std.ArrayList(KnownTag),
    known_value: KnownValue,
) Allocator.Error!bool {
    switch (known_value) {
        .tag => |tag| return try appendTagAlternative(program, arena, out, tag),
        .finite_tags => |finite_tags| {
            for (finite_tags.alternatives) |alternative| {
                if (!try appendTagAlternative(program, arena, out, alternative)) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn appendTagAlternative(
    program: *const Ast.Program,
    arena: Allocator,
    out: *std.ArrayList(KnownTag),
    candidate: KnownTag,
) Allocator.Error!bool {
    for (out.items, 0..) |existing, index| {
        if (existing.name != candidate.name) continue;
        if (!sameType(program, existing.ty, candidate.ty)) return false;
        if (existing.payloads.len != candidate.payloads.len) return false;

        const payloads = try arena.alloc(KnownValue, existing.payloads.len);
        for (existing.payloads, candidate.payloads, payloads) |lhs_payload, rhs_payload, *payload_out| {
            payload_out.* = (try joinKnownValuesInArena(program, arena, lhs_payload, rhs_payload)) orelse
                .{ .any = known_valueType(lhs_payload) };
        }
        out.items[index] = .{
            .ty = existing.ty,
            .name = existing.name,
            .payloads = payloads,
        };
        return true;
    }

    try out.append(arena, candidate);
    return true;
}

fn finiteTagAlternativeIndex(
    program: *const Ast.Program,
    alternatives: []const KnownTag,
    value: TagValue,
) ?usize {
    for (alternatives, 0..) |alternative, index| {
        if (!sameType(program, alternative.ty, value.ty)) continue;
        if (alternative.name != value.name or alternative.payloads.len != value.payloads.len) continue;
        for (alternative.payloads, value.payloads) |payload_known_value, payload_value| {
            if (!knownValueMatchesValue(program, payload_known_value, payload_value)) break;
        } else {
            return index;
        }
    }
    return null;
}

fn knownTagsMatchesValue(
    program: *const Ast.Program,
    known_value: KnownTags,
    value: FiniteTagsValue,
) bool {
    if (!sameType(program, known_value.ty, value.ty)) return false;
    if (known_value.alternatives.len != value.alternatives.len) return false;
    for (known_value.alternatives, value.alternatives) |known_value_alternative, value_alternative| {
        if (!sameType(program, known_value_alternative.ty, value_alternative.ty)) return false;
        if (known_value_alternative.name != value_alternative.name or known_value_alternative.payloads.len != value_alternative.payloads.len) return false;
        for (known_value_alternative.payloads, value_alternative.payloads) |payload_known_value, payload_value| {
            if (!knownValueMatchesValue(program, payload_known_value, payload_value)) return false;
        }
    }
    return true;
}

fn knownTagsEql(program: *const Ast.Program, lhs: KnownTags, rhs: KnownTags) bool {
    if (!sameType(program, lhs.ty, rhs.ty) or lhs.alternatives.len != rhs.alternatives.len) return false;
    for (lhs.alternatives) |lhs_alternative| {
        for (rhs.alternatives) |rhs_alternative| {
            if (knownTagEql(program, lhs_alternative, rhs_alternative)) break;
        } else {
            return false;
        }
    }
    return true;
}

fn knownTagEql(program: *const Ast.Program, lhs: KnownTag, rhs: KnownTag) bool {
    if (!sameType(program, lhs.ty, rhs.ty) or
        lhs.name != rhs.name or lhs.payloads.len != rhs.payloads.len)
    {
        return false;
    }
    for (lhs.payloads, rhs.payloads) |lhs_payload, rhs_payload| {
        if (!known_valueEql(program, lhs_payload, rhs_payload)) return false;
    }
    return true;
}

fn finiteKnownTagContainsKnownTag(program: *const Ast.Program, finite: KnownTags, tag: KnownTag) bool {
    for (finite.alternatives) |alternative| {
        if (!sameType(program, alternative.ty, tag.ty) or
            alternative.name != tag.name or
            alternative.payloads.len != tag.payloads.len)
        {
            continue;
        }
        for (alternative.payloads, tag.payloads) |pattern_payload, actual_payload| {
            if (!knownValueMatchesKnownValue(program, pattern_payload, actual_payload)) break;
        } else {
            return true;
        }
    }
    return false;
}

fn knownTagsContainsKnownValue(program: *const Ast.Program, pattern: KnownTags, actual: KnownTags) bool {
    if (!sameType(program, pattern.ty, actual.ty)) return false;
    for (actual.alternatives) |alternative| {
        if (!finiteKnownTagContainsKnownTag(program, pattern, alternative)) return false;
    }
    return true;
}

fn commonKnownCallables(
    program: *const Ast.Program,
    arena: Allocator,
    lhs: KnownValue,
    rhs: KnownValue,
) Allocator.Error!?KnownValue {
    const ty = known_valueType(lhs);
    var alternatives = std.ArrayList(KnownCallable).empty;
    defer alternatives.deinit(arena);

    if (!try appendKnownCallableAlternatives(program, arena, &alternatives, lhs)) return null;
    if (!try appendKnownCallableAlternatives(program, arena, &alternatives, rhs)) return null;
    if (alternatives.items.len == 0) return null;
    if (alternatives.items.len == 1) return KnownValue{ .callable = alternatives.items[0] };

    const stored = try arena.dupe(KnownCallable, alternatives.items);
    return KnownValue{ .finite_callables = .{
        .ty = ty,
        .alternatives = stored,
    } };
}

fn appendKnownCallableAlternatives(
    program: *const Ast.Program,
    arena: Allocator,
    out: *std.ArrayList(KnownCallable),
    known_value: KnownValue,
) Allocator.Error!bool {
    switch (known_value) {
        .callable => |callable| return try appendCallableAlternative(program, arena, out, callable),
        .finite_callables => |finite_callables| {
            for (finite_callables.alternatives) |alternative| {
                if (!try appendCallableAlternative(program, arena, out, alternative)) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn appendCallableAlternative(
    program: *const Ast.Program,
    arena: Allocator,
    out: *std.ArrayList(KnownCallable),
    candidate: KnownCallable,
) Allocator.Error!bool {
    for (out.items, 0..) |existing, index| {
        if (!callableTargetMatches(program, existing.fn_id, candidate.fn_id)) continue;
        if (!sameType(program, existing.ty, candidate.ty)) continue;
        if (existing.captures.len != candidate.captures.len) continue;

        const captures = try arena.alloc(KnownValue, existing.captures.len);
        for (existing.captures, candidate.captures, captures) |lhs_capture, rhs_capture, *capture_out| {
            capture_out.* = (try joinKnownValuesInArena(program, arena, lhs_capture, rhs_capture)) orelse
                .{ .any = known_valueType(lhs_capture) };
        }
        out.items[index] = .{
            .ty = existing.ty,
            .fn_id = existing.fn_id,
            .captures = captures,
        };
        return true;
    }

    try out.append(arena, candidate);
    return true;
}

fn finiteCallableAlternativeIndex(
    program: *const Ast.Program,
    alternatives: []const KnownCallable,
    value: CallableValue,
) ?usize {
    for (alternatives, 0..) |alternative, index| {
        if (!sameType(program, alternative.ty, value.ty)) continue;
        if (!callableTargetMatches(program, alternative.fn_id, value.fn_id) or alternative.captures.len != value.captures.len) continue;
        for (alternative.captures, value.captures) |capture_known_value, capture_value| {
            if (!knownValueMatchesValue(program, capture_known_value, capture_value)) break;
        } else {
            return index;
        }
    }
    return null;
}

fn knownCallablesMatchesValue(
    program: *const Ast.Program,
    known_value: KnownCallables,
    value: FiniteCallablesValue,
) bool {
    if (!sameType(program, known_value.ty, value.ty)) return false;
    if (known_value.alternatives.len != value.alternatives.len) return false;
    for (known_value.alternatives, value.alternatives) |known_value_alternative, value_alternative| {
        if (!sameType(program, known_value_alternative.ty, value_alternative.ty)) return false;
        if (!callableTargetMatches(program, known_value_alternative.fn_id, value_alternative.fn_id) or
            known_value_alternative.captures.len != value_alternative.captures.len)
        {
            return false;
        }
        for (known_value_alternative.captures, value_alternative.captures) |capture_known_value, capture_value| {
            if (!knownValueMatchesValue(program, capture_known_value, capture_value)) return false;
        }
    }
    return true;
}

fn knownCallablesEql(program: *const Ast.Program, lhs: KnownCallables, rhs: KnownCallables) bool {
    if (!sameType(program, lhs.ty, rhs.ty) or lhs.alternatives.len != rhs.alternatives.len) return false;
    for (lhs.alternatives) |lhs_alternative| {
        for (rhs.alternatives) |rhs_alternative| {
            if (knownCallableEql(program, lhs_alternative, rhs_alternative)) break;
        } else {
            return false;
        }
    }
    return true;
}

fn knownCallableEql(program: *const Ast.Program, lhs: KnownCallable, rhs: KnownCallable) bool {
    if (!sameType(program, lhs.ty, rhs.ty) or
        !callableTargetMatches(program, lhs.fn_id, rhs.fn_id) or
        lhs.captures.len != rhs.captures.len)
    {
        return false;
    }
    for (lhs.captures, rhs.captures) |lhs_capture, rhs_capture| {
        if (!known_valueEql(program, lhs_capture, rhs_capture)) return false;
    }
    return true;
}

fn finiteKnownCallableContainsKnownCallable(program: *const Ast.Program, finite: KnownCallables, callable: KnownCallable) bool {
    for (finite.alternatives) |alternative| {
        if (!sameType(program, alternative.ty, callable.ty) or
            !callableTargetMatches(program, alternative.fn_id, callable.fn_id) or
            alternative.captures.len != callable.captures.len)
        {
            continue;
        }
        for (alternative.captures, callable.captures) |pattern_capture, actual_capture| {
            if (!knownValueMatchesKnownValue(program, pattern_capture, actual_capture)) break;
        } else {
            return true;
        }
    }
    return false;
}

fn knownCallablesContainsKnownValue(program: *const Ast.Program, pattern: KnownCallables, actual: KnownCallables) bool {
    if (!sameType(program, pattern.ty, actual.ty)) return false;
    for (actual.alternatives) |alternative| {
        if (!finiteKnownCallableContainsKnownCallable(program, pattern, alternative)) return false;
    }
    return true;
}

fn callableTargetMatches(program: *const Ast.Program, expected: Ast.FnId, actual: Ast.FnId) bool {
    if (expected == actual) return true;
    const expected_source = program.fns.items[@intFromEnum(expected)].source orelse return false;
    const actual_source = program.fns.items[@intFromEnum(actual)].source orelse return false;
    return Mono.fnTemplateIdentityEql(expected_source, actual_source);
}

fn fieldFromValue(value: Value, name: names.RecordFieldNameId) ?Value {
    if (value == .private_state) {
        const field = privateStateField(value.private_state, name) orelse return null;
        return .{ .private_state = field };
    }
    if (value == .expr_with_known_value) {
        if (value.expr_with_known_value.value) |structured_value| {
            if (fieldFromValue(structured_value.*, name)) |field| return field;
        }
    }
    const record = recordFromValue(value) orelse return null;
    return fieldFromRecord(record, name);
}

fn fieldFromRecord(record: RecordValue, name: names.RecordFieldNameId) ?Value {
    for (record.fields) |field| {
        if (field.name == name) return field.value;
    }
    return null;
}

fn recordPatField(fields: []const Ast.RecordDestruct, name: names.RecordFieldNameId) ?Ast.PatId {
    for (fields) |field| {
        if (field.name == name) return field.pattern;
    }
    return null;
}

fn itemFromValue(value: Value, index: u32) ?Value {
    if (value == .private_state) {
        const item = privateStateItem(value.private_state, index) orelse return null;
        return .{ .private_state = item };
    }
    if (value == .expr_with_known_value) {
        if (value.expr_with_known_value.value) |structured_value| {
            if (itemFromValue(structured_value.*, index)) |item| return item;
        }
    }
    const tuple = tupleFromValue(value) orelse return null;
    if (index >= tuple.items.len) return null;
    return tuple.items[index];
}

fn tagFromValue(value: Value) ?TagValue {
    return switch (value) {
        .tag => |tag| tag,
        .nominal => |nominal| tagFromValue(nominal.backing.*),
        .expr_with_known_value => |known| if (known.value) |structured_value| tagFromValue(structured_value.*) else null,
        else => null,
    };
}

fn tagNameFromValue(value: Value) ?names.TagNameId {
    if (tagFromValue(value)) |tag| return tag.name;
    return switch (value) {
        .private_state => |private_state| if (privateStateTag(private_state)) |tag| tag.name else null,
        .expr_with_known_value => |known| if (known.value) |structured_value| tagNameFromValue(structured_value.*) else null,
        .nominal => |nominal| tagNameFromValue(nominal.backing.*),
        else => null,
    };
}

fn tagPayloadFromValue(value: Value, index: u32) ?Value {
    if (tagFromValue(value)) |tag| {
        if (index >= tag.payloads.len) return null;
        return tag.payloads[index];
    }

    return switch (value) {
        .private_state => |private_state| blk: {
            const tag = privateStateTag(private_state) orelse break :blk null;
            const payload = privateStateIndexedValueByIndex(tag.payloads, index) orelse break :blk null;
            break :blk Value{ .private_state = payload };
        },
        .expr_with_known_value => |known| if (known.value) |structured_value| tagPayloadFromValue(structured_value.*, index) else null,
        .nominal => |nominal| tagPayloadFromValue(nominal.backing.*, index),
        else => null,
    };
}

fn patternTagChoiceMatchesValue(program: *const Ast.Program, pat_id: Ast.PatId, value: Value) bool {
    const pat = program.pats.items[@intFromEnum(pat_id)];
    return switch (pat.data) {
        .wildcard,
        .bind,
        => true,
        .as => |as| patternTagChoiceMatchesValue(program, as.pattern, value),
        .nominal => |backing| patternTagChoiceMatchesValue(program, backing, value),
        .tag => |tag_pat| blk: {
            const tag_name = tagNameFromValue(value) orelse break :blk false;
            break :blk tag_name == tag_pat.name;
        },
        .record,
        .tuple,
        .list,
        .int_lit,
        .dec_lit,
        .frac_f32_lit,
        .frac_f64_lit,
        .str_lit,
        .str_pattern,
        => false,
    };
}

fn knownIfConditionBoolTag(program: *const Ast.Program, value: Value) ?bool {
    if (value == .private_state) {
        const tag = privateStateTag(value.private_state) orelse return null;
        return boolPrivateStateTag(program, tag) orelse
            Common.invariant("known if condition Bool tag used a non-Bool tag label");
    }

    const tag = tagFromValue(value) orelse return null;
    return boolTagValue(program, tag) orelse
        Common.invariant("known if condition Bool tag used a non-Bool tag label");
}

fn finiteBoolTagsValue(program: *const Ast.Program, value: Value) ?FiniteTagsValue {
    const finite_tags = switch (value) {
        .finite_tags => |finite_tags| finite_tags,
        else => return null,
    };
    for (finite_tags.alternatives) |alternative| {
        if (boolTagValue(program, alternative) == null) return null;
    }
    return finite_tags;
}

fn boolTagValue(program: *const Ast.Program, tag: TagValue) ?bool {
    if (tag.payloads.len != 0) Common.invariant("Bool tag had payloads");
    const tag_text = program.names.tagLabelText(tag.name);
    if (std.mem.eql(u8, tag_text, "True")) return true;
    if (std.mem.eql(u8, tag_text, "False")) return false;
    return null;
}

fn boolPrivateStateTag(program: *const Ast.Program, tag: PrivateStateTag) ?bool {
    if (tag.payloads.len != 0) Common.invariant("Bool tag had payloads");
    const tag_text = program.names.tagLabelText(tag.name);
    if (std.mem.eql(u8, tag_text, "True")) return true;
    if (std.mem.eql(u8, tag_text, "False")) return false;
    return null;
}

fn unsignedIntLiteral(value: anytype) can.CIR.IntValue {
    const widened: u128 = @intCast(value);
    return .{ .bytes = @bitCast(widened), .kind = .u128 };
}

fn recordFromValue(value: Value) ?RecordValue {
    return switch (value) {
        .record => |record| record,
        .nominal => |nominal| recordFromValue(nominal.backing.*),
        .expr_with_known_value => |known| if (known.value) |structured_value| recordFromValue(structured_value.*) else null,
        else => null,
    };
}

fn tupleFromValue(value: Value) ?TupleValue {
    return switch (value) {
        .tuple => |tuple| tuple,
        .nominal => |nominal| tupleFromValue(nominal.backing.*),
        .expr_with_known_value => |known| if (known.value) |structured_value| tupleFromValue(structured_value.*) else null,
        else => null,
    };
}

test "value demand equality ignores capture read order" {
    const materialize: ValueDemand = .materialize;
    const none: ValueDemand = .none;
    const field_a: names.RecordFieldNameId = @enumFromInt(1);
    const field_b: names.RecordFieldNameId = @enumFromInt(2);

    const record_lhs_fields = [_]FieldDemand{
        .{ .name = field_a, .demand = &materialize },
        .{ .name = field_b, .demand = &none },
    };
    const record_rhs_fields = [_]FieldDemand{
        .{ .name = field_b, .demand = &none },
        .{ .name = field_a, .demand = &materialize },
    };
    try std.testing.expect(valueDemandEql(
        .{ .record = &record_lhs_fields },
        .{ .record = &record_rhs_fields },
    ));

    const tuple_lhs_items = [_]ItemDemand{
        .{ .index = 0, .demand = &materialize },
        .{ .index = 3, .demand = &none },
    };
    const tuple_rhs_items = [_]ItemDemand{
        .{ .index = 3, .demand = &none },
        .{ .index = 0, .demand = &materialize },
    };
    try std.testing.expect(valueDemandEql(
        .{ .tuple = &tuple_lhs_items },
        .{ .tuple = &tuple_rhs_items },
    ));

    const tag_lhs_payloads = [_]ItemDemand{
        .{ .index = 2, .demand = &none },
        .{ .index = 0, .demand = &materialize },
    };
    const tag_rhs_payloads = [_]ItemDemand{
        .{ .index = 0, .demand = &materialize },
        .{ .index = 2, .demand = &none },
    };
    try std.testing.expect(valueDemandEql(
        .{ .tag = .{ .payloads = &tag_lhs_payloads } },
        .{ .tag = .{ .payloads = &tag_rhs_payloads } },
    ));

    const record_missing_field = [_]FieldDemand{
        .{ .name = field_a, .demand = &materialize },
    };
    try std.testing.expect(!valueDemandEql(
        .{ .record = &record_lhs_fields },
        .{ .record = &record_missing_field },
    ));
}

test "demanded known value materialization preserves indexed tuple children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tuple_ty: Type.TypeId = @enumFromInt(10);
    const first_ty: Type.TypeId = @enumFromInt(11);
    const second_ty: Type.TypeId = @enumFromInt(12);
    const third_ty: Type.TypeId = @enumFromInt(13);
    const dense_items = [_]KnownValue{
        .{ .leaf = first_ty },
        .{ .any = second_ty },
        .{ .leaf = third_ty },
    };
    const known = KnownValue{ .tuple = .{
        .ty = tuple_ty,
        .items = &dense_items,
    } };

    const demanded = (try demandedKnownValueFromDemand(null, null, arena.allocator(), known, .materialize)) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(tuple_ty, demanded.tuple.ty);
    try std.testing.expectEqual(@as(usize, 3), demanded.tuple.items.len);
    try std.testing.expectEqual(@as(u32, 0), demanded.tuple.items[0].index);
    try std.testing.expectEqual(@as(u32, 1), demanded.tuple.items[1].index);
    try std.testing.expectEqual(@as(u32, 2), demanded.tuple.items[2].index);
    try std.testing.expectEqual(second_ty, demanded.tuple.items[1].known_value.any);
}

test "demanded known value omits tuple siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tuple_ty: Type.TypeId = @enumFromInt(20);
    const first_ty: Type.TypeId = @enumFromInt(21);
    const second_ty: Type.TypeId = @enumFromInt(22);
    const third_ty: Type.TypeId = @enumFromInt(23);
    const dense_items = [_]KnownValue{
        .{ .leaf = first_ty },
        .{ .any = second_ty },
        .{ .leaf = third_ty },
    };
    const known = KnownValue{ .tuple = .{
        .ty = tuple_ty,
        .items = &dense_items,
    } };
    const materialize: ValueDemand = .materialize;
    const item_demands = [_]ItemDemand{
        .{ .index = 1, .demand = &materialize },
    };

    const demanded = (try demandedKnownValueFromDemand(null, null, arena.allocator(), known, .{ .tuple = &item_demands })) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(tuple_ty, demanded.tuple.ty);
    try std.testing.expectEqual(@as(usize, 1), demanded.tuple.items.len);
    try std.testing.expectEqual(@as(u32, 1), demanded.tuple.items[0].index);
    try std.testing.expectEqual(second_ty, demanded.tuple.items[0].known_value.any);
}

test "demanded known value preserves tag choice without payload demand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tag_ty: Type.TypeId = @enumFromInt(70);
    const first_ty: Type.TypeId = @enumFromInt(71);
    const second_ty: Type.TypeId = @enumFromInt(72);
    const tag_name: names.TagNameId = @enumFromInt(4);
    const payloads = [_]KnownValue{
        .{ .leaf = first_ty },
        .{ .any = second_ty },
    };
    const known = KnownValue{ .tag = .{
        .ty = tag_ty,
        .name = tag_name,
        .payloads = &payloads,
    } };

    const demanded = (try demandedKnownValueFromDemand(null, null, arena.allocator(), known, .{
        .tag = .{ .payloads = &.{} },
    })) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(tag_ty, demanded.tag.ty);
    try std.testing.expectEqual(tag_name, demanded.tag.name);
    try std.testing.expectEqual(@as(usize, 0), demanded.tag.payloads.len);
}

test "demanded known value preserves finite tag choices without payload demand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tag_ty: Type.TypeId = @enumFromInt(80);
    const payload_ty: Type.TypeId = @enumFromInt(81);
    const first_name: names.TagNameId = @enumFromInt(5);
    const second_name: names.TagNameId = @enumFromInt(6);
    const first_payloads = [_]KnownValue{
        .{ .leaf = payload_ty },
    };
    const second_payloads = [_]KnownValue{
        .{ .any = payload_ty },
    };
    const alternatives = [_]KnownTag{
        .{
            .ty = tag_ty,
            .name = first_name,
            .payloads = &first_payloads,
        },
        .{
            .ty = tag_ty,
            .name = second_name,
            .payloads = &second_payloads,
        },
    };
    const known = KnownValue{ .finite_tags = .{
        .ty = tag_ty,
        .alternatives = &alternatives,
    } };

    const demanded = (try demandedKnownValueFromDemand(null, null, arena.allocator(), known, .{
        .tag = .{ .payloads = &.{} },
    })) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(tag_ty, demanded.finite_tags.ty);
    try std.testing.expectEqual(@as(usize, 2), demanded.finite_tags.alternatives.len);
    try std.testing.expectEqual(first_name, demanded.finite_tags.alternatives[0].name);
    try std.testing.expectEqual(second_name, demanded.finite_tags.alternatives[1].name);
    try std.testing.expectEqual(@as(usize, 0), demanded.finite_tags.alternatives[0].payloads.len);
    try std.testing.expectEqual(@as(usize, 0), demanded.finite_tags.alternatives[1].payloads.len);
}

test "demanded known value equality ignores sparse child order" {
    const program: *const Ast.Program = undefined;

    const record_ty: Type.TypeId = @enumFromInt(90);
    const first_ty: Type.TypeId = @enumFromInt(91);
    const second_ty: Type.TypeId = @enumFromInt(92);
    const field_a: names.RecordFieldNameId = @enumFromInt(8);
    const field_b: names.RecordFieldNameId = @enumFromInt(9);
    const lhs_fields = [_]DemandedKnownField{
        .{ .name = field_a, .known_value = .{ .leaf = first_ty } },
        .{ .name = field_b, .known_value = .{ .any = second_ty } },
    };
    const rhs_fields = [_]DemandedKnownField{
        .{ .name = field_b, .known_value = .{ .any = second_ty } },
        .{ .name = field_a, .known_value = .{ .leaf = first_ty } },
    };
    try std.testing.expect(demandedKnownValueEql(
        program,
        .{ .record = .{ .ty = record_ty, .fields = &lhs_fields } },
        .{ .record = .{ .ty = record_ty, .fields = &rhs_fields } },
    ));

    const tuple_ty: Type.TypeId = @enumFromInt(93);
    const lhs_items = [_]DemandedKnownIndexedValue{
        .{ .index = 2, .known_value = .{ .leaf = first_ty } },
        .{ .index = 0, .known_value = .{ .any = second_ty } },
    };
    const rhs_items = [_]DemandedKnownIndexedValue{
        .{ .index = 0, .known_value = .{ .any = second_ty } },
        .{ .index = 2, .known_value = .{ .leaf = first_ty } },
    };
    try std.testing.expect(demandedKnownValueEql(
        program,
        .{ .tuple = .{ .ty = tuple_ty, .items = &lhs_items } },
        .{ .tuple = .{ .ty = tuple_ty, .items = &rhs_items } },
    ));
}

test "demanded known value equality distinguishes omitted child from unknown carried child" {
    const program: *const Ast.Program = undefined;

    const callable_ty: Type.TypeId = @enumFromInt(100);
    const capture_ty: Type.TypeId = @enumFromInt(101);
    const fn_id: Ast.FnId = @enumFromInt(7);
    const carried_captures = [_]DemandedKnownIndexedValue{
        .{ .index = 0, .known_value = .{ .any = capture_ty } },
    };

    try std.testing.expect(!demandedKnownValueEql(
        program,
        .{ .callable = .{
            .ty = callable_ty,
            .fn_id = fn_id,
            .captures = &.{},
        } },
        .{ .callable = .{
            .ty = callable_ty,
            .fn_id = fn_id,
            .captures = &carried_captures,
        } },
    ));
}

test "demanded known value finite-state detection follows demanded children" {
    const selector_ty: Type.TypeId = @enumFromInt(110);
    const wrapper_ty: Type.TypeId = @enumFromInt(111);
    const field: names.RecordFieldNameId = @enumFromInt(10);
    const alternatives = [_]DemandedKnownTag{
        .{
            .ty = selector_ty,
            .name = @enumFromInt(11),
            .payloads = &.{},
        },
        .{
            .ty = selector_ty,
            .name = @enumFromInt(12),
            .payloads = &.{},
        },
    };
    const fields = [_]DemandedKnownField{
        .{ .name = field, .known_value = .{ .finite_tags = .{
            .ty = selector_ty,
            .alternatives = &alternatives,
        } } },
    };

    try std.testing.expect(demandedKnownValueContainsFiniteState(.{ .record = .{
        .ty = wrapper_ty,
        .fields = &fields,
    } }));
    try std.testing.expect(!demandedKnownValueContainsFiniteState(.{ .record = .{
        .ty = wrapper_ty,
        .fields = &.{},
    } }));
}

test "demanded known value products expand finite tags without materializing omitted payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tag_ty: Type.TypeId = @enumFromInt(120);
    const record_ty: Type.TypeId = @enumFromInt(121);
    const step_field: names.RecordFieldNameId = @enumFromInt(13);
    const len_field: names.RecordFieldNameId = @enumFromInt(14);
    const alternatives = [_]DemandedKnownTag{
        .{
            .ty = tag_ty,
            .name = @enumFromInt(15),
            .payloads = &.{},
        },
        .{
            .ty = tag_ty,
            .name = @enumFromInt(16),
            .payloads = &.{},
        },
    };
    const fields = [_]DemandedKnownField{
        .{ .name = step_field, .known_value = .{ .finite_tags = .{
            .ty = tag_ty,
            .alternatives = &alternatives,
        } } },
        .{ .name = len_field, .known_value = .{ .leaf = @enumFromInt(122) } },
    };
    const roots = [_]DemandedKnownValue{
        .{ .record = .{
            .ty = record_ty,
            .fields = fields[0..1],
        } },
    };

    const products = try demandedKnownValueProducts(std.testing.allocator, arena.allocator(), &roots);

    try std.testing.expectEqual(@as(usize, 2), products.len);
    for (products) |product| {
        try std.testing.expectEqual(@as(usize, 1), product.len);
        try std.testing.expectEqual(record_ty, product[0].record.ty);
        try std.testing.expectEqual(@as(usize, 1), product[0].record.fields.len);
        try std.testing.expectEqual(step_field, product[0].record.fields[0].name);
        try std.testing.expectEqual(@as(usize, 0), product[0].record.fields[0].known_value.tag.payloads.len);
    }
    try std.testing.expect(products[0].record.fields[0].known_value.tag.name != products[1].record.fields[0].known_value.tag.name);
}

test "demanded known value products preserve sparse callable capture indexes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const callable_ty: Type.TypeId = @enumFromInt(130);
    const capture_ty: Type.TypeId = @enumFromInt(131);
    const first_fn: Ast.FnId = @enumFromInt(8);
    const second_fn: Ast.FnId = @enumFromInt(9);
    const first_captures = [_]DemandedKnownIndexedValue{
        .{ .index = 2, .known_value = .{ .leaf = capture_ty } },
    };
    const second_captures = [_]DemandedKnownIndexedValue{
        .{ .index = 2, .known_value = .{ .any = capture_ty } },
    };
    const alternatives = [_]DemandedKnownCallable{
        .{
            .ty = callable_ty,
            .fn_id = first_fn,
            .captures = &first_captures,
        },
        .{
            .ty = callable_ty,
            .fn_id = second_fn,
            .captures = &second_captures,
        },
    };
    const roots = [_]DemandedKnownValue{
        .{ .finite_callables = .{
            .ty = callable_ty,
            .alternatives = &alternatives,
        } },
    };

    const products = try demandedKnownValueProducts(std.testing.allocator, arena.allocator(), &roots);

    try std.testing.expectEqual(@as(usize, 2), products.len);
    try std.testing.expectEqual(first_fn, products[0][0].callable.fn_id);
    try std.testing.expectEqual(second_fn, products[1][0].callable.fn_id);
    try std.testing.expectEqual(@as(usize, 1), products[0][0].callable.captures.len);
    try std.testing.expectEqual(@as(usize, 1), products[1][0].callable.captures.len);
    try std.testing.expectEqual(@as(u32, 2), products[0][0].callable.captures[0].index);
    try std.testing.expectEqual(@as(u32, 2), products[1][0].callable.captures[0].index);
}

test "demanded known value private state param count ignores identity-only state" {
    const tag_ty: Type.TypeId = @enumFromInt(140);
    const callable_ty: Type.TypeId = @enumFromInt(141);
    const capture_ty: Type.TypeId = @enumFromInt(142);
    const step_field: names.RecordFieldNameId = @enumFromInt(17);
    const len_field: names.RecordFieldNameId = @enumFromInt(18);
    const captures = [_]DemandedKnownIndexedValue{
        .{ .index = 2, .known_value = .{ .any = capture_ty } },
    };
    const fields = [_]DemandedKnownField{
        .{ .name = step_field, .known_value = .{ .callable = .{
            .ty = callable_ty,
            .fn_id = @enumFromInt(10),
            .captures = &captures,
        } } },
        .{ .name = len_field, .known_value = .{ .tag = .{
            .ty = tag_ty,
            .name = @enumFromInt(19),
            .payloads = &.{},
        } } },
    };

    try std.testing.expectEqual(@as(usize, 1), demandedKnownValuePrivateStateParamCount(.{ .record = .{
        .ty = @enumFromInt(143),
        .fields = &fields,
    } }));
}

test "demanded known value private state param count ignores omitted children" {
    const callable_ty: Type.TypeId = @enumFromInt(150);
    const capture_ty: Type.TypeId = @enumFromInt(151);
    const carried_captures = [_]DemandedKnownIndexedValue{
        .{ .index = 2, .known_value = .{ .any = capture_ty } },
    };

    try std.testing.expectEqual(@as(usize, 0), demandedKnownValuePrivateStateParamCount(.{ .callable = .{
        .ty = callable_ty,
        .fn_id = @enumFromInt(11),
        .captures = &.{},
    } }));
    try std.testing.expectEqual(@as(usize, 1), demandedKnownValuePrivateStateParamCount(.{ .callable = .{
        .ty = callable_ty,
        .fn_id = @enumFromInt(11),
        .captures = &carried_captures,
    } }));
}

test "private state value reads sparse tuple items by original index" {
    const tuple_ty: Type.TypeId = @enumFromInt(184);
    const item_ty: Type.TypeId = @enumFromInt(185);
    const item_expr: Ast.ExprId = @enumFromInt(9);
    const items = [_]PrivateStateIndexedValue{
        .{
            .index = 2,
            .value = .{ .leaf = .{
                .ty = item_ty,
                .expr = item_expr,
            } },
        },
    };

    const tuple = PrivateStateValue{ .tuple = .{
        .ty = tuple_ty,
        .items = &items,
    } };

    try std.testing.expectEqual(tuple_ty, privateStateValueType(tuple));
    try std.testing.expect(privateStateItem(tuple, 0) == null);
    const item = privateStateItem(tuple, 2) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(item_ty, privateStateValueType(item));
    try std.testing.expectEqual(item_expr, item.leaf.expr);
}

test "private state value reads sparse tag payloads by original index through nominal backing" {
    const nominal_ty: Type.TypeId = @enumFromInt(186);
    const tag_ty: Type.TypeId = @enumFromInt(187);
    const payload_ty: Type.TypeId = @enumFromInt(188);
    const tag_name: names.TagNameId = @enumFromInt(28);
    const payload_expr: Ast.ExprId = @enumFromInt(10);
    const payloads = [_]PrivateStateIndexedValue{
        .{
            .index = 3,
            .value = .{ .leaf = .{
                .ty = payload_ty,
                .expr = payload_expr,
            } },
        },
    };
    const tag = PrivateStateValue{ .tag = .{
        .ty = tag_ty,
        .name = tag_name,
        .payloads = &payloads,
    } };
    const nominal = PrivateStateValue{ .nominal = .{
        .ty = nominal_ty,
        .backing = &tag,
    } };

    try std.testing.expectEqual(nominal_ty, privateStateValueType(nominal));
    try std.testing.expect(privateStateTagPayload(nominal, 0) == null);
    const payload = privateStateTagPayload(nominal, 3) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(payload_ty, privateStateValueType(payload));
    try std.testing.expectEqual(payload_expr, payload.leaf.expr);
}

test "private state value reads sparse callable captures by original index" {
    const callable_ty: Type.TypeId = @enumFromInt(189);
    const capture_ty: Type.TypeId = @enumFromInt(190);
    const capture_expr: Ast.ExprId = @enumFromInt(11);
    const fn_id: Ast.FnId = @enumFromInt(5);
    const captures = [_]PrivateStateIndexedValue{
        .{
            .index = 4,
            .value = .{ .leaf = .{
                .ty = capture_ty,
                .expr = capture_expr,
            } },
        },
    };

    const callable = PrivateStateValue{ .callable = .{
        .ty = callable_ty,
        .fn_id = fn_id,
        .captures = &captures,
    } };

    try std.testing.expectEqual(callable_ty, privateStateValueType(callable));
    try std.testing.expect(privateStateCallableCapture(callable, 0) == null);
    const capture = privateStateCallableCapture(callable, 4) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(capture_ty, privateStateValueType(capture));
    try std.testing.expectEqual(capture_expr, capture.leaf.expr);
}

test "value type reads private state type without public materialization" {
    const private_ty: Type.TypeId = @enumFromInt(191);
    const private_expr: Ast.ExprId = @enumFromInt(12);
    const program: *const Ast.Program = undefined;

    try std.testing.expectEqual(private_ty, valueType(program, .{ .private_state = .{ .leaf = .{
        .ty = private_ty,
        .expr = private_expr,
    } } }));
}

test "demanded known value matching ignores omitted record fields" {
    const program: *const Ast.Program = undefined;

    const record_ty: Type.TypeId = @enumFromInt(160);
    const tag_ty: Type.TypeId = @enumFromInt(161);
    const tag_name: names.TagNameId = @enumFromInt(22);
    const kept_field: names.RecordFieldNameId = @enumFromInt(20);
    const omitted_field: names.RecordFieldNameId = @enumFromInt(21);
    const demanded_fields = [_]DemandedKnownField{
        .{ .name = kept_field, .known_value = .{ .tag = .{
            .ty = tag_ty,
            .name = tag_name,
            .payloads = &.{},
        } } },
    };
    const value_fields = [_]FieldValue{
        .{ .name = kept_field, .value = .{ .tag = .{
            .ty = tag_ty,
            .name = tag_name,
            .payloads = &.{},
        } } },
        .{ .name = omitted_field, .value = .{ .expr = @enumFromInt(1) } },
    };

    try std.testing.expect(demandedKnownValueMatchesValue(
        program,
        .{ .record = .{
            .ty = record_ty,
            .fields = &demanded_fields,
        } },
        .{ .record = .{
            .ty = record_ty,
            .fields = &value_fields,
        } },
    ));
    try std.testing.expect(!demandedKnownValueMatchesValue(
        program,
        .{ .record = .{
            .ty = record_ty,
            .fields = &demanded_fields,
        } },
        .{ .record = .{
            .ty = @enumFromInt(163),
            .fields = &value_fields,
        } },
    ));
}

test "demanded known value matching ignores omitted callable captures" {
    const program: *const Ast.Program = undefined;

    const callable_ty: Type.TypeId = @enumFromInt(170);
    const tag_ty: Type.TypeId = @enumFromInt(171);
    const tag_name: names.TagNameId = @enumFromInt(23);
    const fn_id: Ast.FnId = @enumFromInt(12);
    const demanded_captures = [_]DemandedKnownIndexedValue{
        .{ .index = 1, .known_value = .{ .tag = .{
            .ty = tag_ty,
            .name = tag_name,
            .payloads = &.{},
        } } },
    };
    const value_captures = [_]Value{
        .{ .expr = undefined }, // capture 0 is omitted by demand; reading it is a test failure.
        .{ .tag = .{
            .ty = tag_ty,
            .name = tag_name,
            .payloads = &.{},
        } },
        .{ .expr = @enumFromInt(2) },
    };

    try std.testing.expect(demandedKnownValueMatchesValue(
        program,
        .{ .callable = .{
            .ty = callable_ty,
            .fn_id = fn_id,
            .captures = &demanded_captures,
        } },
        .{ .callable = .{
            .ty = callable_ty,
            .fn_id = fn_id,
            .captures = &value_captures,
        } },
    ));
    try std.testing.expect(!demandedKnownValueMatchesValue(
        program,
        .{ .callable = .{
            .ty = callable_ty,
            .fn_id = @enumFromInt(13),
            .captures = &demanded_captures,
        } },
        .{ .callable = .{
            .ty = callable_ty,
            .fn_id = fn_id,
            .captures = &value_captures,
        } },
    ));
}

test "demanded known value distinguishes omitted capture from unknown carried capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const callable_ty: Type.TypeId = @enumFromInt(30);
    const first_ty: Type.TypeId = @enumFromInt(31);
    const second_ty: Type.TypeId = @enumFromInt(32);
    const third_ty: Type.TypeId = @enumFromInt(33);
    const fn_id: Ast.FnId = @enumFromInt(34);
    const captures = [_]KnownValue{
        .{ .leaf = first_ty },
        .{ .any = second_ty },
        .{ .leaf = third_ty },
    };
    const known = KnownValue{ .callable = .{
        .ty = callable_ty,
        .fn_id = fn_id,
        .captures = &captures,
    } };
    const capture_demands = [_]ValueDemand{
        .none,
        .materialize,
        .none,
    };

    const demanded = (try demandedKnownValueFromDemand(null, null, arena.allocator(), known, .{
        .callable = .{ .captures = &capture_demands },
    })) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(callable_ty, demanded.callable.ty);
    try std.testing.expectEqual(fn_id, demanded.callable.fn_id);
    try std.testing.expectEqual(@as(usize, 1), demanded.callable.captures.len);
    try std.testing.expectEqual(@as(u32, 1), demanded.callable.captures[0].index);
    try std.testing.expectEqual(second_ty, demanded.callable.captures[0].known_value.any);
}

test "demanded known value preserves callable target with no demanded captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const callable_ty: Type.TypeId = @enumFromInt(50);
    const first_ty: Type.TypeId = @enumFromInt(51);
    const second_ty: Type.TypeId = @enumFromInt(52);
    const captures = [_]KnownValue{
        .{ .leaf = first_ty },
        .{ .any = second_ty },
    };
    const fn_id: Ast.FnId = @enumFromInt(3);
    const known = KnownValue{ .callable = .{
        .ty = callable_ty,
        .fn_id = fn_id,
        .captures = &captures,
    } };
    const capture_demands = [_]ValueDemand{
        .none,
        .none,
    };

    const demanded = (try demandedKnownValueFromDemand(null, null, arena.allocator(), known, .{
        .callable = .{ .captures = &capture_demands },
    })) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(callable_ty, demanded.callable.ty);
    try std.testing.expectEqual(fn_id, demanded.callable.fn_id);
    try std.testing.expectEqual(@as(usize, 0), demanded.callable.captures.len);
}

test "demanded known value preserves finite callable alternatives with no demanded captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const callable_ty: Type.TypeId = @enumFromInt(60);
    const capture_ty: Type.TypeId = @enumFromInt(61);
    const first_fn: Ast.FnId = @enumFromInt(5);
    const second_fn: Ast.FnId = @enumFromInt(6);
    const first_captures = [_]KnownValue{
        .{ .leaf = capture_ty },
    };
    const second_captures = [_]KnownValue{
        .{ .any = capture_ty },
    };
    const alternatives = [_]KnownCallable{
        .{
            .ty = callable_ty,
            .fn_id = first_fn,
            .captures = &first_captures,
        },
        .{
            .ty = callable_ty,
            .fn_id = second_fn,
            .captures = &second_captures,
        },
    };
    const known = KnownValue{ .finite_callables = .{
        .ty = callable_ty,
        .alternatives = &alternatives,
    } };
    const capture_demands = [_]ValueDemand{
        .none,
    };

    const demanded = (try demandedKnownValueFromDemand(null, null, arena.allocator(), known, .{
        .callable = .{ .captures = &capture_demands },
    })) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(callable_ty, demanded.finite_callables.ty);
    try std.testing.expectEqual(@as(usize, 2), demanded.finite_callables.alternatives.len);
    try std.testing.expectEqual(first_fn, demanded.finite_callables.alternatives[0].fn_id);
    try std.testing.expectEqual(second_fn, demanded.finite_callables.alternatives[1].fn_id);
    try std.testing.expectEqual(@as(usize, 0), demanded.finite_callables.alternatives[0].captures.len);
    try std.testing.expectEqual(@as(usize, 0), demanded.finite_callables.alternatives[1].captures.len);
}

test "demanded known value omits unused record fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const record_ty: Type.TypeId = @enumFromInt(40);
    const kept_ty: Type.TypeId = @enumFromInt(41);
    const omitted_ty: Type.TypeId = @enumFromInt(42);
    const kept_field: names.RecordFieldNameId = @enumFromInt(1);
    const omitted_field: names.RecordFieldNameId = @enumFromInt(2);
    const fields = [_]KnownField{
        .{ .name = kept_field, .known_value = .{ .leaf = kept_ty } },
        .{ .name = omitted_field, .known_value = .{ .leaf = omitted_ty } },
    };
    const known = KnownValue{ .record = .{
        .ty = record_ty,
        .fields = &fields,
    } };
    const materialize: ValueDemand = .materialize;
    const field_demands = [_]FieldDemand{
        .{ .name = kept_field, .demand = &materialize },
    };

    const demanded = (try demandedKnownValueFromDemand(null, null, arena.allocator(), known, .{ .record = &field_demands })) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(record_ty, demanded.record.ty);
    try std.testing.expectEqual(@as(usize, 1), demanded.record.fields.len);
    try std.testing.expectEqual(kept_field, demanded.record.fields[0].name);
    try std.testing.expectEqual(kept_ty, demanded.record.fields[0].known_value.leaf);
}

test "call-pattern specialization declarations are referenced" {
    std.testing.refAllDecls(@This());
}
