//% -- test yaml
//% name: SingleCoreConcurrencyConfiguration
//% timeout: 6s
//% concurrency: true
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 6000
//% -----------

import CPicoSDK
import CPicoConcurrency

private nonisolated(unsafe) let singleCoreConfigLock: UnsafeMutablePointer<mutex_t> = {
    let lock = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    lock.initialize(to: mutex_t())
    mutex_init(lock)
    return lock
}()

private struct SingleCoreConfigCounters {
    var done: UInt32 = 0
    var core0Hits: UInt32 = 0
    var core1Hits: UInt32 = 0
    var checksum: UInt32 = 0
}

private nonisolated(unsafe) var singleCoreConfigCounters = SingleCoreConfigCounters()

/// Goal: validate explicit multicore startup by omission. The device test
/// runner does not start core1 automatically, and this test intentionally does
/// not call `ConcurrencyRuntime.startMulticore()`. Even under many yielding
/// tasks, scheduler work should remain on core0.
func core1DisabledKeepsConcurrencyWorkOnCore0() async throws {
    resetSingleCoreConfigCounters()

    for workerID in UInt32(0)..<8 {
        Task {
            await singleCoreConfigWorker(id: workerID)
        }
    }

    let completed = await waitForSingleCoreConfigCondition(timeoutMs: 4_000) {
        withSingleCoreConfigLock {
            singleCoreConfigCounters.done == 8
        }
    }

    let snapshot = withSingleCoreConfigLock { singleCoreConfigCounters }
    print("single-core-config done=\(snapshot.done) c0=\(snapshot.core0Hits) c1=\(snapshot.core1Hits) sum=\(snapshot.checksum)")

    try deviceExpect(completed, "single-core configuration workers did not complete")
    try deviceExpect(snapshot.core0Hits > 0, "single-core configuration never observed core0 work")
    try deviceExpect(snapshot.core1Hits == 0, "single-core configuration allowed work on core1")
}

private func singleCoreConfigWorker(id: UInt32) async {
    var checksum = id &+ 1
    for iteration in UInt32(0)..<80 {
        checksum = singleCoreConfigSpin(seed: checksum &+ iteration, rounds: 2_000)
        recordSingleCoreConfigHit()
        await Task.yield()
    }

    withSingleCoreConfigLock {
        singleCoreConfigCounters.done += 1
        singleCoreConfigCounters.checksum &+= checksum
    }
}

private func recordSingleCoreConfigHit() {
    withSingleCoreConfigLock {
        if (get_core_num() & 1) == 0 {
            singleCoreConfigCounters.core0Hits += 1
        } else {
            singleCoreConfigCounters.core1Hits += 1
        }
    }
}

private func resetSingleCoreConfigCounters() {
    withSingleCoreConfigLock {
        singleCoreConfigCounters = SingleCoreConfigCounters()
    }
}

private func withSingleCoreConfigLock<T>(_ body: () -> T) -> T {
    mutex_enter_blocking(singleCoreConfigLock)
    defer {
        mutex_exit(singleCoreConfigLock)
    }
    return body()
}

private func waitForSingleCoreConfigCondition(timeoutMs: UInt64, condition: () -> Bool) async -> Bool {
    let deadline = time_us_64() &+ timeoutMs &* 1_000
    while time_us_64() < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

private func singleCoreConfigSpin(seed: UInt32, rounds: UInt32) -> UInt32 {
    var value = seed
    for index in UInt32(0)..<rounds {
        value = value &* 1_664_525 &+ 1_013_904_223 &+ index
        value ^= value >> 13
    }
    return value
}
