import Foundation
import PicoBuildConfigurationCore

@main
struct PicoBuildConfigurationTool {
    static func main() {
        do {
            var arguments = CommandLine.arguments.dropFirst().makeIterator()
            guard let mode = arguments.next(), ["prepare", "build"].contains(mode) else {
                throw ConfigurationError("Expected prepare or build configuration mode.")
            }
            var options: [String: String] = [:]
            let allowed = mode == "prepare" ? ["--request", "--output"]
                : ["--defaults", "--installation", "--archive", "--output", "--triple", "--configuration"]
            while let key = arguments.next() {
                guard let value = arguments.next(), allowed.contains(key), !value.hasPrefix("--"),
                      options.updateValue(value, forKey: key) == nil else {
                    throw ConfigurationError("Invalid or duplicate option: \(key)")
                }
            }
            func required(_ key: String) throws -> String {
                guard let value = options[key], !value.isEmpty else { throw ConfigurationError("Missing \(key)") }
                return value
            }
            func read<T: Decodable>(_ key: String, as: T.Type) throws -> T {
                try JSONDecoder().decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: required(key))))
            }
            let output = URL(fileURLWithPath: try required("--output"))
            if mode == "prepare" {
                let request = try read("--request", as: PreparationRequest.self)
                try ConfigurationResolver.writeJSON(ConfigurationResolver.prepare(request), to: output)
                return
            }
            let defaults = try read("--defaults", as: ConfigurationDefaults.self)
            let installation = try read("--installation", as: BuildInstallation.self)
            let environment = ProcessInfo.processInfo.environment
            let nm = installation.metadataInspectorPath
            guard FileManager.default.isExecutableFile(atPath: nm) else {
                throw ConfigurationError("Missing metadata inspection tool: \(nm). Run explicit preparation; swift build does not install tools.")
            }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: nm)
            process.arguments = [try required("--archive")]
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let symbols = String(data: data, encoding: .utf8) else {
                throw ConfigurationError("Unable to inspect configuration archive with \(nm).")
            }
            let configuration = try ConfigurationResolver.resolveBuild(
                defaults: defaults, installation: installation, symbols: symbols,
                overrides: environment.filter { ["AUTO_STDIO", "BUILD_TYPE", "CPICOSDK_CORE0_STACK_SIZE_BYTES", "CPICOSDK_CORE1_STACK_SIZE_BYTES"].contains($0.key) },
                triple: required("--triple"), configuration: required("--configuration")
            )
            try ConfigurationResolver.validateInstallation(configuration.variables)
            try ConfigurationResolver.writeJSON(configuration, to: output)
            print("[CPicoSDK] Resolved build configuration for \(configuration.board).")
        } catch {
            FileHandle.standardError.write(Data("[CPicoSDK] \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
