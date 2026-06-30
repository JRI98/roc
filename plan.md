# Optimized Callable-State Lowering Plan

## Goal

Implement optimized callable-state lowering as the compiler's single design for
turning Roc `Iter`, `Stream`, and other callable-state values into tight code in
optimized builds.

The target generated shape is Rust-like iterator lowering: private cursor
state, direct stepping, no heap allocation for adapter wrappers in consuming
hot paths, no unobserved public length-hint work, and ordinary LIR before ARC.
Roc does not adopt Rust's public typing model. `Iter(item)` and `Stream(item)`
remain concrete public Roc records whose step fields are ordinary Roc lambdas.
The optimizer uses existing lambda-set data, captures, known values, exact
result demand, and loop-demand graph nodes to reach the private cursor shape.

This optimizer runs only for `--opt=size` and `--opt=speed`. Every other mode
uses ordinary public-value lowering and constructs no optimized demand graphs,
sparse private-state tables, loop fixed-point nodes, or demand-keyed workers.

## Current Checkpoint

The debug and experimental WIP paths have been removed. The remaining direction
is the target design, not a fallback plan.

Deleted or verified absent:

- trace/debug instrumentation for specialization debugging
- hardcoded local-id tripwires
- compact-result demand-refinement experiments
- leaf conditional splitting fallback logic
- public or private `Append` step variants
- explicit iterator-plan or stream-plan IR
- source-form optimization rules for `for`, `if`, `match`, `Iter.append`, or
  `Stream.next!`
- recursive direct-call fallback as a substitute for loop-demand graph nodes

Added minimal contract tests:

- finite callable private state preserves differing demanded capture indexes
- loop-demand references can nest through callable step-result demand without
  requiring materialization or infinite structural expansion

## Reset Guardrails

The previous attempt went off track because implementation pressure started
producing diagnostics, temporary refinement paths, source-shape repairs, and
special-case fallbacks before the core contract was fully represented. The rest
of this plan must be implemented with these guardrails.

The main lesson is that a passing Rocci Bird build or a smaller wasm file is
not evidence that the compiler design is correct. Those are integration
checks. The design is correct only when the optimized lowering consumes
explicit compiler facts and emits ordinary scope-closed LIR with no hidden
iterator, stream, wasm, builtin-name, or source-form knowledge.

Every change starts from the contract, not from Rocci Bird or final wasm size.
Rocci Bird is the motivating integration case, but it is not the design source
of truth. If a Rocci Bird failure cannot be explained through `Demand`,
`KnownValue`, `PrivateState`, `FiniteCallableState`, `LoopDemandNode`,
`DemandFrame`, or `WorkerKey`, stop and add the missing compiler fact or revise
the contract before changing lowering.

Do not debug this by repeatedly changing Rocci Bird and refreshing a browser.
Use minimal compiler regressions first, then LIR inspection, then wasm
disassembly. Browser testing is only a final human validation that the
optimized build still runs.

Every behavior change gets a minimal compiler regression first. The regression
should use the smallest source or Zig unit shape that proves the invariant:
capture indexes, loop-demand references, public materialization, scope closure,
effect order, or ordinary-LIR output. Rocci Bird and disassembly checks come
after those focused tests, not instead of them.

No implementation step may add a second path to keep progress moving. In
particular, do not add:

- trace or print debugging committed to the branch
- hardcoded ids, local numbers, symbol names, proc names, builtin names, wasm
  details, or Rocci Bird-specific recognition
- a fallback from optimized lowering to ordinary public-value lowering
- a cleanup pass that removes wrappers after public-value lowering created them
- source-form branches for `for`, `if`, `match`, `.iter()`, `.append()`, or
  `.next`
- recursive direct-call expansion as a replacement for loop-demand graph nodes
- nullable optimized fields on ordinary lowering state
- dense private-state placeholders for omitted children
- public/private step-shape changes such as adding `Append` to `Iter`
- temporary result-refinement or call-rewrite paths whose inputs are not exact
  compiler data from the target contract

When a test fails, classify the failure before changing code:

- Missing explicit data: add the data to the producing stage and consume it
  directly.
- Wrong invariant: fix the invariant and add a regression that would have caught
  the wrong one.
- Scope leak: keep the binding inside the owning control region or pass it as an
  explicit runtime leaf.
- Demand recursion: represent it through `LoopDemandNode`, not structural
  expansion or recursive direct-call fallback.
- Public observation: add materialization demand at the observation boundary.
- Backend/ARC issue: first prove optimized lowering emitted ordinary
  scope-closed LIR; only then change ARC or backend code.

