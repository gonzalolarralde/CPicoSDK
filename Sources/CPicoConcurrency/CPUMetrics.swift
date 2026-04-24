import ConcurrencyShims
private import CPicoSDK

#if CPU_USAGE_ENABLED
struct RuntimeCPUUsageMeter {
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

        print("[CPicoConcurrency] IRQ wrap reconcile done: wrapped=\(wrappedCount)") // TODO: Make this a log entry
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

    private static let windowUs: UInt64 = 1_000_000

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

        reportIfNeeded(nowUs: nowUs)
    }

    @_transparent
    mutating func sample() {
        let nowUs = time_us_64()
        accountElapsed(nowUs: nowUs)
        reportIfNeeded(nowUs: nowUs)
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
    private mutating func reportIfNeeded(nowUs: UInt64) {
        guard windowStartUs != 0 else {
            return
        }

        guard nowUs &- windowStartUs >= Self.windowUs else {
            return
        }

        let totalUs = taskUs &+ interruptUs &+ idleUs
        let taskPct = percentageTimes100(numerator: taskUs, denominator: totalUs)
        let irqPct = percentageTimes100(numerator: interruptUs, denominator: totalUs)
        let idlePct = percentageTimes100(numerator: idleUs, denominator: totalUs)
        print(
            "[CPicoConcurrency] CPU usage: task=\(formatPercent(taskPct))% irq=\(formatPercent(irqPct))% idle=\(formatPercent(idlePct))% total_us=\(totalUs) irq_events=\(interruptEvents)"
        )

        windowStartUs = nowUs
        lastEventUs = nowUs
        taskUs = 0
        interruptUs = 0
        idleUs = 0
        interruptEvents = 0
    }

    @_transparent
    private func percentageTimes100(numerator: UInt64, denominator: UInt64) -> UInt64 {
        guard denominator != 0 else {
            return 0
        }
        return (numerator &* 10_000) / denominator
    }

    @_transparent
    private func formatPercent(_ valueTimes100: UInt64) -> String {
        let whole = valueTimes100 / 100
        let fraction = valueTimes100 % 100
        let fractionText = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        return "\(whole).\(fractionText)"
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