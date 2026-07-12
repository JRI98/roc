# BUG_BACKLOG

## parse fuzzer (fuzz-parse) triage run
- Date: 2026-07-12
- Duration: ~10 minutes
- Command: `AFL_SKIP_CPUFREQ=1 AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 timeout 600s afl-fuzz -i /tmp/roc-fuzz-corpus-parse -o /tmp/parse-fuzz-out zig-out/bin/fuzz-parse`
- Result artifact dir: `/tmp/parse-fuzz-out/default/hangs`
- Crashes dir: none
- Hangs/crashes detected: 9 files

## Findings

### [P1] Formatting pipeline instability in parser/formatter roundtrip
- Severity: High
- Signature: `panic("Parsing of formatter output failed")` (`SecondParseFailed`)
- First observed file: `id:000000,src:000664,time:105743,execs:440498,op:havoc,rep:1`
- All matching minimized repro files:
  - `/tmp/parse-fuzz-out/default/hangs/id:000000,src:000664,time:105743,execs:440498,op:havoc,rep:1`
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_086.md`

### [P2] Formatting pipeline instability (non-idempotent formatter output)
- Severity: High
- Signature: `panic("Formatting not stable")` (`FormattingNotStable`)
- Observed files (all same root behavior):
  - `id:000001,src:004198,time:159222,op:havoc,rep:4`
  - `id:000002,src:000086,time:205460,op:havoc,rep:1`
  - `id:000003,src:000093,time:241849,op:havoc,rep:2`
  - `id:000004,src:006532,time:335351,op:havoc,rep:1`
  - `id:000005,src:006532,time:336980,op:havoc,rep:2`
  - `id:000006,src:000677,time:464517,op:havoc,rep:1`
  - `id:000007,src:006089,time:590523,op:havoc,rep:2`
  - `id:000008,src:006089,time:591863,op:havoc,rep:1`
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_087.md`
- Note: this uses the minimized reproduction `a=(0->b .c())` from `id:000008`.

## canonicalize fuzzer (fuzz-canonicalize) triage run
- Date: 2026-07-12
- Duration: ~10 minutes
- Command: `AFL_SKIP_CPUFREQ=1 AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 timeout 600s afl-fuzz -i /tmp/roc-fuzz-corpus-canonicalize -o /tmp/canonicalize-fuzz-out-10m-final3 zig-out/bin/fuzz-canonicalize`
- Result artifact dir: `/tmp/canonicalize-fuzz-out-10m-final3/default`
- Crashes: none
- Hangs: 14 files

## Findings

### [C1] Canonicalization hang on malformed numeric annotation declarations
- Severity: High
- Signature: long-running hang / timeout in `fuzz-canonicalize` on type annotation declarations (`timeout`)
- Observed files:
  - `id:000000,src:001399,time:146579,execs:369203,op:havoc,rep:1`
  - `id:000001,src:001399,time:148537,execs:370488,op:havoc,rep:2`
  - `id:000002,src:001399,time:149983,execs:370546,op:havoc,rep:2`
  - `id:000003,src:001399,time:151415,execs:370571,op:havoc,rep:1`
  - `id:000004,src:001399,time:153005,execs:371046,op:havoc,rep:1`
  - `id:000005,src:001399,time:155492,execs:373040,op:havoc,rep:2`
  - `id:000006,src:001399,time:156976,execs:373195,op:havoc,rep:2`
  - `id:000007,src:001399,time:159386,execs:374715,op:havoc,rep:2`
  - `id:000008,src:001399,time:160858,execs:374848,op:havoc,rep:1`
  - `id:000009,src:001399,time:162413,execs:375219,op:havoc,rep:1`
  - `id:000010,src:001399,time:164399,execs:375606,op:havoc,rep:1`
  - `id:000011,src:001399,time:165831,execs:375629,op:havoc,rep:2`
  - Repro command: `timeout 2s ./zig-out/bin/repro-canonicalize /tmp/canonicalize-min/min-id000000`
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_hang_003.md`

### [C2] Canonicalization hang in recursive pattern matcher fragment
- Severity: High
- Signature: long-running hang / timeout in `fuzz-canonicalize` (`timeout`) on recursive list/slice matcher source
- Representative file:
  - `id:000012,src:000956,time:488361,execs:805058,op:havoc,rep:2`
- Repro command: `timeout 2s ./zig-out/bin/repro-canonicalize /tmp/canonicalize-min/min-id000012`
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_hang_004.md`

