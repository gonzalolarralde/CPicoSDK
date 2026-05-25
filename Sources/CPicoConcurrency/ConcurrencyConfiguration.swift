import CPicoSDK

/// Configuration for the embedded Swift concurrency scheduler.
///
/// Configure this from `EmbeddedAsyncApp.configure(with:)`, before the async app
/// enters `setup()`. `EmbeddedAsyncApp` reads the sealed configuration and then
/// explicitly starts core1 before calling `setup()`.
public struct ConcurrencyConfiguration: Configuration {
    public static var id: String { "CPicoConcurrency-ConcurrencyConfiguration" }

    public let core1Enabled: Bool

    public init(core1Enabled: Bool = true) {
        self.core1Enabled = core1Enabled
    }
}

public extension Configurator {
    var core1Enabled: Bool {
        get {
            configurations(for: ConcurrencyConfiguration.self).last?.core1Enabled ?? true
        }
        set {
            configure(ConcurrencyConfiguration(core1Enabled: newValue))
        }
    }
}

public enum ConcurrencyRuntime {
    /// Starts core1 and attaches it to the Swift concurrency scheduler.
    ///
    /// `EmbeddedAsyncApp` calls this automatically when `core1Enabled` is true.
    /// Apps with a custom `@main` can call this after their CPicoSDK
    /// configuration has been sealed and before they expect work to run on
    /// core1.
    public static func startMulticore() {
        cshimsRuntimeScheduler.startMulticore()
    }
}
