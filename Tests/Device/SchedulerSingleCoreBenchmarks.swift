//% -- test yaml
//% name: SchedulerSingleCoreBenchmarks
//% timeout: 8s
//% buildType: Release
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 8000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let singleCoreBenchmarkLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct SingleCoreBenchmarkCounters {
    var done: UInt32 = 0
    var units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private nonisolated(unsafe) var singleCoreBenchmarkCounters = SingleCoreBenchmarkCounters()

/// Goal: capture a single-core throughput baseline before any test in this file
/// can start core1. This benchmark records how many cooperative busy-work units
/// core0 completes in a fixed window and verifies core1 remains unused.
func singleCoreBusyWorkThroughputBaseline() async throws {
    resetSingleCoreBenchmarkCounters()

    let workerCount: UInt32 = 4
    let durationUs: UInt64 = 700_000
    let startedUs = time_us_64()

    for workerID in UInt32(0)..<workerCount {
        Task {
            await singleCoreBenchmarkWorker(id: workerID, durationUs: durationUs)
        }
    }

    let completed = await waitForSingleCoreBenchmarkCondition(timeoutMs: 2_000) {
        withSingleCoreBenchmarkLock {
            singleCoreBenchmarkCounters.done == workerCount
        }
    }

    let elapsedMs = (time_us_64() &- startedUs) / 1_000
    let snapshot = withSingleCoreBenchmarkLock { singleCoreBenchmarkCounters }
    let unitsPerSecond = elapsedMs > 0 ? UInt64(snapshot.units) * 1_000 / elapsedMs : 0

    // Diagnostic fields: workers is the number of tasks, units is completed
    // fixed-cost spin chunks, ups is units/sec, elapsed is wall time in ms,
    // c0/c1 are observed execution-core hits, and sum prevents dead-code loss.
    // score is units/sec, so higher is better.
    let rawLine = "workers=\(workerCount), units=\(snapshot.units), elapsedMs=\(elapsedMs), coreHits=\(snapshot.core0Hits)/\(snapshot.core1Hits), checksum=\(snapshot.checksum)"
    deviceDiagnostic("bench-single-throughput")
    deviceDiagnostic("  raw: \(rawLine)")
    deviceDiagnostic("  score workPerSecond=\(unitsPerSecond) (higher is better)")
    logScore("bench-single-throughput", rawLine, "workPerSecond", unitsPerSecond, "(higher is better)")

    try deviceExpect(completed, "single-core benchmark workers did not complete")
    try deviceExpect(snapshot.done == workerCount, "single-core benchmark lost worker completions")
    try deviceExpect(snapshot.units > 0, "single-core benchmark did not record work units")
    try deviceExpect(snapshot.core0Hits > 0, "single-core benchmark never observed core0 work")
    try deviceExpect(snapshot.core1Hits == 0, "single-core benchmark observed core1 before multicore startup")
}

private func singleCoreBenchmarkWorker(id: UInt32, durationUs: UInt64) async {
    let deadline = time_us_64() &+ durationUs
    var checksum = id &+ 1
    var units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0

    while time_us_64() < deadline {
        checksum = singleCoreBenchmarkSpin(seed: checksum &+ units, rounds: 1_400)
        units += 1
        if (get_core_num() & 1) == 0 {
            core0Hits += 1
        } else {
            core1Hits += 1
        }
        await Task.yield()
    }

    withSingleCoreBenchmarkLock {
        singleCoreBenchmarkCounters.done += 1
        singleCoreBenchmarkCounters.units += units
        singleCoreBenchmarkCounters.core0Hits += core0Hits
        singleCoreBenchmarkCounters.core1Hits += core1Hits
        singleCoreBenchmarkCounters.checksum &+= checksum
    }
}

private func resetSingleCoreBenchmarkCounters() {
    withSingleCoreBenchmarkLock {
        singleCoreBenchmarkCounters = SingleCoreBenchmarkCounters()
    }
}

private func withSingleCoreBenchmarkLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(singleCoreBenchmarkLock)
    defer {
        mutex_exit(singleCoreBenchmarkLock)
    }
    return body()
}

private func waitForSingleCoreBenchmarkCondition(timeoutMs: UInt64, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ timeoutMs &* 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

private func singleCoreBenchmarkSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 13
    }
    return value
}
