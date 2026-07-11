# Silent-Drift Guards for Mirrored Semantic Pairs

## Problem

A July 2026 duplication audit found several places where one semantic rule
was implemented twice on purpose, the copies had to agree, and nothing
checked that they did. Most of that list has since been fixed: the two
monotype digest walkers now share one strategy-parameterized body guarded
by a property test, the escape alphabet lives in one table
(`src/parse/escape.zig`) consumed by the tokenizer and both canonicalizer
interpreters, the unique-list child-decref traversal exists only in
`builtins/list.zig` (the interpreter bridges via callback), and the SWAR
caseless-equality mirror is pinned by a shared test-vector suite plus an
end-to-end LLVM-path test.

Two related items remain, both discovered or deliberately deferred during
that work:

1. **The monotype identity rules are still restated in the equality
   comparators.** `src/postcheck/monotype/type.zig`'s `writeIdentityDigest`
   now states the specialization identity rules once for both digest paths,
   but `typeViewEqlInner` / `namedTypeViewEql` / `typeEqlAcrossStoresInner`
   re-encode the same rules by hand (their comments say they "mirror the
   intentional identity rules used by typeDigest"). Deriving comparator and
   digest from one identity-field visitor was evaluated and deferred: the
   comparators are pairwise with two-sided alias unwrapping before the
   switch, short-circuiting, a visited-*pair* set (vs. the digest's single
   visiting stack), and one of them spans two id-spaces. A shared visitor
   must abstract all of that without disturbing digest bytes.

2. **The cached digest is not alias-transparent (latent, pre-existing).**
   The digest property test proved that the uncached digest treats an alias
   as identical to its backing while the cached digest wraps the backing in
   a nested `"type-digest"` sub-digest, so `typeDigestCached(alias) !=
   typeDigestCached(backing)` even though `typeEql` says they are equal.
   This is soundness-preserving — the digest→eql cache protocol can only
   *miss* deduplication for alias-containing types, never confirm a false
   match — but it contradicts the alias-transparency identity rule and
   silently costs duplicate specializations. Fixing it changes cached
   digest bytes for alias-containing types, so it needs its own change with
   snapshot-corpus verification, which is why it was not folded into the
   digest unification.

## Background

Monotype specialization identity is decided by a digest→eql protocol: hash
to find a candidate, confirm with `typeEql`. The digest side lives in
`src/postcheck/monotype/type.zig` (`writeIdentityDigest`, driven by
`UncachedDigestStrategy` and `CachedDigestStrategy`; see design.md on
specialization identity and the stored-beside-the-node cached digests).
The property test
`"monotype cached and uncached digests agree on type identity"` asserts
the two strategies induce the same equivalence relation over an enumerated
corpus including cyclic types — that test is the regression net any change
here must keep green, and it currently carves out the known alias case.

## Evidence

- The comparator functions and their "mirror the intentional identity
  rules" comments in `src/postcheck/monotype/type.zig`.
- The alias-transparency asymmetry is demonstrable directly:
  `typeDigest(alias_i64) == typeDigest(i64)` but
  `typeDigestCached(alias_i64) != typeDigestCached(i64)`, while
  `typeEql(alias_i64, i64)` is true.

## Solution design

1. **Identity-field visitor for the comparators.** Introduce one
   declarative description of "identity fields per Type variant" consumed
   by `writeIdentityDigest` and by a pairwise comparator core, so a change
   to the named-type discriminators or row rules cannot reach the digest
   without reaching equality. The comparator-specific machinery (pair
   memoization, two-store id mapping, alias pre-unwrapping) stays local;
   only the per-variant field enumeration unifies. Digest bytes must be
   proven unchanged (the unification work left an 11-type byte-identity
   check worth repeating).
2. **Alias-transparent cached digests.** Make `CachedDigestStrategy`
   digest an alias as its backing (matching the uncached path and
   `typeEql`), bump whatever cache/version accompanies changed cached
   digest bytes, and verify: the property test's alias section flips to
   asserting full agreement, specialization counts on the snapshot corpus
   do not increase (they may decrease — that is the point), and
   `git diff test/snapshots` stays empty.

## What success looks like

- The named-type discriminator list and row identity rules appear exactly
  once in `src/postcheck/monotype/type.zig`, consumed by digest and
  equality alike.
- `typeDigestCached` is alias-transparent; the property test asserts
  digest equality wherever `typeEql` holds, with no alias carve-out.

## How to evaluate the result

### Correctness ideal

The digest property test passes with its alias exception removed. Mutation
test: remove one discriminator from the shared identity description and
confirm both the digest and the comparator change together (a test
comparing two types differing only in that field flips in both). Snapshot
corpus unchanged.

### Performance ideal

Comparator performance is unchanged (the visitor monomorphizes like the
digest strategies). Alias-heavy corpora may see fewer duplicate
specializations; nothing may see more.

## Tests to add

- Property-test extension: full digest/eql agreement including aliases.
- A specialization-count regression check on an alias-heavy fixture
  (asserting the count does not increase after the cached-digest change).
- The mutation test described above, kept as documentation if not
  automated.

## Related projects

- [A Shared Cycle-Guarded Checked-Type
  Traversal](shared-checked-type-traversal.md) — same file-family; the
  visitor should compose with that utility if it lands first.
- [Single-Source Builtin
  Registration](../big/single-source-builtin-registration.md) — the
  big-scale version of "two encodings of one rule".
