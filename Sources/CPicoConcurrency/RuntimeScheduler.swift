import ConcurrencyShims
import CPicoSDK

private let cshimsMaxJobSlots = 64
private let schedulerInputQueueCapacity: UInt32 = 128
private let schedulerTaskTableCapacity = 64
private let schedulerTaskIdleGraceUs: UInt64 = 100_000

private enum SchedulerMessageKind: UInt8 {
    case immediate = 0
    case delayed = 1
    case deadline = 2
    case probe = 3
}

private struct SchedulerMessage {
    var kind: SchedulerMessageKind
    var ownerCore: UInt8
    var job: UnsafeMutableRawPointer?
    var executorFirst: UnsafeMutableRawPointer?
    var executorSecond: UnsafeMutableRawPointer?
    var timeUs: UInt64
    var taskID: UInt64
    var ownerToken: UInt32
    var asyncTaskAddress: UInt32
    var currentTaskAddress: UInt32
    var jobAddress: UInt32

    init(
        kind: SchedulerMessageKind,
        ownerCore: UInt8,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?,
        timeUs: UInt64
    ) {
        self.kind = kind
        self.ownerCore = ownerCore
        self.job = job
        self.executorFirst = executorFirst
        self.executorSecond = executorSecond
        self.timeUs = timeUs
        self.taskID = job.map { cshims_job_task_id($0) } ?? 0
        self.asyncTaskAddress = job.map { UInt32(truncatingIfNeeded: UInt(bitPattern: cshims_job_async_task($0))) } ?? 0
        self.currentTaskAddress = UInt32(truncatingIfNeeded: UInt(bitPattern: cshims_current_task()))
        self.jobAddress = job.map { UInt32(truncatingIfNeeded: UInt(bitPattern: $0)) } ?? 0
        self.ownerToken = job.map { UInt32(truncatingIfNeeded: UInt(bitPattern: cshims_job_owner_task($0))) } ?? 0
    }
}

private struct TaskTableEntry {
    var ownerToken: UInt32 = 0
    var taskID: UInt64 = 0
    var ownerCore: UInt8 = 0
    var queuedCount: UInt16 = 0
    var runningCount: UInt8 = 0
    var idleSince: UInt64 = 0

    var isEmpty: Bool { ownerToken == 0 }
    var isActive: Bool { queuedCount != 0 || runningCount != 0 }
}

private struct RuntimeSchedulerCounters {
    var pushed: UInt32 = 0
    var pushedCore0: UInt32 = 0
    var pushedCore1: UInt32 = 0
    var queueFull: UInt32 = 0
    var poppedCore0: UInt32 = 0
    var poppedCore1: UInt32 = 0
    var deferredCore0: UInt32 = 0
    var deferredCore1: UInt32 = 0
    var runCore0: UInt32 = 0
    var runCore1: UInt32 = 0
    var nullJobsDropped: UInt32 = 0
    var core1Boots: UInt32 = 0
    var core1LoopEntries: UInt32 = 0
    var core1PollReturns: UInt32 = 0
    var core1Probes: UInt32 = 0
    var core1SeedRuns: UInt32 = 0
    var core1SeedRunsOnCore0: UInt32 = 0
    var core1SeedRunsOnCore1: UInt32 = 0
    var activeTasks: UInt32 = 0
    var tasksOwnedCore0: UInt32 = 0
    var tasksOwnedCore1: UInt32 = 0
    var newTaskCore0: UInt32 = 0
    var newTaskCore1: UInt32 = 0
    var reuseCore0: UInt32 = 0
    var reuseCore1: UInt32 = 0
    var enqueueWhileRunning: UInt32 = 0
    var taskIdle: UInt32 = 0
    var taskEvicted: UInt32 = 0
    var activeEvictBlocked: UInt32 = 0
    var lastCore1TaskIDLow: UInt32 = 0
    var lastCore1OwnerToken: UInt32 = 0
    var lastCore1QueuedCount: UInt32 = 0
    var lastCore1RunningCount: UInt32 = 0
    var lastCore1JobAddress: UInt32 = 0
    var lastSeedTaskAddress: UInt32 = 0
    var lastSeedOwnerCore: UInt32 = 0
    var lastEnqueueCore: UInt32 = 0
    var lastEnqueueHadAsyncTask: UInt32 = 0
    var lastEnqueueHadCurrentTask: UInt32 = 0
    var lastSelectedOwnerCore: UInt32 = 0
    var forcedCore1SeedOwners: UInt32 = 0
    var pendingCore1SeedOwnerForces: UInt32 = 0
    var core1SeedMigrations: UInt32 = 0
}

