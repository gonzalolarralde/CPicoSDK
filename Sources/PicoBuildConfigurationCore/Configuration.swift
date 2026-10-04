import Foundation

public struct ConfigurationError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ConfigurationDefaults: Codable, Sendable {
    public struct Combination: Codable, Sendable {
        public let vars: [String: String]
        public let traits: [String]
    }
    public let vars: [String: String]
    public let combinations: [String: Combination]
}

public struct ConfigurationContext: Codable, Sendable {
    public let packagePath: String
    public let pluginOutputPath: String
    public let sdkPackagePath: String
}

public struct PreparationRequest: Codable, Sendable {
    public let defaults: ConfigurationDefaults
    public let given: [String: String]
    public let board: String
    public let context: ConfigurationContext
}

public struct PreparationResult: Codable, Sendable {
    public let variables: [String: String]
    public let specializations: [String: [String: String]]
    public let installation: BuildInstallation
}

public struct BuildInstallation: Codable, Sendable {
    public let schemaVersion: Int
    public let context: ConfigurationContext
    public let overrides: [String: String]
    public let compilerPath: String
    public let metadataInspectorPath: String
    public let targetTriple: String
    public let compileSettings: [String: String]
}

public struct ResolvedBuildConfiguration: Codable, Sendable {
    public struct Stdio: Codable, Equatable, Sendable {
        public let uart: Bool
        public let usb: Bool
        public let rtt: Bool
    }
    public let schemaVersion: Int
    public let board: String
    public let stdio: Stdio
    public let variables: [String: String]
}

public enum ConfigurationResolver {
    // Keep the legacy export order stable for existing command-plugin callers.
    public static let relevantVariables = [
        "HOME", "PACKAGE_PATH", "PLUGIN_OUTPUT_PATH", "SWIFTPM_PRODUCT", "PICO_SDK_BUNDLE_PATH",
        "SWIFT_VERSION", "CPICOSDK_SWIFT_EXEC", "SDK_VERSION", "TOOLCHAIN_VERSION", "CMAKE_VERSION",
        "NINJA_VERSION", "PICOTOOL_VERSION", "OPENOCD_VERSION", "PICO_SDK_PATH", "PICO_TOOLCHAIN_PATH",
        "PICOTOOL_PATH", "CMAKE_PATH", "NINJA_PATH", "SWIFTLY_PATH", "SWIFT_EMBEDDED_FALLBACK_PATH",
        "SWIFT_EMBEDDED_FALLBACK_MODULES", "TOOLSET_PATH", "SDK_PATH", "LD_PATH", "GDB_PATH", "NM_PATH",
        "RSYNC_PATH", "IMPORTED_LIBS", "IMPORTED_LIBS_MORE", "ARCH_PREPROCESSOR_DEFINE", "OPENOCD_TARGET",
        "OPENOCD_DEVICE", "SVD_FILE", "SWIFTPM_TRIPLE", "BUILD_TYPE", "SWIFT_BUILD_TYPE", "EXTRA_CONFIG_PARAMS",
        "CPICOSDK_CORE0_STACK_SIZE_BYTES", "CPICOSDK_CORE1_STACK_SIZE_BYTES", "BOARD",
    ]

    // These affect SwiftPM's already-planned compiler invocation, not just CMake.
    static let compileSettingKeys = [
        "SDK_PATH", "SWIFT_VERSION", "SWIFT_EMBEDDED_FALLBACK_PATH", "SWIFT_EMBEDDED_FALLBACK_MODULES",
        "CPICOSDK_CORE1_STACK_SIZE_BYTES",
    ]

