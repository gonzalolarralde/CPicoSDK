import ConcurrencyShims
import CPicoSDK

/// FIFO transport queue for one core.
///
/// `SchedulerSystem` chooses a destination core and pushes a `JobEnvelope` into
/// that core's executor. The executor owns this inbox and drains it only from
/// the matching core run loop before converting envelopes into async-context
/// workers. Pico's queue provides the cross-core synchronization; the inbox does
/// not decide priority or placement.
final class CoreInbox {
    private static let capacity: UInt32 = 128

    let core: CoreID
    private var queue = queue_t()

    init(core: CoreID) {
        self.core = core
        queue_init(
            &queue,
            UInt32(MemoryLayout<JobEnvelope>.stride),
            Self.capacity
        )
    }

    deinit {
        queue_free(&queue)
    }

    /// Adds an envelope selected for this core.
    ///
    /// Producers may be on either core. `queue_t` serializes producer/consumer
    /// access without requiring a separate scheduler lock.
    func push(_ envelope: JobEnvelope) -> Bool {
        var mutableEnvelope = envelope
        return queue_try_add(&queue, &mutableEnvelope)
    }

    /// Removes the oldest envelope for the owning executor.
    ///
    /// Only the matching `CoreExecutor` should pop from this queue. That keeps
    /// transport ownership simple: a core drains its own inbox and schedules its
    /// own async-context workers.
    func pop() -> JobEnvelope? {
        var envelope = JobEnvelope(
            kind: .immediate,
            job: nil,
            executorFirst: nil,
            executorSecond: nil,
            timeUs: 0,
            identity: nil
        )
        guard queue_try_remove(&queue, &envelope) else {
            return nil
        }
        return envelope
    }
}

/// Fixed async-context slot for one scheduled Swift runtime job.
///
/// Each slot owns the Pico worker structs whose `user_data` points back to the
/// slot. `CoreExecutor` stores the current `JobEnvelope` here, Pico calls one of
/// the C worker entrypoints, and the entrypoint asks `SchedulerSystem` to run the
/// slot on the current core.
struct JobSlot {
    static let maxJobSlots = 64
    enum State: UInt8 {
        case free = 0
        case pending = 1
        case delayed = 2
    }

    var state: State
    var envelope: JobEnvelope?
    var pendingWorker: async_when_pending_worker_t
    var delayedWorker: async_at_time_worker_t

    /// Resets the slot so it can be reused by the owning `JobSlotPool`.
    mutating func free() {
        state = .free
        envelope = nil
        pendingWorker.work_pending = false
        delayedWorker.next = nil
        delayedWorker.next_time = 0
    }
}

/// Fixed-size slot allocator for one executor.
///
/// The pool avoids allocating while scheduling runtime jobs. It also centralizes
/// the relationship between Swift slot storage and Pico async-context worker
/// callbacks, so `CoreExecutor` can schedule immediate and timed jobs by
/// borrowing a prepared slot.
private final class JobSlotPool {
    private let slots: UnsafeMutablePointer<JobSlot>
    private var lock = mutex_t()

    init() {
        slots = .allocate(capacity: JobSlot.maxJobSlots)
        mutex_init(&lock)
    }

    deinit {
        slots.deinitialize(count: JobSlot.maxJobSlots)
        slots.deallocate()
    }

    /// Initializes all slot storage and binds each Pico worker's `user_data` to
    /// its containing `JobSlot`.
    func initializeSlots(
        pendingWorker: @escaping @convention(c) (
            UnsafeMutablePointer<async_context_t>?,
            UnsafeMutablePointer<async_when_pending_worker_t>?
        ) -> Void,
        delayedWorker: @escaping @convention(c) (
            UnsafeMutablePointer<async_context_t>?,
            UnsafeMutablePointer<async_at_time_worker_t>?
        ) -> Void
    ) {
        for index in 0..<JobSlot.maxJobSlots {
            let slot = slots.advanced(by: index)
            slot.initialize(
                to: JobSlot(
                    state: .free,
                    envelope: nil,
                    pendingWorker: .init(
                        next: nil,
                        do_work: pendingWorker,
                        work_pending: false,
                        user_data: nil
                    ),
                    delayedWorker: .init(
                        next: nil,
                        do_work: delayedWorker,
                        next_time: 0,
                        user_data: nil
                    )
                )
            )
            slot.pointee.pendingWorker.user_data = UnsafeMutableRawPointer(slot)
            slot.pointee.delayedWorker.user_data = UnsafeMutableRawPointer(slot)
        }
    }

