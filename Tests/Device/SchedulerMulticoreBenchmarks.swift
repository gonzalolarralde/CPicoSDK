//% -- test yaml
//% name: SchedulerMulticoreBenchmarks
//% timeout: 25s
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 25000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let multicoreBenchmarkLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct MulticoreThroughputCounters {
    var done: UInt32 = 0
    var units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private struct PriorityTraceCounters {
    var ready: UInt32 = 0
    var done: UInt32 = 0
    var gateOpen: Bool = false
    var gateOpenedUs: UInt64 = 0
    var events: UInt32 = 0
    var firstBucketsPacked: UInt64 = 0
    var high: UInt32 = 0
    var defaultPriority: UInt32 = 0
    var low: UInt32 = 0
    var background: UInt32 = 0
    var slice0High: UInt32 = 0
    var slice0Default: UInt32 = 0
    var slice0Low: UInt32 = 0
    var slice0Background: UInt32 = 0
    var slice1High: UInt32 = 0
    var slice1Default: UInt32 = 0
    var slice1Low: UInt32 = 0
    var slice1Background: UInt32 = 0
    var slice2High: UInt32 = 0
    var slice2Default: UInt32 = 0
    var slice2Low: UInt32 = 0
    var slice2Background: UInt32 = 0
    var slice3High: UInt32 = 0
    var slice3Default: UInt32 = 0
    var slice3Low: UInt32 = 0
    var slice3Background: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private struct FairnessCounters {
    var ready: UInt32 = 0
    var done: UInt32 = 0
    var gateOpen: Bool = false
    var worker0Units: UInt32 = 0
    var worker1Units: UInt32 = 0
    var worker2Units: UInt32 = 0
    var worker3Units: UInt32 = 0
    var worker4Units: UInt32 = 0
    var worker5Units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private struct YieldCadenceCounters {
    var done: UInt32 = 0
    var unitsEvery1: UInt32 = 0
    var unitsEvery4: UInt32 = 0
    var unitsEvery16: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private struct AlarmJitterCounters {
    var sleepersDone: UInt32 = 0
    var pressureDone: UInt32 = 0
    var pressureUnits: UInt32 = 0
    var minLateUs: UInt64 = UInt64.max
    var maxLateUs: UInt64 = 0
    var sumLateUs: UInt64 = 0
    var lateCount: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private struct BurstCounters {
    var ready: UInt32 = 0
    var done: UInt32 = 0
    var gateOpen: Bool = false
    var gateOpenedUs: UInt64 = 0
    var firstObservedUs: UInt64 = 0
    var lastObservedUs: UInt64 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private struct ContinuationCounters {
    var slotsReady: UInt32 = 0
    var resumed: UInt32 = 0
    var consumed: UInt32 = 0
    var resumersDone: UInt32 = 0
    var resumerCore0Hits: UInt32 = 0
    var resumerCore1Hits: UInt32 = 0
    var consumerCore0Hits: UInt32 = 0
    var consumerCore1Hits: UInt32 = 0
    var resumedChecksum: UInt32 = 0
    var consumedChecksum: UInt32 = 0
}

private struct AllocationBenchmarkCounters {
    var done: UInt32 = 0
    var units: UInt32 = 0
    var beforeUsed: UInt32 = 0
    var afterUsed: UInt32 = 0
    var beforeTotalFree: UInt32 = 0
    var afterTotalFree: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private nonisolated(unsafe) var multicoreThroughputCounters = MulticoreThroughputCounters()
private nonisolated(unsafe) var priorityTraceCounters = PriorityTraceCounters()
private nonisolated(unsafe) var fairnessCounters = FairnessCounters()
private nonisolated(unsafe) var yieldCadenceCounters = YieldCadenceCounters()
private nonisolated(unsafe) var alarmJitterCounters = AlarmJitterCounters()
private nonisolated(unsafe) var burstCounters = BurstCounters()
private nonisolated(unsafe) var continuationCounters = ContinuationCounters()
private nonisolated(unsafe) var allocationBenchmarkCounters = AllocationBenchmarkCounters()
private nonisolated(unsafe) var continuationSlots: [UnsafeContinuation<UInt32, Never>?] =
    Array(repeating: nil, count: 128)

/// Goal: capture multicore busy-work throughput. The benchmark tracks how many
/// cooperative CPU work units complete in a fixed window after core1 joins the
/// scheduler, and verifies both cores contributed work.
func multicoreBusyWorkThroughputOverFixedWindow() async throws {
    ConcurrencyRuntime.startMulticore()
    resetMulticoreThroughputCounters()

    let workerCount: UInt32 = 8
    let durationUs: UInt64 = 700_000
    let startedUs = time_us_64()

    for workerID in UInt32(0)..<workerCount {
        Task {
            await multicoreThroughputWorker(id: workerID, durationUs: durationUs)
        }
    }

    let completed = await waitForMulticoreBenchmarkCondition(timeoutMs: 2_500) {
        withMulticoreBenchmarkLock {
            multicoreThroughputCounters.done == workerCount
        }
    }

    let elapsedMs = (time_us_64() &- startedUs) / 1_000
    let snapshot = withMulticoreBenchmarkLock { multicoreThroughputCounters }
    let unitsPerSecond = elapsedMs > 0 ? UInt64(snapshot.units) * 1_000 / elapsedMs : 0

    print("bench-multi-throughput workers=\(workerCount) units=\(snapshot.units) ups=\(unitsPerSecond) elapsed=\(elapsedMs) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(completed, "multicore throughput workers did not complete")
    try deviceExpect(snapshot.done == workerCount, "multicore throughput lost worker completions")
    try deviceExpect(snapshot.units > 0, "multicore throughput did not record work units")
    try deviceExpect(snapshot.core0Hits > 0, "multicore throughput never observed core0 work")
    try deviceExpect(snapshot.core1Hits > 0, "multicore throughput never observed core1 work")
}

/// Goal: record priority execution order when tasks are released together. The
/// benchmark records early execution buckets and per-slice work distribution
/// for Task priorities without asserting scheduler policy yet.
func priorityWorkExecutionOrderIsRecordedOverTimeSlices() async throws {
    ConcurrencyRuntime.startMulticore()
    resetPriorityTraceCounters()

    let workersPerPriority: UInt32 = 2
    let totalWorkers = workersPerPriority * 4

    for workerID in UInt32(0)..<workersPerPriority {
        Task(priority: .high) {
            await priorityTraceWorker(priorityBucket: 0, workerID: workerID)
        }
        Task(priority: .default) {
            await priorityTraceWorker(priorityBucket: 1, workerID: workerID)
        }
        Task(priority: .low) {
            await priorityTraceWorker(priorityBucket: 2, workerID: workerID)
        }
        Task(priority: .background) {
            await priorityTraceWorker(priorityBucket: 3, workerID: workerID)
        }
    }

    let ready = await waitForMulticoreBenchmarkCondition(timeoutMs: 1_500) {
        withMulticoreBenchmarkLock {
            priorityTraceCounters.ready == totalWorkers
        }
    }
    withMulticoreBenchmarkLock {
        priorityTraceCounters.gateOpenedUs = time_us_64()
        priorityTraceCounters.gateOpen = true
    }

    let completed = await waitForMulticoreBenchmarkCondition(timeoutMs: 2_500) {
        withMulticoreBenchmarkLock {
            priorityTraceCounters.done == totalWorkers
        }
    }

    let snapshot = withMulticoreBenchmarkLock { priorityTraceCounters }
    print("bench-priority ready=\(snapshot.ready) done=\(snapshot.done) firstPacked=\(snapshot.firstBucketsPacked) totals=\(snapshot.high)/\(snapshot.defaultPriority)/\(snapshot.low)/\(snapshot.background) s0=\(snapshot.slice0High)/\(snapshot.slice0Default)/\(snapshot.slice0Low)/\(snapshot.slice0Background) s1=\(snapshot.slice1High)/\(snapshot.slice1Default)/\(snapshot.slice1Low)/\(snapshot.slice1Background) s2=\(snapshot.slice2High)/\(snapshot.slice2Default)/\(snapshot.slice2Low)/\(snapshot.slice2Background) s3=\(snapshot.slice3High)/\(snapshot.slice3Default)/\(snapshot.slice3Low)/\(snapshot.slice3Background) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(ready, "priority benchmark workers did not all become ready")
    try deviceExpect(completed, "priority benchmark workers did not complete")
    try deviceExpect(snapshot.high > 0, "priority benchmark recorded no high-priority work")
    try deviceExpect(snapshot.defaultPriority > 0, "priority benchmark recorded no default-priority work")
    try deviceExpect(snapshot.low > 0, "priority benchmark recorded no low-priority work")
    try deviceExpect(snapshot.background > 0, "priority benchmark recorded no background-priority work")
}

/// Goal: measure same-priority fairness without requiring a precise balance.
/// Equal-priority workers start behind one gate, then record per-worker units so
/// later scheduler changes can compare min/max spread.
func samePriorityFairnessOverFixedWindow() async throws {
    ConcurrencyRuntime.startMulticore()
    resetFairnessCounters()

    let workerCount: UInt32 = 6
    for workerID in UInt32(0)..<workerCount {
        Task(priority: .default) {
            await fairnessWorker(id: workerID)
        }
    }

    let ready = await waitForMulticoreBenchmarkCondition(timeoutMs: 1_000) {
        withMulticoreBenchmarkLock {
            fairnessCounters.ready == workerCount
        }
    }
    withMulticoreBenchmarkLock {
        fairnessCounters.gateOpen = true
    }

    let completed = await waitForMulticoreBenchmarkCondition(timeoutMs: 2_000) {
        withMulticoreBenchmarkLock {
            fairnessCounters.done == workerCount
        }
    }

    let snapshot = withMulticoreBenchmarkLock { fairnessCounters }
    let minUnits = min6(snapshot.worker0Units, snapshot.worker1Units, snapshot.worker2Units, snapshot.worker3Units, snapshot.worker4Units, snapshot.worker5Units)
    let maxUnits = max6(snapshot.worker0Units, snapshot.worker1Units, snapshot.worker2Units, snapshot.worker3Units, snapshot.worker4Units, snapshot.worker5Units)
    let totalUnits = snapshot.worker0Units + snapshot.worker1Units + snapshot.worker2Units + snapshot.worker3Units + snapshot.worker4Units + snapshot.worker5Units

    print("bench-fairness ready=\(snapshot.ready) done=\(snapshot.done) total=\(totalUnits) min=\(minUnits) max=\(maxUnits) workers=\(snapshot.worker0Units)/\(snapshot.worker1Units)/\(snapshot.worker2Units)/\(snapshot.worker3Units)/\(snapshot.worker4Units)/\(snapshot.worker5Units) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(ready, "fairness benchmark workers did not all become ready")
    try deviceExpect(completed, "fairness benchmark workers did not complete")
    try deviceExpect(minUnits > 0, "at least one fairness worker recorded no work")
}

/// Goal: compare scheduler overhead for different cooperative yield cadences.
/// Workers yield every 1, 4, or 16 work units and the benchmark records the
/// resulting unit counts for later revision-to-revision comparisons.
func yieldCadenceThroughputComparison() async throws {
    ConcurrencyRuntime.startMulticore()
    resetYieldCadenceCounters()

    let workersPerCadence: UInt32 = 3
    for workerID in UInt32(0)..<workersPerCadence {
        Task {
            await yieldCadenceWorker(id: workerID, cadence: 1)
        }
        Task {
            await yieldCadenceWorker(id: workerID &+ 10, cadence: 4)
        }
        Task {
            await yieldCadenceWorker(id: workerID &+ 20, cadence: 16)
        }
    }

    let completed = await waitForMulticoreBenchmarkCondition(timeoutMs: 2_500) {
        withMulticoreBenchmarkLock {
            yieldCadenceCounters.done == workersPerCadence * 3
        }
    }

    let snapshot = withMulticoreBenchmarkLock { yieldCadenceCounters }
    print("bench-yield-cadence done=\(snapshot.done) units1=\(snapshot.unitsEvery1) units4=\(snapshot.unitsEvery4) units16=\(snapshot.unitsEvery16) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(completed, "yield-cadence benchmark workers did not complete")
    try deviceExpect(snapshot.unitsEvery1 > 0, "yield-every-1 group recorded no work")
    try deviceExpect(snapshot.unitsEvery4 > 0, "yield-every-4 group recorded no work")
    try deviceExpect(snapshot.unitsEvery16 > 0, "yield-every-16 group recorded no work")
}

/// Goal: measure alarm-backed sleep jitter while CPU pressure is running. This
/// benchmark records wake lateness as diagnostic output without enforcing a
/// tight timing threshold.
func alarmJitterUnderCPUPressure() async throws {
    ConcurrencyRuntime.startMulticore()
    resetAlarmJitterCounters()

    let sleeperCount: UInt32 = 8
    let pressureCount: UInt32 = 4
    for workerID in UInt32(0)..<pressureCount {
        Task {
            await alarmPressureWorker(id: workerID)
        }
    }
    for sleeperID in UInt32(0)..<sleeperCount {
        Task {
            await alarmJitterSleeper(id: sleeperID, sleepUs: 45_000 &+ UInt64(sleeperID) &* 2_000)
        }
    }

    let completed = await waitForMulticoreBenchmarkCondition(timeoutMs: 2_500) {
        withMulticoreBenchmarkLock {
            alarmJitterCounters.sleepersDone == sleeperCount &&
                alarmJitterCounters.pressureDone == pressureCount
        }
    }

    let snapshot = withMulticoreBenchmarkLock { alarmJitterCounters }
    let minLate = snapshot.minLateUs == UInt64.max ? 0 : snapshot.minLateUs
    let avgLate = snapshot.sleepersDone > 0 ? snapshot.sumLateUs / UInt64(snapshot.sleepersDone) : 0
    print("bench-alarm-jitter sleepers=\(snapshot.sleepersDone) pressure=\(snapshot.pressureDone) units=\(snapshot.pressureUnits) lateMin=\(minLate) lateAvg=\(avgLate) lateMax=\(snapshot.maxLateUs) lateCount=\(snapshot.lateCount) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(completed, "alarm jitter benchmark did not complete")
    try deviceExpect(snapshot.sleepersDone == sleeperCount, "alarm jitter benchmark lost sleepers")
    try deviceExpect(snapshot.pressureDone == pressureCount, "alarm jitter benchmark lost pressure workers")
}

/// Goal: measure burst enqueue latency. Many workers are ready before one gate
/// opens, then the benchmark records the first and last observed execution
/// times after release.
func burstEnqueueLatencyIsRecorded() async throws {
    ConcurrencyRuntime.startMulticore()
    resetBurstCounters()

    let workerCount: UInt32 = 24
    for workerID in UInt32(0)..<workerCount {
        Task {
            await burstWorker(id: workerID)
        }
    }

    let ready = await waitForMulticoreBenchmarkCondition(timeoutMs: 1_500) {
        withMulticoreBenchmarkLock {
            burstCounters.ready == workerCount
        }
    }
    withMulticoreBenchmarkLock {
        burstCounters.gateOpenedUs = time_us_64()
        burstCounters.gateOpen = true
    }

    let completed = await waitForMulticoreBenchmarkCondition(timeoutMs: 2_000) {
        withMulticoreBenchmarkLock {
            burstCounters.done == workerCount
        }
    }

    let snapshot = withMulticoreBenchmarkLock { burstCounters }
    let firstLatency = snapshot.firstObservedUs > snapshot.gateOpenedUs ? snapshot.firstObservedUs &- snapshot.gateOpenedUs : 0
    let lastLatency = snapshot.lastObservedUs > snapshot.gateOpenedUs ? snapshot.lastObservedUs &- snapshot.gateOpenedUs : 0
    let span = snapshot.lastObservedUs > snapshot.firstObservedUs ? snapshot.lastObservedUs &- snapshot.firstObservedUs : 0
    print("bench-burst ready=\(snapshot.ready) done=\(snapshot.done) firstUs=\(firstLatency) lastUs=\(lastLatency) spanUs=\(span) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(ready, "burst benchmark workers did not all become ready")
    try deviceExpect(completed, "burst benchmark workers did not complete")
    try deviceExpect(snapshot.done == workerCount, "burst benchmark lost workers")
    try deviceExpect(snapshot.core0Hits > 0, "burst benchmark never observed core0 work")
    try deviceExpect(snapshot.core1Hits > 0, "burst benchmark never observed core1 work")
}

/// Goal: measure explicit continuation resume throughput. Suspended consumer
/// tasks publish continuation slots, resumer tasks release them in parallel, and
/// the benchmark records resumptions per second and core participation.
func explicitContinuationThroughput() async throws {
    ConcurrencyRuntime.startMulticore()
    resetContinuationCounters()

    let continuationCount: UInt32 = 64
    let resumerCount: UInt32 = 4
    let startedUs = time_us_64()

    for slot in UInt32(0)..<continuationCount {
        Task {
            let value = await withUnsafeContinuation { continuation in
                storeContinuationSlot(slot, continuation)
            }
            recordContinuationConsumed(value)
        }
    }

    let slotsReady = await waitForMulticoreBenchmarkCondition(timeoutMs: 1_500) {
        withMulticoreBenchmarkLock {
            continuationCounters.slotsReady == continuationCount
        }
    }

    for resumerID in UInt32(0)..<resumerCount {
        Task {
            await continuationResumer(id: resumerID, resumerCount: resumerCount, continuationCount: continuationCount)
        }
    }

    let consumedExpectedValues = await waitForMulticoreBenchmarkCondition(timeoutMs: 2_000) {
        withMulticoreBenchmarkLock {
            continuationCounters.consumed == continuationCount
        }
    }

    let resumersCompleted = await waitForMulticoreBenchmarkCondition(timeoutMs: 1_500) {
        withMulticoreBenchmarkLock {
            continuationCounters.resumersDone == resumerCount
        }
    }

    let elapsedMs = (time_us_64() &- startedUs) / 1_000
    let snapshot = withMulticoreBenchmarkLock { continuationCounters }
    let perSecond = elapsedMs > 0 ? UInt64(snapshot.consumed) * 1_000 / elapsedMs : 0
    print("bench-continuation slots=\(snapshot.slotsReady) resumed=\(snapshot.resumed) consumed=\(snapshot.consumed) done=\(snapshot.resumersDone) rps=\(perSecond) elapsed=\(elapsedMs) rc0=\(snapshot.resumerCore0Hits) rc1=\(snapshot.resumerCore1Hits) cc0=\(snapshot.consumerCore0Hits) cc1=\(snapshot.consumerCore1Hits) rsum=\(snapshot.resumedChecksum) csum=\(snapshot.consumedChecksum)")

    try deviceExpect(slotsReady, "continuation benchmark slots did not become ready")
    try deviceExpect(resumersCompleted, "continuation benchmark resumers did not complete")
    try deviceExpect(consumedExpectedValues, "continuation benchmark consumer did not receive expected values")
    try deviceExpect(snapshot.resumed == continuationCount, "continuation benchmark lost resumed values")
    try deviceExpect(snapshot.consumed == continuationCount, "continuation benchmark lost consumed values")
    try deviceExpect(snapshot.resumedChecksum == snapshot.consumedChecksum, "continuation benchmark checksum mismatch")
}

/// Goal: measure allocation-heavy throughput and memory delta. Workers allocate
/// and free small buffers while doing CPU work so allocator/runtime overhead can
/// be compared between scheduler revisions.
func allocationHeavyThroughputAndMemoryDelta() async throws {
    ConcurrencyRuntime.startMulticore()
    resetAllocationBenchmarkCounters()

    let before = MemoryStats.sram
    withMulticoreBenchmarkLock {
        allocationBenchmarkCounters.beforeUsed = before.used
        allocationBenchmarkCounters.beforeTotalFree = before.totalFree
    }

    let workerCount: UInt32 = 8
    for workerID in UInt32(0)..<workerCount {
        Task {
            await allocationBenchmarkWorker(id: workerID)
        }
    }

    let completed = await waitForMulticoreBenchmarkCondition(timeoutMs: 3_000) {
        withMulticoreBenchmarkLock {
            allocationBenchmarkCounters.done == workerCount
        }
    }

    let after = MemoryStats.sram
    withMulticoreBenchmarkLock {
        allocationBenchmarkCounters.afterUsed = after.used
        allocationBenchmarkCounters.afterTotalFree = after.totalFree
    }

    let snapshot = withMulticoreBenchmarkLock { allocationBenchmarkCounters }
    let usedGrowth = snapshot.afterUsed > snapshot.beforeUsed ? snapshot.afterUsed - snapshot.beforeUsed : 0
    let freeLoss = snapshot.beforeTotalFree > snapshot.afterTotalFree ? snapshot.beforeTotalFree - snapshot.afterTotalFree : 0
    print("bench-allocation done=\(snapshot.done) units=\(snapshot.units) used=\(snapshot.beforeUsed)->\(snapshot.afterUsed) free=\(snapshot.beforeTotalFree)->\(snapshot.afterTotalFree) usedGrowth=\(usedGrowth) freeLoss=\(freeLoss) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(completed, "allocation benchmark workers did not complete")
    try deviceExpect(snapshot.units > 0, "allocation benchmark recorded no work")
    try deviceExpect(snapshot.core0Hits > 0, "allocation benchmark never observed core0 work")
    try deviceExpect(snapshot.core1Hits > 0, "allocation benchmark never observed core1 work")
    try deviceExpect(usedGrowth < 48_000, "allocation benchmark retained too much used memory")
    try deviceExpect(freeLoss < 48_000, "allocation benchmark lost too much free memory")
}

private func multicoreThroughputWorker(id: UInt32, durationUs: UInt64) async {
    let deadline = time_us_64() &+ durationUs
    var checksum = id &+ 1
    var units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0

    while time_us_64() < deadline {
        checksum = multicoreBenchmarkSpin(seed: checksum &+ units, rounds: 1_400)
        units += 1
        recordLocalCoreHits(core0Hits: &core0Hits, core1Hits: &core1Hits)
        await Task.yield()
    }

    withMulticoreBenchmarkLock {
        multicoreThroughputCounters.done += 1
        multicoreThroughputCounters.units += units
        multicoreThroughputCounters.core0Hits += core0Hits
        multicoreThroughputCounters.core1Hits += core1Hits
        multicoreThroughputCounters.checksum &+= checksum
    }
}

private func priorityTraceWorker(priorityBucket: UInt32, workerID: UInt32) async {
    markPriorityReady()
    while !priorityGateOpen() {
        await Task.yield()
    }

    let durationUs: UInt64 = 300_000
    let deadline = time_us_64() &+ durationUs
    var checksum = workerID &+ priorityBucket &* 101 &+ 1

    while time_us_64() < deadline {
        checksum = multicoreBenchmarkSpin(seed: checksum, rounds: 900)
        recordPriorityEvent(priorityBucket: priorityBucket, checksum: checksum)
        await Task.yield()
    }

    withMulticoreBenchmarkLock {
        priorityTraceCounters.done += 1
        priorityTraceCounters.checksum &+= checksum
    }
}

private func fairnessWorker(id: UInt32) async {
    withMulticoreBenchmarkLock {
        fairnessCounters.ready += 1
    }
    while !fairnessGateOpen() {
        await Task.yield()
    }

    let deadline = time_us_64() &+ 450_000
    var checksum = id &+ 1
    var units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0

    while time_us_64() < deadline {
        checksum = multicoreBenchmarkSpin(seed: checksum &+ units, rounds: 850)
        units += 1
        recordLocalCoreHits(core0Hits: &core0Hits, core1Hits: &core1Hits)
        await Task.yield()
    }

    withMulticoreBenchmarkLock {
        fairnessCounters.done += 1
        recordFairnessUnits(workerID: id, units: units)
        fairnessCounters.core0Hits += core0Hits
        fairnessCounters.core1Hits += core1Hits
        fairnessCounters.checksum &+= checksum
    }
}

private func yieldCadenceWorker(id: UInt32, cadence: UInt32) async {
    let deadline = time_us_64() &+ 450_000
    var checksum = id &+ cadence
    var units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0

    while time_us_64() < deadline {
        checksum = multicoreBenchmarkSpin(seed: checksum &+ units, rounds: 750)
        units += 1
        recordLocalCoreHits(core0Hits: &core0Hits, core1Hits: &core1Hits)
        if units % cadence == 0 {
            await Task.yield()
        }
    }

    withMulticoreBenchmarkLock {
        yieldCadenceCounters.done += 1
        switch cadence {
        case 1:
            yieldCadenceCounters.unitsEvery1 += units
        case 4:
            yieldCadenceCounters.unitsEvery4 += units
        default:
            yieldCadenceCounters.unitsEvery16 += units
        }
        yieldCadenceCounters.core0Hits += core0Hits
        yieldCadenceCounters.core1Hits += core1Hits
        yieldCadenceCounters.checksum &+= checksum
    }
}

private func alarmPressureWorker(id: UInt32) async {
    let deadline = time_us_64() &+ 450_000
    var checksum = id &+ 1
    var units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0

    while time_us_64() < deadline {
        checksum = multicoreBenchmarkSpin(seed: checksum &+ units, rounds: 1_000)
        units += 1
        recordLocalCoreHits(core0Hits: &core0Hits, core1Hits: &core1Hits)
        await Task.yield()
    }

    withMulticoreBenchmarkLock {
        alarmJitterCounters.pressureDone += 1
        alarmJitterCounters.pressureUnits += units
        alarmJitterCounters.core0Hits += core0Hits
        alarmJitterCounters.core1Hits += core1Hits
        alarmJitterCounters.checksum &+= checksum
    }
}

private func alarmJitterSleeper(id: UInt32, sleepUs: UInt64) async {
    let startedUs = time_us_64()
    try? await Task.sleep(us: sleepUs)
    let elapsedUs = time_us_64() &- startedUs
    let lateUs = elapsedUs > sleepUs ? elapsedUs &- sleepUs : 0
    let checksum = multicoreBenchmarkSpin(seed: id &+ UInt32(lateUs & 0xffff), rounds: 400)

    withMulticoreBenchmarkLock {
        alarmJitterCounters.sleepersDone += 1
        if lateUs < alarmJitterCounters.minLateUs {
            alarmJitterCounters.minLateUs = lateUs
        }
        if lateUs > alarmJitterCounters.maxLateUs {
            alarmJitterCounters.maxLateUs = lateUs
        }
        alarmJitterCounters.sumLateUs += lateUs
        if lateUs > 10_000 {
            alarmJitterCounters.lateCount += 1
        }
        if (get_core_num() & 1) == 0 {
            alarmJitterCounters.core0Hits += 1
        } else {
            alarmJitterCounters.core1Hits += 1
        }
        alarmJitterCounters.checksum &+= checksum
    }
}

private func burstWorker(id: UInt32) async {
    withMulticoreBenchmarkLock {
        burstCounters.ready += 1
    }
    while !burstGateOpen() {
        await Task.yield()
    }

    let observedUs = time_us_64()
    var checksum = multicoreBenchmarkSpin(seed: id &+ 1, rounds: 1_800)
    checksum = multicoreBenchmarkSpin(seed: checksum, rounds: 1_800)

    withMulticoreBenchmarkLock {
        burstCounters.done += 1
        if burstCounters.firstObservedUs == 0 || observedUs < burstCounters.firstObservedUs {
            burstCounters.firstObservedUs = observedUs
        }
        if observedUs > burstCounters.lastObservedUs {
            burstCounters.lastObservedUs = observedUs
        }
        if (get_core_num() & 1) == 0 {
            burstCounters.core0Hits += 1
        } else {
            burstCounters.core1Hits += 1
        }
        burstCounters.checksum &+= checksum
    }
}

private func storeContinuationSlot(_ slot: UInt32, _ continuation: UnsafeContinuation<UInt32, Never>) {
    withMulticoreBenchmarkLock {
        continuationSlots[Int(slot)] = continuation
        continuationCounters.slotsReady += 1
    }
}

private func continuationResumer(id: UInt32, resumerCount: UInt32, continuationCount: UInt32) async {
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var resumed: UInt32 = 0
    var checksum: UInt32 = 0

    var slot = id
    while slot < continuationCount {
        let value = 10_000 &+ slot
        let continuation = takeContinuationSlot(slot)
        continuation?.resume(returning: value)
        checksum &+= value
        resumed += 1
        recordLocalCoreHits(core0Hits: &core0Hits, core1Hits: &core1Hits)
        slot += resumerCount
        await Task.yield()
    }

    withMulticoreBenchmarkLock {
        continuationCounters.resumersDone += 1
        continuationCounters.resumed += resumed
        continuationCounters.resumerCore0Hits += core0Hits
        continuationCounters.resumerCore1Hits += core1Hits
        continuationCounters.resumedChecksum &+= checksum
    }
}

private func takeContinuationSlot(_ slot: UInt32) -> UnsafeContinuation<UInt32, Never>? {
    withMulticoreBenchmarkLock {
        let index = Int(slot)
        let continuation = continuationSlots[index]
        continuationSlots[index] = nil
        return continuation
    }
}

private func recordContinuationConsumed(_ value: UInt32) {
    withMulticoreBenchmarkLock {
        continuationCounters.consumed += 1
        continuationCounters.consumedChecksum &+= value
        if (get_core_num() & 1) == 0 {
            continuationCounters.consumerCore0Hits += 1
        } else {
            continuationCounters.consumerCore1Hits += 1
        }
    }
}

private func allocationBenchmarkWorker(id: UInt32) async {
    var checksum = id &+ 1
    var units: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0

    for iteration in UInt32(0)..<48 {
        let capacity = 32 + Int((id &+ iteration) % 48)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        for index in 0..<capacity {
            let value = UInt8(truncatingIfNeeded: checksum &+ UInt32(index))
            buffer.advanced(by: index).initialize(to: value)
            checksum &+= UInt32(value)
        }
        buffer.deinitialize(count: capacity)
        buffer.deallocate()

        checksum = multicoreBenchmarkSpin(seed: checksum, rounds: 1_100)
        units += 1
        recordLocalCoreHits(core0Hits: &core0Hits, core1Hits: &core1Hits)
        await Task.yield()
    }

    withMulticoreBenchmarkLock {
        allocationBenchmarkCounters.done += 1
        allocationBenchmarkCounters.units += units
        allocationBenchmarkCounters.core0Hits += core0Hits
        allocationBenchmarkCounters.core1Hits += core1Hits
        allocationBenchmarkCounters.checksum &+= checksum
    }
}

private func markPriorityReady() {
    withMulticoreBenchmarkLock {
        priorityTraceCounters.ready += 1
    }
}

private func priorityGateOpen() -> Bool {
    withMulticoreBenchmarkLock {
        priorityTraceCounters.gateOpen
    }
}

private func fairnessGateOpen() -> Bool {
    withMulticoreBenchmarkLock {
        fairnessCounters.gateOpen
    }
}

private func burstGateOpen() -> Bool {
    withMulticoreBenchmarkLock {
        burstCounters.gateOpen
    }
}

private func recordPriorityEvent(priorityBucket: UInt32, checksum: UInt32) {
    withMulticoreBenchmarkLock {
        let eventIndex = priorityTraceCounters.events
        priorityTraceCounters.events += 1
        if eventIndex < 16 {
            priorityTraceCounters.firstBucketsPacked |= UInt64(priorityBucket & 0xf) << UInt64(eventIndex * 4)
        }

        let elapsedUs = time_us_64() &- priorityTraceCounters.gateOpenedUs
        let slice = elapsedUs / 75_000
        recordPriorityTotal(priorityBucket)
        recordPrioritySlice(priorityBucket: priorityBucket, slice: slice)
        if (get_core_num() & 1) == 0 {
            priorityTraceCounters.core0Hits += 1
        } else {
            priorityTraceCounters.core1Hits += 1
        }
        priorityTraceCounters.checksum &+= checksum
    }
}

private func recordPriorityTotal(_ priorityBucket: UInt32) {
    switch priorityBucket {
    case 0:
        priorityTraceCounters.high += 1
    case 1:
        priorityTraceCounters.defaultPriority += 1
    case 2:
        priorityTraceCounters.low += 1
    default:
        priorityTraceCounters.background += 1
    }
}

private func recordPrioritySlice(priorityBucket: UInt32, slice: UInt64) {
    let cappedSlice = slice > 3 ? 3 : slice
    switch (cappedSlice, priorityBucket) {
    case (0, 0):
        priorityTraceCounters.slice0High += 1
    case (0, 1):
        priorityTraceCounters.slice0Default += 1
    case (0, 2):
        priorityTraceCounters.slice0Low += 1
    case (0, _):
        priorityTraceCounters.slice0Background += 1
    case (1, 0):
        priorityTraceCounters.slice1High += 1
    case (1, 1):
        priorityTraceCounters.slice1Default += 1
    case (1, 2):
        priorityTraceCounters.slice1Low += 1
    case (1, _):
        priorityTraceCounters.slice1Background += 1
    case (2, 0):
        priorityTraceCounters.slice2High += 1
    case (2, 1):
        priorityTraceCounters.slice2Default += 1
    case (2, 2):
        priorityTraceCounters.slice2Low += 1
    case (2, _):
        priorityTraceCounters.slice2Background += 1
    case (_, 0):
        priorityTraceCounters.slice3High += 1
    case (_, 1):
        priorityTraceCounters.slice3Default += 1
    case (_, 2):
        priorityTraceCounters.slice3Low += 1
    default:
        priorityTraceCounters.slice3Background += 1
    }
}

private func recordFairnessUnits(workerID: UInt32, units: UInt32) {
    switch workerID {
    case 0:
        fairnessCounters.worker0Units = units
    case 1:
        fairnessCounters.worker1Units = units
    case 2:
        fairnessCounters.worker2Units = units
    case 3:
        fairnessCounters.worker3Units = units
    case 4:
        fairnessCounters.worker4Units = units
    default:
        fairnessCounters.worker5Units = units
    }
}

private func recordLocalCoreHits(core0Hits: inout UInt32, core1Hits: inout UInt32) {
    if (get_core_num() & 1) == 0 {
        core0Hits += 1
    } else {
        core1Hits += 1
    }
}

private func resetMulticoreThroughputCounters() {
    withMulticoreBenchmarkLock {
        multicoreThroughputCounters = MulticoreThroughputCounters()
    }
}

private func resetPriorityTraceCounters() {
    withMulticoreBenchmarkLock {
        priorityTraceCounters = PriorityTraceCounters()
    }
}

private func resetFairnessCounters() {
    withMulticoreBenchmarkLock {
        fairnessCounters = FairnessCounters()
    }
}

private func resetYieldCadenceCounters() {
    withMulticoreBenchmarkLock {
        yieldCadenceCounters = YieldCadenceCounters()
    }
}

private func resetAlarmJitterCounters() {
    withMulticoreBenchmarkLock {
        alarmJitterCounters = AlarmJitterCounters()
    }
}

private func resetBurstCounters() {
    withMulticoreBenchmarkLock {
        burstCounters = BurstCounters()
    }
}

private func resetContinuationCounters() {
    withMulticoreBenchmarkLock {
        continuationCounters = ContinuationCounters()
        for index in continuationSlots.indices {
            continuationSlots[index] = nil
        }
    }
}

private func resetAllocationBenchmarkCounters() {
    withMulticoreBenchmarkLock {
        allocationBenchmarkCounters = AllocationBenchmarkCounters()
    }
}

private func withMulticoreBenchmarkLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(multicoreBenchmarkLock)
    defer {
        mutex_exit(multicoreBenchmarkLock)
    }
    return body()
}

private func waitForMulticoreBenchmarkCondition(timeoutMs: UInt64, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ timeoutMs &* 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

private func min6(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, _ e: UInt32, _ f: UInt32) -> UInt32 {
    var value = a
    if b < value { value = b }
    if c < value { value = c }
    if d < value { value = d }
    if e < value { value = e }
    if f < value { value = f }
    return value
}

private func max6(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, _ e: UInt32, _ f: UInt32) -> UInt32 {
    var value = a
    if b > value { value = b }
    if c > value { value = c }
    if d > value { value = d }
    if e > value { value = e }
    if f > value { value = f }
    return value
}

private func multicoreBenchmarkSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 13
    }
    return value
}
