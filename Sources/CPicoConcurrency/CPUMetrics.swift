import ConcurrencyShims
import CPicoSDK

public enum CPUCore: UInt8 {
    case core0 = 0
    case core1 = 1
}

/// Report containing CPU usage metrics for a given time window. The `usageEvents` 
/// async stream provides periodic reports with the latest CPU usage data, which 
/// can be used for monitoring or debugging purposes.
/// 
/// WARNING: *THIS IS AN EXPERIMENTAL IMPLEMENTATION* Expect inaccurate readings,
/// missing features, and potential performance issues. Use with caution.
/// 
/// WARNING: To count CPU usage accurately the IRQ handlers are wrapped with 
/// a shim that accounts for their execution time in the CPU usage metrics.
/// Expect potential performance degradations and unexpected interactions with 
/// third-party libraries that also wrap IRQ handlers. If you experience issues,
/// you can disable CPU monitoring and the IRQ wrapping by undefining the `CPUMetrics`
/// flag in your build configuration.
public struct CPUStats {
    public static var enabled: Bool {
        #if CPUMetrics
            true
        #else
            false
        #endif
    }

    public static func usageEvents(for core: CPUCore) -> AsyncStream<Self>? {
        #if CPUMetrics
            // TODO: Support per-core metrics.
            cshimsRuntimeScheduler.cpuUsage.stream
        #else
            nil
        #endif
    }

    public let timestamp: UInt64
    public let core: CPUCore = .core0 // TODO: Support per-core metrics.
    public let taskUsageTime: UInt64
    public let interruptUsageTime: UInt64
    public let idleUsageTime: UInt64
    public let totalTime: UInt64
    public let interruptEvents: UInt64

    public let memoryStats: [MemoryType: MemoryStats] = MemoryStats.stats

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
    nonisolated(unsafe) private static var irqWrapNextReconcileUs: UInt64 = 0

    @_transparent
    static func irqNeedsWrapping(num irq: UInt32) -> Bool {
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
        let nowUs = time_us_64()
        if irqWrapNextReconcileUs != 0 && nowUs < irqWrapNextReconcileUs {
            return
        }
        irqWrapNextReconcileUs = nowUs &+ irqWrapReconcileIntervalUs

        // Non-critical fast pass to find IRQs that might need wrapping. We will check them again in 
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

    enum Event {
        case enterTask(name: String)
        case exitTask(name: String)
        case enterInterrupt(interrupt: UInt)
        case exitInterrupt(interrupt: UInt)
    }

    // MARK: - CPU Usage Metering

    private static let windowUs: UInt64 = 1_000_000

    private let streamPair = AsyncStream.makeStream(of: CPUStats.self, bufferingPolicy: .bufferingNewest(1))
    var stream: AsyncStream<CPUStats> { streamPair.stream }

    private var windowStartUs: UInt64 = 0
    private var lastEventUs: UInt64 = 0

    private var taskUs: UInt64 = 0
    private var interruptUs: UInt64 = 0
    private var idleUs: UInt64 = 0
    private var interruptEvents: UInt64 = 0

    private var taskIsActive = false
    private var interruptDepth: UInt = 0
    
    private let mutex: UnsafeMutablePointer<mutex_t> = .allocate(capacity: 1)

    init() {
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
            assertionFailure("[CPicoConcurrency] Ignoring event due to mutex contention.")
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
            assertionFailure("[CPicoConcurrency] Ignoring event due to mutex contention.")
            return
        }

        defer {
            mutex_exit(mutex)
        }

        let nowUs = time_us_64()
        accountElapsed(nowUs: nowUs)
    }

    @_transparent
    mutating func reportIfNeeded() {
        guard mutex_try_enter(mutex, nil) else {
            // This might cause some inaccuracies in the metrics, but it's better than blocking critical code paths like IRQ handlers.
            assertionFailure("[CPicoConcurrency] Ignoring event due to mutex contention.")
            return
        }

        defer {
            mutex_exit(mutex)
        }

        let nowUs = time_us_64()

        guard windowStartUs != 0 else {
            return
        }

        guard nowUs &- windowStartUs >= Self.windowUs else {
            return
        }

        let totalUs = taskUs &+ interruptUs &+ idleUs
        let report = CPUStats(
            timestamp: nowUs, 
            taskUsageTime: taskUs, 
            interruptUsageTime: interruptUs, 
            idleUsageTime: idleUs, 
            totalTime: totalUs, 
            interruptEvents: interruptEvents
        )

        streamPair.continuation.yield(report)

        windowStartUs = nowUs
        lastEventUs = nowUs
        taskUs = 0
        interruptUs = 0
        idleUs = 0
        interruptEvents = 0
    }

    @_transparent
    private mutating func accountElapsed(nowUs: UInt64) {
        if windowStartUs == 0 {
            windowStartUs = nowUs
            lastEventUs = nowUs
            return
        }

        let elapsedUs = nowUs &- lastEventUs
        lastEventUs = nowUs

        if interruptDepth > 0 {
            interruptUs &+= elapsedUs
        } else if taskIsActive {
            taskUs &+= elapsedUs
        } else {
            idleUs &+= elapsedUs
        }
    }
}

@_spi(Internal) @_cdecl("_cpicosdk_record_runtime_scheduler_enter_interrupt")
public func recordRuntimeSchedulerEnterInterrupt(_ interrupt: UInt) {
    cshimsRuntimeScheduler.recordExternalEvent(.enterInterrupt(interrupt: interrupt))
}

@_spi(Internal) @_cdecl("_cpicosdk_record_runtime_scheduler_exit_interrupt")
public func recordRuntimeSchedulerExitInterrupt(_ interrupt: UInt) {
    cshimsRuntimeScheduler.recordExternalEvent(.exitInterrupt(interrupt: interrupt))
}

@_spi(Internal) @_cdecl("_cpicosdk_sample_runtime_scheduler_cpu_usage")
public func sampleRuntimeSchedulerCPUUsage() {
    cshimsRuntimeScheduler.sampleCPUUsage()
}

#endif
