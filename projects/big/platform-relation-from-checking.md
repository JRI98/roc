# Carry the Platform-App Relation from Checking

## Problem

The app↔platform correspondence — which app-provided value satisfies each
platform requirement, and at what types — is derived twice.

Checking derives it first: the app is checked against the platform's
requirement surface (`platform_requirements` on the type-check task), the
requirement types are instantiated into the app's env, unified against
the app's provided values, and any mismatch is a normal check-time
diagnostic naming the requirement and the platform region. That
correspondence — requirement → app value, with solved types — is then
discarded.

Finalization derives it second, from scratch:
`finalizeExecutableArtifactsInternal` (`src/compile/coordinator.zig:1812`)
calls `buildPlatformAppRelation`
(`src/check/checked_artifact.zig:16935`), which re-resolves each
app-provided value **by interned export name**
(`appExportedTopLevelValueByName`, `checked_artifact.zig:20767`),
re-checks type compatibility, computes identity substitutions with
`PlatformRelationSubstitutionCollector` (`checked_artifact.zig:1911`),
and republishes the platform root artifact with the substituted types.

The second derivation is the last name-keyed cross-module resolution left
in the compiler after canonicalization import-resolution, and it is a
live bug generator: PR roc-lang/roc#10000 patched a panic *inside* it
("platform relation substitution mapped one identity to incompatible
actual types" when one requirement identity binds through an app-side
alias and its backing) by adding a compensating refinement
(`refineBoundActual`, `checked_artifact.zig:2031`) — after the
check-time migration (#9911, #9945) was nominally complete. Facts proven
at check time are being re-proven at publication by name and structure;
the panics and refinements live at the consumption site.

There is also a straight performance cost: the platform root is published
twice on every cold build — once relation-less when the platform package
finishes checking, once relation-bearing at finalization.

## Background

The requires migration so far: #9911 moved requirement *diagnostics* to
check time and deleted the coordinator shadow-validator
(`PlatformRequiredValidationSnapshot` and ~20 report builders); #9945
deleted the app-side publication rewrites
(`substitutePlatformRequiredVariablesInProvidedExports` and the resolved
dispatch specialization set, −1775 lines). What remains is the
*platform-side* rewrite: the executable needs the platform's provided
exports specialized to the app's concrete types, and that substitution is
still computed at finalization from the re-derived relation.

`validatePlatformAppRelationsForCheck` (`coordinator.zig:1865`) is the
old shadow-validator's ghost, downgraded to a Debug-only assertion.

Cache correctness is currently preserved despite the double derivation:
the republished platform artifact keys on `platform_app_relation.key`
(computed from the app artifact key + requirement context, both content
hashes; see design.md "platform/app relation identity"), and
`tryLoadCachedRepublishedRoot` (`coordinator.zig:2979`) short-circuits
repeats. The problem is not purity — it is that the derivation is
duplicated, name-keyed, and enforced by panics.

## Evidence

- `src/compile/coordinator.zig:1812` `finalizeExecutableArtifactsInternal`
  → `buildPlatformAppRelation` → `republishCheckedArtifact`.
- `src/check/checked_artifact.zig:20767` `appExportedTopLevelValueByName`:
  interned-name lookup of the app value at finalization.
- `src/check/checked_artifact.zig:1911` `PlatformRelationSubstitutionCollector`,
  `:2031` `refineBoundActual` (the #10000 compensation), `:1880`
  `platformRelationSubstitutedCheckedRoot`.
- `src/compile/coordinator.zig:1865` `validatePlatformAppRelationsForCheck`
  — Debug-only re-validation of what checking already proved.
- Chain of fixes on this surface: #9762 → #9835 → #9873 (pre-migration
  cascade), #9911, #9945, #10000 (post-migration compensation).

## Solution design

Assign the relation once, at check time, and carry it.

1. **Emit the relation as a checked fact.** When the app module's check
   against `platform_requirements` succeeds, record — in the app's
   checked artifact (or a dedicated relation artifact keyed by
   `PlatformAppRelationKey`) — for each platform requirement: the
   requirement identity, the app value it resolved to (as a checked
   export id, not a name), and the solved checked types of the
   correspondence (the identity-variable bindings the substitution
   needs). This is the data check-time already has in hand at the moment
   it unifies requirement against provided value.
2. **Make finalization a reader.** `buildPlatformAppRelation` becomes:
   load the relation fact, apply the recorded substitutions to the
   platform root. DELETE `appExportedTopLevelValueByName` and the
   by-name/by-structure re-matching. `PlatformRelationSubstitutionCollector`'s
   binding refinement (`refineBoundActual`) is deleted with it — the
   alias-vs-backing case #10000 patched cannot arise when the bindings
   are recorded at solve time instead of re-collected from two
   structural walks.
3. **Publish the platform root once.** With the relation available as an
   input, the relation-bearing platform artifact can be produced directly
   when both sides are done, instead of publish-then-republish. The cache
   key stays `platform_app_relation.key`-based, unchanged.
4. **Delete the ghost.** `validatePlatformAppRelationsForCheck` goes away;
   its assertion becomes vacuous when finalization consumes rather than
   re-derives. Keep one Debug invariant at the *producer*: the relation
   recorded at check time references only exports that exist in the
   published app artifact.
5. Update design.md's platform-relation section to state the carried-fact
   contract, mirroring what the "Identity provenance follows meaning
   provenance" principle already requires.

## What success looks like

Every criterion below must hold; the project is not done until all do:

- `grep -rn "appExportedTopLevelValueByName" src/` matches nothing.
- `grep -rn "PlatformRelationSubstitutionCollector\|refineBoundActual" src/`
  matches nothing.
- `grep -rn "validatePlatformAppRelationsForCheck" src/` matches nothing.
- No code path after check completion resolves an app export by name or
  re-checks requirement/provided type compatibility; finalization's
  relation input is a deserialized checked fact.
- A cold `roc build` of a platform+app fixture publishes the platform
  root exactly once (assert via the coordinator's publication counters or
  a test hook; the double-publication path is deleted, not just skipped).
- The #10000 repro (one requirement identity bound through an app-side
  alias and its backing) passes, with the refinement code deleted.
