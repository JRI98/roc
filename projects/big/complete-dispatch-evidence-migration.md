# Complete the Checked Dispatch Evidence Migration

## Problem

The compiler decides "which concrete method does this static dispatch call
resolve to?" in two independent places. Checking resolves each dispatch and
records the answer as *checked evidence* in the module's checked artifact.
Monotype lowering is supposed to consume only that evidence — but it still
carries a second, parallel mechanism that re-derives the target from type
structure at monomorphization time: find the method owner from the receiver
type (`methodOwnerFromType`), then look the method up in a registry
(`lookupMethodTarget` / `lookupMethodTargetByName`).

The code is explicitly mid-migration between the two. In
`src/postcheck/monotype/specialize.zig`, the stats struct carries
`evidence_missing: u64` with a comment that reads: "Total-dispatch migration
audit: requirements still resolved by owner derivation instead of checked
evidence. Must reach zero before the derivation path is deleted."
`src/postcheck/monotype/lower.zig` has the matching
`evidence_missing_count`, and doc comments stating that lowering "falls back
to owner derivation until the migration completes."

Until the migration completes, every dispatch-shaped bug has two places to
hide, and the two deciders are kept honest only by debug-build invariants
that compare their answers ("dispatch evidence target disagreed with the
owner-derivation target"). In release builds nothing compares them: wherever
evidence is missing, the owner-derivation answer silently wins, and wherever
evidence exists but the derivation would have disagreed, nobody notices.

This is the single largest remaining instance of the systemic disease the
May–June 2026 bug analysis identified: facts proven during checking being
re-derived post-check from type/name/structure content. The
"checked method registry is missing resolved dispatch target" panic family
(PRs roc-lang/roc#9858, #9892, #9875, #9864) came from exactly this
re-derivation.

## Background

The pipeline: parse → canonicalize → type-check (producing checked artifacts
per module) → postcheck Monotype IR (monomorphization/specialization in
`src/postcheck/monotype/`) → later postcheck stages → LIR → backends.
`design.md` at the repo root is authoritative, and `AGENTS.md` states the
governing rule directly: every stage other than parsing and error reporting
"must consume explicit data produced by earlier stages rather than trying to
recover, guess, reconstruct, approximate, or 'best effort' its way to
missing information."

Checked dispatch evidence is produced during checking (the evidence pass in
`src/check/checked_artifact.zig`) and consumed in
`src/postcheck/monotype/lower.zig` via `evidenceResolution` /
`dispatchTarget`. The parallel derivation lives in the same file:
`methodOwnerFromType` (map a monotype to its method-owning nominal),
`lookupMethodTarget` / `lookupMethodTargetByName` (text-keyed registry
lookup), and `synthesizeComponentEvidence` (manufacture evidence-shaped
answers for structural components where no checked record exists).

## Evidence

- `src/postcheck/monotype/specialize.zig` — `evidence_missing` counter and
  its "must reach zero before the derivation path is deleted" comment.
- `src/postcheck/monotype/lower.zig` — `evidence_missing_count`, its
  increment site, and the migration doc comments ("it falls back to owner
  derivation until the migration completes"; "migration gaps still covered
  by owner derivation").
- `methodOwnerFromType` has roughly a dozen call sites spread through
  `lower.zig` (dispatch lowering, iterator dispatch, parser-format
  synthesis, reachability queries) — each one is a place monotype lowering
  consults type structure instead of checked data.
- Debug-only cross-checks that exist purely because two deciders coexist:
  `Common.invariant("dispatch evidence target disagreed with the
  owner-derivation target")`, `"dispatch evidence chose structural but owner
  derivation found a target"`, and the iterator-dispatch variant. These are
  the tripwires this project will render unnecessary.
- History of the bug class: PRs roc-lang/roc#9858, #9892, #9875, #9864
  (late owner re-derivation panics), and PR #10073 / issue #10062
  (evidence-dependent dispatch hoisting) show the seam is still active.

## Solution design

Make checked evidence the *only* source of dispatch targets, then delete the
derivation path.

1. **Break down the gap.** The `evidence_missing` counter says how often
   owner derivation still decides, but the fix requires knowing *why*. Tag
   each increment with the requirement kind (user dispatch, structural
   derivation component, builtin helper edge, iterator protocol,
   parser/encoder synthesis) and dump the breakdown under a debug flag.
   Run the full test corpus + snapshot suite and enumerate the gap classes.
2. **Close each gap at the producer.** For every class, extend the checking
   evidence pass to emit an explicit record where today lowering
   re-derives. The known-suspect classes, from the migration comments and
   call sites: compiler-generated structural derivations
   (`synthesizeComponentEvidence`'s clientele), builtin-helper edges, the
   iterator dispatch path, and the parser-format synthesis path. Each fix
   is "check proves it, check writes it down" — never "lowering finds it
   again."
3. **Make dispatch plans total in the checked artifact.** Every dispatch
   requirement resolves to exactly one of: direct target, structural kind,
   or where-clause constraint index. A requirement with none of these is a
   checking bug and must fail at the check/postcheck boundary — not surface
   as a lowering panic.
4. **Delete the derivation path.** When `evidence_missing` is zero across
   the full corpus: delete `methodOwnerFromType`, `lookupMethodTarget` /
   `lookupMethodTargetByName`, the owner-derivation branch of
   `synthesizeComponentEvidence`, and all `debugCompare`-style audits that
   exist only to compare the two deciders. The reachability-style queries
   that use `methodOwnerFromType` for non-dispatch purposes must be
   inventoried during step 1 and either given their own checked data or
   shown to be derivable without deciding dispatch.
5. **Enforce at the boundary.** Replace the counter with a boundary
   validator: after evidence loading, assert every dispatch requirement in
   the module has a plan, and report a compiler bug otherwise. Missing
   evidence becomes loud and early instead of silently re-derived.

## What success looks like

- `grep -rn "methodOwnerFromType" src/postcheck` matches nothing.
- `evidence_missing` / `evidence_missing_count` and the disagreement
  invariants are gone — there is nothing left to disagree.
- Monotype lowering resolves every dispatch by lookup into checked data;
  no code path in postcheck maps a type to a method owner.
- The "checked method registry is missing resolved dispatch target" panic
  class is unrepresentable: a missing plan fails the boundary validator
  with a check-side diagnostic, not a lowering panic.

## How to evaluate the result

### Correctness ideal

During the migration, the debug disagreement invariants act as the harness:
every intermediate state must keep them silent across the full test corpus,
snapshot suite, and fuzz runs. After deletion, mutation-test the boundary:
remove one evidence record from a checked artifact in a test and confirm the
boundary validator reports a compiler bug rather than lowering picking a
target. LIR output on the full snapshot corpus is byte-identical before and
after the deletion commit (the deletion changes who decides, not what is
decided).

### Performance ideal

Dispatch resolution in lowering becomes a table lookup instead of a type
walk plus registry probe. Monotype lowering time on the largest test
platforms should be neutral or better; the deleted debug audits also stop
re-deriving every target a second time in debug builds, which should
measurably speed up debug-mode snapshot runs.

## Tests to add

- Regression tests from the historical panic family stay green (the suites
  added in PRs roc-lang/roc#9858, #9892, #9875, #9864, #10073).
- A debug-build assertion (or test-mode check) that `evidence_missing` is
  zero over the whole snapshot corpus — added *before* the deletion, so the
  corpus itself proves the migration is complete.
- Boundary-validator test: a hand-corrupted checked artifact with one
  dispatch plan removed produces a compiler-bug diagnostic naming the
  requirement, not a panic in lowering.
- One test per closed gap class (structural component, builtin helper,
  iterator, parser-format), each asserting the dispatch lowers via evidence
  (e.g. by keeping the class's tagged counter at zero).

## Related projects

- [Replace the Dispatch Ambiguity Sweep with a Generalization-Time
  Rule](generalization-time-ambiguity.md) — the sibling dispatch project:
  that one moves the *ambiguity* decision to check time; this one makes the
  *target* decision travel from check time. Both shrink what monotype
  lowering is allowed to figure out on its own.
- [Cross-Phase Coverage Parity
  Tests](../small/cross-phase-coverage-parity-tests.md) — the parity-test
  harness is the natural home for the "evidence is total" corpus check.