### [C3] Canonicalization panic in checked artifact invariants
- Severity: High
- Signature: `panic("constant root has no top-level value entry")` (`checkedArtifactInvariant`)
- Representative file:
  - `id:000013,src:005653,time:512683,execs:859166,op:havoc,rep:2`
- Repro command: `timeout 2s ./zig-out/bin/repro-canonicalize /tmp/canonicalize-min/min-id000013`
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_088.md`

## Unresolved GitHub parser/formatting issues (reproducible)
- Date: 2026-07-12

### [P3] GH-10097 unstable formatting
- Severity: High
- Issue: https://github.com/roc-lang/roc/issues/10097
- Repro command: `zig build run-repro-parse -- -b ZT17MCMKLnt9fQ== -v`
- Signature: `panic("Formatting not stable")` (`FormattingNotStable`)
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_089.md`

### [P4] GH-10096 invalid formatting (`e={()\\` input)
- Severity: High
- Issue: https://github.com/roc-lang/roc/issues/10096
- Repro command: `zig build run-repro-parse -- -b ZT17KClcXAoue2Z9e319 -v`
- Signature: `panic("Parsing of formatter output failed")` (`SecondParseFailed`)
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_090.md`

### [P5] GH-10055 unstable formatting (`a=(0->X .a)`)
- Severity: High
- Issue: https://github.com/roc-lang/roc/issues/10055
- Repro command: `zig build run-repro-parse -- -b YT0oMC0+WCAuYSk= -v`
- Signature: `panic("Formatting not stable")` (`FormattingNotStable`)
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_091.md`

### [P6] GH-10056 unstable formatting (`d=(0->X .a)`)
- Severity: High
- Issue: https://github.com/roc-lang/roc/issues/10056
- Repro command: `zig build run-repro-parse -- -b ZD0oMC0+WCAuYSk= -v`
- Signature: `panic("Formatting not stable")` (`FormattingNotStable`)
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_092.md`

### [P7] GH-10047 unstable formatting (`d=(0||())`)
- Severity: High
- Issue: https://github.com/roc-lang/roc/issues/10047
- Repro command: `zig build run-repro-parse -- -b ZD0oMHx8KCkp -v`
- Signature: `panic("Formatting not stable")` (`FormattingNotStable`)
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_093.md`

### [P8] GH-10094 invalid formatting (`dapkage[e,E.a.*]{}`)
- Severity: High
- Issue: https://github.com/roc-lang/roc/issues/10094
- Repro command: `zig build run-repro-parse -- -b ZGFwa2FnZVtlLEUuYS4qXXt9 -v`
- Signature: formatter roundtrip returns parse diagnostics after formatter output (`statement_unexpected_token`, `expected_colon_after_type_annotation`)
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_094.md`

### [P9] GH-10095 invalid formatting (`t=0->(0)()`)
- Severity: High
- Issue: https://github.com/roc-lang/roc/issues/10095
- Repro command: `zig build run-repro-parse -- -b dD0wLT4oMCkoKQ== -v`
- Signature: `panic("Parsing of formatter output failed")` (`SecondParseFailed`)
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_095.md`

### [P10] GH-10092 parser/typecheck panic
- Severity: High
- Issue: https://github.com/roc-lang/roc/issues/10092
- Repro command: `printf 'T := [].{\\n\\tA : T.A\\n}\\n' > /tmp/roc-10092.roc && ./zig-out/bin/roc check /tmp/roc-10092.roc`
- Signature: `panic("unreachable, node is not a type annotation tag: .type_header")` (`unreachable`)
- Note: this repro is not snapshot-tool generated because it currently panics during snapshot generation path; source is still captured in `fuzz_crash_096.md`.
- Minimal repro snapshot added:
  - `test/snapshots/fuzz_crash/fuzz_crash_096.md`
