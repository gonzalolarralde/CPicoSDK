//% -- test yaml
//% name: SchedulerPolicyComparison
//% timeout: 15s
//% buildType: Release
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT]
//% alts:
//%   - name: weighted16
//%     traits:
//%       add: [SchedulerPolicyComparison]
//%   - name: clutchLite
//%     traits:
//%       add: [SchedulerPolicyComparison, SchedulerClutchLite]
//%   - name: xnuClutchP
//%     traits:
//%       add: [SchedulerPolicyComparison, SchedulerXNUClutch]
//%   - name: directWgt0
//%   - name: directLite
//%     traits:
//%       add: [SchedulerClutchLite]
//%   - name: directXNU0
//%     traits:
//%       add: [SchedulerXNUClutch]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 15000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let schedulerPolicyBenchmarkLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct PolicyHandoffCounters {
    var ready: UInt32 = 0
    var done: UInt32 = 0
    var gateOpen = false
    var deadlineUs: UInt64 = 0
    var yields: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
}

private struct PolicyBurstCounters {
    var pressureReady: UInt32 = 0
    var pressureDone: UInt32 = 0
    var highDone: UInt32 = 0
    var gateOpen = false
    var pressureDeadlineUs: UInt64 = 0
    var submittedUs: UInt64 = 0
    var latencyCount: UInt32 = 0
    var latencySumUs: UInt64 = 0
    var latencyMaxUs: UInt64 = 0
    var pressureUnits: UInt32 = 0
}

private struct PolicyStarvationCounters {
    var highReady: UInt32 = 0
    var backgroundReady: UInt32 = 0
    var highDone: UInt32 = 0
    var backgroundDone: UInt32 = 0
    var gateOpen = false
    var gateOpenedUs: UInt64 = 0
    var deadlineUs: UInt64 = 0
    var backgroundFirstUs: UInt64 = 0
    var backgroundMaxGapUs: UInt64 = 0
    var backgroundSamples: UInt32 = 0
    var highUnits: UInt32 = 0
}

private nonisolated(unsafe) var policyHandoffCounters = PolicyHandoffCounters()
private nonisolated(unsafe) var policyBurstCounters = PolicyBurstCounters()
private nonisolated(unsafe) var policyStarvationCounters = PolicyStarvationCounters()

/// Goal: isolate scheduler handoff cost with eight same-priority tasks that do
/// no work beyond observing a core and yielding back to the runtime.
func policySamePriorityYieldHandoffThroughput() async throws {
    ConcurrencyRuntime.startMulticore()
    withSchedulerPolicyBenchmarkLock {
        policyHandoffCounters = PolicyHandoffCounters()
    }

    let workerCount: UInt32 = 8
    for _ in UInt32(0)..<workerCount {
        Task(priority: .default) {
            await policyHandoffWorker()
        }
    }

    let ready = await waitForSchedulerPolicyBenchmark(timeoutMs: 1_000) {
        withSchedulerPolicyBenchmarkLock { policyHandoffCounters.ready == workerCount }
    }
    let startedUs = time_us_64()
    withSchedulerPolicyBenchmarkLock {
        policyHandoffCounters.deadlineUs = startedUs &+ 500_000
        policyHandoffCounters.gateOpen = true
    }

    let completed = await waitForSchedulerPolicyBenchmark(timeoutMs: 1_500) {
        withSchedulerPolicyBenchmarkLock { policyHandoffCounters.done == workerCount }
    }
    let elapsedUs = time_us_64() &- startedUs
    let snapshot = withSchedulerPolicyBenchmarkLock { policyHandoffCounters }
    let handoffsPerSecond = elapsedUs > 0 ? UInt64(snapshot.yields) * 1_000_000 / elapsedUs : 0
    let smallerCoreHits = snapshot.core0Hits < snapshot.core1Hits ? snapshot.core0Hits : snapshot.core1Hits
    let largerCoreHits = snapshot.core0Hits > snapshot.core1Hits ? snapshot.core0Hits : snapshot.core1Hits
    let balance = largerCoreHits > 0 ? smallerCoreHits * 1_000 / largerCoreHits : 0
    let raw = "workers=\(workerCount), yields=\(snapshot.yields), elapsedUs=\(elapsedUs), coreHits=\(snapshot.core0Hits)/\(snapshot.core1Hits)"
    logScore("policy-yield-handoff", raw, "handoffsPerSecond", handoffsPerSecond, "higher is better")
    logScore("policy-yield-handoff", raw, "coreBalance", balance, "/1000 closest to 1000 is best")

    try deviceExpect(ready, "policy handoff workers did not reach the gate")
    try deviceExpect(completed, "policy handoff workers did not complete")
    try deviceExpect(snapshot.yields > 0, "policy handoff benchmark observed no yields")
    try deviceExpect(snapshot.core0Hits > 0 && snapshot.core1Hits > 0, "policy handoff did not use both cores")
}

