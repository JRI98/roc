# Single-Source Builtin Registration

## Problem

Adding one Zig-backed builtin to the compiler currently means editing about
eleven places by hand: `src/build/roc/Builtin.roc` (type signature),
`src/base/LowLevel.zig` (op enum), `src/canonicalize/BuiltinLowLevel.zig`
(name→op map), the interpreter dispatch in `src/eval/interpreter.zig`, the
dev backend (`BuiltinFn` + `symbolName` in `src/backend/dev/LirCodeGen.zig`),
the LLVM backend (dispatch plus an inline symbol-string literal in
`src/backend/llvm/MonoLlvmCodeGen.zig`), the wasm backend
(`BuiltinKind` + an ABI row in `src/backend/wasm/builtin_signatures.zig`),
the wrapper in `src/builtins/dev_wrappers.zig`, the `@export` lists in
`src/builtins/static_lib.zig` and `static_lib_core.zig`, the JIT
symbol→address table in `src/backend/dev/object_reader.zig`, and the
implementation itself.

The worst part is not the count — it is that the `roc_builtins_*` linker
symbol names and the per-builtin ABI facts are hand-retyped in seven-plus
independent string tables that nothing cross-checks. Their memberships
already differ (roughly 187 / 145 / 138 / 104 / 101 / 83 / 81 names across
the tables, because each backend supports a different subset), and a
mismatch between the name a backend emits and the name the runtime resolves
is not a compile error — it surfaces late, as an unresolved-symbol link
failure, a JIT "symbol not found" at run time, or a wasm validation error.
A wrong hand-written ABI row is worse: silent stack corruption.

## Background

The healthy core to build on: `src/base/LowLevel.zig` is an explicit,
documented single source of truth for the primitive-op vocabulary — a
432-member `enum(u16)` shared by canonicalize and every executor. Because
Zig `switch` over it is exhaustive, forgetting to handle a new op in a
backend is a compile error. `src/build/roc/Builtin.roc` is likewise the
single source for builtin *type signatures* (checking reads them via normal
canonicalization; there is no second signature table). And
`src/canonicalize/BuiltinLowLevel.zig`'s name→op map is enforced at
builtin-load time in the reverse direction
(`replaceProvidedByCompilerLowLevels` errors on any unmapped
annotation-only def).

What was never unified is everything downstream of the op: the linker
symbol scheme and the call ABI. The hand-maintained tables:

- `src/builtins/dev_wrappers.zig` — the `extern`-style wrapper functions,
  one per symbol. These wrappers ARE the real ABI: their Zig parameter
  types define exactly what crosses the call boundary.
- `src/builtins/static_lib.zig` and `static_lib_core.zig` — `@export`
  lists mapping wrapper functions to `"roc_builtins_*"` names.
- `src/backend/dev/object_reader.zig` — the JIT symbol→address table.
- `src/backend/dev/LirCodeGen.zig` — `BuiltinFn` enum plus a
  `symbolName()` switch mapping each member to its string.
- `src/backend/wasm/builtin_signatures.zig` — `BuiltinKind` enum plus the
  `sigs` table, which hand-writes each builtin's wasm-level ABI
  (`wasm_params`/`wasm_results` `ValType` lists — i128 as two i64s,
  pointers as i32, sret pointers, a trailing `roc_ops` i32 — plus a
  separate `takes_roc_ops` flag), all of which must byte-for-byte match
  the wrapper's actual lowering.
- `src/backend/llvm/MonoLlvmCodeGen.zig` — inline `"roc_builtins_*"`
  string literals at each call-emission site.
- `src/llvm_compile/compile.zig` and `src/cli/builder.zig` — symbol
  allowlists / prefix checks.

## Evidence

- Table membership counts differ per file (grep `roc_builtins_` in each);
  no test or comptime check compares any two tables.
- `BuiltinFn.symbolName()` (dev), the `sigs` `.name` strings (wasm), and
  MonoLlvmCodeGen's inline literals each independently spell the same
  symbol-name scheme.
- The `LowLevel → BuiltinFn` / `LowLevel → BuiltinKind` mappings are
  hand-written switches per backend; a `LowLevel` op that should lower to a
  builtin call but is missing from a backend's switch fails at run time
  (unhandled case), not compile time — the exhaustiveness guarantee of
  `LowLevel` does not extend across the enum boundary.
- The interpreter avoids the whole problem by calling the Zig functions
  directly — evidence that the symbol/ABI tables are pure backend
  plumbing, derivable from the wrappers.

