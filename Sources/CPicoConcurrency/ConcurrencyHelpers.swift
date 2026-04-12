@_exported import _Concurrency
import ConcurrencyShims
private import CPicoSDK

public func picoSDKTightLoop() {
    tight_loop_contents()
    cshims_swift_task_poll_once()
}

private nonisolated(unsafe) var continuations: [alarm_id_t: (UnsafeContinuation<Void, Never>)] = [:]

@c
private func sleep_alarm_callback(_ id: alarm_id_t, _ userData: UnsafeMutableRawPointer?) -> Int64 {
    if let cont = continuations[id] {
        continuations.removeValue(forKey: id)
        cont.resume()
    }
    return 0 // 0 = do not reschedule
}

extension Task {
    public static func sleep(us: UInt64) async throws(_Concurrency.CancellationError) where Success == Never, Failure == Never {
        var cancelled: Bool = false

        await withUnsafeContinuation { continuation in
            let id = add_alarm_in_us(us, sleep_alarm_callback, nil, true)
            continuations[id] = continuation

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
            let id = add_alarm_in_ms(ms, sleep_alarm_callback, nil, true)
            continuations[id] = continuation

            cancelled = unsafe withUnsafeCurrentTask { task in
                unsafe task?.isCancelled ?? false
            }
        }

        if cancelled {
            throw _Concurrency.CancellationError()
        }
    }
}
