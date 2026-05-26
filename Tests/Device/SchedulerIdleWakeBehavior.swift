//% -- test yaml
//% name: SchedulerIdleWakeBehavior
//% timeout: 14s
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT, CPUMetrics]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 14000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let idleWakeLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct IdleWakeCounters {
    var reports: UInt32 = 0
    var core0Reports: UInt32 = 0
    var core1Reports: UInt32 = 0
    var idleCore0Reports: UInt32 = 0
    var idleCore1Reports: UInt32 = 0
    var maxCore0IdlePercentX100: UInt32 = 0
    var maxCore1IdlePercentX100: UInt32 = 0
    var workerDone: UInt32 = 0
    var workerCore0Hits: UInt32 = 0
    var workerCore1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private nonisolated(unsafe) var idleWakeCounters = IdleWakeCounters()

/// Goal: validate low-activity scheduler behavior from public signals. After
/// multicore startup, the scheduler is left mostly quiet long enough for CPU
/// metrics to observe idle-heavy windows on both cores. The test then verifies
/// alarm-backed delayed work wakes promptly and both cores still run work.
func idleWindowReportsBothCoresAndDelayedWorkWakesScheduler() async throws {
    ConcurrencyRuntime.startMulticore()

    guard let usageEvents = CPUStats.usageEvents() else {
        try deviceExpect(false, "CPU metrics stream was not available with CPUMetrics enabled")
        return
    }

    resetIdleWakeCounters()

    let consumer = Task {
        var iterator = usageEvents.makeAsyncIterator()
        while let report = await iterator.next() {
            recordIdleWakeReport(report)
            let snapshot = withIdleWakeLock { idleWakeCounters }
            if snapshot.idleCore0Reports > 0 && snapshot.idleCore1Reports > 0 {
                break
            }
        }
    }

    let idleSleepStartedUs = time_us_64()
    print("idle-window phase=before-idle-sleep")
    try? await Task.sleep(us: 1_250_000)
    let idleSleepElapsedUs = time_us_64() &- idleSleepStartedUs
    print("idle-window phase=after-idle-sleep elapsedUs=\(idleSleepElapsedUs)")

    let observedIdleBothCores = await waitForIdleWakeCondition(timeoutMs: 2_500) {
        let snapshot = withIdleWakeLock { idleWakeCounters }
        return snapshot.idleCore0Reports > 0 && snapshot.idleCore1Reports > 0
    }

    let delayedWakeStartedUs = time_us_64()
    print("idle-window phase=before-post-idle-delay")
    try? await Task.sleep(us: 40_000)
    let delayedWakeElapsedUs = time_us_64() &- delayedWakeStartedUs
    print("idle-window phase=after-post-idle-delay elapsedUs=\(delayedWakeElapsedUs)")

    for workerID in UInt32(0)..<6 {
        Task {
            await idleWakeWorker(id: workerID, runForUs: 180_000)
        }
    }

    let workersDone = await waitForIdleWakeCondition(timeoutMs: 1_500) {
        withIdleWakeLock { idleWakeCounters.workerDone == 6 }
    }

    let snapshot = withIdleWakeLock { idleWakeCounters }
    consumer.cancel()
    print("idle-window reports=\(snapshot.reports) cores=\(snapshot.core0Reports)/\(snapshot.core1Reports) idleReports=\(snapshot.idleCore0Reports)/\(snapshot.idleCore1Reports) idlePctX100=\(snapshot.maxCore0IdlePercentX100)/\(snapshot.maxCore1IdlePercentX100) idleSleepUs=\(idleSleepElapsedUs) wakeUs=\(delayedWakeElapsedUs) wdone=\(snapshot.workerDone) w0=\(snapshot.workerCore0Hits) w1=\(snapshot.workerCore1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(idleSleepElapsedUs >= 1_150_000, "idle-window sleep woke substantially early")
    try deviceExpect(idleSleepElapsedUs < 2_500_000, "idle-window sleep did not wake promptly")
    try deviceExpect(observedIdleBothCores, "idle window did not report idle time on both scheduler cores")
    try deviceExpect(delayedWakeElapsedUs >= 35_000, "delayed work woke substantially early after idle")
    try deviceExpect(delayedWakeElapsedUs < 250_000, "delayed work did not wake promptly after idle")
    try deviceExpect(workersDone, "post-idle workers did not complete")
    try deviceExpect(snapshot.workerCore0Hits > 0, "post-idle work did not execute on core0")
    try deviceExpect(snapshot.workerCore1Hits > 0, "post-idle work did not execute on core1")
}

private func recordIdleWakeReport(_ report: CPUStats) {
    withIdleWakeLock {
        idleWakeCounters.reports += 1
        let idlePercentX100 = report.totalTime > 0
            ? UInt32((report.idleUsageTime * 10_000) / report.totalTime)
            : 0

        switch report.core {
        case .core0:
            idleWakeCounters.core0Reports += 1
            if idlePercentX100 > idleWakeCounters.maxCore0IdlePercentX100 {
                idleWakeCounters.maxCore0IdlePercentX100 = idlePercentX100
            }
            if report.idleUsageTime > 0 && idlePercentX100 >= 5_000 {
                idleWakeCounters.idleCore0Reports += 1
            }
        case .core1:
            idleWakeCounters.core1Reports += 1
            if idlePercentX100 > idleWakeCounters.maxCore1IdlePercentX100 {
                idleWakeCounters.maxCore1IdlePercentX100 = idlePercentX100
            }
            if report.idleUsageTime > 0 && idlePercentX100 >= 5_000 {
                idleWakeCounters.idleCore1Reports += 1
            }
        }
    }
}

private func idleWakeWorker(id: UInt32, runForUs: UInt64) async {
    let deadline = time_us_64() &+ runForUs
    var checksum = id &+ 1

    while time_us_64() < deadline {
        checksum = idleWakeSpin(seed: checksum, rounds: 4_000)
        withIdleWakeLock {
            if (get_core_num() & 1) == 0 {
                idleWakeCounters.workerCore0Hits += 1
            } else {
                idleWakeCounters.workerCore1Hits += 1
            }
        }
        await Task.yield()
    }

    withIdleWakeLock {
        idleWakeCounters.workerDone += 1
        idleWakeCounters.checksum &+= checksum
    }
}

private func resetIdleWakeCounters() {
    withIdleWakeLock {
        idleWakeCounters = IdleWakeCounters()
    }
}

private func withIdleWakeLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(idleWakeLock)
    defer {
        mutex_exit(idleWakeLock)
    }
    return body()
}

private func waitForIdleWakeCondition(timeoutMs: UInt64, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ timeoutMs &* 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

private func idleWakeSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 13
    }
    return value
}
