import ConcurrencyShims
import CPicoSDK

/// Swift facade for the C scheduler core.
///
/// The performance-sensitive runtime paths live in `ConcurrencyShims.c`. This
/// object keeps the public Swift API, async-context compatibility hook, deferred
/// Swift closure execution, and CPU metrics stream surface in one place.
final class SchedulerSystem {
    private var core0Context = async_context_poll_t()

#if CPUMetrics
    private struct CPUUsageSnapshotState {
        var core0Report: CPUStats?
        var core1Report: CPUStats?
        var core0Sequence: UInt64 = 0
        var core1Sequence: UInt64 = 0
        var sequence: UInt64 = 0
        var nextCoreIndex: UInt8 = 0
    }

    private var core0Usage = RuntimeCPUUsageMeter(core: .core0)
    private var core1Usage = RuntimeCPUUsageMeter(core: .core1)
    private var core1MetricsActive = false
    private var cpuUsageSnapshots = CPUUsageSnapshotState()
    private var cpuUsageSnapshotsLock = mutex_t()
#endif

    init() {
        cshims_scheduler_prepare_lock()
        guard async_context_poll_init_with_defaults(&core0Context) else {
            fatalError("[CPicoConcurrency] failed to initialize scheduler async_context")
        }
#if CPUMetrics
        mutex_init(&cpuUsageSnapshotsLock)
#endif
    }

    @discardableResult
    func pollOnce() -> Int32 {
        cshims_scheduler_poll_once()
    }

    @discardableResult
    func pollOnce(on core: CoreID) -> Int32 {
        _ = core
        return cshims_scheduler_poll_once()
    }

    func waitForWork() {
        cshims_scheduler_wait_for_work_forever()
    }

    func startMulticore() {
        cshims_scheduler_start_multicore()
#if CPUMetrics
        core1MetricsActive = true
#endif
    }

#if CPUMetrics
    func cpuUsageEvents(for core: CPUCore) -> AsyncStream<CPUStats> {
        makeCPUUsageStream(core: core)
    }

    func cpuUsageEvents() -> AsyncStream<CPUStats> {
        makeCPUUsageStream(core: nil)
    }

    func recordInterruptCPUUsage(_ event: RuntimeCPUUsageMeter.Event, coreIndex: UInt) {
        meter(for: coreIndex)?.pointee.record(event: event)
    }

    func recordSchedulerTaskStart(coreIndex: UInt) {
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        meter(for: coreIndex)?.pointee.record(event: .enterTask(name: "runtimeScheduler.job"))
    }

    func recordSchedulerTaskEnd(coreIndex: UInt) {
        meter(for: coreIndex)?.pointee.record(event: .exitTask(name: "runtimeScheduler.job"))
    }

    func recordSchedulerIdleSample(coreIndex: UInt) {
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        meter(for: coreIndex)?.pointee.sample()
    }

    func collectCPUUsageReports() {
        collectCPUUsageReport(core: .core0, report: core0Usage.reportIfNeeded())
        if core1MetricsActive {
            collectCPUUsageReport(core: .core1, report: core1Usage.reportIfNeeded())
        }
    }

    private func makeCPUUsageStream(core: CPUCore?) -> AsyncStream<CPUStats> {
        var sequence: UInt64 = 0
        return AsyncStream<CPUStats> {
            guard let sample = await self.nextCPUUsageReport(core: core, after: sequence) else {
                return nil
            }
            sequence = sample.sequence
            return sample.report
        }
    }

    private func nextCPUUsageReport(core: CPUCore?, after sequence: UInt64) async -> (report: CPUStats, sequence: UInt64)? {
        while true {
            if Task.isCancelled {
                return nil
            }
            if let report = latestCPUUsageReport(core: core, after: sequence) {
                return report
            }
            await Task.yield()
        }
    }