The classification must produce one of these outputs before code changes
continue:

- a new focused failing regression
- a documented contract correction in this file and `design.md`
- deletion of obsolete code that contradicts the contract

If the local fix would need a phrase like "for now", "fallback", "special case",
"detect", "recognize", "cleanup", or "just inline", stop. Either the target
contract is missing an explicit fact, or the implementation is in the wrong
stage.

The same stop rule applies to "public compatibility" arguments. `Iter` and
`Stream` keep their current public shape, and the optimizer must make that shape
lower well. Do not change the public step union, add a private public-looking
variant, or normalize at a new API boundary to make the optimizer easier.

Each commit should leave the branch in one of two states:

- a pure contract/test/doc checkpoint with no behavior change, or
- an implementation checkpoint whose new tests pass and whose diff removes any
  obsolete path it replaces

Do not keep obsolete code beside replacement code unless both are permanent
public paths described by this plan. Ordinary public-value lowering and
optimized callable-state lowering are the two permanent paths; everything else
is suspect until justified by the target contract.

Before moving to the next numbered implementation section, verify all of the
following for the section just changed:

- every new behavior has a focused regression that fails without the change
- no forbidden words or concepts were introduced into optimized lowering
- replaced code was deleted in the same commit
- the relevant focused Zig target passes
- the completion checklist was updated only for facts proven by tests or
  architecture checks

Do not check off a Rocci Bird item until the focused compiler tests for the
underlying invariant have passed. Do not check off a compiler invariant because
Rocci Bird got smaller.

## Target Contract

The optimized entrypoint owns builder-local optimizer data. That data is not a
stored public IR stage and must not escape into LIR, ARC, interpreters, LLVM,
wasm, Binaryen, or linkers.

Required internal data:

- `Demand`: exact continuation use of a value, including materialization,
  runtime leaves, fields, tuple items, nominal backing data, tag alternatives
  and payloads, callable captures and results, direct-call results, and
  loop-carried values.
- `KnownValue`: checked producer structure, including primitive leaves,
  records, tuples, tags, nominals, finite callable targets, and finite tag
  choices.
- `PrivateState`: optimized-only state with sparse demanded children. Missing
  children mean not carried. Present unknown children mean carried runtime
  leaves.
- `FiniteCallableState`: ordinary lambda-set target data plus demanded captures
  by original capture index. Alternatives may have different capture shapes.
- `LoopDemandNode`: graph identity for recursive loop-carried demand. A nested
  demand may refer back to a loop parameter while the owning fixed point is
  active; references must be resolved or closed before crossing worker,
  public-materialization, or LIR boundaries.
- `DemandFrame`: the transient producer-consumer boundary while cloning under
  demand, including the checked control scope that owns any locals introduced
  while satisfying that demand.
- `WorkerKey`: exact compiler data for optimized direct-call workers: callee
  identity, split argument facts, split capture facts, result demand, and
  relevant type/layout decisions.

Output:

- ordinary scope-closed LIR only
- explicit LIR ARC statements only
- no iterator, stream, private-cursor, demand, worker-key, or loop-demand-node
  concepts in LIR, ARC, or backend code

Forbidden shapes:

- public or compiler-private `Append` step variants
- explicit iterator plans, stream plans, or adapter-chain IR
- source-form rewrites for `for`, `if`, `match`, `Iter.append`, or
  `Stream.next!`
- target, wasm, Rocci Bird, generated-symbol, object-byte, or disassembly
  recognition rules
- late cleanup passes after public-value lowering
- state-count, size-count, or "try optimized then fall back" cutoffs
- dense private state that cannot distinguish omitted children from carried
  unknown children
- hidden mutation of public iterator, stream, callable, or source mutable values

## Implementation Plan

### 1. Preserve The Public Model

- Keep public `Iter` and `Stream` as the three-step shape: `One`, `Skip`,
  `Done`.
- Keep `len_if_known` as a public field that is demanded only when source code
  observes it.
- Keep adapter construction in Roc source as ordinary records and ordinary
  lambdas.
- Add architecture checks that reject any reintroduction of `Append` as an
  iterator step or any explicit iterator-plan IR.
- Before changing optimizer code, add source scans or structural tests for the
  forbidden public/private iterator shapes so obsolete representations cannot
  reappear silently.

### 2. Mode Gate And Context Ownership

- Compute the post-check lowering family once from explicit build mode.
- Construct ordinary public-value lowering for all non-optimized modes.
- Construct optimized callable-state lowering only for `--opt=size` and
  `--opt=speed`.
