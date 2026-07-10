# Bug Backlog

## Active

### [fuzz_crash_082](test/snapshots/fuzz_crash/fuzz_crash_082.md)
- Fuzzer: parse (`fuzz-parse`)
- Crash signature: `sig:06` in parse fuzzer run
- Severity: P1
- Repro: [test/snapshots/fuzz_crash/fuzz_crash_082.md](test/snapshots/fuzz_crash/fuzz_crash_082.md)
- Reproducer command:
  - `./zig-out/bin/repro-parse /tmp/roc-fuzz-plan-20260710/parse-run/default/crashes/id:000000,sig:06,src:000985,time:271224,execs:829515,op:havoc,rep:1`
  - `cat /tmp/roc-fuzz-plan-20260710/parse-run/minimized.roc`
- Notes:
  - Snapshot has canonical expected sections generated from snapshot tool.
  - This one is parser/formatter pipeline instability (`parse format output mismatch` path in `fmt` fuzzer).

### [fuzz_crash_083](test/snapshots/fuzz_crash/fuzz_crash_083.md)
- Fuzzer: canonicalize (`fuzz-canonicalize`)
- Crash signature: `sig:06` in canonicalize fuzzer run
- Severity: P1
- Repro: [test/snapshots/fuzz_crash/fuzz_crash_083.md](test/snapshots/fuzz_crash/fuzz_crash_083.md)
- Reproducer command:
  - `./zig-out/bin/repro-canonicalize /tmp/roc-fuzz-plan-20260710/canonicalize-run/default/crashes/id:000000,sig:06,src:001310,time:57857,execs:75271,op:havoc,rep:1`
  - Manual minimized source in snapshot file reproduces with `./zig-out/bin/repro-canonicalize`.
- Notes:
  - Snapshot marked `skip=true` because snapshot generation is blocked by panic in
    `src/canonicalize/ModuleEnv.zig:3165` (`Unhandled canonicalize diagnostic ... type_parameter_conflict`).
