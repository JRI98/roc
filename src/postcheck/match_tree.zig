//! Decision-tree match compiler shared by both LIR lowerers.
//!
//! This module turns a `match` (a list of branches, each a pattern plus an
//! optional guard and a body) into an explicit decision tree that the host
//! lowerer then emits as LIR: multiway `switch_stmt`s on tag discriminants and
//! integer values, `str_match_set`s for string arms, length-bucketed switches
//! for list patterns, and equality chains for wide or non-switchable literals.
//! Each scrutinee position ("occurrence") is read into at most one LIR local
//! per dominating scope: one discriminant read per tested tag position, one
//! field read per destructured position, one length read per list position.
//!
//! ## The sharing invariant
//!
//! Monotype is a DAG: an expression id referenced from multiple positions is
//! RE-LOWERED at each reference, so anything the tree wants to share must go
//! through LIR join points (`join`/`jump`), never through re-lowering. PR 9707
//! removed the one known violator (the list-pattern desugarer) after measuring
//! ~(elements+1)^branches statement blowup. This compiler is structured so the
//! invariant holds by construction:
//!
//! - Rows (branches) are never duplicated during specialization. A row whose
//!   pattern does not test the selected occurrence ends the current test
//!   group instead of being copied into every arm; the rows below the group
//!   are compiled once and reached through a single exit join.
//! - Each branch body and guard is therefore lowered exactly once. Bodies end
//!   with a jump to the match's result join; guard failures fall through to
//!   the residual tree for the rows below the guarded row, re-entering the
//!   tree without re-testing columns already known.
//!
//! Because rows never duplicate, the emitted statement count is O(total
//! pattern size) with a small constant; a debug lint in the emitter asserts a
//! hard multiplier bound per match so exponential regressions fail loudly.
//!
//! ## Exhaustiveness
//!
//! Lowering consumes the checker's committed verdicts and never re-derives
//! them. A closed match manifests structurally: the committed union layout's
//! variant set is exactly what `closeExhaustiveVars` left, so a tag test whose
//! arms cover every variant of the occurrence type emits its last arm as the
//! switch default and no failure terminal. Open matches keep the terminal the
//! chain used: `comptime_exhaustiveness_failed` when the match has a comptime
//! site, `runtime_error` otherwise.

const std = @import("std");

/// Pattern kinds the accessor context reports. This is the module's neutral
/// view of `PatData` across Monotype Lifted and Lambda Mono inputs; `callable`
/// only occurs for Lambda Mono.
pub const PatKind = enum {
    bind,
    wildcard,
    as_pattern,
    record,
    tuple,
    list,
    nominal,
    tag,
    callable,
    int_lit,
    dec_lit,
    frac_f32_lit,
    frac_f64_lit,
    str_lit,
    str_pattern,
};

/// What a test node switches on.
pub const TestKind = enum {
    /// Tag-union discriminant; arms keyed by variant index.
    tag,
    /// Lambda Mono callable variant; dispatches like `tag`.
    callable,
    /// Integer scrutinee whose layout fits a `switch_stmt` (size <= 8 bytes);
    /// arm keys are the value zero-extended at layout width.
    int_switch,
    /// Sequential equality tests sharing one scrutinee local: wide integers,
    /// Dec, floats (which must keep IEEE `==` semantics), and string literals
    /// when they cannot be string-set arms.
    eq_chain,
    /// `str_match_set` arms (string interpolation patterns, and string
    /// literals as exact arms).
    str_set,
    /// List length dispatch: exact lengths as switch arms.
    list_len,
};

/// One step from a parent occurrence to a child occurrence.
pub const Step = union(enum) {
    /// The scrutinee itself.
    root,
    /// Record field or tuple item by committed index.
    field: u16,
    /// Tag payload `index` of `variant`; `single` payloads extract through
    /// `tag_payload_struct` rather than `tag_payload`.
    tag_payload: struct { variant: u16, index: u16, single: bool },
    /// Callable payload of `variant` (Lambda Mono only).
    callable_payload: struct { variant: u16 },
    /// List element at a fixed index from the front.
    list_elem_front: u32,
    /// List element at `n` from the back (index `len - n` at runtime).
    list_elem_back: u32,
    /// The rest slice of a list pattern: everything between `front` fixed
    /// elements and `back` fixed elements.
    list_rest: struct { front: u32, back: u32 },
    /// The backing value of a nominal pattern (PR 9849 boundary rules).
    nominal_backing,
    /// Capture `index` of a string-set arm with the given shape key.
    str_capture: struct { shape: u32, index: u16 },
};

/// Interned occurrence id; `root` is always index 0.
pub const OccId = enum(u32) {
    root = 0,
    _,

    pub fn idx(self: OccId) u32 {
        return @intFromEnum(self);
    }
};

