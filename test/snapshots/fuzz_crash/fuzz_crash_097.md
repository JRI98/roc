# META
~~~ini
description=Parser formatting instability (multiline tuple vs lambda)
type=file
~~~
# SOURCE
~~~roc
a=(0(0->X)
->X .a)
~~~
# EXPECTED
PANIC: Formatting not stable in parser formatter round-trip
