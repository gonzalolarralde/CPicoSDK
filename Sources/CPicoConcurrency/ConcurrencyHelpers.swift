@_exported import _Concurrency
import ConcurrencyShims
@_spi(Internal) private import CPicoSDK

// MARK: - Cancellation and scheduling helpers

public typealias CancellationError = _Concurrency.CancellationError

extension Task where Success == Never, Failure == Never {
    /// Function to be called in tight loops to allow the concurrency system to make progress. 
    /// This is only needed if you're doing a busy wait in a non-async context, if you're in 
    /// an async context you can just use `await Task.yield()` instead.
    /// 
    /// Use this instead of `tight_loop_contents()` in your code to ensure that the concurrency 
    /// system can make progress and schedule other tasks while you're busy-waiting.
    /// 
    /// Note: USB polling (tud_task) happens automatically in the global executor loops.
    public static func tightLoop() {
        tight_loop_contents()
        cshims_swift_task_poll_once()
    }
}

/// Embedded async app protocol. Provides a default implementation of the `main` method that
/// ensures to setup basic PicoSDK features before calling the user-defined `setup` and `loop`
/// methods, and uses the `tightLoop` helper to allow concurrency progress in busy loops.
/// 
/// Using this protocol is optional, if a custom `main` start sequence is needed, it can be
/// implemented directly in their app.
public protocol EmbeddedAsyncApp {
    static func setup() async
    static func loop() async
}

public extension EmbeddedAsyncApp {
    static func main() async {
        // TODO: WatchDog
        setupPicoSDK()
        await setup()
        while true {
            await loop()
            Task.tightLoop()
        }
    }
}

// MARK: - ISR trampoline helpers

