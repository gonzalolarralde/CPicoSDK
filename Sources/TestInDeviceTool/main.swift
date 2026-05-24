import Foundation
import TestInDeviceCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct TestInDeviceTool {
    static func main() throws {
        let rawArguments = CommandLine.arguments
        let arguments = rawArguments.count > 1 ? Array(rawArguments[1...]) : []
        let options = try Options.parse(arguments)
        let runner = DeviceHarnessRunner(options: options)
        let ok = try runner.run()
        if !ok {
            Foundation.exit(1)
        }
    }
}

struct Options {
    var packageDirectory: URL
    var workDirectory: URL
    var cpicoSDKPath: URL
    var filter: String?
    var listOnly: Bool
    var buildOnly: Bool
    var adapterSpeed: Int
    var target: DeviceTestTarget

    static func parse(_ arguments: [String]) throws -> Options {
        var packageDirectory: URL?
        var workDirectory: URL?
        var cpicoSDKPath: URL?
        var filter: String?
        var listOnly = false
        var buildOnly = false
        var adapterSpeed = 5_000
        var target = DeviceTestTarget.rp2350
        var index = arguments.startIndex

        func takeValue(for option: String) throws -> String {
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                throw DeviceTestHarnessError.invalidMetadata("missing value for \(option)")
            }
            index = valueIndex
            return arguments[index]
        }

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--package-dir":
                packageDirectory = URL(fileURLWithPath: try takeValue(for: argument), isDirectory: true)
            case "--work-dir":
                workDirectory = URL(fileURLWithPath: try takeValue(for: argument), isDirectory: true)
            case "--cpicosdk-path":
                cpicoSDKPath = URL(fileURLWithPath: try takeValue(for: argument), isDirectory: true)
            case "--filter":
                filter = try takeValue(for: argument)
            case "--list":
                listOnly = true
            case "--build-only":
                buildOnly = true
            case "--adapter-speed":
                adapterSpeed = Int(try takeValue(for: argument)) ?? adapterSpeed
            case "--target", "--device":
                target = try DeviceTestTarget(argument: try takeValue(for: argument))
            case "--allow-writing-to-package-directory", "--disable-sandbox":
                break
            case "--allow-network-connections":
                _ = try takeValue(for: argument)
            case "--help", "-h":
                print(Self.help)
                Foundation.exit(0)
            default:
                throw DeviceTestHarnessError.invalidMetadata("unknown argument \(argument)")
            }
            index = arguments.index(after: index)
        }

        guard let packageDirectory, let workDirectory, let cpicoSDKPath else {
            throw DeviceTestHarnessError.invalidMetadata("--package-dir, --work-dir, and --cpicosdk-path are required")
        }

        return Options(
            packageDirectory: packageDirectory,
            workDirectory: workDirectory,
            cpicoSDKPath: cpicoSDKPath,
            filter: filter,
            listOnly: listOnly,
            buildOnly: buildOnly,
            adapterSpeed: adapterSpeed,
            target: target
        )
    }

    static let help = """
    Usage: swift package test-in-device [--target rp2350|rp2040] [--filter NAME] [--list] [--build-only] [--adapter-speed HZ]

    Tests are discovered under Tests/Device/**/*.swift. Each file must start with a //% metadata block.
    """
}

struct DeviceHarnessRunner {
    var options: Options

