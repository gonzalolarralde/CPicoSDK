@_exported import _CPicoSDK

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
@used @_silgen_name("_cpicosdk_combination")
public let _cpicosdk_combination = "pico2"
#elseif Variant_RP2350A && Radio_CYW43439
@used @_silgen_name("_cpicosdk_combination")
public let _cpicosdk_combination = "pico2_w"
#elseif Variant_RP2350B && Radio_None
@used @_silgen_name("_cpicosdk_combination")
public let _cpicosdk_combination = "pimoroni_pico_plus2_rp2350"
#elseif Variant_RP2350B && Radio_CYW43439
@used @_silgen_name("_cpicosdk_combination")
public let _cpicosdk_combination = "pimoroni_pico_plus2_w_rp2350"
#else
// TODO: This is very restrained, until we can add proper board capability support this will help us move through.
#error("Invalid Variant + Radio combination.")
#endif

#if RP2
@used @_silgen_name("_cpicosdk_trait_rp2")
public let _cpicosdk_trait_rp2 = 1
#endif

#if RP2350B
@used @_silgen_name("_cpicosdk_trait_rp2350b")
public let _cpicosdk_trait_rp2350b = 1
#endif

#if StdIO_UART
@used @_silgen_name("_cpicosdk_trait_stdio_uart")
public let _cpicosdk_trait_stdio_uart = 1
#endif

#if StdIO_USB
@used @_silgen_name("_cpicosdk_trait_stdio_usb")
public let _cpicosdk_trait_stdio_usb = 1
#endif

#if StdIO_RTT
@used @_silgen_name("_cpicosdk_trait_stdio_rtt")
public let _cpicosdk_trait_stdio_rtt = 1
#endif

// TODO: Implement trait generation.
// GENERATOR MARK: TRAIT DEFINITIONS