/// Helper class to allow scheduling work from an ISR onto the shared async context, with support
/// for passing data from the ISR to the async context without allocations. This is used internally
/// for the sleep implementation, but can also be used directly by users for other IRQ handling scenarios.
public actor ISRTrampoline<UserData: Sendable, CriticalData: Sendable> {
    /// Creates a new trampoline with the given user data and post-ISR handler, and returns the trampoline 
    /// along with an opaque pointer that can be passed to C code and later consumed to trigger the trampoline.
    /// 
    /// Example:
    /// ```swift
    /// @c func someHandlingFunction(pointer: UnsafeMutableRawPointer?) {
    ///     ISRTrampoline.consume(pointer) { userData in
    ///         // This runs in IRQ context. Do minimal work here, just prepare any data you need to pass to postISR and return it.
    ///         return prepareCriticalDataFromIRQ(userData)
    ///     }
    /// }
    /// 
    /// let (trampoline, pointer) = ISRTrampoline.create(value: someUserData) { criticalData in
    ///     // This runs in async_context worker context, NOT in IRQ. You can safely interact with Swift concurrency primitives here.
    ///     handleCriticalData(criticalData)
    /// }
    /// 
    /// setIRQHandler(someHandlingFunction, pointer)
    /// ```
    /// 
    /// The data flow is as follows:
    /// - The trampoline is created with some user data and a post-ISR handler. An opaque pointer to the trampoline is returned.
    /// - The pointer is passed to C code and stored there (e.g. as an IRQ handler argument).
    /// - When the C code calls the handler with the pointer, `ISRTrampoline.consume` is called to obtain the userData, handle the critical section in the ISR, and obtain an output named criticalData.
    /// - The post-ISR handler is scheduled on the async context with the criticalData, allowing safe interaction with Swift concurrency primitives.
    /// - The trampoline is automatically cleaned up when the post-ISR handler runs, but it can also be manually cancelled if needed to free resources earlier.
    /// 
    /// When the trampoline is created User Data comes in > When the ISR is triggered Critical Data is prepared > Post-ISR handler is executed with Critical Data
    /// 
    /// Note: The trampoline is designed to be signaled only once. If the trampoline is signaled multiple times, it will trigger an assertion failure and ignore subsequent signals after the first one.
    public static func create(value: sending UserData, postISR: @Sendable @escaping @isolated(any) (sending CriticalData) async -> Void) -> sending (ISRTrampoline, UnsafeMutableRawPointer) {
        let trampoline = ISRTrampoline(value: value, postISR: postISR)
        return (trampoline, Unmanaged.passRetained(trampoline).toOpaque())
    }

    /// Consumes the trampoline pointer, executes the critical section in the ISR, and signals the post-ISR handler with the resulting critical data.
    /// This function is designed to be called from C code with the opaque pointer obtained from `ISRTrampoline.create`. It will handle the necessary 
    /// conversions and scheduling to ensure that the post-ISR handler is executed on the async context with the critical data prepared in the ISR.
    /// 
    /// Example:
    /// ```swift
    /// @c func someHandlingFunction(pointer: UnsafeMutableRawPointer?) {
    ///     ISRTrampoline.consume(pointer) { userData in
    ///         // This runs in IRQ context. Do minimal work here, just prepare any data you need to pass to postISR and return it.
    ///         return prepareCriticalDataFromIRQ(userData)
    ///     }
    /// }
    /// ```
    public static func consume(_ pointer: UnsafeMutableRawPointer?, criticalSection: (sending UserData) -> sending CriticalData) {
        guard let pointer else {
            assertionFailure("[CPicoSDK] ISRTrampoline consume called with null pointer.")
            return
        }

        let trampoline = Unmanaged<ISRTrampoline<UserData, CriticalData>>.fromOpaque(pointer).takeUnretainedValue()

        trampoline.signal(criticalData: criticalSection(trampoline.value))
    }

    /// Preallocated work schedule to avoid allocations in the ISR path.
    nonisolated(unsafe) private let scheduledWork: ScheduledBlock
    private let value: UserData
    nonisolated(unsafe) private let criticalData: UnsafeMutablePointer<CriticalData> = .allocate(capacity: 1)
    private var postISR: (@isolated(any) (sending CriticalData) async -> Void)?

    private init(value: sending UserData, postISR: @Sendable @escaping @isolated(any) (sending CriticalData) async -> Void) {
        self.value = value
        self.postISR = postISR
        self.scheduledWork = ScheduledBlock()

        let rawSelf: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()
        scheduledWork.configure {
            Task {
                await self.run()
            }
        } finalizer: {
            Unmanaged<ISRTrampoline<UserData, CriticalData>>.fromOpaque(rawSelf).release()
        }

        cshimsRuntimeScheduler.register(scheduledWork)
    }

    nonisolated private func signal(criticalData: sending CriticalData) {
        self.criticalData.pointee = criticalData
        scheduledWork.signal()
    }

    private func run() async {
        guard let postISR = self.postISR.take() else {
            assertionFailure("[CPicoSDK] ISRTrampoline postISR handler is gone, the trampoline was signaled more than once.")
            return
        }

        await postISR(criticalData.pointee)
    }

    /// Cancels the trampoline, preventing the post-ISR handler from being called if the trampoline is still pending, and freeing resources. 
    /// If the trampoline has already been signaled, this has no effect.
    public func cancel() {
        scheduledWork.cancel()
    }

    deinit {
        criticalData.deallocate()
    }
}

/// Schedules a one-shot block onto the shared async context. It cannot be cancelled.
/// This is useful for scheduling work from an ISR or other non-async contexts without 
/// needing to manage continuations or trampolines, but it should be used with care as 
/// it does not provide any guarantees about when the block will be executed.
/// 
/// Prefer using `ISRTrampoline` if you need to pass data from the ISR context avoiding
/// allocations.
/// 
/// Example usage:
/// ```swift
/// @c func someIRQHandler() {
///     executeLater {
///         // This runs in async_context worker context.
///         continuation.resume()
///     }
/// }
/// ```
public func executeLater(_ block: @escaping () -> Void) {
    cshimsRuntimeScheduler.schedule(block)
}

// MARK: - Continuation helpers

