# Compiler Improvement Projects

This folder contains self-contained project specifications for structural
improvements to the compiler. Each `.md` file is written so that someone brand
new to the codebase (human or agent) can read that one file and understand the
problem, the solution approach, what success looks like, how to evaluate the
result for long-term correctness and performance, and what tests to add. Each
doc's "What success looks like" section is a completion contract: the project
is not done until every criterion listed there holds.

- `small/` — localized, mostly additive checks or deletions, low design risk;
  hours to days each.
- `big/` — projects on the order of weeks each: cross-cutting, and several
  require a design decision before implementation starts.

The projects come from a root-cause analysis of eight weeks of bug fixes
(May–June 2026), a July 2026 duplication audit, and a July 2026 differential
re-analysis of the fixes that landed since. The recurring disease across
independent bug clusters was: facts proven during checking get re-derived
downstream from type, name, or structure content instead of traveling as
explicit data, keyed by fragile identity (name strings, positional order,
mutable keys) and enforced only by panics at the consumption site. The
re-analysis added a second-order lesson: generators whose mechanism was
*deleted* stayed dead, while generators that were centralized but left a
parallel old path kept firing on uncovered axes — so each project's finishing
move is deleting the re-derivation path, not just adding the carried fact
beside it. `design.md` at the repo root is the authoritative post-check
design; these projects implement its stated principles more completely.

## Recommended order

### Start here — enforcement layers, cheap and load-bearing

1. [small/cross-phase-coverage-parity-tests.md](small/cross-phase-coverage-parity-tests.md)
   — the divergence-classification parity suite; a regression net the big
   lowering projects inherit.
2. [small/silent-drift-guards.md](small/silent-drift-guards.md)
   — pins the remaining intentional mirrors (type digests, escape rules,
   list decref, SWAR string equality) with shared tables or drift tests.
3. [small/rceffect-conformance.md](small/rceffect-conformance.md)
   — comptime validity plus a per-op refcount conformance harness for the
   central ownership table (the PR 10023 bug class).
4. [small/cache-and-identity-residuals.md](small/cache-and-identity-residuals.md)
   — closes the four small seams left after the identity/cache cures
   (name-text fallback, hand-enrolled serde contracts, split version
   hashes, `type_name` in nominal keys).

### Chain A — dispatch evidence, consumed everywhere

1. [big/complete-dispatch-evidence-migration.md](big/complete-dispatch-evidence-migration.md)
   — finishes the migration from owner re-derivation to checked dispatch
   evidence (`evidence_missing` → 0), then deletes the derivation path.
2. [small/hoist-consumes-dispatch-evidence.md](small/hoist-consumes-dispatch-evidence.md)
   — hoist selection reads the dispatch resolution instead of re-deriving
   evidence-dependence from type-var content (the PR 10073 seam), and
   recovers the hoisting its conservative gate gives up.

### Chain B — the host/platform boundary

1. [small/hosted-extern-declared-abi.md](small/hosted-extern-declared-abi.md)
   — the invariant that a hosted extern is only specialized at its declared
   type, enforced at the producer instead of by a checker rewrite.
2. [small/audit-solver-mutating-rewrites.md](small/audit-solver-mutating-rewrites.md)
   — classifies every probe-then-mutate solver rewrite as mechanism or
   declared policy (the 9834→9921→9966 lesson); depends on Chain B step 1
   to make the 9966 rewrite non-load-bearing before judging it.
3. [big/platform-relation-from-checking.md](big/platform-relation-from-checking.md)
   — the app↔platform correspondence becomes a checked fact carried to
   finalization, retiring the last name-keyed cross-module resolution and
   the double platform publication.

### Chain C — specialization sealing

1. [small/pin-deferred-spec-requests.md](small/pin-deferred-spec-requests.md)
   — seal-time instrumentation, the snapshot-regime pin, and the
   `unifyThroughBacking` decision; end state: `row_default` unreachable
   for checker-constrained rows.

### Independent — start any time, in any order

Small:
- [small/frame-partitioned-checker-state.md](small/frame-partitioned-checker-state.md)
  — inventory and convert frame-scoped checker/canonicalizer state to
  dedicated frame storage (the 9929→10010 and 10001 shape).
- [small/compact-constant-aggregates.md](small/compact-constant-aggregates.md)
  — static-data and builtin-call materialization for constant/repeated
  lists, ending the one-local-per-element explosion behind issue 9898.

Big:
- [big/arc-inserter-join-summaries.md](big/arc-inserter-join-summaries.md)
  — applies the certifier's finite-summary/dataflow discipline to
  production ARC insertion, replacing the join and liveness re-walks that
  make generated structural encoders compile in minutes.
- [big/unify-build-pipelines.md](big/unify-build-pipelines.md)
  — one orchestration core behind check/run/test; lands best after
  Chain B step 3 shrinks what finalization does.
- [big/single-source-builtin-registration.md](big/single-source-builtin-registration.md)
  — collapses the seven hand-typed `roc_builtins_*` symbol/ABI tables onto
  one comptime-generated registry.
- [big/decision-tree-match-compiler.md](big/decision-tree-match-compiler.md)
  — benefits from the coverage-parity harness landing first.

### Suggested overall sequence

If one person or agent works through everything serially, this order
front-loads leverage and keeps prerequisites satisfied:

1. `small/cross-phase-coverage-parity-tests.md`
2. `small/silent-drift-guards.md`
3. `small/rceffect-conformance.md`
4. `small/cache-and-identity-residuals.md`
5. `small/pin-deferred-spec-requests.md`
6. `big/complete-dispatch-evidence-migration.md`
7. `small/hoist-consumes-dispatch-evidence.md`
8. `small/hosted-extern-declared-abi.md`
9. `small/audit-solver-mutating-rewrites.md`
10. `big/platform-relation-from-checking.md`
11. `small/frame-partitioned-checker-state.md`
12. `small/compact-constant-aggregates.md`
13. `big/arc-inserter-join-summaries.md`
14. `big/unify-build-pipelines.md`
15. `big/single-source-builtin-registration.md`
16. `big/decision-tree-match-compiler.md`
