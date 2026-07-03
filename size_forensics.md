# Rocci Bird `--opt=size` forensics: where the bytes went (Slice G vs checkpoint)

Measurement task under the Slice-G measurement ruling. No optimizer code was
changed; only temporary probes (since removed) and this report. Numbers are
from four freshly built `--opt=size` wasm carts:

| variant | checkpoint `57b0541c66` | current `b0069f306c` | delta |
|---|---:|---:|---:|
| iter   (`rocci-bird.roc`)            | 94,455 | 103,548 | **+9,093** |
| noiter (`rocci-bird-noiter-check.roc`) | 92,940 |  96,234 | **+3,294** |

(File sizes differ from the plan's 94,448 / 92,933 / 103,544 / 96,230 by 4-8
bytes of embedded build hash; the deltas are exact.) The two source files are
identical except line 358: iter has `].iter()`, noiter has `]`.

## Section-level accounting: it is all code

| section | iter ckpt -> G | noiter ckpt -> G |
|---|---|---|
| **data**   | 33,622 -> 33,622 (**0**) | 33,622 -> 33,622 (**0**) |
| **code**   | 55,477 -> 64,618 (**+9,141**) | 54,028 -> 57,483 (**+3,455**) |
| custom (names) | 4,162 -> 4,118 (-44) | 4,100 -> 3,946 (-154) |
| everything else (type/import/func/table/global/export/elem) | ~1 net | ~0 net |

The data segment is byte-identical. The whole regression lives in the code
section. Function counts actually *dropped* (iter 177 -> 173, noiter 173 ->
165): fewer functions, more code. The growth is **concentration** - surviving
functions absorbed per-site machinery via inlining/scalarization.

Builtins, host shims, allocator, and refcount thunks align by name and are
byte-stable: matched-by-name delta is **-31 B (iter)** / **-58 B (noiter)**,
dominated by `roc_llvm_rc_decref_109` shrinking. Every regressing byte is in
the `roc__proc_*` set. The `roc__proc_<hex>` suffixes renumber wholesale
between builds (checkpoint 2xx/3xx, current 4xx/5xx), so procs were aligned by
(1) stable wasm **function index**, (2) `host_*` call signature, and (3) size/
shape. All three agree.

## Top-20 functions per binary (body bytes, function index, name)

### current iter (G)
```
 8351 #119 proc_4aa      2577 #124 proc_4cf      831 #147 proc_4ff
 7406 #82  proc_47b      2272 #92  proc_4a2      817 #153 proc_4fe
 4321 #132 proc_4ec      2198 #127 proc_4a1      806 #90  proc_4a8
 4226 #84  proc_47a      1854 #81  proc_47c      752 #31  host.ummRemap
 3688 #129 proc_4a5      1761 #120 proc_4a9      662 #23  allocator.malloc
 2577 #85  proc_47d      1279 #74  proc_46f      618 #108 proc_4cb
                          880 #176 list.listReserve  831 #139 proc_502
```
### checkpoint iter
```
 8351 #131 proc_351      2577 #140 proc_360      818 #134 proc_355
 3956 #84  proc_2e6      2272 #92  proc_30e      806 #90  proc_314
 3688 #128 proc_311      2198 #126 proc_30d      752 #31  host.ummRemap
 3066 #82  proc_2e7      1761 #132 proc_350      685 #154 proc_36c
 2577 #85  proc_2e9      1384 #81  proc_2e8      662 #23  allocator.malloc
                          1279 #74 proc_2db      618 #108 proc_334
                          880 #180 list.listReserve  618 #111 proc_32f  532 #120 proc_315
```
### current noiter (G)
```
 8351 #119 proc_3d5      2577 #124 proc_3fa      806 #90  proc_3d3
 7406 #82  proc_3a6      2272 #92  proc_3cd      752 #31  host.ummRemap
 4226 #84  proc_3a5      2198 #127 proc_3cc      662 #23  allocator.malloc
 3688 #129 proc_3d0      1854 #81  proc_3a7      618 #108 proc_3f6
 2577 #85  proc_3a8      1761 #120 proc_3d4      618 #111 proc_3f1
                          1279 #74 proc_39a      447 #125 proc_3ff
                          1029 #132 proc_417     880 #168 list.listReserve
```
### checkpoint noiter
```
 8351 #131 proc_350      2577 #140 proc_35f      806 #90  proc_313
 3956 #84  proc_2e5      2272 #92  proc_30d      752 #31  host.ummRemap
 3688 #128 proc_310      2198 #126 proc_30c      662 #23  allocator.malloc
 3066 #82  proc_2e6      1761 #132 proc_34f      618 #108 proc_333
 2577 #85  proc_2e8      1384 #81  proc_2e7      618 #111 proc_32e
                          1279 #74 proc_2da      532 #120 proc_314
                          897 #134 proc_354      880 #176 list.listReserve
```

