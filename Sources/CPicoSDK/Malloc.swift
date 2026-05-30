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
import CShims

// MARK: - Memory type

/// The type of memory for an allocator. This is used to categorize allocators and
/// provide information about the type of memory being allocated.
public enum MemoryType: String, Sendable {
    case sram = "SRAM"
    case psram = "PSRAM"
}

// MARK: - Allocator manager

/// A memory allocator that can be registered with the CPicoSDK configuration system.
/// Each allocator is associated with a specific memory type and address space, and
/// provides implementations for malloc, calloc, realloc, and free, as well as a way
/// to retrieve memory usage statistics. 
/// 
/// Allocators must be registered during the configuration phase and must not have
/// overlapping address spaces with other allocators.
public struct Allocator: Configuration, @unchecked Sendable { // TODO: Check how to make this non-sendable
    public enum Error: Swift.Error, CustomStringConvertible {
        case overlappingAllocator

        public var description: String {
            switch self {
            case .overlappingAllocator: return "Allocator overlaps with an existing allocator's address space."
            }
        }
    }

    public static let id = "Allocator_CPicoSDK_\(Int.random(in: Int.min...Int.max))"
    static let addressSpaceMask: UInt32 = 0xFF00_0000

    let memoryType: MemoryType

    let addressSpace: UInt32
    let stackLimit: UInt
    let malloc: (Int) -> UnsafeMutableRawPointer?
    let alignedMalloc: (Int, Int) -> UnsafeMutableRawPointer?
    let calloc: (Int, Int) -> UnsafeMutableRawPointer?
    let realloc: (UnsafeMutableRawPointer?, Int) -> UnsafeMutableRawPointer?
    let free: (UnsafeMutableRawPointer?) -> Void
    let memStats: () -> MemoryStats

    public init(
        memoryType: MemoryType,
        addressSpace: UInt32,
        stackLimit: UInt,
        malloc: @escaping (Int) -> UnsafeMutableRawPointer?,
        alignedMalloc: @escaping (Int, Int) -> UnsafeMutableRawPointer?,
        calloc: @escaping (Int, Int) -> UnsafeMutableRawPointer?,
        realloc: @escaping (UnsafeMutableRawPointer?, Int) -> UnsafeMutableRawPointer?,
        free: @escaping (UnsafeMutableRawPointer?) -> Void,
        memStats: @escaping () -> MemoryStats
    ) {
        self.memoryType = memoryType
        self.addressSpace = addressSpace
        self.stackLimit = stackLimit
        self.malloc = malloc
        self.alignedMalloc = alignedMalloc
        self.calloc = calloc
        self.realloc = realloc
        self.free = free
        self.memStats = memStats
    }

    @inline(__always)
    func owns(address: UInt32) -> Bool {
        (address & Self.addressSpaceMask) == (addressSpace & Self.addressSpaceMask)
    }

    @section(".flashdata.malloc_cold")
    public func executeConfiguration(with configurator: inout Configurator) throws(Allocator.Error) {
        try AllocatorManager.shared.register(self)
    }
}

final class AllocatorManager: @unchecked Sendable {
    public static let shared = AllocatorManager()

    private static func makeInitialStorage() -> [MemoryType: [Allocator]] {
        var storage: [MemoryType: [Allocator]] = [:]
        storage.reserveCapacity(2)

        var sramAllocators: [Allocator] = []
        sramAllocators.reserveCapacity(1)
        sramAllocators.append(.sram)
        storage[.sram] = sramAllocators

        var psramAllocators: [Allocator] = []
        psramAllocators.reserveCapacity(1)
        storage[.psram] = psramAllocators

        return storage
    }

    private let storage: Mutex<[MemoryType: [Allocator]]> = .init(makeInitialStorage())

    var allocators: [Allocator] {
        var all: [Allocator] = []
        storage.withLock { storage in
            for allocators in storage.values {
                all.append(contentsOf: allocators)
            }
        }
        return all
    }