/// Decision-tree compiler generic over an accessor context.
///
/// `Ctx` supplies pattern access, type queries, and constructor identity:
///
/// ```
/// const PatId/TypeId/ExprId/LocalId  — input IR id types
/// patKind(pat) PatKind
/// bindLocal(pat) LocalId                                  // .bind
/// asInfo(pat) struct { pattern: PatId, local: LocalId }   // .as_pattern
/// recordDestructCount(pat) u16
/// recordDestruct(pat, ty, i) SubPat                       // committed field index
/// tupleItemCount(pat) u16
/// tupleItem(pat, ty, i) SubPat
/// nominalInner(pat, ty) SubPat                            // backing pattern + type
/// tagVariant(pat, ty) u16
/// tagPayloadCount(pat) u16
/// tagPayload(pat, ty, i) SubPat
/// tagVariantCount(ty) ?u32                                // null: unknown, never exhaustive
/// callableVariant(pat, ty) u16                            // Lambda Mono only
/// callablePayload(pat, ty) ?SubPat
/// callableVariantCount(ty) ?u32
/// listView(pat) ListPatView
/// listElemPat(pat, i) PatId
/// listElemTy(ty) TypeId
/// ctorKey(pat, ty) u128        // identity within a TestKind (see TestKind docs)
/// intSwitchValue(pat, ty) ?u64 // null: integer literal must use eq_chain
/// strLitIsSetArm() bool        // whether str_lit unifies with str_pattern arms
/// strCaptureCount(pat) u16     // .str_pattern capture steps
/// strCapturePat(pat, i) ?PatId
/// ```
///
/// where `SubPat = struct { index: u16, ty: TypeId, pat: PatId }` (field
/// names, not the concrete type, are what matters).
pub fn Compiler(comptime Ctx: type) type {
    return struct {
        pub const PatId = Ctx.PatId;
        pub const TypeId = Ctx.TypeId;
        pub const ExprId = Ctx.ExprId;
        pub const LocalId = Ctx.LocalId;

        /// A match branch, in source order.
        pub const Branch = struct {
            pat: PatId,
            guard: ?ExprId,
            body: ExprId,
            branch_index: u32,
        };

        /// A pattern binding: assign the value at `occ` to `local` when the
        /// row's tests have all passed (or before its guard runs).
        pub const Bind = struct {
            occ: OccId,
            ty: TypeId,
            local: LocalId,
        };

        /// A refutable column: the value at `occ` must match `pat`.
        pub const Col = struct {
            occ: OccId,
            ty: TypeId,
            pat: PatId,
        };

        pub const Leaf = struct {
            binds: []const Bind,
            body: ExprId,
            branch_index: u32,
        };

        pub const GuardNode = struct {
            binds: []const Bind,
            guard: ExprId,
            body: ExprId,
            branch_index: u32,
            /// Compiled residual for the rows below this one; taken when the
            /// guard evaluates to false. Never re-tests known columns.
            otherwise: *Tree,
        };

        pub const Arm = struct {
            /// Constructor identity within the test's kind.
            key: u128,
            /// Representative pattern for emission (literal value, string
            /// shape). All rows merged into this arm share the identity.
            example: PatId,
            example_ty: TypeId,
            subtree: *Tree,
        };

        pub const TestNode = struct {
            occ: OccId,
            ty: TypeId,
            kind: TestKind,
            arms: []Arm,
            /// Taken when no arm matches; null iff `exhaustive`.
            default: ?*Tree,
            /// Arms cover the occurrence type's full variant set (checker
            /// verdict made structural); emission turns the last arm into the
            /// switch default.
            exhaustive: bool,
        };

        /// A single rest-pattern list row: `len >= min_len` guards the
        /// specialized row; both the length-test failure and any element-test
        /// failure continue with `otherwise`.
        pub const LenCheck = struct {
            occ: OccId,
            ty: TypeId,
            min_len: u64,
            then: *Tree,
            otherwise: *Tree,
        };

        /// A shared continuation: `inner` is a test whose misses jump to the
        /// exit; `cont` is compiled once and emitted as the body of one LIR
        /// join point.
        pub const ExitJoin = struct {
            id: u32,
            cont: *Tree,
            inner: *Tree,
        };

        pub const Tree = union(enum) {
            leaf: Leaf,
            guard: GuardNode,
            test_: TestNode,
            len_check: LenCheck,
            exit_join: ExitJoin,
            /// Jump to the exit join with this id.
            exit_: u32,
            /// Open-match failure terminal.
            fail,
        };

        pub const OccEntry = struct {
            parent: OccId,
            step: Step,
            ty: TypeId,
        };

        pub const Stats = struct {
            /// Total normalized pattern nodes across all branches (the "total
            /// pattern size" of the statement-count lint).
            pattern_nodes: u32 = 0,
            /// References to the failure terminal in the built tree.
            fail_refs: u32 = 0,
        };

        pub const BuildResult = struct {
            tree: *Tree,
            occs: []const OccEntry,
            stats: Stats,
        };

        const OccKey = struct {
            parent: u32,
            tag: u8,
            a: u32,
            b: u32,
        };

        const Row = struct {
            cols: []const Col,
            binds: []const Bind,
            guard: ?ExprId,
            body: ExprId,
            branch_index: u32,
        };

        const Miss = union(enum) {
            fail,
            exit_: u32,
        };

        const ExitState = struct {
            cont: *Tree,
            refs: u32,
        };

        const Builder = struct {
            arena: std.mem.Allocator,
            ctx: Ctx,
            occ_entries: std.ArrayList(OccEntry),
            occ_map: std.AutoHashMap(OccKey, u32),
            exits: std.ArrayList(ExitState),
            stats: Stats,
            /// Shape keys for string-set arms, assigned per distinct ctorKey
            /// so `Step.str_capture` occurrences intern consistently.
            str_shapes: std.AutoHashMap(u128, u32),

            fn intern(self: *Builder, parent: OccId, step: Step, ty: TypeId) error{OutOfMemory}!OccId {
                const key = occKey(parent, step);
                const gop = try self.occ_map.getOrPut(key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(self.occ_entries.items.len);
                    try self.occ_entries.append(self.arena, .{ .parent = parent, .step = step, .ty = ty });
                }
                return @enumFromInt(gop.value_ptr.*);
            }

            fn occKey(parent: OccId, step: Step) OccKey {
                return switch (step) {
                    .root => .{ .parent = parent.idx(), .tag = 0, .a = 0, .b = 0 },
                    .field => |i| .{ .parent = parent.idx(), .tag = 1, .a = i, .b = 0 },
                    .tag_payload => |p| .{ .parent = parent.idx(), .tag = 2, .a = p.variant, .b = (@as(u32, p.index) << 1) | @intFromBool(p.single) },
                    .callable_payload => |p| .{ .parent = parent.idx(), .tag = 3, .a = p.variant, .b = 0 },
                    .list_elem_front => |i| .{ .parent = parent.idx(), .tag = 4, .a = i, .b = 0 },
                    .list_elem_back => |i| .{ .parent = parent.idx(), .tag = 5, .a = i, .b = 0 },
                    .list_rest => |r| .{ .parent = parent.idx(), .tag = 6, .a = r.front, .b = r.back },
                    .nominal_backing => .{ .parent = parent.idx(), .tag = 7, .a = 0, .b = 0 },
                    .str_capture => |c| .{ .parent = parent.idx(), .tag = 8, .a = c.shape, .b = c.index },
                };
            }

            fn strShapeId(self: *Builder, key: u128) error{OutOfMemory}!u32 {
                const gop = try self.str_shapes.getOrPut(key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(self.str_shapes.count() - 1);
                }
                return gop.value_ptr.*;
            }

            fn mk(self: *Builder, tree: Tree) error{OutOfMemory}!*Tree {
                const node = try self.arena.create(Tree);
                node.* = tree;
                return node;
            }

            /// Expand `pat` at `occ` into refutable columns and bindings.
            /// Irrefutable structure (binds, wildcards, as-patterns, records,
            /// tuples, nominal wrappers, and rest-only list patterns)
            /// disappears here; only patterns that require a test remain as
            /// columns.
            fn normalize(
                self: *Builder,
                occ: OccId,
                ty: TypeId,
                pat: PatId,
                cols: *std.ArrayList(Col),
                binds: *std.ArrayList(Bind),
            ) error{OutOfMemory}!void {
                self.stats.pattern_nodes += 1;
                switch (self.ctx.patKind(pat)) {
                    .bind => try binds.append(self.arena, .{ .occ = occ, .ty = ty, .local = self.ctx.bindLocal(pat) }),
                    .wildcard => {},
                    .as_pattern => {
                        const info = self.ctx.asInfo(pat);
                        try binds.append(self.arena, .{ .occ = occ, .ty = ty, .local = info.local });
                        try self.normalize(occ, ty, info.pattern, cols, binds);
                    },
                    .record => {
                        const count = self.ctx.recordDestructCount(pat);
                        var i: u16 = 0;
                        while (i < count) : (i += 1) {
                            const sub = self.ctx.recordDestruct(pat, ty, i);
                            const child = try self.intern(occ, .{ .field = sub.index }, sub.ty);
                            try self.normalize(child, sub.ty, sub.pat, cols, binds);
                        }
                    },
                    .tuple => {
                        const count = self.ctx.tupleItemCount(pat);
                        var i: u16 = 0;
                        while (i < count) : (i += 1) {
                            const sub = self.ctx.tupleItem(pat, ty, i);
                            const child = try self.intern(occ, .{ .field = sub.index }, sub.ty);
                            try self.normalize(child, sub.ty, sub.pat, cols, binds);
                        }
                    },
                    .nominal => {
                        const sub = self.ctx.nominalInner(pat, ty);
                        const child = try self.intern(occ, .nominal_backing, sub.ty);
                        try self.normalize(child, sub.ty, sub.pat, cols, binds);
                    },
                    .list => {
                        const view = self.ctx.listView(pat);
                        if (view.fixed_count == 0) {
                            if (view.rest) |rest| {
                                // `[..]` / `[.. as r]`: irrefutable; the rest
                                // IS the whole scrutinee list.
                                if (rest.pattern) |rest_pat| {
                                    try self.normalize(occ, ty, rest_pat, cols, binds);
                                }
                                return;
                            }
                        }
                        try cols.append(self.arena, .{ .occ = occ, .ty = ty, .pat = pat });
                    },
                    .tag, .callable, .int_lit, .dec_lit, .frac_f32_lit, .frac_f64_lit, .str_lit, .str_pattern => {
                        try cols.append(self.arena, .{ .occ = occ, .ty = ty, .pat = pat });
                    },
                }
            }

            fn missTree(self: *Builder, miss: Miss) error{OutOfMemory}!*Tree {
                switch (miss) {
                    .fail => {
                        self.stats.fail_refs += 1;
                        return try self.mk(.fail);
                    },
                    .exit_ => |id| {
                        self.exits.items[id].refs += 1;
                        return try self.mk(.{ .exit_ = id });
                    },
                }
            }

            fn colAt(row: Row, occ: OccId) ?Col {
                for (row.cols) |col| {
                    if (col.occ == occ) return col;
                }
                return null;
            }

            fn colsWithout(self: *Builder, row: Row, occ: OccId) error{OutOfMemory}![]const Col {
                var out: std.ArrayList(Col) = .empty;
                try out.ensureTotalCapacityPrecise(self.arena, row.cols.len -| 1);
                for (row.cols) |col| {
                    if (col.occ != occ) try out.append(self.arena, col);
                }
                return out.items;
            }

            fn testKindOf(self: *Builder, col: Col) TestKind {
                return switch (self.ctx.patKind(col.pat)) {
                    .tag => .tag,
                    .callable => .callable,
                    .int_lit => if (self.ctx.intSwitchValue(col.pat, col.ty) != null) .int_switch else .eq_chain,
                    .dec_lit, .frac_f32_lit, .frac_f64_lit => .eq_chain,
                    .str_lit => if (self.ctx.strLitIsSetArm()) .str_set else .eq_chain,
                    .str_pattern => .str_set,
                    .list => .list_len,
                    .bind, .wildcard, .as_pattern, .record, .tuple, .nominal => unreachable, // normalized away
                };
            }

            fn isRestList(self: *Builder, pat: PatId) bool {
                if (self.ctx.patKind(pat) != .list) return false;
                return self.ctx.listView(pat).rest != null;
            }

            /// Length of the test group at `occ` starting at `rows[0]`: the
            /// maximal prefix of rows that all test `occ` with the same kind.
            /// A row without a column at `occ` (a wildcard there), a row whose
            /// column has a different kind, and a rest-pattern list row all
            /// end the group (rest rows become `len_check` nodes instead so
            /// rows never duplicate across arms).
            fn runLength(self: *Builder, rows: []const Row, occ: OccId, kind: TestKind) usize {
                var n: usize = 0;
                while (n < rows.len) : (n += 1) {
                    const col = colAt(rows[n], occ) orelse break;
                    if (self.testKindOf(col) != kind) break;
                    if (kind == .list_len and self.isRestList(col.pat)) break;
                }
                return n;
            }

            /// Pick the occurrence to test next: the column of `rows[0]` with
            /// the longest same-kind run down the matrix (ties broken by
            /// first-column order). Longer runs mean more rows dispatched by
            /// one multiway test.
            fn selectColumn(self: *Builder, rows: []const Row) Col {
                const row0 = rows[0];
                var best = row0.cols[0];
                var best_run: usize = 0;
                for (row0.cols) |col| {
                    const kind = self.testKindOf(col);
                    var run = self.runLength(rows, col.occ, kind);
                    if (kind == .list_len and run == 0 and self.isRestList(col.pat)) {
                        // A leading rest row forms its own len_check segment.
                        run = 1;
                    }
                    if (run > best_run) {
                        best = col;
                        best_run = run;
                    }
                }
                return best;
            }

            /// Specialize `row` for tag/callable arm membership: replace the
            /// tested column with payload sub-columns.
            fn specTagRow(self: *Builder, row: Row, col: Col, kind: TestKind) error{OutOfMemory}!Row {
                var cols: std.ArrayList(Col) = .empty;
                var binds: std.ArrayList(Bind) = .empty;
                try binds.appendSlice(self.arena, row.binds);

                switch (kind) {
                    .tag => {
                        const variant = self.ctx.tagVariant(col.pat, col.ty);
                        const count = self.ctx.tagPayloadCount(col.pat);
                        const single = count == 1;
                        var i: u16 = 0;
                        while (i < count) : (i += 1) {
                            const sub = self.ctx.tagPayload(col.pat, col.ty, i);
                            const child = try self.intern(col.occ, .{ .tag_payload = .{
                                .variant = variant,
                                .index = sub.index,
                                .single = single,
                            } }, sub.ty);
                            try self.normalize(child, sub.ty, sub.pat, &cols, &binds);
                        }
                    },
                    .callable => {
                        const variant = self.ctx.callableVariant(col.pat, col.ty);
                        if (self.ctx.callablePayload(col.pat, col.ty)) |sub| {
                            const child = try self.intern(col.occ, .{ .callable_payload = .{ .variant = variant } }, sub.ty);
                            try self.normalize(child, sub.ty, sub.pat, &cols, &binds);
                        }
                    },
                    else => unreachable,
                }

                for (row.cols) |c| {
                    if (c.occ != col.occ) try cols.append(self.arena, c);
                }
                return .{
                    .cols = cols.items,
                    .binds = binds.items,
                    .guard = row.guard,
                    .body = row.body,
                    .branch_index = row.branch_index,
                };
            }

            /// Specialize a string row inside a str_set arm: capture patterns
            /// become columns/binds at str_capture occurrences. Literal string
            /// arms have no captures and just drop the column.
            fn specStrRow(self: *Builder, row: Row, col: Col, shape: u32) error{OutOfMemory}!Row {
                var cols: std.ArrayList(Col) = .empty;
                var binds: std.ArrayList(Bind) = .empty;
                try binds.appendSlice(self.arena, row.binds);

                if (self.ctx.patKind(col.pat) == .str_pattern) {
                    const count = self.ctx.strCaptureCount(col.pat);
                    var i: u16 = 0;
                    while (i < count) : (i += 1) {
                        if (self.ctx.strCapturePat(col.pat, i)) |capture| {
                            const child = try self.intern(col.occ, .{ .str_capture = .{ .shape = shape, .index = i } }, col.ty);
                            try self.normalize(child, col.ty, capture, &cols, &binds);
                        }
                    }
                }

                for (row.cols) |c| {
                    if (c.occ != col.occ) try cols.append(self.arena, c);
                }
                return .{
                    .cols = cols.items,
                    .binds = binds.items,
                    .guard = row.guard,
                    .body = row.body,
                    .branch_index = row.branch_index,
                };
            }

            /// Specialize a literal row (int/dec/frac/str_lit equality arm):
            /// the matched literal imposes no sub-structure, so the column
            /// just drops.
            fn specLiteralRow(self: *Builder, row: Row, col: Col) error{OutOfMemory}!Row {
                return .{
                    .cols = try self.colsWithout(row, col.occ),
                    .binds = row.binds,
                    .guard = row.guard,
                    .body = row.body,
                    .branch_index = row.branch_index,
                };
            }

            /// Specialize an exact-length list row inside a length arm:
            /// element patterns become columns at element occurrences. With
            /// the length known exactly, back-relative elements canonicalize
            /// to front indices so rows agree on occurrence identity.
            fn specListExactRow(self: *Builder, row: Row, col: Col, exact_len: u64) error{OutOfMemory}!Row {
                var cols: std.ArrayList(Col) = .empty;
                var binds: std.ArrayList(Bind) = .empty;
                try binds.appendSlice(self.arena, row.binds);
                try self.specListInto(row, col, .{ .exact = exact_len }, &cols, &binds);
                return .{
                    .cols = cols.items,
                    .binds = binds.items,
                    .guard = row.guard,
                    .body = row.body,
                    .branch_index = row.branch_index,
                };
            }

            /// Specialize a rest-pattern list row under its `len >= k` check:
            /// elements before the rest index are front-relative, elements
            /// after it are back-relative, and the rest slice binds between
            /// them.
            fn specListRestRow(self: *Builder, row: Row, col: Col) error{OutOfMemory}!Row {
                var cols: std.ArrayList(Col) = .empty;
                var binds: std.ArrayList(Bind) = .empty;
                try binds.appendSlice(self.arena, row.binds);
                try self.specListInto(row, col, .rest_relative, &cols, &binds);
                return .{
                    .cols = cols.items,
                    .binds = binds.items,
                    .guard = row.guard,
                    .body = row.body,
                    .branch_index = row.branch_index,
                };
            }

            const ListIndexing = union(enum) {
                exact: u64,
                rest_relative,
            };

            fn specListInto(
                self: *Builder,
                row: Row,
                col: Col,
                indexing: ListIndexing,
                cols: *std.ArrayList(Col),
                binds: *std.ArrayList(Bind),
            ) error{OutOfMemory}!void {
                const view = self.ctx.listView(col.pat);
                const elem_ty = self.ctx.listElemTy(col.ty);
                const rest_index: ?u32 = if (view.rest) |rest| rest.index else null;

                var i: u32 = 0;
                while (i < view.fixed_count) : (i += 1) {
                    const from_back = if (rest_index) |ri| i >= ri else false;
                    const step: Step = if (!from_back)
                        .{ .list_elem_front = i }
                    else switch (indexing) {
                        // Element i sits (fixed_count - i) from the end; with
                        // the length known exactly that is a fixed front
                        // index, letting arms share element occurrences.
                        .exact => |n| .{ .list_elem_front = @intCast(n - (view.fixed_count - i)) },
                        .rest_relative => .{ .list_elem_back = view.fixed_count - i },
                    };
                    const child = try self.intern(col.occ, step, elem_ty);
                    try self.normalize(child, elem_ty, self.ctx.listElemPat(col.pat, i), cols, binds);
                }

                if (view.rest) |rest| {
                    if (rest.pattern) |rest_pat| {
                        const front = rest_index.?;
                        const back = view.fixed_count - front;
                        const child = try self.intern(col.occ, .{ .list_rest = .{ .front = front, .back = back } }, col.ty);
                        try self.normalize(child, col.ty, rest_pat, cols, binds);
                    }
                }

                for (row.cols) |c| {
                    if (c.occ != col.occ) try cols.append(self.arena, c);
                }
            }

            /// Compile `rows` against `miss`. Rows are consumed front-to-back
            /// as segments (leaf/guard runs, test groups, single rest-row
            /// length checks); segments compose bottom-up so the recursion
            /// depth tracks pattern nesting, not branch count.
            fn compile(self: *Builder, rows: []const Row, miss: Miss) error{OutOfMemory}!*Tree {
                const segments = try self.partition(rows);
                var acc: ?*Tree = null;
                var i = segments.len;
                while (i > 0) {
                    i -= 1;
                    const seg = segments[i];
                    acc = try self.buildSegment(seg.kind, rows[seg.start..seg.end], acc, miss);
                }
                return acc orelse try self.missTree(miss);
            }

            const Segment = struct {
                start: usize,
                end: usize,
                kind: SegmentKind,
            };

            const SegmentKind = union(enum) {
                /// Rows with no remaining columns: a run of guarded leaves
                /// optionally ending in an unguarded (terminal) leaf.
                leaves,
                /// A multiway test group on one occurrence.
                group: struct { occ: OccId, ty: TypeId, kind: TestKind },
                /// A single rest-pattern list row.
                rest_row: struct { occ: OccId, ty: TypeId },
            };

            fn partition(self: *Builder, rows: []const Row) error{OutOfMemory}![]const Segment {
                var segments: std.ArrayList(Segment) = .empty;
                var i: usize = 0;
                while (i < rows.len) {
                    const row = rows[i];
                    if (row.cols.len == 0) {
                        var end = i;
                        var terminal = false;
                        while (end < rows.len and rows[end].cols.len == 0) {
                            const unguarded = rows[end].guard == null;
                            end += 1;
                            if (unguarded) {
                                terminal = true;
                                break;
                            }
                        }
                        try segments.append(self.arena, .{ .start = i, .end = end, .kind = .leaves });
                        if (terminal) return segments.items; // rows below are unreachable here
                        i = end;
                        continue;
                    }

                    const col = self.selectColumn(rows[i..]);
                    const kind = self.testKindOf(col);
                    if (kind == .list_len and self.isRestList(col.pat)) {
                        try segments.append(self.arena, .{ .start = i, .end = i + 1, .kind = .{ .rest_row = .{ .occ = col.occ, .ty = col.ty } } });
                        i += 1;
                        continue;
                    }
                    const run = self.runLength(rows[i..], col.occ, kind);
                    std.debug.assert(run > 0);
                    try segments.append(self.arena, .{ .start = i, .end = i + run, .kind = .{ .group = .{ .occ = col.occ, .ty = col.ty, .kind = kind } } });
                    i += run;
                }
                return segments.items;
            }

            /// Build one segment. `below` is the already-compiled tree for
            /// the rows after this segment (null when this segment is last),
            /// and `miss` is where matching continues when the whole
            /// remainder is exhausted.
            fn buildSegment(self: *Builder, seg_kind: SegmentKind, rows: []const Row, below: ?*Tree, miss: Miss) error{OutOfMemory}!*Tree {
                switch (seg_kind) {
                    .leaves => {
                        var acc = below;
                        var i = rows.len;
                        while (i > 0) {
                            i -= 1;
                            const row = rows[i];
                            if (row.guard) |guard| {
                                const otherwise = acc orelse try self.missTree(miss);
                                acc = try self.mk(.{ .guard = .{
                                    .binds = row.binds,
                                    .guard = guard,
                                    .body = row.body,
                                    .branch_index = row.branch_index,
                                    .otherwise = otherwise,
                                } });
                            } else {
                                acc = try self.mk(.{ .leaf = .{
                                    .binds = row.binds,
                                    .body = row.body,
                                    .branch_index = row.branch_index,
                                } });
                            }
                        }
                        return acc.?;
                    },
                    .rest_row => |info| return try self.buildRestRow(info.occ, rows[0], below, miss),
                    .group => |info| return try self.buildGroup(info.occ, info.ty, info.kind, rows, below, miss),
                }
            }

            fn buildRestRow(self: *Builder, occ: OccId, row: Row, below: ?*Tree, miss: Miss) error{OutOfMemory}!*Tree {
                const col = colAt(row, occ).?;
                const view = self.ctx.listView(col.pat);
                std.debug.assert(view.rest != null);

                if (below) |cont| {
                    const exit_id: u32 = @intCast(self.exits.items.len);
                    try self.exits.append(self.arena, .{ .cont = cont, .refs = 0 });
                    const spec = try self.specListRestRow(row, col);
                    const then = try self.compile(&.{spec}, .{ .exit_ = exit_id });
                    const otherwise = try self.missTree(.{ .exit_ = exit_id });
                    const node = try self.mk(.{ .len_check = .{
                        .occ = col.occ,
                        .ty = col.ty,
                        .min_len = view.fixed_count,
                        .then = then,
                        .otherwise = otherwise,
                    } });
                    return try self.wrapExit(exit_id, node);
                }

                const spec = try self.specListRestRow(row, col);
                const then = try self.compile(&.{spec}, miss);
                const otherwise = try self.missTree(miss);
                return try self.mk(.{ .len_check = .{
                    .occ = col.occ,
                    .ty = col.ty,
                    .min_len = view.fixed_count,
                    .then = then,
                    .otherwise = otherwise,
                } });
            }

            /// Wrap `inner` in an exit join when its continuation is
            /// referenced; splice the continuation inline when the join would
            /// have a single default-position reference.
            fn wrapExit(self: *Builder, exit_id: u32, inner: *Tree) error{OutOfMemory}!*Tree {
                const state = self.exits.items[exit_id];
                if (state.refs == 0) return inner;
                if (state.refs == 1) {
                    // Splice into the unique reference site when it is a
                    // directly-owned default/otherwise slot of `inner`.
                    switch (inner.*) {
                        .test_ => |*t| if (t.default) |d| {
                            if (d.* == .exit_ and d.exit_ == exit_id) {
                                t.default = state.cont;
                                return inner;
                            }
                        },
                        .len_check => |*lc| {
                            if (lc.otherwise.* == .exit_ and lc.otherwise.exit_ == exit_id) {
                                lc.otherwise = state.cont;
                                return inner;
                            }
                        },
                        else => {},
                    }
                }
                return try self.mk(.{ .exit_join = .{ .id = exit_id, .cont = state.cont, .inner = inner } });
            }

            fn buildGroup(self: *Builder, occ: OccId, occ_ty: TypeId, kind: TestKind, rows: []const Row, below: ?*Tree, miss: Miss) error{OutOfMemory}!*Tree {
                // Arm collection preserves first-appearance order; rows with
                // the same constructor identity merge into one arm in source
                // order, which is what makes guard fallthrough inside an arm
                // (including duplicate string patterns) retry later rows
                // instead of skipping them.
                var arm_keys: std.ArrayList(u128) = .empty;
                var arm_examples: std.ArrayList(Col) = .empty;
                var arm_rows: std.ArrayList(std.ArrayList(Row)) = .empty;
                var key_index: std.AutoHashMap(u128, usize) = .init(self.arena);

                for (rows) |row| {
                    const col = colAt(row, occ).?;
                    const key = self.ctx.ctorKey(col.pat, col.ty);
                    const gop = try key_index.getOrPut(key);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = arm_keys.items.len;
                        try arm_keys.append(self.arena, key);
                        try arm_examples.append(self.arena, col);
                        try arm_rows.append(self.arena, .empty);
                    }
                    const spec = switch (kind) {
                        .tag, .callable => try self.specTagRow(row, col, kind),
                        .int_switch, .eq_chain => try self.specLiteralRow(row, col),
                        .str_set => try self.specStrRow(row, col, try self.strShapeId(key)),
                        .list_len => try self.specListExactRow(row, col, @truncate(key)),
                    };
                    try arm_rows.items[gop.value_ptr.*].append(self.arena, spec);
                }

                const exit_id: u32 = @intCast(self.exits.items.len);
                try self.exits.append(self.arena, .{ .cont = undefined, .refs = 0 });
                const have_below = below != null;
                const arm_miss: Miss = if (have_below) .{ .exit_ = exit_id } else miss;

                const arms = try self.arena.alloc(Arm, arm_keys.items.len);
                for (arms, arm_keys.items, arm_examples.items, arm_rows.items) |*arm, key, example, rows_list| {
                    arm.* = .{
                        .key = key,
                        .example = example.pat,
                        .example_ty = example.ty,
                        .subtree = try self.compile(rows_list.items, arm_miss),
                    };
                }

                const exhaustive = switch (kind) {
                    .tag => if (self.ctx.tagVariantCount(occ_ty)) |count| arms.len == count else false,
                    .callable => if (self.ctx.callableVariantCount(occ_ty)) |count| arms.len == count else false,
                    .int_switch, .eq_chain, .str_set, .list_len => false,
                };

                const default: ?*Tree = if (exhaustive) null else if (have_below)
                    try self.missTree(.{ .exit_ = exit_id })
                else
                    try self.missTree(miss);

                const node = try self.mk(.{ .test_ = .{
                    .occ = occ,
                    .ty = occ_ty,
                    .kind = kind,
                    .arms = arms,
                    .default = default,
                    .exhaustive = exhaustive,
                } });

                if (!have_below) return node;
                self.exits.items[exit_id].cont = below.?;
                return try self.wrapExit(exit_id, node);
            }
        };

        /// Build the decision tree for one match. All allocations go through
        /// `arena`, which the caller frees wholesale after emission.
        pub fn build(
            arena: std.mem.Allocator,
            ctx: Ctx,
            scrutinee_ty: TypeId,
            branches: []const Branch,
        ) error{OutOfMemory}!BuildResult {
            var builder = Builder{
                .arena = arena,
                .ctx = ctx,
                .occ_entries = .empty,
                .occ_map = .init(arena),
                .exits = .empty,
                .stats = .{},
                .str_shapes = .init(arena),
            };
            try builder.occ_entries.append(arena, .{ .parent = .root, .step = .root, .ty = scrutinee_ty });

            const rows = try arena.alloc(Row, branches.len);
            for (branches, rows) |branch, *row| {
                var cols: std.ArrayList(Col) = .empty;
                var binds: std.ArrayList(Bind) = .empty;
                try builder.normalize(.root, scrutinee_ty, branch.pat, &cols, &binds);
                row.* = .{
                    .cols = cols.items,
                    .binds = binds.items,
                    .guard = branch.guard,
                    .body = branch.body,
                    .branch_index = branch.branch_index,
                };
            }

            const tree = try builder.compile(rows, .fail);
            return .{
                .tree = tree,
                .occs = builder.occ_entries.items,
                .stats = builder.stats,
            };
        }
    };
}

