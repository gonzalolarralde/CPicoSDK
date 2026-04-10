#if Concurrency

import _Concurrency

/// A minimal queue-backed serial executor implemented in Swift.
///
/// This is intentionally small and explicit:
/// - jobs are queued in a fixed-size ring buffer
/// - nothing is preemptive
/// - work only runs when `pollOnce()` or `drain()` is called
///
/// This is a draft execution model for embedded experimentation, not a
/// replacement for the full Swift concurrency runtime.
public final class PicoSerialExecutor: SerialExecutor, @unchecked Sendable {
    public static let shared = PicoSerialExecutor()
    public static let defaultQueueCapacity = 64

    private var queue: [UnownedJob?]
    private var head = 0
    private var tail = 0
    private var isDraining = false

    public init(queueCapacity: Int = defaultQueueCapacity) {
        precondition(queueCapacity > 1, "queueCapacity must be greater than 1")
        self.queue = Array(repeating: nil, count: queueCapacity)
    }

    public nonisolated func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    public func isSameExclusiveExecutionContext(other: PicoSerialExecutor) -> Bool {
        self === other
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        enqueue(UnownedJob(job))
    }

    public func enqueue(_ job: UnownedJob) {
        let nextTail = (tail + 1) % queue.count
        precondition(nextTail != head, "PicoSerialExecutor queue overflow")
        queue[tail] = job
        tail = nextTail
    }

    public var hasPendingJobs: Bool {
        head != tail
    }

    @discardableResult
    public func pollOnce() -> Bool {
        guard head != tail, let job = queue[head] else {
            return false
        }

        queue[head] = nil
        head = (head + 1) % queue.count
        job.runSynchronously(on: asUnownedSerialExecutor())
        return true
    }

    public func drain() {
        guard !isDraining else {
            return
        }

        isDraining = true
        defer { isDraining = false }

        while pollOnce() {}
    }
}

/// Global actor bound to `PicoSerialExecutor.shared`.
///
/// Async work explicitly isolated to `@PicoActor` will enqueue onto
/// `PicoSerialExecutor.shared` and then run when the executor is pumped.
@globalActor
public actor PicoActor {
    public static let shared = PicoActor()

    public nonisolated let executor = PicoSerialExecutor.shared

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
}

/// Convenience APIs for driving the Swift-native executor from application code.
public enum PicoConcurrency {
    public static let executor = PicoSerialExecutor.shared

    @discardableResult
    public static func pollOnce() -> Bool {
        executor.pollOnce()
    }

    public static func drain() {
        executor.drain()
    }

    /// Schedule async work onto `@PicoActor`.
    ///
    /// The created task will not make progress until the executor is pumped via
    /// `pollOnce()` or `drain()`.
    public static func spawn(
        _ operation: @escaping @Sendable @PicoActor () async -> Void
    ) {
        Task { @PicoActor in
            await operation()
        }
    }
}

#endif
