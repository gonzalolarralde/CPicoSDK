/// Preallocated closure work that can be signaled without allocating.
///
/// This is separate from `JobEnvelope` because it is not a Swift runtime job.
/// `ISRTrampoline` uses a preallocated item to escape ISR context without
/// allocating; once the item executes on a scheduler core it may create a Swift
/// `Task`, letting normal runtime job placement handle the async work.
final class DeferredWorkItem {
    private var block: (() -> Void)?
    private var finalizer: (() -> Void)?
    fileprivate var next: UnsafeMutableRawPointer?
    fileprivate var enqueued = false
    private var didFinish = false

    init(block: (() -> Void)? = nil, finalizer: (() -> Void)? = nil) {
        self.block = block
        self.finalizer = finalizer
        self.next = nil
    }

    /// Installs the closure to run and an optional finalizer for ownership
    /// cleanup after execution or cancellation.
    func configure(block: @escaping () -> Void, finalizer: (() -> Void)? = nil) {
        self.block = block
        self.finalizer = finalizer
    }

    /// Runs the stored closure and finishes the work item.
    ///
    /// The closure runs outside ISR context after a core executor drains its
    /// deferred queue.
    func execute() {
        block?()
        finish()
    }

    /// Finishes the work item without running the closure.
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
        next = nil

        let finalizer = self.finalizer
        self.finalizer = nil
        finalizer?()
    }
}

/// Allocation-free FIFO for preallocated deferred work items.
///
/// The queue stores raw unretained links between work items. Ownership is held
/// by the creator: `ISRTrampoline` owns its item, and one-shot scheduling retains
/// its item until the finalizer releases it.
struct DeferredWorkQueue {
    private var head: UnsafeMutableRawPointer?
    private var tail: UnsafeMutableRawPointer?

    mutating func push(_ item: DeferredWorkItem) -> Bool {
        withCritical {
            guard !item.enqueued else {
                return false
            }

            let rawItem = Unmanaged.passUnretained(item).toOpaque()
            item.next = nil
            item.enqueued = true

            if let tail {
                let tailItem = Unmanaged<DeferredWorkItem>.fromOpaque(tail).takeUnretainedValue()
                tailItem.next = rawItem
            } else {
                head = rawItem
            }
            tail = rawItem
            return true
        }
    }

    mutating func pop() -> DeferredWorkItem? {
        withCritical {
            guard let current = head else {
                return nil
            }

            let item = Unmanaged<DeferredWorkItem>.fromOpaque(current).takeUnretainedValue()
            head = item.next
            if head == nil {
                tail = nil
            }
            item.next = nil
            item.enqueued = false
            return item
        }
    }
}
