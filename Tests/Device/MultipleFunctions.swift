//% -- test yaml
//% name: MultipleFunctions
//% timeout: 5s
//% concurrency: false
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   stdout:
//%     regex: "^first\\nsecond\\n?$"
//%   durationMs:
//%     min: 0
//%     max: 5000
//% -----------

import CPicoSDK

func firstFunction() {
    print("first")
}

func secondFunction() throws {
    try deviceExpect(true)
    print("second")
}
