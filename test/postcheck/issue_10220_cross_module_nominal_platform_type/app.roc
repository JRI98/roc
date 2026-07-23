app [main] { pf: platform "platform/main.roc" }

import pf.Lib
import App

main = { things: [Box.box(handler!)] }

handler! = |_req| App.wrap("ok")