    public static func expand(_ input: [String: String]) throws -> [String: String] {
        var result = input
        let pattern = try NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
        for _ in 0..<10 {
            let previous = result
            for (key, value) in previous where value.contains("$") {
                var expanded = value
                for match in pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                    let name = (value as NSString).substring(with: match.range(at: 1))
                    if let replacement = previous[name], let range = Range(match.range, in: expanded) {
                        expanded.replaceSubrange(range, with: replacement)
                    }
                }
                result[key] = expanded
            }
            if !result.values.contains(where: { $0.contains("$") }) { return result }
        }
        let unresolved = result.filter { $0.value.contains("$") }.keys.sorted().joined(separator: ", ")
        throw ConfigurationError("Unresolved configuration variables: \(unresolved). Only ${NAME} substitutions are supported.")
    }

    public static func prepare(_ request: PreparationRequest) throws -> PreparationResult {
        guard let combination = request.defaults.combinations[request.board] else {
            throw ConfigurationError("Unknown board configuration: \(request.board)")
        }
        let given = request.given.filter { relevantVariables.contains($0.key) }
        var values = request.defaults.vars.filter { $0.key != "BOARD" }
        values.merge(combination.vars, uniquingKeysWith: { _, new in new })
        values.merge(given, uniquingKeysWith: { _, new in new })
        let buildType = values["BUILD_TYPE"] ?? ""
        let swiftBuildType: String
        var extraFlags: String
        switch buildType {
        case "Debug": swiftBuildType = "debug"; extraFlags = ""
        case "Release": swiftBuildType = "release"; extraFlags = ""
        case "RelWithDebInfo": swiftBuildType = "release"; extraFlags = "-Xswiftc -g -Xswiftc -debug-info-format=dwarf -Xcc -g"
        case "MinSizeRel": swiftBuildType = "release"; extraFlags = "-Xswiftc -Osize"
        default: throw ConfigurationError("Unsupported BUILD_TYPE: \(buildType)")
        }
        extraFlags = values["EXTRA_CONFIG_PARAMS"] ?? extraFlags
        #if os(Linux)
        if !extraFlags.contains("--disable-sandbox") {
            extraFlags += " --disable-sandbox --disable-build-manifest-caching --manifest-cache none"
        }
        #endif
        values["SWIFT_BUILD_TYPE"] = values["SWIFT_BUILD_TYPE"] ?? swiftBuildType
        values["TOOLSET_PATH"] = values["TOOLSET_PATH"] ?? request.context.packagePath + "/toolset.json"
        values["PACKAGE_PATH"] = values["PACKAGE_PATH"] ?? request.context.packagePath
        values["PLUGIN_OUTPUT_PATH"] = values["PLUGIN_OUTPUT_PATH"] ?? request.context.pluginOutputPath
        values["SWIFTPM_PRODUCT"] = values["SWIFTPM_PRODUCT"] ?? ""
        values["RELEVANT_ENV_VARS"] = relevantVariables.joined(separator: ",")
        values["SWIFT_EMBEDDED_FALLBACK_MODULES"] = values["SWIFT_EMBEDDED_FALLBACK_MODULES"] ?? "0"
        values["CPICOSDK_CORE0_STACK_SIZE_BYTES"] = values["CPICOSDK_CORE0_STACK_SIZE_BYTES"] ?? "8192"
        values["CPICOSDK_CORE1_STACK_SIZE_BYTES"] = values["CPICOSDK_CORE1_STACK_SIZE_BYTES"] ?? "8192"
        if !extraFlags.contains("CPICOSDK_CORE1_STACK_SIZE_BYTES=") {
            extraFlags += " -Xcc -DCPICOSDK_CORE1_STACK_SIZE_BYTES=\(values["CPICOSDK_CORE1_STACK_SIZE_BYTES"]!)"
        }
        values["EXTRA_CONFIG_PARAMS"] = extraFlags
        if values["SWIFT_EMBEDDED_FALLBACK_PATH"] == nil, let version = values["SWIFT_VERSION"] {
            values["SWIFT_EMBEDDED_FALLBACK_PATH"] = request.context.sdkPackagePath
                + "/Vendor/EmbeddedSwiftRuntime/\(version)/usr/lib/swift/embedded"
        }
        values = try expand(values)
        var specializations: [String: [String: String]] = [:]
        for (board, configuration) in request.defaults.combinations {
            let overrides = configuration.vars.filter { given[$0.key] == nil }
            let specialized = try expand(values.merging(overrides, uniquingKeysWith: { _, new in new }))
            let missing = relevantVariables.filter { $0 != "CPICOSDK_SWIFT_EXEC" && specialized[$0] == nil }
            guard missing.isEmpty else {
                throw ConfigurationError("Missing configuration for \(board): \(missing.joined(separator: ", "))")
            }
            specializations[board] = specialized.filter { overrides[$0.key] != nil }
        }
        return PreparationResult(
            variables: values, specializations: specializations,
            installation: BuildInstallation(
                schemaVersion: 1, context: request.context, overrides: given,
                compilerPath: values["CPICOSDK_SWIFT_EXEC"] ?? values["PLUGIN_OUTPUT_PATH"]! + "/generated/swift-toolchain/bin/swiftc",
                metadataInspectorPath: values["NM_PATH"]!,
                targetTriple: values["SWIFTPM_TRIPLE"]!,
                compileSettings: values.filter { compileSettingKeys.contains($0.key) }
            )
        )
    }

    public static func board(from symbols: String) throws -> String {
        let pattern = try NSRegularExpression(pattern: "_cpicosdk_combination_([a-zA-Z0-9_]+)")
        let matches = Set(pattern.matches(in: symbols, range: NSRange(symbols.startIndex..., in: symbols))
            .map { (symbols as NSString).substring(with: $0.range(at: 1)) })
        guard matches.count == 1, let board = matches.first else {
            throw ConfigurationError("Expected exactly one board marker in CPicoSDKConfiguration; found \(matches.sorted()).")
        }
        return board
    }

    public static func resolveBuild(
        defaults: ConfigurationDefaults, installation: BuildInstallation, symbols: String,
        overrides: [String: String], triple: String, configuration: String
    ) throws -> ResolvedBuildConfiguration {
        guard installation.schemaVersion == 1 else { throw ConfigurationError("Unsupported installation configuration version.") }
        let board = try board(from: symbols)
        var given = installation.overrides
        given.merge(overrides.filter { relevantVariables.contains($0.key) }, uniquingKeysWith: { _, new in new })
        if let requestedBoard = given["BOARD"], requestedBoard != board {
            throw ConfigurationError("BOARD=\(requestedBoard) disagrees with compiled board metadata \(board).")
        }
        if let requestedCompiler = given["CPICOSDK_SWIFT_EXEC"], requestedCompiler != installation.compilerPath {
            throw ConfigurationError("Compiler selection changed. Rerun explicit preparation before building.")
        }
        given["CPICOSDK_SWIFT_EXEC"] = installation.compilerPath
        if configuration.lowercased() == "debug" {
            if let explicit = overrides["BUILD_TYPE"], explicit != "Debug" {
                throw ConfigurationError("BUILD_TYPE=\(explicit) disagrees with SwiftPM Debug configuration.")
            }
            given["BUILD_TYPE"] = "Debug"
        }
        let result = try prepare(.init(defaults: defaults, given: given, board: board, context: installation.context))
        var values = result.variables
        let boardTriple = defaults.combinations[board]?.vars["SWIFTPM_TRIPLE"] ?? defaults.vars["SWIFTPM_TRIPLE"]
        guard boardTriple == triple, values["SWIFTPM_TRIPLE"] == triple, installation.targetTriple == triple else {
            throw ConfigurationError("Board \(board), installed toolset, and SwiftPM triple \(triple) disagree. Rerun explicit preparation for the selected board.")
        }
        let nativeSwiftConfiguration = values["BUILD_TYPE"] == "Debug" ? "debug" : "release"
        guard nativeSwiftConfiguration == configuration.lowercased(),
              values["SWIFT_BUILD_TYPE"]?.lowercased() == configuration.lowercased() else {
            throw ConfigurationError("BUILD_TYPE disagrees with SwiftPM \(configuration) configuration.")
        }
        for key in compileSettingKeys where values[key] != installation.compileSettings[key] {
            throw ConfigurationError("\(key) changed after toolset generation. Rerun explicit preparation before building.")
        }
        let automatic = symbols.contains("_cpicosdk_trait_stdio_automatic")
        let automaticMode = overrides["AUTO_STDIO"] ?? "usb"
        guard ["usb", "uart", "rtt"].contains(automaticMode) else {
            throw ConfigurationError("Unsupported AUTO_STDIO: \(automaticMode)")
        }
        let stdio = ResolvedBuildConfiguration.Stdio(
            uart: automatic ? automaticMode == "uart" : symbols.contains("_cpicosdk_trait_stdio_uart"),
            usb: automatic ? automaticMode == "usb" : symbols.contains("_cpicosdk_trait_stdio_usb"),
            rtt: automatic ? automaticMode == "rtt" : symbols.contains("_cpicosdk_trait_stdio_rtt")
        )
        values["BOARD"] = board
        values["AUTO_STDIO"] = automaticMode
        // Native processes only receive build inputs, not editor/debugger configuration.
        let unused: Set<String> = ["OPENOCD_PATH", "OPENOCD_TARGET", "OPENOCD_DEVICE", "OPENOCD_VERSION", "GDB_PATH", "SVD_FILE"]
        values = values.filter { !unused.contains($0.key) }
        values["RELEVANT_ENV_VARS"] = values.keys.filter { $0 != "RELEVANT_ENV_VARS" }.sorted().joined(separator: ",")
        return ResolvedBuildConfiguration(schemaVersion: 1, board: board, stdio: stdio, variables: values)
    }

    public static func validateInstallation(_ values: [String: String]) throws {
        let executables = [
            ("CPICOSDK_SWIFT_EXEC", ""), ("CMAKE_PATH", "/cmake"), ("NINJA_PATH", "/ninja"),
            ("PICO_TOOLCHAIN_PATH", "/bin/arm-none-eabi-gcc"), ("PICO_TOOLCHAIN_PATH", "/bin/arm-none-eabi-g++"),
            ("PICO_TOOLCHAIN_PATH", "/bin/arm-none-eabi-ar"), ("PICO_TOOLCHAIN_PATH", "/bin/arm-none-eabi-objcopy"),
            ("LD_PATH", ""), ("PICOTOOL_PATH", ""), ("NM_PATH", ""), ("RSYNC_PATH", ""),
        ]
        for (key, suffix) in executables {
            guard let path = values[key], FileManager.default.isExecutableFile(atPath: path + suffix) else {
                throw ConfigurationError("Missing executable \(key): \(values[key] ?? "unset")\(suffix). Run explicit preparation; swift build does not install tools.")
            }
        }
        for (key, suffix) in [("PICO_SDK_PATH", "/pico_sdk_init.cmake"), ("SDK_PATH", "/include/stdint.h")] {
            guard let path = values[key], FileManager.default.fileExists(atPath: path + suffix) else {
                throw ConfigurationError("Missing SDK input \(key): \(values[key] ?? "unset")\(suffix). Run explicit preparation.")
            }
        }
    }

    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        if (try? Data(contentsOf: url)) == data { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