public struct RuntimeSchedulerMulticoreStats {
    public let pushed: UInt32
    public let pushedCore0: UInt32
    public let pushedCore1: UInt32
    public let queueFull: UInt32
    public let poppedCore0: UInt32
    public let poppedCore1: UInt32
    public let deferredCore0: UInt32
    public let deferredCore1: UInt32
    public let runCore0: UInt32
    public let runCore1: UInt32
    public let nullJobsDropped: UInt32
    public let core1Boots: UInt32
    public let core1LoopEntries: UInt32
    public let core1PollReturns: UInt32
    public let core1Probes: UInt32
    public let core1SeedRuns: UInt32
    public let core1SeedRunsOnCore0: UInt32
    public let core1SeedRunsOnCore1: UInt32
    public let activeTasks: UInt32
    public let tasksOwnedCore0: UInt32
    public let tasksOwnedCore1: UInt32
    public let newTaskCore0: UInt32
    public let newTaskCore1: UInt32
    public let reuseCore0: UInt32
    public let reuseCore1: UInt32
    public let enqueueWhileRunning: UInt32
    public let taskIdle: UInt32
    public let taskEvicted: UInt32
    public let activeEvictBlocked: UInt32
    public let lastCore1TaskIDLow: UInt32
    public let lastCore1OwnerToken: UInt32
    public let lastCore1QueuedCount: UInt32
    public let lastCore1RunningCount: UInt32
    public let lastCore1JobAddress: UInt32
    public let lastSeedTaskAddress: UInt32
    public let lastSeedOwnerCore: UInt32
    public let lastEnqueueCore: UInt32
    public let lastEnqueueHadAsyncTask: UInt32
    public let lastEnqueueHadCurrentTask: UInt32
    public let lastSelectedOwnerCore: UInt32
    public let forcedCore1SeedOwners: UInt32
    public let pendingCore1SeedOwnerForces: UInt32
    public let core1SeedMigrations: UInt32
}

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
    var taskID: UInt64
    var ownerToken: UInt32
    var pendingWorker: async_when_pending_worker_t
    var delayedWorker: async_at_time_worker_t

    mutating func free() {
        state = .free
        job = nil
        executorFirst = nil
        executorSecond = nil
        taskID = 0
        ownerToken = 0
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
    private let core: CPUCore
    fileprivate var context = async_context_poll_t()
    private let slots: UnsafeMutablePointer<JobSlot>
    private var didRunJob = false
    fileprivate private(set) var activeSlotCount: UInt32 = 0
    private var didInitializeContext = false
#if CPUMetrics
    private(set) var cpuUsage: RuntimeCPUUsageMeter
#endif

    init(core: CPUCore, initializeContext: Bool) {
        self.core = core
#if CPUMetrics
        cpuUsage = RuntimeCPUUsageMeter(core: core)
#endif
        slots = .allocate(capacity: JobSlot.maxJobSlots)

        for index in 0..<JobSlot.maxJobSlots {
            let slot = slots.advanced(by: index)
            slot.initialize(
                to: JobSlot(
                    state: .free,
                    job: nil,
                    executorFirst: nil,
                    executorSecond: nil,
                    taskID: 0,
                    ownerToken: 0,
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

        if initializeContext {
            initializeAsyncContext()
        }
    }

    func initializeAsyncContext() {
        guard !didInitializeContext else {
            return
        }

        guard async_context_poll_init_with_defaults(&context) else {
            fatalError("[CPicoConcurrency] async_context_poll_init_with_defaults failed")
        }

        for index in 0..<JobSlot.maxJobSlots {
            let slot = slots.advanced(by: index)
            guard async_context_add_when_pending_worker(&context.core, &slot.pointee.pendingWorker) else {
                fatalError("[CPicoConcurrency] failed to register pending worker with async_context")
            }
        }

        didInitializeContext = true
    }

    deinit {
        slots.deinitialize(count: cshimsMaxJobSlots)
        slots.deallocate()
    }

    fileprivate func enqueue(_ message: SchedulerMessage) {
        initializeAsyncContext()

        switch message.kind {
        case .immediate:
            enqueueImmediate(message)
        case .delayed:
            enqueueDelayed(message)
        case .deadline:
            enqueueDeadline(message)
        case .probe:
            break
        }
    }

    func enqueueImmediate(
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        let message = SchedulerMessage(
            kind: .immediate,
            ownerCore: UInt8(truncatingIfNeeded: get_core_num()),
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond,
            timeUs: 0
        )
        enqueueImmediate(message)
    }

    func enqueueDelayed(
        delayUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        let message = SchedulerMessage(
            kind: .delayed,
            ownerCore: UInt8(truncatingIfNeeded: get_core_num()),
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond,
            timeUs: delayUs
        )
        enqueueDelayed(message)
    }

    func enqueueDeadline(
        deadlineUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        let message = SchedulerMessage(
            kind: .deadline,
            ownerCore: UInt8(truncatingIfNeeded: get_core_num()),
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond,
            timeUs: deadlineUs
        )
        enqueueDeadline(message)
    }

    @discardableResult
    func pollOnce() -> Int32 {
        initializeAsyncContext()
    #if CPUMetrics
        if core == .core0 {
            RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        }
        cpuUsage.record(event: .enterTask(name: "runtimeScheduler.pollOnce"))
    #endif
        didRunJob = false
        async_context_poll(&context.core)
    #if CPUMetrics
        cpuUsage.record(event: .exitTask(name: "runtimeScheduler.pollOnce"))
        cpuUsage.reportIfNeeded()
    #endif
        return didRunJob ? 1 : 0
    }

    func drain() {
        while pollOnce() != 0 {
        }
    }

    var hasScheduledWork: Bool {
        activeSlotCount != 0
    }

    func waitForever() {
        initializeAsyncContext()
#if CPUMetrics
        if core == .core0 {
            RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        }
        cpuUsage.sample()
#endif
        async_context_wait_for_work_until(&context.core, make_timeout_time_us(1000))
#if CPUMetrics
        if core == .core0 {
            RuntimeCPUUsageMeter.ensureIRQUsageVectorWrapping()
        }
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

    func cpuUsageStream() -> AsyncStream<CPUStats> {
        cpuUsage.stream
    }

    func latestCPUUsage() -> CPUStats? {
        cpuUsage.latest()
    }
#endif

    func schedule(_ block: @escaping () -> Void) {
        initializeAsyncContext()
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
        initializeAsyncContext()
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

        defer {
            releaseSlot(slot)
        }
        didRunJob = true
        guard let job else {
            cshimsRuntimeScheduler.recordNullJobDrop()
            return
        }
        cshims_run_job_bridge(job, executorFirst, executorSecond)
    }

    private func enqueueImmediate(_ message: SchedulerMessage) {
        let slot = allocateSlot(for: message)
        slot.pointee.state = .pending
        async_context_set_work_pending(&context.core, &slot.pointee.pendingWorker)
    }

    private func enqueueDelayed(_ message: SchedulerMessage) {
        let slot = allocateSlot(for: message)
        slot.pointee.state = .delayed

        let deadline = make_timeout_time_us(message.timeUs)
        guard async_context_add_at_time_worker_at(&context.core, &slot.pointee.delayedWorker, deadline) else {
            releaseSlot(slot)
            fatalError("[CPicoConcurrency] failed to schedule delayed async_context job")
        }
    }

    private func enqueueDeadline(_ message: SchedulerMessage) {
        let slot = allocateSlot(for: message)
        slot.pointee.state = .delayed

        let deadline = from_us_since_boot(message.timeUs)
        guard async_context_add_at_time_worker_at(&context.core, &slot.pointee.delayedWorker, deadline) else {
            releaseSlot(slot)
            fatalError("[CPicoConcurrency] failed to schedule deadline async_context job")
        }
    }

    private func allocateSlot(for message: SchedulerMessage) -> UnsafeMutablePointer<JobSlot> {
        if let slot = withCritical(findFreeSlot) {
            slot.pointee.pendingWorker.work_pending = false
            slot.pointee.delayedWorker.next = nil
            slot.pointee.delayedWorker.next_time = 0
            slot.pointee.job = message.job
            slot.pointee.executorFirst = message.executorFirst
            slot.pointee.executorSecond = message.executorSecond
            slot.pointee.taskID = message.taskID
            slot.pointee.ownerToken = message.ownerToken
            activeSlotCount &+= 1
            return slot
        }

        fatalError("[CPicoConcurrency] Concurrency job slot pool exhausted")
    }

    private func releaseSlot(_ slot: UnsafeMutablePointer<JobSlot>) {
        withCritical {
            slot.pointee.free()
            activeSlotCount &-= 1
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

final class RuntimeSchedulerSystem {
    private var core0Queue = queue_t()
    private var core1Queue = queue_t()
    private var didInitializeQueue = false
    private let core0Scheduler = RuntimeScheduler(core: .core0, initializeContext: true)
    private let core1Scheduler = RuntimeScheduler(core: .core1, initializeContext: false)
    private var counters = RuntimeSchedulerCounters()
    private var lock = mutex_t()
    private var didLaunchCore1 = false
    private var pendingCore1SeedOwnerForces: UInt8 = 0
    private var pendingCore1SeedMigrationOwner: UInt32 = 0
    private var taskTable = Array(repeating: TaskTableEntry(), count: schedulerTaskTableCapacity)

    init() {
        mutex_init(&lock)
        initializeQueue()
    }

    func startMulticore() {
        guard !didLaunchCore1 else {
            return
        }
        core1Scheduler.initializeAsyncContext()
        didLaunchCore1 = true
        cshims_scheduler_launch_core1()
    }

    @discardableResult
    func pollOnce() -> Int32 {
        let scheduler = schedulerForCurrentCore()
        let didRouteMessage = drainInputMessages(into: scheduler)
        let didPollWork = (didRouteMessage || scheduler.hasScheduledWork || get_core_num() == 0) && scheduler.pollOnce() != 0
        return (didRouteMessage || didPollWork) ? 1 : 0
    }

    func drain() {
        while pollOnce() != 0 {
        }
    }

    func waitForever() {
        schedulerForCurrentCore().waitForever()
    }

    func enqueueImmediate(
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        enqueueRuntimeJob(kind: .immediate, timeUs: 0, job: job, executorFirst: executorFirst, executorSecond: executorSecond)
    }

    func enqueueDelayed(
        delayUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        enqueueRuntimeJob(kind: .delayed, timeUs: delayUs, job: job, executorFirst: executorFirst, executorSecond: executorSecond)
    }

    func enqueueDeadline(
        deadlineUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        enqueueRuntimeJob(kind: .deadline, timeUs: deadlineUs, job: job, executorFirst: executorFirst, executorSecond: executorSecond)
    }

    func enqueueProbe() {
        push(SchedulerMessage(kind: .probe, ownerCore: 1, job: nil, executorFirst: nil, executorSecond: nil, timeUs: 0))
    }

    func schedule(_ block: @escaping () -> Void) {
        schedulerForCurrentCore().schedule(block)
    }

    func register(_ scheduledBlock: ScheduledBlock) {
        schedulerForCurrentCore().register(scheduledBlock)
    }

    fileprivate func run(slot: UnsafeMutablePointer<JobSlot>) {
        let core = UInt8(truncatingIfNeeded: get_core_num())
        let ownerToken = slot.pointee.ownerToken
        let taskID = slot.pointee.taskID
        jobWillRun(ownerToken: ownerToken, taskID: taskID, on: core)
        defer {
            jobDidRun(ownerToken: ownerToken, taskID: taskID, on: core)
        }
        scheduler(forCore: core).run(slot: slot)
    }

    func recordNullJobDrop() {
        withLock {
            counters.nullJobsDropped &+= 1
        }
    }

    func recordCore1Boot() {
        withLock {
            counters.core1Boots &+= 1
        }
    }

    func recordCore1LoopEntry() {
        withLock {
            counters.core1LoopEntries &+= 1
        }
    }

    func recordCore1PollReturn() {
        withLock {
            counters.core1PollReturns &+= 1
        }
    }

    func recordCore1SeedRun() {
        let core = UInt8(truncatingIfNeeded: get_core_num())
        let currentTaskAddress = UInt32(truncatingIfNeeded: UInt(bitPattern: cshims_current_task()))
        withLock {
            counters.core1SeedRuns &+= 1
            if core == 1 {
                counters.core1SeedRunsOnCore1 &+= 1
            } else {
                counters.core1SeedRunsOnCore0 &+= 1
            }
            counters.lastSeedTaskAddress = currentTaskAddress
            if currentTaskAddress != 0,
               let index = taskTable.firstIndex(where: { $0.ownerToken == currentTaskAddress }) {
                counters.lastSeedOwnerCore = UInt32(taskTable[index].ownerCore)
                if core == 0, taskTable[index].ownerCore == 0 {
                    pendingCore1SeedMigrationOwner = currentTaskAddress
                }
            } else {
                counters.lastSeedOwnerCore = 255
            }
        }
    }

    func createCore1SeedTask() {
        withLock {
            pendingCore1SeedOwnerForces &+= 1
            counters.pendingCore1SeedOwnerForces = UInt32(pendingCore1SeedOwnerForces)
        }
        Task {
            await core1SeedWorker()
        }
    }

    func statsSnapshot() -> RuntimeSchedulerMulticoreStats {
        withLock {
            RuntimeSchedulerMulticoreStats(
                pushed: counters.pushed,
                pushedCore0: counters.pushedCore0,
                pushedCore1: counters.pushedCore1,
                queueFull: counters.queueFull,
                poppedCore0: counters.poppedCore0,
                poppedCore1: counters.poppedCore1,
                deferredCore0: counters.deferredCore0,
                deferredCore1: counters.deferredCore1,
                runCore0: counters.runCore0,
                runCore1: counters.runCore1,
                nullJobsDropped: counters.nullJobsDropped,
                core1Boots: counters.core1Boots,
                core1LoopEntries: counters.core1LoopEntries,
                core1PollReturns: counters.core1PollReturns,
                core1Probes: counters.core1Probes,
                core1SeedRuns: counters.core1SeedRuns,
                core1SeedRunsOnCore0: counters.core1SeedRunsOnCore0,
                core1SeedRunsOnCore1: counters.core1SeedRunsOnCore1,
                activeTasks: counters.activeTasks,
                tasksOwnedCore0: counters.tasksOwnedCore0,
                tasksOwnedCore1: counters.tasksOwnedCore1,
                newTaskCore0: counters.newTaskCore0,
                newTaskCore1: counters.newTaskCore1,
                reuseCore0: counters.reuseCore0,
                reuseCore1: counters.reuseCore1,
                enqueueWhileRunning: counters.enqueueWhileRunning,
                taskIdle: counters.taskIdle,
                taskEvicted: counters.taskEvicted,
                activeEvictBlocked: counters.activeEvictBlocked,
                lastCore1TaskIDLow: counters.lastCore1TaskIDLow,
                lastCore1OwnerToken: counters.lastCore1OwnerToken,
                lastCore1QueuedCount: counters.lastCore1QueuedCount,
                lastCore1RunningCount: counters.lastCore1RunningCount,
                lastCore1JobAddress: counters.lastCore1JobAddress,
                lastSeedTaskAddress: counters.lastSeedTaskAddress,
                lastSeedOwnerCore: counters.lastSeedOwnerCore,
                lastEnqueueCore: counters.lastEnqueueCore,
                lastEnqueueHadAsyncTask: counters.lastEnqueueHadAsyncTask,
                lastEnqueueHadCurrentTask: counters.lastEnqueueHadCurrentTask,
                lastSelectedOwnerCore: counters.lastSelectedOwnerCore,
                forcedCore1SeedOwners: counters.forcedCore1SeedOwners,
                pendingCore1SeedOwnerForces: counters.pendingCore1SeedOwnerForces,
                core1SeedMigrations: counters.core1SeedMigrations
            )
        }
    }

#if CPUMetrics
    func recordExternalEvent(_ event: RuntimeCPUUsageMeter.Event) {
        schedulerForCurrentCore().recordExternalEvent(event)
    }

    func sampleCPUUsage() {
        schedulerForCurrentCore().sampleCPUUsage()
    }

    func cpuUsageStream(for core: CPUCore) -> AsyncStream<CPUStats> {
        scheduler(forCore: core.rawValue).cpuUsageStream()
    }

    func latestCPUUsage(for core: CPUCore) -> CPUStats? {
        scheduler(forCore: core.rawValue).latestCPUUsage()
    }
#endif

    func callWithCurrentAsyncContext(_ body: (UnsafeMutableRawPointer) -> Void) {
        let scheduler = schedulerForCurrentCore()
        scheduler.initializeAsyncContext()
        withUnsafeMutablePointer(to: &scheduler.context.core) { contextPtr in
            body(UnsafeMutableRawPointer(contextPtr))
        }
    }

    private func initializeQueue() {
        guard !didInitializeQueue else {
            return
        }

        queue_init(
            &core0Queue,
            UInt32(MemoryLayout<SchedulerMessage>.stride),
            schedulerInputQueueCapacity
        )
        queue_init(
            &core1Queue,
            UInt32(MemoryLayout<SchedulerMessage>.stride),
            schedulerInputQueueCapacity
        )
        didInitializeQueue = true
    }

    private func enqueueRuntimeJob(
        kind: SchedulerMessageKind,
        timeUs: UInt64,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?
    ) {
        var message = SchedulerMessage(
            kind: kind,
            ownerCore: 0,
            job: job,
            executorFirst: executorFirst,
            executorSecond: executorSecond,
            timeUs: timeUs
        )
        message.ownerCore = ownerCoreForEnqueuedJob(message)
        push(message)
    }

    private func ownerCoreForEnqueuedJob(_ message: SchedulerMessage) -> UInt8 {
        guard message.ownerToken != 0 else {
            return UInt8(truncatingIfNeeded: get_core_num())
        }

        return withLock {
            let enqueueCore = UInt8(truncatingIfNeeded: get_core_num())
            let now = time_us_64()
            let index = entryIndexForEnqueue(ownerToken: message.ownerToken)
            let wasActive = taskTable[index].isActive
            let reuseIdleOwner = !taskTable[index].isEmpty
                && !wasActive
                && taskTable[index].idleSince != 0
                && now &- taskTable[index].idleSince <= schedulerTaskIdleGraceUs

            if taskTable[index].isEmpty {
                taskTable[index].ownerToken = message.ownerToken
                taskTable[index].taskID = message.taskID
                taskTable[index].ownerCore = chooseOwnerCore(message: message, enqueueCore: enqueueCore)
                taskTable[index].idleSince = 0
                if taskTable[index].ownerCore == 1 {
                    counters.newTaskCore1 &+= 1
                } else {
                    counters.newTaskCore0 &+= 1
                }
            } else if !wasActive {
                taskTable[index].taskID = message.taskID
                taskTable[index].idleSince = 0
                if reuseIdleOwner {
                    if taskTable[index].ownerCore == 1 {
                        counters.reuseCore1 &+= 1
                    } else {
                        counters.reuseCore0 &+= 1
                    }
                } else {
                    taskTable[index].ownerCore = chooseOwnerCore(message: message, enqueueCore: enqueueCore)
                    if taskTable[index].ownerCore == 1 {
                        counters.newTaskCore1 &+= 1
                    } else {
                        counters.newTaskCore0 &+= 1
                    }
                }
            } else if taskTable[index].ownerCore == 1 {
                counters.reuseCore1 &+= 1
            } else {
                counters.reuseCore0 &+= 1
            }

            if taskTable[index].runningCount != 0 {
                counters.enqueueWhileRunning &+= 1
            }

            taskTable[index].queuedCount &+= 1
            counters.lastEnqueueCore = UInt32(enqueueCore)
            counters.lastEnqueueHadAsyncTask = message.asyncTaskAddress == 0 ? 0 : 1
            counters.lastEnqueueHadCurrentTask = message.currentTaskAddress == 0 ? 0 : 1
            counters.lastSelectedOwnerCore = UInt32(taskTable[index].ownerCore)
            recordCore1LastTaskIfNeeded(message: message, entry: taskTable[index])
            refreshTaskOwnershipCounters()
            return taskTable[index].ownerCore
        }
    }

    private func entryIndexForEnqueue(ownerToken: UInt32) -> Int {
        var emptyIndex: Int?
        var oldestIdleIndex: Int?
        var oldestIdleSince = UInt64.max

        for index in 0..<taskTable.count {
            let entry = taskTable[index]
            if entry.ownerToken == ownerToken {
                return index
            }
            if entry.isEmpty && emptyIndex == nil {
                emptyIndex = index
            }
            if !entry.isEmpty && !entry.isActive && entry.idleSince < oldestIdleSince {
                oldestIdleIndex = index
                oldestIdleSince = entry.idleSince
            }
        }

        if let emptyIndex {
            return emptyIndex
        }

        if let oldestIdleIndex {
            counters.taskEvicted &+= 1
            taskTable[oldestIdleIndex] = TaskTableEntry()
            return oldestIdleIndex
        }

        counters.activeEvictBlocked &+= 1
        fatalError("[CPicoConcurrency] scheduler task table full with no idle entry")
    }

    private func chooseOwnerCore(message: SchedulerMessage, enqueueCore: UInt8) -> UInt8 {
        guard didLaunchCore1 else {
            return 0
        }

        if pendingCore1SeedOwnerForces != 0, message.currentTaskAddress == 0 || enqueueCore == 1 {
            pendingCore1SeedOwnerForces &-= 1
            counters.pendingCore1SeedOwnerForces = UInt32(pendingCore1SeedOwnerForces)
            counters.forcedCore1SeedOwners &+= 1
            return 1
        }

        if message.currentTaskAddress != 0,
           let currentIndex = taskTable.firstIndex(where: { $0.ownerToken == message.currentTaskAddress }) {
            return taskTable[currentIndex].ownerCore
        }

        let core0Work = outstandingWork(on: 0)
        let core1Work = outstandingWork(on: 1)
        return core0Work <= core1Work ? 0 : 1
    }

    private func outstandingWork(on core: UInt8) -> UInt32 {
        var total: UInt32 = 0
        for entry in taskTable where !entry.isEmpty && entry.ownerCore == core {
            total &+= UInt32(entry.queuedCount)
            total &+= UInt32(entry.runningCount)
        }
        return total
    }

    private func push(_ message: SchedulerMessage) {
        initializeQueue()
        var mutableMessage = message
        let didPush: Bool
        if message.ownerCore == 1 {
            didPush = queue_try_add(&core1Queue, &mutableMessage)
        } else {
            didPush = queue_try_add(&core0Queue, &mutableMessage)
        }
        guard didPush else {
            undoAcceptedJob(message)
            withLock {
                counters.queueFull &+= 1
            }
            fatalError("[CPicoConcurrency] scheduler owner queue full")
        }

        withLock {
            counters.pushed &+= 1
            if message.ownerCore == 1 {
                counters.pushedCore1 &+= 1
            } else {
                counters.pushedCore0 &+= 1
            }
        }
    }

    private func undoAcceptedJob(_ message: SchedulerMessage) {
        guard message.ownerToken != 0 else {
            return
        }
        withLock {
            guard let index = taskTable.firstIndex(where: { $0.ownerToken == message.ownerToken }) else {
                return
            }
            if taskTable[index].queuedCount > 0 {
                taskTable[index].queuedCount &-= 1
            }
            if !taskTable[index].isActive {
                taskTable[index].idleSince = time_us_64()
            }
            refreshTaskOwnershipCounters()
        }
    }

    private func drainInputMessages(into scheduler: RuntimeScheduler) -> Bool {
        let core = UInt8(truncatingIfNeeded: get_core_num())
        var didRoute = false

        for _ in 0..<schedulerInputQueueCapacity {
            var message = SchedulerMessage(kind: .immediate, ownerCore: 0, job: nil, executorFirst: nil, executorSecond: nil, timeUs: 0)
            let didPop: Bool
            if core == 1 {
                didPop = queue_try_remove(&core1Queue, &message)
            } else {
                didPop = queue_try_remove(&core0Queue, &message)
            }
            guard didPop else {
                break
            }

            refreshMessageOwnerFromTable(&message)
            guard message.ownerCore == core else {
                withLock {
                    counters.activeEvictBlocked &+= 1
                }
                fatalError("[CPicoConcurrency] scheduler owner queue delivered wrong-core job")
            }

            if core == 1 {
                withLock {
                    counters.poppedCore1 &+= 1
                }
            } else {
                withLock {
                    counters.poppedCore0 &+= 1
                }
            }

            switch message.kind {
            case .probe:
                if core == 1 {
                    withLock {
                        counters.core1Probes &+= 1
                    }
                }
            case .immediate, .delayed, .deadline:
                scheduler.enqueue(message)
            }
            didRoute = true
        }

        return didRoute
    }

    private func refreshMessageOwnerFromTable(_ message: inout SchedulerMessage) {
        guard message.ownerToken != 0 else {
            return
        }
        withLock {
            guard let index = taskTable.firstIndex(where: { $0.ownerToken == message.ownerToken }) else {
                return
            }
            message.ownerCore = taskTable[index].ownerCore
        }
    }

    private func jobWillRun(ownerToken: UInt32, taskID: UInt64, on core: UInt8) {
        withLock {
            if core == 1 {
                counters.runCore1 &+= 1
            } else {
                counters.runCore0 &+= 1
            }

            guard ownerToken != 0, let index = taskTable.firstIndex(where: { $0.ownerToken == ownerToken }) else {
                return
            }

            if taskTable[index].ownerCore != core {
                counters.activeEvictBlocked &+= 1
                fatalError("[CPicoConcurrency] task owner mismatch before swift_job_run")
            }

            if taskTable[index].queuedCount > 0 {
                taskTable[index].queuedCount &-= 1
            }
            taskTable[index].runningCount &+= 1
            recordCore1LastTaskIfNeeded(taskID: taskID, jobAddress: 0, entry: taskTable[index])
            refreshTaskOwnershipCounters()
        }
    }

    private func jobDidRun(ownerToken: UInt32, taskID: UInt64, on core: UInt8) {
        guard ownerToken != 0 else {
            return
        }

        withLock {
            guard let index = taskTable.firstIndex(where: { $0.ownerToken == ownerToken }) else {
                return
            }
            if taskTable[index].runningCount > 0 {
                taskTable[index].runningCount &-= 1
            }
            if pendingCore1SeedMigrationOwner == ownerToken, !taskTable[index].isActive {
                taskTable[index].ownerCore = 1
                pendingCore1SeedMigrationOwner = 0
                counters.core1SeedMigrations &+= 1
            }
            if !taskTable[index].isActive {
                taskTable[index].idleSince = time_us_64()
                counters.taskIdle &+= 1
                recordCore1LastTaskIfNeeded(taskID: taskID, jobAddress: 0, entry: taskTable[index])
            } else {
                recordCore1LastTaskIfNeeded(taskID: taskID, jobAddress: 0, entry: taskTable[index])
            }
            refreshTaskOwnershipCounters()
        }
    }

    private func recordCore1LastTaskIfNeeded(message: SchedulerMessage, entry: TaskTableEntry) {
        recordCore1LastTaskIfNeeded(taskID: message.taskID, jobAddress: message.jobAddress, entry: entry)
    }

    private func recordCore1LastTaskIfNeeded(taskID: UInt64, jobAddress: UInt32, entry: TaskTableEntry) {
        guard entry.ownerCore == 1 else {
            return
        }
        counters.lastCore1TaskIDLow = UInt32(truncatingIfNeeded: taskID)
        counters.lastCore1OwnerToken = entry.ownerToken
        counters.lastCore1QueuedCount = UInt32(entry.queuedCount)
        counters.lastCore1RunningCount = UInt32(entry.runningCount)
        if jobAddress != 0 {
            counters.lastCore1JobAddress = jobAddress
        }
    }

    private func refreshTaskOwnershipCounters() {
        var active: UInt32 = 0
        var owned0: UInt32 = 0
        var owned1: UInt32 = 0
        for entry in taskTable where !entry.isEmpty {
            if entry.isActive {
                active &+= 1
                if entry.ownerCore == 1 {
                    owned1 &+= 1
                } else {
                    owned0 &+= 1
                }
            }
        }
        counters.activeTasks = active
        counters.tasksOwnedCore0 = owned0
        counters.tasksOwnedCore1 = owned1
    }

    private func withLock<T>(_ body: () -> T) -> T {
        mutex_enter_blocking(&lock)
        defer { mutex_exit(&lock) }
        return body()
    }

    private func schedulerForCurrentCore() -> RuntimeScheduler {
        scheduler(forCore: UInt8(truncatingIfNeeded: get_core_num()))
    }

    private func scheduler(forCore core: UInt8) -> RuntimeScheduler {
        core == 1 ? core1Scheduler : core0Scheduler
    }
}

nonisolated(unsafe) var cshimsRuntimeScheduler = RuntimeSchedulerSystem()

@_spi(Internal) public func callWithAsyncContext(_ body: (UnsafeMutableRawPointer) -> Void) {
    cshimsRuntimeScheduler.callWithCurrentAsyncContext(body)
}

public func startRuntimeSchedulerMulticore() {
    cshimsRuntimeScheduler.startMulticore()
}

public func runtimeSchedulerMulticoreStats() -> RuntimeSchedulerMulticoreStats {
    cshimsRuntimeScheduler.statsSnapshot()
}

public func enqueueRuntimeSchedulerMulticoreProbe() {
    cshimsRuntimeScheduler.enqueueProbe()
}

#if CPUMetrics
public func runtimeSchedulerCPUUsageSnapshot(for core: CPUCore) -> CPUStats? {
    cshimsRuntimeScheduler.latestCPUUsage(for: core)
}
#endif

private func core1SeedWorker() async {
    while true {
        cshimsRuntimeScheduler.recordCore1SeedRun()
        await Task.yield()
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

@_cdecl("cshims_scheduler_core1_boot")
func cshims_scheduler_core1_boot() {
    cshimsRuntimeScheduler.recordCore1Boot()
}

@_cdecl("cshims_scheduler_core1_seed")
func cshims_scheduler_core1_seed() {
    cshimsRuntimeScheduler.createCore1SeedTask()
}

@_cdecl("cshims_scheduler_core1_loop_iteration")
func cshims_scheduler_core1_loop_iteration() -> Int32 {
    cshimsRuntimeScheduler.recordCore1LoopEntry()
    let didWork = cshimsRuntimeScheduler.pollOnce()
    cshimsRuntimeScheduler.recordCore1PollReturn()
    return didWork
}
