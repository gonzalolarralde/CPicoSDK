import CPicoSDK

@main
struct App {
    static func main() {
        stdio_init_all()
        status_led_init()

        sleep_ms(1000)
        print("Hello, world!")

        multicore_launch_core1(ledExample)
        try! pioExample()
    }
}

// MARK: LED Example

@c
func ledExample() {
    var last_state = false

    while true {
        status_led_set_state(last_state)
        last_state = !last_state
        sleep_ms(100)

        tight_loop_contents()
    }
}

// MARK: PIO Example

enum PIOError: Error {
    case noFreeStateMachine
    case pioNotResolved
}

// This is a reimplementation of hello_pio from pico-examples
// https://github.com/raspberrypi/pico-examples/blob/master/pio/hello_pio/hello.c
func pioExample() throws(PIOError) {
    let pin: UInt32 = 20
    gpio_set_dir(pin, GPIO_OUT.rawValue != 0)

    var pio: PIO? = nil
    var sm: uint = 0
    var offset: uint = 0

    // This will find a free pio and state machine for our program and load it for us
    // We use pio_claim_free_sm_and_add_program_for_gpio_range so we can address gpios >= 32 if needed and supported by the hardware
    guard pio_claim_free_sm_and_add_program_for_gpio_range(hello.program, &pio, &sm, &offset, pin, 1, true) else {
        throw PIOError.noFreeStateMachine
    }

    guard let pio = pio else {
        throw PIOError.pioNotResolved
    }

    // Configure it to run our program, and start it, using the
    // helper function we included in our .pio file.
    print("Using gpio \(pin)")
    hello.program_init(pio: pio, sm: sm, offset: offset, pin: pin);

    // The state machine is now running. Any value we push to its TX FIFO will
    // appear on the LED pin.
    // press a key to exit
    while true {
    // while getchar_timeout_us(0) == PICO_ERROR_TIMEOUT.rawValue {
        // Blink
        pio_sm_put_blocking(pio, sm, 0xffff);
        // sleep_ms(500);
        // Blonk
        pio_sm_put_blocking(pio, sm, 0);
        // sleep_ms(500);
    }

    // This will free resources and unload our program
    pio_remove_program_and_unclaim_sm(hello.program, pio, sm, offset);
}