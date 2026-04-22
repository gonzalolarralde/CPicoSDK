import _Concurrency
import ConcurrencyShims
private import CPicoSDK

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
        var registrationFailed = false

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
                    registrationFailed = true
                    continuation.resume()
                    return
                }

                registeredContinuation.alarmId.put(id)
            }
        } onCancel: {
            registeredContinuation.handler.take()?.resume()
        }

        if Task.isCancelled || registrationFailed {
            await PicoTimeoutManager.shared.cancel(continuationId: registeredContinuation.id)
            throw _Concurrency.CancellationError()
        }
    }

    /// Async sleep implementation that uses the PicoSDK timers to avoid blocking worker threads.
    /// This allows other tasks to run while waiting, and is more power efficient than busy-waiting.
    public static func sleep(ms: UInt32) async throws(CancellationError) where Success == Never, Failure == Never {
        var registrationFailed = false

        let (registeredContinuation, trampolinePointer) = await PicoTimeoutManager.shared.createNewContinuation() { continuationId in
            await PicoTimeoutManager.shared.triggeredAlarm(for: continuationId)?.resume()
        }
    
        await withTaskCancellationHandler {
            await withUnsafeContinuation { continuation in
                registeredContinuation.handler.put(continuation)

                let id = add_alarm_in_ms(ms, sleep_alarm_callback, trampolinePointer, true)
                guard id > 0 else {
                    registrationFailed = true
                    continuation.resume()
                    return
                }

                registeredContinuation.alarmId.put(id)
            }
        } onCancel: {
            registeredContinuation.handler.take()?.resume()
        }

        if Task.isCancelled || registrationFailed {
            await PicoTimeoutManager.shared.cancel(continuationId: registeredContinuation.id)
            throw _Concurrency.CancellationError()
        }
    }
}
