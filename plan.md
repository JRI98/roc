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

The reset failure was not a small coding mistake. It was a process failure:
code was changed before the compiler fact being consumed was named, old paths
were left alive next to new paths, and local test failures invited "just inline"
or recursive expansion behavior instead of forcing the missing invariant into
the producer stage. From this point forward, every implementation step follows
the reset protocol below. If the protocol cannot be followed for a change, the
plan or design is incomplete and must be fixed before code changes continue.

The main lesson is that a passing Rocci Bird build or a smaller wasm file is
not evidence that the compiler design is correct. Those are integration
checks. The design is correct only when the optimized lowering consumes
explicit compiler facts and emits ordinary scope-closed LIR with no hidden
iterator, stream, wasm, builtin-name, or source-form knowledge.

The latest reset failure exposed a more specific trap: a wrapper can be
semantically transparent to optimized lowering even when no argument to the
wrapper is itself a known value. Late LIR wrapper inlining can expose the real
producer too late for demand propagation, at which point it is tempting to add
cleanup rewrites or recursive inline paths. That is the wrong stage. Optimized
lowering must consume explicit solved-inline wrapper decisions before demand
propagation begins, and those decisions are ordinary checked compiler data.
If a wrapper only becomes visible after public-value LIR has already been
created, the producer stage is incomplete.

A follow-up failure made the same lesson sharper: solved-inline wrapper facts
are not a global permission to inline a call anywhere. They are producer facts
for optimized lowering under an exact demand. Consuming the same fact again
later in `SolvedLirLower`, or consuming it in a plain materialization context,
can erase useful destination-passing and `Box` update boundaries after the
stage that could have represented them explicitly. The fix must make wrapper
facts single-stage and demand-contextual: structured-demand lowering may use a
transparent wrapper to see the real producer, but late public-value lowering
must not rediscover and inline that wrapper as a cleanup step.

The same failure also exposed demand fixed-point fragility. A fixed point has
not grown merely because the next iteration allocated a fresh demand node,
reordered equivalent entries, or preserved different temporary provenance.
Loop-demand solving must converge by semantic equality of normalized demand
graphs. Iteration limits are debug assertions for compiler bugs, not an
optimization policy, and public materialization must never be used merely to
make a recursive demand terminate.

The next failed implementation slice exposed two additional process hazards.
First, demanded private loop values can introduce generated locals while
cloning a loop body. Those locals are valid only inside the control region that
owns the demanded state. If they are not registered in the active
`DemandFrame`/state-param scope before the body is cloned, later scope checks
will find apparently mysterious unavailable locals. That is not an ARC,
backend, or LIR problem. It means optimized lowering introduced a binding
without also producing the explicit scope fact that makes the binding legal.

Second, finite callable alternatives can have different capture counts and
different demanded capture indexes. A merged callable demand is not a demand
that can be blindly replayed against every alternative. The consumer must keep
capture demand keyed by the original capture identity for the particular
alternative being lowered. If an alternative has fewer captures than a merged
demand vector, the producer-consumer contract is wrong; do not repair this by
padding captures, materializing the callable, dropping the demand, or adding an
arity check at the call site.

The next aborted attempt exposed a third contract gap: public materialization
boundaries are not the same thing as decomposable structural demand. A
non-inlined direct call, hosted call, or backend-visible runtime boundary needs
an ordinary public value for each argument. A sparse private record that carries
only the demanded fields is not a valid substitute, even if its demand graph
contains a `record` demand that came from asking to "materialize" it. Before
optimized lowering splits a loop value into private state, it must know whether
that value will cross a public-value boundary. If it will, the producer must
either keep an explicit public leaf available for that boundary or produce an
explicit public-boundary demand fact. Do not fix this by manufacturing
uninitialized placeholder args, forcing a late direct-call inline, treating
`materialize` as both structural decomposition and public value, or adding a
boundary-local escape hatch.

