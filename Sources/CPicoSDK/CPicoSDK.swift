@_exported import ARMClib
@_exported import Atomics

#if (Platform_RP2350 && (Platform_RP2350_arm_s || Platform_RP2350_riscv || Platform_Host))
    #error("Only one Platform can be selected at a time.")
#elseif (Platform_RP2350_arm_s && (Platform_RP2350_riscv || Platform_Host))
    #error("Only one Platform can be selected at a time.")
#elseif (Platform_RP2350_riscv && Platform_Host)
    #error("Only one Platform can be selected at a time.")
#elseif !Platform_RP2350 && !Platform_RP2350_arm_s && !Platform_RP2350_riscv && !Platform_Host
    #error("At least one Platform needs to be selected.")
#endif

#if (Platform_RP2350 || Platform_RP2350_arm_s || Platform_RP2350_riscv)
    #if (Variant_RP2350A && Variant_RP2350B)
        #error("Only one Variant can be selected at a time.")
    #elseif !Variant_RP2350A && !Variant_RP2350B
        #error("At least one Variant needs to be selected.")
    #endif
#endif

#if Variant_RP2350A && Radio_None
    @_cdecl("_cpicosdk_combination_pico2")
    func cpicosdk_combination_pico2_marker() {}

    @_exported import _CPicoSDK_pico2
#elseif Variant_RP2350A && Radio_CYW43439
    @_cdecl("_cpicosdk_combination_pico2_w")
    func cpicosdk_combination_pico2_w_marker() {}

    @_exported import _CPicoSDK_pico2_w
#elseif Variant_RP2350B && Radio_None
    @_cdecl("_cpicosdk_combination_pimoroni_pico_plus2_rp2350")
    func cpicosdk_combination_pimoroni_pico_plus2_rp2350_marker() {}

    @_exported import _CPicoSDK_pimoroni_pico_plus2_rp2350
#elseif Variant_RP2350B && Radio_CYW43439
    @_cdecl("_cpicosdk_combination_pimoroni_pico_plus2_w_rp2350")
    func cpicosdk_combination_pimoroni_pico_plus2_w_rp2350_marker() {}

    @_exported import _CPicoSDK_pimoroni_pico_plus2_w_rp2350
#else
    // TODO: This is very constrained, until we can add proper board capability support this will help us keep moving.
    #error("Invalid Variant + Radio combination.")

    // This is kept here to trick sourcekit into resolving the imports for the correct symbols, 
    // even if they won't be used due to the error above.
    import _CPicoSDK_pico2_w
#endif

#if StdIO_Automatic && (StdIO_UART || StdIO_USB || StdIO_RTT)
    #error("StdIO_Automatic mode is selected, StdIO_UART, StdIO_USB or StdIO_RTT can't be selected at the same time.")
#endif

#if StdIO_Automatic
    // Automatic mode will enable USB when using picotool and UART when using cortex-debug.
    // Depends on the environment where the binary is being built, vscode extensions may be required.
    @_cdecl("_cpicosdk_trait_stdio_automatic")
    func cpicosdk_trait_stdio_automatic_marker() {}
#endif

#if StdIO_UART
    @_cdecl("_cpicosdk_trait_stdio_uart")
    func cpicosdk_trait_stdio_uart_marker() {}
#endif

#if StdIO_USB
    @_cdecl("_cpicosdk_trait_stdio_usb")
    func cpicosdk_trait_stdio_usb_marker() {}
#endif

#if StdIO_RTT
    @_cdecl("_cpicosdk_trait_stdio_rtt")
    func cpicosdk_trait_stdio_rtt_marker() {}
#endif

// TODO: Implement trait generation.
// GENERATOR MARK: TRAIT DEFINITIONS

@_spi(Internal) public func setupPicoSDK() {
    stdio_init_all()
}

/// Embedded app protocol. Provides a default implementation of the `main` method that
/// sets up basic PicoSDK features before calling the user-defined `setup` and `loop`.
/// 
/// Using this protocol is optional, if a custom `main` start sequence is needed, it can be
/// implemented directly in their app.
public protocol EmbeddedApp {
    static func setup()
    static func loop()
}

public extension EmbeddedApp {
    static func main() {
        // TODO: WatchDog
        setupPicoSDK()
        setup()
        while true {
            loop()
            tight_loop_contents()
        }
    }
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
    public static var current: MemoryStats {
        // Get the current end of the heap (sbrk(0))
        guard let currentHeapEnd = sbrk(0) else {
            assertionFailure("[CPicoSDK] Failed to get current heap end using sbrk(0).")
            return .init(untouched: 0, freed: 0, used: 0)
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

        return .init(untouched: untouchedRam, freed: UInt32(mi.fordblks), used: UInt32(mi.uordblks))
    }

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
        "Memory: used=\(used) bytes; freed=\(freed) bytes; untouched=\(untouched) bytes; total_free=\(totalFree) bytes; total=\(total) bytes"
    }

    public func print() {
        Swift::print("[CPicoSDK] \(self.description)")
    }
}