    func run() throws -> Bool {
        let files = DeviceTestParser.discoverFiles(packageDirectory: options.packageDirectory)
        if files.isEmpty {
            log("[test-in-device] No device tests found under \(options.packageDirectory.appendingPathComponent("Tests/Device").path).")
            let exampleDeviceTests = options.packageDirectory
                .appendingPathComponent("Example/Tests/Device", isDirectory: true)
            if FileManager.default.fileExists(atPath: exampleDeviceTests.path) {
                log("[test-in-device] Found Example/Tests/Device; run this command from Example/ for device tests.")
            }
            return true
        }

        var tests = try files.map(DeviceTestParser.load(fileURL:))
        if let filter = options.filter {
            tests = tests.filter { $0.metadata.name.contains(filter) || $0.fileURL.lastPathComponent.contains(filter) }
        }

        if tests.isEmpty {
            log("[test-in-device] No device tests matched filter.")
            return true
        }

        if options.listOnly {
            for test in tests {
                log(test.metadata.name)
            }
            return true
        }

        let generatedRoot = options.workDirectory
            .appendingPathComponent("GeneratedDeviceTests", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedRoot, withIntermediateDirectories: true)
        if let sharedBundle = try resolvedSharedPicoSDKBundlePath() {
            log("[test-in-device] Using shared Pico SDK bundle: \(sharedBundle.path)")
        } else {
            log("[test-in-device] No prepared shared Pico SDK bundle found; generated packages will prepare dependencies independently.")
        }

        var allPassed = true
        for (index, test) in tests.enumerated() {
            let startedAt = Date()
            logPartial("[test-in-device] \(index + 1)/\(tests.count) \(test.metadata.name)")
            if test.metadata.concurrency && !options.target.supportsConcurrency {
                logLine(" SKIP: target \(options.target.rawValue) does not support concurrency")
                continue
            }
            do {
                let generated = try DevicePackageGenerator.generate(
                    source: test,
                    cpicoSDKPath: options.cpicoSDKPath,
                    outputRoot: generatedRoot,
                    target: options.target,
                    packageDirectoryName: "Current"
                )
                let buildStartedAt = Date()
                let firmware = try build(generated: generated)
                let buildElapsed = Date().timeIntervalSince(buildStartedAt)
                let firmwareSize = firmwareSizeLabel(url: firmware.uf2URL)
                if options.buildOnly {
                    logLine(" (build=\(formatDuration(buildElapsed))) - \(formatElapsed(since: startedAt)) - \(firmwareSize) BUILT \(firmware.uf2URL.path)")
                    continue
                }
                let runResult = try runOnDevice(
                    elfURL: firmware.elfURL,
                    packageDirectory: generated.packageDirectory,
                    timeoutMilliseconds: test.metadata.timeoutMilliseconds
                )
                let transcript = runResult.transcript
                let evaluation = DeviceResultParser.evaluate(transcript: transcript, expectations: test.metadata.expectations)
                let timing = " (build=\(formatDuration(buildElapsed)); program=\(formatDuration(runResult.burnElapsed)); run=\(formatDuration(runResult.captureElapsed)); device=\(formatDeviceMilliseconds(transcript.durationMilliseconds))) - \(formatElapsed(since: startedAt)) - \(firmwareSize)"
                if evaluation.passed {
                    logLine("\(timing) PASS")
                    logFunctionDurations(transcript.functionDurations)
                } else {
                    allPassed = false
                    logLine("\(timing) FAIL: \(evaluation.reason ?? "unknown failure")")
                    logFunctionDurations(transcript.functionDurations)
                    if !transcript.stdout.isEmpty {
                        log("[test-in-device] Captured stdout:\n\(transcript.stdout)")
                    }
                }
            } catch {
                allPassed = false
                logLine(" total \(formatElapsed(since: startedAt)) FAIL: \(error)")
            }
        }
        return allPassed
    }

