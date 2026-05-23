//% -- test yaml
//% name: DeviceExpectPass
//% timeout: 5s
//% concurrency: false
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   stdout:
//%     equals: "expect-ok\n"
//%   durationMs:
//%     min: 0
//%     max: 5000
//% -----------

import CPicoSDK

func deviceExpectationPasses() throws {
    try deviceExpect(7 * 6 == 42, "multiplication check failed")
    print("expect-ok")
}
