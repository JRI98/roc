# Silent-Drift Guards for Mirrored Semantic Pairs

## Problem

A July 2026 duplication audit found several places where one semantic rule
is implemented twice on purpose (performance, layering, or interpreter-vs-
compiled-code splits), the two copies must agree exactly, and **nothing
checks that they do**. Unlike the big consolidation projects, the fix here
is not necessarily to merge the implementations — some of these pairs have
legitimate reasons to exist — it is to make every remaining pair either
share its decision table or be pinned by a test that fails on drift.

The four pairs, in priority order:

1. **Monotype type digest, computed twice.**
   `src/postcheck/monotype/type.zig` contains two near-line-for-line copies
   of the same hashing algorithm over the same `Type` union:
   `writeCachedTypeDigest` (used by `typeDigestCached` /
   `specializationDigestCached`) and `writeTypeDigest` (used by
   `typeDigest` / `specializationDigest`). They differ only in
   cycle-tracking mechanism, must produce byte-identical digests — the
   cached one is an optimization of the other — and no test compares them.
   The same identity rules (alias transparency; named types compare by
   module bytes / def module / source decl / kind / builtin owner / args;
   rows by label text + ordered children) are additionally re-encoded by
   hand in `typeViewEqlInner` / `namedTypeViewEql` and
   `typeEqlAcrossStoresInner`, and a fourth time for the sibling IR in
   `src/postcheck/lambda_mono/type.zig`'s `writeTypeDigest`. Drift is
   completely silent and the blast radius is specialization-cache
   correctness: structurally equal types hashing differently (duplicate
   specializations, missed reuse) or the digest→eql cache protocol
   confirming a false match.

2. **String-escape rules in three switches with opposite failure modes.**
   The escape alphabet (`\n \r \t \\ \" \' \$ \u(...)`) is encoded in
   `src/parse/tokenize.zig` (`chompEscapeSequence`, the validation
   allowlist), `src/canonicalize/Can.zig` `parseSingleQuoteCodepoint`
   (interpretation for char literals, terminal `else => unreachable`), and
   `Can.zig` `processEscapeSequences` (interpretation for string literals,
   terminal else keeps the backslash as-is). The three agree today. If the
   tokenizer's allowlist gains an escape the interpreters don't know, the
   char-literal path panics and the string path silently emits wrong bytes
   — a panic and a data corruption, respectively, from the same one-line
   drift.

3. **Interpreter re-implements RocList child-decref traversal.**
   `src/eval/interpreter.zig`'s `decrefListElements` (serving the
   `list_decref` / `list_free` low-levels) re-implements the "when a unique
   refcounted list dies, walk and decref its refcounted children first"
   policy that also lives in the compiled `RocList` decref path in
   `src/builtins/list.zig`. The interpreter shares the leaf primitive
   (`builtins.utils.decref`) but hand-copies the traversal policy; its own
   comments say it "mirrors the element cleanup logic in RocList.decref". A
   divergence leaks or double-frees list elements in interpreted runs only.

4. **SWAR caseless-ASCII equality emitted twice.**
   `src/backend/llvm/MonoLlvmCodeGen.zig`'s
   `emitSwarCaselessAsciiEqualMasked` re-emits, as LLVM IR, the word-at-a-
   time caseless-equality bit-twiddle implemented in
   `src/builtins/str.zig`'s `wordCaselessAsciiEqualMasked`. The
   duplication is deliberate (inline mask ops instead of a helper call),
   but only the backend's comment points at the builtin — nothing runs the
   two against shared inputs.

## Background

The pipeline stages and stores involved: monotype specialization keys
(`typeDigest*` feed the specialization cache — see `design.md` on
specialization identity); surface-syntax escapes flow tokenizer →
canonicalizer (`Can.zig` interprets the bytes the tokenizer validated);
ARC and refcounting policy is owned by earlier stages, with executors
"dumbly following" emitted RC statements per `AGENTS.md` — which is why an
interpreter-private child-decref walk is a policy copy, not just plumbing.

## Evidence

- No test in `src/postcheck` compares `typeDigest` with `typeDigestCached`
  (verified by search). The identity coupling is acknowledged in-source:
  a comment near the equality helpers says the rules "mirror the
  intentional identity rules used by `typeDigest`".
- `Can.zig`'s two escape switches carry different terminal arms
  (`unreachable` vs. keep-backslash), so the drift consequences are
  provably different per literal form.
