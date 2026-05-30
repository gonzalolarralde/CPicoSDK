//% -- test yaml
//% name: IRQAllocatorWarning
//% timeout: 5s
//% concurrency: false
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   stdout:
//%     regex: "(?s).*\\[CPicoSDK\\] malloc/calloc/realloc/free was called from IRQ context; .*GuardIRQAllocations trait.*"
//%   durationMs:
//%     min: 0
//%     max: 5000
//% -----------

import CPicoSDK

private nonisolated(unsafe) var irqAllocationAlarmFired: UInt32 = 0

@c
private func irqAllocationAlarmCallback(_: alarm_id_t, _: UnsafeMutableRawPointer?) -> Int64 {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
    pointer.storeBytes(of: UInt32(0x1234_5678), as: UInt32.self)
    pointer.deallocate()
    irqAllocationAlarmFired = 1
    return 0
}

func irqAllocatorWarningIsPrinted() throws {
    irqAllocationAlarmFired = 0
    let alarm = add_alarm_in_ms(10, irqAllocationAlarmCallback, nil, true)
    try deviceExpect(alarm > 0, "failed to schedule IRQ allocation alarm")

    let deadline = time_us_64() &+ 1_000_000
    while irqAllocationAlarmFired == 0 && time_us_64() < deadline {
        tight_loop_contents()
    }

    try deviceExpect(irqAllocationAlarmFired != 0, "IRQ allocation alarm did not fire")
    sleep_ms(20)
}
