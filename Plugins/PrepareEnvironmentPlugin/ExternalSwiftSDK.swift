import Foundation
import PackagePlugin

extension PrepareEnvironmentPlugin {
    private struct ExternalSwiftSDKStageResult: Decodable {
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

    func stageExternalSwiftSDK(
        context: PackagePlugin.PluginContext,
        cPicoSDKPackageURL: URL,
        envVars: [String: String]
    ) async throws {
        let packageURL = context.package.directoryURL
        let givenEnvironment = ProcessInfo.processInfo.environment
        let stagingRoot = self.absoluteURL(
            givenEnvironment["CPICOSDK_SWIFT_SDKS_PATH"]
                ?? givenEnvironment["CPICOSDK_SWIFT_SDK_STAGING_ROOT"]
                ?? packageURL.appending(path: ".build/swift-sdk-staging").path,
            relativeTo: packageURL
        )
        let resultFile = context.pluginWorkDirectoryURL
            .appending(path: "generated/external-swift-sdk-stage.json")
        let tool = try context.tool(named: "CPicoSDKEnvironmentTool")

        func required(_ key: String) -> String {
            guard let value = envVars[key], !value.isEmpty else {
                fatalError("[CPicoSDK] Missing \(key) while staging the Swift SDK.")
            }
            return value
        }

        var toolArguments = [
            "stage",
            "--template-directory",
            cPicoSDKPackageURL.appending(path: "SwiftSDK/ExternalPreviewSDK").path,
            "--staging-root",
            stagingRoot.path,
            "--pico-sdk-bundle",
            required("PICO_SDK_BUNDLE_PATH"),
            "--result-file",
            resultFile.path,
            "--sdk-version",
            required("SDK_VERSION"),
            "--toolchain-version",
            required("TOOLCHAIN_VERSION"),
            "--cmake-version",
            required("CMAKE_VERSION"),
            "--ninja-version",
            required("NINJA_VERSION"),
            "--picotool-version",
            required("PICOTOOL_VERSION"),
            "--openocd-version",
            required("OPENOCD_VERSION"),
            "--bundle-version",
            givenEnvironment["CPICOSDK_SWIFT_SDK_BUNDLE_VERSION"] ?? required("SDK_VERSION"),
        ]
        if givenEnvironment["CPICOSDK_REQUIRE_RP2040_CONCURRENCY"] == "1" {
            toolArguments.append("--require-rp2040-concurrency")
        }

        print("[CPicoSDK] Staging the relocatable CPico RP2 Swift SDK...")
        let process = Process()
        process.executableURL = tool.url
        process.arguments = toolArguments
        let status = try await process.asyncRun()
        guard status == 0 else {
            fatalError("[CPicoSDK] Swift SDK staging failed with exit code \(status).")
        }

        let result: ExternalSwiftSDKStageResult
        do {
            result = try JSONDecoder().decode(
                ExternalSwiftSDKStageResult.self,
                from: Data(contentsOf: resultFile)
            )
        } catch {
            fatalError("[CPicoSDK] Couldn't read Swift SDK staging result at \(resultFile.path): \(error)")
        }
        guard result.schemaVersion == 1 else {
            fatalError("[CPicoSDK] Unsupported Swift SDK staging result schema \(result.schemaVersion).")
        }

        let sdkID: String
        switch required("SWIFTPM_TRIPLE") {
        case "armv6m-none-none-eabi":
            sdkID = "cpicosdk-rp2040"
        case "armv7em-none-none-eabi":
            sdkID = "cpicosdk-rp2350"
        default:
            fatalError("[CPicoSDK] No staged Swift SDK matches \(required("SWIFTPM_TRIPLE")).")
        }
        guard result.sdkIDs.contains(sdkID) else {
            fatalError("[CPicoSDK] Staged bundle does not publish expected SDK ID \(sdkID).")
        }

        self.appendExport("CPICOSDK_SWIFT_SDKS_PATH", value: result.swiftSDKsPath)
        self.appendExport("CPICOSDK_SWIFT_SDK_ID", value: sdkID)
        self.appendExport("CPICOSDK_SWIFT_SDK_ARTIFACT_BUNDLE", value: result.artifactBundlePath)
        self.appendExport(
            "CPICOSDK_SWIFT_EXECUTABLE",
            value: result.swiftCompilerExecutable
        )
        self.appendExport("CPICOSDK_SWIFT_COMPILER_VERSION", value: result.swiftCompilerVersion)
        self.appendExport("CPICOSDK_SWIFT_HOST_TRIPLE", value: result.hostTriple)
        self.appendExport(
            "CPICOSDK_RP2040_CONCURRENCY_SUPPORTED",
            value: result.rp2040ConcurrencySupported ? "1" : "0"
        )
        self.appendExport(
            "CPICOSDK_RP2350_CONCURRENCY_SUPPORTED",
            value: result.rp2350ConcurrencySupported ? "1" : "0"
        )
        self.appendExport("CPICOSDK_ROOT", value: cPicoSDKPackageURL.standardizedFileURL.path)

        let configuration = givenEnvironment["CPICOSDK_BUILD_CONFIGURATION"]
            .map { self.absoluteURL($0, relativeTo: packageURL) }
            ?? packageURL.appending(path: "cpicosdk-build.json")
        if FileManager.default.fileExists(atPath: configuration.path) {
            self.appendExport(
                "CPICOSDK_BUILD_CONFIGURATION",
                value: configuration.standardizedFileURL.path
            )
        }
    }

    func appendExternalBuildInvocationConfiguration(arguments: [String]) {
        let usesUART = arguments.contains("--cortex-debug")
        self.appendExport("AUTO_STDIO", value: usesUART ? "uart" : "usb")
        self.appendExport("CPICO_EXTERNAL_STDIO_RTT", value: "0")
        self.appendExport("CPICO_EXTERNAL_STDIO_UART", value: usesUART ? "1" : "0")
        self.appendExport("CPICO_EXTERNAL_STDIO_USB", value: usesUART ? "0" : "1")
    }

    private func absoluteURL(_ path: String, relativeTo base: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return base.appending(path: path).standardizedFileURL
    }

    func appendExport(_ name: String, value: String) {
        // POSIX-shell single quoting, including paths with spaces, dollar signs,
        // quotes, or other characters that must not be reinterpreted on source.
        let quoted = "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        self.output += "export \(name)=\(quoted)\n"
    }
}
