# Compiler Improvement Projects

This folder contains self-contained project specifications for structural
improvements to the compiler. Each `.md` file is written so that someone brand
new to the codebase (human or agent) can read that one file and understand the
problem, the solution approach, what success looks like, how to evaluate the
result for long-term correctness and performance, and what tests to add.

- `small/` — localized, mostly additive checks or deletions, low design risk;
  hours to days each.
- `big/` — projects on the order of weeks each: cross-cutting, and several
  require a design decision before implementation starts.

The projects came out of a root-cause analysis of eight weeks of bug fixes
(May–June 2026) and a July 2026 duplication audit. The recurring disease
across independent bug clusters was: facts proven during checking get
re-derived downstream from type, name, or structure content instead of
traveling as explicit data, keyed by fragile identity (name strings,
positional order, mutable keys) and enforced only by panics at the
consumption site. These projects either move a fact into an explicit
artifact, assign an identity once and carry it, or delete a duplicated
computation. `design.md` at the repo root is the authoritative post-check
design; these projects implement its stated principles more completely.

## Recommended order

### Start here

1. [small/cross-phase-coverage-parity-tests.md](small/cross-phase-coverage-parity-tests.md)
   — the divergence-classification parity suite; cheap insurance that gives
   the big lowering projects below a focused regression net.
2. [small/pin-deferred-spec-requests.md](small/pin-deferred-spec-requests.md)
   — audit the one remaining propagation hole in deferred spec requests
   (`unifyThroughBacking` never pairs named type arguments) with seal-time
   debug instrumentation.
3. [small/silent-drift-guards.md](small/silent-drift-guards.md)
   — pins the remaining intentional mirrors (type digests, escape rules,
   list decref, SWAR string equality) with shared tables or drift tests.

### Big projects

- [big/complete-dispatch-evidence-migration.md](big/complete-dispatch-evidence-migration.md)
  — finishes the in-tree migration from owner re-derivation to checked
  dispatch evidence (`evidence_missing` → 0), then deletes the derivation
  path.
- [big/arc-inserter-join-summaries.md](big/arc-inserter-join-summaries.md)
  — applies the certifier's finite-summary/dataflow discipline to production
  ARC insertion, replacing join and liveness re-walks that make generated
  structural encoders compile in minutes. Independent of everything else.
- [big/unify-build-pipelines.md](big/unify-build-pipelines.md) — one
  orchestration core behind check/run/test; the run path still hand-wires
  coordinator setup and report rendering.
- [big/single-source-builtin-registration.md](big/single-source-builtin-registration.md)
  — collapses the seven hand-typed `roc_builtins_*` symbol/ABI tables onto
  one comptime-generated registry.
- [big/decision-tree-match-compiler.md](big/decision-tree-match-compiler.md)
  — benefits from landing the coverage-parity harness first, and pairs
  naturally with pipeline unification since today every match-lowering
  change must be made twice.

### Suggested overall sequence

If one person or agent works through everything serially, this order
front-loads leverage and keeps prerequisites satisfied:

1. `small/cross-phase-coverage-parity-tests.md`
2. `small/pin-deferred-spec-requests.md`
3. `small/silent-drift-guards.md`
4. `big/complete-dispatch-evidence-migration.md`
5. `big/arc-inserter-join-summaries.md`
6. `big/unify-build-pipelines.md`
7. `big/single-source-builtin-registration.md`
8. `big/decision-tree-match-compiler.md`
