import Foundation

private struct SDKLayout: Decodable {
    let picotoolPath: String
}

private enum FlashError: Swift.Error, CustomStringConvertible {
    case invalidLayout(String)
    case invalidOption(String)
    case missingArtifact(String)
    case missingOption(String)
    case missingTool(String)
    case processFailed([String], Int32)
    case tooManyArtifacts([String])
    case unavailableDevice(waitSeconds: Double, diagnostic: String)
    case unknownOption(String)

    var description: String {
        switch self {
        case .invalidLayout(let path):
            return "Invalid CPicoSDK Swift SDK layout at \(path)."
        case .invalidOption(let message):
            return message
        case .missingArtifact(let path):
            return "No matching firmware artifact was found under \(path)."
        case .missingOption(let option):
            return "Missing required option \(option)."
        case .missingTool(let path):
            return "picotool is unavailable at \(path)."
        case .processFailed(let command, let status):
            return "Command failed with status \(status): \(command.joined(separator: " "))"
        case .tooManyArtifacts(let paths):
            return "More than one matching firmware artifact was found: \(paths.joined(separator: ", "))"
        case .unavailableDevice(let waitSeconds, let diagnostic):
            let detail = diagnostic.isEmpty ? "" : " Last picotool result: \(diagnostic)"
            return "No uniquely selectable device became available within \(waitSeconds) seconds.\(detail)"
        case .unknownOption(let option):
            return "Unknown option \(option)."
        }
    }
}

@main
private struct CPicoFlashTool {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("[CPicoSDK] \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
        let packageDirectory = try required("--package-directory", in: options)
        let scratchPath = try required("--scratch-path", in: options)
        let swiftSDKsPath = try required("--swift-sdks-path", in: options)
        let product = try required("--product", in: options)
        let configuration = try required("--configuration", in: options).lowercased()
        let waitValue = try required("--wait-seconds", in: options)
        guard let waitSeconds = Double(waitValue),
              waitSeconds > 0,
              waitSeconds <= 3_600
        else {
            throw FlashError.invalidOption(
                "--wait-seconds must be greater than zero and no more than 3600."
            )
        }
        let selector = options["--serial"].map { ["--ser", $0] } ?? []

        let sdkBundle = URL(fileURLWithPath: swiftSDKsPath, isDirectory: true)
            .appendingPathComponent(
                "cpicosdk-rp2xxx.artifactbundle",
                isDirectory: true
            )
        let layoutURL = sdkBundle.appendingPathComponent("cpicosdk-layout.json")
        guard let layout = try? JSONDecoder().decode(
            SDKLayout.self,
            from: Data(contentsOf: layoutURL)
        ) else {
            throw FlashError.invalidLayout(layoutURL.path)
        }
        let picotool = sdkBundle.appendingPathComponent(layout.picotoolPath)
        guard FileManager.default.isExecutableFile(atPath: picotool.path) else {
            throw FlashError.missingTool(picotool.path)
        }

        let productsDirectory = URL(
            fileURLWithPath: scratchPath,
            isDirectory: true
        ).appendingPathComponent("out/Products", isDirectory: true)
        let candidates = firmwareCandidates(
            under: productsDirectory,
            product: product,
            configuration: configuration
        )
        guard let firmware = candidates.first else {
            throw FlashError.missingArtifact(productsDirectory.path)
        }
        guard candidates.count == 1 else {
            throw FlashError.tooManyArtifacts(candidates.map(\.path))
        }

        print("[CPicoSDK] Waiting up to \(waitSeconds) seconds for a device in BOOTSEL mode...")
        let deadline = Date().addingTimeInterval(waitSeconds)
        var lastDiagnostic = ""
        while true {
            let probe = try runCapturing(
                [picotool.path, "info", "--device"] + selector
            )
            if probe.status == 0 {
                break
            }
            lastDiagnostic = probe.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard Date() < deadline else {
                throw FlashError.unavailableDevice(
                    waitSeconds: waitSeconds,
                    diagnostic: lastDiagnostic
                )
            }
            Thread.sleep(forTimeInterval: 2)
        }
        // `load` is a single-device picotool command: without an explicit
        // serial it refuses an ambiguous device set before modifying flash.
        try requireSuccess(
            [picotool.path, "load", "--verify", firmware.path] + selector
        )
        try requireSuccess([picotool.path, "reboot"] + selector)
        print("[CPicoSDK] Flashed \(firmware.path) from \(packageDirectory).")
    }

    private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--") else {
                throw FlashError.unknownOption(option)
            }
            guard index + 1 < arguments.count else {
                throw FlashError.missingOption(option)
            }
            result[option] = arguments[index + 1]
            index += 2
        }
        return result
    }

    private static func required(
        _ option: String,
        in options: [String: String]
    ) throws -> String {
        guard let value = options[option], !value.isEmpty else {
            throw FlashError.missingOption(option)
        }
        return value
    }

    private static func firmwareCandidates(
        under directory: URL,
        product: String,
        configuration: String
    ) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL,
                  url.lastPathComponent == "\(product).uf2",
                  url.deletingLastPathComponent().lastPathComponent
                    .lowercased().hasPrefix("\(configuration)-"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true
            else {
                return nil
            }
            return url
        }.sorted { $0.path < $1.path }
    }

    private static func requireSuccess(_ command: [String]) throws {
        let status = try run(command)
        guard status == 0 else {
            throw FlashError.processFailed(command, status)
        }
    }

    private static func run(_ command: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func runCapturing(
        _ command: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }
}