    private func build(generated: GeneratedPackage) throws -> BuiltFirmware {
        let sharedBundleExport = try sharedPicoSDKBundleExportScript()
        let script = """
        set -euo pipefail
        cd \(shellQuote(generated.packageDirectory.path))
        export BUILD_TYPE="RelWithDebInfo"
        export BOARD="\(options.target.board)"
        export BUILD_SCRIPT_VERSION=1
        \(sharedBundleExport)
        export PREPARATION_SCRIPT_PATH="\(generated.packageDirectory.path)/.env_prep"
        export PREPARATION_BUNDLE_STAMP="$PREPARATION_SCRIPT_PATH.pico-sdk-bundle-path"
        export GENERATED_INPUTS_CHANGED="\(generated.inputsChanged ? "1" : "0")"
        PREPARATION_INPUTS_CHANGED="$GENERATED_INPUTS_CHANGED"
        if [ ! -f "$PREPARATION_BUNDLE_STAMP" ] || [ "$(cat "$PREPARATION_BUNDLE_STAMP")" != "${PICO_SDK_BUNDLE_PATH:-}" ]; then
          PREPARATION_INPUTS_CHANGED="1"
        fi
        if command -v swiftly >/dev/null 2>&1; then
          export SWIFTLY_PATH="$(command -v swiftly)"
        elif [ -f "$HOME/.swiftly/bin/swiftly" ]; then
          export SWIFTLY_PATH="$HOME/.swiftly/bin/swiftly"
        elif [ -f "$HOME/.local/share/swiftly/bin/swiftly" ]; then
          export SWIFTLY_PATH="$HOME/.local/share/swiftly/bin/swiftly"
        else
          echo "swiftly not found in PATH."
          exit 1
        fi

        if [ "$PREPARATION_INPUTS_CHANGED" = "1" ] || [ ! -f "$PREPARATION_SCRIPT_PATH" ] || [ \(shellQuote(options.cpicoSDKPath.appendingPathComponent("env.json").path)) -nt "$PREPARATION_SCRIPT_PATH" ]; then
          "$SWIFTLY_PATH" run swift package prepare-rp2xxx-environment \\
            --cpicosdk-envs-path \(shellQuote(options.cpicoSDKPath.appendingPathComponent("env.json").path)) \\
            --dump-prep-script "$PREPARATION_SCRIPT_PATH" \\
            --allow-writing-to-package-directory \\
            --allow-network-connections all \\
            --disable-vscode-settings \\
            --disable-sourcekit-lsp-settings
          printf '%s' "${PICO_SDK_BUNDLE_PATH:-}" > "$PREPARATION_BUNDLE_STAMP"
        fi
        source "$PREPARATION_SCRIPT_PATH"
        "$SWIFTLY_PATH" install
        "$SWIFTLY_PATH" run swift build \\
          --build-system native \\
          --configuration $SWIFT_BUILD_TYPE \\
          --toolset $TOOLSET_PATH \\
          --triple $SWIFTPM_TRIPLE \\
          $EXTRA_CONFIG_PARAMS
        LIB_PATH=".build/${SWIFTPM_TRIPLE}/${SWIFT_BUILD_TYPE}/lib\(generated.productName).a"
        ELF_PATH=".build/${SWIFTPM_TRIPLE}/${SWIFT_BUILD_TYPE}/\(generated.productName).elf"
        if [ ! -f "$ELF_PATH" ] || [ "$LIB_PATH" -nt "$ELF_PATH" ]; then
          finalize_rp2xxx_binary \(generated.productName) --incremental
        fi
        find .build -path "*/\(generated.productName).elf" -print -quit
        """

        let result = try ProcessRunner.run("/bin/bash", arguments: ["-lc", script], workingDirectory: generated.packageDirectory)
        guard result.status == 0 else {
            throw DeviceTestHarnessError.processFailed(command: "build \(generated.packageDirectory.path)", status: result.status, output: result.output)
        }

        let foundELF = result.output.split(whereSeparator: \.isNewline).map(String.init).last { $0.hasSuffix(".elf") }
        if let foundELF {
            let path = foundELF.hasPrefix("/") ? foundELF : generated.packageDirectory.appendingPathComponent(foundELF).path
            let elfURL = URL(fileURLWithPath: path)
            return BuiltFirmware(elfURL: elfURL, uf2URL: try findUF2(for: elfURL, generated: generated))
        }
        return BuiltFirmware(
            elfURL: generated.elfURL,
            uf2URL: try findUF2(for: generated.elfURL, generated: generated)
        )
    }

