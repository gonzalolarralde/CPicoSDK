import Foundation

public struct ExternalBuildEnvironmentResolver {
    public struct Configuration: Decodable {
        public var combination: String?
        public var environment: [String: String] = [:]
        public var platformTriple: String?
        public var swiftBuildType: String?
        public var incremental: Bool?

        public init(
            combination: String? = nil,
            environment: [String: String] = [:],
            platformTriple: String? = nil,
            swiftBuildType: String? = nil,
            incremental: Bool? = nil
        ) {
            self.combination = combination
            self.environment = environment
            self.platformTriple = platformTriple
            self.swiftBuildType = swiftBuildType
            self.incremental = incremental
        }

        private enum CodingKeys: String, CodingKey {
            case combination
            case environment
            case platformTriple
            case swiftBuildType
            case incremental
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                combination: try container.decodeIfPresent(
                    String.self,
                    forKey: .combination
                ),
                environment: try container.decodeIfPresent(
                    [String: String].self,
                    forKey: .environment
                ) ?? [:],
                platformTriple: try container.decodeIfPresent(
                    String.self,
                    forKey: .platformTriple
                ),
                swiftBuildType: try container.decodeIfPresent(
                    String.self,
                    forKey: .swiftBuildType
                ),
                incremental: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .incremental
                )
            )
        }
    }

    public struct Resolution {
        public let environment: [String: String]
        public let combination: String
        public let platformTriple: String
        public let swiftBuildType: String
        public let incremental: Bool
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidPlatformTriple
        case missingCombination
        case unknownCombination(String)

        public var description: String {
            switch self {
            case .invalidPlatformTriple:
                return "Couldn't derive the bare-metal target triple from the external build configuration or SwiftBuild's target settings."
            case .missingCombination:
                return "The external build configuration must select a CPicoSDK combination."
            case .unknownCombination(let name):
                return "CPicoSDK env.json does not define combination '\(name)'."
            }
        }
    }

    private struct CPicoEnvironment: Decodable {
        struct Combination: Decodable {
            let vars: [String: String]
        }

        let vars: [String: String]
        let combinations: [String: Combination]
    }

    private struct SwiftSDKLayout: Decodable {
        let picoSDKPath: String
        let picoToolchainPath: String
        let cmakePath: String
        let ninjaPath: String
        let picotoolPath: String
        let openocdPath: String?
        let swiftResourcesPath: String?
    }

    private static let forwardedProcessNames: Set<String> = [
        "AUTO_STDIO",
        "BOARD",
        "BUILD_TYPE",
        "CC",
        "CMAKE_PATH",
        "CPICOSDK_BUILD_CONFIGURATION",
        "CPICOSDK_COMBINATION",
        "CPICOSDK_CORE0_STACK_SIZE_BYTES",
        "CPICOSDK_CORE1_STACK_SIZE_BYTES",
        "CXX",
        "HOME",
        "IMPORTED_LIBS",
        "IMPORTED_LIBS_MORE",
        "NINJA_PATH",
        "NM_PATH",
        "OPENOCD_PATH",
        "PATH",
        "PICOTOOL_PATH",
        "PICO_SDK_BUNDLE_PATH",
        "PICO_SDK_PATH",
        "PICO_TOOLCHAIN_PATH",
        "SDK_VERSION",
        "SWIFTLY_PATH",
        "SWIFTPM_TRIPLE",
        "SWIFT_ARCHS",
        "SWIFT_BUILD_TYPE",
        "SWIFT_CONFIGURATION",
        "SWIFT_EMBEDDED_FALLBACK_MODULES",
        "SWIFT_EMBEDDED_FALLBACK_PATH",
        "SWIFT_EXEC",
        "SWIFT_OS",
        "SWIFT_SDK",
        "SWIFT_SUFFIX",
        "SWIFT_TOOLCHAIN_PATH",
        "SWIFT_VENDOR",
        "TMPDIR",
        "TOOLCHAIN_VERSION",
    ]

    private static let cmakeChildNames = [
        "BOARD",
        "CPICOSDK_CORE0_STACK_SIZE_BYTES",
        "CPICOSDK_CORE1_STACK_SIZE_BYTES",
        "HOME",
        "PICO_SDK_PATH",
        "PICO_TOOLCHAIN_PATH",
        "PICOTOOL_PATH",
        "SDKROOT",
        "TMPDIR",
    ]

    private let processEnvironment: [String: String]
    private let configurationURL: URL?
    private let cpicoSDKDirectory: URL

    public init(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        configurationURL: URL? = nil,
        cpicoSDKDirectory: URL
    ) {
        self.processEnvironment = processEnvironment
        self.configurationURL = configurationURL
        self.cpicoSDKDirectory = cpicoSDKDirectory
    }

    public func resolve() throws -> Resolution {
        let configuration: Configuration
        if let configurationURL {
            configuration = try JSONDecoder().decode(
                Configuration.self,
                from: Data(contentsOf: configurationURL)
            )
        } else {
            configuration = Configuration()
        }
        let cpicoEnvironment = try JSONDecoder().decode(
            CPicoEnvironment.self,
            from: Data(contentsOf: cpicoSDKDirectory.appendingPathComponent("env.json"))
        )
        guard let combination = configuration.combination
            ?? processEnvironment["CPICOSDK_COMBINATION"]
        else {
            throw Error.missingCombination
        }
        guard let combinationEnvironment = cpicoEnvironment.combinations[combination] else {
            throw Error.unknownCombination(combination)
        }

        var environment = cpicoEnvironment.vars
        environment.merge(
            combinationEnvironment.vars,
            uniquingKeysWith: { _, combinationValue in combinationValue }
        )
        environment.merge(
            configuration.environment,
            uniquingKeysWith: { _, configuredValue in configuredValue }
        )
        environment.merge(
            processEnvironment.filter { key, _ in
                Self.forwardedProcessNames.contains(key)
                    || key.hasPrefix("CPICO_EXTERNAL_STDIO_")
            },
            uniquingKeysWith: { _, processValue in processValue }
        )
        environment["CPICOSDK_COMBINATION"] = combination

        applyInstalledSwiftSDKLayout(to: &environment)
        applyDerivedDefaults(to: &environment)

        let platformTriple = try configuration.platformTriple
            ?? environment["CPICOSDK_PLATFORM_TRIPLE"]
            ?? environment["SWIFTPM_TRIPLE"]
            ?? derivedTriple(from: environment)
            ?? { throw Error.invalidPlatformTriple }()
        let swiftBuildType = configuration.swiftBuildType
            ?? environment["SWIFT_BUILD_TYPE"]
            ?? environment["SWIFT_CONFIGURATION"]?.lowercased()
            ?? "release"

        return Resolution(
            environment: environment,
            combination: combination,
            platformTriple: platformTriple,
            swiftBuildType: swiftBuildType,
            incremental: configuration.incremental ?? true
        )
    }

    private func applyInstalledSwiftSDKLayout(
        to environment: inout [String: String]
    ) {
        guard let swiftSDK = environment["SWIFT_SDK"],
              let layoutURL = findLayout(startingAt: URL(
                fileURLWithPath: swiftSDK,
                isDirectory: true
              )),
              let data = try? Data(contentsOf: layoutURL),
              let layout = try? JSONDecoder().decode(SwiftSDKLayout.self, from: data)
        else {
            return
        }

        let root = layoutURL.deletingLastPathComponent()
        func absolute(_ path: String) -> URL {
            return (path as NSString).isAbsolutePath
                ? URL(fileURLWithPath: path).standardizedFileURL
                : root.appendingPathComponent(path).standardizedFileURL
        }

        let picoSDKBundle = root.appendingPathComponent("pico-sdk-bundle")
        let picoSDK = absolute(layout.picoSDKPath)
        let toolchain = absolute(layout.picoToolchainPath)
        let cmake = absolute(layout.cmakePath)
        let ninja = absolute(layout.ninjaPath)
        environment["PICO_SDK_BUNDLE_PATH"] = picoSDKBundle.path
        environment["PICO_SDK_PATH"] = picoSDK.path
        environment["PICO_TOOLCHAIN_PATH"] = toolchain.path
        environment["CMAKE_PATH"] = cmake.deletingLastPathComponent().path
        environment["NINJA_PATH"] = ninja.deletingLastPathComponent().path
        environment["PICOTOOL_PATH"] = absolute(layout.picotoolPath).path
        environment["NM_PATH"] = toolchain
            .appendingPathComponent("bin/arm-none-eabi-nm").path
        environment["LD_PATH"] = toolchain
            .appendingPathComponent("bin/arm-none-eabi-ld").path
        environment["GDB_PATH"] = toolchain
            .appendingPathComponent("bin/arm-none-eabi-gdb").path
        environment["SDK_PATH"] = toolchain
            .appendingPathComponent("arm-none-eabi").path
        environment["SDK_VERSION"] = picoSDK.lastPathComponent
        environment["TOOLCHAIN_VERSION"] = toolchain.lastPathComponent
        if let openocdPath = layout.openocdPath {
            environment["OPENOCD_PATH"] = absolute(openocdPath).path
        }
        if let swiftResourcesPath = layout.swiftResourcesPath {
            environment["SWIFT_EMBEDDED_FALLBACK_PATH"] = absolute(
                swiftResourcesPath
            ).path
            environment["SWIFT_EMBEDDED_FALLBACK_MODULES"] = "1"
        }
    }

    private func applyDerivedDefaults(to environment: inout [String: String]) {
        if environment["BUILD_TYPE"]?.isEmpty != false {
            environment["BUILD_TYPE"] = "RelWithDebInfo"
        }
        if environment["CPICOSDK_CORE0_STACK_SIZE_BYTES"]?.isEmpty != false {
            environment["CPICOSDK_CORE0_STACK_SIZE_BYTES"] = "8192"
        }
        if environment["CPICOSDK_CORE1_STACK_SIZE_BYTES"]?.isEmpty != false {
            environment["CPICOSDK_CORE1_STACK_SIZE_BYTES"] = "8192"
        }
        environment["RELEVANT_ENV_VARS"] = Self.cmakeChildNames
            .filter { environment[$0]?.isEmpty == false }
            .joined(separator: ",")
    }

    private func derivedTriple(from environment: [String: String]) -> String? {
        guard let architectures = environment["SWIFT_ARCHS"]?
            .split(whereSeparator: \Character.isWhitespace),
              architectures.count == 1,
              let vendor = environment["SWIFT_VENDOR"], !vendor.isEmpty,
              let os = environment["SWIFT_OS"], !os.isEmpty
        else {
            return nil
        }

        let base = "\(architectures[0])-\(vendor)-\(os)"
        guard let suffix = environment["SWIFT_SUFFIX"], !suffix.isEmpty else {
            return base
        }
        return suffix.hasPrefix("-") ? base + suffix : base + "-" + suffix
    }

    private func findLayout(startingAt start: URL) -> URL? {
        var candidate = start.standardizedFileURL
        for _ in 0..<10 {
            let layout = candidate.appendingPathComponent(
                "cpicosdk-layout.json",
                isDirectory: false
            )
            if FileManager.default.fileExists(atPath: layout.path) {
                return layout
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return nil
    }
}
