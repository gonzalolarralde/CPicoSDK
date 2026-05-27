import ConcurrencyShims
import CPicoSDK

public enum CPUCore: UInt8, Sendable {
    case core0 = 0
    case core1 = 1

    fileprivate init(_ core: CoreID) {
        switch core {
        case .core0:
            self = .core0
        case .core1:
            self = .core1
        }
    }
}

/// Report containing CPU usage metrics for a given time window. The `usageEvents`
/// async stream provides periodic reports with the latest CPU usage data, which
/// can be used for monitoring or debugging purposes.
///
/// WARNING: *THIS IS AN EXPERIMENTAL IMPLEMENTATION* Expect inaccurate readings,
/// missing features, and potential performance issues. Use with caution.
///
/// WARNING: IRQ handlers are wrapped with a lightweight shim that counts
/// interrupt events from C. Interrupt time is approximate and is only recorded
/// by handlers that explicitly publish timing samples. Expect potential
/// performance degradations and unexpected interactions with third-party
/// libraries that also wrap IRQ handlers. If you experience issues, you can
/// disable CPU monitoring and the IRQ wrapping by undefining the `CPUMetrics`
/// flag in your build configuration.
public struct CPUStats: Sendable {
    public static var enabled: Bool {
        #if CPUMetrics
            true
        #else
            false
        #endif
    }

    public static func usageEvents(for core: CPUCore) -> AsyncStream<Self>? {
        #if CPUMetrics
            cshimsRuntimeScheduler.cpuUsageEvents(for: core)
        #else
            nil
        #endif
    }

    public static func usageEvents() -> AsyncStream<Self>? {
        #if CPUMetrics
            cshimsRuntimeScheduler.cpuUsageEvents()
        #else
            nil
        #endif
    }

    public let timestamp: UInt64
    public let core: CPUCore
    public let taskUsageTime: UInt64
    public let interruptUsageTime: UInt64
    public let idleUsageTime: UInt64
    public let totalTime: UInt64
    public let interruptEvents: UInt64

    public var memoryStats: [MemoryType: MemoryStats] {
        MemoryStats.stats
    }

    public var taskUsagePercent: Double {
        totalTime > 0 ? Double(taskUsageTime) / Double(totalTime) * 100 : 0
    }
    public var interruptUsagePercent: Double {
        totalTime > 0 ? Double(interruptUsageTime) / Double(totalTime) * 100 : 0
    }
    public var idleUsagePercent: Double {
        totalTime > 0 ? Double(idleUsageTime) / Double(totalTime) * 100 : 0
    }

    public var description: String {
        "CPU(core: \(core.rawValue)) usage: task=\(taskUsagePercent)%; irq=\(interruptUsagePercent)%; idle=\(idleUsagePercent)%; total_us=\(totalTime); irq_events=\(interruptEvents)"
    }

    public func print(includeMemoryStats: Bool = true) {
        Swift::print("[CPicoConcurrency] \(self.description)")
        if includeMemoryStats {
            for memoryStats in memoryStats.values {
                memoryStats.print()
            }
        }
    }
}

#if CPUMetrics

struct RuntimeCPUUsageMeter: ~Copyable {
    // MARK: - IRQ Wrapping for Accurate CPU Usage Attribution
    private static let irqWrapReconcileIntervalUs: UInt64 = 1_000_000
    nonisolated(unsafe) private static var core0IRQWrapNextReconcileUs: UInt64 = 0
    nonisolated(unsafe) private static var core1IRQWrapNextReconcileUs: UInt64 = 0

    @_transparent
    static func irqNeedsWrapping(num irq: UInt32) -> Bool {
        if irq < UInt32(NUM_ALARMS * NUM_GENERIC_TIMERS) {
            return false
        }

        if irq == UInt32(USBCTRL_IRQ.rawValue) {
            return false
        }

        guard let wrapper = cshims_get_irq_wrapper(irq) else {
            return false
        }

        let currentVector = cshims_get_irq_vtor_handler(irq)
        if address(for: currentVector) == address(for: wrapper) {
            return false
        }

        return currentVector != nil
    }

