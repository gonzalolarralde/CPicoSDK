import CPicoSDK
import CPicoConcurrency

@main
struct App {
    static func main() async throws(CancellationError) {
        stdio_init_all()
        status_led_init()

        print("Scheduling 1 second alarm...")
        try await Task.sleep(ms: 1000)
        print("One second!")

        // Keep one Unicode-aware string operation in the example so the finalizer
        // can demonstrate automatic linking of libswiftUnicodeDataTables when needed.
        print("Composed/decomposed match: \("Cafe\u{301}".contains("é"))")

        print("Hello, world!")

        Foo.$bar.withValue("HelloWorld") {
            print("Task local value: \(Foo().getBar())")
        }

        Task {
            try! await blinkLeds()
        }

        // multicore_launch_core1(ledExample)
        // try! pioExample()

        while true {
            try await Task.sleep(ms: 1000)
            print("One second!")
        }
    }
}

// MARK: LED Example

func blinkLeds() async throws(CancellationError) {
    var last_state: Bool = false

    while true {
        status_led_set_state(last_state)
        last_state = !last_state
        try await Task.sleep(ms: 100)
    }
}

@c
func ledExample() {
    var last_state = false

    while true {
        status_led_set_state(last_state)
        last_state = !last_state

        // In async contexts this is discouraged, as sleep_ms will
        // block the entire async context. This example works fine
        // when not using or expecting to use Concurrency features.
        sleep_ms(100)

        picoSDKTightLoop()
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
    // Note that this is not the LED pin, we will blink on GPIO 20 for this example.
    // Please connect something visible to see the effect!
    let pin: UInt32 = 20

    var pio: PIO?
    let sm: UInt32 = 0
    var offset: UInt32 = 0

    // ------------------------------------------------------
    // Option 1: Claim a free state machine and load the program automatically
    // ------------------------------------------------------

    // // This will find a free pio and state machine for our program and load it for us
    // // We use pio_claim_free_sm_and_add_program_for_gpio_range so we can address gpios >= 32 if needed and supported by the hardware
    // guard pio_claim_free_sm_and_add_program_for_gpio_range(hello.program, &pio, &sm, &offset, pin, 1, true) else {
    //     throw PIOError.noFreeStateMachine
    // }

    // guard let pio = pio else {
    //     throw PIOError.pioNotResolved
    // }

    // ------------------------------------------------------
    // Option 2: Manually use a specific PIO and state machine
    // ------------------------------------------------------

    // This is the manual way of doing the same as above
    pio = pio0
    guard let pio = pio else {
        throw PIOError.pioNotResolved
    }

    guard let newOffset = UInt32(exactly: pio_add_program(pio, hello.program)) else {
        throw PIOError.noFreeStateMachine
    }
    offset = newOffset

    // ------------------------------------------------------

    print("Loaded program at \(offset)")

    // Configure it to run our program, and start it, using the
    // helper function we included in our .pio file.
    hello.program_init(pio: pio, sm: sm, offset: offset, pin: pin);
    
    // The state machine is now running. Any value we push to its TX FIFO will
    // appear on the pin.
    // press a key to exit
    while (getchar_timeout_us(0) == PICO_ERROR_TIMEOUT.rawValue) {
        // Blink
        pio_sm_put_blocking(pio, sm, 1);
        sleep_ms(500);
        // Blonk
        pio_sm_put_blocking(pio, sm, 0);
        sleep_ms(500);
    }

    print("Pin \(pin) will stop blinking now.")

    // This will free resources and unload our program
    pio_remove_program_and_unclaim_sm(hello.program, pio, sm, offset);
}

struct Foo {
    @TaskLocal
    static var bar: String?

    func getBar() -> String {
        return Foo.bar ?? "no bar"
    }
}
