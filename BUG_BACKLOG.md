# BUG BACKLOG

## 2026-07-12

### 1) Parser formatting round-trip instability on special-tokenized block expression
- Target: `fuzz-parse`
- Repro command:
  - `./zig-out/bin/repro-parse -v /tmp/parse-fuzz-run/default/crashes/id:000000,sig:06,src:000427+003480,time:127364,execs:392868,op:splice,rep:1`
- Snapshot:
  - `test/snapshots/fuzz_crash/fuzz_crash_104.md`
- Observed:
  - Panic: `Formatting not stable`
  - Crash signature reproduced by formatter output mismatch (non-panicking path).
  - Input source:
    - `e={0#`
    - `.0.{} }`
- Status:
  - **Actioned**: Added to snapshot corpus.

### 2) Canonicalize fuzz run 10-minute pass (`/tmp/canon-fuzz-run-3`) review
- Target: `fuzz-canonicalize`
- Output summary:
  - `saved_crashes: 3` and `saved_hangs: 0` in fuzzer stats at completion.
  - Three saved crash files were:
    - `id:000000,sig:06,src:005168,time:239690,execs:476292,op:havoc,rep:1`
    - `id:000001,sig:06,src:005168,time:241302,execs:476663,op:havoc,rep:1`
    - `id:000002,sig:06,src:005168,time:246705,execs:483278,op:havoc,rep:1`
- Triage:
  - Each reproducer via `./zig-out/bin/repro-canonicalize -v <crashfile>` reports `Invalid Number` and exits cleanly.
  - No additional snapshot was added because these were not reproducible panics/hangs in canonicalization itself.
