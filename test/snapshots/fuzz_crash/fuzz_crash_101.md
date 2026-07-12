# META
~~~ini
description=Parser formatting non-stable roundtrip
type=file
~~~
# SOURCE
~~~roc
r:(),(->c),(->d)->(c,)
r=|()|(()())
a={
}
~~~
# EXPECTED
PANIC: FormattingNotStable
