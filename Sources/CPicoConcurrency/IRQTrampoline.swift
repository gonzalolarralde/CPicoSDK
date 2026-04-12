import ConcurrencyShims
private import CPicoSDK

// Maximum number of IRQ signals that can be queued before the async_context
// worker drains them. IRQ signals that overflow are dropped with a fatalError
// in debug; production builds should size this to the maximum burst rate.
private let cshimsIRQRingCapacity = 16

// Opaque base class so the worker C-callback can hold a typed reference
// without needing a generic parameter in the function pointer.
class IRQTrampolineBase {
    // Called from async_context worker (non-IRQ). Must drain the ring and
    // forward each pending value to the Swift async executor.
    func drainRing() { fatalError("abstract") }
    fileprivate var pendingWorker: async_when_pending_worker_t

    init() {
        pendingWorker = async_when_pending_worker_t(
            next: nil,
            do_work: cshims_irq_trampoline_pending_worker,
            work_pending: false,
            user_data: nil
        )
    }
}

// Typed trampoline handle. Holds a small fixed-size ring of T values that
// are written from IRQ context and drained from async_context worker context.
final class IRQTrampolineHandle<T> {
    // Backing storage exposed to RuntimeScheduler for worker registration.
    fileprivate let base: IRQTrampolineBoxed<T>

    init(base: IRQTrampolineBoxed<T>) {
        self.base = base
    }

    // IRQ-safe. Stores value and marks the async_context worker as pending.
    // Must be called from IRQ context (or with interrupts disabled).
    func signalFromIRQ(_ value: T) {
        base.push(value)
    }
}

// Internal box that holds the ring buffer and the postIRQ callback.
// Stored by pointer in pending_worker.user_data so that the C worker
// callback can reach it without a Swift closure.
final class IRQTrampolineBoxed<T>: IRQTrampolineBase {
    private var ringHead: UInt32 = 0   // written from async_context worker only
    private var ringTail: UInt32 = 0   // written from IRQ only (wraps at capacity)
    private var ring: UnsafeMutablePointer<T>
    private var contextRaw: UnsafeMutableRawPointer?
    private let postIRQ: (T) -> Void

    init(postIRQ: @escaping (T) -> Void) {
        self.postIRQ = postIRQ
        self.contextRaw = nil
        ring = .allocate(capacity: cshimsIRQRingCapacity)
        super.init()
    }

    deinit {
        ring.deallocate()
    }

    // Called during trampoline registration (non-IRQ) to bind this box to the
    // scheduler async_context and register its pending worker.
    func attach(to contextRaw: UnsafeMutableRawPointer) -> Bool {
        self.contextRaw = contextRaw
        pendingWorker.user_data = Unmanaged.passUnretained(self).toOpaque()
        let context = contextRaw.assumingMemoryBound(to: async_context_t.self)
        return async_context_add_when_pending_worker(context, &pendingWorker)
    }

    // Called from IRQ. Stores value, sets pending.
    func push(_ value: T) {
        let state = cshims_enter_critical()
        let next = ringTail &+ 1
        let filled = next &- ringHead
        guard filled <= UInt32(cshimsIRQRingCapacity) else {
            cshims_exit_critical(state)
            return // drop; ring full
        }
        (ring + Int(ringTail % UInt32(cshimsIRQRingCapacity))).initialize(to: value)
        ringTail = next
        cshims_exit_critical(state)
        guard let contextRaw else { return }
        let context = contextRaw.assumingMemoryBound(to: async_context_t.self)
        async_context_set_work_pending(context, &pendingWorker)
    }

    // Called from async_context worker (non-IRQ). Drains all pending values
    // and forwards each to the postIRQ callback on the Swift async executor.
    override func drainRing() {
        while true {
            let state = cshims_enter_critical()
            guard ringHead != ringTail else {
                cshims_exit_critical(state)
                break
            }
            let value = (ring + Int(ringHead % UInt32(cshimsIRQRingCapacity))).move()
            ringHead = ringHead &+ 1
            cshims_exit_critical(state)
            postIRQ(value)
        }
    }
}

// C-compatible pending_worker callback. Fired by async_context poll.
// Must be registered before use (done in RuntimeScheduler.registerIRQTrampoline).
@_cdecl("cshims_irq_trampoline_pending_worker")
private func cshims_irq_trampoline_pending_worker(
    _ context: UnsafeMutablePointer<async_context_t>?,
    _ worker: UnsafeMutablePointer<async_when_pending_worker_t>?
) {
    _ = context
    guard let worker, let userData = worker.pointee.user_data else { return }
    let box = Unmanaged<IRQTrampolineBase>.fromOpaque(userData).takeUnretainedValue()
    box.drainRing()
}