- The full platform-requires CLI suite (the #9911/#9945-era tests: value
  requirements, for-clause aliases, nested dispatch, byte-identical
  platform modules, `allow_user_errors` skips) stays green.
- Cached and fresh builds produce byte-identical republished platform
  artifacts (existing relation-key caching tests extended to assert
  artifact-byte equality, not just key equality).

## How to evaluate the result

### Correctness ideal

One derivation. The relation is computed where it is proven (checking),
serialized with content-hash identity, and consumed everywhere else. The
#10000 class — two structural walks disagreeing about one identity — is
unrepresentable because there is only one walk, at solve time, and its
output travels. Mismatch between app and platform is only ever a
check-time diagnostic; finalization cannot discover a new one.

### Performance ideal

Finalization sheds the name lookups, the compatibility re-check, and the
substitution collection walk; the platform root is serialized once per
(platform, app) pair instead of twice. Measure cold-build wall time on
the largest platform fixture (`test/cli/issue9717-platform`) and on a
URL-package platform app; require the finalization phase to get faster or
stay within noise. Cache hit rate must be unchanged (same key function).

## Tests to add

- Producer-side unit test: checking an app against a platform surface
  records a relation whose export ids and identity bindings match the
  solved types (assert against a hand-built expected relation).
- The alias-plus-backing #10000 shape as a permanent repro.
- Single-publication assertion for a cold build (counter or hook).
- A cross-check test that a *cached* app artifact (fresh process, warm
  cache) yields the same relation bytes as a fresh check — the relation
  must be a pure function of the artifacts it relates.

## Related projects

- [../small/cache-and-identity-residuals.md](../small/cache-and-identity-residuals.md)
  — the remaining smaller name-keyed and hand-enrolled identity seams.
- [../big/unify-build-pipelines.md](../big/unify-build-pipelines.md) — the
  run path duplicates the finalization sequence that consumes this
  relation; landing this first shrinks what unification has to move.
