# META
~~~ini
description=Issue #10092: Panic node is not a type annotation tag
type=file
~~~
# SOURCE
~~~roc
T := [].{
	A : T.A
}
