#if Variant_RP2350A && Radio_None
    import _CPicoSDK_pico2
#elseif Variant_RP2350A && Radio_CYW43439
    import _CPicoSDK_pico2_w
#elseif Variant_RP2350B && Radio_None
    import _CPicoSDK_pimoroni_pico_plus2_rp2350
#elseif Variant_RP2350B && Radio_CYW43439
    import _CPicoSDK_pimoroni_pico_plus2_w_rp2350
#else
    import _CPicoSDK_pico2_w
#endif

/// Configurator struct to gather all the configuration for the SDK and the app in one 
/// place. It provides a type-safe way to configure the SDK and its features, and can 
/// be used to configure hardware features and capabilities as well.
public struct Configurator: ~Copyable { // TODO: Make ~Escapable
    public enum Error: Swift.Error {
        case configurationWasAlreadySealed

        var description: String {
            switch self {
            case .configurationWasAlreadySealed: "Configuration was already sealed, can't modify it anymore."
            }
        }
    }

    // TODO: Decide if this should use a Mutex or move it all to an actor. Unsafe for now.
    private nonisolated(unsafe) static var configurations: [String: UnsafeMutableRawPointer]? = nil

    public static func configuration<C: Configuration>(for: C.Type) -> C? {
        guard let configurations = Self.configurations else {
            assertionFailure("Configurations were not sealed yet.")
            return nil
        }
        guard let ptr = configurations[C.id] else { return nil }
        return ptr.load(as: C.self)
    }

    private var configurations: [Configuration.ID: UnsafeMutableRawPointer] = [:]

    @_spi(Internal) public init() {}

    public mutating func configure<C: Configuration>(_ configuration: consuming C) {
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<C>.size, alignment: MemoryLayout<C>.alignment)
        ptr.storeBytes(of: configuration, as: C.self)
        self.configurations[C.id] = ptr
    }

    @_spi(Internal) public mutating func sealConfiguration() throws {
        if Self.configurations != nil {
            throw Error.configurationWasAlreadySealed
        }
        Self.configurations = self.configurations
        self.configurations = [:]
    }

    deinit {
        for ptr in configurations.values {
            ptr.deallocate()
        }
    }
}

/// Configuration protocol. Types conforming to this protocol can be used to configure the 
/// behavior of the SDK, its features and the hardware connected to it.
public protocol Configuration: ~Copyable {
    typealias ID = String
    static var id: ID { get }
}

/// Embedded app protocol. Provides a default implementation of the `main` method that
/// sets up basic PicoSDK features before calling the user-defined `setup` and `loop`.
/// 
/// Using this protocol is optional, if a custom `main` start sequence is needed, it can be
/// implemented directly in their app.
public protocol EmbeddedApp {
    static func configure(with configurator: inout Configurator)
    static func setup()
    static func loop()
}

public extension EmbeddedApp {
    static func main() {
        setupPicoSDK()

        var configurator = Configurator()
        self.configure(with: &configurator)
        try! configurator.sealConfiguration()

        // TODO: WatchDog

        setup()
        while true {
            loop()
            tight_loop_contents()
        }
    }

    static func configure(with configurator: inout Configurator) {
        // Default implementation does nothing, this can be used by apps that don't need configuration.
    }
}