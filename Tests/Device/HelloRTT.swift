//% -- test yaml
//% name: HelloRTT
//% timeout: 5s
//% concurrency: false
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   stdout:
//%     equals: "hello\n"
//%   durationMs:
//%     min: 0
//%     max: 5000
//% -----------

import CPicoSDK

func helloRTT() throws {
    print("hello")
    try deviceExpect(1 + 1 == 2, "integer arithmetic failed")
}
