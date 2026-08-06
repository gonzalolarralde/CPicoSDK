import Foundation

struct Env: Codable, Hashable {
    enum Error: Swift.Error {
        case fileNotFound(String)
    }

    struct Combination: Codable, Hashable {
        let vars: [String: String]
        let traits: [String]
    }

    // Keep this ordered and stable: it is serialized into RELEVANT_ENV_VARS,
    // and order changes would invalidate SwiftPM plugin cache hashes.
    static let relevantEnvVars: [String] = [
        "HOME",
        "PACKAGE_PATH",
        "PLUGIN_OUTPUT_PATH",
        "SWIFTPM_PRODUCT",
        "PICO_SDK_BUNDLE_PATH",
        "SWIFT_VERSION",
        "SDK_VERSION",
        "TOOLCHAIN_VERSION",
        "CMAKE_VERSION",
        "NINJA_VERSION",
        "PICOTOOL_VERSION",
        "OPENOCD_VERSION",
        "PICO_SDK_PATH",
        "PICO_TOOLCHAIN_PATH",
        "PICOTOOL_PATH",
        "CMAKE_PATH",
        "NINJA_PATH",
        "SWIFTLY_PATH",
        "SWIFT_EMBEDDED_FALLBACK_PATH",
        "SWIFT_EMBEDDED_FALLBACK_MODULES",
        "SDK_PATH",
        "LD_PATH",
        "GDB_PATH",
        "NM_PATH",
        "RSYNC_PATH",
        "IMPORTED_LIBS",
        "IMPORTED_LIBS_MORE",
        "ARCH_PREPROCESSOR_DEFINE",
        "OPENOCD_TARGET",
        "OPENOCD_DEVICE",
        "SVD_FILE",
        "SWIFTPM_TRIPLE",
        "BUILD_TYPE",
        "SWIFT_BUILD_TYPE",
        "CPICOSDK_CORE0_STACK_SIZE_BYTES",
        "CPICOSDK_CORE1_STACK_SIZE_BYTES",
        "CPICOSDK_BUILD_CONFIGURATION",
        "CPICOSDK_COMBINATION",
        "BOARD",
    ]
    
    let vars: [String: String]
    let combinations: [String: Combination]

    static let boardDefiningTraitPrefixes = [
        "Platform_",
        "Variant_",
        "Radio_",
    ]

    static func boardDefiningTraits(from traits: some Sequence<String>) -> Set<String> {
        Set(traits.filter { trait in
            boardDefiningTraitPrefixes.contains { trait.hasPrefix($0) }
        })
    }

    init(from file: String) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: file),
           let envsContent = fileManager.contents(atPath: file),
           let envs = try? JSONDecoder().decode(Self.self, from: envsContent)
        {
            self = envs
        } else {
            throw Error.fileNotFound(file)
        }
    }

    func validateCombinations() {
        var boardTraitSets: [Set<String>: String] = [:]

        for (name, combination) in combinations {
            let boardTraits = Self.boardDefiningTraits(from: combination.traits)
            if boardTraits.isEmpty {
                fatalError("[CPicoSDK] Combination \(name) does not define any board-selection traits.")
            }

            if let existing = boardTraitSets[boardTraits] {
                fatalError("[CPicoSDK] Combinations \(existing) and \(name) use the same board-selection traits: \(boardTraits.sorted().joined(separator: ", "))")
            }

            boardTraitSets[boardTraits] = name
        }
    }
}