// Construction unit tests over a mock accessor context.

const MockPat = union(enum) {
    bind: u32,
    wildcard,
    as_pattern: struct { pattern: u32, local: u32 },
    record: []const MockSub,
    tuple: []const MockSub,
    nominal: MockSub,
    tag: struct { variant: u16, payloads: []const MockSub },
    int_lit: struct { value: i64, switchable: bool = true },
    dec_lit: i128,
    str_lit: u32,
    str_pattern: struct { shape: u32, captures: []const ?u32 },
    list: struct { elems: []const u32, rest: ?struct { index: u32, pattern: ?u32 } },
};

const MockSub = struct { index: u16, ty: u32, pat: u32 };

const MockCtx = struct {
    pats: []const MockPat,
    variant_counts: []const ?u32 = &.{},

    pub const PatId = u32;
    pub const TypeId = u32;
    pub const ExprId = u32;
    pub const LocalId = u32;

    fn get(self: MockCtx, pat: u32) MockPat {
        return self.pats[pat];
    }

    pub fn patKind(self: MockCtx, pat: u32) PatKind {
        return switch (self.get(pat)) {
            .bind => .bind,
            .wildcard => .wildcard,
            .as_pattern => .as_pattern,
            .record => .record,
            .tuple => .tuple,
            .nominal => .nominal,
            .tag => .tag,
            .int_lit => .int_lit,
            .dec_lit => .dec_lit,
            .str_lit => .str_lit,
            .str_pattern => .str_pattern,
            .list => .list,
        };
    }

    pub fn bindLocal(self: MockCtx, pat: u32) u32 {
        return self.get(pat).bind;
    }

    pub fn asInfo(self: MockCtx, pat: u32) struct { pattern: u32, local: u32 } {
        const info = self.get(pat).as_pattern;
        return .{ .pattern = info.pattern, .local = info.local };
    }

    pub fn recordDestructCount(self: MockCtx, pat: u32) u16 {
        return @intCast(self.get(pat).record.len);
    }

    pub fn recordDestruct(self: MockCtx, pat: u32, ty: u32, i: u16) MockSub {
        _ = ty;
        return self.get(pat).record[i];
    }

    pub fn tupleItemCount(self: MockCtx, pat: u32) u16 {
        return @intCast(self.get(pat).tuple.len);
    }

    pub fn tupleItem(self: MockCtx, pat: u32, ty: u32, i: u16) MockSub {
        _ = ty;
        return self.get(pat).tuple[i];
    }

    pub fn nominalInner(self: MockCtx, pat: u32, ty: u32) MockSub {
        _ = ty;
        return self.get(pat).nominal;
    }

    pub fn tagVariant(self: MockCtx, pat: u32, ty: u32) u16 {
        _ = ty;
        return self.get(pat).tag.variant;
    }

    pub fn tagPayloadCount(self: MockCtx, pat: u32) u16 {
        return @intCast(self.get(pat).tag.payloads.len);
    }

    pub fn tagPayload(self: MockCtx, pat: u32, ty: u32, i: u16) MockSub {
        _ = ty;
        return self.get(pat).tag.payloads[i];
    }

    pub fn tagVariantCount(self: MockCtx, ty: u32) ?u32 {
        if (ty < self.variant_counts.len) return self.variant_counts[ty];
        return null;
    }

    pub fn callableVariant(self: MockCtx, pat: u32, ty: u32) u16 {
        _ = self;
        _ = pat;
        _ = ty;
        unreachable;
    }

    pub fn callablePayload(self: MockCtx, pat: u32, ty: u32) ?MockSub {
        _ = self;
        _ = pat;
        _ = ty;
        unreachable;
    }

    pub fn callableVariantCount(self: MockCtx, ty: u32) ?u32 {
        _ = self;
        _ = ty;
        return null;
    }

    pub const ListPatView = struct {
        fixed_count: u32,
        rest: ?struct { index: u32, pattern: ?u32 },
    };

    pub fn listView(self: MockCtx, pat: u32) ListPatView {
        const list = self.get(pat).list;
        return .{ .fixed_count = @intCast(list.elems.len), .rest = if (list.rest) |r| .{ .index = r.index, .pattern = r.pattern } else null };
    }

    pub fn listElemPat(self: MockCtx, pat: u32, i: u32) u32 {
        return self.get(pat).list.elems[i];
    }

    pub fn listElemTy(self: MockCtx, ty: u32) u32 {
        _ = self;
        return ty + 100; // arbitrary distinct element type id
    }

    pub fn ctorKey(self: MockCtx, pat: u32, ty: u32) u128 {
        _ = ty;
        return switch (self.get(pat)) {
            .tag => |t| t.variant,
            .int_lit => |i| @bitCast(@as(i128, i.value)),
            .dec_lit => |d| @bitCast(d),
            .str_lit => |s| s,
            .str_pattern => |s| s.shape,
            .list => |l| l.elems.len,
            else => unreachable,
        };
    }

    pub fn intSwitchValue(self: MockCtx, pat: u32, ty: u32) ?u64 {
        _ = ty;
        const lit = self.get(pat).int_lit;
        if (!lit.switchable) return null;
        return @bitCast(lit.value);
    }

    pub fn strLitIsSetArm(self: MockCtx) bool {
        _ = self;
        return true;
    }

    pub fn strCaptureCount(self: MockCtx, pat: u32) u16 {
        return switch (self.get(pat)) {
            .str_pattern => |s| @intCast(s.captures.len),
            else => 0,
        };
    }

    pub fn strCapturePat(self: MockCtx, pat: u32, i: u16) ?u32 {
        return self.get(pat).str_pattern.captures[i];
    }
};

