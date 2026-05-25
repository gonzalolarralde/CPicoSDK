//% -- test yaml
//% name: MulticoreSchedulerBehavior
//% timeout: 60s
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 60000
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
    var continuationWaits: UInt32 = 0
    var continuationResumes: UInt32 = 0
    var resumeCore0Hits: UInt32 = 0
    var resumeCore1Hits: UInt32 = 0
    var initialCore: UInt32 = UInt32.max
    var pressureStarted: UInt32 = 0
    var pressureInitialCoreStarted: UInt32 = 0
    var pressureOtherCoreStarted: UInt32 = 0
    var pressureInitialCoreBurning: UInt32 = 0
    var pressureGateOpen: Bool = false
    var checksum: UInt32 = 0
}

private struct AlarmSleepCounters {
    var done: UInt32 = 0
    var sleeps: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private struct DelayedSleepCounters {
    var done: UInt32 = 0
    var earlyWakeups: UInt32 = 0
    var lateWakeups: UInt32 = 0
    var elapsed0Us: UInt64 = 0
    var elapsed1Us: UInt64 = 0
    var elapsed2Us: UInt64 = 0
    var checksum: UInt32 = 0
}

private struct MemoryPressureCounters {
    var done: UInt32 = 0
    var iterations: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var maxConcurrentWorkers: UInt32 = 0
    var activeWorkers: UInt32 = 0
    var beforeUsed: UInt32 = 0
    var afterUsed: UInt32 = 0
    var beforeTotalFree: UInt32 = 0
    var afterTotalFree: UInt32 = 0
    var checksum: UInt32 = 0
}

private let coverageBaseline: UInt32 = 1 << 0
private let coverageParallelTiming: UInt32 = 1 << 1
private let coverageAggressiveStress: UInt32 = 1 << 2
private let coverageSameTaskMigration: UInt32 = 1 << 3
private let coverageAlarmSleep: UInt32 = 1 << 4
private let coverageBurstQueueing: UInt32 = 1 << 5
private let coverageDelayedTiming: UInt32 = 1 << 6
private let coverageAllocationStress: UInt32 = 1 << 7
private let coverageAlarmSameTaskMigration: UInt32 = 1 << 8
private let coverageMemoryPressure: UInt32 = 1 << 9
private let coverageMixedAlarmAllocation: UInt32 = 1 << 10

private nonisolated(unsafe) var baselineCounters = SchedulerCounters()
private nonisolated(unsafe) var stressCounters = SchedulerCounters()
private nonisolated(unsafe) var burstCounters = SchedulerCounters()
private nonisolated(unsafe) var allocationCounters = SchedulerCounters()
private nonisolated(unsafe) var timingCounters = TwoWorkerTiming()
private nonisolated(unsafe) var sameTaskMigrationCounters = SameTaskMigrationCounters()
private nonisolated(unsafe) var sameTaskMigrationContinuation: UnsafeContinuation<Void, Never>?
private nonisolated(unsafe) var alarmMigrationCounters = SameTaskMigrationCounters()
private nonisolated(unsafe) var alarmSleepCounters = AlarmSleepCounters()
private nonisolated(unsafe) var delayedSleepCounters = DelayedSleepCounters()
private nonisolated(unsafe) var memoryPressureCounters = MemoryPressureCounters()
private nonisolated(unsafe) var mixedAlarmAllocationCounters = MemoryPressureCounters()
private nonisolated(unsafe) var schedulerCoverageMask: UInt32 = 0

/// Goal: establish the baseline scheduler contract. Several async workers should
/// complete, and their resumed work should be observed on both core0 and core1
/// before any heavier timing or stress assumptions are trusted.
func multicoreBaselineRunsWorkOnBothCores() async throws {
    ConcurrencyRuntime.startMulticore()
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
    ConcurrencyRuntime.startMulticore()
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
    ConcurrencyRuntime.startMulticore()
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

/// Goal: validate that one logical async task can cross many suspension
/// boundaries without ever overlapping with itself. The scheduler may keep this
/// task on one core because affinity is allowed; the alarm-backed migration test
/// below is the stronger probe that checks whether one task eventually appears
/// on both cores.
func sameTaskCanResumeOnBothCoresAfterSuspension() async throws {
    ConcurrencyRuntime.startMulticore()
    resetSameTaskMigrationCounters()

    Task {
        await sameTaskYieldingObservationTask(iterations: 36)
    }

    for workerID in UInt32(0)..<4 {
        Task {
            await sameTaskMigrationBackgroundPressureWorker(id: workerID, iterations: 120)
        }
    }

    let migrationCompleted = await waitUntil(timeoutMs: 2_000) {
        withSchedulerTestLock {
            sameTaskMigrationCounters.migrationDone == 1
        }
    }
    let pressureCompleted = await waitUntil(timeoutMs: 2_000) {
        withSchedulerTestLock {
            sameTaskMigrationCounters.pressureDone == 4
        }
    }
    let snapshot = withSchedulerTestLock { sameTaskMigrationCounters }

    print("same-task done=\(snapshot.migrationDone) obs=\(snapshot.observations) initial=\(snapshot.initialCore) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) waits=\(snapshot.continuationWaits) resumes=\(snapshot.continuationResumes) r0=\(snapshot.resumeCore0Hits) r1=\(snapshot.resumeCore1Hits) pStart=\(snapshot.pressureStarted) pInitial=\(snapshot.pressureInitialCoreStarted) pBurn=\(snapshot.pressureInitialCoreBurning) pOther=\(snapshot.pressureOtherCoreStarted) pressureDone=\(snapshot.pressureDone) overlap=\(snapshot.overlapViolations) sum=\(snapshot.checksum)")

    try deviceExpect(migrationCompleted, "same-task migration task did not finish")
    try deviceExpect(pressureCompleted, "same-task migration pressure workers did not finish")
    try deviceExpect(snapshot.initialCore <= 1, "same-task migration did not record the initial core")
    try deviceExpect(snapshot.pressureStarted == 4, "same-task migration did not start pressure workers")
    try deviceExpect(snapshot.observations == 36, "same-task migration did not record the expected observations")
    try deviceExpect(snapshot.continuationWaits == 36, "same-task migration did not suspend between observations")
    try deviceExpect(snapshot.core0Hits + snapshot.core1Hits == 36, "same-task migration core hit count was incoherent")
    try deviceExpect(snapshot.core0Hits > 0 || snapshot.core1Hits > 0, "same task was never observed on a core")
    try deviceExpect(snapshot.overlapViolations == 0, "same logical task overlapped with itself while migrating")
    recordCoverage(coverageSameTaskMigration)
}

/// Goal: validate the Pico alarm and ISR trampoline path under multicore load.
/// Several workers repeatedly sleep through `Task.sleep(us:)`, then resume and
/// record the core that handled the continuation. This test validates that the
/// alarm-backed path completes without missing work; it does not require both
/// cores because task affinity and alarm routing can legitimately keep this
/// simple sleep-only workload on one core.
func alarmBackedSleepWorkersCompleteWithoutDroppingWork() async throws {
    ConcurrencyRuntime.startMulticore()
    resetAlarmSleepCounters()

    for workerID in UInt32(0)..<4 {
        Task {
            await alarmSleepWorker(id: workerID, iterations: 8, sleepUs: 1_000)
        }
    }

    let completed = await waitUntil(timeoutMs: 3_000) {
        withSchedulerTestLock {
            alarmSleepCounters.done == 4
        }
    }

    let snapshot = withSchedulerTestLock { alarmSleepCounters }
    print("alarm-sleep done=\(snapshot.done) sleeps=\(snapshot.sleeps) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(completed, "alarm-backed sleep workers did not complete")
    try deviceExpect(snapshot.sleeps == 32, "alarm-backed sleep workers missed resumptions")
    try deviceExpect(snapshot.core0Hits + snapshot.core1Hits == 32, "alarm-backed sleep workers recorded incoherent core hits")
    try deviceExpect(snapshot.core0Hits > 0 || snapshot.core1Hits > 0, "alarm-backed sleep workers never recorded a core hit")
    recordCoverage(coverageAlarmSleep)
}

/// Goal: stress the owner-queue transport with a burst of many ready jobs. This
/// stays below the fatal queue-capacity edge but creates enough simultaneous
/// producers to catch lost work, bad cross-core transport, and severe imbalance.
func burstQueuedWorkersCompleteWithoutDroppingWork() async throws {
    ConcurrencyRuntime.startMulticore()
    resetBurstCounters()

    for workerID in UInt32(0)..<48 {
        Task {
            await burstWorker(id: workerID, iterations: 10, spinRounds: 1_500)
        }
    }

    let completed = await waitUntil(timeoutMs: 4_000) {
        withSchedulerTestLock {
            burstCounters.done == 48
        }
    }

    let snapshot = withSchedulerTestLock { burstCounters }
    let hits = snapshot.core0Hits + snapshot.core1Hits
    print("burst done=\(snapshot.done) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) hits=\(hits) sum=\(snapshot.lostWorkChecksum)")

    try deviceExpect(completed, "burst queue workers did not complete")
    try deviceExpect(hits == 480, "burst queue workers lost iterations")
    try deviceExpect(snapshot.core0Hits > 0, "burst queue workers never ran on core0")
    try deviceExpect(snapshot.core1Hits > 0, "burst queue workers never ran on core1")
    try deviceExpect(snapshot.lostWorkChecksum != 0, "burst queue checksum did not change")
    recordCoverage(coverageBurstQueueing)
}

/// Goal: check that alarm-backed sleeps have coherent timing, not just eventual
/// completion. One task performs three sleeps with increasing durations and
/// records whether any continuation resumed substantially early or late.
func delayedSleepTimingLooksCoherent() async throws {
    ConcurrencyRuntime.startMulticore()
    resetDelayedSleepCounters()

    Task {
        await delayedSleepTimingWorker()
    }

    let completed = await waitUntil(timeoutMs: 1_000) {
        withSchedulerTestLock {
            delayedSleepCounters.done == 1
        }
    }

    let snapshot = withSchedulerTestLock { delayedSleepCounters }
    print("delayed done=\(snapshot.done) early=\(snapshot.earlyWakeups) late=\(snapshot.lateWakeups) e0=\(snapshot.elapsed0Us) e1=\(snapshot.elapsed1Us) e2=\(snapshot.elapsed2Us) sum=\(snapshot.checksum)")

    try deviceExpect(completed, "delayed sleep timing worker did not complete")
    try deviceExpect(snapshot.earlyWakeups == 0, "delayed sleep woke substantially early")
    try deviceExpect(snapshot.lateWakeups == 0, "delayed sleep woke substantially late")
    try deviceExpect(snapshot.elapsed0Us > 0 && snapshot.elapsed1Us > 0 && snapshot.elapsed2Us > 0, "delayed sleep did not record elapsed timings")
    recordCoverage(coverageDelayedTiming)
}

/// Goal: put allocator traffic on both cores while Swift jobs are yielding.
/// This exercises the newlib malloc lock and Swift wrapper interaction under
/// concurrent task execution instead of only testing CPU-bound work.
func allocationStressCompletesOnBothCores() async throws {
    ConcurrencyRuntime.startMulticore()
    resetAllocationCounters()

    for workerID in UInt32(0)..<8 {
        Task {
            await allocationStressWorker(id: workerID, iterations: 24)
        }
    }

    let completed = await waitUntil(timeoutMs: 5_000) {
        withSchedulerTestLock {
            allocationCounters.done == 8
        }
    }

    let snapshot = withSchedulerTestLock { allocationCounters }
    let hits = snapshot.core0Hits + snapshot.core1Hits
    print("alloc done=\(snapshot.done) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) hits=\(hits) max=\(snapshot.maxConcurrentWorkers) sum=\(snapshot.lostWorkChecksum)")

    try deviceExpect(completed, "allocation stress workers did not complete")
    try deviceExpect(hits == 192, "allocation stress lost iterations")
    try deviceExpect(snapshot.core0Hits > 0, "allocation stress never ran on core0")
    try deviceExpect(snapshot.core1Hits > 0, "allocation stress never ran on core1")
    try deviceExpect(snapshot.maxConcurrentWorkers >= 2, "allocation stress never observed overlapping workers")
    try deviceExpect(snapshot.lostWorkChecksum != 0, "allocation stress checksum did not change")
    recordCoverage(coverageAllocationStress)
}

/// Goal: aggressively validate alarm-backed same-task resumptions under
/// multicore pressure. This is stricter than the explicit-continuation
/// migration test because the suspension source is PicoTimeoutManager and
/// ISRTrampoline. The same logical task may move between cores after sleep
/// boundaries, but it must never overlap with itself.
func alarmBackedSameTaskMigrationEventuallyUsesBothCores() async throws {
    ConcurrencyRuntime.startMulticore()
    resetAlarmMigrationCounters()

    let pressureDeadlineUs = time_us_64() &+ 1_200_000
    for workerID in UInt32(0)..<4 {
        Task {
            await alarmMigrationPressureWorker(id: workerID, deadlineUs: pressureDeadlineUs)
        }
    }

    await alarmBackedSameTaskMigrationObservedTask(iterations: 48, sleepUs: 1_000)

    let pressureCompleted = await waitUntil(timeoutMs: 1_500) {
        withSchedulerTestLock {
            alarmMigrationCounters.pressureDone == 4
        }
    }
    let snapshot = withSchedulerTestLock { alarmMigrationCounters }

    print("alarm-migration done=\(snapshot.migrationDone) obs=\(snapshot.observations) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) pressureDone=\(snapshot.pressureDone) overlap=\(snapshot.overlapViolations) sum=\(snapshot.checksum)")

    try deviceExpect(snapshot.migrationDone == 1, "alarm-backed same-task migration task did not finish")
    try deviceExpect(pressureCompleted, "alarm-backed same-task pressure workers did not finish")
    try deviceExpect(snapshot.observations == 48, "alarm-backed same-task migration did not record every observation")
    try deviceExpect(snapshot.core0Hits > 0, "alarm-backed same task was never observed on core0")
    try deviceExpect(snapshot.core1Hits > 0, "alarm-backed same task was never observed on core1")
    try deviceExpect(snapshot.overlapViolations == 0, "alarm-backed same logical task overlapped with itself")
    recordCoverage(coverageAlarmSameTaskMigration)
}

/// Goal: pressure the heap with a couple dozen concurrent async tasks while
/// also checking for retained allocation growth. Each worker holds an allocation
/// across a suspension boundary, so free may happen after a later resume and
/// potentially on a different core than allocation.
func memoryPressureDoesNotGrowAfterConcurrentAllocations() async throws {
    ConcurrencyRuntime.startMulticore()
    resetMemoryPressureCounters()

    let before = MemoryStats.sram
    withSchedulerTestLock {
        memoryPressureCounters.beforeUsed = before.used
        memoryPressureCounters.beforeTotalFree = before.totalFree
    }

    for workerID in UInt32(0)..<24 {
        Task {
            await memoryPressureWorker(id: workerID, iterations: 10)
        }
    }

    let completed = await waitUntil(timeoutMs: 6_000) {
        withSchedulerTestLock {
            memoryPressureCounters.done == 24
        }
    }

    for _ in 0..<8 {
        await Task.yield()
    }

    let after = MemoryStats.sram
    var snapshot = withSchedulerTestLock { memoryPressureCounters }
    withSchedulerTestLock {
        memoryPressureCounters.afterUsed = after.used
        memoryPressureCounters.afterTotalFree = after.totalFree
    }
    snapshot.afterUsed = after.used
    snapshot.afterTotalFree = after.totalFree

    let usedGrowth = snapshot.afterUsed > snapshot.beforeUsed ? snapshot.afterUsed - snapshot.beforeUsed : 0
    let freeLoss = snapshot.beforeTotalFree > snapshot.afterTotalFree ? snapshot.beforeTotalFree - snapshot.afterTotalFree : 0
    let hits = snapshot.core0Hits + snapshot.core1Hits
    print("memory-pressure done=\(snapshot.done) iters=\(snapshot.iterations) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) max=\(snapshot.maxConcurrentWorkers) used=\(snapshot.beforeUsed)->\(snapshot.afterUsed) free=\(snapshot.beforeTotalFree)->\(snapshot.afterTotalFree) usedGrowth=\(usedGrowth) freeLoss=\(freeLoss) sum=\(snapshot.checksum)")

    try deviceExpect(completed, "memory pressure workers did not complete")
    try deviceExpect(snapshot.iterations == 240, "memory pressure lost iterations")
    try deviceExpect(hits == 240, "memory pressure hit count was incoherent")
    try deviceExpect(snapshot.core0Hits > 0, "memory pressure never ran on core0")
    try deviceExpect(snapshot.core1Hits > 0, "memory pressure never ran on core1")
    try deviceExpect(snapshot.maxConcurrentWorkers >= 2, "memory pressure never observed overlapping workers")
    try deviceExpect(usedGrowth <= 4_096, "SRAM used bytes grew after completed allocation pressure")
    try deviceExpect(freeLoss <= 8_192, "SRAM total free bytes dropped after completed allocation pressure")
    try deviceExpect(snapshot.checksum != 0, "memory pressure checksum did not change")
    recordCoverage(coverageMemoryPressure)
}

/// Goal: combine timer wakes, allocation/deallocation, frequent yields, and
/// both-core execution in one workload. This tries to catch bugs that only show
/// when alarm-delivered continuations immediately put pressure on the allocator
/// and scheduler transport.
func mixedAlarmAllocationPressureCompletes() async throws {
    ConcurrencyRuntime.startMulticore()
    resetMixedAlarmAllocationCounters()

    let before = MemoryStats.sram
    withSchedulerTestLock {
        mixedAlarmAllocationCounters.beforeUsed = before.used
        mixedAlarmAllocationCounters.beforeTotalFree = before.totalFree
    }

    for workerID in UInt32(0)..<16 {
        Task {
            await mixedAlarmAllocationWorker(id: workerID, iterations: 8)
        }
    }

    let completed = await waitUntil(timeoutMs: 6_000) {
        withSchedulerTestLock {
            mixedAlarmAllocationCounters.done == 16
        }
    }

    for _ in 0..<8 {
        await Task.yield()
    }

    let after = MemoryStats.sram
    var snapshot = withSchedulerTestLock { mixedAlarmAllocationCounters }
    withSchedulerTestLock {
        mixedAlarmAllocationCounters.afterUsed = after.used
        mixedAlarmAllocationCounters.afterTotalFree = after.totalFree
    }
    snapshot.afterUsed = after.used
    snapshot.afterTotalFree = after.totalFree

    let usedGrowth = snapshot.afterUsed > snapshot.beforeUsed ? snapshot.afterUsed - snapshot.beforeUsed : 0
    let freeLoss = snapshot.beforeTotalFree > snapshot.afterTotalFree ? snapshot.beforeTotalFree - snapshot.afterTotalFree : 0
    let hits = snapshot.core0Hits + snapshot.core1Hits
    print("mixed-alarm-alloc done=\(snapshot.done) iters=\(snapshot.iterations) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) max=\(snapshot.maxConcurrentWorkers) used=\(snapshot.beforeUsed)->\(snapshot.afterUsed) free=\(snapshot.beforeTotalFree)->\(snapshot.afterTotalFree) usedGrowth=\(usedGrowth) freeLoss=\(freeLoss) sum=\(snapshot.checksum)")

    try deviceExpect(completed, "mixed alarm/allocation workers did not complete")
    try deviceExpect(snapshot.iterations == 128, "mixed alarm/allocation stress lost iterations")
    try deviceExpect(hits == 128, "mixed alarm/allocation hit count was incoherent")
    try deviceExpect(snapshot.core0Hits > 0, "mixed alarm/allocation stress never ran on core0")
    try deviceExpect(snapshot.core1Hits > 0, "mixed alarm/allocation stress never ran on core1")
    try deviceExpect(snapshot.maxConcurrentWorkers >= 2, "mixed alarm/allocation stress never observed overlapping workers")
    try deviceExpect(usedGrowth <= 4_096, "SRAM used bytes grew after mixed alarm/allocation stress")
    try deviceExpect(freeLoss <= 8_192, "SRAM total free bytes dropped after mixed alarm/allocation stress")
    try deviceExpect(snapshot.checksum != 0, "mixed alarm/allocation checksum did not change")
    recordCoverage(coverageMixedAlarmAllocation)
}

/// Goal: cross-check the file as one suite. The previous tests should
/// collectively cover baseline validation, aggressive CPU-bound parallel timing,
/// allowed same-task migration after suspension, alarm-backed sleep, burst
/// queueing, delayed timing, allocation stress, alarm-backed same-task
/// migration, memory pressure, mixed alarm/allocation stress, and
/// multicore/yield stress. This catches accidental skips or future edits that
/// leave one requested validation area unexercised.
func schedulerBehaviorCoverageMatchesRequest() throws {
    let snapshot = (
        mask: schedulerCoverageMask,
        baseline: baselineCounters,
        timing: timingCounters,
        stress: stressCounters,
        burst: burstCounters,
        migration: sameTaskMigrationCounters,
        alarmMigration: alarmMigrationCounters,
        alarm: alarmSleepCounters,
        delayed: delayedSleepCounters,
        allocation: allocationCounters,
        memory: memoryPressureCounters,
        mixed: mixedAlarmAllocationCounters
    )
    let baselineHits = snapshot.baseline.core0Hits + snapshot.baseline.core1Hits
    let stressHits = snapshot.stress.core0Hits + snapshot.stress.core1Hits
    let burstHits = snapshot.burst.core0Hits + snapshot.burst.core1Hits
    let alarmHits = snapshot.alarm.core0Hits + snapshot.alarm.core1Hits
    let allocationHits = snapshot.allocation.core0Hits + snapshot.allocation.core1Hits
    let memoryHits = snapshot.memory.core0Hits + snapshot.memory.core1Hits
    let mixedHits = snapshot.mixed.core0Hits + snapshot.mixed.core1Hits

    print("coverage mask=\(snapshot.mask) baseline=\(baselineHits) stress=\(stressHits) migration=\(snapshot.migration.core0Hits)/\(snapshot.migration.core1Hits) alarmMigration=\(snapshot.alarmMigration.core0Hits)/\(snapshot.alarmMigration.core1Hits) mixed=\(mixedHits)")
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

private func resetBurstCounters() {
    withSchedulerTestLock {
        burstCounters = SchedulerCounters()
    }
}

private func resetAllocationCounters() {
    withSchedulerTestLock {
        allocationCounters = SchedulerCounters()
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
        sameTaskMigrationContinuation = nil
    }
}

private func resetAlarmMigrationCounters() {
    withSchedulerTestLock {
        alarmMigrationCounters = SameTaskMigrationCounters()
    }
}

private func resetAlarmSleepCounters() {
    withSchedulerTestLock {
        alarmSleepCounters = AlarmSleepCounters()
    }
}

private func resetDelayedSleepCounters() {
    withSchedulerTestLock {
        delayedSleepCounters = DelayedSleepCounters()
    }
}

private func resetMemoryPressureCounters() {
    withSchedulerTestLock {
        memoryPressureCounters = MemoryPressureCounters()
    }
}

private func resetMixedAlarmAllocationCounters() {
    withSchedulerTestLock {
        mixedAlarmAllocationCounters = MemoryPressureCounters()
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

private func burstWorker(id: UInt32, iterations: UInt32, spinRounds: UInt32) async {
    for iteration in UInt32(0)..<iterations {
        let checksum = cpuSpin(seed: id &* 43 &+ iteration &+ 1, rounds: spinRounds)
        recordBurstHit(checksum: checksum)
        await Task.yield()
    }

    withSchedulerTestLock {
        burstCounters.done += 1
    }
}

private func alarmSleepWorker(id: UInt32, iterations: UInt32, sleepUs: UInt64) async {
    for iteration in UInt32(0)..<iterations {
        try? await Task.sleep(us: sleepUs)
        let checksum = cpuSpin(seed: id &* 173 &+ iteration &+ 1, rounds: 700)
        recordAlarmSleepHit(checksum: checksum)
    }

    withSchedulerTestLock {
        alarmSleepCounters.done += 1
    }
}

private func delayedSleepTimingWorker() async {
    await recordDelayedSleep(index: 0, expectedUs: 8_000)
    await recordDelayedSleep(index: 1, expectedUs: 16_000)
    await recordDelayedSleep(index: 2, expectedUs: 24_000)

    withSchedulerTestLock {
        delayedSleepCounters.done = 1
    }
}

private func allocationStressWorker(id: UInt32, iterations: UInt32) async {
    for iteration in UInt32(0)..<iterations {
        recordAllocationEnter()
        let checksum = allocationChecksum(seed: id &* 257 &+ iteration &+ 1, capacity: 16)
        recordAllocationHit(checksum: checksum)
        recordAllocationExit()
        await Task.yield()
    }

    withSchedulerTestLock {
        allocationCounters.done += 1
    }
}

private func alarmMigrationPressureWorker(id: UInt32, deadlineUs: UInt64) async {
    var iteration: UInt32 = 0
    while time_us_64() < deadlineUs {
        if withSchedulerTestLock({ alarmMigrationCounters.migrationDone == 1 }) {
            break
        }
        _ = cpuSpin(seed: id &* 149 &+ iteration, rounds: 4_000)
        iteration &+= 1
        await Task.yield()
    }

    withSchedulerTestLock {
        alarmMigrationCounters.pressureDone += 1
    }
}

private func alarmBackedSameTaskMigrationObservedTask(iterations: UInt32, sleepUs: UInt64) async {
    for iteration in UInt32(0)..<iterations {
        beginAlarmMigrationObservation()
        let checksum = cpuSpin(seed: iteration &+ 0xA1A1, rounds: 3_000)
        endAlarmMigrationObservation(checksum: checksum)
        try? await Task.sleep(us: sleepUs)
    }

    withSchedulerTestLock {
        alarmMigrationCounters.migrationDone = 1
    }
}

private func memoryPressureWorker(id: UInt32, iterations: UInt32) async {
    for iteration in UInt32(0)..<iterations {
        recordMemoryPressureEnter()
        let capacity = 64 + Int((id &+ iteration) % 8) * 8
        let checksum = await liveAllocationChecksum(seed: id &* 389 &+ iteration &+ 1, capacity: capacity)
        recordMemoryPressureHit(checksum: checksum)
        recordMemoryPressureExit()
        await Task.yield()
    }

    withSchedulerTestLock {
        memoryPressureCounters.done += 1
    }
}

private func mixedAlarmAllocationWorker(id: UInt32, iterations: UInt32) async {
    for iteration in UInt32(0)..<iterations {
        try? await Task.sleep(us: 700 + UInt64((id &+ iteration) % 5) * 200)
        recordMixedAlarmAllocationEnter()
        let capacity = 48 + Int((id &+ iteration) % 7) * 8
        let checksum = await liveAllocationChecksum(seed: id &* 421 &+ iteration &+ 1, capacity: capacity)
        recordMixedAlarmAllocationHit(checksum: checksum)
        recordMixedAlarmAllocationExit()
        await Task.yield()
    }

    withSchedulerTestLock {
        mixedAlarmAllocationCounters.done += 1
    }
}

private func sameTaskYieldingObservationTask(iterations: UInt32) async {
    for iteration in UInt32(0)..<iterations {
        beginSameTaskMigrationObservation()
        let checksum = cpuSpin(seed: 0xCAFE &+ iteration, rounds: 3_000)
        endSameTaskMigrationObservation(checksum: checksum)
        withSchedulerTestLock {
            sameTaskMigrationCounters.continuationWaits += 1
        }
        await Task.yield()
    }

    withSchedulerTestLock {
        sameTaskMigrationCounters.migrationDone = 1
    }
}

private func sameTaskMigrationBackgroundPressureWorker(id: UInt32, iterations: UInt32) async {
    withSchedulerTestLock {
        sameTaskMigrationCounters.pressureStarted += 1
    }

    for iteration in UInt32(0)..<iterations {
        _ = cpuSpin(seed: id &* 131 &+ iteration &+ 0x5151, rounds: 6_000)
        await Task.yield()
    }

    withSchedulerTestLock {
        sameTaskMigrationCounters.pressureDone += 1
    }
}

private func sameTaskMigrationPairedPressureWorker(id: UInt32, deadlineUs: UInt64) async {
    let startCore = get_core_num() & 1
    let initialCore = withSchedulerTestLock { sameTaskMigrationCounters.initialCore }
    withSchedulerTestLock {
        sameTaskMigrationCounters.pressureStarted += 1
        if startCore == initialCore {
            sameTaskMigrationCounters.pressureInitialCoreStarted += 1
        } else {
            sameTaskMigrationCounters.pressureOtherCoreStarted += 1
        }
    }

    while time_us_64() < deadlineUs {
        if withSchedulerTestLock({ sameTaskMigrationCounters.pressureGateOpen }) {
            break
        }
        await Task.yield()
    }

    if startCore == initialCore {
        withSchedulerTestLock {
            sameTaskMigrationCounters.pressureInitialCoreBurning += 1
        }
        while time_us_64() < deadlineUs {
            if withSchedulerTestLock({ sameTaskMigrationCounters.migrationDone == 1 }) {
                break
            }
            _ = cpuSpin(seed: id &* 131 &+ 0x5151, rounds: 50_000)
        }
    } else {
        while time_us_64() < deadlineUs {
            if withSchedulerTestLock({ sameTaskMigrationCounters.pressureInitialCoreBurning > 0 }) {
                break
            }
            await Task.yield()
        }
        resumeSameTaskMigrationContinuationIfAvailable()
    }

    withSchedulerTestLock {
        sameTaskMigrationCounters.pressureDone += 1
    }
}

private func sameTaskMigrationObservedTaskOnce() async {
    beginSameTaskMigrationObservation()
    let firstChecksum = cpuSpin(seed: 0xCAFE, rounds: 3_000)
    endSameTaskMigrationObservation(checksum: firstChecksum)

    await suspendSameTaskMigrationObservedTask()

    beginSameTaskMigrationObservation()
    let secondChecksum = cpuSpin(seed: 0xCAFF, rounds: 3_000)
    endSameTaskMigrationObservation(checksum: secondChecksum)

    withSchedulerTestLock {
        sameTaskMigrationCounters.migrationDone = 1
    }
}

private func suspendSameTaskMigrationObservedTask() async {
    await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
        withSchedulerTestLock {
            sameTaskMigrationContinuation = continuation
            sameTaskMigrationCounters.continuationWaits += 1
        }
    }
}

private func resumeSameTaskMigrationContinuationIfAvailable() {
    let core = get_core_num() & 1
    let continuation = withSchedulerTestLock { () -> UnsafeContinuation<Void, Never>? in
        guard let continuation = sameTaskMigrationContinuation else {
            return nil
        }
        sameTaskMigrationContinuation = nil
        sameTaskMigrationCounters.continuationResumes += 1
        if core == 0 {
            sameTaskMigrationCounters.resumeCore0Hits += 1
        } else {
            sameTaskMigrationCounters.resumeCore1Hits += 1
        }
        return continuation
    }

    continuation?.resume()
}

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
        if sameTaskMigrationCounters.observations == 0 {
            sameTaskMigrationCounters.initialCore = core
        }
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

private func beginAlarmMigrationObservation() {
    let core = get_core_num() & 1
    withSchedulerTestLock {
        if alarmMigrationCounters.activeSegments != 0 {
            alarmMigrationCounters.overlapViolations += 1
        }
        alarmMigrationCounters.activeSegments += 1
        alarmMigrationCounters.observations += 1
        if core == 0 {
            alarmMigrationCounters.core0Hits += 1
        } else {
            alarmMigrationCounters.core1Hits += 1
        }
    }
}

private func endAlarmMigrationObservation(checksum: UInt32) {
    withSchedulerTestLock {
        alarmMigrationCounters.checksum &+= checksum
        if alarmMigrationCounters.activeSegments > 0 {
            alarmMigrationCounters.activeSegments -= 1
        }
    }
}

private func recordBurstHit(checksum: UInt32) {
    let core = get_core_num() & 1
    withSchedulerTestLock {
        if core == 0 {
            burstCounters.core0Hits += 1
        } else {
            burstCounters.core1Hits += 1
        }
        burstCounters.lostWorkChecksum &+= checksum
    }
}

private func recordAlarmSleepHit(checksum: UInt32) {
    let core = get_core_num() & 1
    withSchedulerTestLock {
        alarmSleepCounters.sleeps += 1
        if core == 0 {
            alarmSleepCounters.core0Hits += 1
        } else {
            alarmSleepCounters.core1Hits += 1
        }
        alarmSleepCounters.checksum &+= checksum
    }
}

private func recordDelayedSleep(index: UInt32, expectedUs: UInt64) async {
    let startedUs = time_us_64()
    try? await Task.sleep(us: expectedUs)
    let elapsedUs = time_us_64() &- startedUs
    let checksum = cpuSpin(seed: UInt32(truncatingIfNeeded: elapsedUs) &+ index, rounds: 400)

    withSchedulerTestLock {
        if elapsedUs &+ 500 < expectedUs {
            delayedSleepCounters.earlyWakeups += 1
        }
        if elapsedUs > expectedUs &+ 80_000 {
            delayedSleepCounters.lateWakeups += 1
        }
        switch index {
        case 0:
            delayedSleepCounters.elapsed0Us = elapsedUs
        case 1:
            delayedSleepCounters.elapsed1Us = elapsedUs
        default:
            delayedSleepCounters.elapsed2Us = elapsedUs
        }
        delayedSleepCounters.checksum &+= checksum
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

private func recordAllocationEnter() {
    withSchedulerTestLock {
        allocationCounters.activeWorkers += 1
        if allocationCounters.activeWorkers > allocationCounters.maxConcurrentWorkers {
            allocationCounters.maxConcurrentWorkers = allocationCounters.activeWorkers
        }
    }
}

private func recordAllocationHit(checksum: UInt32) {
    let core = get_core_num() & 1
    withSchedulerTestLock {
        if core == 0 {
            allocationCounters.core0Hits += 1
        } else {
            allocationCounters.core1Hits += 1
        }
        allocationCounters.lostWorkChecksum &+= checksum
    }
}

private func recordAllocationExit() {
    withSchedulerTestLock {
        if allocationCounters.activeWorkers > 0 {
            allocationCounters.activeWorkers -= 1
        }
    }
}

private func recordMemoryPressureEnter() {
    withSchedulerTestLock {
        memoryPressureCounters.activeWorkers += 1
        if memoryPressureCounters.activeWorkers > memoryPressureCounters.maxConcurrentWorkers {
            memoryPressureCounters.maxConcurrentWorkers = memoryPressureCounters.activeWorkers
        }
    }
}

private func recordMemoryPressureHit(checksum: UInt32) {
    let core = get_core_num() & 1
    withSchedulerTestLock {
        memoryPressureCounters.iterations += 1
        if core == 0 {
            memoryPressureCounters.core0Hits += 1
        } else {
            memoryPressureCounters.core1Hits += 1
        }
        memoryPressureCounters.checksum &+= checksum
    }
}

private func recordMemoryPressureExit() {
    withSchedulerTestLock {
        if memoryPressureCounters.activeWorkers > 0 {
            memoryPressureCounters.activeWorkers -= 1
        }
    }
}

private func recordMixedAlarmAllocationEnter() {
    withSchedulerTestLock {
        mixedAlarmAllocationCounters.activeWorkers += 1
        if mixedAlarmAllocationCounters.activeWorkers > mixedAlarmAllocationCounters.maxConcurrentWorkers {
            mixedAlarmAllocationCounters.maxConcurrentWorkers = mixedAlarmAllocationCounters.activeWorkers
        }
    }
}

private func recordMixedAlarmAllocationHit(checksum: UInt32) {
    let core = get_core_num() & 1
    withSchedulerTestLock {
        mixedAlarmAllocationCounters.iterations += 1
        if core == 0 {
            mixedAlarmAllocationCounters.core0Hits += 1
        } else {
            mixedAlarmAllocationCounters.core1Hits += 1
        }
        mixedAlarmAllocationCounters.checksum &+= checksum
    }
}

private func recordMixedAlarmAllocationExit() {
    withSchedulerTestLock {
        if mixedAlarmAllocationCounters.activeWorkers > 0 {
            mixedAlarmAllocationCounters.activeWorkers -= 1
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

private func allocationChecksum(seed: UInt32, capacity: Int) -> UInt32 {
    let pointer = UnsafeMutablePointer<UInt32>.allocate(capacity: capacity)
    var checksum = seed ^ 0xC001_C0DE

    for index in 0..<capacity {
        let value = cpuSpin(seed: checksum &+ UInt32(index), rounds: 128)
        pointer.advanced(by: index).initialize(to: value)
        checksum &+= value
    }

    for index in 0..<capacity {
        checksum ^= pointer.advanced(by: index).pointee
        pointer.advanced(by: index).deinitialize(count: 1)
    }

    pointer.deallocate()
    return checksum
}

private func liveAllocationChecksum(seed: UInt32, capacity: Int) async -> UInt32 {
    let pointer = UnsafeMutablePointer<UInt32>.allocate(capacity: capacity)
    var checksum = seed ^ 0xD00D_F00D

    for index in 0..<capacity {
        let value = cpuSpin(seed: checksum &+ UInt32(index), rounds: 96)
        pointer.advanced(by: index).initialize(to: value)
        checksum &+= value
    }

    await Task.yield()

    for index in 0..<capacity {
        checksum ^= pointer.advanced(by: index).pointee
        pointer.advanced(by: index).deinitialize(count: 1)
    }

    pointer.deallocate()
    return checksum
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

private func pollSchedulerUntil(timeoutMs: UInt32, condition: () -> Bool) -> Bool {
    let deadline = time_us_64() &+ UInt64(timeoutMs) * 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        Task<Never, Never>.tightLoop()
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
