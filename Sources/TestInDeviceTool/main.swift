import Foundation
import TestInDeviceCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct TestInDeviceTool {
    static func main() async throws {
        let rawArguments = CommandLine.arguments
        let arguments = rawArguments.count > 1 ? Array(rawArguments[1...]) : []
        let options = try Options.parse(arguments)
        let runner = DeviceHarnessRunner(options: options)
        let ok = try await runner.run()
        if !ok {
            Foundation.exit(1)
        }
    }
}

enum DeviceExecutionMode: String {
    case local
    case remote

    init(_ value: String) throws {
        guard let mode = Self(rawValue: value.lowercased()) else {
            throw DeviceTestHarnessError.invalidMetadata(
                "unknown execution mode '\(value)'; expected local or remote"
            )
        }
        self = mode
    }
}

struct Options {
    var packageDirectory: URL
    var workDirectory: URL
    var cpicoSDKPath: URL
    var filter: String?
    var listOnly: Bool
    var buildOnly: Bool
    var memoryMapReport: Bool
    var memoryMapToolPath: String?
    var passes: Int
    var adapterSpeed: Int
    var target: DeviceTestTarget
    var buildTypeOverride: DeviceBuildType?
    var executionMode: DeviceExecutionMode
    var hardwareRunnerURL: URL?
    var hardwareRunnerToken: String?
    var hardwareRunnerProfileID: UUID?
    var hardwareRunnerPoolID: UUID?
    var hardwareRunnerCapabilities: [String]
    var hardwareRunnerCaptureChannel: String

