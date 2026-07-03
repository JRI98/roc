answer = 1.I64 % 0.I64

main! : List(Str) => Try(I64, [Exit(I8), ..])
main! = |_| Ok(answer)
