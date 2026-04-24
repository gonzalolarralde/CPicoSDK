import ConcurrencyShims
import CPicoSDK

public enum CPUCore: UInt8 {
    case core0 = 0
    case core1 = 1
}

/// Report containing CPU usage metrics for a given time window. The `usageEvents` 
/// async stream provides periodic reports with the latest CPU usage data, which 
/// can be used for monitoring or debugging purposes.
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

    public let memoryStats: MemoryStats = .current

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
            memoryStats.print()
        }
    }
}

#if CPUMetrics

struct RuntimeCPUUsageMeter {
    // MARK: - IRQ Wrapping for Accurate CPU Usage Attribution
    private static let irqWrapReconcileIntervalUs: UInt64 = 1_000_000
    nonisolated(unsafe) private static var irqWrapNextReconcileUs: UInt64 = 0

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

        if irq_has_shared_handler(irq) {
            return false
        }

        let currentExclusive = irq_get_exclusive_handler(irq)
        if address(for: currentExclusive) == address(for: wrapper) {
            return false
        }

        guard let currentExclusive else {
            return false
        }

        cshims_set_irq_wrapper_original(irq, currentExclusive)
        irq_remove_handler(irq, currentExclusive)
        irq_set_exclusive_handler(irq, wrapper)

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
        let candidates = (0..<UInt32(exactly: NUM_IRQS)!).filter { irqIndex in
            guard let wrapper = cshims_get_irq_wrapper(irqIndex) else {
                return false
            }

            let currentExclusive = irq_get_exclusive_handler(irqIndex)
            if address(for: currentExclusive) == address(for: wrapper) {
                return false
            }

            guard currentExclusive != nil else {
                return false
            }

            return true
        }

        if candidates.isEmpty {
            return
        }

        var wrappedCount = 0

        withCritical {
            for irq in candidates {
                if wrapIRQ(num: irq) {
                    wrappedCount += 1
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

    @_transparent
    mutating func record(event: Event) {
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
        let nowUs = time_us_64()
        accountElapsed(nowUs: nowUs)
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

    @_transparent
    mutating func reportIfNeeded() {
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
}

@_spi(Internal)
public func recordRuntimeSchedulerEnterInterrupt(_ interrupt: UInt) {
    cshimsRuntimeScheduler.recordExternalEvent(.enterInterrupt(interrupt: interrupt))
}

@_spi(Internal)
public func recordRuntimeSchedulerExitInterrupt(_ interrupt: UInt) {
    cshimsRuntimeScheduler.recordExternalEvent(.exitInterrupt(interrupt: interrupt))
}

@_spi(Internal)
public func sampleRuntimeSchedulerCPUUsage() {
    cshimsRuntimeScheduler.sampleCPUUsage()
}

#endif
