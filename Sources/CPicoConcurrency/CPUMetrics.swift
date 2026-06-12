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
    public let taskCycles: UInt64?
    public let interruptCycles: UInt64?
    public let idleCycles: UInt64?
    public let totalCycles: UInt64?
    public let taskLoadStoreStallCount: UInt64?
    public let interruptLoadStoreStallCount: UInt64?
    public let idleLoadStoreStallCount: UInt64?
    public let loadStoreStallCount: UInt64?

    init(
        timestamp: UInt64,
        core: CPUCore,
        taskUsageTime: UInt64,
        interruptUsageTime: UInt64,
        idleUsageTime: UInt64,
        totalTime: UInt64,
        interruptEvents: UInt64,
        taskCycles: UInt64? = nil,
        interruptCycles: UInt64? = nil,
        idleCycles: UInt64? = nil,
        totalCycles: UInt64? = nil,
        taskLoadStoreStallCount: UInt64? = nil,
        interruptLoadStoreStallCount: UInt64? = nil,
        idleLoadStoreStallCount: UInt64? = nil,
        loadStoreStallCount: UInt64? = nil
    ) {
        self.timestamp = timestamp
        self.core = core
        self.taskUsageTime = taskUsageTime
        self.interruptUsageTime = interruptUsageTime
        self.idleUsageTime = idleUsageTime
        self.totalTime = totalTime
        self.interruptEvents = interruptEvents
        self.taskCycles = taskCycles
        self.interruptCycles = interruptCycles
        self.idleCycles = idleCycles
        self.totalCycles = totalCycles
        self.taskLoadStoreStallCount = taskLoadStoreStallCount
        self.interruptLoadStoreStallCount = interruptLoadStoreStallCount
        self.idleLoadStoreStallCount = idleLoadStoreStallCount
        self.loadStoreStallCount = loadStoreStallCount
    }

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

enum RuntimeCPUUsageMeter {
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

    static func reportIfNeeded(core: CPUCore) -> CPUStats? {
        var raw = cshims_cpu_metrics_report_t()
        guard cshims_cpu_metrics_take_report(UInt32(core.rawValue), &raw) else {
            return nil
        }

        let hasCycles = (raw.flags & UInt32(CSHIMS_CPU_METRICS_REPORT_HAS_CYCLES)) != 0
        let hasLoadStoreStalls = (raw.flags & UInt32(CSHIMS_CPU_METRICS_REPORT_HAS_LOAD_STORE_STALLS)) != 0
        return CPUStats(
            timestamp: raw.timestampUs,
            core: core,
            taskUsageTime: raw.taskUs,
            interruptUsageTime: raw.interruptUs,
            idleUsageTime: raw.idleUs,
            totalTime: raw.totalUs,
            interruptEvents: raw.interruptEvents,
            taskCycles: hasCycles ? raw.taskCycles : nil,
            interruptCycles: hasCycles ? raw.interruptCycles : nil,
            idleCycles: hasCycles ? raw.idleCycles : nil,
            totalCycles: hasCycles ? raw.totalCycles : nil,
            taskLoadStoreStallCount: hasLoadStoreStalls ? raw.taskLoadStoreStallCount : nil,
            interruptLoadStoreStallCount: hasLoadStoreStalls ? raw.interruptLoadStoreStallCount : nil,
            idleLoadStoreStallCount: hasLoadStoreStalls ? raw.idleLoadStoreStallCount : nil,
            loadStoreStallCount: hasLoadStoreStalls ? raw.loadStoreStallCount : nil
        )
    }
}

@_spi(Internal) @_cdecl("_cpicosdk_record_runtime_scheduler_enter_interrupt")
public func recordRuntimeSchedulerEnterInterrupt(_ coreIndex: UInt, _ interrupt: UInt) {
    _ = interrupt
    cshims_cpu_metrics_record_interrupt_enter(UInt32(coreIndex))
}

@_spi(Internal) @_cdecl("_cpicosdk_record_runtime_scheduler_exit_interrupt")
public func recordRuntimeSchedulerExitInterrupt(_ coreIndex: UInt, _ interrupt: UInt) {
    _ = interrupt
    cshims_cpu_metrics_record_interrupt_exit(UInt32(coreIndex))
}

#endif