    static func parse(_ arguments: [String]) throws -> Options {
        let environment = ProcessInfo.processInfo.environment
        var packageDirectory: URL?
        var workDirectory: URL?
        var cpicoSDKPath: URL?
        var filter: String?
        var listOnly = false
        var buildOnly = false
        var memoryMapReport = false
        var memoryMapToolPath: String?
        var passes = 1
        var adapterSpeed = 5_000
        var target = DeviceTestTarget.rp2350
        var buildTypeOverride: DeviceBuildType?
        var executionMode = try DeviceExecutionMode(
            nonEmpty(environment["CPICOSDK_DEVICE_TEST_EXECUTION"]) ?? "remote"
        )
        var hardwareRunnerURL = try parseURL(
            nonEmpty(environment["HARDWARE_RUNNER_URL"])
                ?? nonEmpty(environment["CPICOSDK_HARDWARE_RUNNER_URL"]),
            option: "HARDWARE_RUNNER_URL"
        )
        var hardwareRunnerToken = nonEmpty(environment["HARDWARE_RUNNER_TOKEN"])
            ?? nonEmpty(environment["CPICOSDK_HARDWARE_RUNNER_TOKEN"])
        var hardwareRunnerProfileID = try parseUUID(
            nonEmpty(environment["HARDWARE_RUNNER_PROFILE_ID"])
                ?? nonEmpty(environment["CPICOSDK_HARDWARE_RUNNER_PROFILE_ID"]),
            option: "HARDWARE_RUNNER_PROFILE_ID"
        )
        var hardwareRunnerPoolID = try parseUUID(
            nonEmpty(environment["HARDWARE_RUNNER_POOL_ID"])
                ?? nonEmpty(environment["CPICOSDK_HARDWARE_RUNNER_POOL_ID"]),
            option: "HARDWARE_RUNNER_POOL_ID"
        )
        var hardwareRunnerCapabilities = commaSeparated(
            environment["HARDWARE_RUNNER_CAPABILITIES"]
                ?? environment["CPICOSDK_HARDWARE_RUNNER_CAPABILITIES"]
        )
        var hardwareRunnerCaptureChannel = nonEmpty(
            environment["HARDWARE_RUNNER_CAPTURE_CHANNEL"]
                ?? environment["CPICOSDK_HARDWARE_RUNNER_CAPTURE_CHANNEL"]
        ) ?? "rtt"
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
            case "--memory-map-report":
                memoryMapReport = true
            case "--memory-map-tool":
                memoryMapToolPath = try takeValue(for: argument)
            case "--passes":
                passes = max(1, Int(try takeValue(for: argument)) ?? passes)
            case "--adapter-speed":
                adapterSpeed = Int(try takeValue(for: argument)) ?? adapterSpeed
            case "--target", "--device":
                target = try DeviceTestTarget(argument: try takeValue(for: argument))
            case "--build-type":
                buildTypeOverride = try DeviceBuildType(metadataValue: try takeValue(for: argument))
            case "--execution":
                executionMode = try DeviceExecutionMode(try takeValue(for: argument))
            case "--local":
                executionMode = .local
            case "--remote":
                executionMode = .remote
            case "--hardware-runner-url":
                hardwareRunnerURL = try parseURL(
                    try takeValue(for: argument),
                    option: argument
                )
            case "--hardware-runner-token":
                hardwareRunnerToken = try takeValue(for: argument)
            case "--hardware-runner-profile-id":
                hardwareRunnerProfileID = try parseUUID(
                    try takeValue(for: argument),
                    option: argument
                )
            case "--hardware-runner-pool-id":
                hardwareRunnerPoolID = try parseUUID(
                    try takeValue(for: argument),
                    option: argument
                )
            case "--hardware-runner-capabilities":
                hardwareRunnerCapabilities = commaSeparated(try takeValue(for: argument))
            case "--hardware-runner-capture-channel":
                hardwareRunnerCaptureChannel = try takeValue(for: argument)
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
        if hardwareRunnerCapabilities.isEmpty {
            hardwareRunnerCapabilities = [
                target.rawValue,
                "cmsis-dap",
                "rtt",
            ]
        }
        guard !hardwareRunnerCaptureChannel.isEmpty else {
            throw DeviceTestHarnessError.invalidMetadata(
                "--hardware-runner-capture-channel cannot be empty"
            )
        }

        return Options(
            packageDirectory: packageDirectory,
            workDirectory: workDirectory,
            cpicoSDKPath: cpicoSDKPath,
            filter: filter,
            listOnly: listOnly,
            buildOnly: buildOnly,
            memoryMapReport: memoryMapReport,
            memoryMapToolPath: memoryMapToolPath,
            passes: passes,
            adapterSpeed: adapterSpeed,
            target: target,
            buildTypeOverride: buildTypeOverride,
            executionMode: executionMode,
            hardwareRunnerURL: hardwareRunnerURL,
            hardwareRunnerToken: hardwareRunnerToken,
            hardwareRunnerProfileID: hardwareRunnerProfileID,
            hardwareRunnerPoolID: hardwareRunnerPoolID,
            hardwareRunnerCapabilities: hardwareRunnerCapabilities,
            hardwareRunnerCaptureChannel: hardwareRunnerCaptureChannel
        )
    }

    static let help = """
    Usage: swift package test-in-device [--execution remote|local] [--target rp2350|rp2040] [--build-type Debug|Release|RelWithDebInfo|MinSizeRel] [--filter NAME] [--list] [--build-only] [--passes N] [--adapter-speed HZ] [--memory-map-report]

    Tests are discovered under Tests/Device/**/*.swift. Each file must start with a //% metadata block.
    Execution defaults to remote. Configure HardwareRunner with HARDWARE_RUNNER_URL,
    HARDWARE_RUNNER_TOKEN, HARDWARE_RUNNER_PROFILE_ID, and optionally
    HARDWARE_RUNNER_POOL_ID/HARDWARE_RUNNER_CAPABILITIES and
    HARDWARE_RUNNER_CAPTURE_CHANNEL. Use --local to run directly through this
    host's OpenOCD installation.
    """

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func parseURL(_ value: String?, option: String) throws -> URL? {
        guard let value = nonEmpty(value) else {
            return nil
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            throw DeviceTestHarnessError.invalidMetadata(
                "\(option) must be an absolute HTTP or HTTPS URL"
            )
        }
        return url
    }