/// Embedded friendly wrapper of `UnsafeContinuation` and `CheckedContinuation` that supports typed 
/// error handling.
public struct EmbeddedContinuation<T: Sendable, E: Error> {
    private let continuation: @Sendable (sending Result<T, E>) -> Void

    fileprivate init(_ continuation: UnsafeContinuation<Result<T, E>, Never>) {
        self.continuation = continuation.resume(returning:)
    }

    fileprivate init(_ continuation: CheckedContinuation<Result<T, E>, Never>) {
        self.continuation = continuation.resume(returning:)
    }    

    public func resume(returning value: T) {
        continuation(.success(value))
    }

    public func resume(throwing error: E) {
        continuation(.failure(error))
    }

    public func resume(with result: Result<T, E>) {
        continuation(result)
    }
}

/// Embedded version of `withUnsafeContinuation` supporting typed error handling.
/// TODO: Remove when support is fixed in the standard library.
public func withEmbeddedUnsafeThrowingContinuation<T: Sendable, E: Error>(_ fn: (EmbeddedContinuation<T, E>) -> Void) async throws(E) -> sending T {
    let result: Result<T, E> = await withUnsafeContinuation { continuation in 
        fn(EmbeddedContinuation(continuation))
    }

    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    }
}

/// Embedded version of `withCheckedContinuation` supporting typed error handling.
/// TODO: Remove when support is fixed in the standard library.
public func withEmbeddedCheckedThrowingContinuation<T: Sendable, E: Error>(_ fn: (EmbeddedContinuation<T, E>) -> Void) async throws(E) -> sending T {
    let result: Result<T, E> = await withCheckedContinuation { continuation in 
        fn(EmbeddedContinuation(continuation))
    }

    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    }
}

extension Task where Success == Never, Failure == Never {
    /// Checks for cancellation in embedded contexts. This is a temporary replacement
    /// for `Task.checkCancellation()` which is currently not supported in embedded contexts.
    public static func checkEmbeddedCancellation() throws(CancellationError) {
        if Self.isCancelled {
            throw _Concurrency.CancellationError()
        }
    }
}

// MARK: - Sleep helpers

actor PicoTimeoutManager {
    typealias ContinuationID = Int

    final class SyncExchangeBox<T>: @unchecked Sendable {
        private var value: T?
        private let mutex: UnsafeMutablePointer<mutex_t> = .allocate(capacity: 1)

        init() {
            mutex_init(mutex)
        }

        deinit {
            mutex.deinitialize(count: 1)
            mutex.deallocate()
        }

        func put(_ newValue: T) {
            mutex_enter_blocking(mutex)
            value = newValue
            mutex_exit(mutex)
        }

        func take() -> sending T? {
            mutex_enter_blocking(mutex)
            defer {
                mutex_exit(mutex)
            }

            return self.value.take()
        }
    }

    struct Continuation: Identifiable {
        let id: ContinuationID
        fileprivate var alarmId: SyncExchangeBox<alarm_id_t>
        let trampoline: ISRTrampoline<ContinuationID, ContinuationID>
        var handler: SyncExchangeBox<UnsafeContinuation<Void, Never>>
    }

    static let shared = PicoTimeoutManager()

    var nextContinuationId: ContinuationID = 1
    var continuations: [ContinuationID: Continuation] = [:]

    func nextId() -> ContinuationID {
        defer { nextContinuationId &+= 1 }
        return nextContinuationId
    }

    fileprivate func createNewContinuation(postISR: @Sendable @escaping @isolated(any) (sending ContinuationID) async -> Void) -> sending (Continuation, UnsafeMutableRawPointer) {
        let id = nextId()
        let (trampoline, trampolinePointer) = ISRTrampoline<ContinuationID, ContinuationID>.create(value: id, postISR: postISR)
        let continuation = Continuation(id: id, alarmId: .init(), trampoline: trampoline, handler: .init())
        continuations[id] = continuation
        return (continuation, trampolinePointer)
    }

    func triggeredAlarm(for continuationId: ContinuationID) -> UnsafeContinuation<Void, Never>? {
        guard let continuation = continuations.removeValue(forKey: continuationId) else {
            // Assuming the continuation was cancelled
            return nil
        }

        return continuation.handler.take()
    }

    func cancel(continuationId: ContinuationID) async {
        if let continuation = continuations.removeValue(forKey: continuationId) {
            // There might not be an alarm Id if the cancellation happened before the scheduling
            // or if the alarm failed to schedule in the first place, in which case there's nothing to cancel.
            if let alarmId = continuation.alarmId.take() {
                if cancel_alarm(alarmId) {
                    await continuation.trampoline.cancel()
                }
            } else {
                await continuation.trampoline.cancel()
            }
        }
    }
}

