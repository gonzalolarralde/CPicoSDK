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
    private var didRunJobByCore: [2 of Bool] = [false, false]

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
        let executor = executor(for: core)
        didRunJobByCore[core.index] = false
        executor.pollOnce()
        return didRunJobByCore[core.index] ? 1 : 0
    }

    /// Blocks the current core's executor until its async context has work.
    ///
    /// `SchedulerSystem` chooses the current executor; the executor performs the
    /// actual Pico wait. CPU metrics sampling wraps the wait when enabled.
    func waitForWork() {
        executor(for: CoreID.current).waitForWork()
    }

    /// Starts core1 once scheduler work begins.
    ///
    /// This keeps the launch path in Swift while avoiding an unused C shim. It
    /// also waits until after the global scheduler object is initialized, so
    /// core1 can safely enter through `cshimsRuntimeScheduler`.
    func startMulticore() {
        guard CoreID.current == .core0, !multicoreEnabled else {
            return
        }

        multicore_reset_core1()
        multicore_launch_core1(cshims_scheduler_core1_entry)
        multicoreEnabled = true
    }

#if CPUMetrics
    func cpuUsageEvents(for core: CPUCore) -> AsyncStream<CPUStats> {
        executors[Int(core.rawValue)].cpuUsageEvents
    }

    func recordInterruptCPUUsage(_ event: RuntimeCPUUsageMeter.Event, coreIndex: UInt) {
        guard coreIndex < 2 else {
            fatalError("[CPicoConcurrency] CPU metrics received invalid core index \(coreIndex)")
        }
        executors[Int(coreIndex)].recordInterruptCPUUsage(event: event)
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
        didRunJobByCore[core.index] = true
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
        startMulticore()

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
    /// This aggregates executor-owned transport, deferred work, and scheduled
    /// slot state. It is intentionally a load estimate, not a correctness
    /// counter; affinity state remains owned by `AffinityTable`.
    private func outstandingWork(for core: CoreID) -> UInt32 {
        executor(for: core).outstandingWork
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
