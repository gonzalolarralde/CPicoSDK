import ConcurrencyShims
import CPicoSDK

/// Compile-only facade for a clean-room embedded Swift concurrency scheduler.
///
/// This branch intentionally contains no working scheduler policy. The public
/// API and Swift runtime entrypoints remain linkable so a future implementation
/// can replace the internals without rediscovering the boundary with
/// `_Concurrency`, multicore startup, deferred IRQ work, timers, and CPU stats.
final class SchedulerSystem {
    private var core0Context = async_context_poll_t()

    init() {
        guard async_context_poll_init_with_defaults(&core0Context) else {
            fatalError("[CPicoConcurrency] clean-room scheduler shell: failed to initialize placeholder async_context")
        }
    }

    func enqueueImmediate(
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        _ = JobEnvelope(
            kind: .immediate,
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond,
            timeUs: 0,
            identity: TaskIdentity.resolve(job: job),
            priorityBucket: JobPriorityBucket.resolve(job: job)
        )
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement immediate enqueue")
    }

    func enqueueDelayed(
        delayUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        _ = JobEnvelope(
            kind: .delayed,
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond,
            timeUs: delayUs,
            identity: TaskIdentity.resolve(job: job),
            priorityBucket: JobPriorityBucket.resolve(job: job)
        )
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement delayed enqueue")
    }

    func enqueueDeadline(
        deadlineUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        _ = JobEnvelope(
            kind: .deadline,
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond,
            timeUs: deadlineUs,
            identity: TaskIdentity.resolve(job: job),
            priorityBucket: JobPriorityBucket.resolve(job: job)
        )
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement deadline enqueue")
    }

    @discardableResult
    func pollOnce() -> Int32 {
        pollOnce(on: CoreID.current)
    }

    @discardableResult
    func pollOnce(on core: CoreID) -> Int32 {
        _ = core
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement scheduler poll")
    }

    func waitForWork() {
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement scheduler wait")
    }

    func startMulticore() {
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement multicore startup")
    }

#if CPUMetrics
    func cpuUsageEvents(for core: CPUCore) -> AsyncStream<CPUStats> {
        _ = core
        return AsyncStream { nil }
    }

    func cpuUsageEvents() -> AsyncStream<CPUStats> {
        AsyncStream { nil }
    }

    func recordInterruptCPUUsage(_ event: RuntimeCPUUsageMeter.Event, coreIndex: UInt) {
        _ = event
        _ = coreIndex
    }
#endif

    func schedule(_ block: @escaping () -> Void) {
        _ = block
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement deferred scheduler work")
    }

    func enqueueDeferred(_ item: DeferredWorkItem, preferredCore: CoreID? = nil) {
        _ = item
        _ = preferredCore
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement ISR-safe deferred enqueue")
    }

    func run(slot: UnsafeMutablePointer<JobSlot>) {
        _ = slot
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement fired job slot handling")
    }

    func jobWillRun(envelope: JobEnvelope, core: CoreID) {
        _ = envelope
        _ = core
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement job start accounting")
    }

    func jobDidRun(envelope: JobEnvelope, core: CoreID) {
        _ = envelope
        _ = core
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement job completion")
    }

    func timerFired(envelope: JobEnvelope) {
        _ = envelope
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement fired timer requeue")
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

/// C shim entrypoint for one nonblocking scheduler poll.
@_cdecl("cshims_scheduler_poll_once")
func cshims_scheduler_poll_once() -> Int32 {
    cshimsRuntimeScheduler.pollOnce()
}

/// C shim entrypoint used by Swift runtime global/main enqueue hooks.
@_cdecl("cshims_scheduler_enqueue_immediate")
func cshims_scheduler_enqueue_immediate(
    _ job: UnsafeMutableRawPointer?,
    _ executorFirst: UnsafeMutableRawPointer?,
    _ executorSecond: UnsafeMutableRawPointer?
) {
    cshimsRuntimeScheduler.enqueueImmediate(
        job: job,
        executorFirst: executorFirst,
        executorSecond: executorSecond
    )
}

/// C shim entrypoint used by Swift runtime delayed enqueue hooks.
@_cdecl("cshims_scheduler_enqueue_delayed")
func cshims_scheduler_enqueue_delayed(
    _ delayUs: UInt64,
    _ job: UnsafeMutableRawPointer?,
    _ executorFirst: UnsafeMutableRawPointer?,
    _ executorSecond: UnsafeMutableRawPointer?
) {
    cshimsRuntimeScheduler.enqueueDelayed(
        delayUs: delayUs,
        job: job,
        executorFirst: executorFirst,
        executorSecond: executorSecond
    )
}

/// C shim entrypoint used by Swift runtime deadline enqueue hooks.
@_cdecl("cshims_scheduler_enqueue_deadline")
func cshims_scheduler_enqueue_deadline(
    _ deadlineUs: UInt64,
    _ job: UnsafeMutableRawPointer?,
    _ executorFirst: UnsafeMutableRawPointer?,
    _ executorSecond: UnsafeMutableRawPointer?
) {
    cshimsRuntimeScheduler.enqueueDeadline(
        deadlineUs: deadlineUs,
        job: job,
        executorFirst: executorFirst,
        executorSecond: executorSecond
    )
}

/// C shim entrypoint for donating the current core until work arrives.
@_cdecl("cshims_scheduler_wait_for_work_forever")
func cshims_scheduler_wait_for_work_forever() {
    cshimsRuntimeScheduler.waitForWork()
}
