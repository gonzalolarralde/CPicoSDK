//% -- test yaml
//% name: CPUStatsUsageEvents
//% timeout: 8s
//% concurrency: false
//% traits:
//%   add: [StdIO_RTT, CPUMetrics]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 8000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let cpuStatsTestLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct CPUStatsStreamCounters {
    var sampleCount: UInt32 = 0
    var sampleCore0Hits: UInt32 = 0
    var sampleCore1Hits: UInt32 = 0
    var workerDone: UInt32 = 0
    var workerCore0Hits: UInt32 = 0
    var workerCore1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private nonisolated(unsafe) var cpuStatsStreamCounters = CPUStatsStreamCounters()

/// Goal: validate the combined CPU metrics stream. A single subscription to
/// `CPUStats.usageEvents()` should receive reports tagged with every active
/// scheduler core, while keeping the existing per-sample `core` identity.
func combinedCPUUsageEventsReportsActiveCores() async throws {
    guard let usageEvents = CPUStats.usageEvents() else {
        try deviceExpect(false, "CPU metrics stream was not available with CPUMetrics enabled")
        return
    }

    resetCPUStatsStreamCounters()

    Task {
        var iterator = usageEvents.makeAsyncIterator()
        while let report = await iterator.next() {
            recordCPUStatsReport(report)
            let snapshot = withCPUStatsTestLock { cpuStatsStreamCounters }
            if snapshot.sampleCore0Hits > 0 && snapshot.sampleCore1Hits > 0 {
                break
            }
        }
    }

    for workerID in UInt32(0)..<8 {
        Task {
            await cpuStatsPressureWorker(id: workerID, runForUs: 2_500_000)
        }
    }

    let observedBothSampleCores = await waitForCPUStatsCondition(timeoutMs: 6_000) {
        let snapshot = withCPUStatsTestLock { cpuStatsStreamCounters }
        return snapshot.sampleCore0Hits > 0 && snapshot.sampleCore1Hits > 0
    }

    let workersDone = await waitForCPUStatsCondition(timeoutMs: 1_500) {
        withCPUStatsTestLock { cpuStatsStreamCounters.workerDone == 8 }
    }

    let snapshot = withCPUStatsTestLock { cpuStatsStreamCounters }
    print("cpu-stats samples=\(snapshot.sampleCount) s0=\(snapshot.sampleCore0Hits) s1=\(snapshot.sampleCore1Hits) wdone=\(snapshot.workerDone) w0=\(snapshot.workerCore0Hits) w1=\(snapshot.workerCore1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(observedBothSampleCores, "combined CPU metrics stream did not report both active cores")
    try deviceExpect(workersDone, "CPU metrics pressure workers did not complete")
    try deviceExpect(snapshot.workerCore0Hits > 0, "CPU metrics pressure did not execute on core0")
    try deviceExpect(snapshot.workerCore1Hits > 0, "CPU metrics pressure did not execute on core1")
}

/// Goal: validate the public CPU and memory stats print surface. The test waits
/// for one real scheduler CPU report, checks that its description and memory
/// snapshot are internally coherent, then exercises both `CPUStats.print()` and
/// `MemoryStats.print()` so their log formats stay usable together.
func cpuAndMemoryStatsPrintConsistently() async throws {
    guard let usageEvents = CPUStats.usageEvents() else {
        try deviceExpect(false, "CPU metrics stream was not available with CPUMetrics enabled")
        return
    }

    Task {
        await cpuStatsPressureWorker(id: 100, runForUs: 1_300_000)
    }

    var iterator = usageEvents.makeAsyncIterator()
    let deadline = time_us_64() &+ 3_500_000
    var report: CPUStats?

    while time_us_64() < deadline {
        if let nextReport = await iterator.next() {
            report = nextReport
            break
        }
        await Task.yield()
    }

    guard let report else {
        try deviceExpect(false, "CPU metrics stream did not produce a report for print validation")
        return
    }

    let description = report.description
    try deviceExpect(stringContains(description, "CPU(core: "), "CPU stats description did not include the core")
    try deviceExpect(stringContains(description, "task="), "CPU stats description did not include task usage")
    try deviceExpect(stringContains(description, "irq="), "CPU stats description did not include interrupt usage")
    try deviceExpect(stringContains(description, "idle="), "CPU stats description did not include idle usage")
    try deviceExpect(stringContains(description, "total_us="), "CPU stats description did not include total time")
    try deviceExpect(report.totalTime > 0, "CPU stats report had no measured time")
    try deviceExpect(report.taskUsageTime + report.interruptUsageTime + report.idleUsageTime == report.totalTime, "CPU stats time fields did not add up")

    guard let sramStats = report.memoryStats[.sram] else {
        try deviceExpect(false, "CPU stats report did not include SRAM memory stats")
        return
    }

    let memoryDescription = sramStats.description
    try deviceExpect(stringContains(memoryDescription, "SRAM Memory:"), "memory stats description did not include memory type")
    try deviceExpect(stringContains(memoryDescription, "used="), "memory stats description did not include used bytes")
    try deviceExpect(stringContains(memoryDescription, "freed="), "memory stats description did not include freed bytes")
    try deviceExpect(stringContains(memoryDescription, "untouched="), "memory stats description did not include untouched bytes")
    try deviceExpect(stringContains(memoryDescription, "total_free="), "memory stats description did not include total free bytes")
    try deviceExpect(stringContains(memoryDescription, "total="), "memory stats description did not include total bytes")
    try deviceExpect(sramStats.used + sramStats.totalFree == sramStats.total, "memory stats total fields did not add up")
    try deviceExpect(sramStats.total > 0, "memory stats total was zero")

    print("stats-print-start")
    report.print(includeMemoryStats: true)
    MemoryStats.print()
    print("stats-print-end")
}

private func cpuStatsPressureWorker(id: UInt32, runForUs: UInt64) async {
    let deadline = time_us_64() &+ runForUs
    var checksum = id &+ 1

    while time_us_64() < deadline {
        checksum = cpuStatsSpin(seed: checksum, rounds: 4_000)
        recordCPUStatsWorkerCore()
        await Task.yield()
    }

    withCPUStatsTestLock {
        cpuStatsStreamCounters.workerDone += 1
        cpuStatsStreamCounters.checksum &+= checksum
    }
}

private func recordCPUStatsReport(_ report: CPUStats) {
    withCPUStatsTestLock {
        cpuStatsStreamCounters.sampleCount += 1
        switch report.core {
        case .core0:
            cpuStatsStreamCounters.sampleCore0Hits += 1
        case .core1:
            cpuStatsStreamCounters.sampleCore1Hits += 1
        }
    }
}

private func recordCPUStatsWorkerCore() {
    withCPUStatsTestLock {
        if (get_core_num() & 1) == 0 {
            cpuStatsStreamCounters.workerCore0Hits += 1
        } else {
            cpuStatsStreamCounters.workerCore1Hits += 1
        }
    }
}

private func resetCPUStatsStreamCounters() {
    withCPUStatsTestLock {
        cpuStatsStreamCounters = CPUStatsStreamCounters()
    }
}

private func withCPUStatsTestLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(cpuStatsTestLock)
    defer {
        mutex_exit(cpuStatsTestLock)
    }
    return body()
}

private func waitForCPUStatsCondition(timeoutMs: UInt64, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ timeoutMs &* 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

private func cpuStatsSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 13
    }
    return value
}

private func stringContains(_ string: String, _ substring: String) -> Bool {
    let haystack = Array(string.utf8)
    let needle = Array(substring.utf8)

    if needle.isEmpty {
        return true
    }

    if needle.count > haystack.count {
        return false
    }

    let lastStart = haystack.count - needle.count
    for start in 0...lastStart {
        var matched = true
        for offset in 0..<needle.count {
            if haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
        }
        if matched {
            return true
        }
    }
    return false
}
