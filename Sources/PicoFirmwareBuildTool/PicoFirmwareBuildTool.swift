import Foundation

struct FirmwareRequest {
    enum Phase: String, CaseIterable {
        case all
        case sdk
        case link
    }

    let phase: Phase
    let product: String
    let archive: URL
    let configurationArchive: URL
    let sdkArtifactsDirectory: URL?
    let outputDirectory: URL
    let workDirectory: URL
    let sdkDirectory: URL
    let resources: [URL]
    let clean: Bool

    init(arguments: [String]) throws {
        let options: Set<String> = [
            "--product", "--archive", "--output-directory", "--work-directory",
            "--sdk-directory", "--phase", "--configuration-archive", "--sdk-artifacts-directory",
        ]
        var values: [String: String] = [:]
        var resources: [URL] = []
        var clean = false
        var iterator = arguments.makeIterator()
        while let option = iterator.next() {
            if option == "--clean" { clean = true; continue }
            guard options.contains(option) || option == "--resource",
                  let value = iterator.next(), !value.hasPrefix("--") else {
                throw RequestError.invalidOption(option)
            }
            if option == "--resource" {
                resources.append(URL(fileURLWithPath: value))
            } else {
                guard values.updateValue(value, forKey: option) == nil else {
                    throw RequestError.invalidOption(option)
                }
            }
        }
        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else { throw RequestError.missingOption(key) }
            return value
        }
        product = try required("--product")
        guard !product.contains("/"), !product.contains("\\"), product != ".", product != ".." else {
            throw RequestError.invalidOption("--product")
        }
        archive = URL(fileURLWithPath: try required("--archive"))
        configurationArchive = values["--configuration-archive"].map { URL(fileURLWithPath: $0) } ?? archive
        sdkArtifactsDirectory = values["--sdk-artifacts-directory"].map { URL(fileURLWithPath: $0) }
        outputDirectory = URL(fileURLWithPath: try required("--output-directory"))
        workDirectory = URL(fileURLWithPath: try required("--work-directory"))
        sdkDirectory = URL(fileURLWithPath: try required("--sdk-directory"))
        guard let phase = Phase(rawValue: values["--phase"] ?? "all"),
              phase != .link || !clean else {
            throw RequestError.invalidOption("--phase (expected all, sdk, or link; link cannot use --clean)")
        }
        self.phase = phase
        if phase == .link && sdkArtifactsDirectory == nil {
            throw RequestError.missingOption("--sdk-artifacts-directory")
        }
        self.resources = resources
        self.clean = clean
    }

    enum RequestError: Error, CustomStringConvertible, LocalizedError {
        case invalidOption(String)
        case missingOption(String)

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case .invalidOption(let name): return "Invalid or duplicate firmware build option: \(name)"
            case .missingOption(let name): return "Missing firmware build option: \(name)"
            }
        }
    }
}

@main
struct PicoFirmwareBuildTool {
    static func main() async {
        do {
            let request = try FirmwareRequest(arguments: Array(CommandLine.arguments.dropFirst()))
            try FileManager.default.createDirectory(at: request.workDirectory, withIntermediateDirectories: true)
            try await FirmwareBuilder().build(request)
        } catch {
            FileHandle.standardError.write(Data("[CPicoSDK] \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
