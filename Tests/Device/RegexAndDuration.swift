//% -- test yaml
//% name: RegexAndDuration
//% timeout: 5s
//% concurrency: false
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   stdout:
//%     regex: "^tick-[0-9]+\\n$"
//%   durationMs:
//%     min: 10
//%     max: 5000
//% -----------

import CPicoSDK

func regexAndDuration() {
    sleep_ms(10)
    print("tick-123")
}
