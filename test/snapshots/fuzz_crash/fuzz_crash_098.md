# META
~~~ini
description=Parser formatter round-trip failure on carriage return byte
type=file
source_escapes=true
~~~
# SOURCE
~~~roc
a=(0\r.e)
~~~
# EXPECTED
PANIC: Parsing of formatter output failed
