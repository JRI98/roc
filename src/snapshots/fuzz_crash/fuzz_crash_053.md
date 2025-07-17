# META
~~~ini
description=fuzz crash
type=file
~~~
# SOURCE
~~~roc
module[){..0,)
~~~
# EXPECTED
MISMATCHED BRACE - :0:0:0:0
MISMATCHED BRACE - :0:0:0:0
PARSE ERROR - fuzz_crash_053.md:1:10:1:12
PARSE ERROR - fuzz_crash_053.md:1:12:1:13
UNEXPECTED TOKEN IN EXPRESSION - fuzz_crash_053.md:1:13:1:14
UNEXPECTED TOKEN IN EXPRESSION - fuzz_crash_053.md:1:14:1:15
INVALID STATEMENT - fuzz_crash_053.md:1:9:1:13
INVALID STATEMENT - fuzz_crash_053.md:1:13:1:14
INVALID STATEMENT - fuzz_crash_053.md:1:14:1:15
# PROBLEMS
**MISMATCHED BRACE**
This brace does not match the corresponding opening brace.

**MISMATCHED BRACE**
This brace does not match the corresponding opening brace.

**PARSE ERROR**
A parsing error occurred: `expected_expr_record_field_name`
This is an unexpected parsing error. Please check your syntax.

Here is the problematic code:
**fuzz_crash_053.md:1:10:1:12:**
```roc
module[){..0,)
```
         ^^


**PARSE ERROR**
A parsing error occurred: `expected_expr_close_curly_or_comma`
This is an unexpected parsing error. Please check your syntax.

Here is the problematic code:
**fuzz_crash_053.md:1:12:1:13:**
```roc
module[){..0,)
```
           ^


**UNEXPECTED TOKEN IN EXPRESSION**
The token **,** is not expected in an expression.
Expressions can be identifiers, literals, function calls, or operators.

Here is the problematic code:
**fuzz_crash_053.md:1:13:1:14:**
```roc
module[){..0,)
```
            ^


**UNEXPECTED TOKEN IN EXPRESSION**
The token **)** is not expected in an expression.
Expressions can be identifiers, literals, function calls, or operators.

Here is the problematic code:
**fuzz_crash_053.md:1:14:1:15:**
```roc
module[){..0,)
```
             ^


**INVALID STATEMENT**
The statement `expression` is not allowed at the top level.
Only definitions, type annotations, and imports are allowed at the top level.

**fuzz_crash_053.md:1:9:1:13:**
```roc
module[){..0,)
```
        ^^^^


**INVALID STATEMENT**
The statement `expression` is not allowed at the top level.
Only definitions, type annotations, and imports are allowed at the top level.

**fuzz_crash_053.md:1:13:1:14:**
```roc
module[){..0,)
```
            ^


**INVALID STATEMENT**
The statement `expression` is not allowed at the top level.
Only definitions, type annotations, and imports are allowed at the top level.

**fuzz_crash_053.md:1:14:1:15:**
```roc
module[){..0,)
```
             ^


# TOKENS
~~~zig
KwModule(1:1-1:7),OpenSquare(1:7-1:8),CloseSquare(1:8-1:9),OpenCurly(1:9-1:10),DoubleDot(1:10-1:12),Int(1:12-1:13),Comma(1:13-1:14),CloseCurly(1:14-1:15),EndOfFile(1:15-1:15),
~~~
# PARSE
~~~clojure
(file @1.1-1.15
	(module @1.1-1.9
		(exposes @1.7-1.9))
	(statements
		(e-malformed @1.12-1.13 (reason "expected_expr_close_curly_or_comma"))
		(e-malformed @1.13-1.14 (reason "expr_unexpected_token"))
		(e-malformed @1.14-1.15 (reason "expr_unexpected_token"))))
~~~
# FORMATTED
~~~roc
module []

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