const TestCompiler = Compiler(MockCtx);

fn buildMock(
    arena: std.mem.Allocator,
    ctx: MockCtx,
    scrutinee_ty: u32,
    branches: []const TestCompiler.Branch,
) !TestCompiler.BuildResult {
    return try TestCompiler.build(arena, ctx, scrutinee_ty, branches);
}

fn mockBranches(comptime n: usize, pats: [n]u32) [n]TestCompiler.Branch {
    var out: [n]TestCompiler.Branch = undefined;
    for (pats, 0..) |pat, i| {
        out[i] = .{ .pat = pat, .guard = null, .body = @intCast(i), .branch_index = @intCast(i) };
    }
    return out;
}

test "N tag branches with wildcard become one multiway test" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ctx = MockCtx{
        .pats = &.{
            .{ .tag = .{ .variant = 0, .payloads = &.{} } },
            .{ .tag = .{ .variant = 1, .payloads = &.{} } },
            .{ .tag = .{ .variant = 2, .payloads = &.{} } },
            .wildcard,
        },
        .variant_counts = &.{null}, // scrutinee ty 0: open (variant count unknown)
    };
    const branches = mockBranches(4, .{ 0, 1, 2, 3 });
    const result = try buildMock(arena, ctx, 0, &branches);

    // One test node with three arms; the default is the spliced wildcard leaf.
    const node = result.tree.test_;
    try std.testing.expectEqual(TestKind.tag, node.kind);
    try std.testing.expectEqual(@as(usize, 3), node.arms.len);
    try std.testing.expect(!node.exhaustive);
    try std.testing.expectEqual(@as(u32, 3), node.default.?.leaf.branch_index);
    for (node.arms, 0..) |arm, i| {
        try std.testing.expectEqual(@as(u128, i), arm.key);
        try std.testing.expectEqual(@as(u32, @intCast(i)), arm.subtree.leaf.branch_index);
    }
    try std.testing.expectEqual(@as(u32, 0), result.stats.fail_refs);
}

