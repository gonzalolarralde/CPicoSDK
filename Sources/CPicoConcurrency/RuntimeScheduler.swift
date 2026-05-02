import ConcurrencyShims
import CPicoSDK

private let cshimsMaxJobSlots = 64

private struct JobSlot {
    static let maxJobSlots = 64
    enum State: UInt8 {
        case free = 0
        case pending = 1
        case delayed = 2
    }

    var state: State
    var owner: UnsafeMutableRawPointer?
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

private final class JobSlotPool {
    private let slots: UnsafeMutablePointer<JobSlot>
    private let lock: UnsafeMutablePointer<mutex_t>

    init(owner: UnsafeMutableRawPointer) {
        slots = .allocate(capacity: JobSlot.maxJobSlots)
        lock = .allocate(capacity: 1)
        mutex_init(lock)

        for index in 0..<JobSlot.maxJobSlots {
            let slot = slots.advanced(by: index)
            slot.initialize(
                to: JobSlot(
                    state: .free,
                    owner: owner,
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
        }
    }

    deinit {
        slots.deinitialize(count: cshimsMaxJobSlots)
        slots.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func registerPendingWorkers(with context: UnsafeMutablePointer<async_context_t>) {
        for index in 0..<JobSlot.maxJobSlots {
            let slot = slots.advanced(by: index)
            guard async_context_add_when_pending_worker(context, &slot.pointee.pendingWorker) else {
                fatalError("[CPicoConcurrency] failed to register pending worker with async_context")
            }
        }
    }

    func allocateSlot() -> UnsafeMutablePointer<JobSlot> {
        mutex_enter_blocking(lock)
        defer { mutex_exit(lock) }

        for index in 0..<JobSlot.maxJobSlots {
            let slot = slots.advanced(by: index)
            if slot.pointee.state == .free {
                slot.pointee.state = .pending
                slot.pointee.pendingWorker.work_pending = false
                slot.pointee.delayedWorker.next = nil
                slot.pointee.delayedWorker.next_time = 0
                return slot
            }
        }

        fatalError("[CPicoConcurrency] Concurrency job slot pool exhausted")
    }

    func releaseSlot(_ slot: UnsafeMutablePointer<JobSlot>) {
        mutex_enter_blocking(lock)
        slot.pointee.free()
        mutex_exit(lock)
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

private final class SchedulerCore {
    fileprivate var context = async_context_poll_t()
    private var slots: JobSlotPool!
    private let coreNumber: UInt32
    private let scheduler: RuntimeScheduler

    init(coreNumber: UInt32, scheduler: RuntimeScheduler) {
        self.coreNumber = coreNumber
        self.scheduler = scheduler

        guard async_context_poll_init_with_defaults(&context) else {
            fatalError("[CPicoConcurrency] async_context_poll_init_with_defaults failed")
        }

        slots = JobSlotPool(owner: Unmanaged.passUnretained(self).toOpaque())
        slots.registerPendingWorkers(with: &context.core)
    }

    func enqueueImmediate(
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        let slot = slots.allocateSlot()
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
        let slot = slots.allocateSlot()
        slot.pointee.state = .delayed
        slot.pointee.job = job
        slot.pointee.executorFirst = executorFirst
        slot.pointee.executorSecond = executorSecond

        let deadline = make_timeout_time_us(delayUs)
        guard async_context_add_at_time_worker_at(&context.core, &slot.pointee.delayedWorker, deadline) else {
            slots.releaseSlot(slot)
            fatalError("[CPicoConcurrency] failed to schedule delayed async_context job")
        }
    }

    func enqueueDeadline(
        deadlineUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        let slot = slots.allocateSlot()
        slot.pointee.state = .delayed
        slot.pointee.job = job
        slot.pointee.executorFirst = executorFirst
        slot.pointee.executorSecond = executorSecond

        let deadline = from_us_since_boot(deadlineUs)
        guard async_context_add_at_time_worker_at(&context.core, &slot.pointee.delayedWorker, deadline) else {
            slots.releaseSlot(slot)
            fatalError("[CPicoConcurrency] failed to schedule deadline async_context job")
        }
    }

    @discardableResult
    func pollOnce() -> Int32 {
        scheduler.setDidRunJob(false, on: coreNumber)
        async_context_poll(&context.core)
        return scheduler.didRunJob(on: coreNumber) ? 1 : 0
    }

    func waitForever() {
        async_context_wait_for_work_until(&context.core, UInt64.max)
    }

    func releaseSlot(_ slot: UnsafeMutablePointer<JobSlot>) {
        slots.releaseSlot(slot)
    }
}

final class RuntimeScheduler {
    // Core 0 is also used by IRQ trampolines and delayed Swift runtime jobs.
    fileprivate var core0: SchedulerCore!
    private var didRunJobCore0 = false
    private var didRunJobCore1 = false
    private var nextImmediateCore: UInt32 = 0
    private var core1SchedulingEnabled = false
    private var core1Started = false
    private var core1OffloadBudget = 0
    private let stateLock: UnsafeMutablePointer<mutex_t>
#if CPUMetrics
    private(set) var cpuUsage = RuntimeCPUUsageMeter()
#endif

    init() {
        stateLock = .allocate(capacity: 1)
        mutex_init(stateLock)
        core0 = SchedulerCore(coreNumber: 0, scheduler: self)
    }

    deinit {
        stateLock.deallocate()
    }

    func enqueueImmediate(
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        let target = withStateLock { () -> UInt32 in
            guard core1SchedulingEnabled else {
                return 0
            }
            if get_core_num() == 1 {
                return 0
            }
            guard core1OffloadBudget > 0 else {
                return 0
            }
            let current = nextImmediateCore
            nextImmediateCore = nextImmediateCore == 0 ? 1 : 0
            if current == 1 {
                core1OffloadBudget -= 1
            }
            return current
        }

        if target == 1 {
            startCore1IfNeeded()
            if !cshims_scheduler_enqueue_core1(job, executorFirst, executorSecond) {
                core0.enqueueImmediate(job: job, executorFirst: executorFirst, executorSecond: executorSecond)
            }
        } else {
            core0.enqueueImmediate(job: job, executorFirst: executorFirst, executorSecond: executorSecond)
        }
    }

    func enqueueDelayed(
        delayUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        core0.enqueueDelayed(
            delayUs: delayUs,
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond
        )
    }

    func enqueueDeadline(
        deadlineUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        core0.enqueueDeadline(
            deadlineUs: deadlineUs,
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond
        )
    }

    @discardableResult
    func pollOnce() -> Int32 {
    #if CPUMetrics
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.record(event: .enterTask(name: "runtimeScheduler.pollOnce"))
    #endif
        let result = core0.pollOnce()
    #if CPUMetrics
        cpuUsage.record(event: .exitTask(name: "runtimeScheduler.pollOnce"))
        cpuUsage.reportIfNeeded()
    #endif
        return result
    }

    func drain() {
        while pollOnce() != 0 {
        }
    }

    func enableCore1Scheduling() {
        withStateLock {
            core1SchedulingEnabled = true
            nextImmediateCore = 1
            core1OffloadBudget = 1
        }
        startCore1IfNeeded()
    }

    func waitForever() {
#if CPUMetrics
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.sample()
#endif
        core0.waitForever()
#if CPUMetrics
        RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        cpuUsage.sample()
#endif
    }

#if CPUMetrics
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

        let registered = withUnsafeMutablePointer(to: &core0.context.core) { context in
            scheduledBlock.attach(to: context)
        }
        guard registered else {
            scheduledBlock.cancel()
            fatalError("[CPicoConcurrency] failed to register scheduled worker")
        }

        scheduledBlock.signal()
    }

    func register(_ scheduledBlock: ScheduledBlock) {
        let registered = withUnsafeMutablePointer(to: &core0.context.core) { context in
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
        let owner = slot.pointee.owner

        guard let owner else {
            fatalError("[CPicoConcurrency] scheduler job slot has no owner")
        }

        let schedulerCore = Unmanaged<SchedulerCore>.fromOpaque(owner).takeUnretainedValue()
        schedulerCore.releaseSlot(slot)

        setDidRunJob(true, on: get_core_num())
        cshims_run_job_bridge(job, executorFirst, executorSecond)
    }

    fileprivate func setDidRunJob(_ value: Bool, on coreNumber: UInt32) {
        withStateLock {
            if coreNumber == 0 {
                didRunJobCore0 = value
            } else {
                didRunJobCore1 = value
            }
        }
    }

    fileprivate func didRunJob(on coreNumber: UInt32) -> Bool {
        withStateLock {
            coreNumber == 0 ? didRunJobCore0 : didRunJobCore1
        }
    }

    private func startCore1IfNeeded() {
        let shouldStart = withStateLock { () -> Bool in
            guard !core1Started else {
                return false
            }
            core1Started = true
            return true
        }

        if shouldStart {
            cshims_scheduler_launch_core1()
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        mutex_enter_blocking(stateLock)
        defer { mutex_exit(stateLock) }
        return body()
    }

}

nonisolated(unsafe) var cshimsRuntimeScheduler = RuntimeScheduler()

public func schedulerCore1BootCount() -> UInt32 {
    cshims_scheduler_core1_boot_count()
}

public func schedulerCore1JobsRun() -> UInt32 {
    cshims_scheduler_core1_jobs_run()
}

public func schedulerCore1OverflowCount() -> UInt32 {
    cshims_scheduler_core1_overflow_count()
}

public func enableMulticoreSchedulerPoC() {
    cshimsRuntimeScheduler.enableCore1Scheduling()
}

@_spi(Internal) public func callWithAsyncContext(_ body: (UnsafeMutableRawPointer) -> Void) {
    withUnsafeMutablePointer(to: &cshimsRuntimeScheduler.core0.context.core) { contextPtr in
        body(UnsafeMutableRawPointer(contextPtr))
    }
}

@_cdecl("cshims_scheduler_core1_main")
func cshims_scheduler_core1_main() {
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