    private static func parseUUID(_ value: String?, option: String) throws -> UUID? {
        guard let value = nonEmpty(value) else {
            return nil
        }
        guard let uuid = UUID(uuidString: value) else {
            throw DeviceTestHarnessError.invalidMetadata(
                "\(option) must be a UUID"
            )
        }
        return uuid
    }

    private static func commaSeparated(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

struct DeviceHarnessRunner {
    var options: Options

    func run() async throws -> Bool {
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

        var tests = try files.map(DeviceTestParser.load(fileURL:)).flatMap(expandedAlternatives(for:))
        if let buildTypeOverride = options.buildTypeOverride {
            tests = tests.map { source in
                var source = source
                source.metadata.buildType = buildTypeOverride
                return source
            }
        }
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
        if !options.buildOnly {
            switch options.executionMode {
            case .local:
                log("[test-in-device] Device execution: local OpenOCD")
            case .remote:
                let configuration = try hardwareRunnerConfiguration()
                log("[test-in-device] Device execution: \(configuration)")
            }
        }

        if options.executionMode == .remote && !options.buildOnly {
            return try await runRemoteBatch(
                tests: tests,
                generatedRoot: generatedRoot
            )
        }
        return try runSequentially(
            tests: tests,
            generatedRoot: generatedRoot
        )
    }

    private func runSequentially(
        tests: [DeviceTestSource],
        generatedRoot: URL
    ) throws -> Bool {
        var allPassed = true
        for (index, test) in tests.enumerated() {
            let startedAt = Date()
            logPartial("[test-in-device] \(index + 1)/\(tests.count) \(terminalBoldYellow(test.metadata.name))")
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
                let firmware = try build(generated: generated, buildType: test.metadata.buildType)
                let buildElapsed = Date().timeIntervalSince(buildStartedAt)
                let firmwareSize = firmwareSizeLabel(url: firmware.uf2URL)
                let memoryMapReport = options.memoryMapReport
                    ? try makeMemoryMapReport(for: firmware, generated: generated)
                    : nil
                if options.buildOnly {
                    logLine(" (build=\(formatDuration(buildElapsed))) - \(formatElapsed(since: startedAt)) - \(firmwareSize) BUILT \(firmware.uf2URL.path)")
                    logMemoryMapReport(memoryMapReport)
                    continue
                }
                var scoreSamples: [DeviceScore] = []
                let passCount = options.passes
                for pass in 1...passCount {
                    let runResult = try runLocally(
                        elfURL: firmware.elfURL,
                        packageDirectory: generated.packageDirectory,
                        timeoutMilliseconds: test.metadata.timeoutMilliseconds
                    )
                    let report = report(
                        runResult: runResult,
                        test: test,
                        pass: pass,
                        passCount: passCount,
                        buildElapsed: buildElapsed,
                        startedAt: startedAt,
                        firmwareSize: firmwareSize
                    )
                    scoreSamples.append(contentsOf: report.scores)
                    if !report.passed {
                        allPassed = false
                    }
                }
                logScoreStatistics(scoreSamples, passCount: passCount)
                logMemoryMapReport(memoryMapReport)
            } catch {
                allPassed = false
                logLine(" total \(formatElapsed(since: startedAt)) \(terminalRed("FAIL")): \(error)")
            }
        }
        return allPassed
    }

    private func runRemoteBatch(
        tests: [DeviceTestSource],
        generatedRoot: URL
    ) async throws -> Bool {
        let stagingDirectory = generatedRoot
            .appendingPathComponent("RemoteBatchArtifacts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer {
            // This directory is unique to this invocation and contains only
            // copies made below. No local consumer needs those copies after
            // this batch returns or fails.
            try? FileManager.default.removeItem(at: stagingDirectory)
        }

        var allPassed = true
        var builtTests: [RemoteBuiltDeviceTest] = []
        for (index, test) in tests.enumerated() {
            let startedAt = Date()
            logPartial(
                "[test-in-device] \(index + 1)/\(tests.count) "
                    + terminalBoldYellow(test.metadata.name)
            )
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
                let firmware = try build(
                    generated: generated,
                    buildType: test.metadata.buildType
                )
                let buildElapsed = Date().timeIntervalSince(buildStartedAt)
                let memoryMapReport = options.memoryMapReport
                    ? try makeMemoryMapReport(for: firmware, generated: generated)
                    : nil
                let stagedFirmware = try stage(
                    firmware: firmware,
                    index: index,
                    in: stagingDirectory
                )
                let firmwareSize = firmwareSizeLabel(url: stagedFirmware.uf2URL)
                builtTests.append(RemoteBuiltDeviceTest(
                    index: index,
                    source: test,
                    startedAt: startedAt,
                    buildElapsed: buildElapsed,
                    firmware: stagedFirmware,
                    firmwareSize: firmwareSize,
                    memoryMapReport: memoryMapReport
                ))
                logLine(
                    " (build=\(formatDuration(buildElapsed))) - "
                        + "\(formatElapsed(since: startedAt)) - \(firmwareSize) "
                        + "STAGED"
                )
            } catch {
                allPassed = false
                logLine(
                    " total \(formatElapsed(since: startedAt)) "
                        + "\(terminalRed("FAIL")): \(error)"
                )
            }
        }

        let remoteInputs = builtTests.flatMap { built in
            (1...options.passes).map { pass in
                HardwareRunnerExecutionInput(
                    callerItemID: remoteCallerItemID(
                        testIndex: built.index,
                        pass: pass
                    ),
                    firmwareURL: built.firmware.elfURL,
                    testName: options.passes == 1
                        ? built.source.metadata.name
                        : "\(built.source.metadata.name)-pass-\(pass)",
                    timeoutMilliseconds:
                        built.source.metadata.timeoutMilliseconds
                )
            }
        }
        guard !remoteInputs.isEmpty else {
            return allPassed
        }

        log(
            "[test-in-device] Submitting \(remoteInputs.count) work item(s) "
                + "as one fair HardwareRunner job."
        )
        let remoteResults: [HardwareRunnerBatchExecutionResult]
        do {
            remoteResults = try await HardwareRunnerClient(
                configuration: try hardwareRunnerConfiguration()
            ).execute(inputs: remoteInputs)
        } catch {
            log("[test-in-device] Remote batch \(terminalRed("FAIL")): \(error)")
            return false
        }
        guard remoteResults.count == remoteInputs.count else {
            log(
                "[test-in-device] Remote batch \(terminalRed("FAIL")): "
                    + "result count did not match submitted work items"
            )
            return false
        }
        let resultByCallerID = Dictionary(
            uniqueKeysWithValues: remoteResults.map {
                ($0.callerItemID, $0.outcome)
            }
        )

        for built in builtTests {
            var scoreSamples: [DeviceScore] = []
            for pass in 1...options.passes {
                let callerItemID = remoteCallerItemID(
                    testIndex: built.index,
                    pass: pass
                )
                guard let outcome = resultByCallerID[callerItemID] else {
                    allPassed = false
                    log(
                        "[test-in-device] \(built.source.metadata.name) "
                            + "\(terminalRed("FAIL")): missing remote result "
                            + callerItemID
                    )
                    continue
                }
                let result: HardwareRunnerExecutionResult
                switch outcome {
                case .success(let execution):
                    result = execution
                case .failure(let error):
                    allPassed = false
                    let passLabel = options.passes > 1
                        ? " pass \(pass)/\(options.passes)"
                        : ""
                    log(
                        "[test-in-device] \(built.source.metadata.name)"
                            + "\(passLabel) [\(callerItemID)] "
                            + "\(terminalRed("FAIL")): \(error)"
                    )
                    continue
                }
                logPartial(
                    "[test-in-device] \(built.index + 1)/\(tests.count) "
                        + terminalBoldYellow(built.source.metadata.name)
                )
                let report = report(
                    runResult: DeviceRunResult(
                        rawOutput: result.rawOutput,
                        queueElapsed: result.queueElapsed,
                        programElapsed: result.programElapsed ?? 0,
                        captureElapsed: result.captureElapsed ?? 0
                    ),
                    test: built.source,
                    pass: pass,
                    passCount: options.passes,
                    buildElapsed: built.buildElapsed,
                    startedAt: built.startedAt,
                    firmwareSize: built.firmwareSize
                )
                scoreSamples.append(contentsOf: report.scores)
                if !report.passed {
                    allPassed = false
                }
            }
            logScoreStatistics(scoreSamples, passCount: options.passes)
            logMemoryMapReport(built.memoryMapReport)
        }
        return allPassed
    }

