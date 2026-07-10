# Iterator Design Contract

This contract governs the compiler-internal representation and optimization of
`Iter` and `Stream`. Their public source APIs are frozen. Bounded chains use
per-chain minted nominal types; recursive or over-cap chains use an explicit
forced-dynamic representation. Optimized modes additionally run the general
SpecConstr and wrapper-inline machinery before direct Lambda Solved-to-LIR
lowering.

## As-Built Status (2026-07)

The shipping iterator goal is complete.

- The authoritative Rocci Bird `--opt=size --target=wasm32` cart is 36,892
  bytes with idiomatic iterators.
- The equivalent direct-list cart is 36,850 bytes.
- The iterator premium is 42 bytes.
- The iterator cart boots with the same `OK 191` result as the direct-list cart.
- The iterator chain and constant base list perform zero runtime heap
  allocations on the cart gate.
- All 18 focused allocation cases pass across interpreter, dev, and Roc's WASM
  backend.
- Runtime-recursive dev `concat` terminates, lowers, and executes correctly
  through the forced-dynamic tier. The committed cart is 541,756 bytes with a
  600,000-byte regression ceiling.

The remaining roughly 26 KB gap to the 10,655-byte Rust cart is general
runtime, standard-library, platform, ARC, export, and code-generation cost. It
is not iterator representation overhead.

## Public Contract

The source representation remains:

```roc
Iter(item) :: {
    len_if_known : [Known(U64), Unknown],
    step : () -> [One({ item, rest : Iter(item) }), Skip({ rest }), Done],
}

Stream(item) :: {
    len_if_known : [Known(U64), Unknown],
    step! : () => [One({ item, rest : Stream(item) }), Skip({ rest }), Done],
}
```

There is no public iterator trait, chain type parameter, private source-visible
step tag, or runtime-tagged universal chain API. Adapters and custom sources
remain ordinary Roc functions.

## Goals And Non-Goals

The representation goal is that every statically bounded iterator or stream
chain can be carried by value without an iterator-attributable heap box,
including chains that escape a local expression, cross function boundaries, or
are selected by branches.

Recursive construction whose adapter depth is a runtime value must still
compile through a finite type and callable universe. Such a chain may
materialize dynamic state. The compiler must prefer correct explicit dynamic
representation over unbounded specialization.

Optimized generated code should approach the corresponding hand-written loop.
Non-optimizing backends must be correct and bounded; matching optimized
throughput there is not a goal.

## Hard Invariants

1. `Iter(item)` and `Stream(item)` keep their public APIs.
2. Purity and effect semantics are unchanged. The compiler does not turn pull
   stepping into eager mutation.
3. No algebraic iterator rewrite may skip, duplicate, or reorder user
   computation.
4. Materialization consumers such as List, Set, and Dict construction still run
   exactly where written.
5. Element order and Stream effect order are preserved exactly.
6. User `is_eq` results never license compiler value substitution.
7. Backends receive ordinary LIR plus explicit ARC statements. They do not
   receive iterator representation policy.

## Representation Tiers

Monotype `TypeDef` records:

```zig
const IteratorRepresentation = enum(u8) {
    none,
    minted,
    forced_dynamic,
};
```

The representation and `iterator_depth` fields participate in type equality,
cross-store equality, and digests, and every type-store translation preserves
them.

### Public

`none` is the ordinary public nominal. It carries the recursive public backing
and no internal chain identity.

### Minted

`minted` is a statically bounded internal chain nominal. Its
`def.generated` digest includes adapter kind, item type, component types, and
callable evidence where required. Its `iterator_depth` records the chain depth
computed where the type is created.

The backing rewrites public recursive `rest : Iter(item)` occurrences to the
minted self type. Additional nominal arguments record concrete components such
as the predecessor iterator and adapter captures. Each adapter layer therefore
embeds a different concrete predecessor by value; the layout graph does not see
one public nominal's recursive self edge.

Minted step callables remain finite Lambda Solved callable sets. They become
ordinary generated callable tag-union values during direct LIR lowering.

### Forced Dynamic

`forced_dynamic` is the explicit finite fixed point for recursive and over-cap
construction. It is interned per item-type digest, retains the public source
declaration identity, and has a public-shaped backing whose recursive
`rest` occurrences point to the forced-dynamic self type.

A forced-dynamic iterator is distinct from both the public nominal and every
minted nominal. When it meets either in Monotype or Lambda Solved unification,
the forced-dynamic root wins. Lambda Solved unifies item and backing types so
all reachable step implementations flow into the boundary, then marks the
completed backing's step callable as erased. Direct LIR lowering emits packed
erased callable values and indirect calls from that solved data.

The dynamic tier does not imply one fixed heap-allocation count. The exact
layout can keep a finite erased callable payload by value, while genuinely
recursive public-shaped state may require materialization. The contract is a
finite, explicit representation and correct behavior, not a requirement to
manufacture a heap box.

## Mint-Depth Bound

`generatedIteratorType` in `src/postcheck/monotype/lower.zig` is the sole
minting producer. It uses:

- maximum minted chain depth: 16;
- bounded structural walk budget: 64;
- source depth: 1;
- adapter depth: one plus the maximum component depth reachable by value.

Minted children contribute their recorded depth. Forced-dynamic children
contribute the cap, so adapters above a dynamic boundary remain dynamic.
Records, tuples, tag payloads, named arguments, lists, and boxes propagate
contained value depth. Function types contribute no stored value depth, and
named backings are not traversed.

When the next depth exceeds the cap, the producer returns the interned
forced-dynamic type. If the structural walk exhausts its own budget, it reports
the cap. The bound therefore limits the type universe at its creation point and
gives recursive specialization a finite fixed point.

Lambda Solved never computes chain depth from transformed type structure. It
consumes the representation tier and recorded depth produced by Monotype.

## Consumers And Specialization

Consumers such as `next`, `fold`, `for`, and `collect` specialize against
the concrete internal nominal family. Source `for` becomes ordinary Monotype
loop, match, and call structure carrying the current iterator explicitly.

Every build mode follows the same production route:

```text
Monotype
  -> Monotype Lifted
  -> optional SpecConstr
  -> Lambda Solved
  -> solved inline plan
  -> SolvedLirLower
  -> LIR optimization and ARC
```

Dev and interpreter modes use `InlineMode.none`. Size and speed modes use
`InlineMode.wrappers`, which runs Monotype Lifted SpecConstr and solved wrapper
inline analysis.

SpecConstr is a general call-pattern specialization pass, not a second iterator
representation. For exposed iterator and stream loops it can inline finite
callables, split known constructor state into leaves, simplify known matches,
and scalarize loop-carried state. Every reachable `continue` edge must supply
the required leaves, including transitions where adapter state changes.

Minting removes recursive layout allocation before any backend sees the
program. SpecConstr exposes scalar loop shape in optimized modes. LLVM then
performs ordinary target optimization on the already-flat LIR.

## Constant List Storage

Compile-time finalization can turn an eligible constant list into an explicit
`static_data_candidate`. Direct LIR lowering emits its bytes into the data
segment. This is separate from minting and SpecConstr, but it is required for a
constant list's base allocation to disappear from the shipping cart.

The eval allocation harness does not run this constant-hoisting path, so its
constant-list iterator case deliberately permits the one base-list allocation.
The static-library cart gate is authoritative for the zero-allocation constant
list claim.

## Rejected Approaches

These remain rejected.

1. **A public iterator trait or chain type family.** This changes the frozen Roc
   API. The compiler recovers concrete chain identity internally instead.
2. **Eager mutation modeled after Rust's `&mut self`.** This changes Roc
   semantics and does not itself remove a recursive data-layout edge.
3. **One uniform internal layout for all `Iter(item)` values.** Layout
   recursion is keyed on nominal identity. Varying only a backing under one
   nominal does not move predecessor state into a different recursive component.
4. **Continuation flattening as the representation fix.** Iterator predecessor
   recursion is stored data, not only recursion behind a continuation return.
5. **A missing callable variant treated as unreachable.** The dev recursive
   `concat` investigation proved the missing variant executes at runtime.
   Routing it to an impossible branch is unsound.
6. **Binary size, fingerprints, or differential values as allocation proxies.**
   Allocation claims require allocation counters or static LIR shape evidence.
7. **A second iterator-only fusion representation.** The implemented general
   SpecConstr pass already supplies optimized scalarization, and the measured
   cart premium is only 42 bytes. More iterator-specific machinery requires a
   new measured deficiency.

## Acceptance Gates

The durable focused gates are:

- `src/eval/test/eval_iter_alloc_tests.zig`: 18 allocation-counted cases across
  interpreter, dev, and WASM;
- `src/eval/test/lir_inline_test.zig`: bounded escaping chains stay flat,
  recursive and over-cap chains use forced-dynamic erased callables, and
  iterator loops expose the required scalar shape;
- `test/wasm/iter_list_hoist_static_lib_app.roc`: constant list plus iterator
  chain has zero runtime allocations;
- `test/wasm/iter_for_static_lib_app.roc`: optimized iterator `for` drive
  boots and stays under its cart ceiling;
- `test/wasm/iter_for_noiter_static_lib_app.roc`: direct-list size twin;
- `test/wasm/iter_recursive_concat_static_lib_app.roc`: dev recursive
  `concat` returns `ok`, balances allocations/deallocations, and remains below
  600,000 bytes;
- Rocci Bird iterator and direct-list carts: equal `OK 191` behavior and the
  measured 42-byte premium.

Focused implementation work must run the smallest relevant subsets first.
Whole-tree CI is a final integration gate, not the inner edit/test loop.

## Current Conclusion

Per-chain minting, explicit forced-dynamic representation, SpecConstr loop
scalarization, and constant-list static storage jointly deliver the iterator
goal. The current iterator premium is 42 bytes. Further work toward Rust's total
cart size belongs to general ARC, runtime, export, standard-library, platform,
and code-generation size efforts, not to a new iterator representation or
fusion campaign.
