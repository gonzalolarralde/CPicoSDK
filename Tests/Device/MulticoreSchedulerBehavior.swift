//% -- test yaml
//% name: MulticoreSchedulerBehavior
//% timeout: 20s
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 20000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let schedulerTestLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct SchedulerCounters {
    var done: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var maxConcurrentWorkers: UInt32 = 0
    var activeWorkers: UInt32 = 0
    var lostWorkChecksum: UInt32 = 0
}

private struct TwoWorkerTiming {
    var done: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var elapsedMs: UInt64 = 0
    var intervalsOverlap: Bool = false
    var worker0StartUs: UInt64 = 0
    var worker0EndUs: UInt64 = 0
    var worker1StartUs: UInt64 = 0
    var worker1EndUs: UInt64 = 0
    var checksum: UInt32 = 0
}

private struct SameTaskMigrationCounters {
    var observations: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var pressureDone: UInt32 = 0
    var migrationDone: UInt32 = 0
    var overlapViolations: UInt32 = 0
    var activeSegments: UInt32 = 0
    var checksum: UInt32 = 0
}

private let coverageBaseline: UInt32 = 1 << 0
private let coverageParallelTiming: UInt32 = 1 << 1
private let coverageAggressiveStress: UInt32 = 1 << 2
private let coverageSameTaskMigration: UInt32 = 1 << 3

private nonisolated(unsafe) var baselineCounters = SchedulerCounters()
private nonisolated(unsafe) var stressCounters = SchedulerCounters()
private nonisolated(unsafe) var timingCounters = TwoWorkerTiming()
private nonisolated(unsafe) var sameTaskMigrationCounters = SameTaskMigrationCounters()
private nonisolated(unsafe) var schedulerCoverageMask: UInt32 = 0

/// Goal: establish the baseline scheduler contract. Several async workers should
/// complete, and their resumed work should be observed on both core0 and core1
/// before any heavier timing or stress assumptions are trusted.
func multicoreBaselineRunsWorkOnBothCores() async throws {
    resetBaselineCounters()

    for workerID in UInt32(0)..<6 {
        Task {
            await baselineWorker(id: workerID, iterations: 24, spinRounds: 8_000)
        }
    }

    let completed = await waitUntil(timeoutMs: 3_000) {
        withSchedulerTestLock {
            baselineCounters.done == 6
        }
    }

    let snapshot = withSchedulerTestLock { baselineCounters }
    print("baseline done=\(snapshot.done) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) max=\(snapshot.maxConcurrentWorkers) sum=\(snapshot.lostWorkChecksum)")

    try deviceExpect(completed, "baseline workers did not complete")
    try deviceExpect(snapshot.core0Hits > 0, "baseline never ran work on core0")
    try deviceExpect(snapshot.core1Hits > 0, "baseline never ran work on core1")
    recordCoverage(coverageBaseline)
}

