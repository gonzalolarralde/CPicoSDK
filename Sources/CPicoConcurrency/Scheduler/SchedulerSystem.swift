import ConcurrencyShims
import CPicoSDK

/// Top-level facade for embedded Swift concurrency scheduling.
///
/// This is the only scheduler object exposed to the C shims. Runtime hooks enter
/// here with raw Swift jobs, the system resolves identity and placement, then it
/// hands an envelope to the selected core executor. The system owns cross-core
/// coordination state such as affinity and multicore enablement; executors own
/// per-core transport and async-context mechanics.
final class SchedulerSystem {
    private var executors: [2 of CoreExecutor] = [
        .init(core: .core0),
        .init(core: .core1),
    ]
    private var affinityTable = AffinityTable()
    private var multicoreEnabled = false
    private var didRunJob = false
#if CPUMetrics
    private(set) var cpuUsage = RuntimeCPUUsageMeter()
#endif

    /// Enqueues a Swift runtime job that should run as soon as its destination
    /// core polls.
    ///
    /// Called by the global/main executor runtime hooks. This method does no
    /// async-context work directly; it creates the common envelope path used by
    /// all job kinds.
    func enqueueImmediate(
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        enqueue(
            kind: .immediate,
            timeUs: 0,
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond
        )
    }

    /// Enqueues a Swift runtime job after a relative delay in microseconds.
    ///
    /// Placement happens at enqueue time, so the selected core owns the timer in
    /// its own async context.
    func enqueueDelayed(
        delayUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        enqueue(
            kind: .delayed,
            timeUs: delayUs,
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond
        )
    }

    /// Enqueues a Swift runtime job for an absolute microsecond deadline.
    ///
    /// As with delayed jobs, the deadline worker belongs to the selected core's
    /// executor. Affinity is decided before the timer is installed.
    func enqueueDeadline(
        deadlineUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        enqueue(
            kind: .deadline,
            timeUs: deadlineUs,
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond
        )
    }

    @discardableResult
    /// Polls the scheduler once on the current core.
    ///
    /// This is the normal entry from runtime drain/donate hooks and tight-loop
    /// integration. Core0 and core1 both use the same `pollOnce(on:)` path so
    /// each core drains its own inbox and polls its own async context.
    func pollOnce() -> Int32 {
        pollOnce(on: CoreID.current)
    }

    @discardableResult
    /// Runs one scheduler iteration for a specific core.
    ///
    /// The iteration drains only that core's executor inbox, polls only that
    /// core's async context, and returns whether a Swift runtime job ran. This
    /// method is the place where transport and execution meet.
    func pollOnce(on core: CoreID) -> Int32 {
    #if CPUMetrics
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.record(event: .enterTask(name: "runtimeScheduler.pollOnce"))
    #endif
        didRunJob = false
        executor(for: core).drainInbox()
        executor(for: core).pollAsyncContext()
    #if CPUMetrics
        cpuUsage.record(event: .exitTask(name: "runtimeScheduler.pollOnce"))
        cpuUsage.reportIfNeeded()
    #endif
        return didRunJob ? 1 : 0
    }

    /// Polls repeatedly until one iteration reports no completed runtime job.
    ///
    /// Used by runtime drain hooks that want to make progress without blocking
    /// forever.
    func drain() {
        while pollOnce() != 0 {
        }
    }

    /// Waits indefinitely for work on the current core.
    ///
    /// Kept as a runtime-hook-shaped wrapper around `waitForWork()`.
    func waitForever() {
        waitForWork()
    }

    /// Blocks the current core's executor until its async context has work.
    ///
    /// `SchedulerSystem` chooses the current executor; the executor performs the
    /// actual Pico wait. CPU metrics sampling wraps the wait when enabled.
    func waitForWork() {
#if CPUMetrics
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.sample()
#endif
        executor(for: CoreID.current).waitForWork()
#if CPUMetrics
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.sample()
#endif
    }

    /// Starts multicore scheduling if the platform launcher can bring up core1.
    ///
    /// Runtime isolation setup happens before launch. Placement only starts
    /// returning core1 after `MulticoreLauncher` reports success.
    func startMulticore() {
        guard !multicoreEnabled else {
            return
        }

        PlatformRuntimeIsolation.prepareCoreForSwiftRuntime(.core1)
        multicoreEnabled = MulticoreLauncher.start(system: self)
    }

    @discardableResult
    /// Runs one iteration of the loop used by the future core1 C entrypoint.
    ///
    /// Keeping this C-callable shape lets startup/stack-sensitive code remain in
    /// C while the scheduler logic stays in Swift.
    func coreLoopIteration() -> Int32 {
        pollOnce(on: CoreID.current)
    }

#if CPUMetrics
    func recordExternalEvent(_ event: RuntimeCPUUsageMeter.Event) {
        cpuUsage.record(event: event)
    }

    func sampleCPUUsage() {
        cpuUsage.sample()
    }
#endif

    /// Schedules a one-shot closure as deferred scheduler work.
    ///
    /// This helper allocates and is not ISR-safe. ISR paths should preallocate a
    /// `DeferredWorkItem` and call `enqueueDeferred`.
    func schedule(_ block: @escaping () -> Void) {
        let core = selectDeferredWorkCore(preferredCore: nil)
        executor(for: core).schedule(block)
    }