The same aborted attempt also exposed a process gap in how failures were
classified. The first invariant failure was about loop-state key selection: the
state side had been keyed as an unknown leaf while the entry side had already
been split into private record state. A local change moved that failure forward
to a different invariant: a sparse private value then reached a non-inlined
direct-call boundary and crashed during materialization. Those are two separate
contracts. When a change moves a focused regression to the next invariant, stop
and update the current slice before continuing. Do not keep editing under the
old failure label, and do not treat "made it fail later" as a completed
implementation checkpoint until the newly exposed invariant has its own named
producer fact and passing focused test.

The lesson from that sequence is that sparse private state and public boundary
state must be represented at the same time when a value has both internal
optimized uses and public observation uses. A public boundary must not ask
`materialize` to reverse-engineer a value from whatever sparse private fields
happen to be present. The producer must decide, before the split, whether a
public leaf/public value is needed alongside private fields, and the consumer
must read that explicit fact.

The diagnostic loop that found those issues also showed why temporary
inspection must stay out of commits. Shape dumps, proc counters, disassembly
notes, hardcoded local ids, and "print then infer" debugging are acceptable
while classifying a failure, but they are not compiler facts. Before a change
is committed, the same conclusion must be represented by a focused regression
and an explicit producer-owned fact.

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

The most recent false start exposed a simple but important process hole: adding
a test near the suspected bug is not the same as adding a regression. A new
test that already passes before the production change is useful coverage at
best; it does not prove the missing invariant and must not unblock production
edits. If a newly written test passes, either delete it before moving on or
explicitly keep it as secondary coverage while a separate failing regression is
named.

An existing failing test may serve as the regression, but only if it is treated
with the same discipline as a new one. Before editing production code, record
the exact test filter, the failure mode, and the compiler invariant it proves.
The failure must be the expected compiler invariant failure, not a parse error,
missing platform, unrelated earlier assertion, or Rocci Bird/browser symptom.

The finite-callable crash that triggered this reset is the template for future
work. The relevant invariant is not "Rocci Bird gets smaller" or "the iterator
pipeline happens to build." It is that demanded callable captures are keyed to
the specific finite alternative being lowered. A merged capture-demand vector
must never be replayed positionally against alternatives with different source
capture layouts. That fact must be proved by a focused failing test before the
producer/consumer contract changes.

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
- Late wrapper exposure: move explicit solved-inline wrapper data to optimized
  lowering before demand propagation; do not rely on late LIR inline cleanup.
- Wrapper-context leak: if a solved-inline wrapper fact inlines a public
  materialization boundary or destroys a destination/`Box` update opportunity,
  the fact is being consumed in the wrong context or stage. Move the decision
  to structured-demand lowering or add the missing destination fact there; do
  not repair the resulting LIR afterward.
- Fixed-point non-convergence: reduce to a demand-graph regression, then fix
  demand normalization, reference closure, ordering, or equality. Do not add
  caps, cutoffs, source-specific exits, or public materialization.
- Generated-scope leak: reduce to the smallest private-state body that
  references a generated local outside its owning control region. The fix is to
  make the owner frame expose that local explicitly while cloning the region, or
  to pass the value as an explicit runtime leaf. Do not move the local outward
  based on source shape.
- Cross-alternative callable demand: reduce to finite callable alternatives
  whose captures differ in count or index. The fix is per-alternative demanded
  capture identity. Do not merge capture vectors into a single positional shape
  and apply it to every alternative.
- Public-boundary demand: reduce to a loop-carried private value that is later
  passed to a non-inlined direct call, hosted call, or other public runtime
  boundary. The fix is an explicit producer fact that the boundary needs a
  public value, or an explicit public leaf in the state. Do not model this as
  ordinary structural `record`/`tuple`/`callable` demand, and do not make the
  boundary recover by inspecting sparse private state.

The classification must produce one of these outputs before code changes
continue:

- a new focused failing regression
- a documented contract correction in this file and `design.md`
- deletion of obsolete code that contradicts the contract

If the local fix would need a phrase like "for now", "fallback", "special case",
"detect", "recognize", "cleanup", or "just inline", stop. Either the target
contract is missing an explicit fact, or the implementation is in the wrong
stage.

