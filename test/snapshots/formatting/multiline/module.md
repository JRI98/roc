# META
~~~ini
description=Multiline formatting module
type=snippet
~~~
# SOURCE
~~~roc
module [
	a,
	b,
]

a = 'a'

b = 'a'
~~~
# EXPECTED
MODULE HEADER DEPRECATED - module.md:1:1:4:2
# PROBLEMS

┌──────────────────────────┐
│ MODULE HEADER DEPRECATED ├─ The `module` header is deprecated. ─────────────┐
└┬─────────────────────────┘                                                  │
 │                                                                            │
 │  module [                                                                  │
 │      a,                                                                    │
 │      b,                                                                    │
 │  ]                                                                         │
 │                                                                            │
 └───────────────────────────────────────────────────────────── module.md:1:1 ┘

    Type modules (headerless files with a top-level type matching the filename)
    are now the preferred way to define modules.

    Remove the `module` header and ensure your file defines a type that matches
    the filename.

# TOKENS
~~~zig
KwModule,OpenSquare,
LowerIdent,Comma,
LowerIdent,Comma,
CloseSquare,
LowerIdent,OpAssign,SingleQuote,
LowerIdent,OpAssign,SingleQuote,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(module
		(exposes
			(exposed-lower-ident
				(text "a"))
			(exposed-lower-ident
				(text "b"))))
	(statements
		(s-decl
			(p-ident (raw "a"))
			(e-single-quote (raw "'a'")))
		(s-decl
			(p-ident (raw "b"))
			(e-single-quote (raw "'a'")))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "a"))
		(e-num (value "97")))
	(d-let
		(p-assign (ident "b"))
		(e-num (value "97"))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Dec"))
		(patt (type "Dec")))
	(expressions
		(expr (type "Dec"))
		(expr (type "Dec"))))
~~~
