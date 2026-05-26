//% -- test yaml
//% name: CPUStatsUsageBehavior
//% timeout: 14s
//% buildType: Debug
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT, CPUMetrics]
//% alts:
//%   - name: singleCore
//%     swiftDefines: [CPU_STATS_SINGLE_CORE]
//%   - name: multicore
//%     swiftDefines: [CPU_STATS_MULTICORE]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 14000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let cpuStatsBehaviorLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct CPUStatsBehaviorCounters {
    var phase: UInt8 = 0
    var workerDone: UInt32 = 0
    var checksum: UInt32 = 0

    var core0Reports: UInt32 = 0
    var core1Reports: UInt32 = 0
    var idleCore0Reports: UInt32 = 0
    var idleCore1Reports: UInt32 = 0
    var highTaskReports: UInt32 = 0

    var maxCore0IdlePercentX100: UInt64 = 0
    var maxCore1IdlePercentX100: UInt64 = 0
    var maxTaskPercentX100: UInt64 = 0
}

private nonisolated(unsafe) var cpuStatsBehaviorCounters = CPUStatsBehaviorCounters()

func cpuUsageEventsReflectActiveCoresAndLoad() async throws {
    #if CPU_STATS_MULTICORE
    ConcurrencyRuntime.startMulticore()
    let expectsCore1 = true
    #else
    let expectsCore1 = false
    #endif

    guard let usageEvents = CPUStats.usageEvents() else {
        try deviceExpect(false, "CPUStats.usageEvents() was unavailable with CPUMetrics enabled")
        return
    }

    resetCPUStatsBehaviorCounters()

    let consumer = Task {
        var iterator = usageEvents.makeAsyncIterator()
        while let report = await iterator.next() {
            recordCPUStatsBehaviorReport(report)
        }
    }

    setCPUStatsBehaviorPhase(1)
    let idleObserved = await waitForCPUStatsBehaviorCondition(timeoutMs: 4_000) {
        let snapshot = withCPUStatsBehaviorLock { cpuStatsBehaviorCounters }
        if expectsCore1 {
            return snapshot.idleCore0Reports > 0 && snapshot.idleCore1Reports > 0
        }
        return snapshot.idleCore0Reports > 0
    }

    let idleSnapshot = withCPUStatsBehaviorLock { cpuStatsBehaviorCounters }
    try deviceExpect(idleObserved, "CPUStats did not report idle usage for expected core set")
    try deviceExpect(idleSnapshot.core0Reports > 0, "CPUStats did not report core0")
    if expectsCore1 {
        try deviceExpect(idleSnapshot.core1Reports > 0, "CPUStats did not report core1 after multicore start")
    } else {
        try deviceExpect(idleSnapshot.core1Reports == 0, "CPUStats reported core1 while multicore was disabled")
    }

    setCPUStatsBehaviorPhase(2)
    let workerCount: UInt32 = expectsCore1 ? 4 : 1
    for workerID in UInt32(0)..<workerCount {
        Task {
            await cpuStatsBehaviorBusyWorker(id: workerID, durationUs: 1_250_000)
        }
    }

    let highObserved = await waitForCPUStatsBehaviorCondition(timeoutMs: 5_000) {
        withCPUStatsBehaviorLock {
            cpuStatsBehaviorCounters.highTaskReports > 0
                && cpuStatsBehaviorCounters.workerDone == workerCount
        }
    }

    consumer.cancel()

    let finalSnapshot = withCPUStatsBehaviorLock { cpuStatsBehaviorCounters }
    let rawLine = "mode=\(expectsCore1 ? "multicore" : "singleCore"), reports=\(finalSnapshot.core0Reports)/\(finalSnapshot.core1Reports), idleReports=\(finalSnapshot.idleCore0Reports)/\(finalSnapshot.idleCore1Reports), maxIdleX100=\(finalSnapshot.maxCore0IdlePercentX100)/\(finalSnapshot.maxCore1IdlePercentX100), maxTaskX100=\(finalSnapshot.maxTaskPercentX100), checksum=\(finalSnapshot.checksum)"
    deviceDiagnostic("cpu-stats-usage-behavior")
    deviceDiagnostic("  raw: \(rawLine)")
    logScore("cpu-stats-usage-behavior", rawLine, "maxTaskPercentX100", finalSnapshot.maxTaskPercentX100, "(higher during busy phase is better)")

    try deviceExpect(highObserved, "CPUStats did not report high task usage under CPU pressure")
    try deviceExpect(finalSnapshot.maxTaskPercentX100 >= 5_000, "CPUStats busy phase task usage was too low")
}

private func recordCPUStatsBehaviorReport(_ report: CPUStats) {
    withCPUStatsBehaviorLock {
        let total = report.totalTime
        let idlePercentX100 = total > 0 ? report.idleUsageTime * 10_000 / total : 0
        let taskPercentX100 = total > 0 ? report.taskUsageTime * 10_000 / total : 0

        if taskPercentX100 > cpuStatsBehaviorCounters.maxTaskPercentX100 {
            cpuStatsBehaviorCounters.maxTaskPercentX100 = taskPercentX100
        }

        switch report.core {
        case .core0:
            cpuStatsBehaviorCounters.core0Reports += 1
            if idlePercentX100 > cpuStatsBehaviorCounters.maxCore0IdlePercentX100 {
                cpuStatsBehaviorCounters.maxCore0IdlePercentX100 = idlePercentX100
            }
            if cpuStatsBehaviorCounters.phase == 1 && idlePercentX100 >= 1_000 {
                cpuStatsBehaviorCounters.idleCore0Reports += 1
            }
        case .core1:
            cpuStatsBehaviorCounters.core1Reports += 1
            if idlePercentX100 > cpuStatsBehaviorCounters.maxCore1IdlePercentX100 {
                cpuStatsBehaviorCounters.maxCore1IdlePercentX100 = idlePercentX100
            }
            if cpuStatsBehaviorCounters.phase == 1 && idlePercentX100 >= 1_000 {
                cpuStatsBehaviorCounters.idleCore1Reports += 1
            }
        }

        if cpuStatsBehaviorCounters.phase == 2 && taskPercentX100 >= 5_000 {
            cpuStatsBehaviorCounters.highTaskReports += 1
        }
    }
}

private func cpuStatsBehaviorBusyWorker(id: UInt32, durationUs: UInt64) async {
    let deadline = time_us_64() &+ durationUs
    var checksum = id &+ 1
    var units: UInt32 = 0

    while time_us_64() < deadline {
        checksum = cpuStatsBehaviorSpin(seed: checksum &+ units, rounds: 1_300)
        units += 1
        await Task.yield()
    }

    withCPUStatsBehaviorLock {
        cpuStatsBehaviorCounters.workerDone += 1
        cpuStatsBehaviorCounters.checksum &+= checksum
    }
}

private func setCPUStatsBehaviorPhase(_ phase: UInt8) {
    withCPUStatsBehaviorLock {
        cpuStatsBehaviorCounters.phase = phase
    }
}

private func resetCPUStatsBehaviorCounters() {
    withCPUStatsBehaviorLock {
        cpuStatsBehaviorCounters = CPUStatsBehaviorCounters()
    }
}

private func withCPUStatsBehaviorLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(cpuStatsBehaviorLock)
    defer {
        mutex_exit(cpuStatsBehaviorLock)
    }
    return body()
}

private func waitForCPUStatsBehaviorCondition(timeoutMs: UInt64, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ timeoutMs &* 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(ms: 20)
    }
    return condition()
}

private func cpuStatsBehaviorSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 13
    }
    return value
}