/// Goal: measure how quickly an interactive burst cuts into an already-runnable
/// background workload. The runner reports raw mean/max latency; it does not
/// impose one policy's expected value on the other policies.
func policyHighPriorityBurstLatencyUnderBackgroundPressure() async throws {
    ConcurrencyRuntime.startMulticore()
    withSchedulerPolicyBenchmarkLock {
        policyBurstCounters = PolicyBurstCounters()
    }

    let pressureCount: UInt32 = 8
    let highCount: UInt32 = 8
    for id in UInt32(0)..<pressureCount {
        Task(priority: .background) {
            await policyBurstPressureWorker(id: id)
        }
    }
    let ready = await waitForSchedulerPolicyBenchmark(timeoutMs: 1_000) {
        withSchedulerPolicyBenchmarkLock { policyBurstCounters.pressureReady == pressureCount }
    }
    withSchedulerPolicyBenchmarkLock {
        policyBurstCounters.pressureDeadlineUs = time_us_64() &+ 500_000
        policyBurstCounters.gateOpen = true
    }
    try? await Task.sleep(us: 50_000)

    let submittedUs = time_us_64()
    withSchedulerPolicyBenchmarkLock {
        policyBurstCounters.submittedUs = submittedUs
    }
    for id in UInt32(0)..<highCount {
        Task(priority: .high) {
            await policyBurstHighWorker(id: id)
        }
    }

    let highCompleted = await waitForSchedulerPolicyBenchmark(timeoutMs: 1_000) {
        withSchedulerPolicyBenchmarkLock { policyBurstCounters.highDone == highCount }
    }
    let pressureCompleted = await waitForSchedulerPolicyBenchmark(timeoutMs: 1_500) {
        withSchedulerPolicyBenchmarkLock { policyBurstCounters.pressureDone == pressureCount }
    }
    let snapshot = withSchedulerPolicyBenchmarkLock { policyBurstCounters }
    let meanLatencyUs = snapshot.latencyCount > 0
        ? snapshot.latencySumUs / UInt64(snapshot.latencyCount)
        : 0
    let raw = "high=\(snapshot.highDone), samples=\(snapshot.latencyCount), pressureUnits=\(snapshot.pressureUnits)"
    logScore("policy-high-burst", raw, "meanStartLatencyUs", meanLatencyUs, "lower is better")
    logScore("policy-high-burst", raw, "maxStartLatencyUs", snapshot.latencyMaxUs, "lower is better")

    try deviceExpect(ready, "policy burst pressure workers did not reach the gate")
    try deviceExpect(highCompleted, "policy high-priority burst did not complete")
    try deviceExpect(pressureCompleted, "policy burst pressure workers did not complete")
    try deviceExpect(snapshot.latencyCount == highCount, "policy burst lost latency samples")
}