The same stop rule applies when a change introduces a broad expression-shape
allowlist. A producer may classify a checked expression into an explicit fact,
such as a transparent solved-inline wrapper body or a demanded private value.
An optimized consumer must not keep its own informal list of expression forms
that are "safe enough" to inline, materialize, or skip. If a consumer needs that
answer, add the answer to the producer output and test the producer output
directly.

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

### Reset Implementation Protocol

Each remaining implementation slice is executed in this order:

1. Name the explicit compiler fact.

   Write down which producer owns the fact, which consumer reads it, and why the
   fact is sufficient. Examples: selected compile-time roots from checking,
   solved-inline transparent wrapper bodies, sparse demanded capture indexes,
   normalized loop-demand graph identity, or demand-keyed worker keys.

   If the fact cannot be named this concretely, do not edit lowering code.

2. Add the focused regression before the production change.

   The test must fail for the missing fact and must assert the compiler
   invariant, not the Rocci Bird symptom. Prefer LIR shape, checked output, or
   producer-table assertions over wasm byte size. Browser behavior and wasm
   disassembly are not acceptable first regressions.

   If the first attempted regression passes, stop. Do not reinterpret that
   passing test as evidence. Delete it or mark it as later coverage, then find
   the actual failing invariant. A production diff may start only after there
   is a named failing regression or a named existing failing test that has been
   rerun with its exact filter.

   For existing failures, write down the expected failure class before editing:
   invariant panic, missing scope binding, non-convergence, wrong public
   boundary materialization, wrong LIR shape, or wrong checked producer table.
   If the test fails differently, classify the new failure first instead of
   continuing with the planned fix.

3. Delete contradicted old code in the same slice.

   If the new fact replaces late wrapper cleanup, recursive call expansion,
   dense placeholder state, public materialization used as termination, or
   source-form handling, remove that old behavior while adding the new one. A
   failing test after deletion means the new fact is incomplete; it is not a
   reason to keep both paths.

4. Implement the producer before the consumer.

   The earlier compiler stage must emit explicit data. The optimized consumer
   then reads that data through a narrow API. Do not make the consumer recover
   the answer by walking source-like expression shape, debug names, builtin
   names, proc ids, or LIR emitted by a previous attempt.

5. Keep exactly one optimized consumer for each behavior.

   A solved-inline wrapper fact, demand split, private-state decision, or worker
   key must have one owner in the optimized pipeline. If the same wrapper can be
   consumed both before demand propagation and later as LIR cleanup, one of the
   consumers is wrong. Delete the wrong one before moving on.

6. Prove scope closure before proving shape quality.

   When optimized lowering introduces generated locals, first prove those
   locals are owned by the cloned region or passed explicitly as runtime leaves.
   A LIR shape expectation is not meaningful while scope closure is broken.
   Once the scope regression passes, then check join counts, call counts, and
   private-state shape.

7. Prove per-alternative callable capture demand before broad loop demand.

   A callable-state change that handles only one capture layout is not ready to
   support iterator or stream pipelines. Add or run the focused test where
   finite alternatives have different capture counts or demanded capture
   indexes before using the result to explain Rocci Bird.

8. Prove public-boundary demand before sparse private-state transport.

   If a loop value may be passed to a non-inlined direct call, hosted call, or
   backend-visible boundary, first prove that optimized lowering has an
   explicit public-value fact for that path. Only then split the same value into
   sparse private state for internal iterator, stream, or callable operations.
   A passing private-state shape test is not enough if a later boundary still
   tries to materialize sparse state.

9. Prove the narrow invariant, then update the checklist.

   Run the smallest focused Zig target that exercises the invariant. Check off
   a plan item only when that focused test proves it. Rocci Bird size and
   browser testing are final integration checks, not checklist proof for
   compiler invariants.

10. Clear failed experiments before implementing the next slice.

   The working tree must not carry an exploratory test, diagnostic helper, or
   partial production change that failed to reproduce the intended invariant.
   If the experiment taught something real, move that lesson into this plan or
   `design.md`; otherwise delete it before continuing. This prevents the next
   slice from being built on accidental scaffolding.

