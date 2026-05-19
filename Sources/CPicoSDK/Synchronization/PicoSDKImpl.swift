#if Platform_RP2040 && Variant_RP2040 && Radio_None
    import _CPicoSDK_pico
#elseif Platform_RP2040 && Variant_RP2040 && Radio_CYW43439
    import _CPicoSDK_pico_w
#elseif Variant_RP2350A && Radio_None
    import _CPicoSDK_pico2
#elseif Variant_RP2350A && Radio_CYW43439
    import _CPicoSDK_pico2_w
#elseif Variant_RP2350B && Radio_None
    import _CPicoSDK_pimoroni_pico_plus2_rp2350
#elseif Variant_RP2350B && Radio_CYW43439
    import _CPicoSDK_pimoroni_pico_plus2_w_rp2350
#else
    import _CPicoSDK_pico2_w
#endif

@_staticExclusiveOnly
public struct _MutexHandle: ~Copyable {
    @usableFromInline
    let storage: UnsafeMutablePointer<mutex_t>

    @_alwaysEmitIntoClient
    @_transparent
    public init() {
        storage = UnsafeMutablePointer.allocate(capacity: 1)
        mutex_init(storage)
    }

    deinit {
        storage.deallocate()
    }
}

extension _MutexHandle {
    @_alwaysEmitIntoClient
    @_transparent
    internal borrowing func _lock() {
        mutex_enter_blocking(storage)
    }

    @_alwaysEmitIntoClient
    @_transparent
    internal borrowing func _tryLock() -> Bool {
        mutex_try_enter(storage, nil)
    }

    @_alwaysEmitIntoClient
    @_transparent
    internal borrowing func _unlock() {
        mutex_exit(storage)
    }
}
