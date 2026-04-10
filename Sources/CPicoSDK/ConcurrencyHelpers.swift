#if Concurrency

@_exported import _Concurrency
import ConcurrencyShims

#if Variant_RP2350A && Radio_None
    @_exported import _CPicoSDK_pico2
#elseif Variant_RP2350A && Radio_CYW43439
    @_exported import _CPicoSDK_pico2_w
#elseif Variant_RP2350B && Radio_None
    @_exported import _CPicoSDK_pimoroni_pico_plus2_rp2350
#elseif Variant_RP2350B && Radio_CYW43439
    @_exported import _CPicoSDK_pimoroni_pico_plus2_w_rp2350
#else
    // TODO: This is very constrained, until we can add proper board capability support this will help us keep moving.
    #error("Invalid Variant + Radio combination.")
#endif

public func picoSDKTightLoop() {
    tight_loop_contents()
    cshims_swift_task_poll_once()
}

nonisolated(unsafe) var continuations: [alarm_id_t: (UnsafeContinuation<Void, Never>)] = [:]

@c
func sleep_alarm_callback(_ id: alarm_id_t, _ userData: UnsafeMutableRawPointer?) -> Int64 {
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

#endif