    /// Registers each slot's pending worker with the executor's async context.
    ///
    /// Pending workers are registered once up front and later triggered with
    /// `async_context_set_work_pending` for immediate jobs.
    func registerPendingWorkers(on context: UnsafeMutablePointer<async_context_t>) {
        for index in 0..<JobSlot.maxJobSlots {
            let slot = slots.advanced(by: index)
            guard async_context_add_when_pending_worker(context, &slot.pointee.pendingWorker) else {
                fatalError("[CPicoConcurrency] failed to register pending worker with async_context")
            }
        }
    }

    /// Reserves a free slot for a new envelope.
    ///
    /// Slot exhaustion is fatal for now because dropping a Swift runtime job
    /// would violate scheduler correctness. A later implementation can add
    /// backpressure or a larger pool if needed.
    func allocate() -> UnsafeMutablePointer<JobSlot> {
        if let slot = withLock(findFreeSlot) {
            slot.pointee.pendingWorker.work_pending = false
            slot.pointee.delayedWorker.next = nil
            slot.pointee.delayedWorker.next_time = 0
            return slot
        }

        fatalError("[CPicoConcurrency] Concurrency job slot pool exhausted")
    }

    /// Returns a slot to the pool after execution or scheduling failure.
    func release(_ slot: UnsafeMutablePointer<JobSlot>) {
        withLock {
            slot.pointee.free()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        mutex_enter_blocking(&lock)
        defer {
            mutex_exit(&lock)
        }
        return body()
    }

    private func findFreeSlot() -> UnsafeMutablePointer<JobSlot>? {
        for index in 0..<JobSlot.maxJobSlots {
            let slot = slots.advanced(by: index)
            if slot.pointee.state == .free {
                slot.pointee.state = .pending
                return slot
            }
        }
        return nil
    }
}

/// Executor for one core.
///
/// A core executor owns the core's transport inbox, async_context_poll_t, and
/// fixed job-slot pool. It does not choose where work belongs; `SchedulerSystem`
/// and `PlacementPolicy` do that before calling `enqueue`. Once work arrives,
/// the executor converts envelopes into Pico async-context workers and performs
/// the final `swift_job_run` bridge when a slot fires.
final class CoreExecutor {
    let core: CoreID
    var context = async_context_poll_t()
    private let inbox: CoreInbox
    private var deferredWork = DeferredWorkQueue()
    private var deferredWorkWorker: async_when_pending_worker_t
    private let slotPool = JobSlotPool()
#if CPUMetrics
    private var cpuUsage: RuntimeCPUUsageMeter
#endif

    init(core: CoreID) {
        self.core = core
        self.inbox = CoreInbox(core: core)
#if CPUMetrics
        self.cpuUsage = RuntimeCPUUsageMeter(core: core)
#endif
        self.deferredWorkWorker = async_when_pending_worker_t(
            next: nil,
            do_work: cshims_scheduler_deferred_work_worker,
            work_pending: false,
            user_data: nil
        )

        slotPool.initializeSlots(
            pendingWorker: cshims_scheduler_pending_worker,
            delayedWorker: cshims_scheduler_delayed_worker
        )

        guard async_context_poll_init_with_defaults(&context) else {
            fatalError("[CPicoConcurrency] async_context_poll_init_with_defaults failed")
        }

        withUnsafeMutablePointer(to: &context.core) { context in
            slotPool.registerPendingWorkers(on: context)
            deferredWorkWorker.user_data = Unmanaged.passUnretained(self).toOpaque()
            guard async_context_add_when_pending_worker(context, &deferredWorkWorker) else {
                fatalError("[CPicoConcurrency] failed to register deferred work worker with async_context")
            }
        }
    }

#if CPUMetrics
    /// Stream of usage reports produced by this executor's core-local meter.
    ///
    /// The public `CPUStats.usageEvents(for:)` API reaches this through
    /// `SchedulerSystem`, but the meter itself lives here because executor work
    /// is what the report is measuring.
    var cpuUsageEvents: AsyncStream<CPUStats> {
        cpuUsage.stream
    }