11. Reclassify when a fix exposes the next invariant.

   If the focused regression stops failing in the recorded way but fails in a
   new way, do not keep editing under the old slice. Update this plan with the
   new failure text, expected failure class, producer-owned fact, and consumer
   boundary before writing the next production change. A change that only moves
   the failure forward is useful diagnosis, not a commit-ready implementation
   checkpoint.

12. Scan for reset violations before committing.

   Before each commit, verify that no temporary diagnostics, trace scaffolding,
   hardcoded ids, source-form optimization rules, late cleanup rewrites, or
   fallback terminology survived the diff. If a diff contains both an old path
   and a replacement path, the commit is not done.

This protocol intentionally makes progress smaller. It is cheaper to write
three focused regressions and delete one obsolete path than to debug another
large optimized build whose output happens to be smaller for the wrong reason.

Before moving to the next numbered implementation section, verify all of the
following for the section just changed:

- every new behavior has a focused regression that fails without the change
- any passing test added during investigation is either deleted before the
  production slice or explicitly documented as secondary coverage, never as the
  gating regression
- any existing failing test used as the regression has its exact filter,
  expected failure mode, and invariant recorded before production edits
- no forbidden words or concepts were introduced into optimized lowering
- replaced code was deleted in the same commit
- the relevant focused Zig target passes
- the completion checklist was updated only for facts proven by tests or
  architecture checks
- no temporary diagnostic prints, trace scaffolding, browser-refresh debugging,
  or disassembly-derived recognition survived the local investigation
- any new fixed-point loop is proved by a regression that converges because the
  demand graph is semantically stable, not because an iteration limit or
  fallback path stops it
- solved-inline wrapper facts have exactly one optimized consumer for the
  behavior being changed; if both `spec_constr` and `SolvedLirLower` can inline
  the same source wrapper, there must be a focused regression proving that the
  later consumer cannot erase a destination-passing, `Box`, ARC, or private
  state boundary

Do not check off a Rocci Bird item until the focused compiler tests for the
underlying invariant have passed. Do not check off a compiler invariant because
Rocci Bird got smaller.

## Recent Verified Implementation Slice

The active regression for the finite-callable projection change was:

```sh
zig build run-test-zig-lir-inline -- --test-filter "direct range map collect uses direct list loop"
```

Before the change, this crashed with:

```text
postcheck invariant violated: callable demand capture index exceeded lifted function capture count
```

Expected failure class: cross-alternative callable demand. The invariant being
proved is that a callable result demand applied to finite callable alternatives
must derive demanded captures for each alternative's own source function and
capture layout. A merged callable capture vector is not valid input for every
alternative when the alternatives differ in capture count or capture index.

After the per-alternative projection change, the same filter exposed the next
expected failure class:

```text
postcheck invariant violated: finite demanded state reached private-state argument construction before expansion
```

The invariant being proved is that callable specialization capture patterns
must use the private-state contract before they reach private-state argument
construction. If a demanded capture contains finite tag or finite callable
state, the capture-pattern producer must compact that demanded-known value
recursively; the argument constructor must not expand it into public values or
recover the shape later.

After compacting capture patterns, the same filter exposed a scope-closure
failure:

```text
postcheck invariant violated: materialized expression still referenced unavailable bindings
```

Expected failure class: generated-scope leak. A compact finite callable branch
creates payload locals while building the branch pattern and then immediately
clones the branch body. Those locals are valid inside that branch body, so the
branch-body producer must register them in the active checked scope while it is
cloning the branch. The fix is not to move the locals outward, inline a
surrounding call, or materialize public callable state; it is to make the
owning branch scope explicit during body construction.

Verification after the change:

```sh
zig build run-test-zig-lir-inline -- --test-filter "direct range map collect uses direct list loop"
zig build run-test-zig-lir-inline -- --test-filter "plant iter pipeline collect uses direct range map list loop"
zig build run-test-zig-lir-inline -- --test-filter "known-length List.iter collect specializes without unbound locals"
```

