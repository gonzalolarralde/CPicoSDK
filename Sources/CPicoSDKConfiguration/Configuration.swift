// These symbols are build metadata. Keep this target independent of SDK headers.
#if (Platform_RP2040 && (Platform_RP2350 || Platform_RP2350_arm_s || Platform_RP2350_riscv || Platform_Host))
    #error("Only one Platform can be selected at a time.")
#elseif (Platform_RP2350 && (Platform_RP2350_arm_s || Platform_RP2350_riscv || Platform_Host))
    #error("Only one Platform can be selected at a time.")
#elseif (Platform_RP2350_arm_s && (Platform_RP2350_riscv || Platform_Host || Platform_RP2040))
    #error("Only one Platform can be selected at a time.")
#elseif (Platform_RP2350_riscv && (Platform_Host || Platform_RP2040))
    #error("Only one Platform can be selected at a time.")
#elseif !Platform_RP2040 && !Platform_RP2350 && !Platform_RP2350_arm_s && !Platform_RP2350_riscv && !Platform_Host
    #error("At least one Platform needs to be selected.")
#endif

#if Platform_RP2040
    #if !Variant_RP2040
        #error("Platform_RP2040 requires Variant_RP2040.")
    #elseif Variant_RP2350A || Variant_RP2350B
        #error("Platform_RP2040 cannot be combined with RP2350 variants.")
    #endif
#endif

#if (Platform_RP2350 || Platform_RP2350_arm_s || Platform_RP2350_riscv)
    #if Variant_RP2040
        #error("RP2350 platforms cannot be combined with Variant_RP2040.")
    #elseif (Variant_RP2350A && Variant_RP2350B)
        #error("Only one Variant can be selected at a time.")
    #elseif !Variant_RP2350A && !Variant_RP2350B
        #error("At least one Variant needs to be selected.")
    #endif
#endif

#if Platform_RP2040 && Variant_RP2040 && Radio_None
    @_cdecl("_cpicosdk_combination_pico")
    func cpicosdk_combination_pico_marker() {}
#elseif Platform_RP2040 && Variant_RP2040 && Radio_CYW43439
    @_cdecl("_cpicosdk_combination_pico_w")
    func cpicosdk_combination_pico_w_marker() {}
#elseif Variant_RP2350A && Radio_None
    @_cdecl("_cpicosdk_combination_pico2")
    func cpicosdk_combination_pico2_marker() {}
#elseif Variant_RP2350A && Radio_CYW43439
    @_cdecl("_cpicosdk_combination_pico2_w")
    func cpicosdk_combination_pico2_w_marker() {}
#elseif Variant_RP2350B && Radio_None
    @_cdecl("_cpicosdk_combination_pimoroni_pico_plus2_rp2350")
    func cpicosdk_combination_pimoroni_pico_plus2_rp2350_marker() {}
#elseif Variant_RP2350B && Radio_CYW43439
    @_cdecl("_cpicosdk_combination_pimoroni_pico_plus2_w_rp2350")
    func cpicosdk_combination_pimoroni_pico_plus2_w_rp2350_marker() {}
#else
    #error("Invalid Variant + Radio combination.")
#endif

#if StdIO_Automatic && (StdIO_UART || StdIO_USB || StdIO_RTT)
    #error("StdIO_Automatic mode is selected, StdIO_UART, StdIO_USB or StdIO_RTT can't be selected at the same time.")
#endif

#if StdIO_Automatic
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