/// Goal: validate real parallel execution, not just alternating progress. Two
/// CPU-bound jobs burn a known wall-clock window; the test checks that they run
/// on different cores, their execution intervals overlap, and the measured
/// elapsed time is closer to one burn window than two.
func cpuBoundWorkersOverlapAndWallClockLooksParallel() async throws {
    resetTimingCounters()

    let burnMs: UInt64 = 280
    let startedUs = time_us_64()

    Task {
        cpuTimingWorker(id: 0, burnUs: burnMs * 1_000)
    }
    Task {
        cpuTimingWorker(id: 1, burnUs: burnMs * 1_000)
    }

    let completed = await waitUntil(timeoutMs: 2_000) {
        withSchedulerTestLock {
            timingCounters.done == 2
        }
    }

    let finishedUs = time_us_64()
    let elapsedMs = (finishedUs &- startedUs) / 1_000
    var snapshot = withSchedulerTestLock { timingCounters }
    let intervalsOverlap =
        snapshot.worker0StartUs < snapshot.worker1EndUs &&
        snapshot.worker1StartUs < snapshot.worker0EndUs
    withSchedulerTestLock {
        timingCounters.elapsedMs = elapsedMs
        timingCounters.intervalsOverlap = intervalsOverlap
    }
    snapshot.elapsedMs = elapsedMs
    snapshot.intervalsOverlap = intervalsOverlap

    print("parallel done=\(snapshot.done) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) elapsed=\(elapsedMs) w0=\(snapshot.worker0StartUs)-\(snapshot.worker0EndUs) w1=\(snapshot.worker1StartUs)-\(snapshot.worker1EndUs)")

    try deviceExpect(completed, "CPU-bound timing workers did not complete")
    try deviceExpect(snapshot.core0Hits > 0, "CPU-bound timing test did not run on core0")
    try deviceExpect(snapshot.core1Hits > 0, "CPU-bound timing test did not run on core1")
    try deviceExpect(intervalsOverlap, "CPU-bound worker execution intervals did not overlap")
    try deviceExpect(elapsedMs < burnMs + 180, "CPU-bound workers looked serialized instead of parallel")
    recordCoverage(coverageParallelTiming)
}

/// Goal: pressure the scheduler with many yielding workers. This checks
/// queueing, repeated rescheduling, overlap of active workers, both-core
/// execution under load, and a rough sanity bound that one core is not doing
/// almost all of the work.
func aggressiveYieldStressCompletesAndUsesBothCores() async throws {
    resetStressCounters()

    for workerID in UInt32(0)..<12 {
        Task {
            await stressWorker(id: workerID, iterations: 90, spinRounds: 6_000)
        }
    }

    let completed = await waitUntil(timeoutMs: 8_000) {
        withSchedulerTestLock {
            stressCounters.done == 12
        }
    }

    let snapshot = withSchedulerTestLock { stressCounters }
    let totalHits = snapshot.core0Hits + snapshot.core1Hits
    let smallerCoreHits = snapshot.core0Hits < snapshot.core1Hits ? snapshot.core0Hits : snapshot.core1Hits

    print("stress done=\(snapshot.done) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) total=\(totalHits) min=\(smallerCoreHits) max=\(snapshot.maxConcurrentWorkers) sum=\(snapshot.lostWorkChecksum)")

    try deviceExpect(completed, "yield stress workers did not complete")
    try deviceExpect(snapshot.core0Hits > 0, "yield stress never ran work on core0")
    try deviceExpect(snapshot.core1Hits > 0, "yield stress never ran work on core1")
    try deviceExpect(snapshot.maxConcurrentWorkers >= 2, "yield stress never observed simultaneous worker activity")
    try deviceExpect(smallerCoreHits * 10 >= totalHits, "yield stress was badly imbalanced across cores")
    recordCoverage(coverageAggressiveStress)
}

/// Goal: validate allowed non-overlapping migration of one logical async task.
/// This function records the core from the same task across many suspension
/// boundaries, while background pressure gives the scheduler chances to choose a
/// different core for later continuations. Seeing both cores here is valid as
/// long as the task is only running at one moment at a time.
func sameTaskCanResumeOnBothCoresAfterSuspension() async throws {
    resetSameTaskMigrationCounters()

    let pressureDeadlineUs = time_us_64() &+ 800_000
    for workerID in UInt32(0)..<4 {
        Task {
            await sameTaskMigrationPressureWorker(id: workerID, deadlineUs: pressureDeadlineUs)
        }
    }

    Task {
        await sameTaskMigrationObservedTask(iterations: 36)
    }

    let migrationCompleted = await waitUntil(timeoutMs: 2_500) {
        withSchedulerTestLock {
            sameTaskMigrationCounters.migrationDone == 1
        }
    }
    let pressureCompleted = await waitUntil(timeoutMs: 1_200) {
        withSchedulerTestLock {
            sameTaskMigrationCounters.pressureDone == 4
        }
    }
    let snapshot = withSchedulerTestLock { sameTaskMigrationCounters }

    print("same-task done=\(snapshot.migrationDone) obs=\(snapshot.observations) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) pressureDone=\(snapshot.pressureDone) overlap=\(snapshot.overlapViolations) sum=\(snapshot.checksum)")

    try deviceExpect(migrationCompleted, "same-task migration task did not finish")
    try deviceExpect(pressureCompleted, "same-task migration pressure workers did not finish")
    try deviceExpect(snapshot.observations == 36, "same-task migration did not record every observation")
    try deviceExpect(snapshot.core0Hits > 0, "same task was never observed on core0")
    try deviceExpect(snapshot.core1Hits > 0, "same task was never observed on core1")
    try deviceExpect(snapshot.overlapViolations == 0, "same logical task overlapped with itself while migrating")
    recordCoverage(coverageSameTaskMigration)
}