/// Goal: quantify the other side of responsiveness: service delay for a
/// continuously-ready background task while foreground work remains runnable.
func policyBackgroundProgressUnderSustainedForegroundPressure() async throws {
    ConcurrencyRuntime.startMulticore()
    withSchedulerPolicyBenchmarkLock {
        policyStarvationCounters = PolicyStarvationCounters()
    }

    let highCount: UInt32 = 8
    for id in UInt32(0)..<highCount {
        Task(priority: .high) {
            await policyStarvationHighWorker(id: id)
        }
    }
    Task(priority: .background) {
        await policyStarvationBackgroundWorker()
    }

    let ready = await waitForSchedulerPolicyBenchmark(timeoutMs: 1_000) {
        withSchedulerPolicyBenchmarkLock {
            policyStarvationCounters.highReady == highCount &&
                policyStarvationCounters.backgroundReady == 1
        }
    }
    let openedUs = time_us_64()
    withSchedulerPolicyBenchmarkLock {
        policyStarvationCounters.gateOpenedUs = openedUs
        policyStarvationCounters.deadlineUs = openedUs &+ 650_000
        policyStarvationCounters.gateOpen = true
    }

    let completed = await waitForSchedulerPolicyBenchmark(timeoutMs: 1_800) {
        withSchedulerPolicyBenchmarkLock {
            policyStarvationCounters.highDone == highCount &&
                policyStarvationCounters.backgroundDone == 1
        }
    }
    let snapshot = withSchedulerPolicyBenchmarkLock { policyStarvationCounters }
    let firstServiceUs = snapshot.backgroundFirstUs >= snapshot.gateOpenedUs
        ? snapshot.backgroundFirstUs - snapshot.gateOpenedUs
        : 0
    let raw = "backgroundSamples=\(snapshot.backgroundSamples), highUnits=\(snapshot.highUnits)"
    logScore("policy-background-progress", raw, "firstServiceLatencyUs", firstServiceUs, "lower is better")
    logScore("policy-background-progress", raw, "maxServiceGapUs", snapshot.backgroundMaxGapUs, "lower is better")

    try deviceExpect(ready, "policy starvation workers did not reach the gate")
    try deviceExpect(completed, "policy starvation workload did not complete")
    try deviceExpect(snapshot.backgroundSamples > 0, "background task received no service")
}

private func policyHandoffWorker() async {
    withSchedulerPolicyBenchmarkLock { policyHandoffCounters.ready += 1 }
    while !withSchedulerPolicyBenchmarkLock({ policyHandoffCounters.gateOpen }) {
        await Task.yield()
    }
    let deadlineUs = withSchedulerPolicyBenchmarkLock { policyHandoffCounters.deadlineUs }
    var yields: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    while time_us_64() < deadlineUs {
        if (get_core_num() & 1) == 0 { core0Hits += 1 } else { core1Hits += 1 }
        yields += 1
        await Task.yield()
    }
    withSchedulerPolicyBenchmarkLock {
        policyHandoffCounters.done += 1
        policyHandoffCounters.yields += yields
        policyHandoffCounters.core0Hits += core0Hits
        policyHandoffCounters.core1Hits += core1Hits
    }
}

private func policyBurstPressureWorker(id: UInt32) async {
    withSchedulerPolicyBenchmarkLock { policyBurstCounters.pressureReady += 1 }
    while !withSchedulerPolicyBenchmarkLock({ policyBurstCounters.gateOpen }) {
        await Task.yield()
    }
    let deadlineUs = withSchedulerPolicyBenchmarkLock { policyBurstCounters.pressureDeadlineUs }
    var units: UInt32 = 0
    var checksum = id &+ 1
    while time_us_64() < deadlineUs {
        checksum = schedulerPolicySpin(checksum &+ units, rounds: 500)
        units += 1
        await Task.yield()
    }
    withSchedulerPolicyBenchmarkLock {
        policyBurstCounters.pressureDone += 1
        policyBurstCounters.pressureUnits &+= units &+ (checksum & 1)
    }
}