    /// Enqueues a preallocated deferred work item.
    ///
    /// Deferred work is not a Swift runtime job and has no task identity. The
    /// scheduler still picks a core for transport, then the selected executor's
    /// single wake worker pumps the item outside ISR context.
    func enqueueDeferred(_ item: DeferredWorkItem, preferredCore: CoreID? = nil) {
        let core = selectDeferredWorkCore(preferredCore: preferredCore)
        executor(for: core).enqueueDeferred(item)
    }

    /// Runs a fired job slot on the current core's executor.
    ///
    /// Called by Pico worker callbacks after recovering the slot pointer from
    /// `user_data`.
    func run(slot: UnsafeMutablePointer<JobSlot>) {
        executor(for: CoreID.current).run(slot: slot, scheduler: self)
    }

    /// Marks a job as about to run.
    ///
    /// `CoreExecutor` calls this immediately before `swift_job_run`. The
    /// affinity table should move the identity from queued to running here and
    /// verify that the current core is still the owner.
    func jobWillRun(envelope: JobEnvelope, core: CoreID) {
        affinityTable.markStarting(identity: envelope.identity, core: core)
        didRunJob = true
    }

    /// Marks a job as finished.
    ///
    /// `CoreExecutor` calls this after `swift_job_run`. The affinity table can
    /// then decrement running state and mark the task idle when no work remains.
    func jobDidRun(envelope: JobEnvelope, core: CoreID) {
        affinityTable.markFinished(identity: envelope.identity, core: core, nowUs: time_us_64())
    }

    /// Shared enqueue path for all Swift runtime job kinds.
    ///
    /// The flow is: resolve identity, ask affinity for an active owner, ask
    /// placement for a destination, record accepted ownership, then transport
    /// the envelope into the selected executor's inbox.
    private func enqueue(
        kind: JobKind,
        timeUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        let identity = TaskIdentity.resolve(job: job)
        let enqueueCore = CoreID.current
        let existingOwner = affinityTable.owner(for: identity)
        let ownerCore = PlacementPolicy.chooseCore(
            for: PlacementInput(
                identity: identity,
                enqueueCore: enqueueCore,
                multicoreEnabled: multicoreEnabled,
                outstandingWorkByCore: outstandingWork
            ),
            existingOwner: existingOwner
        )

        let envelope = JobEnvelope(
            kind: kind,
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond,
            timeUs: timeUs,
            identity: identity
        )

        affinityTable.markAccepted(identity: identity, ownerCore: ownerCore, nowUs: time_us_64())
        schedule(envelope, on: ownerCore)
    }

    /// Pushes an envelope to the selected executor.
    ///
    /// If the destination is the current core, the executor drains immediately
    /// so the job can become async-context work without waiting for a later poll.
    private func schedule(_ envelope: JobEnvelope, on core: CoreID) {
        executor(for: core).enqueue(envelope)
        if core == CoreID.current {
            executor(for: core).drainInbox()
        }
    }

    /// Chooses a destination core for deferred non-job work.
    ///
    /// This intentionally does not use task affinity. Deferred work is a
    /// platform escape hatch; if it creates a Swift `Task`, that task will return
    /// through normal runtime enqueue hooks and use the job placement path.
    private func selectDeferredWorkCore(preferredCore: CoreID?) -> CoreID {
        if !multicoreEnabled {
            return .core0
        }

        return preferredCore ?? CoreID.current
    }

    /// Returns the executor that owns a core's inbox and async context.
    private func executor(for core: CoreID) -> CoreExecutor {
        executors[core.index]
    }

    /// Returns the amount of pending/running work used by placement policy.
    ///
    /// This is currently a stub while the first-pass entity graph is being wired.
    /// Later it should aggregate inbox depth, scheduled slots, and affinity
    /// counts for the requested core.
    private func outstandingWork(for core: CoreID) -> UInt32 {
        _ = core
        return 0
    }

    /// Gives legacy helpers access to the core0 async context pointer.
    ///
    /// New scheduler code should prefer going through `CoreExecutor`, but this
    /// keeps existing SPI callers working while the architecture is split apart.
    func callWithAsyncContext(_ body: (UnsafeMutableRawPointer) -> Void) {
        withUnsafeMutablePointer(to: &executors[CoreID.core0.index].context.core) { contextPtr in
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

/// C shim entrypoint for draining currently available scheduler work.
@_cdecl("cshims_scheduler_drain")
func cshims_scheduler_drain() {
    cshimsRuntimeScheduler.drain()
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
    cshimsRuntimeScheduler.waitForever()
}

/// C shim entrypoint for a single core run-loop iteration.
@_cdecl("cshims_scheduler_core_loop_iteration")
func cshims_scheduler_core_loop_iteration() -> Int32 {
    cshimsRuntimeScheduler.coreLoopIteration()
}

/// C shim entrypoint that requests core1 launch.
@_cdecl("cshims_scheduler_start_multicore")
func cshims_scheduler_start_multicore() {
    cshimsRuntimeScheduler.startMulticore()
}
