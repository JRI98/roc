# META
~~~ini
description=Canonicalize crash: duplicate record fields in canonical type key normalization
type=file
~~~
# SOURCE
~~~roc
main! = |_args| {
    dbg Dict.empty().insert({a: 1, b: 2}, 3)
    fn1 = |a,insert({a: 1, a: 2}, 3)nt b||||| a + b Ok({})
}
~~~
# EXPECTED
PANIC: duplicate record fields in canonical type key invariants