// /// Goal: aggressively validate alarm-backed same-task resumptions under
// /// multicore pressure. This is intentionally disabled until the base
// /// migration signal above fails cleanly, because `Task.sleep(us:)` enters the
// /// PicoTimeoutManager/ISRTrampoline path and can currently mask scheduler
// /// behavior as a missing run-end marker.
// func alarmBackedSameTaskMigrationEventuallyUsesBothCores() async throws {
//     resetSameTaskMigrationCounters()
//
//     let pressureDeadlineUs = time_us_64() &+ 1_400_000
//     for workerID in UInt32(0)..<4 {
//         Task {
//             await sameTaskMigrationPressureWorker(id: workerID, deadlineUs: pressureDeadlineUs)
//         }
//     }
//
//     Task {
//         await alarmBackedSameTaskMigrationObservedTask(iterations: 64, sleepUs: 1_000)
//     }
//
//     let migrationCompleted = await waitUntil(timeoutMs: 3_500) {
//         withSchedulerTestLock {
//             sameTaskMigrationCounters.migrationDone == 1
//         }
//     }
//     let snapshot = withSchedulerTestLock { sameTaskMigrationCounters }
//
//     print("alarm-migration done=\(snapshot.migrationDone) obs=\(snapshot.observations) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) pressureDone=\(snapshot.pressureDone) overlap=\(snapshot.overlapViolations) sum=\(snapshot.checksum)")
//
//     try deviceExpect(migrationCompleted, "alarm-backed same-task migration task did not finish")
//     try deviceExpect(snapshot.observations == 64, "alarm-backed same-task migration did not record every observation")
//     try deviceExpect(snapshot.core0Hits > 0, "alarm-backed same task was never observed on core0")
//     try deviceExpect(snapshot.core1Hits > 0, "alarm-backed same task was never observed on core1")
//     try deviceExpect(snapshot.overlapViolations == 0, "alarm-backed same logical task overlapped with itself")
// }

