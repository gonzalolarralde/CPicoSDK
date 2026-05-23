//% -- test yaml
//% name: AsyncMixed
//% timeout: 5s
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   stdout:
//%     regex: "^async-start\\nasync-end\\nsync-ok\\n?$"
//%   durationMs:
//%     min: 0
//%     max: 5000
//% -----------

import CPicoSDK
import CPicoConcurrency

func asyncDelayTest() async {
    print("async-start")
    await Task.yield()
    print("async-end")
}

func syncAfterAsyncTest() throws {
    try deviceExpect(3 * 3 == 9)
    print("sync-ok")
}
