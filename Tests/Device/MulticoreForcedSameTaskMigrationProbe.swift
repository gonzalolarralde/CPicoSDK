//% -- test yaml
//% name: MulticoreForcedSameTaskMigrationProbe
//% timeout: 5s
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

private nonisolated(unsafe) let forcedMigrationLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct ForcedMigrationCounters {
    var observations: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var initialCore: UInt32 = UInt32.max
    var continuationWaits: UInt32 = 0
    var continuationResumes: UInt32 = 0
    var resumeCore0Hits: UInt32 = 0
    var resumeCore1Hits: UInt32 = 0
    var migrationDone: UInt32 = 0
    var pressureStarted: UInt32 = 0
    var pressureInitialCoreStarted: UInt32 = 0
    var pressureOtherCoreStarted: UInt32 = 0
    var pressureInitialCoreBurning: UInt32 = 0
    var pressureDone: UInt32 = 0
    var pressureGateOpen: Bool = false
    var activeSegments: UInt32 = 0
    var overlapViolations: UInt32 = 0
    var checksum: UInt32 = 0
}

private nonisolated(unsafe) var forcedMigrationCounters = ForcedMigrationCounters()
private nonisolated(unsafe) var forcedMigrationContinuation: UnsafeContinuation<Void, Never>?

/// Goal: prove a single suspended async task can make progress on the other
/// core when the core that first ran it is busy. The stream consumer is one
/// logical task: the first yield records its starting core, pressure workers
/// burn that core, then a second yield must be handled on the other core without
/// overlapping the first task segment.
func forcedSameTaskMigrationCanResumeOnOtherCoreWhenInitialCoreIsBusy() async throws {
    ConcurrencyRuntime.startMulticore()
    resetForcedMigrationCounters()

    let consumer = Task {
        await forcedMigrationTwoStepObservedTask()
    }

    let firstContinuationReady = await waitForForcedMigration(timeoutMs: 500) {
        withForcedMigrationLock {
            forcedMigrationCounters.continuationWaits == 1 &&
                forcedMigrationContinuation != nil
        }
    }
    if !firstContinuationReady {
        let snapshot = withForcedMigrationLock { forcedMigrationCounters }
        print("forced-same-task phase=first-continuation-timeout waits=\(snapshot.continuationWaits) obs=\(snapshot.observations)")
    }
    resumeForcedMigrationContinuationIfAvailable()

    let firstObserved = await waitForForcedMigration(timeoutMs: 500) {
        withForcedMigrationLock {
            forcedMigrationCounters.observations == 1 &&
                forcedMigrationCounters.initialCore <= 1
        }
    }
    if !firstObserved {
        let snapshot = withForcedMigrationLock { forcedMigrationCounters }
        print("forced-same-task phase=first-observation-timeout obs=\(snapshot.observations) initial=\(snapshot.initialCore) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits)")
    }
    let firstCore = withForcedMigrationLock { forcedMigrationCounters.initialCore }

    let pressureDeadlineUs = time_us_64() &+ 1_500_000
    var pressureTasks: [Task<Void, Never>] = []
    pressureTasks.reserveCapacity(8)
    for workerID in UInt32(0)..<8 {
        pressureTasks.append(Task {
            await forcedMigrationCoreBlocker(id: workerID, blockedCore: firstCore, deadlineUs: pressureDeadlineUs)
        })
    }

    let coreBlocked = await waitForForcedMigration(timeoutMs: 500) {
        withForcedMigrationLock {
            forcedMigrationCounters.pressureInitialCoreBurning > 0
        }
    }
    if !coreBlocked {
        let snapshot = withForcedMigrationLock { forcedMigrationCounters }
        print("forced-same-task phase=core-block-timeout initial=\(snapshot.initialCore) pStart=\(snapshot.pressureStarted) pInitial=\(snapshot.pressureInitialCoreStarted) pBurn=\(snapshot.pressureInitialCoreBurning) pOther=\(snapshot.pressureOtherCoreStarted)")
    }

    let secondContinuationReady = await waitForForcedMigration(timeoutMs: 500) {
        withForcedMigrationLock {
            forcedMigrationCounters.continuationWaits == 2 &&
                forcedMigrationContinuation != nil
        }
    }
    if !secondContinuationReady {
        let snapshot = withForcedMigrationLock { forcedMigrationCounters }
        print("forced-same-task phase=second-continuation-timeout waits=\(snapshot.continuationWaits) obs=\(snapshot.observations) initial=\(snapshot.initialCore)")
    }
    resumeForcedMigrationContinuationIfAvailable()

    let secondObserved = await waitForForcedMigration(timeoutMs: 1_500) {
        withForcedMigrationLock {
            forcedMigrationCounters.observations >= 2
        }
    }
    if !secondObserved {
        let snapshot = withForcedMigrationLock { forcedMigrationCounters }
        print("forced-same-task phase=second-observation-timeout obs=\(snapshot.observations) initial=\(snapshot.initialCore) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) pBurn=\(snapshot.pressureInitialCoreBurning) overlap=\(snapshot.overlapViolations)")
    }

    let pressureCompleted = await waitForForcedMigration(timeoutMs: 1_500) {
        withForcedMigrationLock {
            forcedMigrationCounters.pressureDone == 8
        }
    }
    if !pressureCompleted {
        let snapshot = withForcedMigrationLock { forcedMigrationCounters }
        print("forced-same-task phase=pressure-completion-timeout pressureDone=\(snapshot.pressureDone) pStart=\(snapshot.pressureStarted) pInitial=\(snapshot.pressureInitialCoreStarted) pOther=\(snapshot.pressureOtherCoreStarted)")
    }

    resumeForcedMigrationContinuationIfAvailable()
    await consumer.value
    for pressureTask in pressureTasks {
        await pressureTask.value
    }

    let snapshot = withForcedMigrationLock { forcedMigrationCounters }
    print("forced-same-task obs=\(snapshot.observations) initial=\(snapshot.initialCore) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) pStart=\(snapshot.pressureStarted) pInitial=\(snapshot.pressureInitialCoreStarted) pBurn=\(snapshot.pressureInitialCoreBurning) pOther=\(snapshot.pressureOtherCoreStarted) pressureDone=\(snapshot.pressureDone) overlap=\(snapshot.overlapViolations) sum=\(snapshot.checksum)")

    try deviceExpect(firstContinuationReady, "forced same-task migration did not install the first continuation")
    try deviceExpect(firstObserved, "forced same-task migration did not record the first stream event")
    try deviceExpect(coreBlocked, "forced same-task migration did not start a blocker on the initial core")
    try deviceExpect(secondContinuationReady, "forced same-task migration did not install the second continuation")
    try deviceExpect(secondObserved, "forced same-task migration did not record the second stream event")
    try deviceExpect(pressureCompleted, "forced same-task migration pressure workers did not finish")
    try deviceExpect(snapshot.observations == 2, "forced same-task migration did not record exactly two task segments")
    try deviceExpect(snapshot.core0Hits > 0, "forced same-task migration never observed the task on core0")
    try deviceExpect(snapshot.core1Hits > 0, "forced same-task migration never observed the task on core1")
    try deviceExpect(snapshot.initialCore <= 1, "forced same-task migration did not capture the initial core")
    if snapshot.initialCore == 0 {
        try deviceExpect(snapshot.core1Hits > 0, "forced same-task migration second segment did not move off core0")
    } else {
        try deviceExpect(snapshot.core0Hits > 0, "forced same-task migration second segment did not move off core1")
    }
    try deviceExpect(snapshot.overlapViolations == 0, "forced same-task migration overlapped the logical task with itself")
}