    @discardableResult @_transparent
    static func wrapIRQ(num irq: UInt32) -> Bool {
        guard let wrapper = cshims_get_irq_wrapper(irq) else {
            return false
        }

        let wasEnabled = irq_is_enabled(irq)
        if wasEnabled {
            irq_set_enabled(irq, false)
        }

        defer {
            if wasEnabled {
                irq_set_enabled(irq, true)
            }
        }

        let currentVector = cshims_get_irq_vtor_handler(irq)
        if address(for: currentVector) == address(for: wrapper) {
            return false
        }

        guard let currentVector else {
            return false
        }

        cshims_set_irq_wrapper_original(irq, currentVector)
        cshims_set_irq_vtor_handler(irq, wrapper)

        return true
    }

    static func ensureIRQUsageVectorWrapping() {
        let core = CoreID.current
        let nowUs = time_us_64()
        let nextReconcileUs = irqWrapNextReconcileUs(for: core)
        if nextReconcileUs != 0 && nowUs < nextReconcileUs {
            return
        }
        setIRQWrapNextReconcileUs(nowUs &+ irqWrapReconcileIntervalUs, for: core)

        // Non-critical fast pass to find IRQs that might need wrapping for the
        // current core's vector table. We will check them again in
        // the critical section to avoid doing any potentially expensive operations while interrupts
        // are disabled.
        if NUM_IRQS > 64 {
            assertionFailure("[CPicoConcurrency] NUM_IRQS exceeds 64, which is currently not supported by the IRQ wrapping logic.")
        }

        let numIRQs = min(NUM_IRQS, 64)
        var candidates: UInt64 = 0
        for irqIndex in 0..<numIRQs {
            if irqNeedsWrapping(num: irqIndex) {
                candidates |= (1 << irqIndex)
            }
        }

        guard candidates > 0 else {
            return
        }

        withCritical {
            for irqIndex in 0..<numIRQs {
                if (candidates & (1 << irqIndex)) != 0 {
                    wrapIRQ(num: irqIndex)
                }
            }
        }
    }

    private static func address(for handler: irq_handler_t?) -> UInt {
        UInt(bitPattern: unsafeBitCast(handler, to: UnsafeRawPointer?.self))
    }

    private static func irqWrapNextReconcileUs(for core: CoreID) -> UInt64 {
        switch core {
        case .core0:
            core0IRQWrapNextReconcileUs
        case .core1:
            core1IRQWrapNextReconcileUs
        }
    }

    private static func setIRQWrapNextReconcileUs(_ value: UInt64, for core: CoreID) {
        switch core {
        case .core0:
            core0IRQWrapNextReconcileUs = value
        case .core1:
            core1IRQWrapNextReconcileUs = value
        }
    }

    enum Event {
        case enterTask(name: String)
        case exitTask(name: String)
        case enterInterrupt(interrupt: UInt)
        case exitInterrupt(interrupt: UInt)
    }

    // MARK: - CPU Usage Metering

    private static let windowUs: UInt64 = 1_000_000

    private let core: CoreID
    private var windowStartUs: UInt64 = 0
    private var lastEventUs: UInt64 = 0

    private var taskUs: UInt64 = 0
    private var interruptUs: UInt64 = 0
    private var idleUs: UInt64 = 0
    private var interruptEvents: UInt64 = 0

    private var taskIsActive = false
    private var interruptDepth: UInt = 0
    
    private let mutex: UnsafeMutablePointer<mutex_t> = .allocate(capacity: 1)

    init(core: CoreID) {
        self.core = core
        mutex_init(mutex)
    }

    deinit {
        mutex.deinitialize(count: 1)
        mutex.deallocate()
    }