    private func stage(
        firmware: BuiltFirmware,
        index: Int,
        in directory: URL
    ) throws -> BuiltFirmware {
        let basename = String(format: "%04d", index + 1)
        let elfURL = directory
            .appendingPathComponent(basename)
            .appendingPathExtension("elf")
        let uf2URL = directory
            .appendingPathComponent(basename)
            .appendingPathExtension("uf2")
        try FileManager.default.copyItem(at: firmware.elfURL, to: elfURL)
        try FileManager.default.copyItem(at: firmware.uf2URL, to: uf2URL)
        return BuiltFirmware(elfURL: elfURL, uf2URL: uf2URL)
    }

    private func remoteCallerItemID(testIndex: Int, pass: Int) -> String {
        "test-\(testIndex + 1)-pass-\(pass)"
    }

    private func report(
        runResult: DeviceRunResult,
        test: DeviceTestSource,
        pass: Int,
        passCount: Int,
        buildElapsed: TimeInterval,
        startedAt: Date,
        firmwareSize: String
    ) -> DeviceRunReport {
        let transcript = DeviceResultParser.parse(
            String(decoding: runResult.rawOutput, as: UTF8.self)
        )
        let evaluation = DeviceResultParser.evaluate(
            transcript: transcript,
            expectations: test.metadata.expectations
        )
        let passLabel = passCount > 1 ? "; pass=\(pass)/\(passCount)" : ""
        let queueLabel = runResult.queueElapsed.map {
            "; queue=\(formatDuration($0))"
        } ?? ""
        let timing =
            " (build=\(formatDuration(buildElapsed))\(queueLabel); "
            + "program=\(formatDuration(runResult.programElapsed)); "
            + "run=\(formatDuration(runResult.captureElapsed)); "
            + "device=\(formatDeviceMilliseconds(transcript.durationMilliseconds))"
            + "\(passLabel)) - \(formatElapsed(since: startedAt)) - "
            + firmwareSize
        if evaluation.passed {
            logLine("\(timing) \(terminalGreen("PASS"))")
            if passCount == 1 {
                logFunctionDurations(transcript.functionDurations)
                logDiagnostics(transcript.diagnostics)
            }
        } else {
            logLine(
                "\(timing) \(terminalRed("FAIL")): "
                    + (evaluation.reason ?? "unknown failure")
            )
            logFunctionDurations(transcript.functionDurations)
            logDiagnostics(transcript.diagnostics)
            if !transcript.stdout.isEmpty {
                log("[test-in-device] Captured stdout:\n\(transcript.stdout)")
            }
        }
        return DeviceRunReport(
            passed: evaluation.passed,
            scores: transcript.scores
        )
    }

