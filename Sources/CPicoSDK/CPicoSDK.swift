@_exported import _CPicoSDK

#if (Platform_RP2040 && (Platform_RP2350 || Platform_RP2350_arm_s || Platform_RP2350_riscv || Platform_Host))
#error("Only one Platform can be selected at a time.")
#elseif (Platform_RP2350 && (Platform_RP2350_arm_s || Platform_RP2350_riscv || Platform_Host))
#error("Only one Platform can be selected at a time.")
#elseif (Platform_RP2350_arm_s && (Platform_RP2350_riscv || Platform_Host))
#error("Only one Platform can be selected at a time.")
#elseif (Platform_RP2350_riscv && Platform_Host)
#error("Only one Platform can be selected at a time.")
#elseif !Platform_RP2040 && !Platform_RP2350 && !Platform_RP2350_arm_s && !Platform_RP2350_riscv && !Platform_Host
#error("At least one Platform needs to be selected.")
#endif
