# META
~~~ini
description=Dollar-prefixed record field names are rejected
type=expr
~~~
# SOURCE
~~~roc
{ $field : "value" }
~~~
# EXPECTED
PARSE ERROR - dollar_prefix_field_name.md:1:3:1:9
PARSE ERROR - dollar_prefix_field_name.md:1:10:1:11
# PROBLEMS

┌─────────────┐
│ PARSE ERROR ├─ A parsing error occurred: expected_expr_record_field_name ───┐
└┬────────────┘                                                               │
 │                                                                            │
 │  { $field : "value" }                                                      │
 │    ‾‾‾‾‾‾                                                                  │
 └─────────────────────────────────────────── dollar_prefix_field_name.md:1:3 ┘

    This is an unexpected parsing error. Please check your syntax.


┌─────────────┐
│ PARSE ERROR ├─ A parsing error occurred: ───────────────────────────────────┐
└┬────────────┘  expected_expr_close_curly_or_comma                           │
 │                                                                            │
 │  { $field : "value" }                                                      │
 │           ‾                                                                │
 └────────────────────────────────────────── dollar_prefix_field_name.md:1:10 ┘

    This is an unexpected parsing error. Please check your syntax.

# TOKENS
~~~zig
OpenCurly,LowerIdent,OpColon,StringStart,StringPart,StringEnd,CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(e-malformed (reason "expected_expr_close_curly_or_comma"))
~~~
# FORMATTED
~~~roc

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