/// Time threshold under which we use the busy-waiting `sleep_us` instead of scheduling a task, 
/// to avoid the overhead of scheduling for very short sleeps. This value is subject to tuning
/// based on benchmarks and may be exposed as a configuration option in the future.
let timerBlockPathCutoff: UInt64 = 500 // microseconds

@c
private func sleep_alarm_callback(_: alarm_id_t, _ userData: UnsafeMutableRawPointer?) -> Int64 {
    ISRTrampoline<PicoTimeoutManager.ContinuationID, PicoTimeoutManager.ContinuationID>.consume(userData) {
        $0
    }

    return 0 // 0 = do not reschedule
}

extension Task {
    /// Async sleep implementation that uses the PicoSDK timers to avoid blocking worker threads.
    /// This allows other tasks to run while waiting, and is more power efficient than busy-waiting.
    public static func sleep(us: UInt64) async throws(CancellationError) where Success == Never, Failure == Never {
        var cancelled: Bool = false

        guard us >= timerBlockPathCutoff else {
            // For very short sleeps, just busy-wait to avoid the overhead of scheduling a task.
            sleep_us(us)
            return
        }

        let (registeredContinuation, trampolinePointer) = await PicoTimeoutManager.shared.createNewContinuation() { continuationId in
            await PicoTimeoutManager.shared.triggeredAlarm(for: continuationId)?.resume()
        }
    
        await withTaskCancellationHandler {
            await withUnsafeContinuation { continuation in
                registeredContinuation.handler.put(continuation)

                let id = add_alarm_in_us(us, sleep_alarm_callback, trampolinePointer, true)
                guard id > 0 else {
                    cancelled = true
                    continuation.resume()
                    return
                }

                registeredContinuation.alarmId.put(id)
            }
        } onCancel: {
            cancelled = true
            registeredContinuation.handler.take()?.resume()
        }

        if cancelled {
            await PicoTimeoutManager.shared.cancel(continuationId: registeredContinuation.id)
            throw _Concurrency.CancellationError()
        }
    }

    /// Async sleep implementation that uses the PicoSDK timers to avoid blocking worker threads.
    /// This allows other tasks to run while waiting, and is more power efficient than busy-waiting.
    public static func sleep(ms: UInt32) async throws(CancellationError) where Success == Never, Failure == Never {
        var cancelled: Bool = false

        let (registeredContinuation, trampolinePointer) = await PicoTimeoutManager.shared.createNewContinuation() { continuationId in
            await PicoTimeoutManager.shared.triggeredAlarm(for: continuationId)?.resume()
        }
    
        await withTaskCancellationHandler {
            await withUnsafeContinuation { continuation in
                registeredContinuation.handler.put(continuation)

                let id = add_alarm_in_ms(ms, sleep_alarm_callback, trampolinePointer, true)
                guard id > 0 else {
                    cancelled = true
                    continuation.resume()
                    return
                }

                registeredContinuation.alarmId.put(id)
            }
        } onCancel: {
            cancelled = true
            registeredContinuation.handler.take()?.resume()
        }

        if cancelled {
            await PicoTimeoutManager.shared.cancel(continuationId: registeredContinuation.id)
            throw _Concurrency.CancellationError()
        }
    }
}
