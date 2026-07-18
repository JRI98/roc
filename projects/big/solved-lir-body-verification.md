# Body-Level Verification for the Direct Solved-to-LIR Path

## Problem

The production pipeline's final lowering fuses two prototype stages: the
cor `lss` pipeline goes lambdasolved → lambdamono → ir as separate,
individually-inspectable passes, while production lowers Lambda Solved
directly to LIR in one pass (`src/postcheck/solved_lir_lower.zig`,
~7,700 lines), computing Lambda Mono decisions inline. design.md sanctions
this and prescribes the guard: a Debug-only verifier that materializes the
logical Lambda Mono tree and checks it against the direct path
(`verifyMaterializedDecisions`, `solved_lir_lower.zig:1876`).

The guard has a structural coverage gap: it verifies **decisions only** —
function specializations, callable variants, capture records,
roots/layout/schema requests (design.md lists these; the implementation
matches). It never verifies **lowered statement bodies**: the actual
LIR — capture pack/unpack sequences, discriminant switches, match branch
chains, field indices, evaluation order — is produced exactly once, by the
direct path, and compared against nothing. The one artifact that was a
faithful body-level port of cor's `ir/lower.ml` (`postcheck/lir_lower.zig`)
was dead code and was deleted in the duplication-audit cleanup
(PR roc-lang/roc#10079) — correctly, since an unexercised oracle is drift,
not protection. But its deletion makes the gap permanent by default: a
body-lowering bug in `solved_lir_lower.zig` (a misordered capture field,
a wrong variant index, a swapped branch target) is caught today only if an
end-to-end test happens to execute the affected construct with a
discriminating input.

The 2026-07 cor-comparison review found no body-lowering bug — the
construct-by-construct comparison against cor's `ir/lower.ml` and `eval/`
semantics checked out, with the classic hazards (capture pack/unpack
alignment, trailing capture argument, record field canonicalization)
explicitly `invariant()`-guarded. The finding is not a defect; it is that
the fused path's correctness currently rests on hand-verification plus
whatever the eval corpus happens to cover, and both erode as the file
changes. This is the highest-leverage remaining structural risk from that
review.

## Background

The compiler pipeline: parse → canonicalize → type-check → postcheck:
Monotype IR → Monotype Lifted → Lambda Solved → **direct solved-to-LIR
lowering** (with Debug Lambda Mono decision verification) → TRMC →
ScalarizeJoins → ReachableProcs → ARC → backends. design.md's "Debug
Lambda Mono Verification" section is the contract; note its list of
checked decisions is prefixed "at least these explicit decisions" — body
verification is an extension it already permits, not a policy change. The
verifier must remain release-free: no tree allocation, no verifier data
structures, compile-time-dead in release.

cor's own architecture points at the answer it used: cor never verified
lowering against lowering — it verified by **executing**. Its `eval/`
stage is a tiny interpreter over the final IR, and the test suite compares
evaluated results. Production has richer analogs: the LIR interpreter
(`src/eval/`), the dev backend, the LLVM backend, and the wasm backend all
execute the same LIR, and cross-opt/cross-backend agreement is already the
stated ground truth in sibling projects.

## Evidence

All symbols verified in the current tree (post-#10079).

- `src/postcheck/solved_lir_lower.zig`: `verifyMaterializedDecisions`
  (`:1876`) — Debug-gated (`:1877`), checks fn entries, roots, layout
  requests, runtime schema requests (`:~1896-1899`), nothing below the
  proc-signature level; the direct body lowering it does not cover:
  decision-tree match lowering (`lowerBranchTree`, `:~4294`, via
  src/postcheck/match_tree.zig), capture record build
  (`lowerCaptureRecordFromCaptureExprsInto`, `:~2398`) and bind
  (`bindCaptureRecord`, `:~818`), callable dispatch
  (`lowerCallableValueCallInto`, `:~3418`), list patterns
  (`lowerListPatternThen`, `:~5216`).
- `src/postcheck/lambda_mono/lower.zig`: the Debug oracle already
  materializes full Lambda Mono **bodies** (expressions, patterns,
  statements) — the tree exists in Debug runs; only the comparison
  stops at decisions.
- design.md "Debug Lambda Mono Verification": "checks at least these
  explicit decisions" — extension-friendly wording; release-zero-cost
  requirement.
- cor reference: `ir/lower.ml` + `eval/runtime.ml` (execution as the
  oracle); the review's construct-by-construct comparison table.

## Solution design

This project needs a design decision first; the two viable shapes, with a
recommendation:

**Option A — execute the oracle (recommended).** Give the Debug-only
Lambda Mono tree a small tree-walking evaluator — cor's `eval/` stage,
productionized to Lambda Mono instead of a second LIR lowerer. In Debug
runs (or a dedicated CI mode), evaluate test-program roots over the
materialized Lambda Mono tree and compare results against the LIR
interpreter executing the direct path's output. Divergence pinpoints a
body-lowering bug (or an oracle bug — either is worth knowing) with a
concrete program and value in hand.

- Pro: an evaluator over the *pre-LIR* tree is a genuinely independent
  derivation (different representation, different traversal), immune to
  the correlated-bug problem a second lowerer had; it is also far smaller
  than a lowerer (cor's whole evaluator is ~250 lines; the production
  tree is richer but the same order of magnitude, because Lambda Mono is
  decisions-plus-monotype-shapes, not layouts).
- Con: it duplicates runtime semantics (numeric ops, string ops) that
  must be delegated to the shared builtins where possible; scope the
  evaluated corpus to programs whose ops it supports and fail loudly on
  unsupported constructs rather than approximating.

**Option B — differential execution without a new evaluator.** Skip the
oracle entirely; build the harness that runs every eval-corpus program
under interpreter, `--opt=dev`, and `--opt=speed` across backends and
asserts identical output, then grow the corpus adversarially toward the
uncovered constructs (generated programs sweeping capture counts/orders,
lambda-set sizes, match shapes, list-pattern rests, guard combinations).

- Pro: no new semantic surface to maintain; strengthens the whole
  pipeline, not just this pass.
- Con: coverage is empirical, not structural — a body bug still hides if
  no generated program discriminates it; and failures localize to "these
  two backends disagree", not to the lowering site.

Recommendation: **A**, seeded with B's generated-program corpus as the
input set (the generator is useful to both and is the bulk of B's work
anyway). Decide explicitly at kickoff; if A's evaluator turns out to need
more than ~2 weeks, descope to B and file the evaluator as follow-up —
recorded, not implicit.

Mutation-hardening either way: whichever harness lands must be validated
by seeded mutations — deliberately break `solved_lir_lower.zig` in five
representative ways (swap capture order at pack site only, off-by-one a
variant index, reorder two match branches, drop a list-rest binding, swap
argument evaluation order) and confirm each is caught. A verifier that
passes on mutants is theater; this is the acceptance test *of the
verifier*.

## What success looks like

- A body-level divergence in `solved_lir_lower.zig` is caught by Debug CI
  on the existing corpus, demonstrated by the five seeded mutations each
  failing the harness.
- Release builds are bit-identical and pay zero cost (compile-time-dead
  verification branches, per design.md).
- The verifier's coverage is stated: which constructs the evaluator
  executes (A) or which construct dimensions the generator sweeps (B),
  with unsupported/unswept constructs listed in the harness, not silently
  skipped.

## How to evaluate the result

### Correctness ideal

- Independence: the oracle derivation shares no lowering code with the
  direct path (A: a tree evaluator; B: whole other backends). Shared
  builtins are acceptable shared ground truth.
- Localization: a failure names the first diverging root/value (A) — or,
  under B, the failing program plus disagreeing backend pair — and
  reproduces deterministically.
- The decision-level verifier stays exactly as design.md specifies; this
  project adds a layer, it does not restructure the existing one.

### Performance ideal

Debug/CI cost only. Measure Debug corpus wall time with the harness on;
budget it as a CI lane rather than forcing it into every local Debug run
if it exceeds ~10% of suite time (a `zig build` step flag, mirroring the
guarded-list violation harness pattern).

## Tests to add

- The five seeded-mutation checks, automated (apply patch, expect harness
  failure, revert) or maintained as a documented manual release-checklist
  item if patch automation is too brittle — decided at implementation.
- The generated-program corpus: sweeps over capture count (0, 1, 2, 8),
  capture types (scalar, heap, closure-in-closure, recursive closure),
  lambda-set size (1, 2, 5, erased), match shapes (guards, wildcards,
  string/list patterns with and without rests, nested nominals), argument
  evaluation-order probes (effectful `dbg` ordering).
- Cross-opt agreement assertions on that corpus (interpreter / dev /
  speed), which stand alone as regression value even under option A.

## Related projects

- [../small/lambda-mono-oracle-fidelity.md](../small/lambda-mono-oracle-fidelity.md)
  — do first: it hardens the materialized tree this project builds on.
- [../small/pin-lambda-solved-invariants.md](../small/pin-lambda-solved-invariants.md)
  — its dispatch matrix tests become early members of this project's
  corpus.
- The decision-tree match compiler has landed: match lowering now goes
  through the shared tree module (src/postcheck/match_tree.zig), so this
  harness verifies tree-shaped match bodies from the start.
