import CPicoExternalBuildSupport
import Foundation

@main
struct CPicoFirmwareFinalizerAdapter {
    struct EmbeddedResource: Encodable {
        let name: String
        let path: String
    }

    struct FinalizationRequest: Encodable {
        let schemaVersion = 1
        let productName: String
        let productArchivePath: String
        let nativeSupportArchivePath: String?
        let pioasmPackageDirectoryPath: String?
        let outputDirectoryPath: String
        let workingDirectoryPath: String
        let cmakeHarnessDirectoryPath: String
        let packageDirectoryPath: String
        let cpicoSDKDirectoryPath: String
        let memoryMapToolPath: String
        let swiftBuildType: String
        let platformTriple: String
        let embeddedResources: [EmbeddedResource]
        let incremental: Bool
        let environment: [String: String]
    }

    struct Options {
        let productName: String
        let packageDirectory: URL
        let cpicoSDKDirectory: URL
        let cmakeHarnessDirectory: URL
        let workingDirectory: URL
        let finalizerTool: URL
        let memoryMapTool: URL
        let configuration: URL?
        let embeddedResources: [EmbeddedResource]

        init(arguments: [String]) throws {
            var values: [String: String] = [:]
            var configuration: URL?
            var resources: [EmbeddedResource] = []
            var index = 0

            func value(after option: String) throws -> String {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw AdapterError.missingOptionValue(option)
                }
                return arguments[valueIndex]
            }

            while index < arguments.count {
                let option = arguments[index]
                switch option {
                case "--configuration":
                    configuration = URL(
                        fileURLWithPath: try value(after: option),
                        isDirectory: false
                    )
                    index += 2
                case "--embedded-resource":
                    let name = try value(after: option)
                    let pathIndex = index + 2
                    guard pathIndex < arguments.count else {
                        throw AdapterError.missingOptionValue(option)
                    }
                    resources.append(EmbeddedResource(
                        name: name,
                        path: arguments[pathIndex]
                    ))
                    index += 3
                case "--product-name", "--package-directory",
                     "--cpicosdk-directory", "--cmake-harness-directory",
                     "--working-directory", "--finalizer-tool",
                     "--memory-map-tool":
                    values[option] = try value(after: option)
                    index += 2
                default:
                    throw AdapterError.unknownOption(option)
                }
            }

            func required(_ option: String) throws -> String {
                guard let value = values[option], !value.isEmpty else {
                    throw AdapterError.missingOptionValue(option)
                }
                return value
            }
            func fileURL(_ option: String, isDirectory: Bool) throws -> URL {
                URL(
                    fileURLWithPath: try required(option),
                    isDirectory: isDirectory
                ).standardizedFileURL
            }

            self.productName = try required("--product-name")
            self.packageDirectory = try fileURL(
                "--package-directory",
                isDirectory: true
            )
            self.cpicoSDKDirectory = try fileURL(
                "--cpicosdk-directory",
                isDirectory: true
            )
            self.cmakeHarnessDirectory = try fileURL(
                "--cmake-harness-directory",
                isDirectory: true
            )
            self.workingDirectory = try fileURL(
                "--working-directory",
                isDirectory: true
            )
            self.finalizerTool = try fileURL(
                "--finalizer-tool",
                isDirectory: false
            )
            self.memoryMapTool = try fileURL(
                "--memory-map-tool",
                isDirectory: false
            )
            self.configuration = configuration
            self.embeddedResources = resources
        }
    }

    enum AdapterError: Swift.Error, CustomStringConvertible {
        case finalizerFailed(Int32)
        case invalidPIOASMPath(String)
        case missingEnvironment(String)
        case missingOptionValue(String)
        case unknownOption(String)

        var description: String {
            switch self {
            case .finalizerFailed(let status):
                return "FirmwareFinalizerTool failed with exit status \(status)."
            case .invalidPIOASMPath(let path):
                return "The external native build reported an invalid pioasm package path: \(path)"
            case .missingEnvironment(let name):
                return "The post-product build task is missing environment variable \(name)."
            case .missingOptionValue(let option):
                return "Expected a value after \(option)."
            case .unknownOption(let option):
                return "Unknown option: \(option)"
            }
        }
    }

    static func main() throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        let processEnvironment = ProcessInfo.processInfo.environment
        let productArchive = try requiredEnvironment(
            "SWIFT_PRODUCT_PATH",
            in: processEnvironment,
            isDirectory: false
        )
        let outputDirectory = try requiredEnvironment(
            "SWIFT_EXTERNAL_OUTPUT_DIR",
            in: processEnvironment,
            isDirectory: true
        )
        let nativeArchive = try requiredEnvironment(
            "CPICOSDK_NATIVE_SUPPORT_ARCHIVE",
            in: processEnvironment,
            isDirectory: false
        )
        let pioasmPathFile = try requiredEnvironment(
            "CPICOSDK_PIOASM_PACKAGE_PATH_FILE",
            in: processEnvironment,
            isDirectory: false
        )
        let pioasmDirectory = try readPIOASMDirectory(from: pioasmPathFile)
        let resolution = try ExternalBuildEnvironmentResolver(
            processEnvironment: processEnvironment,
            configurationURL: options.configuration,
            cpicoSDKDirectory: options.cpicoSDKDirectory
        ).resolve()

        try FileManager.default.createDirectory(
            at: options.workingDirectory,
            withIntermediateDirectories: true
        )
        let request = FinalizationRequest(
            productName: options.productName,
            productArchivePath: productArchive.path,
            nativeSupportArchivePath: nativeArchive.path,
            pioasmPackageDirectoryPath: pioasmDirectory.path,
            outputDirectoryPath: outputDirectory.path,
            workingDirectoryPath: options.workingDirectory.path,
            cmakeHarnessDirectoryPath: options.cmakeHarnessDirectory.path,
            packageDirectoryPath: options.packageDirectory.path,
            cpicoSDKDirectoryPath: options.cpicoSDKDirectory.path,
            memoryMapToolPath: options.memoryMapTool.path,
            swiftBuildType: resolution.swiftBuildType,
            platformTriple: resolution.platformTriple,
            embeddedResources: options.embeddedResources,
            incremental: resolution.incremental,
            environment: resolution.environment
        )
        let requestURL = options.workingDirectory.appendingPathComponent(
            "post-product-finalization-request.json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: requestURL, options: .atomic)

        print("[CPicoSDK] Swift product is ready; generating firmware artifacts.")
        let process = Process()
        process.executableURL = options.finalizerTool
        process.arguments = ["--request", requestURL.path]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AdapterError.finalizerFailed(process.terminationStatus)
        }
    }

    private static func requiredEnvironment(
        _ name: String,
        in environment: [String: String],
        isDirectory: Bool
    ) throws -> URL {
        guard let value = environment[name], !value.isEmpty else {
            throw AdapterError.missingEnvironment(name)
        }
        return URL(
            fileURLWithPath: value,
            isDirectory: isDirectory
        ).standardizedFileURL
    }

    private static func readPIOASMDirectory(from sidecar: URL) throws -> URL {
        let value = try String(contentsOf: sidecar, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = URL(
            fileURLWithPath: value,
            isDirectory: true
        ).standardizedFileURL
        guard value.hasPrefix("/"),
              !value.contains(";"),
              FileManager.default.isExecutableFile(
                atPath: directory.appendingPathComponent("pioasm").path
              )
        else {
            throw AdapterError.invalidPIOASMPath(value)
        }
        return directory
    }
}