## Aligned delta table (index/role-anchored)

| role | fn idx | ckpt | current | delta | note |
|---|---|---:|---:|---:|---|
| `update!` game-state machine | #82 | 3,066 | 7,406 | **+4,340** | loops 1->2; rc-call sites 18->71 |
| draw (blit/rect/text)        | #84 | 3,956 | 4,226 | +270 | |
| draw #81                     | #81 | 1,384 | 1,854 | +470 | |
| `on_screen_collided!` (iter) | -   |    93 | 4,321 | +4,228 | body-only fn -> 3-loop fused fn |
| `on_screen_collided!` (noiter)| -  |   897 | 1,029 | +132 | single list loop, no split |
| big frame fn #119            | #119| 8,351 | 8,351 | 0 | unchanged |
| two 2,577 workers #85/#124   | -   | 5,154 | 5,154 | 0 | present in both builds |
| plain iterator loop sites    | -   | -     | -     | **negative** | scalarized form is smaller (see marginals) |

The low wasm function indices are stable across builds, which nails the
identity of the two biggest movers: **#82 = `update!` grew +4,340** and it is
present, identical in size and shape, in *both* iter and noiter. That single
function is the largest regression term and it is **not** the collision loop.

## Quantified answers to (a)-(d)

### (a) Per-site loop machinery vs removed shared workers (iter)

The checkpoint drove the branch-chosen collision iterator through **shared
generic Iter workers**; current fuses per branch. The exchange:

- **Removed** (checkpoint-only Iter dispatch/append/next workers): 13 functions
  totalling **4,343 B** (818, 685, 532, 406, 320, 296, 283, 268, 235, 219, 134,
  101, 46) plus the 93 B body function.
- **Added** (current per-branch step workers): 7 functions totalling **3,964 B**
  (831, 831, 817, 519, 322, 322, 322), plus the collision function itself
  ballooning from a 93 B body to a **4,321 B** three-loop function.
- Net collision-area cost: **(3,964 + 4,321) - (4,343 + 93) = +3,849 B**, iter only.

Fused loop sites in `proc_4ec`: **3** (one `loop` per branch: append-two,
append-one, base), each with its own step-worker call and an inlined get_pixel
body (`proc_504`, called 3x).

### (b) The two 2,577 B workers: same size, NOT byte-identical

`proc_47d` and `proc_4cf` are both 2,577 B but differ in **26 of 761 lines** -
store offsets (272 vs 264; 72 vs 80; a field at offset 168 placed differently)
and constants (17/6 vs 6/12). They are two **layout-specialized** copies of one
generic worker, each called exactly once (from `proc_472` and `proc_47c`). They
exist unchanged in the checkpoint too, so they are **not part of the
regression**. A naive byte-dedup will not fire; reclaiming them needs
re-generalizing the worker over its field layout (offsets passed as data).

