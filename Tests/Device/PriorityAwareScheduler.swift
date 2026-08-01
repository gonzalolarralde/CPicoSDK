//% -- test yaml
//% name: PriorityAwareScheduler
//% timeout: 45s
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT]
//% alts:
//%   - name: weighted
//%   - name: clutchLite
//%     traits:
//%       add: [SchedulerClutchLite]
//%   - name: xnuClutch
//%     traits:
//%       add: [SchedulerXNUClutch]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 45000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let prioritySchedulerLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct PrioritySchedulerCounters {
    var backgroundDone: UInt32 = 0
    var highDone: UInt32 = 0
    var highFirstBackgroundDone: UInt32 = UInt32.max
    var highCore0Hits: UInt32 = 0
    var highCore1Hits: UInt32 = 0
    var defaultDone: UInt32 = 0
    var sameTaskDone: UInt32 = 0
    var sameTaskObservations: UInt32 = 0
    var sameTaskExpected: UInt32 = 0
    var sameTaskFIFOErrors: UInt32 = 0
    var sameTaskOverlapErrors: UInt32 = 0
    var sameTaskActive: UInt32 = 0
    var burstDone: UInt32 = 0
    var burstChecksum: UInt32 = 0
    var checksum: UInt32 = 0
}

private nonisolated(unsafe) var prioritySchedulerCounters = PrioritySchedulerCounters()