/// Goal: cross-check the file as one suite. The previous tests should
/// collectively cover baseline validation, aggressive CPU-bound parallel timing,
/// allowed same-task migration after suspension, and multicore/yield stress.
/// This catches accidental skips or future edits that leave one requested
/// validation area unexercised.
func schedulerBehaviorCoverageMatchesRequest() throws {
    let snapshot = withSchedulerTestLock {
        (
            mask: schedulerCoverageMask,
            baseline: baselineCounters,
            timing: timingCounters,
            stress: stressCounters,
            migration: sameTaskMigrationCounters
        )
    }
    let baselineHits = snapshot.baseline.core0Hits + snapshot.baseline.core1Hits
    let stressHits = snapshot.stress.core0Hits + snapshot.stress.core1Hits

    print("coverage mask=\(snapshot.mask) baselineHits=\(baselineHits) stressHits=\(stressHits) migration=\(snapshot.migration.core0Hits)/\(snapshot.migration.core1Hits) parallelElapsed=\(snapshot.timing.elapsedMs) parallelOverlap=\(snapshot.timing.intervalsOverlap)")

    try deviceExpect((snapshot.mask & coverageBaseline) != 0, "baseline scheduler validation did not run")
    try deviceExpect((snapshot.mask & coverageParallelTiming) != 0, "parallel CPU timing validation did not run")
    try deviceExpect((snapshot.mask & coverageAggressiveStress) != 0, "aggressive yield stress validation did not run")
    try deviceExpect((snapshot.mask & coverageSameTaskMigration) != 0, "same-task migration validation did not run")
    try deviceExpect(snapshot.baseline.core0Hits > 0 && snapshot.baseline.core1Hits > 0, "baseline did not prove both-core execution")
    try deviceExpect(snapshot.timing.done == 2, "parallel timing did not complete both workers")
    try deviceExpect(snapshot.timing.core0Hits > 0 && snapshot.timing.core1Hits > 0, "parallel timing did not split work across cores")
    try deviceExpect(snapshot.timing.intervalsOverlap, "parallel timing did not observe overlap")
    try deviceExpect(snapshot.timing.elapsedMs > 0 && snapshot.timing.elapsedMs < 460, "parallel timing elapsed window was incoherent")
    try deviceExpect(snapshot.migration.migrationDone == 1, "same logical task migration did not finish")
    try deviceExpect(snapshot.migration.core0Hits > 0 && snapshot.migration.core1Hits > 0, "same logical task did not resume on both cores")
    try deviceExpect(snapshot.migration.overlapViolations == 0, "same logical task overlapped with itself")
    try deviceExpect(snapshot.stress.maxConcurrentWorkers >= 2, "stress did not observe overlapping active workers")
    try deviceExpect(stressHits > baselineHits, "stress did not exercise more scheduler work than the baseline")
}

private func resetBaselineCounters() {
    withSchedulerTestLock {
        baselineCounters = SchedulerCounters()
    }
}

private func resetStressCounters() {
    withSchedulerTestLock {
        stressCounters = SchedulerCounters()
    }
}

private func resetTimingCounters() {
    withSchedulerTestLock {
        timingCounters = TwoWorkerTiming()
    }
}

private func resetSameTaskMigrationCounters() {
    withSchedulerTestLock {
        sameTaskMigrationCounters = SameTaskMigrationCounters()
    }
}

private func baselineWorker(id: UInt32, iterations: UInt32, spinRounds: UInt32) async {
    for iteration in UInt32(0)..<iterations {
        let checksum = cpuSpin(seed: id &+ iteration &+ 1, rounds: spinRounds)
        recordBaselineHit(checksum: checksum)
        await Task.yield()
    }

    withSchedulerTestLock {
        baselineCounters.done += 1
    }
}

private func stressWorker(id: UInt32, iterations: UInt32, spinRounds: UInt32) async {
    for iteration in UInt32(0)..<iterations {
        recordStressEnter()
        let checksum = cpuSpin(seed: id &* 97 &+ iteration &+ 1, rounds: spinRounds)
        recordStressHit(checksum: checksum)
        recordStressExit()
        await Task.yield()
    }

    withSchedulerTestLock {
        stressCounters.done += 1
    }
}

private func sameTaskMigrationPressureWorker(id: UInt32, deadlineUs: UInt64) async {
    var iteration: UInt32 = 0
    while time_us_64() < deadlineUs {
        _ = cpuSpin(seed: id &* 131 &+ iteration, rounds: 5_000)
        iteration &+= 1
        await Task.yield()
    }

    withSchedulerTestLock {
        sameTaskMigrationCounters.pressureDone += 1
    }
}

private func sameTaskMigrationObservedTask(iterations: UInt32) async {
    for iteration in UInt32(0)..<iterations {
        beginSameTaskMigrationObservation()
        let checksum = cpuSpin(seed: iteration &+ 0xCAFE, rounds: 3_000)
        endSameTaskMigrationObservation(checksum: checksum)
        await Task.yield()
    }

    withSchedulerTestLock {
        sameTaskMigrationCounters.migrationDone = 1
    }
}