private func policyBurstHighWorker(id: UInt32) async {
    let observedUs = time_us_64()
    let submittedUs = withSchedulerPolicyBenchmarkLock { policyBurstCounters.submittedUs }
    let latencyUs = observedUs &- submittedUs
    var checksum = id &+ 101
    withSchedulerPolicyBenchmarkLock {
        policyBurstCounters.latencyCount += 1
        policyBurstCounters.latencySumUs &+= latencyUs
        if latencyUs > policyBurstCounters.latencyMaxUs {
            policyBurstCounters.latencyMaxUs = latencyUs
        }
    }
    for iteration in UInt32(0)..<32 {
        checksum = schedulerPolicySpin(checksum &+ iteration, rounds: 200)
        await Task.yield()
    }
    withSchedulerPolicyBenchmarkLock {
        policyBurstCounters.highDone += 1
        policyBurstCounters.pressureUnits &+= checksum & 1
    }
}

private func policyStarvationHighWorker(id: UInt32) async {
    withSchedulerPolicyBenchmarkLock { policyStarvationCounters.highReady += 1 }
    while !withSchedulerPolicyBenchmarkLock({ policyStarvationCounters.gateOpen }) {
        await Task.yield()
    }
    let deadlineUs = withSchedulerPolicyBenchmarkLock { policyStarvationCounters.deadlineUs }
    var units: UInt32 = 0
    var checksum = id &+ 1001
    while time_us_64() < deadlineUs {
        checksum = schedulerPolicySpin(checksum &+ units, rounds: 300)
        units += 1
        await Task.yield()
    }
    withSchedulerPolicyBenchmarkLock {
        policyStarvationCounters.highDone += 1
        policyStarvationCounters.highUnits &+= units &+ (checksum & 1)
    }
}

private func policyStarvationBackgroundWorker() async {
    withSchedulerPolicyBenchmarkLock { policyStarvationCounters.backgroundReady = 1 }
    while !withSchedulerPolicyBenchmarkLock({ policyStarvationCounters.gateOpen }) {
        await Task.yield()
    }
    let snapshot = withSchedulerPolicyBenchmarkLock {
        (policyStarvationCounters.gateOpenedUs, policyStarvationCounters.deadlineUs)
    }
    var previousUs = snapshot.0
    var samples: UInt32 = 0
    var maxGapUs: UInt64 = 0
    var firstUs: UInt64 = 0
    while time_us_64() < snapshot.1 {
        let observedUs = time_us_64()
        if samples == 0 { firstUs = observedUs }
        let gapUs = observedUs &- previousUs
        if gapUs > maxGapUs { maxGapUs = gapUs }
        previousUs = observedUs
        samples += 1
        await Task.yield()
    }
    let terminalGapUs = snapshot.1 >= previousUs ? snapshot.1 - previousUs : 0
    if terminalGapUs > maxGapUs { maxGapUs = terminalGapUs }
    withSchedulerPolicyBenchmarkLock {
        policyStarvationCounters.backgroundFirstUs = firstUs
        policyStarvationCounters.backgroundMaxGapUs = maxGapUs
        policyStarvationCounters.backgroundSamples = samples
        policyStarvationCounters.backgroundDone = 1
    }
}

private func waitForSchedulerPolicyBenchmark(
    timeoutMs: UInt64,
    condition: () -> Bool
) async -> Bool {
    let deadlineUs = time_us_64() &+ timeoutMs * 1_000
    while time_us_64() < deadlineUs {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private func withSchedulerPolicyBenchmarkLock<Result>(_ body: () -> Result) -> Result {
    mutex_enter_blocking(schedulerPolicyBenchmarkLock)
    defer { mutex_exit(schedulerPolicyBenchmarkLock) }
    return body()
}

@inline(never)
private func schedulerPolicySpin(_ seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed | 1
    for iteration in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ iteration
        value ^= value >> 13
    }
    return value
}
