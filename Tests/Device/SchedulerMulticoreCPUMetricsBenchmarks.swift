//% -- test yaml
//% name: SchedulerMulticoreCPUMetricsBenchmarks
//% timeout: 25s
//% buildType: Release
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT]
//% alts:
//%   - name: baseline
//%     swiftDefines: [CPU_MEASUREMENT_BASELINE]
//%   - name: cpuMetrics
//%     traits:
//%       add: [CPUMetrics]
//%     swiftDefines: [CPU_MEASUREMENT_ENABLED]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 25000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let cpuMeasurementBenchmarkLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct CPUMeasurementThroughputCounters {
    var done: UInt32 = 0
    var units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private nonisolated(unsafe) var cpuMeasurementThroughputCounters = CPUMeasurementThroughputCounters()

func multicoreBusyWorkThroughputWithAndWithoutCPUMetrics() async throws {
    ConcurrencyRuntime.startMulticore()
    resetCPUMeasurementThroughputCounters()

    let workerCount: UInt32 = 8
    let durationUs: UInt64 = 700_000
    let startedUs = time_us_64()

    for workerID in UInt32(0)..<workerCount {
        Task {
            await cpuMeasurementThroughputWorker(id: workerID, durationUs: durationUs)
        }
    }

    let completed = await waitForCPUMeasurementBenchmarkCondition(timeoutMs: 2_500) {
        withCPUMeasurementBenchmarkLock {
            cpuMeasurementThroughputCounters.done == workerCount
        }
    }

    let elapsedMs = (time_us_64() &- startedUs) / 1_000
    let snapshot = withCPUMeasurementBenchmarkLock { cpuMeasurementThroughputCounters }
    let unitsPerSecond = elapsedMs > 0 ? UInt64(snapshot.units) * 1_000 / elapsedMs : 0
    let smallerCoreHits = snapshot.core0Hits < snapshot.core1Hits ? snapshot.core0Hits : snapshot.core1Hits
    let largerCoreHits = snapshot.core0Hits > snapshot.core1Hits ? snapshot.core0Hits : snapshot.core1Hits
    let balanceScore = largerCoreHits > 0 ? smallerCoreHits * 1_000 / largerCoreHits : 0

    #if CPU_MEASUREMENT_ENABLED
    let mode = "cpuMetrics"
    #else
    let mode = "baseline"
    #endif

    let rawLine = "mode=\(mode), workers=\(workerCount), units=\(snapshot.units), elapsedMs=\(elapsedMs), coreHits=\(snapshot.core0Hits)/\(snapshot.core1Hits), checksum=\(snapshot.checksum)"
    deviceDiagnostic("bench-cpu-measurement-throughput")
    deviceDiagnostic("  raw: \(rawLine)")
    deviceDiagnostic("  score workPerSecond=\(unitsPerSecond) (higher is better)")
    deviceDiagnostic("  score coreBalance=\(balanceScore)/1000 (closest to 1000 is best)")
    logScore("bench-cpu-measurement-throughput", rawLine, "workPerSecond", unitsPerSecond, "mode=\(mode)")
    logScore("bench-cpu-measurement-throughput", rawLine, "coreBalance", balanceScore, "mode=\(mode) /1000")

    try deviceExpect(completed, "CPU measurement throughput workers did not complete")
    try deviceExpect(snapshot.units > 0, "CPU measurement throughput recorded no work")
    try deviceExpect(snapshot.core0Hits > 0, "CPU measurement throughput never observed core0 work")
    try deviceExpect(snapshot.core1Hits > 0, "CPU measurement throughput never observed core1 work")
}

private func cpuMeasurementThroughputWorker(id: UInt32, durationUs: UInt64) async {
    let deadline = time_us_64() &+ durationUs
    var checksum = id &+ 1
    var units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0

    while time_us_64() < deadline {
        checksum = cpuMeasurementBenchmarkSpin(seed: checksum &+ units, rounds: 1_400)
        units += 1
        if (get_core_num() & 1) == 0 {
            core0Hits += 1
        } else {
            core1Hits += 1
        }
        await Task.yield()
    }

    withCPUMeasurementBenchmarkLock {
        cpuMeasurementThroughputCounters.done += 1
        cpuMeasurementThroughputCounters.units += units
        cpuMeasurementThroughputCounters.core0Hits += core0Hits
        cpuMeasurementThroughputCounters.core1Hits += core1Hits
        cpuMeasurementThroughputCounters.checksum &+= checksum
    }
}

private func resetCPUMeasurementThroughputCounters() {
    withCPUMeasurementBenchmarkLock {
        cpuMeasurementThroughputCounters = CPUMeasurementThroughputCounters()
    }
}

private func withCPUMeasurementBenchmarkLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(cpuMeasurementBenchmarkLock)
    defer {
        mutex_exit(cpuMeasurementBenchmarkLock)
    }
    return body()
}

private func waitForCPUMeasurementBenchmarkCondition(timeoutMs: UInt64, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ timeoutMs &* 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

private func cpuMeasurementBenchmarkSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 13
    }
    return value
}