test "closed tag match is exhaustive with no default and no fail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ctx = MockCtx{
        .pats = &.{
            .{ .tag = .{ .variant = 0, .payloads = &.{} } },
            .{ .tag = .{ .variant = 1, .payloads = &.{} } },
        },
        .variant_counts = &.{2},
    };
    const branches = mockBranches(2, .{ 0, 1 });
    const result = try buildMock(arena, ctx, 0, &branches);

    const node = result.tree.test_;
    try std.testing.expect(node.exhaustive);
    try std.testing.expect(node.default == null);
    try std.testing.expectEqual(@as(u32, 0), result.stats.fail_refs);
}

test "open tag match without wildcard keeps a fail default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ctx = MockCtx{
        .pats = &.{
            .{ .tag = .{ .variant = 0, .payloads = &.{} } },
            .{ .tag = .{ .variant = 1, .payloads = &.{} } },
        },
        .variant_counts = &.{3},
    };
    const branches = mockBranches(2, .{ 0, 1 });
    const result = try buildMock(arena, ctx, 0, &branches);

    const node = result.tree.test_;
    try std.testing.expect(!node.exhaustive);
    try std.testing.expect(node.default.?.* == .fail);
    try std.testing.expectEqual(@as(u32, 1), result.stats.fail_refs);
}