    @_transparent
    mutating func record(event: Event) {
        guard mutex_try_enter(mutex, nil) else {
            // This might cause some inaccuracies in the metrics, but it's better than blocking critical code paths like IRQ handlers.
            return
        }

        defer {
            mutex_exit(mutex)
        }

        let nowUs = time_us_64()
        accountElapsed(nowUs: nowUs)

        switch event {
        case .enterTask:
            taskIsActive = true
        case .exitTask:
            taskIsActive = false
        case .enterInterrupt:
            interruptDepth &+= 1
            interruptEvents &+= 1
        case .exitInterrupt:
            if interruptDepth > 0 {
                interruptDepth &-= 1
            }
        }
    }

    @_transparent
    mutating func sample() {
        guard mutex_try_enter(mutex, nil) else {
            // This might cause some inaccuracies in the metrics, but it's better than blocking critical code paths like IRQ handlers.
            return
        }

        defer {
            mutex_exit(mutex)
        }

        let nowUs = time_us_64()
        accountElapsed(nowUs: nowUs)
    }

    @_transparent
    mutating func reportIfNeeded() -> CPUStats? {
        guard mutex_try_enter(mutex, nil) else {
            // This might cause some inaccuracies in the metrics, but it's better than blocking critical code paths like IRQ handlers.
            return nil
        }

        let nowUs = time_us_64()
        accountElapsed(nowUs: nowUs)

        guard windowStartUs != 0 else {
            mutex_exit(mutex)
            return nil
        }

        guard nowUs &- windowStartUs >= Self.windowUs else {
            mutex_exit(mutex)
            return nil
        }

        let totalUs = taskUs &+ interruptUs &+ idleUs
        let report = CPUStats(
            timestamp: nowUs,
            core: CPUCore(core),
            taskUsageTime: taskUs, 
            interruptUsageTime: interruptUs, 
            idleUsageTime: idleUs, 
            totalTime: totalUs, 
            interruptEvents: interruptEvents
        )

        windowStartUs = nowUs
        lastEventUs = nowUs
        taskUs = 0
        interruptUs = 0
        idleUs = 0
        interruptEvents = 0

        mutex_exit(mutex)

        return report
    }

    @_transparent
    private mutating func accountElapsed(nowUs: UInt64) {
        let interruptSample = takeInterruptSample()

        if windowStartUs == 0 {
            windowStartUs = nowUs
            lastEventUs = nowUs
            interruptEvents &+= interruptSample.events
            interruptUs &+= interruptSample.timeUs
            return
        }

        let elapsedUs = nowUs &- lastEventUs
        lastEventUs = nowUs
        interruptEvents &+= interruptSample.events

        let sampledInterruptUs = min(interruptSample.timeUs, elapsedUs)
        interruptUs &+= sampledInterruptUs

        let unsampledElapsedUs = elapsedUs &- sampledInterruptUs

        if interruptDepth > 0 {
            interruptUs &+= unsampledElapsedUs
        } else if taskIsActive {
            taskUs &+= unsampledElapsedUs
        } else {
            idleUs &+= unsampledElapsedUs
        }
    }

    @_transparent
    private mutating func takeInterruptSample() -> (events: UInt64, timeUs: UInt64) {
        var events: UInt64 = 0
        var timeUs: UInt64 = 0
        cshims_cpu_metrics_take_interrupt_samples(UInt32(CPUCore(core).rawValue), &events, &timeUs)
        return (events, timeUs)
    }
}

@_spi(Internal) @_cdecl("_cpicosdk_record_runtime_scheduler_enter_interrupt")
public func recordRuntimeSchedulerEnterInterrupt(_ coreIndex: UInt, _ interrupt: UInt) {
    cshimsRuntimeScheduler.recordInterruptCPUUsage(.enterInterrupt(interrupt: interrupt), coreIndex: coreIndex)
}

@_spi(Internal) @_cdecl("_cpicosdk_record_runtime_scheduler_exit_interrupt")
public func recordRuntimeSchedulerExitInterrupt(_ coreIndex: UInt, _ interrupt: UInt) {
    cshimsRuntimeScheduler.recordInterruptCPUUsage(.exitInterrupt(interrupt: interrupt), coreIndex: coreIndex)
}

#endif