    private func findUF2(for elfURL: URL, generated: GeneratedPackage) throws -> URL {
        let siblingUF2 = elfURL.deletingPathExtension().appendingPathExtension("uf2")
        if isRegularFile(siblingUF2) {
            return siblingUF2
        }
        let buildDirectory = generated.packageDirectory.appendingPathComponent(".build", isDirectory: true)
        if let uf2URL = findFirstOptional(
            under: buildDirectory,
            matching: { $0.lastPathComponent == "\(generated.productName).uf2" && isRegularFile($0) }
        ) {
            return uf2URL
        }
        throw DeviceTestHarnessError.missingArtifact("\(generated.productName).uf2 under \(buildDirectory.path)")
    }

    private func sharedPicoSDKBundleExportScript() throws -> String {
        if ProcessInfo.processInfo.environment["PICO_SDK_BUNDLE_PATH"] != nil {
            return "export PICO_SDK_BUNDLE_PATH"
        }
        if let bundlePath = try resolvedSharedPicoSDKBundlePath() {
            return "export PICO_SDK_BUNDLE_PATH=\(shellQuote(bundlePath.path))"
        }
        return ": PICO_SDK_BUNDLE_PATH intentionally unset"
    }

    private func resolvedSharedPicoSDKBundlePath() throws -> URL? {
        if let provided = ProcessInfo.processInfo.environment["PICO_SDK_BUNDLE_PATH"], !provided.isEmpty {
            return URL(fileURLWithPath: provided, isDirectory: true)
        }
        for candidate in sharedPicoSDKBundleCandidates() {
            if try picoSDKBundleIsComplete(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func sharedPicoSDKBundleCandidates() -> [URL] {
        [
            options.packageDirectory
                .appendingPathComponent(".build/plugins/PrepareEnvironmentPlugin/outputs/pico-sdk-bundle", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".pico-sdk", isDirectory: true),
        ]
    }

    private func picoSDKBundleIsComplete(_ url: URL) throws -> Bool {
        let vars = try cpicoSDKEnvVars()
        let required = [
            "sdk/\(vars["SDK_VERSION"] ?? "")",
            "toolchain/\(vars["TOOLCHAIN_VERSION"] ?? "")",
            "cmake/v\(vars["CMAKE_VERSION"] ?? "")",
            "ninja/v\(vars["NINJA_VERSION"] ?? "")",
            "picotool/\(vars["PICOTOOL_VERSION"] ?? "")",
            "openocd/\(vars["OPENOCD_VERSION"] ?? "")",
        ]
        return required.allSatisfy { relativePath in
            FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path)
        }
    }

    private func cpicoSDKEnvVars() throws -> [String: String] {
        let envURL = options.cpicoSDKPath.appendingPathComponent("env.json")
        let data = try Data(contentsOf: envURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vars = object["vars"] as? [String: String] else {
            throw DeviceTestHarnessError.invalidMetadata("invalid env.json at \(envURL.path)")
        }
        return vars
    }

    private func runOnDevice(elfURL: URL, packageDirectory: URL, timeoutMilliseconds: Int) throws -> DeviceRunResult {
        let paths = try discoverOpenOCDPaths(packageDirectory: packageDirectory)
        let ports = OpenOCDPorts()
        let openOCD = Process()
        openOCD.executableURL = paths.executable
        openOCD.arguments = OpenOCDCommandBuilder.arguments(
            paths: paths,
            elfURL: elfURL,
            ports: ports,
            adapterSpeed: options.adapterSpeed,
            target: options.target
        )

        let openOCDPipe = Pipe()
        let openOCDOutput = LockedOutput()
        openOCDPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            openOCDOutput.append(data)
        }
        openOCD.standardOutput = openOCDPipe
        openOCD.standardError = openOCDPipe
        let burnStartedAt = Date()
        do {
            try openOCD.run()
        } catch {
            throw DeviceTestHarnessError.processFailed(
                command: paths.executable.path,
                status: -1,
                output: "\(error)"
            )
        }
        defer {
            openOCDPipe.fileHandleForReading.readabilityHandler = nil
            if openOCD.isRunning {
                openOCD.terminate()
                openOCD.waitUntilExit()
            }
        }

        try waitForRTTServer(openOCD: openOCD, output: openOCDOutput, rttPort: ports.rtt)
        let burnElapsed = Date().timeIntervalSince(burnStartedAt)
        let capture = RTTCapture(port: ports.rtt)
        let captureStartedAt = Date()
        let raw = try capture.capture(timeoutMilliseconds: timeoutMilliseconds) {
            DeviceResultParser.parse($0).sawRunEnd
        }
        let captureElapsed = Date().timeIntervalSince(captureStartedAt)
        return DeviceRunResult(
            transcript: DeviceResultParser.parse(raw),
            burnElapsed: burnElapsed,
            captureElapsed: captureElapsed
        )
    }

    private func waitForRTTServer(openOCD: Process, output: LockedOutput, rttPort: Int) throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !openOCD.isRunning {
                throw DeviceTestHarnessError.processFailed(
                    command: "openocd",
                    status: openOCD.terminationStatus,
                    output: output.string()
                )
            }

            let current = output.string()
            if current.contains("Listening on port \(rttPort)") || current.contains("port \(rttPort) for rtt") {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if !openOCD.isRunning {
            throw DeviceTestHarnessError.processFailed(
                command: "openocd",
                status: openOCD.terminationStatus,
                output: output.string()
            )
        }
    }

    private func discoverOpenOCDPaths(packageDirectory: URL) throws -> OpenOCDPaths {
        let environment = try preparedEnvironment(packageDirectory: packageDirectory)
        let openOCDPath = try requiredEnvironmentValue("OPENOCD_PATH", in: environment)
        let openOCDRoot = URL(fileURLWithPath: openOCDPath, isDirectory: true)
        let executableCandidates = [
            openOCDRoot.appendingPathComponent("openocd.exe"),
            openOCDRoot.appendingPathComponent("openocd"),
        ]
        guard let openocd = executableCandidates.first(where: { isRegularFile($0) }) else {
            throw DeviceTestHarnessError.missingTool(executableCandidates.map(\.path).joined(separator: ", "))
        }
        let scripts = openOCDRoot.appendingPathComponent("scripts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: scripts.path) else {
            throw DeviceTestHarnessError.missingTool(scripts.path)
        }
        let helper = findFirstOptional(
            under: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".vscode/extensions", isDirectory: true),
            matching: { $0.lastPathComponent == "openocd-helpers.tcl" }
        )
        return OpenOCDPaths(executable: openocd, scriptsDirectory: scripts, helpersScript: helper)
    }

    private func preparedEnvironment(packageDirectory: URL) throws -> [String: String] {
        let prepScript = packageDirectory.appendingPathComponent(".env_prep")
        let script = """
        set -euo pipefail
        source \(shellQuote(prepScript.path))
        /usr/bin/env -0
        """
        let result = try ProcessRunner.run("/bin/bash", arguments: ["-lc", script], workingDirectory: packageDirectory)
        guard result.status == 0 else {
            throw DeviceTestHarnessError.processFailed(command: "source \(prepScript.path)", status: result.status, output: result.output)
        }
        var environment: [String: String] = [:]
        for assignment in result.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) {
            guard let equals = assignment.firstIndex(of: "=") else {
                continue
            }
            let key = String(assignment[..<equals])
            environment[key] = String(assignment[assignment.index(after: equals)...])
        }
        return environment
    }

