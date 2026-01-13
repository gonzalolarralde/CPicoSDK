import CPicoSDK

enum shift_combined {
    static let wrap_target: UInt32 = 0
    static let wrap: UInt32 = 1
    static let pio_version: UInt8 = 1

    static nonisolated(unsafe) let instructions: UnsafeBufferPointer<UInt16> = {
        let instructions: [UInt16] = [
                    //     .wrap_target
            0x4008, //  0: in     pins, 8
            0x6004, //  1: out    pins, 4
                    //     .wrap
        ]
        let bufferPointer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: instructions.count)
        let (_, index) = bufferPointer.initialize(from: instructions)
        assert(index == instructions.endIndex, "Failed to initialize buffer pointer")
        return UnsafeBufferPointer(bufferPointer)
    }()

    #if !PICO_NO_HARDWARE
    static nonisolated(unsafe) let programStorage = pio_program(
        instructions: instructions.baseAddress!,
        length: 2,
        origin: -1,
        pio_version: Self.pio_version,
        used_gpio_ranges: 0x0
    )

    static var program: UnsafePointer<pio_program_t> {
        // This is safe only because programStorage has static lifetime
        withUnsafePointer(to: programStorage) { $0 }
    }

    static func shift_combined_program_get_default_config(offset: UInt32) -> pio_sm_config {
        var c = pio_get_default_sm_config();
        sm_config_set_wrap(&c, offset + Self.wrap_target, offset + Self.wrap);
        sm_config_set_in_pin_count(&c, 8);
        sm_config_set_in_shift(&c, true, true, 16);
        sm_config_set_out_pin_count(&c, 4);
        sm_config_set_out_shift(&c, true, true, 24);
        return c;
    }
    #endif
}