/// Goal: high-priority tasks should cut ahead of a runnable background backlog.
func highPriorityJobsRunBeforeBackgroundBacklog() async throws {
    ConcurrencyRuntime.startMulticore()
    resetPrioritySchedulerCounters()

    for workerID in UInt32(0)..<10 {
        Task(priority: .background) {
            await priorityBackgroundWorker(id: workerID, iterations: 80)
        }
    }

    for _ in 0..<16 {
        await Task.yield()
    }

    for workerID in UInt32(0)..<4 {
        Task(priority: .high) {
            await priorityHighWorker(id: workerID, iterations: 8)
        }
    }

    let completed = await waitForPrioritySchedulerCondition(timeoutMs: 5_000) {
        withPrioritySchedulerLock {
            prioritySchedulerCounters.highDone == 4 && prioritySchedulerCounters.backgroundDone == 10
        }
    }

    let snapshot = withPrioritySchedulerLock { prioritySchedulerCounters }
    print("priority-backlog high=\(snapshot.highDone) bg=\(snapshot.backgroundDone) bgAtHigh=\(snapshot.highFirstBackgroundDone) hc0=\(snapshot.highCore0Hits) hc1=\(snapshot.highCore1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(completed, "priority backlog workers did not complete")
    try deviceExpect(snapshot.highFirstBackgroundDone < UInt32.max, "high-priority work never recorded first completion")
    try deviceExpect(snapshot.highFirstBackgroundDone < 5, "high-priority work waited behind most background completions")
}

/// Goal: priority is global, not tied to a preselected core queue.
func priorityIsGlobalAcrossCores() async throws {
    ConcurrencyRuntime.startMulticore()
    resetPrioritySchedulerCounters()

    for workerID in UInt32(0)..<8 {
        Task(priority: .default) {
            await priorityDefaultWorker(id: workerID, iterations: 60)
        }
    }

    for _ in 0..<12 {
        await Task.yield()
    }

    for workerID in UInt32(0)..<6 {
        Task(priority: .high) {
            await priorityHighWorker(id: workerID, iterations: 6)
        }
    }

    let highCompleted = await waitForPrioritySchedulerCondition(timeoutMs: 2_500) {
        withPrioritySchedulerLock {
            prioritySchedulerCounters.highDone == 6
        }
    }
    let allCompleted = await waitForPrioritySchedulerCondition(timeoutMs: 4_000) {
        withPrioritySchedulerLock {
            prioritySchedulerCounters.defaultDone == 8
        }
    }

    let snapshot = withPrioritySchedulerLock { prioritySchedulerCounters }
    print("priority-global high=\(snapshot.highDone) default=\(snapshot.defaultDone) hc0=\(snapshot.highCore0Hits) hc1=\(snapshot.highCore1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(highCompleted, "global high-priority workers did not complete promptly")
    try deviceExpect(allCompleted, "global default-priority workers did not complete")
    try deviceExpect(snapshot.highCore0Hits > 0, "global high-priority work never ran on core0")
    try deviceExpect(snapshot.highCore1Hits > 0, "global high-priority work never ran on core1")
}

/// Goal: one logical task remains serialized and observes its own FIFO order.
func sameTaskWaitingQueuePreservesSerializationAndFIFO() async throws {
    ConcurrencyRuntime.startMulticore()
    resetPrioritySchedulerCounters()

    Task(priority: .default) {
        await prioritySameTaskFIFOProbe(iterations: 48)
    }
    for workerID in UInt32(0)..<6 {
        Task(priority: .high) {
            await priorityHighWorker(id: workerID, iterations: 16)
        }
    }

    let completed = await waitForPrioritySchedulerCondition(timeoutMs: 4_000) {
        withPrioritySchedulerLock {
            prioritySchedulerCounters.sameTaskDone == 1 && prioritySchedulerCounters.highDone == 6
        }
    }

    let snapshot = withPrioritySchedulerLock { prioritySchedulerCounters }
    print("priority-same-task done=\(snapshot.sameTaskDone) obs=\(snapshot.sameTaskObservations) expected=\(snapshot.sameTaskExpected) fifo=\(snapshot.sameTaskFIFOErrors) overlap=\(snapshot.sameTaskOverlapErrors) high=\(snapshot.highDone)")

    try deviceExpect(completed, "same-task FIFO probe did not complete")
    try deviceExpect(snapshot.sameTaskObservations == 48, "same-task FIFO probe lost observations")
    try deviceExpect(snapshot.sameTaskFIFOErrors == 0, "same-task FIFO order was not preserved")
    try deviceExpect(snapshot.sameTaskOverlapErrors == 0, "same logical task overlapped with itself")
}

/// Goal: bursts across Swift task priorities do not drop work.
func priorityBurstDoesNotDropWork() async throws {
    ConcurrencyRuntime.startMulticore()
    resetPrioritySchedulerCounters()

    for workerID in UInt32(0)..<3 {
        Task(priority: .high) {
            await priorityBurstWorker(id: workerID, bucket: 0)
        }
        Task(priority: .userInitiated) {
            await priorityBurstWorker(id: workerID, bucket: 1)
        }
        Task(priority: .default) {
            await priorityBurstWorker(id: workerID, bucket: 2)
        }
        Task(priority: .utility) {
            await priorityBurstWorker(id: workerID, bucket: 3)
        }
        Task(priority: .background) {
            await priorityBurstWorker(id: workerID, bucket: 4)
        }
    }

    let completed = await waitForPrioritySchedulerCondition(timeoutMs: 4_000) {
        withPrioritySchedulerLock {
            prioritySchedulerCounters.burstDone == 15
        }
    }

    let snapshot = withPrioritySchedulerLock { prioritySchedulerCounters }
    print("priority-burst done=\(snapshot.burstDone) sum=\(snapshot.burstChecksum)")

    try deviceExpect(completed, "priority burst workers did not complete")
    try deviceExpect(snapshot.burstDone == 15, "priority burst dropped completions")
    try deviceExpect(snapshot.burstChecksum == 0x4bf7a610, "priority burst checksum mismatch")
}

private func priorityBackgroundWorker(id: UInt32, iterations: UInt32) async {
    var checksum = id &+ 1
    for iteration in UInt32(0)..<iterations {
        checksum = prioritySpin(seed: checksum &+ iteration, rounds: 900)
        await Task.yield()
    }
    withPrioritySchedulerLock {
        prioritySchedulerCounters.backgroundDone += 1
        prioritySchedulerCounters.checksum &+= checksum
    }
}

private func priorityDefaultWorker(id: UInt32, iterations: UInt32) async {
    var checksum = id &+ 11
    for iteration in UInt32(0)..<iterations {
        checksum = prioritySpin(seed: checksum &+ iteration, rounds: 1_100)
        await Task.yield()
    }
    withPrioritySchedulerLock {
        prioritySchedulerCounters.defaultDone += 1
        prioritySchedulerCounters.checksum &+= checksum
    }
}

private func priorityHighWorker(id: UInt32, iterations: UInt32) async {
    var checksum = id &+ 101
    for iteration in UInt32(0)..<iterations {
        checksum = prioritySpin(seed: checksum &+ iteration, rounds: 700)
        recordPriorityHighHit()
        await Task.yield()
    }
    withPrioritySchedulerLock {
        if prioritySchedulerCounters.highDone == 0 {
            prioritySchedulerCounters.highFirstBackgroundDone = prioritySchedulerCounters.backgroundDone
        }
        prioritySchedulerCounters.highDone += 1
        prioritySchedulerCounters.checksum &+= checksum
    }
}

private func prioritySameTaskFIFOProbe(iterations: UInt32) async {
    for iteration in UInt32(0)..<iterations {
        withPrioritySchedulerLock {
            if prioritySchedulerCounters.sameTaskActive != 0 {
                prioritySchedulerCounters.sameTaskOverlapErrors += 1
            }
            prioritySchedulerCounters.sameTaskActive = 1
            if prioritySchedulerCounters.sameTaskExpected != iteration {
                prioritySchedulerCounters.sameTaskFIFOErrors += 1
            }
            prioritySchedulerCounters.sameTaskExpected += 1
            prioritySchedulerCounters.sameTaskObservations += 1
            prioritySchedulerCounters.sameTaskActive = 0
        }
        await Task.yield()
    }
    withPrioritySchedulerLock {
        prioritySchedulerCounters.sameTaskDone = 1
    }
}

private func priorityBurstWorker(id: UInt32, bucket: UInt32) async {
    var checksum = (bucket &+ 1) &* 97 &+ id
    for iteration in UInt32(0)..<12 {
        checksum = prioritySpin(seed: checksum &+ iteration &+ bucket, rounds: 500)
        await Task.yield()
    }
    withPrioritySchedulerLock {
        prioritySchedulerCounters.burstDone += 1
        prioritySchedulerCounters.burstChecksum &+= checksum
    }
}

private func recordPriorityHighHit() {
    withPrioritySchedulerLock {
        if (get_core_num() & 1) == 0 {
            prioritySchedulerCounters.highCore0Hits += 1
        } else {
            prioritySchedulerCounters.highCore1Hits += 1
        }
    }
}

private func resetPrioritySchedulerCounters() {
    withPrioritySchedulerLock {
        prioritySchedulerCounters = PrioritySchedulerCounters()
    }
}

private func withPrioritySchedulerLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(prioritySchedulerLock)
    defer {
        mutex_exit(prioritySchedulerLock)
    }
    return body()
}

private func waitForPrioritySchedulerCondition(timeoutMs: UInt64, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ timeoutMs &* 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

private func prioritySpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 15
    }
    return value
}
