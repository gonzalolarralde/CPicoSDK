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

#if PSRAM

private nonisolated(unsafe) var _allocator_storage: PSRAMAllocator?
private nonisolated(unsafe) var _strategy_storage: PSRAMConfiguration.MallocStrategy?

private var allocator: PSRAMAllocator? {
    if let allocator = _allocator_storage {
        return allocator
    } else {
        if let allocatorInstance = try? PSRAMAllocator.shared(initialize: true) {
            _allocator_storage = allocatorInstance
            return allocatorInstance
        } else {
            return nil
        }
    }
}

private var strategy: PSRAMConfiguration.MallocStrategy {
    if let strategy = _strategy_storage {
        return strategy
    } else {
        if let config = Configurator.configuration(for: PSRAMConfiguration.self) {
            _strategy_storage = config.mallocStrategy
            return config.mallocStrategy
        } else {
            return .default
        }
    }
}

@_cdecl("__wrap_malloc")
func malloc(_ size: Int) -> UnsafeMutableRawPointer? {
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
    allocator.real_free(ptr)
}

#else

@_cdecl("__wrap_malloc")
func malloc(_ size: Int) -> UnsafeMutableRawPointer? {
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

#endif

// MARK: - Memory stats

@_extern(c, "__StackLimit") 
private nonisolated(unsafe) var stackLimit: UInt8

@_extern(c, "_sbrk")
private func sbrk(_ incr: Int) -> UnsafeMutableRawPointer?

/// Memory usage statistics for the current state of the heap and stack. 
/// The `current` property provides a snapshot of the current memory stats,
/// including how much memory is currently used, how much is freed but not 
/// yet reused, and how much is untouched (never allocated).
public struct MemoryStats {
    public enum MemoryType: String {
        case sram = "SRAM"
        case psram = "PSRAM"
    }

    public static var sram: MemoryStats {
        // Get the current end of the heap (sbrk(0))
        guard let currentHeapEnd = sbrk(0) else {
            assertionFailure("[CPicoSDK] Failed to get current heap end using sbrk(0).")
            return .init(type: .sram, untouched: 0, freed: 0, used: 0)
        }
        
        // Get the address of the Stack Limit
        // Use withUnsafePointer to treat the symbol as an address
        let limitAddress = withUnsafePointer(to: &stackLimit) { ptr in
            return UInt(bitPattern: ptr)
        }
        
        let currentHeapAddr = UInt(bitPattern: currentHeapEnd)
        
        // Calculate untouched RAM
        // Ensure we don't underflow if the heap has somehow passed the limit
        let untouchedRam: UInt32 = if limitAddress > currentHeapAddr {
            UInt32(limitAddress - currentHeapAddr)
        } else {
            0
        }
        
        // Get internal free blocks via mallinfo
        let mi = mallinfo()

        return .init(type: .sram, untouched: untouchedRam, freed: UInt32(mi.fordblks), used: UInt32(mi.uordblks))
    }

    public static var psram: MemoryStats? {
        #if PSRAM
            if let allocator = try? PSRAMAllocator.shared(initialize: false) {
                let used = allocator.usedMemory
                return .init(type: .psram, untouched: 0, freed: UInt32(allocator.totalMemory - used), used: UInt32(used))
            } else {
                return nil
            }
        #else
            return nil
        #endif
    }

    public let type: MemoryType
    public let untouched: UInt32
    public let freed: UInt32
    public let used: UInt32

    public var totalFree: UInt32 {
        return untouched + freed
    }

    public var total: UInt32 {
        return used + totalFree
    }

    public var description: String {
        "\(type.rawValue) Memory: used=\(used) bytes; freed=\(freed) bytes; untouched=\(untouched) bytes; total_free=\(totalFree) bytes; total=\(total) bytes"
    }

    public func print() {
        Swift::print("[CPicoSDK] \(self.description)")
    }
}
