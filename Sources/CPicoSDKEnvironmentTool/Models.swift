import Foundation

struct StageOptions {
    let templateDirectory: URL
    let stagingRoot: URL
    let picoSDKBundle: URL
    let resultFile: URL
    let sdkVersion: String
    let toolchainVersion: String
    let cmakeVersion: String
    let ninjaVersion: String
    let picotoolVersion: String
    let openocdVersion: String
    let bundleVersion: String
    let requireRP2040Concurrency: Bool
}

struct StageResult: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let swiftSDKsPath: String
    let artifactBundlePath: String
    let swiftCompilerExecutable: String
    let swiftCompilerVersion: String
    let hostTriple: String
    let sdkIDs: [String]
    let rp2040ConcurrencySupported: Bool
    let rp2350ConcurrencySupported: Bool
}

struct SwiftTargetInfo: Decodable {
    struct Target: Decodable {
        let triple: String
        let unversionedTriple: String?
    }

    struct Paths: Decodable {
        let runtimeResourcePath: String
    }

    let target: Target
    let paths: Paths
}

struct SDKLayout: Decodable {
    let schemaVersion: String
    let picoSDKPath: String
    let picoToolchainPath: String
    let cmakePath: String
    let ninjaPath: String
    let picotoolPath: String
    let openocdPath: String
    let newlibOverlayPath: String
    let swiftResourcesPath: String
    let swiftCompilerVersionFile: String
    let embeddedRuntimeStrategy: String
    let rp2040ConcurrencySupported: Bool
    let rp2350ConcurrencySupported: Bool
}

enum EnvironmentToolError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case invalidIdentifier(name: String, value: String)
    case missingPath(String)
    case invalidPath(String)
    case commandFailed(executable: String, arguments: [String], status: Int32, stderr: String)
    case invalidCompiler(String)
    case invalidMetadata(String)
    case brokenLink(link: String, target: String)
    case escapedBundle(link: String, target: String)
    case unsafeRemoval(String)
    case lockFailed(path: String, errorNumber: Int32)

    var description: String {
        switch self {
        case .invalidArguments(let message):
            return message
        case .invalidIdentifier(let name, let value):
            return "\(name) contains unsupported characters: \(value)"
        case .missingPath(let path):
            return "required path is missing: \(path)"
        case .invalidPath(let path):
            return "invalid path: \(path)"
        case .commandFailed(let executable, let arguments, let status, let stderr):
            let detail = stderr.isEmpty ? "" : ": \(stderr)"
            return "command failed (\(status)): \(([executable] + arguments).joined(separator: " "))\(detail)"
        case .invalidCompiler(let message):
            return "selected Swift compiler is incompatible: \(message)"
        case .invalidMetadata(let message):
            return "invalid Swift SDK metadata: \(message)"
        case .brokenLink(let link, let target):
            return "symbolic link is broken: \(link) -> \(target)"
        case .escapedBundle(let link, let target):
            return "symbolic link escapes the artifact bundle: \(link) -> \(target)"
        case .unsafeRemoval(let path):
            return "refusing to remove unexpected path: \(path)"
        case .lockFailed(let path, let errorNumber):
            return "could not acquire staging lock at \(path) (errno \(errorNumber))"
        }
    }
}
