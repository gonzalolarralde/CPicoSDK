@_exported import ARMClib
@_exported import CPicoSDKConfiguration

#if Platform_RP2040 && Variant_RP2040 && Radio_None
    @_exported import _CPicoSDK_pico
#elseif Platform_RP2040 && Variant_RP2040 && Radio_CYW43439
    @_exported import _CPicoSDK_pico_w
#elseif Variant_RP2350A && Radio_None
    @_exported import _CPicoSDK_pico2
#elseif Variant_RP2350A && Radio_CYW43439
    @_exported import _CPicoSDK_pico2_w
#elseif Variant_RP2350B && Radio_None
    @_exported import _CPicoSDK_pimoroni_pico_plus2_rp2350
#elseif Variant_RP2350B && Radio_CYW43439
    @_exported import _CPicoSDK_pimoroni_pico_plus2_w_rp2350
#else
    // TODO: This is very constrained, until we can add proper board capability support this will help us keep moving.
    #error("Invalid Variant + Radio combination.")

    // This is kept here to trick sourcekit into resolving the imports for the correct symbols, 
    // even if they won't be used due to the error above.
    import _CPicoSDK_pico2_w
#endif

// TODO: Implement trait generation.
// GENERATOR MARK: TRAIT DEFINITIONS

#if Platform_RP2040
    // RP2040's pio_program_t doesn't have the used_gpio_ranges field, so we need to provide a custom initializer.
     @inlinable
     public func pio_program(
         instructions: UnsafePointer<UInt16>,
         length: Int,
         origin: Int,
         pio_version: UInt8,
         used_gpio_ranges: Int = 0
     ) -> pio_program_t {
         return pio_program_t(
             instructions: instructions,
             length: UInt8(length),
             origin: Int8(origin),
             pio_version: pio_version
         )
     }
#endif

@_spi(Internal) public func setupPicoSDK() {
    stdio_init_all()
}