- Make optimized helpers require optimized-owned data in their API.
- Add tests proving dev/check/interpreter/finalization paths construct no
  optimized context and optimized modes enter the same optimized entrypoint.
- Delete nullable optimized fields from any ordinary lowering state before
  adding replacement optimized-owned fields elsewhere.

### 3. Demand Model

- Make result demand explicit at every optimized producer-consumer boundary.
- Represent materialization, runtime leaves, records, tuples, nominals, tags,
  callables, direct-call results, and loop-carried values.
- Merge demand deterministically and exactly.
- Keep recursive loop demand as graph references, not copied trees.
- Close or resolve loop-demand references before worker, materialization, or
  LIR boundaries.
- Add tests for nested loop references, field/tuple/tag demand, callable
  result demand, and active-reference closure.
- Any new demand merge rule must state which exact demand forms it consumes and
  must not inspect source syntax, proc debug names, or backend output.

### 4. Known Values And Sparse Private State

- Treat primitive known leaves as first-class. A primitive loop cursor must
  optimize equivalently to a single-field record wrapping that primitive.
- Store demanded children sparsely by checked identity: record field name,
  tuple item index, tag payload index, nominal backing value, and callable
  capture index.
- Preserve the difference between omitted children and carried unknown
  children.
- Convert sparse private state to public values only at explicit
  materialization boundaries.
- Add tests for primitive leaves, single-field records, sparse records, sparse
  tuples, sparse tags, sparse callables, sparse nominals, and public
  materialization.
- Do not introduce dense placeholder children to satisfy an existing helper.
  Change the helper to consume sparse identity-keyed state.

### 5. Finite Callable-State Defunctionalization

- Use existing lambda-set data as the only source of finite callable targets.
- Carry demanded captures by original capture index.
- Inline a single known target directly when demand and scope allow it.
- Dispatch over multiple known targets without widening to a public erased
  callable merely because capture shapes differ.
- Keep callable alternatives private until source code observes a public
  callable boundary.
- Add tests for one target, multiple targets, differing capture counts,
  differing capture indexes, omitted captures, callable reuse after optimized
  call, and public callable crossing.
- Do not normalize differing capture shapes by building public erased callables
  unless materialization demand explicitly requires a public callable value.

### 6. Loop Demand Fixed Points

- Represent loop-parameter demand with explicit graph nodes owned by the loop
  fixed point.
- Merge body observations and reachable `continue` edges monotonically.
- Reclone provisional edge values when demand grows.
- Carry runtime leaves as loop parameters, not finite-state dimensions.
- Keep known tag/callable choices as finite private states only when demanded.
- Keep branch, match, guard, stream effect, `dbg`, `expect`, `crash`,
  `break`, and `return` order exactly as checked source requires.
- Add tests for list iterators, iterator append/concat phase changes, runtime
  cursor leaves, mutually recursive loop parameters, source mutable variables,
  `break`, `return`, stream effects, and infinite iterators.
- If loop demand appears to need unbounded structural expansion, add or use a
  loop-demand graph reference. Do not cap the expansion or switch to public
  materialization to terminate it.

### 7. Control Boundaries

- Treat branches, matches, loops, and direct calls as the same
  producer-under-demand mechanism.
- Do not add source-specific rules for `if`, `match`, `for`, or iterator
  builtins.
- Keep branch-local and match-payload locals inside the cloned region that owns
  them.
- If a demanded private value crosses a control boundary, pass the needed value
  as an explicit runtime leaf or keep the binding inside the state body.
- Reject any private-state body that references an out-of-scope local before
  LIR reaches ARC.
- Add tests for if-joined state, match-joined state, branch-local payloads,
  pending lets, and scope-closed private-state bodies.
- Do not repair branch or match failures by adding special splitting code under
  leaf demand. The same demand-frame mechanism must handle every control
  boundary.

### 8. Demand-Keyed Direct-Call Workers

- Create optimized workers only while cloning a call under explicit optimized
  demand.
- Key workers by callee identity, split argument facts, split capture facts,
  result demand, and relevant type/layout decisions.
- Keep the original public-ABI body available.
- Share workers only when all correctness-relevant facts match.
- Add tests proving worker creation in both optimized modes, no worker creation
  in non-optimized modes, deterministic worker reuse, and public call
  correctness without workers.
- A worker key is not complete until it includes every fact that can affect
  generated behavior. If two calls need different code, add the missing fact to
  `WorkerKey` instead of adding a side condition at the call site.

### 9. Public Boundaries And Effects

Materialize public values when source code observes them, including:

