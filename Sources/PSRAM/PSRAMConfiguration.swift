import CPicoSDK

public struct PSRAMConfiguration: Configuration {
    public static let defaultCSPin: UInt32 = 47

    public static var id: String { "CPicoSDK-PSRAMConfiguration" }

    /// The pin used for the PSRAM chip select. This pin will be configured as `GPIO_FUNC_XIP_CS1` 
    // internally, so make sure to connect your PSRAM's CS pin to a compatible GPIO. It's usually
    // GPIO 47 on most Pico models, but check your board's pinout to be sure.
    let csPin: UInt32

    public init(csPin: UInt32 = defaultCSPin) {
        self.csPin = csPin
    }

    public func executeConfiguration(with configurator: inout Configurator) throws(AllocatorError) {
        let allocator = try PSRAMAllocator.shared(configuration: self)

        configurator.configure(Allocator(
            memoryType: .psram,
            addressSpace: UInt32(truncatingIfNeeded: UInt(bitPattern: allocator.psramBase)),
            stackLimit: UInt(bitPattern: allocator.psramBase) + UInt(allocator.psramSize),
            malloc: { size in allocator.malloc(size) },
            alignedMalloc: { alignment, size in allocator.memalign(alignment, size) },
            calloc: { num, size in allocator.calloc(num, size) },
            realloc: { ptr, size in allocator.realloc(ptr, size) },
            free: { ptr in allocator.free(ptr) },
            memStats: {
                let used = allocator.usedMemory
                return .init(type: .psram, untouched: 0, freed: UInt32(allocator.totalMemory - used), used: UInt32(used))
            }
        ))
    }
}
