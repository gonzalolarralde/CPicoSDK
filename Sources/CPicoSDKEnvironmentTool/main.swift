import Foundation

private let usage = """
Usage: CPicoSDKEnvironmentTool stage [options]

Required options:
  --template-directory <path>
  --staging-root <path>
  --pico-sdk-bundle <path>
  --result-file <path>
  --sdk-version <version>
  --toolchain-version <version>
  --cmake-version <version>
  --ninja-version <version>
  --picotool-version <version>
  --openocd-version <version>

Optional:
  --bundle-version <version>       Defaults to --sdk-version.
  --require-rp2040-concurrency

Compiler selection is controlled by CPICOSDK_SWIFT, or by a Swiftly selector
from CPICOSDK_SWIFT_TOOLCHAIN, SWIFTPM_PREVIEW_TOOLCHAIN, or the template's
swift-toolchain.txt file (in that order).
"""

private func parseOptions(_ arguments: ArraySlice<String>) throws -> StageOptions {
    var values: [String: String] = [:]
    var flags = Set<String>()
    var index = arguments.startIndex
    while index < arguments.endIndex {
        let argument = arguments[index]
        if argument == "--require-rp2040-concurrency" {
            flags.insert(argument)
            index = arguments.index(after: index)
            continue
        }
        guard argument.hasPrefix("--") else {
            throw EnvironmentToolError.invalidArguments("unexpected argument: \(argument)\n\n\(usage)")
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw EnvironmentToolError.invalidArguments("missing value for \(argument)\n\n\(usage)")
        }
        values[argument] = arguments[valueIndex]
        index = arguments.index(after: valueIndex)
    }

    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw EnvironmentToolError.invalidArguments("missing \(name)\n\n\(usage)")
        }
        return value
    }

    let sdkVersion = try required("--sdk-version")
    return StageOptions(
        templateDirectory: URL(fileURLWithPath: try required("--template-directory"), isDirectory: true),
        stagingRoot: URL(fileURLWithPath: try required("--staging-root"), isDirectory: true),
        picoSDKBundle: URL(fileURLWithPath: try required("--pico-sdk-bundle"), isDirectory: true),
        resultFile: URL(fileURLWithPath: try required("--result-file")),
        sdkVersion: sdkVersion,
        toolchainVersion: try required("--toolchain-version"),
        cmakeVersion: try required("--cmake-version"),
        ninjaVersion: try required("--ninja-version"),
        picotoolVersion: try required("--picotool-version"),
        openocdVersion: try required("--openocd-version"),
        bundleVersion: values["--bundle-version"] ?? sdkVersion,
        requireRP2040Concurrency: flags.contains("--require-rp2040-concurrency")
    )
}

do {
    let arguments = CommandLine.arguments.dropFirst()
    if arguments.first == "--help" || arguments.first == "-h" {
        print(usage)
        exit(0)
    }
    guard arguments.first == "stage" else {
        throw EnvironmentToolError.invalidArguments(usage)
    }
    let options = try parseOptions(arguments.dropFirst())
    let result = try SwiftSDKStager(options: options).stage()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var resultData = try encoder.encode(result)
    resultData.append(0x0A)
    try FileManager.default.createDirectory(
        at: options.resultFile.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try resultData.write(to: options.resultFile, options: .atomic)
    print("[CPicoSDK] Swift SDK IDs: \(result.sdkIDs.joined(separator: ", "))")
    print("[CPicoSDK] Swift SDK search path: \(result.swiftSDKsPath)")
} catch {
    FileHandle.standardError.write(Data("[CPicoSDK] \(error)\n".utf8))
    exit(1)
}
