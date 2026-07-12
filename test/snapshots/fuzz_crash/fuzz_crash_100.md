# META
~~~ini
description=Canonicalize crash: type annotation node assumed where nominal declaration is not a type header
type=file
~~~
# SOURCE
~~~roc
T := [].{
	A ::T.A
}
~~~
# EXPECTED
PANIC: unreachable, node is not a type annotation tag
