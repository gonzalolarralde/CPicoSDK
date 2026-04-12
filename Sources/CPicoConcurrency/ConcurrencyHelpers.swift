@_exported import _Concurrency
import ConcurrencyShims
private import CPicoSDK

public func picoSDKTightLoop() {
    tight_loop_contents()
    cshims_swift_task_poll_once()
}

public func irqTrampoline<T>(_ critical: () -> T, postIRQ: @escaping (T) -> Void) {
    let value = critical()
    let trampoline = cshimsRuntimeScheduler.registerIRQTrampoline(postIRQ: postIRQ)
    trampoline.signalFromIRQ(value)
}

public func irqTrampoline(postIRQ: @escaping () -> Void) {
    let trampoline = cshimsRuntimeScheduler.registerIRQTrampoline(postIRQ: postIRQ)
    trampoline.signalFromIRQ(())
}

// MARK: - Sleep helpers

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
    public static func sleep(us: UInt64) async throws(_Concurrency.CancellationError) where Success == Never, Failure == Never {
        var cancelled: Bool = false

        await withUnsafeContinuation { continuation in
            while !mutex_enter_timeout_us(continuations_mutex, 1000) {
                print("[CPicoConcurrency] Warning: failed to acquire continuations mutex, cancelling task to avoid blocking the system.")
                cancelled = true
                return
            }

            let id = add_alarm_in_us(us, sleep_alarm_callback, nil, true)
            continuations[id] = continuation

            mutex_exit(continuations_mutex)

            cancelled = unsafe withUnsafeCurrentTask { task in
                unsafe task?.isCancelled ?? false
            }
        }

        if cancelled {
            throw _Concurrency.CancellationError()
        }
    }

    public static func sleep(ms: UInt32) async throws(_Concurrency.CancellationError) where Success == Never, Failure == Never {
        var cancelled: Bool = false

        await withUnsafeContinuation { continuation in
            while !mutex_enter_timeout_us(continuations_mutex, 1000) {
                print("[CPicoConcurrency] Warning: failed to acquire continuations mutex, cancelling task to avoid blocking the system.")
                cancelled = true
                return
            }

            let id = add_alarm_in_ms(ms, sleep_alarm_callback, nil, true)
            continuations[id] = continuation

            mutex_exit(continuations_mutex)

            cancelled = unsafe withUnsafeCurrentTask { task in
                unsafe task?.isCancelled ?? false
            }
        }

        if cancelled {
            throw _Concurrency.CancellationError()
        }
    }
}