    private func logDiagnostics(_ diagnostics: [String]) {
        guard !diagnostics.isEmpty else {
            return
        }
        let coloredDiagnostics = diagnostics
            .map(colorDiagnosticScores)
            .joined(separator: "\n")
        log("[test-in-device] Diagnostics:\n\(coloredDiagnostics)\n")
    }

    private func expandedAlternatives(for source: DeviceTestSource) -> [DeviceTestSource] {
        guard !source.metadata.alternatives.isEmpty else {
            return [source]
        }

        return source.metadata.alternatives.map { alternative in
            var expanded = source
            var metadata = source.metadata
            metadata.name = "\(metadata.name)-\(alternative.name)"
            if let timeoutMilliseconds = alternative.timeoutMilliseconds {
                metadata.timeoutMilliseconds = timeoutMilliseconds
            }
            if let buildType = alternative.buildType {
                metadata.buildType = buildType
            }
            if let concurrency = alternative.concurrency {
                metadata.concurrency = concurrency
            }
            metadata.traits = TraitSelection(
                add: metadata.traits.add + alternative.traits.add,
                remove: metadata.traits.remove + alternative.traits.remove
            )
            metadata.swiftDefines += alternative.swiftDefines
            metadata.alternatives = []
            expanded.metadata = metadata
            return expanded
        }
    }