The real near-duplicates are two smaller trios (see rank 3): the **831-byte
trio** (`proc_502` vs `proc_4ff` differ in **2 lines**; `proc_4fe` differs in
12) and the **322-byte trio** (`proc_500/501/503` differ in exactly **one
constant** - a byte tag `2` / `3` / `5` stored at `offset=56`).

### (c) Dead `len_if_known` recompute

The append step worker `proc_502` computes a known-length tag twice per call:
`i32.load8_u offset=8` (inner tag) -> `i64.load; i64.const 1; i64.add`
(inner_len + 1) -> `i64.eqz` (is-empty), then stores that byte + i64 into the
freshly allocated iterator state (`offset=16` / `offset=8`). The consuming
for-loop only tests `index == len` at the top of the loop and never reads
`len_if_known`, so the field, its per-iteration recompute, and its refcount
traffic are dead. Whole-binary `i64.eqz` count (a proxy for this recompute)
went **4 -> 9 (iter)**: roughly **+5 recompute sites**, ~15-30 B each including
the carried-state load/store, i.e. an estimated **~150-350 B**. Small.

### (d) Unexpected: refcount-operation proliferation is the real bulk

Whole-binary `call $roc_llvm_rc_*` sites:

| | checkpoint | current | delta |
|---|---:|---:|---:|
| iter   | 175 | 302 | **+127** |
| noiter | 169 | 238 | **+69**  |

