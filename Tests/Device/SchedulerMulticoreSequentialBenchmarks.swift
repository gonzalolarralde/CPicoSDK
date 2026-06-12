//% -- test yaml
//% name: SchedulerMulticoreSequentialBenchmarks
//% timeout: 5s
//% buildType: Release
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 5000
//% -----------

import CPicoSDK
import CPicoConcurrency

@_silgen_name("cshims_benchmark_multicore_sequential")
private func cshimsBenchmarkMulticoreSequential(
    _ durationUs: UInt64,
    _ rounds: UInt32,
    _ core0Units: UnsafeMutablePointer<UInt32>,
    _ core1Units: UnsafeMutablePointer<UInt32>,
    _ core0Checksum: UnsafeMutablePointer<UInt32>,
    _ core1Checksum: UnsafeMutablePointer<UInt32>,
    _ elapsedUs: UnsafeMutablePointer<UInt64>
)

/// Goal: capture raw dual-core continuous throughput for the same fixed-cost
/// spin unit used by scheduler throughput benchmarks, without Swift task
/// scheduling. This is the hardware/runtime ceiling the scheduled multicore
/// score can be compared against.
func multicoreSequentialBusyWorkThroughputBaseline() throws {
    var core0Units: UInt32 = 0
    var core1Units: UInt32 = 0
    var core0Checksum: UInt32 = 0
    var core1Checksum: UInt32 = 0
    var elapsedUs: UInt64 = 0

    cshimsBenchmarkMulticoreSequential(
        700_000,
        1_400,
        &core0Units,
        &core1Units,
        &core0Checksum,
        &core1Checksum,
        &elapsedUs
    )

    let elapsedMs = elapsedUs / 1_000
    let totalUnits = core0Units &+ core1Units
    let unitsPerSecond = elapsedMs > 0 ? UInt64(totalUnits) * 1_000 / elapsedMs : 0
    let minUnits = min(core0Units, core1Units)
    let maxUnits = max(core0Units, core1Units)
    let balanceScore = maxUnits > 0 ? UInt64(minUnits) * 1_000 / UInt64(maxUnits) : 0
    let rawLine = "units=\(totalUnits), elapsedMs=\(elapsedMs), coreUnits=\(core0Units)/\(core1Units), checksum=\(core0Checksum)/\(core1Checksum)"

    deviceDiagnostic("bench-multicore-sequential-throughput")
    deviceDiagnostic("  raw: \(rawLine)")
    deviceDiagnostic("  score workPerSecond=\(unitsPerSecond) (higher is better)")
    deviceDiagnostic("  score coreBalance=\(balanceScore)/1000 (closest to 1000 is best)")
    logScore("bench-multicore-sequential-throughput", rawLine, "workPerSecond", unitsPerSecond, "(higher is better)")
    logScore("bench-multicore-sequential-throughput", rawLine, "coreBalance", balanceScore, "/1000 (closest to 1000 is best)")

    try deviceExpect(core0Units > 0, "multicore sequential benchmark recorded no core0 work")
    try deviceExpect(core1Units > 0, "multicore sequential benchmark recorded no core1 work")
}
