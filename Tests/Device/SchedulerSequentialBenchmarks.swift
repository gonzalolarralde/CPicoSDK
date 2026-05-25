//% -- test yaml
//% name: SchedulerSequentialBenchmarks
//% timeout: 5s
//% buildType: Release
//% concurrency: false
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 5000
//% -----------

import CPicoSDK

/// Goal: capture the raw single-thread baseline for the same fixed-cost spin
/// unit used by scheduler throughput benchmarks, without Swift task scheduling.
func sequentialBusyWorkThroughputBaseline() throws {
    let durationUs: UInt64 = 700_000
    let startedUs = time_us_64()
    let deadline = startedUs &+ durationUs
    var units: UInt32 = 0
    var checksum: UInt32 = 1

    while time_us_64() < deadline {
        checksum = sequentialBenchmarkSpin(seed: checksum &+ units, rounds: 1_400)
        units += 1
    }

    let elapsedMs = (time_us_64() &- startedUs) / 1_000
    let unitsPerSecond = elapsedMs > 0 ? UInt64(units) * 1_000 / elapsedMs : 0
    let core = UInt32(get_core_num() & 1)
    let rawLine = "units=\(units), elapsedMs=\(elapsedMs), core=\(core), checksum=\(checksum)"

    deviceDiagnostic("bench-sequential-throughput")
    deviceDiagnostic("  raw: \(rawLine)")
    deviceDiagnostic("  score workPerSecond=\(unitsPerSecond) (higher is better)")
    logScore("bench-sequential-throughput", rawLine, "workPerSecond", unitsPerSecond, "(higher is better)")

    try deviceExpect(units > 0, "sequential benchmark recorded no work units")
    try deviceExpect(core == 0, "sequential benchmark unexpectedly ran off core0")
}

private func sequentialBenchmarkSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 13
    }
    return value
}
