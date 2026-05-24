//% -- test yaml
//% name: CPUStatsStreamMemoryChurn
//% timeout: 18s
//% concurrency: false
//% traits:
//%   add: [StdIO_RTT, CPUMetrics]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 18000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let cpuStatsChurnLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct CPUStatsChurnCounters {
    var reports: UInt32 = 0
    var workerDone: UInt32 = 0
    var checksum: UInt32 = 0
}

private nonisolated(unsafe) var cpuStatsChurnCounters = CPUStatsChurnCounters()

/// Goal: validate CPU metrics stream churn through public behavior only. The
/// test repeatedly creates combined `CPUStats.usageEvents()` streams, attaches
/// consumers, lets each consumer receive a report, then drops the consumers and
/// checks SRAM usage stays bounded. This targets retained continuations or
/// forwarding tasks without exposing internal subscription counters.
func cpuStatsStreamChurnKeepsMemoryBounded() async throws {
    ConcurrencyRuntime.startMulticore()

    resetCPUStatsChurnCounters()
    try await warmUpCPUStatsStream()

    let before = MemoryStats.sram
    let rounds: UInt32 = 4
    let streamsPerRound: UInt32 = 12
    var expectedReports: UInt32 = 0

    for round in UInt32(0)..<rounds {
        var consumers: [Task<Void, Never>] = []
        consumers.reserveCapacity(Int(streamsPerRound))

        for streamID in UInt32(0)..<streamsPerRound {
            guard let stream = CPUStats.usageEvents() else {
                try deviceExpect(false, "CPU metrics stream was not available with CPUMetrics enabled")
                return
            }

            let consumerID = round &* streamsPerRound &+ streamID
            consumers.append(Task {
                var iterator = stream.makeAsyncIterator()
                if let report = await iterator.next() {
                    recordCPUStatsChurnReport(report, consumerID: consumerID)
                }
            })
        }

        expectedReports &+= streamsPerRound
        Task {
            await cpuStatsChurnPressureWorker(id: round, runForUs: 1_500_000)
        }

        let reportsArrived = await waitForCPUStatsChurnCondition(timeoutMs: 3_500) {
            withCPUStatsChurnLock {
                cpuStatsChurnCounters.reports >= expectedReports
            }
        }

        for consumer in consumers {
            consumer.cancel()
        }
        for _ in 0..<8 {
            await Task.yield()
        }

        try deviceExpect(reportsArrived, "CPU metrics stream churn consumers did not receive reports")
    }

    Task {
        await cpuStatsChurnPressureWorker(id: 99, runForUs: 1_500_000)
    }
    _ = await waitForCPUStatsChurnCondition(timeoutMs: 2_500) {
        withCPUStatsChurnLock {
            cpuStatsChurnCounters.workerDone >= rounds &+ 1
        }
    }
    for _ in 0..<16 {
        await Task.yield()
    }

    let after = MemoryStats.sram
    let usedGrowth = after.used > before.used ? after.used - before.used : 0
    let freeLoss = before.totalFree > after.totalFree ? before.totalFree - after.totalFree : 0
    let snapshot = withCPUStatsChurnLock { cpuStatsChurnCounters }

    print("cpu-stats-stream-churn reports=\(snapshot.reports) workers=\(snapshot.workerDone) used=\(before.used)->\(after.used) free=\(before.totalFree)->\(after.totalFree) usedGrowth=\(usedGrowth) freeLoss=\(freeLoss) sum=\(snapshot.checksum)")

    try deviceExpect(snapshot.reports >= rounds &* streamsPerRound, "CPU metrics stream churn lost consumer reports")
    try deviceExpect(usedGrowth <= 4_096, "CPU metrics stream churn grew SRAM used bytes")
    try deviceExpect(freeLoss <= 8_192, "CPU metrics stream churn reduced SRAM total free bytes")
}

private func warmUpCPUStatsStream() async throws {
    guard let stream = CPUStats.usageEvents() else {
        try deviceExpect(false, "CPU metrics stream was not available with CPUMetrics enabled")
        return
    }

    let baselineReports = withCPUStatsChurnLock { cpuStatsChurnCounters.reports }
    let consumer = Task {
        var iterator = stream.makeAsyncIterator()
        if let report = await iterator.next() {
            recordCPUStatsChurnReport(report, consumerID: 0xffff)
        }
    }

    Task {
        await cpuStatsChurnPressureWorker(id: 0xffff, runForUs: 1_500_000)
    }

    let warmed = await waitForCPUStatsChurnCondition(timeoutMs: 3_500) {
        withCPUStatsChurnLock {
            cpuStatsChurnCounters.reports > baselineReports
        }
    }
    consumer.cancel()
    for _ in 0..<8 {
        await Task.yield()
    }

    try deviceExpect(warmed, "CPU metrics stream warmup did not receive a report")
    resetCPUStatsChurnCounters()
}

private func cpuStatsChurnPressureWorker(id: UInt32, runForUs: UInt64) async {
    let deadline = time_us_64() &+ runForUs
    var checksum = id &+ 1

    while time_us_64() < deadline {
        checksum = cpuStatsChurnSpin(seed: checksum, rounds: 4_000)
        await Task.yield()
    }

    withCPUStatsChurnLock {
        cpuStatsChurnCounters.workerDone &+= 1
        cpuStatsChurnCounters.checksum &+= checksum
    }
}

private func recordCPUStatsChurnReport(_ report: CPUStats, consumerID: UInt32) {
    withCPUStatsChurnLock {
        cpuStatsChurnCounters.reports &+= 1
        cpuStatsChurnCounters.checksum &+= UInt32(report.totalTime & 0xffff)
        cpuStatsChurnCounters.checksum &+= UInt32(report.core.rawValue)
        cpuStatsChurnCounters.checksum &+= consumerID
    }
}

private func resetCPUStatsChurnCounters() {
    withCPUStatsChurnLock {
        cpuStatsChurnCounters = CPUStatsChurnCounters()
    }
}

private func withCPUStatsChurnLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(cpuStatsChurnLock)
    defer {
        mutex_exit(cpuStatsChurnLock)
    }
    return body()
}

private func waitForCPUStatsChurnCondition(timeoutMs: UInt64, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ timeoutMs &* 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

private func cpuStatsChurnSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 13
    }
    return value
}
