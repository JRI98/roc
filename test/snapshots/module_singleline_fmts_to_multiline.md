# META
~~~ini
description=An empty module with a singleline exposes with trailing comma
type=snippet
~~~
# SOURCE
~~~roc
module [something, SomeType,]
~~~
# EXPECTED
MODULE HEADER DEPRECATED - module_singleline_fmts_to_multiline.md:1:1:1:30
EXPOSED BUT NOT DEFINED - module_singleline_fmts_to_multiline.md:1:9:1:18
EXPOSED BUT NOT DEFINED - module_singleline_fmts_to_multiline.md:1:20:1:28
# PROBLEMS

┌──────────────────────────┐
│ MODULE HEADER DEPRECATED ├─ The `module` header is deprecated. ─────────────┐
└┬─────────────────────────┘                                                  │
 │                                                                            │
 │  module [something, SomeType,]                                             │
 │  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾                                             │
 └──────────────────────────────── module_singleline_fmts_to_multiline.md:1:1 ┘

    Type modules (headerless files with a top-level type matching the filename)
    are now the preferred way to define modules.

    Remove the `module` header and ensure your file defines a type that matches
    the filename.


┌─────────────────────────┐
│ EXPOSED BUT NOT DEFINED ├─ The module header says that `something` is ──────┐
└┬────────────────────────┘  exposed, but it is not defined anywhere in       │
 │                           this module.                                     │
 │                                                                            │
 │  module [something, SomeType,]                                             │
 │          ‾‾‾‾‾‾‾‾‾                                                         │
 └──────────────────────────────── module_singleline_fmts_to_multiline.md:1:9 ┘

    You can fix this by either defining `something` in this module, or by
    removing it from the list of exposed values.


┌─────────────────────────┐
│ EXPOSED BUT NOT DEFINED ├─ The module header says that `SomeType` is ───────┐
└┬────────────────────────┘  exposed, but it is not defined anywhere in       │
 │                           this module.                                     │
 │                                                                            │
 │  module [something, SomeType,]                                             │
 │                     ‾‾‾‾‾‾‾‾                                               │
 └─────────────────────────────── module_singleline_fmts_to_multiline.md:1:20 ┘

    You can fix this by either defining `SomeType` in this module, or by
    removing it from the list of exposed values.

# TOKENS
~~~zig
KwModule,OpenSquare,LowerIdent,Comma,UpperIdent,Comma,CloseSquare,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(module
		(exposes
			(exposed-lower-ident
				(text "something"))
			(exposed-upper-ident (text "SomeType"))))
	(statements))
~~~
# FORMATTED
~~~roc
module [
	something,
	SomeType,
]
~~~
# CANONICALIZE
~~~clojure
(can-ir (empty true))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(expressions))
~~~
