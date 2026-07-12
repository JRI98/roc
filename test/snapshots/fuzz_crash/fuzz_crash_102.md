# META
~~~ini
description=Canonicalize panic in canonical_type_keys invariant
type=file
~~~
# SOURCE
~~~roc
main!=|G|"""
.S
~~~
# EXPECTED
PANIC: canonical_type_keys.zig:653 invariantViolation("canonical type key requested for erroneous checked type")