    private func requiredEnvironmentValue(_ name: String, in environment: [String: String]) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            throw DeviceTestHarnessError.missingTool("environment value \(name)")
        }
        return value
    }

    private func findFirst(under roots: [URL], matching predicate: (URL) -> Bool) throws -> URL {
        for root in roots {
            if let url = findFirstOptional(under: root, matching: predicate) {
                return url
            }
        }
        throw DeviceTestHarnessError.missingTool(roots.map(\.path).joined(separator: ", "))
    }

    private func findFirst(under root: URL, matching predicate: (URL) -> Bool) throws -> URL {
        guard let url = findFirstOptional(under: root, matching: predicate) else {
            throw DeviceTestHarnessError.missingTool(root.path)
        }
        return url
    }

    private func findFirstOptional(under root: URL, matching predicate: (URL) -> Bool) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where predicate(url) {
            return url
        }
        return nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }
}

func formatElapsed(since start: Date) -> String {
    formatDuration(Date().timeIntervalSince(start))
}

func formatDuration(_ seconds: TimeInterval) -> String {
    return String(format: "%.2fs", seconds)
}

func formatDeviceMilliseconds(_ milliseconds: Int?) -> String {
    guard let milliseconds else {
        return "unknown"
    }
    return "\(milliseconds)ms"
}

