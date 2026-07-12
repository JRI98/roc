# BUG BACKLOG

## 2026-07-12 (Parser + Canonicalize fuzzer run)

Ran two 10-minute fuzz sessions:

- `timeout 600s env AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 AFL_SKIP_CPUFREQ=1 afl-fuzz -i /tmp/roc-fuzz-parse-corpus -o /tmp/fuzz-parse-out -- -t 5000+ -m none -- zig-out/bin/fuzz-parse`
- `timeout 600s env AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 AFL_SKIP_CPUFREQ=1 afl-fuzz -i /tmp/roc-fuzz-canonicalize-corpus -o /tmp/fuzz-canonicalize-out -- -t 5000+ -m none -- zig-out/bin/fuzz-canonicalize`

Totals observed:

- Parser fuzzer: `8` crash files, `0` hangs
- Canonicalize fuzzer: `11` crash files, `0` hangs

Unique confirmed issues:

1. [fuzz_crash_097.md](</home/lbw/Documents/Github/roc/test/snapshots/fuzz_crash/fuzz_crash_097.md>)  
   Crash family: Parser formatter instability (`panic: Formatting not stable`).

   ```sh
   printf $'a=(0(0->X)\\n->X .a)\\n' > /tmp/repro-parse-097.roc && \
   ./zig-out/bin/repro-parse -v /tmp/repro-parse-097.roc
   ```

   Original corpus hits: `id:000000`, `id:000001`, `id:000002`, `id:000004`, `id:000005`.

2. [fuzz_crash_098.md](</home/lbw/Documents/Github/roc/test/snapshots/fuzz_crash/fuzz_crash_098.md>)  
   Crash family: Parser formatter round-trip failure (`panic: Parsing of formatter output failed`), including control-byte handling.

   ```sh
   printf $'a=(0\\r.e)\\n' > /tmp/repro-parse-098.roc && \
   ./zig-out/bin/repro-parse -v /tmp/repro-parse-098.roc
   ```

   Original corpus hits: `id:000003`, `id:000007` (`id:000006` did not reproduce on replay).

3. [fuzz_crash_099.md](</home/lbw/Documents/Github/roc/test/snapshots/fuzz_crash/fuzz_crash_099.md>)  
   Crash family: Canonicalization invariant violation (`unreachable`, duplicate record fields in `canonical_type_keys`).

   ```sh
   cat > /tmp/repro-canonicalize-099.roc <<'EOF'
   main! = |_args| {
       dbg Dict.empty().insert({a: 1, b: 2}, 3)
       fn1 = |a,insert({a: 1, a: 2}, 3)nt b||||| a + b Ok({})
   }
   EOF
   ./zig-out/bin/repro-canonicalize -v /tmp/repro-canonicalize-099.roc
   ```

4. [fuzz_crash_100.md](</home/lbw/Documents/Github/roc/test/snapshots/fuzz_crash/fuzz_crash_100.md>)  
   Crash family: Canonicalization node-type mismatch (`panic: unreachable, node is not a type annotation tag: .type_header`).

   ```sh
   cat > /tmp/repro-canonicalize-100.roc <<'EOF'
   T := [].{
   	A ::T.A
   }
   EOF
   ./zig-out/bin/repro-canonicalize -v /tmp/repro-canonicalize-100.roc
   ```

No hangs reproduced in either run.

Additional note:
- `/tmp/fuzz-parse-out/default/crashes/id:000006` no longer repros as a crash in direct `repro-parse` replay under `--v`.
