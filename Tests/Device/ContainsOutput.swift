//% -- test yaml
//% name: ContainsOutput
//% timeout: 5s
//% concurrency: false
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   stdout:
//%     contains: "middle"
//%   durationMs:
//%     min: 0
//%     max: 5000
//% -----------

import CPicoSDK

func containsOutput() {
    print("begin")
    print("middle")
    print("end")
}