test "duplicate constructors merge into one arm preserving row order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // match { A if g => 0, A => 1, B => 2 }
    const ctx = MockCtx{
        .pats = &.{
            .{ .tag = .{ .variant = 0, .payloads = &.{} } },
            .{ .tag = .{ .variant = 0, .payloads = &.{} } },
            .{ .tag = .{ .variant = 1, .payloads = &.{} } },
        },
        .variant_counts = &.{2},
    };
    var branches = mockBranches(3, .{ 0, 1, 2 });
    branches[0].guard = 77;
    const result = try buildMock(arena, ctx, 0, &branches);

    const node = result.tree.test_;
    try std.testing.expectEqual(@as(usize, 2), node.arms.len);
    try std.testing.expect(node.exhaustive);
    // Arm A: guard node for row 0 whose otherwise is row 1's leaf.
    const arm_a = node.arms[0].subtree.guard;
    try std.testing.expectEqual(@as(u32, 0), arm_a.branch_index);
    try std.testing.expectEqual(@as(u32, 77), arm_a.guard);
    try std.testing.expectEqual(@as(u32, 1), arm_a.otherwise.leaf.branch_index);
    try std.testing.expectEqual(@as(u32, 2), node.arms[1].subtree.leaf.branch_index);
}

test "guarded wildcard row splits tag groups and shares the continuation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // match { A => 0, _ if g => 1, B => 2, _ => 3 }
    const ctx = MockCtx{
        .pats = &.{
            .{ .tag = .{ .variant = 0, .payloads = &.{} } },
            .wildcard,
            .{ .tag = .{ .variant = 1, .payloads = &.{} } },
            .wildcard,
        },
        .variant_counts = &.{3},
    };
    var branches = mockBranches(4, .{ 0, 1, 2, 3 });
    branches[1].guard = 42;
    const result = try buildMock(arena, ctx, 0, &branches);

    // Group 1 is a one-arm tag test; its sole miss reference is the default,
    // so the continuation (the guard row and everything below) splices in
    // directly with no exit join. The guard's otherwise chains to the second
    // tag test with the final wildcard as its default.
    const first = result.tree.test_;
    try std.testing.expectEqual(@as(usize, 1), first.arms.len);
    try std.testing.expectEqual(@as(u32, 0), first.arms[0].subtree.leaf.branch_index);

    const guard = first.default.?.guard;
    try std.testing.expectEqual(@as(u32, 1), guard.branch_index);
    const second = guard.otherwise.test_;
    try std.testing.expectEqual(@as(usize, 1), second.arms.len);
    try std.testing.expectEqual(@as(u32, 2), second.arms[0].subtree.leaf.branch_index);
    try std.testing.expectEqual(@as(u32, 3), second.default.?.leaf.branch_index);
    try std.testing.expectEqual(@as(u32, 0), result.stats.fail_refs);
}

