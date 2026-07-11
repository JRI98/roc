# Audit Solver-Mutating Rewrites for Encoded Policy

## Problem

A recurring idiom in the checker: run a bespoke structural probe over
solved types, and if it "proves" a condition, mutate the solved graph or
the CIR so a unification that would have failed now succeeds (or a
different plan gets published). The idiom is dangerous for a specific
reason demonstrated twice in July 2026: **a probe-then-mutate rewrite is
indistinguishable at review time from a change to the language's typing
rules.** It passes its own repro, nothing in the type system flags that
subsumption or dispatch policy changed, and the consequences surface as
downstream panics or user reports.

The two demonstrations:

- PR roc-lang/roc#9834 shipped as a bugfix: a row-inclusion probe
  (`actualTagRowIsIncludedInExpected`) followed by
  `dangerousSetVarRedirect`, silently changing `?`'s subsumption rule
  (closed error rows widened into open annotated rows). Users built on
  the relaxation; PR #9921 later reverted it as a language-design
  mistake, and issue #9798's program is a type error by design.
- PR #9998 (seam 1, issue #9971): `rewriteEqBinopAsMethodEq`
  (`src/check/Check.zig:16226`) restamped a CIR node's
  `constraint_fn_var` on every nominal discharge, silently pinning the
  published equality plan to one instantiation's concrete type; the
  second specialization died in monotype lowering. The fix added a
  same-constraint guard and a publication-time debug assert.

And the idiom regrows: two days after #9921's revert, PR #9966
re-introduced a `widenTryConditionForExpectedReturn` probe-then-redirect
(`Check.zig:14675`, redirect at `:14699`) to protect the hosted-function
ABI — same mechanism, new justification, no framework for judging it.

## Background

The mutation primitive is `Store.dangerousSetVarRedirect`
(`src/types/store.zig:558`). Its name is the only guardrail. Current
callers in `src/check/Check.zig`:

- `:14699` — inside `widenTryConditionForExpectedReturn` (PR #9966): after
  `tryErrorRowNeedsUseSiteWidening`/`probeCanUseAs` proves the callee's
  visible errors are included, redirects the `?` condition's root to a
  freshly built widened `Try`. This encodes a subsumption-like policy
  (when a hosted closed row may appear where a wider row is expected) as
  an unreviewable mechanism.
- `:22588` — inside error poisoning: an erroneous value expr's var is
  redirected to a fresh var unified with the expected return, so
  checking can continue past a reported error. This is mechanism
  (diagnostic recovery), not policy — the expression is already
  erroneous and reported.

CIR-side, the same idiom appears as post-solve restamping of recorded
constraint metadata (`rewriteEqBinopAsMethodEq`, now guarded).
Adjacent — and to be classified, not assumed guilty — are the read-only
acceptance probes that feed dispatch decisions:
`staticDispatchConstraintAcceptsCandidate` (`Check.zig:18054`) and
`numeralCandidateStructurallyRefuted` (`Check.zig:17923`). Probes that
only *read* are fine as mechanism; the audit's question for them is
whether the acceptance rule they implement is written down anywhere as
the intended language rule.

## Evidence

- History: #9834 (probe+redirect lands as "bugfix") → #9921 (reverted as
  language mistake; regression test inverted to assert failure) →
  #9966 (same shape re-lands for the ABI two days later).
- `src/types/store.zig:558` `dangerousSetVarRedirect` — no invariant
  comment stating when a redirect is legitimate.
- `src/check/Check.zig:16226` `rewriteEqBinopAsMethodEq` — the restamp
  that corrupted published plans until #9998 guarded it; the guard is a
  consumption-site debug assert, not a rule about who may restamp.

## Solution design

This is an audit-and-codify project, not a rewrite project.

1. **Enumerate.** Every caller of `dangerousSetVarRedirect`, every
   post-solve mutation of recorded constraint/plan metadata on CIR
   nodes, and every structural probe whose result gates such a mutation.
   The list above is the starting set; the enumeration must be exhaustive
   (grep + review of `Check.zig`'s "rewrite"/"restamp"/"redirect"
   families).
2. **Classify each as mechanism or policy.** Mechanism: the rewrite
   cannot change which programs typecheck or which plans are published
   for error-free programs (e.g. the `:22588` poisoning recovery).
   Policy: the rewrite makes a program typecheck that pure unification
   would reject, or changes a published plan (e.g. `:14699`).
3. **For each policy case**, either: (a) promote the rule to a declared
   one — state it in design.md's type-system section, name the probe
   after the rule, and pin it with tests asserting both the accepted and
   the rejected side; or (b) replace it with a structural fix that makes
   the rewrite unnecessary (for #9966 that is the hosted-extern boundary
   guarantee — see the related project). "It makes a test pass" is not a
   sufficient justification for any surviving member.
4. **Codify the primitive.** `dangerousSetVarRedirect` gets a doc
   contract: legitimate uses are (i) diagnostic recovery on already-
   reported errors, and (ii) rules declared in design.md, cited by the
   call site. Add a Debug assertion hook or naming convention such that
   a new caller without a declared-rule citation is caught in review
   (e.g. the function requires a `comptime reason: DeclaredRule` enum
   parameter — adding a caller forces adding an enum member, which is
   greppable and reviewable).
5. Same treatment for post-solve CIR restamps: the #9998 guard becomes a
   stated rule ("only the node's own constraint may restamp it"),
   asserted at the restamp site, not only at publication.

## What success looks like

Every criterion below must hold; the project is not done until all do:

- A written inventory (in the PR description or a design.md appendix) of
  every solver-mutating rewrite, each classified mechanism/policy with
  its justification.
- `dangerousSetVarRedirect` requires a declared reason at the call site
  (enforced by signature, not convention); every existing caller
  compiles only after citing its rule.
- The #9966 widening either cites a design.md-declared rule with
  both-sides tests, or is deleted in favor of the structural ABI
  guarantee — no third state.
- `rewriteEqBinopAsMethodEq`'s restamp rule is asserted at the restamp
  site; the #9971 repro stays green.
- Issue #9798's program still fails to typecheck (no re-relaxation
  sneaks in through the audit).
- The acceptance probes (`staticDispatchConstraintAcceptsCandidate`,
  `numeralCandidateStructurallyRefuted`) have their rules documented in
  design.md or code-level doc comments stating the intended language
  rule they implement, with a test per rule branch.
- A CONTRIBUTING/AGENTS note: new probe-then-mutate rewrites require a
  declared rule — review checklist item, so the #9834 shape cannot land
  as a routine bugfix again.

## How to evaluate the result

### Correctness ideal

Every way the checker bends pure unification is a named, tested,
documented rule. A reviewer seeing a new `dangerousSetVarRedirect` caller
sees which rule it claims and where that rule is declared; a rewrite
without a rule does not compile.

### Performance ideal

None — this project adds no runtime work (a comptime parameter and doc
structure). Any policy case replaced by a structural fix (option 3b) is
evaluated under that project's own performance criteria.

## Tests to add

- Both-sides tests for every surviving policy rule (accepted program and
  rejected program per rule).
- A compile-failure test demonstrating that an unreasoned
  `dangerousSetVarRedirect` call does not build.

## Related projects

- [../small/hosted-extern-declared-abi.md](../small/hosted-extern-declared-abi.md)
  — the structural fix that makes the #9966 rewrite non-load-bearing.
- [../big/complete-dispatch-evidence-migration.md](../big/complete-dispatch-evidence-migration.md)
  — deletes the biggest consumer of re-derived dispatch facts; fewer
  places for restamps to corrupt.