func firmwareSizeLabel(url: URL) -> String {
    "(uf2=\(firmwareSizeKilobytes(url)))"
}

func firmwareSizeKilobytes(_ url: URL) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let bytes = attributes[.size] as? NSNumber else {
        return "unknownkb"
    }
    let kilobytes = Int((bytes.doubleValue / 1024.0).rounded(.up))
    return "\(kilobytes)kb"
}

func logFunctionDurations(_ durations: [DeviceFunctionDuration]) {
    for duration in durations {
        let status = duration.passed ? "PASS" : "FAIL"
        log("[test-in-device]   \(duration.name): \(duration.durationMilliseconds)ms \(status)")
    }
}

func log(_ message: String) {
    ImmediateLogger.shared.write(message)
}

func logPartial(_ message: String) {
    ImmediateLogger.shared.write(message, terminator: "")
}

func logLine(_ message: String) {
    ImmediateLogger.shared.write(message)
}

final class ImmediateLogger: @unchecked Sendable {
    static let shared = ImmediateLogger()

    private let tty: FileHandle?

    private init() {
        if isatty(STDOUT_FILENO) == 0 {
            tty = FileHandle(forWritingAtPath: "/dev/tty")
        } else {
            tty = nil
        }
    }

    func write(_ message: String, terminator: String = "\n") {
        let data = Data("\(message)\(terminator)".utf8)
        if let tty {
            tty.write(data)
            return
        }
        FileHandle.standardOutput.write(data)
    }
}

struct DeviceRunResult {
    var transcript: DeviceTranscript
    var burnElapsed: TimeInterval
    var captureElapsed: TimeInterval
}

struct BuiltFirmware {
    var elfURL: URL
    var uf2URL: URL
}

struct ProcessResult {
    var status: Int32
    var output: String
}

enum ProcessRunner {
    static func run(_ executable: String, arguments: [String], workingDirectory: URL? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw DeviceTestHarnessError.processFailed(
                command: ([executable] + arguments).joined(separator: " "),
                status: -1,
                output: "\(error)"
            )
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}

final class RTTCapture {
    let port: Int

    init(port: Int) {
        self.port = port
    }

    func capture(timeoutMilliseconds: Int, until shouldStop: @escaping (String) -> Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "until /usr/bin/nc 127.0.0.1 \(port); do sleep 0.05; done"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let output = LockedOutput()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.append(data)
        }

        do {
            try process.run()
        } catch {
            throw DeviceTestHarnessError.processFailed(
                command: "/bin/bash -lc until /usr/bin/nc 127.0.0.1 \(port)",
                status: -1,
                output: "\(error)"
            )
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000.0)
        while Date() < deadline {
            let current = output.string()
            if shouldStop(current) {
                return current
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return output.string()
    }
}

final class LockedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let current = data
        lock.unlock()
        return String(data: current, encoding: .utf8) ?? ""
    }
}

func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
