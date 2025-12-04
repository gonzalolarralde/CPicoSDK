import CPicoSDK

@main
struct App {
    static func main() {
        stdio_init_all()
        status_led_init()

        sleep_ms(1000)
        print("Hello, world!")
        
        var last_state = false
        
        while true {
            status_led_set_state(last_state)
            last_state = !last_state
            sleep_ms(200)

            print("Hello, world!")

            tight_loop_contents()
        }
    }
}