test "tag payloads specialize into payload occurrence columns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // match { Ok(1) => 0, Ok(x) => 1, Err => 2 } — nested int test inside Ok.
    const ctx = MockCtx{
        .pats = &.{
            .{ .tag = .{ .variant = 0, .payloads = &.{.{ .index = 0, .ty = 9, .pat = 3 }} } },
            .{ .tag = .{ .variant = 0, .payloads = &.{.{ .index = 0, .ty = 9, .pat = 4 }} } },
            .{ .tag = .{ .variant = 1, .payloads = &.{} } },
            .{ .int_lit = .{ .value = 1 } },
            .{ .bind = 5 },
        },
        .variant_counts = &.{2},
    };
    const branches = mockBranches(3, .{ 0, 1, 2 });
    const result = try buildMock(arena, ctx, 0, &branches);

    const node = result.tree.test_;
    try std.testing.expect(node.exhaustive);
    const ok_arm = node.arms[0].subtree.test_;
    try std.testing.expectEqual(TestKind.int_switch, ok_arm.kind);
    try std.testing.expectEqual(@as(usize, 1), ok_arm.arms.len);
    try std.testing.expectEqual(@as(u32, 0), ok_arm.arms[0].subtree.leaf.branch_index);
    // Default of the inner int test is the spliced Ok(x) leaf with its bind.
    const fallback = ok_arm.default.?.leaf;
    try std.testing.expectEqual(@as(u32, 1), fallback.branch_index);
    try std.testing.expectEqual(@as(usize, 1), fallback.binds.len);
    try std.testing.expectEqual(@as(u32, 5), fallback.binds[0].local);
    // The payload occurrence was interned under the scrutinee root.
    const payload_occ = result.occs[fallback.binds[0].occ.idx()];
    try std.testing.expectEqual(OccId.root, payload_occ.parent);
    try std.testing.expectEqual(@as(u16, 0), payload_occ.step.tag_payload.variant);
    try std.testing.expect(payload_occ.step.tag_payload.single);
}

test "string arms with identical shapes merge and retry on guard failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // match { "${a}!" if g => 0, "${b}!" => 1, "x" => 2, _ => 3 }
    const ctx = MockCtx{
        .pats = &.{
            .{ .str_pattern = .{ .shape = 7, .captures = &.{0xA} } },
            .{ .str_pattern = .{ .shape = 7, .captures = &.{0xB} } },
            .{ .str_lit = 3 },
            .wildcard,
            // capture binds (ids 4/5 unused; captures reference pat ids 10/11 below)
        },
        .variant_counts = &.{},
    };
    // Extend pats with capture bind patterns at ids 0xA and 0xB.
    var pats: [12]MockPat = undefined;
    for (ctx.pats, 0..) |p, i| pats[i] = p;
    pats[4] = .wildcard;
    pats[5] = .wildcard;
    pats[6] = .wildcard;
    pats[7] = .wildcard;
    pats[8] = .wildcard;
    pats[9] = .wildcard;
    pats[0xA] = .{ .bind = 100 };
    pats[0xB] = .{ .bind = 101 };
    const full_ctx = MockCtx{ .pats = &pats, .variant_counts = &.{} };

    var branches = mockBranches(4, .{ 0, 1, 2, 3 });
    branches[0].guard = 55;
    const result = try buildMock(arena, full_ctx, 0, &branches);

    const node = result.tree.test_;
    try std.testing.expectEqual(TestKind.str_set, node.kind);
    try std.testing.expectEqual(@as(usize, 2), node.arms.len);
    // First arm: shape 7; rows 0 (guarded) then 1 merged in order.
    const first_arm = node.arms[0].subtree.guard;
    try std.testing.expectEqual(@as(u32, 0), first_arm.branch_index);
    try std.testing.expectEqual(@as(u32, 1), first_arm.otherwise.leaf.branch_index);
    try std.testing.expectEqual(@as(usize, 1), first_arm.otherwise.leaf.binds.len);
    try std.testing.expectEqual(@as(u32, 101), first_arm.otherwise.leaf.binds[0].local);
    // Guard failure retries the SAME arm's later row — not the group default.
    try std.testing.expectEqual(@as(u32, 2), node.arms[1].subtree.leaf.branch_index);
    try std.testing.expectEqual(@as(u32, 3), node.default.?.leaf.branch_index);
}

test "list exact lengths bucket into one length test with rest row below" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // match { [] => 0, [_] => 1, [_, ..] => 2, [] => dead }
    const ctx = MockCtx{
        .pats = &.{
            .{ .list = .{ .elems = &.{}, .rest = null } },
            .{ .list = .{ .elems = &.{4}, .rest = null } },
            .{ .list = .{ .elems = &.{4}, .rest = .{ .index = 1, .pattern = null } } },
            .{ .list = .{ .elems = &.{}, .rest = null } },
            .wildcard,
        },
    };
    const branches = mockBranches(4, .{ 0, 1, 2, 3 });
    const result = try buildMock(arena, ctx, 0, &branches);

    // Group 1: exact lengths 0 and 1; the rest row breaks the group and
    // becomes a len_check spliced in as the group default (single miss
    // reference, no join). The trailing duplicate [] row lands in its own
    // dead group below the rest row.
    const node = result.tree.test_;
    try std.testing.expectEqual(TestKind.list_len, node.kind);
    try std.testing.expectEqual(@as(usize, 2), node.arms.len);
    try std.testing.expectEqual(@as(u128, 0), node.arms[0].key);
    try std.testing.expectEqual(@as(u32, 0), node.arms[0].subtree.leaf.branch_index);
    try std.testing.expectEqual(@as(u128, 1), node.arms[1].key);
    try std.testing.expectEqual(@as(u32, 1), node.arms[1].subtree.leaf.branch_index);

    const rest = node.default.?.len_check;
    try std.testing.expectEqual(@as(u64, 1), rest.min_len);
    try std.testing.expectEqual(@as(u32, 2), rest.then.leaf.branch_index);
    // The dead trailing [] group still hangs off the rest row's otherwise.
    const dead = rest.otherwise.test_;
    try std.testing.expectEqual(@as(u32, 3), dead.arms[0].subtree.leaf.branch_index);
    try std.testing.expect(dead.default.?.* == .fail);
}

test "leading rest row forms a len_check with the remaining rows below" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // match { [x, ..] => 0, [] => 1 }
    const ctx = MockCtx{
        .pats = &.{
            .{ .list = .{ .elems = &.{2}, .rest = .{ .index = 1, .pattern = null } } },
            .{ .list = .{ .elems = &.{}, .rest = null } },
            .{ .bind = 9 },
        },
    };
    const branches = mockBranches(2, .{ 0, 1 });
    const result = try buildMock(arena, ctx, 0, &branches);

    // The rest row's then-branch never misses, so the continuation splices
    // into the otherwise slot with no join.
    const check = result.tree.len_check;
    try std.testing.expectEqual(@as(u64, 1), check.min_len);
    const then_leaf = check.then.leaf;
    try std.testing.expectEqual(@as(u32, 0), then_leaf.branch_index);
    try std.testing.expectEqual(@as(usize, 1), then_leaf.binds.len);
    const below = check.otherwise.test_;
    try std.testing.expectEqual(TestKind.list_len, below.kind);
    try std.testing.expectEqual(@as(u32, 1), below.arms[0].subtree.leaf.branch_index);
}

