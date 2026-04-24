import ConcurrencyShims
private import CPicoSDK

private let cshimsMaxJobSlots = 64

private struct JobSlot {
    static let maxJobSlots = 64
    enum State: UInt8 {
        case free = 0
        case pending = 1
        case delayed = 2
    }

    var state: State
    var job: UnsafeMutableRawPointer?
    var executorFirst: UnsafeMutableRawPointer?
    var executorSecond: UnsafeMutableRawPointer?
    var pendingWorker: async_when_pending_worker_t
    var delayedWorker: async_at_time_worker_t

    mutating func free() {
        state = .free
        job = nil
        executorFirst = nil
        executorSecond = nil
        pendingWorker.work_pending = false
        delayedWorker.next = nil
        delayedWorker.next_time = 0
    }
}

func withCritical<T>(_ body: () -> T) -> T {
    let state = cshims_enter_critical()
    defer { cshims_exit_critical(state) }
    return body()
}

final class ScheduledBlock {
    private var block: (() -> Void)?
    private var finalizer: (() -> Void)?
    private var context: UnsafeMutablePointer<async_context_t>?
    private var pendingWorker: async_when_pending_worker_t
    private var didFinish = false

    init(block: (() -> Void)? = nil, finalizer: (() -> Void)? = nil) {
        self.block = block
        self.finalizer = finalizer
        self.context = nil
        self.pendingWorker = async_when_pending_worker_t(
            next: nil,
            do_work: cshims_scheduler_scheduled_block_worker,
            work_pending: false,
            user_data: nil
        )
    }

    func configure(block: @escaping () -> Void, finalizer: (() -> Void)? = nil) {
        self.block = block
        self.finalizer = finalizer
    }

    fileprivate func attach(to context: UnsafeMutablePointer<async_context_t>) -> Bool {
        self.context = context
        pendingWorker.user_data = Unmanaged.passUnretained(self).toOpaque()
        return async_context_add_when_pending_worker(context, &pendingWorker)
    }

    func signal() {
        guard let context else { return }
        async_context_set_work_pending(context, &pendingWorker)
    }

    func execute() {
        block?()
        finish()
    }

    func cancel() {
        finish()
    }

    private func finish() {
        let markedAsFinished = withCritical { () -> Bool in
            guard !self.didFinish else {
                return false
            }
            self.didFinish = true
            return true
        }

        guard markedAsFinished else {
            return
        }

        block = nil
        removeWorker()

        let finalizer = self.finalizer
        self.finalizer = nil
        finalizer?()
    }

    private func removeWorker() {
        guard let context else {
            return
        }

        _ = async_context_remove_when_pending_worker(context, &pendingWorker)
        self.context = nil
    }
}

final class RuntimeScheduler {
    // Shared async_context used by both Swift runtime jobs and IRQ trampolines.
    fileprivate var context = async_context_poll_t()
    private let slots: UnsafeMutablePointer<JobSlot>
    private var didRunJob = false
#if CPU_USAGE_ENABLED
    private var cpuUsage = RuntimeCPUUsageMeter()
#endif

    init() {
        slots = .allocate(capacity: JobSlot.maxJobSlots)

        guard async_context_poll_init_with_defaults(&context) else {
            fatalError("[CPicoConcurrency] async_context_poll_init_with_defaults failed")
        }

        for index in 0..<JobSlot.maxJobSlots {
            let slot = slots.advanced(by: index)
            slot.initialize(
                to: JobSlot(
                    state: .free,
                    job: nil,
                    executorFirst: nil,
                    executorSecond: nil,
                    pendingWorker: .init(
                        next: nil,
                        do_work: cshims_scheduler_pending_worker,
                        work_pending: false,
                        user_data: nil
                    ),
                    delayedWorker: .init(
                        next: nil,
                        do_work: cshims_scheduler_delayed_worker,
                        next_time: 0,
                        user_data: nil
                    )
                )
            )
            slot.pointee.pendingWorker.user_data = UnsafeMutableRawPointer(slot)
            slot.pointee.delayedWorker.user_data = UnsafeMutableRawPointer(slot)

            guard async_context_add_when_pending_worker(&context.core, &slot.pointee.pendingWorker) else {
                fatalError("[CPicoConcurrency] failed to register pending worker with async_context")
            }
        }
    }

    deinit {
        slots.deinitialize(count: cshimsMaxJobSlots)
        slots.deallocate()
    }

    func enqueueImmediate(
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        let slot = allocateSlot()
        slot.pointee.state = .pending
        slot.pointee.job = job
        slot.pointee.executorFirst = executorFirst
        slot.pointee.executorSecond = executorSecond
        async_context_set_work_pending(&context.core, &slot.pointee.pendingWorker)
    }

    func enqueueDelayed(
        delayUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        let slot = allocateSlot()
        slot.pointee.state = .delayed
        slot.pointee.job = job
        slot.pointee.executorFirst = executorFirst
        slot.pointee.executorSecond = executorSecond

        let deadline = make_timeout_time_us(delayUs)
        guard async_context_add_at_time_worker_at(&context.core, &slot.pointee.delayedWorker, deadline) else {
            releaseSlot(slot)
            fatalError("[CPicoConcurrency] failed to schedule delayed async_context job")
        }
    }

    func enqueueDeadline(
        deadlineUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        let slot = allocateSlot()
        slot.pointee.state = .delayed
        slot.pointee.job = job
        slot.pointee.executorFirst = executorFirst
        slot.pointee.executorSecond = executorSecond

        let deadline = from_us_since_boot(deadlineUs)
        guard async_context_add_at_time_worker_at(&context.core, &slot.pointee.delayedWorker, deadline) else {
            releaseSlot(slot)
            fatalError("[CPicoConcurrency] failed to schedule deadline async_context job")
        }
    }