private func forcedMigrationTwoStepObservedTask() async {
    await forcedMigrationWaitForResume()
    beginForcedMigrationObservation()
    let firstChecksum = forcedMigrationSpin(seed: 0xCAFE, rounds: 3_000)
    endForcedMigrationObservation(checksum: firstChecksum)

    await forcedMigrationWaitForResume()
    beginForcedMigrationObservation()
    let secondChecksum = forcedMigrationSpin(seed: 0xCAFF, rounds: 3_000)
    endForcedMigrationObservation(checksum: secondChecksum)

    withForcedMigrationLock {
        forcedMigrationCounters.migrationDone = 1
    }
}

private func forcedMigrationWaitForResume() async {
    await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
        withForcedMigrationLock {
            forcedMigrationContinuation = continuation
            forcedMigrationCounters.continuationWaits += 1
        }
    }
}

private func forcedMigrationCoreBlocker(id: UInt32, blockedCore: UInt32, deadlineUs: UInt64) async {
    let startCore = get_core_num() & 1
    withForcedMigrationLock {
        forcedMigrationCounters.pressureStarted += 1
        if startCore == blockedCore {
            forcedMigrationCounters.pressureInitialCoreStarted += 1
            forcedMigrationCounters.pressureInitialCoreBurning += 1
        } else {
            forcedMigrationCounters.pressureOtherCoreStarted += 1
        }
    }

    if startCore == blockedCore {
        var checksum = id &+ 0x5151
        while time_us_64() < deadlineUs {
            if withForcedMigrationLock({ forcedMigrationCounters.observations >= 2 }) {
                break
            }
            checksum = forcedMigrationSpin(seed: checksum, rounds: 50_000)
        }
        withForcedMigrationLock {
            forcedMigrationCounters.checksum &+= checksum
        }
    } else {
        while time_us_64() < deadlineUs {
            if withForcedMigrationLock({ forcedMigrationCounters.observations >= 2 }) {
                break
            }
            await Task.yield()
        }
    }

    withForcedMigrationLock {
        forcedMigrationCounters.pressureDone += 1
    }
}