## Solution design

One canonical registry, everything else generated at comptime.

1. **Pick the canonical enum.** Promote `BuiltinFn` out of the dev backend
   into `src/builtins/` (it describes builtins, not dev codegen) — or
   create a leaf `builtin_registry.zig` there. Each member carries exactly
   one `symbolName()` and a reference to its wrapper function
   (comptime-resolvable, e.g. via a `wrapperFor(comptime fn) fn` table in
   `dev_wrappers.zig`).
2. **Generate the export lists.** Replace the hand-written `@export`
   blocks in `static_lib.zig` / `static_lib_core.zig` with a comptime loop
   over `std.enums.values(BuiltinFn)` (with a member predicate for the
   core subset). A builtin present in the enum but missing a wrapper is a
   compile error.
3. **Generate the JIT table.** `object_reader.zig`'s symbol→address table
   becomes the same comptime loop emitting `.{ name, &wrapper }` pairs.
4. **Derive the wasm ABI by reflection.** The wrapper function types are
   the ABI. Compute each `sigs` row's `wasm_params` / `wasm_results` /
   `takes_roc_ops` from `@typeInfo` of the wrapper (i128 → two i64s,
   pointer → i32, `*RocOps` → trailing i32, sret by return-type size),
   instead of hand-writing `ValType` lists. If full derivation is too
   deep a cut for one step, the interim is a comptime assertion per row
   that re-derives the row from the wrapper type and errors on mismatch —
   drift becomes a compile error either way.
5. **Kill the inline literals.** `MonoLlvmCodeGen` call sites use
   `BuiltinFn.<x>.symbolName()`; the allowlists in `llvm_compile` /
   `cli/builder.zig` iterate the enum. `grep -rn '"roc_builtins_'
   src/backend src/cli src/llvm_compile` should end up matching nothing.
6. **One `LowLevel → BuiltinFn` mapping.** Keep per-backend decisions
   about *whether* to call a builtin vs. emit inline code, but the mapping
   from op to builtin lives in one shared table next to the registry, so a
   backend cannot map the same op to a different symbol. Fold
   `BuiltinLowLevel.zig`'s `isIntrinsicAnnotation` allowlist into the same
   registry so builtin-ness is declared once.

## What success looks like

- Adding a builtin touches: `Builtin.roc`, `LowLevel`, one registry entry
  (enum member + wrapper), and the implementation. Everything else —
  exports, JIT table, wasm signatures, LLVM symbol names — is generated,
  and forgetting any formerly-manual step is a compile error.
- No file contains a hand-written `"roc_builtins_..."` string except the
  registry's `symbolName()`.
- The seven tables' membership counts cannot be asked about anymore,
  because there is one membership with per-consumer predicates.

## How to evaluate the result

### Correctness ideal

Every backend links and runs the full test suite; the JIT resolves every
symbol the dev backend can emit (an exhaustive test calls each registry
member through the object-file path); the wasm backend validates every
generated module that calls each builtin. The reflection/assertion layer is
the real prize: change one wrapper's parameter list and confirm the build
breaks at the `sigs` derivation, not at run time.

### Performance ideal

All generation is comptime — zero runtime cost and no measurable build-time
regression (the comptime loops replace equivalent amounts of hand-written
code). Generated export/JIT tables are identical in content to today's,
verifiable by diffing `nm` output on the static library before/after.

## Tests to add

- Comptime totality: every `BuiltinFn` has a wrapper, a symbol name, and a
  wasm signature (derived or asserted).
- Per-backend smoke: a generated test that invokes every registry member
  through the dev-JIT path and through a compiled static-lib link, so a
  missing export or JIT entry fails CI rather than a user build.
- Signature-drift canary: a comptime assertion suite that re-derives each
  wasm `sigs` row from its wrapper's `@typeInfo` (this is the interim form
  of step 4, kept permanently if full derivation lands).
- `nm`-diff harness (CI or local script) comparing exported symbol sets of
  `static_lib` before/after registry changes.

## Related projects

- [Complete the Checked Dispatch Evidence
  Migration](complete-dispatch-evidence-migration.md) — same disease
  (hand-synced parallel encodings), different subsystem.
- [Silent-Drift Guards for Mirrored Semantic
  Pairs](../small/silent-drift-guards.md) — the small-scale companion for
  mirrored logic that cannot be structurally unified.