    /// Records an interrupt transition observed by this executor's core.
    func recordInterruptCPUUsage(event: RuntimeCPUUsageMeter.Event) {
        cpuUsage.record(event: event)
    }
#endif

    /// Runs one scheduler iteration for this executor's core.
    ///
    /// The scheduler selects the executor; the executor owns the actual loop
    /// mechanics and metrics for its core.
    func pollOnce() {
    #if CPUMetrics
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.record(event: .enterTask(name: "runtimeScheduler.pollOnce"))
    #endif
        drainInbox()
        pollAsyncContext()
    #if CPUMetrics
        cpuUsage.record(event: .exitTask(name: "runtimeScheduler.pollOnce"))
        cpuUsage.reportIfNeeded()
    #endif
    }

    /// Accepts an already-placed envelope for this core.
    ///
    /// This is the transport boundary from `SchedulerSystem` into the executor.
    /// The envelope remains FIFO queued until this core's run loop drains the
    /// inbox.
    func enqueue(_ envelope: JobEnvelope) -> Bool {
        inbox.push(envelope)
    }

    /// Moves all queued envelopes from transport into async-context scheduling.
    ///
    /// This should be called by the matching core's run loop before polling the
    /// async context, so newly arrived work can run in the same iteration.
    func drainInbox() {
        while let envelope = inbox.pop() {
            schedule(envelope)
        }
    }

    /// Converts an envelope into Pico async-context work.
    ///
    /// Immediate jobs use a pre-registered pending worker. Delayed and deadline
    /// jobs use an at-time worker owned by the same slot. The envelope's selected
    /// core is already decided; this method only handles execution mechanics.
    func schedule(_ envelope: JobEnvelope) {
        let slot = slotPool.allocate()
        slot.pointee.envelope = envelope

        switch envelope.kind {
        case .immediate:
            slot.pointee.state = .pending
            async_context_set_work_pending(&context.core, &slot.pointee.pendingWorker)
        case .delayed:
            slot.pointee.state = .delayed
            let deadline = make_timeout_time_us(envelope.timeUs)
            guard async_context_add_at_time_worker_at(&context.core, &slot.pointee.delayedWorker, deadline) else {
                slotPool.release(slot)
                fatalError("[CPicoConcurrency] failed to schedule delayed async_context job")
            }
        case .deadline:
            slot.pointee.state = .delayed
            let deadline = from_us_since_boot(envelope.timeUs)
            guard async_context_add_at_time_worker_at(&context.core, &slot.pointee.delayedWorker, deadline) else {
                slotPool.release(slot)
                fatalError("[CPicoConcurrency] failed to schedule deadline async_context job")
            }
        }
    }

    /// Schedules a one-shot Swift closure as deferred work on this executor.
    ///
    /// This helper allocates and is not ISR-safe. ISR paths should preallocate a
    /// `DeferredWorkItem` and call `SchedulerSystem.enqueueDeferred`.
    func schedule(_ block: @escaping () -> Void) {
        let item = DeferredWorkItem()
        _ = Unmanaged.passRetained(item)
        item.configure(block: block) {
            Unmanaged.passUnretained(item).release()
        }

        enqueueDeferred(item)
    }

