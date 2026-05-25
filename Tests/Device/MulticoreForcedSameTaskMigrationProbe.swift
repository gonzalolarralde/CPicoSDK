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

/// Goal: preserve the aggressive same-task migration probe that currently
/// exposes an unsupported scheduler/runtime edge. The test suspends one task,
/// keeps the core where it first ran busy, resumes the continuation from the
/// other core, and expects that same logical task to continue on the other core
/// without overlapping itself. This is expected to fail until the scheduler
/// refactor can safely migrate suspended task continuations under pressure.
func forcedSameTaskMigrationCanResumeOnOtherCoreWhenInitialCoreIsBusy() async throws {
    ConcurrencyRuntime.startMulticore()
    resetForcedMigrationCounters()

    Task {
        await forcedMigrationObservedTaskOnce()
    }

    let initialSuspended = await waitForForcedMigration(timeoutMs: 300) {
        withForcedMigrationLock {
            forcedMigrationCounters.initialCore <= 1 &&
                forcedMigrationCounters.continuationWaits == 1 &&
                forcedMigrationContinuation != nil
        }
    }

    let pressureDeadlineUs = time_us_64() &+ 1_000_000
    for workerID in UInt32(0)..<2 {
        Task {
            await forcedMigrationPairedPressureWorker(id: workerID, deadlineUs: pressureDeadlineUs)
        }
    }

    let pressureStarted = await waitForForcedMigration(timeoutMs: 300) {
        withForcedMigrationLock {
            forcedMigrationCounters.pressureStarted == 2 &&
                forcedMigrationCounters.pressureInitialCoreStarted > 0 &&
                forcedMigrationCounters.pressureOtherCoreStarted > 0
        }
    }
    withForcedMigrationLock {
        forcedMigrationCounters.pressureGateOpen = true
    }

    let migrationCompleted = await waitForForcedMigration(timeoutMs: 500) {
        withForcedMigrationLock {
            forcedMigrationCounters.migrationDone == 1
        }
    }
    let pressureCompleted = await waitForForcedMigration(timeoutMs: 500) {
        withForcedMigrationLock {
            forcedMigrationCounters.pressureDone == 2
        }
    }

    let snapshot = withForcedMigrationLock { forcedMigrationCounters }
    print("forced-same-task done=\(snapshot.migrationDone) obs=\(snapshot.observations) initial=\(snapshot.initialCore) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) waits=\(snapshot.continuationWaits) resumes=\(snapshot.continuationResumes) r0=\(snapshot.resumeCore0Hits) r1=\(snapshot.resumeCore1Hits) pStart=\(snapshot.pressureStarted) pInitial=\(snapshot.pressureInitialCoreStarted) pBurn=\(snapshot.pressureInitialCoreBurning) pOther=\(snapshot.pressureOtherCoreStarted) pressureDone=\(snapshot.pressureDone) overlap=\(snapshot.overlapViolations) sum=\(snapshot.checksum)")

    try deviceExpect(initialSuspended, "forced same-task migration task did not suspend for pressure setup")
    try deviceExpect(pressureStarted, "forced same-task migration did not start pressure on both relevant cores")
    try deviceExpect(migrationCompleted, "forced same-task migration task did not finish")
    try deviceExpect(pressureCompleted, "forced same-task migration pressure workers did not finish")
    try deviceExpect(snapshot.observations == 2, "forced same-task migration did not record both task segments")
    try deviceExpect(snapshot.core0Hits > 0, "forced same-task migration never observed the task on core0")
    try deviceExpect(snapshot.core1Hits > 0, "forced same-task migration never observed the task on core1")
    try deviceExpect(snapshot.resumeCore0Hits > 0, "forced same-task migration continuation was never resumed from core0")
    try deviceExpect(snapshot.resumeCore1Hits > 0, "forced same-task migration continuation was never resumed from core1")
    try deviceExpect(snapshot.overlapViolations == 0, "forced same-task migration overlapped the logical task with itself")
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
