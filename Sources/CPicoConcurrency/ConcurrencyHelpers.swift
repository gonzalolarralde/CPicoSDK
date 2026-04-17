@_exported import _Concurrency
import ConcurrencyShims
private import CPicoSDK

/// Function to be called in tight loops to allow the concurrency system to make progress. 
/// This is only needed if you're doing a busy wait in a non-async context, if you're in 
/// an async context you can just use `await Task.yield()` instead.
/// 
/// Use this instead of `tight_loop_contents()` in your code to ensure that the concurrency 
/// system can make progress and schedule other tasks while you're busy-waiting.
/// 
/// Note: USB polling (tud_task) happens automatically in the global executor loops.
public func picoSDKTightLoop() {
    tight_loop_contents()
    cshims_swift_task_poll_once()
}

// MARK: - IRQ trampoline helpers

/// Helper to run minimal IRQ work now and schedule follow-up Swift work on the
/// shared async context.
///
/// This helper intentionally allows allocations while scheduling the post-IRQ
/// block so the call site stays simple. If a zero-allocation IRQ path is needed
/// later, the implementation can be swapped behind this API.
/// 
/// Example usage:
/// ```swift
/// @c func someIRQHandler() {
///     irqTrampoline {
///         // This runs in IRQ context. Do minimal work here, just prepare any data you need to pass to postIRQ and return it.
///         return readSensorDataFromIRQ()
///     } postIRQ: { sensorData in
///         // This runs in async_context worker context, NOT in IRQ. You can
///         // safely interact with Swift concurrency primitives here.
///         sensorDataStream.send(sensorData)
///     }
/// }
/// ```
public func irqTrampoline<T>(_ critical: () -> T, postIRQ: @escaping (T) -> Void) {
    let value = critical()
    cshimsRuntimeScheduler.schedule {
        postIRQ(value)
    }
}

/// Schedules a one-shot follow-up block from IRQ context onto the shared async
/// context.
/// 
/// Example usage:
/// ```swift
/// @c func someIRQHandler() {
///     irqTrampoline {
///         // This runs in async_context worker context, NOT in IRQ.
///         continuation.resume()
///     }
/// }
/// ```
public func irqTrampoline(postIRQ: @escaping () -> Void) {
    cshimsRuntimeScheduler.schedule(postIRQ)
}


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

// MARK: - Sleep helpers

/// Time threshold under which we use the busy-waiting `sleep_us` instead of scheduling a task, 
/// to avoid the overhead of scheduling for very short sleeps. This value is subject to tuning
/// based on benchmarks and may be exposed as a configuration option in the future.
let timerBlockPathCutoff: UInt32 = 500 // microseconds

// TODO: Maybe replace with a global actor isolated storage instead of using Mutex.
private nonisolated(unsafe) var continuations: [alarm_id_t: UnsafeContinuation<Void, Never>] = [:]
private nonisolated(unsafe) let continuations_mutex = {
    let mutex = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    mutex_init(mutex)
    return mutex
}()

@c
private func sleep_alarm_callback(_ id: alarm_id_t, _ userData: UnsafeMutableRawPointer?) -> Int64 {
    irqTrampoline { [id] in
        // This runs in async_context worker context, NOT in IRQ.
        mutex_enter_blocking(continuations_mutex)
        let cont = continuations[id]
        continuations.removeValue(forKey: id)
        mutex_exit(continuations_mutex)
        cont?.resume()
    }

    return 0 // 0 = do not reschedule
}

extension Task {
    /// Async sleep implementation that uses the PicoSDK timers to avoid blocking worker threads.
    /// This allows other tasks to run while waiting, and is more power efficient than busy-waiting.
    public static func sleep(us: UInt64) async throws(_Concurrency.CancellationError) where Success == Never, Failure == Never {
        var cancelled: Bool = false

        guard us >= timerBlockPathCutoff else {
            // For very short sleeps, just busy-wait to avoid the overhead of scheduling a task.
            sleep_us(us)
            return
        }

        await withUnsafeContinuation { continuation in
            while !mutex_enter_timeout_us(continuations_mutex, timerBlockPathCutoff) {
                print("[CPicoConcurrency] Warning: failed to acquire continuations mutex, cancelling task to avoid blocking the system.")
                cancelled = true
                return
            }

            let id = add_alarm_in_us(us, sleep_alarm_callback, nil, true)
            guard id > 0 else {
                mutex_exit(continuations_mutex)
                print("[CPicoConcurrency] Warning: failed to create alarm, cancelling task to avoid blocking the system.")
                cancelled = true
                return
            }

            continuations[id] = continuation

            mutex_exit(continuations_mutex)

            // TODO: Implement alarm cancellation on Task.cancel()
            cancelled = unsafe withUnsafeCurrentTask { task in
                unsafe task?.isCancelled ?? false
            }
        }

        if cancelled {
            throw _Concurrency.CancellationError()
        }
    }

    /// Async sleep implementation that uses the PicoSDK timers to avoid blocking worker threads.
    /// This allows other tasks to run while waiting, and is more power efficient than busy-waiting.
    public static func sleep(ms: UInt32) async throws(_Concurrency.CancellationError) where Success == Never, Failure == Never {
        var cancelled: Bool = false

        await withUnsafeContinuation { continuation in
            while !mutex_enter_timeout_us(continuations_mutex, timerBlockPathCutoff) {
                print("[CPicoConcurrency] Warning: failed to acquire continuations mutex, cancelling task to avoid blocking the system.")
                cancelled = true
                return
            }

            let id = add_alarm_in_ms(ms, sleep_alarm_callback, nil, true)
            guard id > 0 else {
                mutex_exit(continuations_mutex)
                print("[CPicoConcurrency] Warning: failed to create alarm, cancelling task to avoid blocking the system.")
                cancelled = true
                return
            }

            continuations[id] = continuation

            mutex_exit(continuations_mutex)

            // TODO: Implement alarm cancellation on Task.cancel()
            cancelled = unsafe withUnsafeCurrentTask { task in
                unsafe task?.isCancelled ?? false
            }
        }

        if cancelled {
            throw _Concurrency.CancellationError()
        }
    }
}
