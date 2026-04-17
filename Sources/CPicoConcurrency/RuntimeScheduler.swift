import ConcurrencyShims
private import CPicoSDK

private let cshimsJobSlotFree: UInt8 = 0
private let cshimsJobSlotPending: UInt8 = 1
private let cshimsJobSlotDelayed: UInt8 = 2
private let cshimsMaxJobSlots = 64

private struct JobSlot {
    var state: UInt8
    var job: UnsafeMutableRawPointer?
    var executorFirst: UnsafeMutableRawPointer?
    var executorSecond: UnsafeMutableRawPointer?
    var pendingWorker: async_when_pending_worker_t
    var delayedWorker: async_at_time_worker_t
}

private func cshimsMakePendingWorker() -> async_when_pending_worker_t {
    async_when_pending_worker_t(
        next: nil,
        do_work: cshims_scheduler_pending_worker,
        work_pending: false,
        user_data: nil
    )
}

private func cshimsMakeDelayedWorker() -> async_at_time_worker_t {
    async_at_time_worker_t(
        next: nil,
        do_work: cshims_scheduler_delayed_worker,
        next_time: 0,
        user_data: nil
    )
}

private func cshimsWithCritical<T>(_ body: () -> T) -> T {
    let state = cshims_enter_critical()
    defer { cshims_exit_critical(state) }
    return body()
}

private final class ScheduledBlock {
    let id: UInt32
    private let block: () -> Void
    private var contextRaw: UnsafeMutableRawPointer?
    var pendingWorker: async_when_pending_worker_t

    init(id: UInt32, block: @escaping () -> Void) {
        self.id = id
        self.block = block
        self.contextRaw = nil
        self.pendingWorker = async_when_pending_worker_t(
            next: nil,
            do_work: cshims_scheduler_scheduled_block_worker,
            work_pending: false,
            user_data: nil
        )
    }

    func attach(to contextRaw: UnsafeMutableRawPointer) -> Bool {
        self.contextRaw = contextRaw
        pendingWorker.user_data = Unmanaged.passUnretained(self).toOpaque()
        let context = contextRaw.assumingMemoryBound(to: async_context_t.self)
        return async_context_add_when_pending_worker(context, &pendingWorker)
    }

    func signal() {
        guard let contextRaw else { return }
        let context = contextRaw.assumingMemoryBound(to: async_context_t.self)
        async_context_set_work_pending(context, &pendingWorker)
    }

    func execute() {
        block()

        if let contextRaw {
            let context = contextRaw.assumingMemoryBound(to: async_context_t.self)
            _ = async_context_remove_when_pending_worker(context, &pendingWorker)
        }

        cshimsRuntimeScheduler.completeScheduledBlock(id: id)
    }
}

final class RuntimeScheduler {
    // Shared async_context used by both Swift runtime jobs and IRQ trampolines.
    fileprivate var context = async_context_poll_t()
    private let slots: UnsafeMutablePointer<JobSlot>
    private var didRunJob = false
    private var scheduledBlocks: [UInt32: AnyObject] = [:]
    private var nextScheduledBlockID: UInt32 = 0

    init() {
        slots = .allocate(capacity: cshimsMaxJobSlots)

        guard async_context_poll_init_with_defaults(&context) else {
            fatalError("[CPicoConcurrency] async_context_poll_init_with_defaults failed")
        }

        for index in 0..<cshimsMaxJobSlots {
            let slot = slots.advanced(by: index)
            slot.initialize(
                to: JobSlot(
                    state: cshimsJobSlotFree,
                    job: nil,
                    executorFirst: nil,
                    executorSecond: nil,
                    pendingWorker: cshimsMakePendingWorker(),
                    delayedWorker: cshimsMakeDelayedWorker()
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
        slot.pointee.state = cshimsJobSlotPending
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
        slot.pointee.state = cshimsJobSlotDelayed
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
        slot.pointee.state = cshimsJobSlotDelayed
        slot.pointee.job = job
        slot.pointee.executorFirst = executorFirst
        slot.pointee.executorSecond = executorSecond

        let deadline = from_us_since_boot(deadlineUs)
        guard async_context_add_at_time_worker_at(&context.core, &slot.pointee.delayedWorker, deadline) else {
            releaseSlot(slot)
            fatalError("[CPicoConcurrency] failed to schedule deadline async_context job")
        }
    }

    func pollOnce() -> Int32 {
        didRunJob = false
        async_context_poll(&context.core)
        return didRunJob ? 1 : 0
    }

    func drain() {
        while pollOnce() != 0 {
        }
    }

    func waitForever() {
        async_context_wait_for_work_until(&context.core, UInt64.max)
    }

    // Schedules a one-shot block to run from async_context worker context.
    // This is allowed to allocate; callers that need zero-allocation IRQ paths
    // should use a dedicated preallocated mechanism instead.
    func schedule(_ block: @escaping () -> Void) {
        let id = cshimsWithCritical {
            let id = nextScheduledBlockID
            nextScheduledBlockID &+= 1
            return id
        }

        let scheduledBlock = ScheduledBlock(id: id, block: block)
        let registered = withUnsafeMutablePointer(to: &context.core) { corePtr in
            scheduledBlock.attach(to: UnsafeMutableRawPointer(corePtr))
        }
        guard registered else {
            fatalError("[CPicoConcurrency] failed to register scheduled worker")
        }

        cshimsWithCritical {
            scheduledBlocks[id] = scheduledBlock
        }

        scheduledBlock.signal()
    }

    func completeScheduledBlock(id: UInt32) {
        _ = cshimsWithCritical {
            scheduledBlocks.removeValue(forKey: id)
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
        if let slot = cshimsWithCritical(findFreeSlot) {
            slot.pointee.pendingWorker.work_pending = false
            slot.pointee.delayedWorker.next = nil
            slot.pointee.delayedWorker.next_time = 0
            return slot
        }

        fatalError("[CPicoConcurrency] Concurrency job slot pool exhausted")
    }

    private func releaseSlot(_ slot: UnsafeMutablePointer<JobSlot>) {
        cshimsWithCritical {
            slot.pointee.state = cshimsJobSlotFree
            slot.pointee.job = nil
            slot.pointee.executorFirst = nil
            slot.pointee.executorSecond = nil
            slot.pointee.pendingWorker.work_pending = false
            slot.pointee.delayedWorker.next = nil
            slot.pointee.delayedWorker.next_time = 0
        }
    }

    private func findFreeSlot() -> UnsafeMutablePointer<JobSlot>? {
        for index in 0..<cshimsMaxJobSlots {
            let slot = slots.advanced(by: index)
            if slot.pointee.state == cshimsJobSlotFree {
                slot.pointee.state = cshimsJobSlotPending
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
    scheduledBlock.execute()
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