    @discardableResult
    func pollOnce() -> Int32 {
    #if CPU_USAGE_ENABLED
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.record(event: .enterTask(name: "runtimeScheduler.pollOnce"))
    #endif
        didRunJob = false
        async_context_poll(&context.core)
    #if CPU_USAGE_ENABLED
        cpuUsage.record(event: .exitTask(name: "runtimeScheduler.pollOnce"))
    #endif
        return didRunJob ? 1 : 0
    }

    func drain() {
        while pollOnce() != 0 {
        }
    }

    func waitForever() {
#if CPU_USAGE_ENABLED
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.sample()
#endif
        async_context_wait_for_work_until(&context.core, UInt64.max)
#if CPU_USAGE_ENABLED
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.sample()
#endif
    }

#if CPU_USAGE_ENABLED
    func recordExternalEvent(_ event: RuntimeCPUUsageMeter.Event) {
        cpuUsage.record(event: event)
    }

    func sampleCPUUsage() {
        cpuUsage.sample()
    }
#endif

    // Schedules a one-shot block to run from async_context worker context.
    // This is allowed to allocate; callers that need zero-allocation IRQ paths
    // should use a dedicated preallocated mechanism instead.
    func schedule(_ block: @escaping () -> Void) {
        let scheduledBlock = ScheduledBlock()
        _ = Unmanaged.passRetained(scheduledBlock)
        scheduledBlock.configure(block: block) {
            Unmanaged.passUnretained(scheduledBlock).release()
        }

        let registered = withUnsafeMutablePointer(to: &context.core) { context in
            scheduledBlock.attach(to: context)
        }
        guard registered else {
            scheduledBlock.cancel()
            fatalError("[CPicoConcurrency] failed to register scheduled worker")
        }

        scheduledBlock.signal()
    }

    func register(_ scheduledBlock: ScheduledBlock) {
        let registered = withUnsafeMutablePointer(to: &context.core) { context in
            scheduledBlock.attach(to: context)
        }
        guard registered else {
            fatalError("[CPicoConcurrency] failed to register scheduled worker")
        }
    }

    fileprivate func run(slot: UnsafeMutablePointer<JobSlot>) {
        let job = slot.pointee.job
        let executorFirst = slot.pointee.executorFirst
        let executorSecond = slot.pointee.executorSecond

        releaseSlot(slot)
        didRunJob = true
        cshims_run_job_bridge(job, executorFirst, executorSecond)
    }

    private func allocateSlot() -> UnsafeMutablePointer<JobSlot> {
        if let slot = withCritical(findFreeSlot) {
            slot.pointee.pendingWorker.work_pending = false
            slot.pointee.delayedWorker.next = nil
            slot.pointee.delayedWorker.next_time = 0
            return slot
        }

        fatalError("[CPicoConcurrency] Concurrency job slot pool exhausted")
    }

    private func releaseSlot(_ slot: UnsafeMutablePointer<JobSlot>) {
        withCritical {
            slot.pointee.free()
        }
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

nonisolated(unsafe) var cshimsRuntimeScheduler = RuntimeScheduler()

@_spi(Internal) public func callWithAsyncContext(_ body: (UnsafeMutableRawPointer) -> Void) {
    withUnsafeMutablePointer(to: &cshimsRuntimeScheduler.context.core) { contextPtr in
        body(UnsafeMutableRawPointer(contextPtr))
    }
}

@_cdecl("cshims_scheduler_scheduled_block_worker")
private func cshims_scheduler_scheduled_block_worker(
    _ context: UnsafeMutablePointer<async_context_t>?,
    _ worker: UnsafeMutablePointer<async_when_pending_worker_t>?
) {
    _ = context
    guard let worker, let userData = worker.pointee.user_data else {
        return
    }
    let scheduledBlock = Unmanaged<ScheduledBlock>.fromOpaque(userData).takeUnretainedValue()
    _ = Unmanaged.passRetained(scheduledBlock)
    scheduledBlock.execute()
    Unmanaged.passUnretained(scheduledBlock).release()
}

@_cdecl("cshims_scheduler_pending_worker")
private func cshims_scheduler_pending_worker(
    _ context: UnsafeMutablePointer<async_context_t>?,
    _ worker: UnsafeMutablePointer<async_when_pending_worker_t>?
) {
    _ = context
    guard let worker, let userData = worker.pointee.user_data else {
        return
    }
    cshimsRuntimeScheduler.run(slot: userData.assumingMemoryBound(to: JobSlot.self))
}

@_cdecl("cshims_scheduler_delayed_worker")
private func cshims_scheduler_delayed_worker(
    _ context: UnsafeMutablePointer<async_context_t>?,
    _ worker: UnsafeMutablePointer<async_at_time_worker_t>?
) {
    _ = context
    guard let worker, let userData = worker.pointee.user_data else {
        return
    }
    cshimsRuntimeScheduler.run(slot: userData.assumingMemoryBound(to: JobSlot.self))
}

@_cdecl("cshims_scheduler_poll_once")
func cshims_scheduler_poll_once() -> Int32 {
    cshimsRuntimeScheduler.pollOnce()
}

@_cdecl("cshims_scheduler_drain")
func cshims_scheduler_drain() {
    cshimsRuntimeScheduler.drain()
}

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

@_cdecl("cshims_scheduler_wait_for_work_forever")
func cshims_scheduler_wait_for_work_forever() {
    cshimsRuntimeScheduler.waitForever()
}