private func forcedMigrationObservedTaskOnce() async {
    beginForcedMigrationObservation()
    let firstChecksum = forcedMigrationSpin(seed: 0xCAFE, rounds: 3_000)
    endForcedMigrationObservation(checksum: firstChecksum)

    await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
        withForcedMigrationLock {
            forcedMigrationContinuation = continuation
            forcedMigrationCounters.continuationWaits += 1
        }
    }

    beginForcedMigrationObservation()
    let secondChecksum = forcedMigrationSpin(seed: 0xCAFF, rounds: 3_000)
    endForcedMigrationObservation(checksum: secondChecksum)

    withForcedMigrationLock {
        forcedMigrationCounters.migrationDone = 1
    }
}

private func forcedMigrationPairedPressureWorker(id: UInt32, deadlineUs: UInt64) async {
    let startCore = get_core_num() & 1
    let initialCore = withForcedMigrationLock { forcedMigrationCounters.initialCore }
    withForcedMigrationLock {
        forcedMigrationCounters.pressureStarted += 1
        if startCore == initialCore {
            forcedMigrationCounters.pressureInitialCoreStarted += 1
        } else {
            forcedMigrationCounters.pressureOtherCoreStarted += 1
        }
    }

    while time_us_64() < deadlineUs {
        if withForcedMigrationLock({ forcedMigrationCounters.pressureGateOpen }) {
            break
        }
        await Task.yield()
    }

    if startCore == initialCore {
        withForcedMigrationLock {
            forcedMigrationCounters.pressureInitialCoreBurning += 1
        }
        while time_us_64() < deadlineUs {
            if withForcedMigrationLock({ forcedMigrationCounters.migrationDone == 1 }) {
                break
            }
            _ = forcedMigrationSpin(seed: id &* 131 &+ 0x5151, rounds: 50_000)
        }
    } else {
        while time_us_64() < deadlineUs {
            if withForcedMigrationLock({ forcedMigrationCounters.pressureInitialCoreBurning > 0 }) {
                break
            }
            await Task.yield()
        }
        resumeForcedMigrationContinuationIfAvailable()
    }

    withForcedMigrationLock {
        forcedMigrationCounters.pressureDone += 1
    }
}

private func resumeForcedMigrationContinuationIfAvailable() {
    let core = get_core_num() & 1
    let continuation = withForcedMigrationLock { () -> UnsafeContinuation<Void, Never>? in
        guard let continuation = forcedMigrationContinuation else {
            return nil
        }
        forcedMigrationContinuation = nil
        forcedMigrationCounters.continuationResumes += 1
        if core == 0 {
            forcedMigrationCounters.resumeCore0Hits += 1
        } else {
            forcedMigrationCounters.resumeCore1Hits += 1
        }
        return continuation
    }

    continuation?.resume()
}

private func beginForcedMigrationObservation() {
    let core = get_core_num() & 1
    withForcedMigrationLock {
        if forcedMigrationCounters.observations == 0 {
            forcedMigrationCounters.initialCore = core
        }
        if forcedMigrationCounters.activeSegments != 0 {
            forcedMigrationCounters.overlapViolations += 1
        }
        forcedMigrationCounters.activeSegments += 1
        forcedMigrationCounters.observations += 1
        if core == 0 {
            forcedMigrationCounters.core0Hits += 1
        } else {
            forcedMigrationCounters.core1Hits += 1
        }
    }
}

private func endForcedMigrationObservation(checksum: UInt32) {
    withForcedMigrationLock {
        forcedMigrationCounters.checksum &+= checksum
        if forcedMigrationCounters.activeSegments > 0 {
            forcedMigrationCounters.activeSegments -= 1
        }
    }
}

private func resetForcedMigrationCounters() {
    withForcedMigrationLock {
        forcedMigrationCounters = ForcedMigrationCounters()
        forcedMigrationContinuation = nil
    }
}

private func withForcedMigrationLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(forcedMigrationLock)
    defer {
        mutex_exit(forcedMigrationLock)
    }
    return body()
}

private func waitForForcedMigration(timeoutMs: UInt64, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ timeoutMs &* 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

private func forcedMigrationSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 13
    }
    return value
}
