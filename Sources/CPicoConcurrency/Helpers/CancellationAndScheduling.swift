import _Concurrency
import ConcurrencyShims
@_spi(Internal) private import CPicoSDK

public typealias CancellationError = _Concurrency.CancellationError

extension Task where Success == Never, Failure == Never {
    /// Function to be called in tight loops to allow the concurrency system to make progress. 
    /// This is only needed if you're doing a busy wait in a non-async context, if you're in 
    /// an async context you can just use `await Task.yield()` instead.
    /// 
    /// Use this instead of `tight_loop_contents()` in your code to ensure that the concurrency 
    /// system can make progress and schedule other tasks while you're busy-waiting.
    /// 
    /// Note: USB polling (tud_task) happens automatically in the global executor loops.
    public static func tightLoop() {
        tight_loop_contents()
        cshimsRuntimeScheduler.pollOnce()
    }
}

/// Embedded async app protocol. Provides a default implementation of the `main` method that
/// sets up basic PicoSDK features before calling the user-defined `setup` and `loop`
/// methods, and uses the `tightLoop` helper to allow concurrency progress in busy loops.
/// 
/// Using this protocol is optional, if a custom `main` start sequence is needed, it can be
/// implemented directly in their app.
public protocol EmbeddedAsyncApp {
    static func setup() async
    static func loop() async
}

public extension EmbeddedAsyncApp {
    static func main() async {
        // TODO: Add WatchDog support here, and maybe a way to setup lwip callbacks in tightLoop.
        setupPicoSDK()
        await setup()
        while true {
            await loop()
            Task.tightLoop()
        }
    }
}