    private func logScoreStatistics(_ scores: [DeviceScore], passCount: Int) {
        guard !scores.isEmpty else {
            return
        }

        let grouped = Dictionary(grouping: scores) { score in
            ScoreKey(metric: score.metric, score: score.score, context: score.context)
        }
        let lines = grouped.keys.sorted().map { key -> String in
            let samples = grouped[key] ?? []
            let values = samples.map(\.value).sorted()
            let average = values.reduce(0, +) / Double(values.count)
            let p95 = percentile(values, percentile: 0.95)
            let minValue = values.first ?? 0
            let maxValue = values.last ?? 0
            let latestRaw = samples.last?.rawLine ?? ""
            return "  \(key.metric) \(key.score): count=\(terminalSkyBlue("\(values.count)/\(passCount)")), avg=\(coloredScoreValue(average)), p95=\(coloredScoreValue(p95)), min=\(coloredScoreValue(minValue)), max=\(coloredScoreValue(maxValue)) \(key.context) latestRaw=\"\(latestRaw)\""
        }
        log("[test-in-device] Score statistics:\n\(lines.joined(separator: "\n"))\n")
    }

    private func makeMemoryMapReport(for firmware: BuiltFirmware, generated: GeneratedPackage) throws -> String {
        guard let memoryMapToolPath = options.memoryMapToolPath else {
            throw DeviceTestHarnessError.invalidMetadata("--memory-map-report requires the TestInDevice plugin-provided --memory-map-tool path")
        }
        let result = try ProcessRunner.run(
            memoryMapToolPath,
            arguments: [
                "--package-dir", generated.packageDirectory.path,
                "--cpicosdk-path", options.cpicoSDKPath.path,
                "--elf", firmware.elfURL.path,
                "--no-sections",
            ],
            workingDirectory: generated.packageDirectory
        )
        guard result.status == 0 else {
            throw DeviceTestHarnessError.processFailed(command: "memory-map-report \(firmware.elfURL.path)", status: result.status, output: result.output)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func logMemoryMapReport(_ report: String?) {
        guard let report else {
            return
        }
        log("\n\(report)\n")
    }

    private func build(generated: GeneratedPackage, buildType: DeviceBuildType) throws -> BuiltFirmware {
        let sharedBundleExport = try sharedPicoSDKBundleExportScript()
        let cpicoSDKEnvVars = try cpicoSDKEnvVars()
        let core0StackSize = cpicoSDKEnvVars["CPICOSDK_CORE0_STACK_SIZE_BYTES"] ?? "8192"
        let core1StackSize = cpicoSDKEnvVars["CPICOSDK_CORE1_STACK_SIZE_BYTES"] ?? "8192"
        let script = """
        set -euo pipefail
        cd \(shellQuote(generated.packageDirectory.path))
        export BUILD_TYPE="\(buildType.rawValue)"
        export BOARD="\(options.target.board)"
        export CPICOSDK_CORE0_STACK_SIZE_BYTES="${CPICOSDK_CORE0_STACK_SIZE_BYTES:-\(core0StackSize)}"
        export CPICOSDK_CORE1_STACK_SIZE_BYTES="${CPICOSDK_CORE1_STACK_SIZE_BYTES:-\(core1StackSize)}"
        export BUILD_SCRIPT_VERSION=1
        \(sharedBundleExport)
        export PREPARATION_SCRIPT_PATH="\(generated.packageDirectory.path)/.env_prep"
        export PREPARATION_BUNDLE_STAMP="$PREPARATION_SCRIPT_PATH.pico-sdk-bundle-path"
        export PREPARATION_BUILD_TYPE_STAMP="$PREPARATION_SCRIPT_PATH.build-type"
        export PREPARATION_STACK_SIZE_STAMP="$PREPARATION_SCRIPT_PATH.stack-sizes"
        export GENERATED_INPUTS_CHANGED="\(generated.inputsChanged ? "1" : "0")"
        STACK_SIZE_SIGNATURE="$CPICOSDK_CORE0_STACK_SIZE_BYTES:$CPICOSDK_CORE1_STACK_SIZE_BYTES"
        PREPARATION_INPUTS_CHANGED="$GENERATED_INPUTS_CHANGED"
        if [ ! -f "$PREPARATION_BUNDLE_STAMP" ] || [ "$(cat "$PREPARATION_BUNDLE_STAMP")" != "${PICO_SDK_BUNDLE_PATH:-}" ]; then
          PREPARATION_INPUTS_CHANGED="1"
        fi
        if [ ! -f "$PREPARATION_BUILD_TYPE_STAMP" ] || [ "$(cat "$PREPARATION_BUILD_TYPE_STAMP")" != "$BUILD_TYPE" ]; then
          PREPARATION_INPUTS_CHANGED="1"
        fi
        if [ ! -f "$PREPARATION_STACK_SIZE_STAMP" ] || [ "$(cat "$PREPARATION_STACK_SIZE_STAMP")" != "$STACK_SIZE_SIGNATURE" ]; then
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
          printf '%s' "$BUILD_TYPE" > "$PREPARATION_BUILD_TYPE_STAMP"
          printf '%s' "$STACK_SIZE_SIGNATURE" > "$PREPARATION_STACK_SIZE_STAMP"
        fi
        source "$PREPARATION_SCRIPT_PATH"
        "$SWIFTLY_PATH" install
        "$SWIFTLY_PATH" run swift build \\
          --build-system native \\
          --configuration $SWIFT_BUILD_TYPE \\
          --toolset "$TOOLSET_PATH" \\
          --triple $SWIFTPM_TRIPLE \\
          $EXTRA_CONFIG_PARAMS
        LIB_PATH=".build/${SWIFTPM_TRIPLE}/${SWIFT_BUILD_TYPE}/lib\(generated.productName).a"
        ELF_PATH=".build/${SWIFTPM_TRIPLE}/${SWIFT_BUILD_TYPE}/\(generated.productName).elf"
        if [ "$PREPARATION_INPUTS_CHANGED" = "1" ] || [ ! -f "$ELF_PATH" ] || [ "$LIB_PATH" -nt "$ELF_PATH" ]; then
          finalize_rp2xxx_binary \(generated.productName) --incremental
        fi
        printf '%s\\n' "$ELF_PATH"
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

    private func hardwareRunnerConfiguration() throws -> HardwareRunnerClientConfiguration {
        var missing: [String] = []
        if options.hardwareRunnerURL == nil {
            missing.append("HARDWARE_RUNNER_URL/--hardware-runner-url")
        }
        if options.hardwareRunnerToken == nil {
            missing.append("HARDWARE_RUNNER_TOKEN/--hardware-runner-token")
        }
        if options.hardwareRunnerProfileID == nil {
            missing.append(
                "HARDWARE_RUNNER_PROFILE_ID/--hardware-runner-profile-id"
            )
        }
        guard missing.isEmpty,
              let baseURL = options.hardwareRunnerURL,
              let token = options.hardwareRunnerToken,
              let profileID = options.hardwareRunnerProfileID
        else {
            throw DeviceTestHarnessError.invalidMetadata(
                "remote execution is the default and requires "
                    + missing.joined(separator: ", ")
                    + "; use --local for direct OpenOCD execution"
            )
        }
        return try HardwareRunnerClientConfiguration(
            baseURL: baseURL,
            token: token,
            profileID: profileID,
            poolID: options.hardwareRunnerPoolID,
            capabilities: options.hardwareRunnerCapabilities,
            captureChannel: options.hardwareRunnerCaptureChannel
        )
    }

    private func runLocally(
        elfURL: URL,
        packageDirectory: URL,
        timeoutMilliseconds: Int
    ) throws -> DeviceRunResult {
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
            rawOutput: Data(raw.utf8),
            queueElapsed: nil,
            programElapsed: burnElapsed,
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

func percentile(_ sortedValues: [Double], percentile: Double) -> Double {
    guard !sortedValues.isEmpty else {
        return 0
    }
    let rank = Int((percentile * Double(sortedValues.count)).rounded(.up))
    let index = min(max(rank - 1, 0), sortedValues.count - 1)
    return sortedValues[index]
}

func formatScoreValue(_ value: Double) -> String {
    if value.isFinite && abs(value.rounded() - value) < 0.000_001 {
        return "\(Int64(value.rounded()))"
    }
    return String(format: "%.2f", value)
}

func coloredScoreValue(_ value: Double) -> String {
    terminalSkyBlue(formatScoreValue(value))
}

func colorDiagnosticScores(_ diagnostic: String) -> String {
    diagnostic
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in
            let value = String(line)
            return value.contains("score ") ? terminalSkyBlue(value) : value
        }
        .joined(separator: "\n")
}

struct ScoreKey: Hashable, Comparable {
    var metric: String
    var score: String
    var context: String

    static func < (lhs: ScoreKey, rhs: ScoreKey) -> Bool {
        if lhs.metric != rhs.metric {
            return lhs.metric < rhs.metric
        }
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        return lhs.context < rhs.context
    }
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
        let status = duration.passed ? terminalGreen("PASS") : terminalRed("FAIL")
        log("[test-in-device]   \(duration.name): \(duration.durationMilliseconds)ms \(status)")
    }
}

func terminalBoldYellow(_ value: String) -> String {
    terminalColor(value, code: "1;33")
}

func terminalGreen(_ value: String) -> String {
    terminalColor(value, code: "32")
}

func terminalRed(_ value: String) -> String {
    terminalColor(value, code: "31")
}

func terminalSkyBlue(_ value: String) -> String {
    terminalColor(value, code: "96")
}

func terminalColor(_ value: String, code: String) -> String {
    if ProcessInfo.processInfo.environment["NO_COLOR"] != nil {
        return value
    }
    return "\u{001B}[\(code)m\(value)\u{001B}[0m"
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
    var rawOutput: Data
    var queueElapsed: TimeInterval?
    var programElapsed: TimeInterval
    var captureElapsed: TimeInterval
}

struct DeviceRunReport {
    var passed: Bool
    var scores: [DeviceScore]
}

struct RemoteBuiltDeviceTest {
    var index: Int
    var source: DeviceTestSource
    var startedAt: Date
    var buildElapsed: TimeInterval
    var firmware: BuiltFirmware
    var firmwareSize: String
    var memoryMapReport: String?
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
