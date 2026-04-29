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

// MARK: - Memory type

public enum MemoryType: String {
    case sram = "SRAM"
    case psram = "PSRAM"
}

// MARK: - Real malloc symbols

@_extern(c, "__real_malloc")
func real_malloc(_ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "__real_calloc")
func real_calloc(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "__real_realloc")
func real_realloc(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "__real_free")
func real_free(_ ptr: UnsafeMutableRawPointer?)

// MARK: - Malloc overrides

struct Allocator {
    static let addressSpaceMask = 0xFF00_0000
    let addressSpace: UInt32,
    let malloc: (Int) -> UnsafeMutableRawPointer?
    let calloc: (Int, Int) -> UnsafeMutableRawPointer?
    let realloc: (UnsafeMutableRawPointer?, Int) -> UnsafeMutableRawPointer?
    let free: (UnsafeMutableRawPointer?) -> Void
}

final class AllocatorManager {
    enum Error: Swift.Error {
        case overlappingAllocator
    }

    static let shared = AllocatorManager()

    private let allocators: Mutex<[UInt32: Allocator]> = .init([])

    func register(allocator: Allocator) throws {
        allocators.withLock { allocators in
            for existingAllocator in self.allocators {
                guard allocator.addressSpace.value & Allocator.addressSpaceMask != existingAllocator.addressSpace.value & Allocator.addressSpaceMask else {
                    throw Error.overlappingAllocator
                }
            }

            allocators.append(allocator)
        }
    }

    func allocator(forAddress address: UInt32) -> Allocator? {
        return allocators.withLock { allocators in
            .first { $0.addressSpace & Allocator.addressSpaceMask == address & Allocator.addressSpaceMask }
        }
    }
}

private nonisolated(unsafe) let mallocMutex: UnsafeMutablePointer<mutex_t> = {
    let ptr = UnsafeMutablePointer<mutex_t>.allocate(capacity: 1)
    ptr.initialize(to: mutex_t())
    mutex_init(ptr)
    return ptr
}()
private nonisolated(unsafe) var mallocMutexExceptionLevelPlusOneCore0: UInt8 = 0
private nonisolated(unsafe) var mallocMutexExceptionLevelPlusOneCore1: UInt8 = 0

private struct MallocLockState {
    let doLock: Bool
    let outer: Bool
    let core: UInt32
}

@inline(__always)
private func getExceptionLevelPlusOne(forCore core: UInt32) -> UInt8 {
    core == 0 ? mallocMutexExceptionLevelPlusOneCore0 : mallocMutexExceptionLevelPlusOneCore1
}

@inline(__always)
private func setExceptionLevelPlusOne(forCore core: UInt32, _ value: UInt8) {
    if core == 0 {
        mallocMutexExceptionLevelPlusOneCore0 = value
    } else {
        mallocMutexExceptionLevelPlusOneCore1 = value
    }
}

@inline(__always)
private func mallocEnter(outer: Bool) -> MallocLockState {
    let exception = Int(__get_current_exception())
    let core = get_core_num()
    let exceptionLevelPlusOne = UInt8(truncatingIfNeeded: exception + 1)
    let existingLevel = getExceptionLevelPlusOne(forCore: core)

    // Match Pico SDK behavior: only re-lock inner calls when exception nesting changed.
    let doLock = outer || exceptionLevelPlusOne != existingLevel
    if doLock {
        mutex_enter_blocking(mallocMutex)
        if outer {
            setExceptionLevelPlusOne(forCore: core, exceptionLevelPlusOne)
        }
    }

    return .init(doLock: doLock, outer: outer, core: core)
}

@inline(__always)
private func mallocExit(_ state: MallocLockState) {
    if state.outer {
        setExceptionLevelPlusOne(forCore: state.core, 0)
    }
    if state.doLock {
        mutex_exit(mallocMutex)
    }
}

@inline(__always)
private func mallocPanic() -> Never {
    fatalError("[CPicoSDK] Out of memory")
}

@inline(__always)
private func checkAlloc(_ mem: UnsafeMutableRawPointer?, _ size: Int) {
    guard let mem else {
        mallocPanic()
    }
    let end = UInt(bitPattern: mem) &+ UInt(size)
    let limit = withUnsafePointer(to: &stackLimit) { UInt(bitPattern: $0) }
    if end > limit {
        mallocPanic()
    }
}

@inline(__always)
private func debugAllocFailure(_ fn: StaticString, _ size: Int) {
    Swift::print("[CPicoSDK] \(fn) failed to allocate \(size) bytes")
}

@_cdecl("__wrap_malloc")
func malloc(_ size: Int) -> UnsafeMutableRawPointer? {
    let state = mallocEnter(outer: false)
    let rc = real_malloc(size)
    mallocExit(state)
    if rc == nil { debugAllocFailure("malloc", size) }
    checkAlloc(rc, size)
    return rc
}

@_cdecl("__wrap_calloc")
func calloc(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer? {
    let (totalSize, overflow) = num.multipliedReportingOverflow(by: size)
    if overflow {
        mallocPanic()
    }
    let state = mallocEnter(outer: true)
    let rc = real_calloc(num, size)
    mallocExit(state)
    if rc == nil { debugAllocFailure("calloc", totalSize) }
    checkAlloc(rc, totalSize)
    return rc
}

@_cdecl("__wrap_realloc")
func realloc(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
    let state = mallocEnter(outer: true)
    let rc = real_realloc(ptr, size)
    mallocExit(state)
    if rc == nil { debugAllocFailure("realloc", size) }
    checkAlloc(rc, size)
    return rc
}

@_cdecl("__wrap_free")
func free(_ ptr: UnsafeMutableRawPointer?) {
    let state = mallocEnter(outer: false)
    real_free(ptr)
    mallocExit(state)
}

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