    private func latestCPUUsageReport(core: CPUCore?, after sequence: UInt64) -> (report: CPUStats, sequence: UInt64)? {
        withCPUUsageSnapshotsLock {
            if let core {
                switch core {
                case .core0:
                    guard cpuUsageSnapshots.core0Sequence > sequence, let report = cpuUsageSnapshots.core0Report else {
                        return nil
                    }
                    return (report, cpuUsageSnapshots.core0Sequence)
                case .core1:
                    guard cpuUsageSnapshots.core1Sequence > sequence, let report = cpuUsageSnapshots.core1Report else {
                        return nil
                    }
                    return (report, cpuUsageSnapshots.core1Sequence)
                }
            }

            for offset in UInt8(0)..<2 {
                let index = (cpuUsageSnapshots.nextCoreIndex &+ offset) & 1
                if index == 0,
                   cpuUsageSnapshots.core0Sequence > sequence,
                   let report = cpuUsageSnapshots.core0Report {
                    cpuUsageSnapshots.nextCoreIndex = 1
                    return (report, cpuUsageSnapshots.core0Sequence)
                }
                if index == 1,
                   cpuUsageSnapshots.core1Sequence > sequence,
                   let report = cpuUsageSnapshots.core1Report {
                    cpuUsageSnapshots.nextCoreIndex = 0
                    return (report, cpuUsageSnapshots.core1Sequence)
                }
            }

            return nil
        }
    }

    private func collectCPUUsageReport(core: CPUCore, report: CPUStats?) {
        guard let report else {
            return
        }

        withCPUUsageSnapshotsLock {
            cpuUsageSnapshots.sequence &+= 1
            switch core {
            case .core0:
                cpuUsageSnapshots.core0Report = report
                cpuUsageSnapshots.core0Sequence = cpuUsageSnapshots.sequence
            case .core1:
                cpuUsageSnapshots.core1Report = report
                cpuUsageSnapshots.core1Sequence = cpuUsageSnapshots.sequence
            }
        }
    }

    private func meter(for coreIndex: UInt) -> UnsafeMutablePointer<RuntimeCPUUsageMeter>? {
        switch coreIndex {
        case 0:
            return withUnsafeMutablePointer(to: &core0Usage) { $0 }
        case 1:
            return withUnsafeMutablePointer(to: &core1Usage) { $0 }
        default:
            assertionFailure("[CPicoConcurrency] CPU metrics received invalid core index \(coreIndex)")
            return nil
        }
    }

    private func withCPUUsageSnapshotsLock<T>(_ body: () -> T) -> T {
        mutex_enter_blocking(&cpuUsageSnapshotsLock)
        defer {
            mutex_exit(&cpuUsageSnapshotsLock)
        }
        return body()
    }
#endif

    func schedule(_ block: @escaping () -> Void) {
        let item = DeferredWorkItem()
        _ = Unmanaged.passRetained(item)
        item.configure(block: block) {
            Unmanaged.passUnretained(item).release()
        }
        enqueueDeferred(item)
    }

    func enqueueDeferred(_ item: DeferredWorkItem, preferredCore: CoreID? = nil) {
        _ = preferredCore
        cshims_scheduler_enqueue_deferred(Unmanaged.passUnretained(item).toOpaque())
    }

    func callWithAsyncContext(_ body: (UnsafeMutableRawPointer) -> Void) {
        withUnsafeMutablePointer(to: &core0Context.core) { contextPtr in
            body(UnsafeMutableRawPointer(contextPtr))
        }
    }
}

nonisolated(unsafe) var cshimsRuntimeScheduler = SchedulerSystem()

/// SPI bridge for code that still needs direct async-context access.
@_spi(Internal) public func callWithAsyncContext(_ body: (UnsafeMutableRawPointer) -> Void) {
    cshimsRuntimeScheduler.callWithAsyncContext(body)
}

@_cdecl("cshims_scheduler_run_deferred_item")
func cshims_scheduler_run_deferred_item(_ item: UnsafeMutableRawPointer?) {
    guard let item else {
        assertionFailure("[CPicoConcurrency] scheduler received nil deferred item")
        return
    }
    Unmanaged<DeferredWorkItem>.fromOpaque(item).takeUnretainedValue().execute()
}

#if CPUMetrics
@_cdecl("cshims_scheduler_record_task_start")
func cshims_scheduler_record_task_start(_ core: UInt32) {
    cshimsRuntimeScheduler.recordSchedulerTaskStart(coreIndex: UInt(core))
}

@_cdecl("cshims_scheduler_record_task_end")
func cshims_scheduler_record_task_end(_ core: UInt32) {
    cshimsRuntimeScheduler.recordSchedulerTaskEnd(coreIndex: UInt(core))
}

@_cdecl("cshims_scheduler_record_idle_sample")
func cshims_scheduler_record_idle_sample(_ core: UInt32) {
    cshimsRuntimeScheduler.recordSchedulerIdleSample(coreIndex: UInt(core))
}

@_cdecl("cshims_scheduler_collect_cpu_reports")
func cshims_scheduler_collect_cpu_reports() {
    cshimsRuntimeScheduler.collectCPUUsageReports()
}
#endif
