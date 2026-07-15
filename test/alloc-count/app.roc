app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# Regression test: a `for` loop over a list's bytes must not allocate on each
# iteration. Setup work (Str.to_utf8's copy) happens before the first count is
# taken, so `loop_allocs` measures the loop alone.
run! : Str => Str
run! = |input| {
    bytes = Str.to_utf8(input)

    before = Host.alloc_count!()

    var $sum = 0
    for byte in bytes {
        $sum = $sum + byte.to_u64()
    }

    loop_allocs = Host.alloc_count!() - before
    expect loop_allocs == 0

    "sum: ${$sum.to_str()}, loop allocations: ${loop_allocs.to_str()}"
}
