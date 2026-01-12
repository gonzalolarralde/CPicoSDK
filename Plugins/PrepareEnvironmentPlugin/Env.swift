import Foundation

struct Env: Codable, Hashable {
    enum Error: Swift.Error {
        case fileNotFound(String)
    }

    struct Combination: Codable, Hashable {
        let vars: [String: String]
        let traits: [String]
    }

    static let relevantEnvVars: Set<String> = [
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
        "TOOLSET_PATH",
        "SDK_PATH",
        "LD_PATH",
        "GDB_PATH",
        "IMPORTED_LIBS",
        "IMPORTED_LIBS_MORE",
        "SWIFTPM_TRIPLE",
        "BUILD_TYPE",
        "SWIFT_BUILD_TYPE",
        "EXTRA_CONFIG_PARAMS",
        "BOARD",
    ]
    
    let vars: [String: String]
    let combinations: [String: Combination]

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
}
