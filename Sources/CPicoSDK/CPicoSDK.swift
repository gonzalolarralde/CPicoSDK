@_exported import ARMClib

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