    /// Enqueues a preallocated deferred work item and wakes this executor.
    ///
    /// The enqueue path does not allocate and is suitable for ISR handoff when
    /// the item and its closure were prepared ahead of time.
    func enqueueDeferred(_ item: DeferredWorkItem) {
        if deferredWork.push(item) {
            async_context_set_work_pending(&context.core, &deferredWorkWorker)
        }
    }

    /// Runs all deferred work currently queued for this executor.
    func drainDeferredWork() {
        while let item = deferredWork.pop() {
            item.execute()
        }
    }

    /// Polls this core's async context once.
    ///
    /// Fired workers call back through the C entrypoints below and eventually
    /// re-enter `CoreExecutor.run(slot:scheduler:)`.
    func pollAsyncContext() {
        async_context_poll(&context.core)
    }

    /// Blocks until this executor's async context has work or a timeout wakes it.
    ///
    /// A short timeout lets the current core notice work that another core
    /// pushed into this executor's inbox without also signaling this async
    /// context.
    func waitForWork() {
    #if CPUMetrics
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.sample()
    #endif
        async_context_wait_for_work_until(&context.core, make_timeout_time_us(1_000))
    #if CPUMetrics
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.sample()
    #endif
    }

    /// Runs the Swift job stored in a fired slot.
    ///
    /// The executor releases the slot, notifies `SchedulerSystem` so affinity
    /// state can transition from queued to running, invokes the Swift runtime
    /// job bridge, then reports completion. Placement decisions are already over
    /// at this point.
    func run(slot: UnsafeMutablePointer<JobSlot>, scheduler: SchedulerSystem) {
        guard let envelope = slot.pointee.envelope else {
            slotPool.release(slot)
            return
        }

        scheduler.jobWillRun(envelope: envelope, core: core)
        cshims_run_job_bridge(envelope.job, envelope.executorFirst, envelope.executorSecond)
        scheduler.jobDidRun(envelope: envelope, core: core)
        slotPool.release(slot)
    }
}

/// Pico pending-worker callback for deferred work.
///
/// Each executor registers one wake worker. Signaled deferred items are held in
/// the executor's allocation-free queue; the worker only pumps that queue.
@_cdecl("cshims_scheduler_deferred_work_worker")
func cshims_scheduler_deferred_work_worker(
    _ context: UnsafeMutablePointer<async_context_t>?,
    _ worker: UnsafeMutablePointer<async_when_pending_worker_t>?
) {
    _ = context
    guard let worker, let userData = worker.pointee.user_data else {
        return
    }
    let executor = Unmanaged<CoreExecutor>.fromOpaque(userData).takeUnretainedValue()
    executor.drainDeferredWork()
}

/// Pico pending-worker callback for immediate Swift runtime jobs.
///
/// `JobSlotPool` registered this worker up front and stored the slot pointer in
/// `user_data`. When Pico fires it, control returns to the global scheduler so
/// the current core's executor can run the slot.
@_cdecl("cshims_scheduler_pending_worker")
func cshims_scheduler_pending_worker(
    _ context: UnsafeMutablePointer<async_context_t>?,
    _ worker: UnsafeMutablePointer<async_when_pending_worker_t>?
) {
    _ = context
    guard let worker, let userData = worker.pointee.user_data else {
        return
    }
    cshimsRuntimeScheduler.run(slot: userData.assumingMemoryBound(to: JobSlot.self))
}

/// Pico at-time worker callback for delayed and deadline Swift runtime jobs.
///
/// The worker owns no policy. It only recovers the slot pointer and asks the
/// scheduler to execute it on the current core.
@_cdecl("cshims_scheduler_delayed_worker")
func cshims_scheduler_delayed_worker(
    _ context: UnsafeMutablePointer<async_context_t>?,
    _ worker: UnsafeMutablePointer<async_at_time_worker_t>?
) {
    _ = context
    guard let worker, let userData = worker.pointee.user_data else {
        return
    }
    cshimsRuntimeScheduler.run(slot: userData.assumingMemoryBound(to: JobSlot.self))
}
