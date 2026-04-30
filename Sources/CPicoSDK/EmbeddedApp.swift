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
        case configurationExecutionsFailed([(Configuration.ID, ConfigurationError)])

        var description: String {
            switch self {
            case .configurationWasAlreadySealed: "Configuration was already sealed, can't modify it anymore."
            case .configurationExecutionsFailed(let errors): "Configuration executions failed: \n\(errors.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))"
            }
        }
    }

    // TODO: Decide if this should use a Mutex, there are no concurrency guarantees but are they needed given where this runs?
    private nonisolated(unsafe) static var configurations: [String: [UnsafeWeaklyTypedContainer]]? = nil

    public static func configurations<C: Configuration>(for: C.Type) -> [C] {
        guard let configurations = Self.configurations else {
            assertionFailure("Configurations were not sealed yet.")
            return []
        }

        return configurations[C.id]?.compactMap { $0.load(as: C.self) } ?? []
    }

    private var accumulatedConfigurations: [Configuration.ID: [AnyConfiguration]] = [:]

    @_spi(Internal) public init() {}

    public func configurations<C: Configuration>(for: C.Type) -> [C] {
        return accumulatedConfigurations[C.id]?.compactMap { try? $0.load(as: C.self) } ?? []
    }

    public mutating func configure<C: Configuration>(_ configuration: sending C) {
        let anyConfiguration = AnyConfiguration(configuration: configuration)
        if var existing = accumulatedConfigurations[C.id] {
            existing.append(anyConfiguration)
            accumulatedConfigurations[C.id] = existing
        } else {
            accumulatedConfigurations[C.id] = [anyConfiguration]
        }
    }

    @_spi(Internal) public mutating func sealConfiguration() throws {
        if Self.configurations != nil {
            throw Error.configurationWasAlreadySealed
        }

        var processedIDs: Set<Configuration.ID> = []
        while true {
            let pending = accumulatedConfigurations.filter { !processedIDs.contains($0.key) }
            guard !pending.isEmpty else { break }

            var errors: [(Configuration.ID, ConfigurationError)] = []
            for (id, configurations) in pending {
                processedIDs.insert(id)
                for configuration in configurations {
                    do {
                        try configuration.executeConfiguration(configuration.erasedConfiguration, &self)
                    } catch {
                        errors.append((error.configurationID, error))
                    }
                }
            }

            if !errors.isEmpty {
                throw Error.configurationExecutionsFailed(errors)
            }
        }

        Self.configurations = accumulatedConfigurations.mapValues { anyConfigurations in
            anyConfigurations.map { configuration in
                configuration.erasedConfiguration
            }
        }
    }
}

/// Configuration protocol. Types conforming to this protocol can be used to configure the 
/// behavior of the SDK, its features and the hardware connected to it.
public protocol Configuration: ~Copyable {
    typealias ID = String
    associatedtype ExecutionError: Swift.Error = Never
    static var id: ID { get }
    static var dependencies: [Configuration.ID] { get }
    func executeConfiguration(with configurator: inout Configurator) throws(ExecutionError)
}

extension Configuration {
    public static func interpretError(_ error: ConfigurationError) -> ExecutionError? {
        return error.underlyingError.load(as: ExecutionError.self)
    }

    public static var dependencies: [Configuration.ID] { [] }
    public func executeConfiguration(with configurator: inout Configurator) throws(ExecutionError) {
        // Default implementation does nothing, this can be used by configurations that don't need to derive other configurations.
    }
}

public struct ConfigurationError: Swift.Error {
    public let configurationID: Configuration.ID
    let underlyingError: UnsafeWeaklyTypedContainer

    init<E: Swift.Error>(configurationID: Configuration.ID, underlyingError: E) {
        self.configurationID = configurationID
        self.underlyingError = UnsafeWeaklyTypedContainer(underlyingError)
    }

    static func wrapError<T, E: Swift.Error>(for configurationId: Configuration.ID, _ body: () throws(E) -> T) throws(ConfigurationError) -> T {
        do {
            return try body()
        } catch {
            throw ConfigurationError(configurationID: configurationId, underlyingError: error)
        }
    }
}

struct AnyConfiguration {
    enum Error: Swift.Error {
        case couldNotLoadAsRequestedType(requested: Configuration.ID, actual: Configuration.ID)
    }
    
    let id: Configuration.ID
    let dependencies: [Configuration.ID]
    let executeConfiguration: (UnsafeWeaklyTypedContainer, inout Configurator) throws(ConfigurationError) -> Void
    let erasedConfiguration: UnsafeWeaklyTypedContainer

    func load<C: Configuration>(as type: C.Type) throws(Error) -> C {
        guard id == C.id, let configuration = erasedConfiguration.load(as: C.self) else {
            throw Error.couldNotLoadAsRequestedType(requested: C.id, actual: id)
        }
        return configuration
    }

    init<C: Configuration>(configuration: sending C) {
        self.id = C.id
        self.dependencies = C.dependencies
        self.executeConfiguration = { (erasedConfiguration, configurator) throws(ConfigurationError) in 
            try ConfigurationError.wrapError(for: C.id) { () throws(C.ExecutionError) -> Void in
                let configuration = erasedConfiguration.load(as: C.self)!
                try configuration.executeConfiguration(with: &configurator)
            }
        }
        self.erasedConfiguration = UnsafeWeaklyTypedContainer(configuration)
    }
}

extension [Configuration.ID: [UnsafeWeaklyTypedContainer]] {
    public func configurations<C: Configuration>(for: C.Type) -> [C] {
        self[C.id]?.compactMap { $0.load(as: C.self) } ?? []
    }
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