The full `zig build run-test-zig-lir-inline --summary all --color off` target
still fails after this slice. The next remaining failure class starts in
optimized loop entry/state construction, not in finite callable capture
projection.

Do not use this verified slice as evidence for the remaining loop-demand,
public-boundary, or broad scope-closure checklist items.

## Current Implementation Slice

The active regression for the loop-entry private-state key change and the
public-boundary follow-up is:

```sh
zig build run-test-zig-lir-inline -- --test-filter "imported iterator producer keeps finite step callables"
```

Before the change, this crashes with:

```text
postcheck invariant violated: optimized loop entry values could neither select a state nor be emitted as ordinary loop initials
```

Expected failure class: loop-state key mismatch. The diagnostic shape was:

```text
state 0: any leaf
entry: private_state(record) expr
```

The invariant is that state-loop keys and entry keys must be derived from the
same demanded representation. If optimized lowering decides that a loop entry
is carried as demanded private state, the state key producer must key the loop
state from that demanded private shape too. It must not key the state from the
original public value and then ask a private entry value to match it.

After the local loop-key change, the same focused regression moves to:

```text
postcheck invariant violated: sparse private state reached materialization
```

Expected failure class: public-boundary demand. The crash occurs while cloning
a non-inlined direct-call boundary argument. A sparse private value is valid for
internal demanded-state transport, but it is not an ordinary public argument.
The next producer fact must say when a loop-carried value also needs an
ordinary public value for a direct-call, hosted-call, or backend-visible
boundary. The fix must not be in `materialize`, must not force a late direct
call inline, and must not treat structural `record` demand as equivalent to a
public runtime value.

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
- Treat explicit solved-inline wrapper bodies as producer facts for optimized
  lowering. A transparent wrapper can expose a finite callable producer even
  when the wrapper call has no known-value argument.
- Add tests for one target, multiple targets, differing capture counts,
  differing capture indexes, omitted captures, callable reuse after optimized
  call, public callable crossing, and a user wrapper that exposes a builtin
  iterator producer before demand propagation.
- Do not normalize differing capture shapes by building public erased callables
  unless materialization demand explicitly requires a public callable value.
- Do not depend on late LIR wrapper inlining to create the optimized shape. The
  solved-inline plan is an input to optimized lowering, not a cleanup pass after
  optimized lowering failed to see through a wrapper.

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
- Add tests where two loop iterations produce freshly allocated but
  semantically identical demands. Those tests must converge by normalized graph
  equality, including active loop-demand references and closed references.
- Demand equality, merge, and closure must be deterministic. Changing arena
  allocation order, temporary ids, or source traversal order must not make an
  unchanged demand look like growth.

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
- A direct call does not become eligible for optimized cloning because source
  text looks wrapper-like or because LIR cleanup would later inline it. It is
  eligible when explicit optimized context contains the necessary producer
  facts: known argument values, solved-inline wrapper body data, or an existing
  demand-keyed worker fact.

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
- [x] Reset implementation protocol records the failure mode from the aborted
      wrapper/inline attempt: name the producer fact, add the focused
      regression first, delete contradicted old paths, keep one consumer, and
      treat Rocci Bird/wasm size only as integration validation.
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
- [ ] Demand fixed points compare normalized semantic demand graphs, not arena
      identity, temporary provenance, or entry order.
- [ ] A focused non-convergence regression covers repeated equal loop demands
      with active and closed loop-demand references.
- [ ] Primitive demanded values optimize without aggregate wrapping.
- [ ] Primitive and single-field-record loop state optimize equivalently.
- [ ] Sparse private state distinguishes omitted children from
      unknown-but-carried children.
- [x] Finite callable alternatives remain finite across differing capture
      shapes.
- [x] Explicit solved-inline wrapper bodies are available to optimized lowering
      before demand propagation.
- [x] Materialize-safe wrapper bodies are classified by the solved-inline
      producer, including transitive direct-call wrappers whose callees already
      have materialize-safe inline bodies.
- [x] A user wrapper around a builtin iterator producer optimizes without
      relying on late LIR wrapper cleanup.
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
