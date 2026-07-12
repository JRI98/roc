# META
~~~ini
description=Canonicalize panic in static_dispatch_registry invariant
type=file
~~~
# SOURCE
~~~roc
topThunk=||echo!("")main!=|_|{thunk=||echo!("")thunk()topThunk()
({}1E483647)}
~~~
# EXPECTED
PANIC: static_dispatch_registry.zig:1221 unreachable
