# Compiler Improvement Projects

This folder contains self-contained project specifications for structural
improvements to the compiler. Each `.md` file is written so that someone brand
new to the codebase (human or agent) can read that one file and understand the
problem, the solution approach, what success looks like, how to evaluate the
result for long-term correctness and performance, and what tests to add.

- `small/` — projects on the order of days each: localized, mostly additive
  checks or deletions, low design risk.
- `big/` — projects on the order of weeks each: cross-cutting, and several
  require a design decision before implementation starts.

The projects came out of a root-cause analysis of eight weeks of bug fixes
(May–June 2026). The recurring disease across independent bug clusters was:
facts proven during checking get re-derived downstream from type, name, or
structure content instead of traveling as explicit data, keyed by fragile
identity (name strings, positional order, mutable keys) and enforced only by
panics at the consumption site. Most of these projects either move a fact into
an explicit artifact, assign an identity once and carry it, or delete a
duplicated computation. `design.md` at the repo root is the authoritative
post-check design; these projects implement its stated principles more
completely.

A second batch of projects came out of the 2026-07 comparative review of
the post-check pipeline against the cor `lss` prototype it was
productionized from (stage-by-stage divergence review; no shipped
miscompile found, but several unstated load-bearing invariants, one
termination hazard, and one verification coverage gap):

- [small/spec-constr-specialization-limits.md](small/spec-constr-specialization-limits.md)
  — termination budgets for call-pattern specialization (compile-time
  divergence is reachable today).
- [small/empty-tag-union-yield-provenance.md](small/empty-tag-union-yield-provenance.md)
  — key Lambda Solved's one unification escape hatch on carried provenance
  instead of shape.
- [small/pin-lambda-solved-invariants.md](small/pin-lambda-solved-invariants.md)
  — state, assert, and test the four invariants that make monomorphic
  lambda-set solving sound.
- [small/lambda-mono-oracle-fidelity.md](small/lambda-mono-oracle-fidelity.md)
  — agreement asserts and contract pins for the Debug Lambda Mono oracle;
  delete its dead Queue.
- [small/monotype-machinery-hardening.md](small/monotype-machinery-hardening.md)
  — release-gate verification-only type checks; measure-first fixes for
  digest depth fallback, unify memo, spec duplication, cross-store reuse.
- [small/lift-capture-single-sourcing.md](small/lift-capture-single-sourcing.md)
  — one capture-fixpoint driver, the `if_initialized_payload` binder
  question, and the capture-id override path.
- [big/solved-lir-body-verification.md](big/solved-lir-body-verification.md)
  — a body-level oracle for the fused solved-to-LIR path (decision
  verification exists; statement bodies are unverified).

Within this batch: land `lambda-mono-oracle-fidelity` before
`solved-lir-body-verification`; the rest are independent.
`spec-constr-specialization-limits` pairs naturally with
`spec-constr-static-match-soundness`.

## Recommended order

### Start here

1. [small/cross-phase-coverage-parity-tests.md](small/cross-phase-coverage-parity-tests.md)
   — cheap insurance before larger migrations: it pins producer/consumer
   predicate parity so later refactors have a focused regression net.

### Dependency chains

**Chain A — dispatch:**
1. [big/generalization-time-ambiguity.md](big/generalization-time-ambiguity.md)
   — builds on the landed total static-dispatch plan work and replaces the
   remaining ambiguity sweep with a generalization-time rule.
2. [big/complete-dispatch-evidence-migration.md](big/complete-dispatch-evidence-migration.md)
   — finishes the in-tree migration from owner re-derivation to checked
   dispatch evidence (`evidence_missing` → 0), then deletes the derivation
   path.

**Chain B — ARC:**
1. [big/arc-inserter-join-summaries.md](big/arc-inserter-join-summaries.md)
   — applies the certifier's landed finite-summary/dataflow discipline to
   production ARC insertion, replacing join and liveness re-walks that make
   generated structural encoders compile in minutes.

**Chain C — numerics:**
1. [big/exact-numeral-pipeline.md](big/exact-numeral-pipeline.md)
- [small/checked-arithmetic-lir-ops.md](small/checked-arithmetic-lir-ops.md)
  is independent of both and can land any time.

### Independent — start any time, in any order

Small:
- [small/cross-phase-coverage-parity-tests.md](small/cross-phase-coverage-parity-tests.md)
  — cheap insurance; ideally land early so later projects inherit the harness.
- [small/centralize-slice-reuse-predicate.md](small/centralize-slice-reuse-predicate.md)
- [small/store-generation-counters.md](small/store-generation-counters.md)
- [small/checked-arithmetic-lir-ops.md](small/checked-arithmetic-lir-ops.md)
- [small/shared-checked-type-traversal.md](small/shared-checked-type-traversal.md)
- [small/glue-consumes-committed-layouts.md](small/glue-consumes-committed-layouts.md)
- [small/structural-hoist-contexts.md](small/structural-hoist-contexts.md)
- [small/silent-drift-guards.md](small/silent-drift-guards.md)
  — pins the remaining intentional mirrors (type digests, escape rules,
  list decref, SWAR string equality) with shared tables or drift tests.

Big:
- [big/decision-tree-match-compiler.md](big/decision-tree-match-compiler.md)
  — independent; benefits from landing the coverage-parity test harness first,
  and pairs naturally with pipeline unification (below) since today every
  match-lowering change must be made twice.
- [big/unify-build-pipelines.md](big/unify-build-pipelines.md) — independent;
  package identity is already centralized, but the run path still hand-wires
  coordinator setup and report rendering.
- [big/single-source-builtin-registration.md](big/single-source-builtin-registration.md)
  — independent; collapses the seven hand-typed `roc_builtins_*`
  symbol/ABI tables onto one comptime-generated registry.

### Suggested overall sequence

If one person or agent works through everything serially, this order front-loads
leverage and keeps prerequisites satisfied:

1. `small/cross-phase-coverage-parity-tests.md`
2. `small/centralize-slice-reuse-predicate.md`
3. `small/store-generation-counters.md`
4. `small/checked-arithmetic-lir-ops.md`
5. `small/shared-checked-type-traversal.md`
6. `big/arc-inserter-join-summaries.md`
7. `big/exact-numeral-pipeline.md`
8. `big/generalization-time-ambiguity.md`
9. `big/complete-dispatch-evidence-migration.md`
10. `big/unify-build-pipelines.md`
11. `big/decision-tree-match-compiler.md`
12. `big/single-source-builtin-registration.md`
13. `small/silent-drift-guards.md`
14. `small/glue-consumes-committed-layouts.md`
15. `small/structural-hoist-contexts.md`
