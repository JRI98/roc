# META
~~~ini
description=fuzz crash: canonicalization panic for type_parameter_conflict
type=file
skip=true
~~~
# SOURCE
~~~roc
A(a) : a where [a.a1 : (a, a) -> Str]
C(b, b) : (a, b)
D(a, b) : C(a, b)
~~~
# EXPECTED
Unhandled canonicalize diagnostic in diagnosticToReport: type_parameter_conflict

Source: /home/lbw/Documents/Github/roc/src/canonicalize/ModuleEnv.zig:3165

This snapshot is intentionally marked `skip=true` because `zig build run-snapshot-tool`
crashes while materializing EXPECTED diagnostics for this input.