Inside `update!` (#82) alone the count goes **18 -> 71**. When a shared worker
owned the iteration, refcounts were managed once behind the call boundary;
inlining/scalarizing the loop bodies into their callers re-exposed per-element
incref/decref that did not get elided, and duplicated it across the two
game-state arms (the inner loop appears twice, at lines 498 and 992 of
`proc_47b`). This is the mechanism behind the +4,340 `update!` term and it is
present in **noiter too** (no iterators involved), which is why noiter grew even
though its collision loop barely changed (+132).

## Marginal per-site cost (isolated probes, both compilers, N=1/3/5)

Distinct-constant loop sites, `--opt=size`, file bytes; slope = (N5 - N1)/4:

| loop pattern | current B/site | checkpoint B/site | verdict |
|---|---:|---:|---|
| plain iterator `for n in list.iter()` | **418** | **526** | current **saves 108/site** |
| collect / keep-if `for n in l { if c { $out=$out.append } }` | **721** | **721** | **unchanged** (byte-identical carts at every N) |
| branch-chosen append (collision shape) | **1,352** | **811** | current **costs +541/site** |

Fixed (N=1) premium of the branch-append shape over checkpoint: ~1,800 B; it
then grows +541 per added site (linear across N=1,3,5). Plain scalarized loops
are a **net win** and the win scales; the collect pattern did not change; only
the **branch-chosen-append** shape regresses per site.

## Ranked reclaim list

1. **Refcount elision after inline/scalarize** - structural, largest, both
   variants. +127 rc sites (iter) / +69 (noiter); ~53 of them in `update!`
   alone. Owner: the refcount-insertion / ownership pass. Sketch: when a loop
   body or step worker is inlined and its carried operands are provably linear
   (single owner, consumed once), own them in place and drop the surrounding
   incref/decref instead of re-emitting per-iteration RC traffic. **Est. reclaim
   ~1,500-2,500 B iter, ~1,000-1,500 B noiter.** This is the *only* lever on the
   noiter regression and roughly half of iter's.

2. **Branch-append loop-fission / shared-core peel** - structural, iter-only.
   Collapses `for e in (if c {append(base,x)} else {base}) {BODY}` into
   `for e in base {BODY}; if c {BODY[item:=x]}`, replacing the 3 per-branch
   loops + their step-worker trios with one base loop and a tail dispatch.
   Owner: the loop-split/fusion pass (the escalated FACT 2). Removes the
   +541 B/site marginal and most of the +3,849 collision-area cost.
   **Est. reclaim ~2,500-3,500 B iter-only** (0 for noiter).

3. **Congruence-keyed step-worker dedup** - surgical, iter. The 831-trio
   (`proc_502` vs `proc_4ff`: 2-line diff) and the 322-trio (`proc_500/501/503`:
   one baked byte-tag `2/3/5`) are near-congruent. Owner: the branch-split
   step-worker emission. Sketch: key emitted workers by structural congruence
   *up to baked constants and field offsets*; emit one worker parameterized by
   the differing constant (or carry it in state). **Est. reclaim ~1,600 (831
   pair) + ~644 (322 pair) = ~2,240 B iter.**

4. **Dead `len_if_known` field + recompute** - surgical, small. Owner: iterator-
   state lowering. Sketch: liveness on loop-carried state fields - if
   `len_if_known` is read by neither the loop condition, body, nor result, drop
   the field, its per-iteration `inner_len+1 / eqz` recompute, and its RC.
   **Est. reclaim ~150-350 B.**

5. **Re-generalize the two 2,577 B layout-specialized workers** - pre-existing,
   not part of this regression. Same size, different field offsets; needs the
   worker parameterized over layout. Owner: monomorphization/specialization
   policy. **Est. reclaim up to ~2,577 B** but a larger refactor; deprioritized.

## Verdict: (iii) - a per-site-vs-shared policy tension

Not (i): the surgical facts (ranks 3+4 ≈ 2,400-2,600 B) reclaim well under a
third of the +9,093 iter regression and **essentially none** of the +3,294
noiter regression. Not (ii): the peel (rank 2) is iter-only - it reclaims ~0 of
noiter and is not even a majority of iter. The dominant single term (+4,340
`update!`, rank 1) is refcount/inline proliferation that hits **both** variants
and that neither the peel nor the surgical facts touch.

The marginal probes make the tension explicit: the same pipeline that makes
plain scalarized loops **smaller** (-108 B/site) makes branch-append loops
**larger** (+541 B/site) and neutral on collect. Per-site emission is a win when
the carried state is scalar and linear, and a loss when it retains boxed/owned
carry, congruent-but-duplicated workers, or un-elided refcount traffic.

**Proposed structural rule (not a byte threshold):**

> Emit per-site iteration machinery only when the loop's carried state is
> *scalar-linear*: every carried leaf demotes to a scalar (no boxed/owned
> carry) **and** the per-iteration refcount traffic provably nets to zero.
> A site that fails this gate routes through a shared worker. Emitted workers
> are deduplicated by **structural congruence** (identical up to baked constants
> and field offsets), emitting one worker parameterized by the differing datum.
> For branch-chosen sources, the shared-core / loop-fission form is the default;
> fully split into per-branch loops only when the branch cores are structurally
> disjoint.

The peel remains the right fix for the collision premium specifically, but the
numbers say it must be paired with rank-1 refcount elision to bring both carts
back under the checkpoint - the peel alone leaves the +4,340 `update!` term
(and all of noiter) standing.

## Surprising findings

- **noiter grew with no iterators involved.** Its collision loop barely moved
  (+132); the growth is the shared `update!` +4,340 from RC/inline proliferation.
- **Plain-loop scalarization is a net size win** (-108 B/site) that scales - the
  regression is not "fusion is bigger," it is specifically the branch-append
  shape plus refcount churn.
- **Fewer functions, more code**: both current carts define fewer functions than
  the checkpoint yet ship more code - pure concentration by inlining.
- The two "duplicated 2,577 B workers" flagged in the plan are same-size but
  **not** byte-identical and **predate** this regression; the actual dedup wins
  are the smaller 831- and 322-byte trios.
- **`--debug` is not code-identical**: the `--opt=size --debug` build carries 23
  extra helper functions (+1,696 code bytes) versus the shipped build, so it is
  the wrong proxy for size work. The shipped `--opt=size` build already carries
  a function-name section, which is what these tables use.