- `decrefListElements`' doc comments state the mirroring explicitly.
- `emitSwarCaselessAsciiEqualMasked`'s doc comment names the builtin it
  mirrors; there is no reverse reference and no shared test vector file.

## Solution design

Per pair, in the same order:

1. **Digests:** collapse `writeCachedTypeDigest` / `writeTypeDigest` into
   one traversal parameterized over the cycle-tracking strategy (comptime
   strategy parameter or a small context interface), so there is one body.
   Then derive digest AND equality from one declarative "identity fields
   per Type variant" visitor, so `typeViewEqlInner` / `namedTypeViewEql` /
   `typeEqlAcrossStoresInner` and the digest walker cannot disagree about
   which fields participate in identity. Land a property test comparing
   cached vs. uncached digests over randomly built (including cyclic)
   type graphs FIRST, before any refactoring, so the consolidation itself
   is protected. The lambda_mono digest gets the same treatment against
   its own store.
2. **Escapes:** one table (suggested home: `src/parse/` next to the
   tokenizer, since parse is upstream of canonicalize) mapping escape byte
   → interpretation, plus the `\u(...)` helper. The tokenizer's allowlist
   is "the table's domain"; both `Can.zig` interpreters call the table.
   Adding an escape becomes a one-row change, and an unknown escape can no
   longer mean two different things.
3. **List decref:** extract the child-traversal policy from
   `builtins/list.zig` into a helper the interpreter can call with its own
   element-decref callback (the interpreter needs per-element layout
   knowledge the builtin gets from `element_refcounted`/callbacks anyway —
   the existing `RocList.decref` callback shape likely already fits).
   Delete `decrefListElements`' hand-copied walk.
4. **SWAR:** add a shared test-vector suite (word-sized byte patterns:
   equal, case-differing letters, case-bit-differing non-letters, high-bit
   bytes, partial-word masks) driven against BOTH
   `builtins.str.wordCaselessAsciiEqualMasked` and a JIT-executed build of
   the LLVM-emitted routine. Add the missing cross-reference comment on
   the builtin side. Do not merge the implementations — the inline-IR
   choice is legitimate; the test makes it safe.

## What success looks like

- One digest body, one identity-field definition; the equality helpers and
  digest walker share it structurally.
- `grep -n "case 'n'"`-style escape knowledge appears once; the tokenizer,
  char-literal, and string-literal paths all consume the same table.
- `decrefListElements`' traversal exists only in `builtins/list.zig`.
- Every remaining intentional mirror (SWAR) is pinned by a shared-vector
  test that fails on either side drifting.

## How to evaluate the result

### Correctness ideal

The digest property test (cached == uncached over generated cyclic type
graphs) runs in CI and passes before and after the consolidation; snapshot
corpus specialization behavior is unchanged (same specialization counts on
the largest test platforms — drift there means identity rules changed).
Escape handling produces byte-identical strings/chars for the full escape
alphabet in both literal forms, including the malformed cases (asserted via
snapshot tests). Interpreted vs. compiled runs of list-heavy programs show
identical refcount behavior under the existing leak-checking test
allocators.

### Performance ideal

Digest unification must not slow the cached path — the strategy
parameterization compiles to the same code (verify no regression in
monotype lowering time on the biggest corpus). The escape table is a
comptime-known switch, identical codegen. List decref via the shared helper
adds at most one indirect call per list death in the interpreter, which is
noise there.

## Tests to add

- Digest property test: random + hand-built cyclic type stores, assert
  `typeDigest(t) == typeDigestCached(t)` for every root; assert equal
  types have equal digests and (statistically) unequal types differ.
- Escape-table exhaustiveness: for every byte in the table's domain,
  tokenizer accepts exactly the escapes the interpreters interpret, in
  both string and char forms; one snapshot each for the malformed arms.
- Interpreter/compiled refcount parity: a program that allocates, shares,
  and drops nested lists of strings, run through the interpreter and dev
  backend under the leak-checking allocator.
- SWAR shared-vector suite as described, wired to run the LLVM path under
  the existing JIT test harness.

## Related projects

- [A Shared Cycle-Guarded Checked-Type
  Traversal](shared-checked-type-traversal.md) — same file-family as the
  digest work; the digest walker should be expressible with that utility's
  digest variant if it lands first.
- [Single-Source Builtin
  Registration](../big/single-source-builtin-registration.md) — the
  big-scale version of "two encodings of one ABI/rule".