- returning, storing, or passing an iterator or stream
- reading `len_if_known`
- directly matching on public `Iter.next` or `Stream.next!`
- returning, storing, or passing a callable through a public/erased boundary
- storing private candidates in records or lists that source later observes

Add tests for iterator reuse, storing iterators in records/lists, passing
through unspecialized code, direct public `next` matches, length hints, stream
effect ordering, and custom unbounded iterators.

### 10. Lower To Ordinary LIR

- Lower private state machines to ordinary joins, blocks, switches, calls, and
  jumps.
- Ensure every state body is scope-closed before ARC insertion.
- Keep ARC and backends limited to ordinary LIR and explicit RC statements.
- Add source scans or architecture checks proving backend and ARC code do not
  contain iterator, stream, private-cursor, demand, or worker-key concepts.
- Do not use ARC, backend output, wasm disassembly, or Binaryen output to
  recover missing optimized-lowering data.

### 11. Rocci Bird And Rust Validation

Build and record:

- Rocci Bird with `.iter()` collision points using Roc `--opt=size`
- Rocci Bird with direct-list collision points using Roc `--opt=size`
- Rust Rocci Bird with Rust size optimizations and Binaryen

For each Roc build:

- record final wasm byte size
- disassemble `update`
- count normal-playing-path allocator wrapper calls
- count normal-playing-path public iterator/callable wrapper calls
- compare collision-loop control flow
- confirm static collision/sprite data is emitted as static data when eligible
- confirm unobserved `len_if_known` work is absent
- explain any remaining Roc-vs-Rust gap with concrete disassembly evidence and
  a compiler issue or follow-up plan when it violates this design

## Test Commands

Run focused tests first:

```sh
zig build run-test-zig-module-postcheck --summary all --color off
zig build run-test-zig-lir-inline --summary all --color off
zig build run-test-cli --summary all --color off
```

When `zig build minici` fails in one section, fix that section and rerun that
specific failing section until it passes. Return to full `minici` only after
the targeted section passes.

```sh
zig build minici
```

## Completion Checklist

- [x] Architecture checks reject `Append` iterator steps and explicit iterator
      plans.
- [x] Architecture checks reject committed trace/debug scaffolding and
      hardcoded local/proc/symbol recognition in optimized lowering.
- [x] Optimized callable-state lowering is constructed only for `--opt=size`
      and `--opt=speed`.
- [x] Non-optimized paths construct zero optimized demand/private-state/worker
      data.
- [ ] Result demand is explicit compiler data everywhere optimized lowering
      needs it.
- [ ] Every optimizer behavior change has a focused compiler regression before
      Rocci Bird validation.
- [ ] Loop-carried demand is represented by graph nodes and reaches a fixed
      point over body observations and reachable `continue` edges.
- [ ] Loop-demand references are closed or resolved before worker,
      materialization, and LIR boundaries.
- [ ] Primitive demanded values optimize without aggregate wrapping.
- [ ] Primitive and single-field-record loop state optimize equivalently.
- [ ] Sparse private state distinguishes omitted children from
      unknown-but-carried children.
- [ ] Finite callable alternatives remain finite across differing capture
      shapes.
- [ ] Public materialization is explicit.
- [ ] Private-state bodies are scope-closed before LIR.
- [ ] Demand is threaded through fields, tuples, tags, callables, direct calls,
      branches, matches, and loops.
- [ ] No implementation step relies on source-form rules, target rules,
      generated names, disassembly, or post-lowering cleanup.
- [ ] Public iterator reuse and public materialization boundaries are correct.
- [ ] Stream effect ordering is correct.
- [ ] Infinite iterator examples work.
- [ ] LIR, ARC, and backends contain no iterator/stream/private-cursor logic.
- [ ] Focused iterator allocation/control-flow regressions pass.
- [ ] Rocci Bird `.iter()` and direct-list collision loops have equivalent
      optimized hot-path disassembly.
- [ ] Rocci Bird `.iter()` has no normal-path `Iter.append` allocation.
- [ ] Rocci Bird `.iter()` has no normal-path public wrapper allocation.
- [ ] Rocci Bird `.iter()` has no unobserved `len_if_known` hot-path work.
- [ ] Rocci Bird final `--opt=size` wasm size is recorded.
- [ ] Rust comparison wasm size is recorded.
- [ ] Remaining Roc-vs-Rust size gap is explained with disassembly evidence.
- [x] `zig build run-test-zig-module-postcheck --summary all --color off`
      passes.
- [ ] `zig build run-test-zig-lir-inline --summary all --color off` passes.
- [ ] `zig build run-test-cli --summary all --color off` passes.
- [ ] `zig build minici` passes.