// private func alarmBackedSameTaskMigrationObservedTask(iterations: UInt32, sleepUs: UInt64) async {
//     for iteration in UInt32(0)..<iterations {
//         beginSameTaskMigrationObservation()
//         let checksum = cpuSpin(seed: iteration &+ 0xA1A1, rounds: 3_000)
//         endSameTaskMigrationObservation(checksum: checksum)
//         try? await Task.sleep(us: sleepUs)
//     }
//
//     withSchedulerTestLock {
//         sameTaskMigrationCounters.migrationDone = 1
//     }
// }

private func cpuTimingWorker(id: UInt32, burnUs: UInt64) {
    let start = time_us_64()
    let checksum = burnFor(durationUs: burnUs, seed: id &+ 0x55AA)
    let end = time_us_64()
    let core = get_core_num() & 1

    withSchedulerTestLock {
        if core == 0 {
            timingCounters.core0Hits += 1
        } else {
            timingCounters.core1Hits += 1
        }

        if id == 0 {
            timingCounters.worker0StartUs = start
            timingCounters.worker0EndUs = end
        } else {
            timingCounters.worker1StartUs = start
            timingCounters.worker1EndUs = end
        }

        timingCounters.done += 1
        timingCounters.checksum &+= checksum
    }
}

private func beginSameTaskMigrationObservation() {
    let core = get_core_num() & 1
    withSchedulerTestLock {
        if sameTaskMigrationCounters.activeSegments != 0 {
            sameTaskMigrationCounters.overlapViolations += 1
        }
        sameTaskMigrationCounters.activeSegments += 1
        sameTaskMigrationCounters.observations += 1
        if core == 0 {
            sameTaskMigrationCounters.core0Hits += 1
        } else {
            sameTaskMigrationCounters.core1Hits += 1
        }
    }
}

private func endSameTaskMigrationObservation(checksum: UInt32) {
    withSchedulerTestLock {
        sameTaskMigrationCounters.checksum &+= checksum
        if sameTaskMigrationCounters.activeSegments > 0 {
            sameTaskMigrationCounters.activeSegments -= 1
        }
    }
}

private func recordBaselineHit(checksum: UInt32) {
    let core = get_core_num() & 1
    withSchedulerTestLock {
        if core == 0 {
            baselineCounters.core0Hits += 1
        } else {
            baselineCounters.core1Hits += 1
        }
        baselineCounters.lostWorkChecksum &+= checksum
    }
}

private func recordStressEnter() {
    withSchedulerTestLock {
        stressCounters.activeWorkers += 1
        if stressCounters.activeWorkers > stressCounters.maxConcurrentWorkers {
            stressCounters.maxConcurrentWorkers = stressCounters.activeWorkers
        }
    }
}

private func recordStressHit(checksum: UInt32) {
    let core = get_core_num() & 1
    withSchedulerTestLock {
        if core == 0 {
            stressCounters.core0Hits += 1
        } else {
            stressCounters.core1Hits += 1
        }
        stressCounters.lostWorkChecksum &+= checksum
    }
}

private func recordStressExit() {
    withSchedulerTestLock {
        if stressCounters.activeWorkers > 0 {
            stressCounters.activeWorkers -= 1
        }
    }
}

private func cpuSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed ^ 0x9E37_79B9
    for round in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ round
    }
    return value
}

private func burnFor(durationUs: UInt64, seed: UInt32) -> UInt32 {
    let deadline = time_us_64() &+ durationUs
    var value = seed ^ 0xA5A5_5A5A
    while time_us_64() < deadline {
        value = cpuSpin(seed: value, rounds: 512)
    }
    return value
}

private func waitUntil(timeoutMs: UInt32, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ UInt64(timeoutMs) * 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

private func withSchedulerTestLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(schedulerTestLock)
    defer {
        mutex_exit(schedulerTestLock)
    }
    return body()
}

private func recordCoverage(_ bit: UInt32) {
    withSchedulerTestLock {
        schedulerCoverageMask |= bit
    }
}