    @inline(__always)
    func allocator(for memoryType: MemoryType) -> Allocator? {
        allocators.first { $0.memoryType == memoryType }
    }

    @inline(__always)
    private func hasOverlappingAllocator(_ allocator: Allocator, in storage: [MemoryType: [Allocator]]) -> Bool {
        let newAddressSpace = allocator.addressSpace & Allocator.addressSpaceMask
        for allocators in storage.values {
            for existing in allocators {
                if (existing.addressSpace & Allocator.addressSpaceMask) == newAddressSpace {
                    return true
                }
            }
        }
        return false
    }

    func register(_ allocator: Allocator) throws(Allocator.Error) {
        var overlapDetected = false

        storage.withLock { storage in
            if hasOverlappingAllocator(allocator, in: storage) {
                overlapDetected = true
                return
            }

            var allocators = storage[allocator.memoryType] ?? []
            if allocators.isEmpty {
                allocators.reserveCapacity(1)
            }
            allocators.append(allocator)
            storage[allocator.memoryType] = allocators
        }

        if overlapDetected {
            throw Allocator.Error.overlappingAllocator
        }
    }

    @inline(__always)
    func allocator(for pointer: UnsafeMutableRawPointer?) -> Allocator {
        guard let pointer else { return .sram }

        let address = UInt32(truncatingIfNeeded: UInt(bitPattern: pointer))

        // Fast path: SRAM pointers always resolve to the built-in SRAM allocator.
        if (address & Allocator.addressSpaceMask) == (Allocator.sramAddressSpace & Allocator.addressSpaceMask) {
            return .sram
        }

        return storage.withLock { storage in
            for allocators in storage.values {
                for allocator in allocators {
                    if allocator.owns(address: address) {
                        return allocator
                    }
                }
            }
            return .sram
        }
    }

}

// MARK: - SRAM allocator