test "continuation referenced from two miss sites keeps its exit join" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // match { Ok(1) => 0, _ => 1 }: the wildcard row is reachable both from
    // the tag test's default (scrutinee is Err) and from the inner literal
    // test's miss (scrutinee is Ok(n), n != 1). The continuation must compile
    // once behind an exit join — re-lowering it would violate the sharing
    // invariant.
    const ctx = MockCtx{
        .pats = &.{
            .{ .tag = .{ .variant = 0, .payloads = &.{.{ .index = 0, .ty = 9, .pat = 2 }} } },
            .wildcard,
            .{ .int_lit = .{ .value = 1 } },
        },
        .variant_counts = &.{2},
    };
    const branches = mockBranches(2, .{ 0, 1 });
    const result = try buildMock(arena, ctx, 0, &branches);

    const join = result.tree.exit_join;
    try std.testing.expectEqual(@as(u32, 1), join.cont.leaf.branch_index);
    const tag_test = join.inner.test_;
    try std.testing.expect(tag_test.default.?.* == .exit_);
    const inner = tag_test.arms[0].subtree.test_;
    try std.testing.expectEqual(TestKind.int_switch, inner.kind);
    try std.testing.expect(inner.default.?.* == .exit_);
    try std.testing.expectEqual(@as(u32, 0), result.stats.fail_refs);
}

test "unguarded irrefutable row makes later rows dead" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ctx = MockCtx{
        .pats = &.{
            .{ .bind = 1 },
            .{ .tag = .{ .variant = 0, .payloads = &.{} } },
        },
        .variant_counts = &.{2},
    };
    const branches = mockBranches(2, .{ 0, 1 });
    const result = try buildMock(arena, ctx, 0, &branches);

    const leaf = result.tree.leaf;
    try std.testing.expectEqual(@as(u32, 0), leaf.branch_index);
    try std.testing.expectEqual(@as(u32, 0), result.stats.fail_refs);
}

test "records and tuples destructure without tests" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // match { { x: 1, y } => 0, { x, y: 2 } => 1, { x, y } => 2 }
    const ctx = MockCtx{
        .pats = &.{
            .{ .record = &.{ .{ .index = 0, .ty = 5, .pat = 3 }, .{ .index = 1, .ty = 5, .pat = 4 } } },
            .{ .record = &.{ .{ .index = 0, .ty = 5, .pat = 5 }, .{ .index = 1, .ty = 5, .pat = 6 } } },
            .{ .record = &.{ .{ .index = 0, .ty = 5, .pat = 7 }, .{ .index = 1, .ty = 5, .pat = 8 } } },
            .{ .int_lit = .{ .value = 1 } }, // row0 field x
            .{ .bind = 20 }, // row0 field y
            .{ .bind = 21 }, // row1 field x
            .{ .int_lit = .{ .value = 2 } }, // row1 field y
            .{ .bind = 22 }, // row2 field x
            .{ .bind = 23 }, // row2 field y
        },
    };
    const branches = mockBranches(3, .{ 0, 1, 2 });
    const result = try buildMock(arena, ctx, 0, &branches);

    // First test: field 0 (x == 1); its default splices to the field-1 test
    // (y == 2) with the all-binds row as that test's default.
    const x_test = result.tree.test_;
    try std.testing.expectEqual(TestKind.int_switch, x_test.kind);
    const x_occ = result.occs[x_test.occ.idx()];
    try std.testing.expectEqual(@as(u16, 0), x_occ.step.field);
    try std.testing.expectEqual(@as(u32, 0), x_test.arms[0].subtree.leaf.branch_index);

    const y_test = x_test.default.?.test_;
    const y_occ = result.occs[y_test.occ.idx()];
    try std.testing.expectEqual(@as(u16, 1), y_occ.step.field);
    try std.testing.expectEqual(@as(u32, 1), y_test.arms[0].subtree.leaf.branch_index);
    try std.testing.expectEqual(@as(u32, 2), y_test.default.?.leaf.branch_index);
    try std.testing.expectEqual(@as(u32, 0), result.stats.fail_refs);
}

test "column selection prefers the longer run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two-column matrix via tuples: rows (A, 1) / (B, 1) / (C, 1): the first
    // column runs 3 deep, the second (int) also runs 3 — first wins ties.
    // Make column 2 run longer: (A, 1) / (_, 2) / would break col0... instead:
    // rows: (A, 1), (B, 2), (B, 3): col0 run = 3, col1 run = 3; tie -> col0.
    const ctx = MockCtx{
        .pats = &.{
            .{ .tuple = &.{ .{ .index = 0, .ty = 1, .pat = 3 }, .{ .index = 1, .ty = 2, .pat = 6 } } },
            .{ .tuple = &.{ .{ .index = 0, .ty = 1, .pat = 4 }, .{ .index = 1, .ty = 2, .pat = 7 } } },
            .{ .tuple = &.{ .{ .index = 0, .ty = 1, .pat = 5 }, .{ .index = 1, .ty = 2, .pat = 8 } } },
            .{ .tag = .{ .variant = 0, .payloads = &.{} } },
            .{ .tag = .{ .variant = 1, .payloads = &.{} } },
            .{ .tag = .{ .variant = 1, .payloads = &.{} } },
            .{ .int_lit = .{ .value = 1 } },
            .{ .int_lit = .{ .value = 2 } },
            .{ .int_lit = .{ .value = 3 } },
        },
        .variant_counts = &.{ null, 2 },
    };
    const branches = mockBranches(3, .{ 0, 1, 2 });
    const result = try buildMock(arena, ctx, 1, &branches);

    const node = result.tree.test_;
    try std.testing.expectEqual(TestKind.tag, node.kind);
    const occ = result.occs[node.occ.idx()];
    try std.testing.expectEqual(@as(u16, 0), occ.step.field);
    // Arm B contains rows 1 and 2, distinguished by the int column inside.
    const arm_b = node.arms[1].subtree.test_;
    try std.testing.expectEqual(TestKind.int_switch, arm_b.kind);
    try std.testing.expectEqual(@as(usize, 2), arm_b.arms.len);
}

test "non-switchable ints fall back to eq_chain kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ctx = MockCtx{
        .pats = &.{
            .{ .int_lit = .{ .value = 1, .switchable = false } },
            .{ .int_lit = .{ .value = 2, .switchable = false } },
            .wildcard,
        },
    };
    const branches = mockBranches(3, .{ 0, 1, 2 });
    const result = try buildMock(arena, ctx, 0, &branches);

    const node = result.tree.test_;
    try std.testing.expectEqual(TestKind.eq_chain, node.kind);
    try std.testing.expectEqual(@as(usize, 2), node.arms.len);
    try std.testing.expectEqual(@as(u32, 2), node.default.?.leaf.branch_index);
}

test "pattern node stats count normalized nodes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ctx = MockCtx{
        .pats = &.{
            .{ .tag = .{ .variant = 0, .payloads = &.{.{ .index = 0, .ty = 9, .pat = 1 }} } },
            .{ .bind = 4 },
            .wildcard,
        },
        .variant_counts = &.{2},
    };
    const branches = mockBranches(2, .{ 0, 2 });
    const result = try buildMock(arena, ctx, 0, &branches);
    // Row 0: tag col (1 node at normalize) + payload bind (1 node during
    // specialization); row 1: wildcard (1 node).
    try std.testing.expectEqual(@as(u32, 3), result.stats.pattern_nodes);
}
