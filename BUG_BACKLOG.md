# BUG BACKLOG

## 2026-07-12 (Parser + Canonicalize fuzzer run, 10 min each)

Ran:

- `timeout 600s env AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 AFL_SKIP_CPUFREQ=1 afl-fuzz -i /tmp/roc-fuzz-parse-corpus -o /tmp/fuzz-parse-out -t 5000+ -m none ./zig-out/bin/fuzz-parse`
- `timeout 600s env AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 AFL_SKIP_CPUFREQ=1 afl-fuzz -i /tmp/roc-fuzz-canonicalize-corpus -o /tmp/fuzz-canonicalize-out -t 5000+ -m none ./zig-out/bin/fuzz-canonicalize`

Observed outcomes:

- Parser fuzz: `3` crash files, `0` hangs
- Canonicalize fuzz: `4` crash files, `0` hangs

Crash IDs:

- Parser: `id:000000`, `id:000001`, `id:000002`
- Canonicalize: `id:000000`, `id:000001`, `id:000002`, `id:000003`

Triage (unique issues):

1. `moduleFmtsStable` formatting instability (panic: `error.FormattingNotStable`)
   - Snapshot repro: `test/snapshots/fuzz_crash/fuzz_crash_101.md`
   - Crash IDs: parser `id:000000`, `id:000001`, `id:000002`

2. Canonicalization invariant violation while building canonical type keys
   - Panic: `src/check/canonical_type_keys.zig:653` (`invariantViolation` / `"canonical type key requested for erroneous checked type"`)
   - Snapshot repro: `test/snapshots/fuzz_crash/fuzz_crash_102.md`
   - Crash IDs: canonicalize `id:000000`, `id:000001`

3. Canonicalization invariant violation in static dispatch publication
   - Panic: `src/check/static_dispatch_registry.zig:1221` (`unreachable` in `fromModule__anon_*`)
   - Snapshot repro: `test/snapshots/fuzz_crash/fuzz_crash_103.md`
   - Crash IDs: canonicalize `id:000002`, `id:000003`