@_extern(c, "memalign")
func memalign(_ alignment: Int, _ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "__real_malloc")
func real_malloc(_ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "__real_calloc")
func real_calloc(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "__real_realloc")
func real_realloc(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer?

@_extern(c, "__real_free")
func real_free(_ ptr: UnsafeMutableRawPointer?)

extension Allocator {
    fileprivate static let sramAddressSpace: UInt32 = 0x2000_0000

    private static let sramStackLimit: UInt = withUnsafePointer(to: &stackLimitSymbol) { UInt(bitPattern: $0) }

    static let sram: Allocator = {
        Allocator(
            memoryType: .sram,
            addressSpace: sramAddressSpace,
            stackLimit: sramStackLimit,
            malloc: real_malloc,
            alignedMalloc: memalign,
            calloc: real_calloc,
            realloc: real_realloc,
            free: real_free,
            memStats: { MemoryStats.sram }
        )
    }()
}

// MARK: - Allocator integration with malloc

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

private enum AllocatorOperation: UInt32 {
    case malloc = 1
    case calloc = 2
    case realloc = 3
    case free = 4
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

@inline(never)
private func trapIRQAllocatorUse(operation: AllocatorOperation, exception: UInt32) -> Never {
    cshims_record_irq_allocator_use(operation.rawValue, exception)
    while true {
        cshims_irq_allocator_debug_break()
    }
}

@inline(__always)
private func mallocEnter(operation: AllocatorOperation, outer: Bool) -> MallocLockState {
    let exception = __get_current_exception()
    if _slowPath(exception != 0) {
        #if GuardIRQAllocations
        trapIRQAllocatorUse(operation: operation, exception: UInt32(exception))
        #else
        cshims_warn_irq_allocator_use(operation.rawValue, UInt32(exception))
        #endif
    }

    let core = get_core_num()
    let exceptionLevelPlusOne = UInt8(truncatingIfNeeded: Int(exception) &+ 1)
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
private func mallocPanic(memoryType: MemoryType) -> Never {
    fatalError("[CPicoSDK] \(memoryType.rawValue) Out of memory")
}

@inline(__always)
private func checkAlloc(_ mem: UnsafeMutableRawPointer?, _ size: Int, allocator: Allocator) {
    guard let mem else {
        mallocPanic(memoryType: allocator.memoryType)
    }

    if UInt(bitPattern: mem) &+ UInt(size) > allocator.stackLimit {
        mallocPanic(memoryType: allocator.memoryType)
    }
}

@inline(__always)
private func debugAllocFailure(_ fn: StaticString, _ size: Int, memoryType: MemoryType) {
    print("[CPicoSDK] \(fn) failed to allocate \(size) bytes in \(memoryType.rawValue) allocator.")
}

@_cdecl("__wrap_malloc")
func malloc(_ size: Int) -> UnsafeMutableRawPointer? {
    let allocator = Allocator.sram
    let state = mallocEnter(operation: .malloc, outer: false)
    let rc = allocator.malloc(size)
    mallocExit(state)
    if rc == nil { debugAllocFailure("malloc", size, memoryType: allocator.memoryType) }
    checkAlloc(rc, size, allocator: allocator)
    return rc
}

@_cdecl("__wrap_calloc")
func calloc(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer? {
    let (totalSize, overflow) = num.multipliedReportingOverflow(by: size)
    let allocator = Allocator.sram
    if overflow {
        mallocPanic(memoryType: allocator.memoryType)
    }
    let state = mallocEnter(operation: .calloc, outer: true)
    let rc = allocator.calloc(num, size)
    mallocExit(state)
    if rc == nil { debugAllocFailure("calloc", totalSize, memoryType: allocator.memoryType) }
    checkAlloc(rc, totalSize, allocator: allocator)
    return rc
}

@_cdecl("__wrap_realloc")
func realloc(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
    let state = mallocEnter(operation: .realloc, outer: true)
    let allocator = AllocatorManager.shared.allocator(for: ptr)
    let rc = allocator.realloc(ptr, size)
    mallocExit(state)
    if rc == nil { debugAllocFailure("realloc", size, memoryType: allocator.memoryType) }
    checkAlloc(rc, size, allocator: allocator)
    return rc
}

@_cdecl("__wrap_free")
func free(_ ptr: UnsafeMutableRawPointer?) {
    let state = mallocEnter(operation: .free, outer: false)
    let allocator = AllocatorManager.shared.allocator(for: ptr)
    allocator.free(ptr)
    mallocExit(state)
}

// MARK: - Memory stats

@_extern(c, "__StackLimit") 
private nonisolated(unsafe) var stackLimitSymbol: UInt8

@_extern(c, "_sbrk")
private func sbrk(_ incr: Int) -> UnsafeMutableRawPointer?

/// Memory usage statistics for the current state of the heap and stack. 
/// The `current` property provides a snapshot of the current memory stats,
/// including how much memory is currently used, how much is freed but not 
/// yet reused, and how much is untouched (never allocated).
public struct MemoryStats: Sendable {
    public static var stats: [MemoryType: MemoryStats] {
        AllocatorManager.shared.allocators.reduce(into: [MemoryType: MemoryStats]()) { partial, allocator in
            partial[allocator.memoryType] = allocator.memStats()
        }
    }

    public static var sram: MemoryStats {
        // Get the current end of the heap (sbrk(0))
        guard let currentHeapEnd = sbrk(0) else {
            assertionFailure("[CPicoSDK] Failed to get current heap end using sbrk(0).")
            return .init(type: .sram, untouched: 0, freed: 0, used: 0)
        }
        
        // Get the address of the Stack Limit
        // Use withUnsafePointer to treat the symbol as an address
        let limitAddress = withUnsafePointer(to: &stackLimitSymbol) { ptr in
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

    public static func print() {
        for stats in stats.values {
            stats.print()
        }
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

    public init(type: MemoryType, untouched: UInt32, freed: UInt32, used: UInt32) {
        self.type = type
        self.untouched = untouched
        self.freed = freed
        self.used = used
    }

    public func print() {
        Swift::print("[CPicoSDK] \(self.description)")
    }
}

// MARK: - Swift Pointer helpers

extension UnsafeMutablePointer {
    /// Allocates uninitialized memory for the specified number of instances of
    /// type `Pointee` in the specified memory space.
    ///
    /// The resulting pointer references a region of memory that is bound to
    /// `Pointee` and is `count * MemoryLayout<Pointee>.stride` bytes in size.
    ///
    /// The following example allocates enough new memory to store four `Int`
    /// instances and then initializes that memory with the elements of a range.
    ///
    ///     let intPointer = UnsafeMutablePointer<Int>.allocate(capacity: 4)
    ///     for i in 0..<4 {
    ///         (intPointer + i).initialize(to: i)
    ///     }
    ///     print(intPointer.pointee)
    ///     // Prints "0"
    ///
    /// When you allocate memory, always remember to deallocate once you're
    /// finished.
    ///
    ///     intPointer.deallocate()
    ///
    /// You must only use `deallocate()` to end the lifetime of memory
    /// created with `allocate()`; it is a programming error to use `free` or
    /// another deallocation API, and may result in undefined behavior.
    ///
    /// - Parameter count: The amount of memory to allocate, counted in instances
    ///   of `Pointee`.
    /// - Parameter memory: The memory type in which to allocate the memory.
    public static func allocate(capacity: Int, in memory: MemoryType) -> UnsafeMutablePointer<Pointee>? {
        let size = MemoryLayout<Pointee>.size * capacity
        guard let allocator = AllocatorManager.shared.allocator(for: memory) else { return nil }
        return allocator.malloc(size)?.assumingMemoryBound(to: Pointee.self)
    }

    /// Allocates uninitialized memory for the specified number of instances of
    /// type `Pointee` in the specified memory space, with an optional fallback.
    ///
    /// The resulting pointer references a region of memory that is bound to
    /// `Pointee` and is `count * MemoryLayout<Pointee>.stride` bytes in size.
    ///
    /// The following example allocates enough new memory to store four `Int`
    /// instances and then initializes that memory with the elements of a range.
    ///
    ///     let intPointer = UnsafeMutablePointer<Int>.allocate(capacity: 4)
    ///     for i in 0..<4 {
    ///         (intPointer + i).initialize(to: i)
    ///     }
    ///     print(intPointer.pointee)
    ///     // Prints "0"
    ///
    /// When you allocate memory, always remember to deallocate once you're
    /// finished.
    ///
    ///     intPointer.deallocate()
    ///
    /// You must only use `deallocate()` to end the lifetime of memory
    /// created with `allocate()`; it is a programming error to use `free` or
    /// another deallocation API, and may result in undefined behavior.
    ///
    /// - Parameter count: The amount of memory to allocate, counted in instances
    ///   of `Pointee`.
    /// - Parameter memory: The memory types in which try to allocate the memory. 
    ///   Use `.psramIfAvailable` to attempt PSRAM first and fall back to SRAM if
    ///   PSRAM allocation fails or is not configured.
    public static func allocate(capacity: Int, in memory: [MemoryType]) -> UnsafeMutablePointer<Pointee>? {
        for mem in memory {
            if let ptr = Self.allocate(capacity: capacity, in: mem) {
                return ptr
            }
        }
        return nil
    }
}

extension UnsafeMutableRawPointer {
    /// Allocates uninitialized memory with the specified size and alignment in the 
    /// specified memory space.
    ///
    /// You are in charge of managing the allocated memory. Be sure to deallocate
    /// any memory that you manually allocate.
    ///
    /// The allocated memory is not bound to any specific type and must be bound
    /// before performing any typed operations. If you are using the memory for
    /// a specific type, allocate memory using the
    /// `UnsafeMutablePointerBuffer.allocate(capacity:)` static method instead.
    ///
    /// - Parameters:
    ///   - byteCount: The number of bytes to allocate. `byteCount` must not be
    ///     negative.
    ///   - alignment: The alignment of the new region of allocated memory, in
    ///     bytes. `alignment` must be a whole power of 2.
    ///   - memory: The memory type in which to allocate the memory.
    /// - Returns: A buffer pointer to a newly allocated region of memory aligned 
    ///     to `alignment`.
    public static func allocate(byteCount: Int, alignment: Int, in memory: MemoryType) -> UnsafeMutableRawPointer? {
        guard let allocator = AllocatorManager.shared.allocator(for: memory) else { return nil }
        return allocator.alignedMalloc(alignment, byteCount)
    }

    /// Allocates uninitialized memory with the specified size and alignment in the 
    /// specified memory space, with an optional fallback.
    ///
    /// You are in charge of managing the allocated memory. Be sure to deallocate
    /// any memory that you manually allocate.
    ///
    /// The allocated memory is not bound to any specific type and must be bound
    /// before performing any typed operations. If you are using the memory for
    /// a specific type, allocate memory using the
    /// `UnsafeMutablePointerBuffer.allocate(capacity:)` static method instead.
    ///
    /// - Parameters:
    ///   - byteCount: The number of bytes to allocate. `byteCount` must not be
    ///     negative.
    ///   - alignment: The alignment of the new region of allocated memory, in
    ///     bytes. `alignment` must be a whole power of 2.
    ///   - memory: The memory types in which try to allocate the memory. 
    ///     Use `.psramIfAvailable` to attempt PSRAM first and fall back to SRAM if
    ///     PSRAM allocation fails or is not configured.
    /// - Returns: A buffer pointer to a newly allocated region of memory aligned 
    ///     to `alignment`.
    public static func allocate(byteCount: Int, alignment: Int, in memory: [MemoryType]) -> UnsafeMutableRawPointer? {
        for mem in memory {
            if let ptr = Self.allocate(byteCount: byteCount, alignment: alignment, in: mem) {
                return ptr
            }
        }
        return nil
    }
}

extension UnsafeMutableBufferPointer {
    /// Allocates uninitialized memory for the specified number of instances of
    /// type `Element` in the specified memory space.
    ///
    /// The resulting buffer references a region of memory that is bound to
    /// `Element` and is `count * MemoryLayout<Element>.stride` bytes in size.
    ///
    /// The following example allocates a buffer that can store four `Int`
    /// instances and then initializes that memory with the elements of a range:
    ///
    ///     let buffer = UnsafeMutableBufferPointer<Int>.allocate(capacity: 4)
    ///     _ = buffer.initialize(from: 1...4)
    ///     print(buffer[2])
    ///     // Prints "3"
    ///
    /// When you allocate memory, always remember to deallocate once you're
    /// finished.
    ///
    ///     buffer.deallocate()
    ///
    /// - Parameter count: The amount of memory to allocate, counted in instances
    ///   of `Element`.
    /// - Parameter memory: The memory type in which to allocate the memory.
    public static func allocate(capacity: Int, in memory: MemoryType) -> UnsafeMutableBufferPointer<Element>? {
        let size = MemoryLayout<Element>.size * capacity
        guard let allocator = AllocatorManager.shared.allocator(for: memory) else { return nil }
        guard let ptr = allocator.malloc(size)?.assumingMemoryBound(to: Element.self) else { return nil }
        return UnsafeMutableBufferPointer(start: ptr, count: capacity)
    }

    /// Allocates uninitialized memory for the specified number of instances of
    /// type `Element` in the specified memory space, with an optional fallback.
    ///
    /// The resulting buffer references a region of memory that is bound to
    /// `Element` and is `count * MemoryLayout<Element>.stride` bytes in size.
    ///
    /// The following example allocates a buffer that can store four `Int`
    /// instances and then initializes that memory with the elements of a range:
    ///
    ///     let buffer = UnsafeMutableBufferPointer<Int>.allocate(capacity: 4)
    ///     _ = buffer.initialize(from: 1...4)
    ///     print(buffer[2])
    ///     // Prints "3"
    ///
    /// When you allocate memory, always remember to deallocate once you're
    /// finished.
    ///
    ///     buffer.deallocate()
    ///
    /// - Parameter count: The amount of memory to allocate, counted in instances
    ///   of `Element`.
    /// - Parameter memory: The memory types in which try to allocate the memory. 
    ///   Use `.psramIfAvailable` to attempt PSRAM first and fall back to SRAM if
    ///   PSRAM allocation fails or is not configured.
    public static func allocate(capacity: Int, in memory: [MemoryType]) -> UnsafeMutableBufferPointer<Element>? {
        for mem in memory {
            if let ptr = Self.allocate(capacity: capacity, in: mem) {
                return ptr
            }
        }
        return nil
    }
}

extension UnsafeMutableRawBufferPointer {
    /// Allocates uninitialized memory with the specified size and alignment in the
    /// specified memory space.
    ///
    /// You are in charge of managing the allocated memory. Be sure to deallocate
    /// any memory that you manually allocate.
    ///
    /// The allocated memory is not bound to any specific type and must be bound
    /// before performing any typed operations. If you are using the memory for
    /// a specific type, allocate memory using the
    /// `UnsafeMutablePointerBuffer.allocate(capacity:)` static method instead.
    ///
    /// - Parameters:
    ///   - byteCount: The number of bytes to allocate. `byteCount` must not be
    ///     negative.
    ///   - alignment: The alignment of the new region of allocated memory, in
    ///     bytes. `alignment` must be a whole power of 2.
    ///   - memory: The memory types in which try to allocate the memory.
    /// - Returns: A buffer pointer to a newly allocated region of memory aligned 
    ///     to `alignment`.
    public static func allocate(byteCount: Int, alignment: Int, in memory: MemoryType) -> UnsafeMutableRawBufferPointer? {
        guard let allocator = AllocatorManager.shared.allocator(for: memory) else { return nil }
        guard let ptr = allocator.alignedMalloc(alignment, byteCount) else { return nil }
        return UnsafeMutableRawBufferPointer(start: ptr, count: byteCount)
    }

    /// Allocates uninitialized memory with the specified size and alignment in the
    /// specified memory space, with an optional fallback.
    ///
    /// You are in charge of managing the allocated memory. Be sure to deallocate
    /// any memory that you manually allocate.
    ///
    /// The allocated memory is not bound to any specific type and must be bound
    /// before performing any typed operations. If you are using the memory for
    /// a specific type, allocate memory using the
    /// `UnsafeMutablePointerBuffer.allocate(capacity:)` static method instead.
    ///
    /// - Parameters:
    ///   - byteCount: The number of bytes to allocate. `byteCount` must not be
    ///     negative.
    ///   - alignment: The alignment of the new region of allocated memory, in
    ///     bytes. `alignment` must be a whole power of 2.
    /// - Parameter memory: The memory types in which try to allocate the memory. 
    ///   Use `.psramIfAvailable` to attempt PSRAM first and fall back to SRAM if
    ///   PSRAM allocation fails or is not configured.
    /// - Returns: A buffer pointer to a newly allocated region of memory aligned 
    ///     to `alignment`.
    public static func allocate(byteCount: Int, alignment: Int, in memory: [MemoryType]) -> UnsafeMutableRawBufferPointer? {
        for mem in memory {
            if let ptr = Self.allocate(byteCount: byteCount, alignment: alignment, in: mem) {
                return ptr
            }
        }
        return nil
    }
}

extension [MemoryType] {
    public static var psramIfAvailable: Self { [.psram, .sram] }
}
