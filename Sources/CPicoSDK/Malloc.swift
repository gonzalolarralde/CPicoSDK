#if Variant_RP2350A && Radio_None
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

@_extern(c, "__real_malloc")
func real_malloc(_ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "__real_calloc")
func real_calloc(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "__real_realloc")
func real_realloc(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "__real_free")
func real_free(_ ptr: UnsafeMutableRawPointer?)

import _Concurrency
public enum Allocator: Sendable {
    @TaskLocal
    public static var current: Allocator = .auto

    case sram
    case psram
    case auto

    var description: String {
        switch self {
        case .sram: return "SRAM"
        case .psram: return "PSRAM"
        case .auto: return "Automatic"
        }
    }
}

// #if PSRAM

// nonisolated(unsafe) let allocator = try! PSRAMAllocator(csPin: 47)

// @_cdecl("__wrap_malloc")
// func malloc(_ size: Int) -> UnsafeMutableRawPointer? {
//     return allocator.sfeMemMalloc(size)
// }

// @_cdecl("__wrap_calloc")
// func calloc(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer? {
//     return allocator.sfeMemCalloc(num, size)
// }

// @_cdecl("__wrap_realloc")
// func realloc(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
//     return allocator.sfeMemRealloc(ptr, size)
// }

// @_cdecl("__wrap_free")
// func free(_ ptr: UnsafeMutableRawPointer?) {
//     allocator.sfeMemFree(ptr)
// }

// #else

@_cdecl("__wrap_malloc")
func malloc(_ size: Int) -> UnsafeMutableRawPointer? {
    print("Using task-local \(size) allocator=\(Allocator.current.description)")
    return real_malloc(size)
}

@_cdecl("__wrap_calloc")
func calloc(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer? {
    return real_calloc(num, size)
}

@_cdecl("__wrap_realloc")
func realloc(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
    return real_realloc(ptr, size)
}

@_cdecl("__wrap_free")
func free(_ ptr: UnsafeMutableRawPointer?) {
    real_free(ptr)
}

// #endif
