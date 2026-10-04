import Foundation
import PicoBuildConfigurationCore

struct FirmwareBuilder: Sendable {
    let env: Env
    let configuration: ResolvedBuildConfiguration?

    init(env: Env = Env(), configuration: ResolvedBuildConfiguration? = nil) {
        self.env = env
        self.configuration = configuration
    }
    enum Error: Swift.Error, LocalizedError {
        case nmFailed
        case swiftlyResolutionFailed
        case rsyncFailed
        case cmakeConfigurationFailed
        case cmakeBuildFailed
        case noCombinationFound
        case multipleCombinationsFound(Set<String>)
        case invalidEmbeddedResourceName(String)
        case invalidEmbeddedResourcePath(String, URL)
        case duplicateEmbeddedResourceName(String)

        var errorDescription: String? {
            switch self {
            case .nmFailed:
                return "nm process failed"
            case .swiftlyResolutionFailed:
                return "swiftly run which swift failed"
            case .rsyncFailed:
                return "rsync process failed"
            case .cmakeConfigurationFailed:
                return "CMake configuration process failed"
            case .cmakeBuildFailed:
                return "CMake build process failed"
            case .noCombinationFound:
                return "No combination found in the build artifact"
            case .multipleCombinationsFound(let combinations):
                return "Multiple combinations found in the build artifact: \(combinations)"
            case .invalidEmbeddedResourceName(let name):
                return "Embedded resource name must not be empty or contain path/list separators, got: \(name)"
            case .invalidEmbeddedResourcePath(let name, let url):
                return "Embedded resource '\(name)' must use an absolute file URL without CMake list separators, got: \(url)"
            case .duplicateEmbeddedResourceName(let name):
                return "Multiple embedded resources would be staged as '\(name)'"
            }
        }
    }

    func build(_ request: FirmwareRequest) async throws {
        guard env.value("RELEVANT_ENV_VARS") != nil else {
            throw NSError(domain: "CPicoSDK.FirmwareBuild", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Run prepare-rp2xxx-environment and source its output before building firmware.",
            ])
        }
        let combination = try await getCombination(from: request.configurationArchive)
        if let configuration, configuration.board != combination {
            throw ConfigurationError("Resolved configuration does not match the board metadata. Rebuild PicoBuildConfiguration.")
        }
        let stdioOptions: (uart: Bool, usb: Bool, rtt: Bool)
        if let configuration {
            stdioOptions = (configuration.stdio.uart, configuration.stdio.usb, configuration.stdio.rtt)
        } else {
            stdioOptions = await getStdioOptions(from: request.configurationArchive, combination: combination)
        }
        let extraSwiftArchives = request.phase == .sdk ? [] : try await getExtraSwiftArchives(from: request.archive)
        var resources: [String: URL] = [:]
        for resource in request.resources {
            let name = resource.lastPathComponent
            guard resources[name] == nil else { throw Error.duplicateEmbeddedResourceName(name) }
            resources[name] = resource
        }
        try await runBuild(
            combination: combination,
            stdioOptions: stdioOptions,
            extraSwiftArchives: extraSwiftArchives,
            workingDir: request.workDirectory,
            cmakeHarness: request.sdkDirectory.appending(path: "Plugins/FinalizeBinaryPluginTool/CMakeHarness"),
            outputDir: request.outputDirectory,
            buildArtifact: request.archive,
            productName: request.phase == .sdk ? configuration?.variables["SWIFTPM_PRODUCT"]?.nonEmpty ?? request.product : request.product,
            embeddedResources: resources,
            clean: request.clean,
            phase: request.phase,
            sdkArtifactsDirectory: request.sdkArtifactsDirectory
        )
    }

    func getStaticTrait(from buildArtifact: URL, traitName: String) async throws -> Bool {
        let traitSymbol = "_cpicosdk_trait_\(traitName.lowercased())"
        return try await runNM(on: buildArtifact).contains(traitSymbol)
    }

    func getStdioOptions(from buildArtifact: URL, combination: String) async -> (uart: Bool, usb: Bool, rtt: Bool) {
        do {
            var (uart, usb, rtt) = (false, false, false)

            if try await getStaticTrait(from: buildArtifact, traitName: "stdio_automatic") {
                switch env.value("AUTO_STDIO") {
                    case .some("uart"):
                        uart = true
                        print("[CPicoSDK] StdIO automatically selected UART.")
                    case .some("usb"):
                        usb = true
                        print("[CPicoSDK] StdIO automatically selected USB.")
                    case .some("rtt"):
                        rtt = true
                        print("[CPicoSDK] StdIO automatically selected RTT.")
                    case .some(let other):
                        usb = true
                        print("[CPicoSDK] StdIO automatical selection enabled, but unknown value provided by tool (\(other)). Defaulting to USB.")
                    case .none:
                        usb = true
                        print("[CPicoSDK] StdIO automatical selection enabled, but no value provided by tool. Defaulting to USB.")
                }
            } else {
                if try await getStaticTrait(from: buildArtifact, traitName: "stdio_uart") {
                    uart = true
                }
                if try await getStaticTrait(from: buildArtifact, traitName: "stdio_usb") {
                    usb = true
                }
                if try await getStaticTrait(from: buildArtifact, traitName: "stdio_rtt") {
                    rtt = true
                }

                print("[CPicoSDK] StdIO manual selection: UART=\(uart), USB=\(usb), RTT=\(rtt).")
            }

            return (uart, usb, rtt)
        } catch {
            print("[CPicoSDK] StdIO Warning: Couldn't determine options from the build artifact. Defaulting to USB. Error: \(error)")
            return (false, true, false)
        }
    }

    func getCombination(from buildArtifact: URL) async throws -> String {
        let combinationRegex = /_cpicosdk_combination_([a-zA-Z0-9_]+)/
        let combinations = Set(
            try await runNM(on: buildArtifact)
                .matches(of: combinationRegex)
                .map { String($0.output.1) }
        )

        guard combinations.count == 1, let combination = combinations.first else {
            throw combinations.isEmpty ? Error.noCombinationFound : Error.multipleCombinationsFound(combinations)
        }

        return combination
    }

    func getExtraSwiftArchives(from buildArtifact: URL) async throws -> [String] {
        let nmOutput = try await runNM(on: buildArtifact)
        var extraArchives: [String] = []
        let toolchainPath = try await resolveSwiftToolchainPath()
        let platformTriple = try env.value("SWIFTPM_TRIPLE").expected

        func appendEmbeddedArchive(_ archiveName: String, reason: String) {
            if let fallbackRoot = env.value("SWIFT_EMBEDDED_FALLBACK_PATH") {
                let fallbackArchivePath = URL(filePath: fallbackRoot, directoryHint: .isDirectory)
                    .appending(path: "\(platformTriple)/\(archiveName)")
                if FileManager.default.fileExists(atPath: fallbackArchivePath.path) {
                    extraArchives.append(fallbackArchivePath.path)
                    print("[CPicoSDK] Linking vendored Swift embedded archive (\(reason)): \(fallbackArchivePath.path)")
                    return
                }
            }

            let archivePath = URL(filePath: toolchainPath, directoryHint: .isDirectory)
                .appending(path: "usr/lib/swift/embedded/\(platformTriple)/\(archiveName)")

            if FileManager.default.fileExists(atPath: archivePath.path) {
                extraArchives.append(archivePath.path)
                print("[CPicoSDK] Linking extra Swift embedded archive (\(reason)): \(archivePath.path)")
            } else {
                print("[CPicoSDK] Warning: \(reason) detected, but embedded archive was not found at \(archivePath.path)")
            }
        }

        let unicodeTableMarkers = [
            "_swift_stdlib_getNormData",
            "_swift_stdlib_getComposition",
            "_swift_stdlib_getDecompositionEntry",
            "_swift_stdlib_nfd_decompositions",
            "_swift_stdlib_isInCB_",
            "_swift_stdlib_getGraphemeBreakProperty",
        ]

        if unicodeTableMarkers.contains(where: nmOutput.contains) {
            appendEmbeddedArchive("libswiftUnicodeDataTables.a", reason: "Unicode data symbols")
        }

        let concurrencyMarkers = [
            "swift_task_alloc",
            "swift_task_dealloc",
            "swift_task_switch",
            "swift_task_create",
            "swift_job_run",
            "swift_continuation_init",
            "swift_continuation_await",
            "swift_continuation_throwingResume",
            "swift_task_getMainExecutor",
            "swift_task_isCurrentExecutor",
            "swift_task_reportUnexpectedExecutor",
            "swift_createDefaultExecutorsOnce",
        ]

        if concurrencyMarkers.contains(where: nmOutput.contains) {
            appendEmbeddedArchive("libswift_Concurrency.a", reason: "Swift concurrency symbols")
        }

        if extraArchives.isEmpty {
            print("[CPicoSDK] No extra Swift embedded archives were needed.")
        }

        return extraArchives
    }

    func resolveSwiftToolchainPath() async throws -> String {
        if let compiler = env.value("CPICOSDK_SWIFT_EXEC") {
            return URL(fileURLWithPath: compiler)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent().path
        }
        let swiftlyProcess = Process()
        swiftlyProcess.executableURL = URL(filePath: try env.value("SWIFTLY_PATH").expected, directoryHint: .notDirectory)
        swiftlyProcess.arguments = ["run", "which", "swift"]

        let (status, outputData, _) = try await swiftlyProcess.asyncRun(captureStdout: true, captureStderr: false)
        guard status == 0,
              let outputData,
              let swiftPath = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        else {
            throw Error.swiftlyResolutionFailed
        }

        return URL(filePath: swiftPath, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    func runBuild(combination: String, stdioOptions: (uart: Bool, usb: Bool, rtt: Bool), extraSwiftArchives: [String], workingDir: URL, cmakeHarness: URL, outputDir: URL, buildArtifact: URL, productName: String, embeddedResources: [String: URL], clean: Bool, phase: FirmwareRequest.Phase, sdkArtifactsDirectory: URL?) async throws {
        let fileManager = FileManager.default
        let cmakePath = try env.value("CMAKE_PATH", combination: combination).expected
        let cmakeBin = URL(filePath: cmakePath, directoryHint: .notDirectory).appending(path: "cmake")
        let ninjaPath = try env.value("NINJA_PATH", combination: combination).expected

        let srcDir = workingDir.appending(path: "CMakeHarness")
        // Stable paths let the plugin declare SDK artifacts before reading the Swift archive.
        let buildDir = srcDir.appending(path: "build")

        let importedLibs = try env.importedLibs(combination: combination)
        let embeddedResourceArguments = try makeEmbeddedResourceCMakeArguments(embeddedResources)

        print("[CPicoSDK] Imported libraries: \(importedLibs)")
        if !extraSwiftArchives.isEmpty {
            print("[CPicoSDK] Extra Swift archives: \(extraSwiftArchives)")
        }

        var processEnvironment = try env.combinedVars(for: combination)
        processEnvironment["PATH"] = "\(cmakePath):\(ninjaPath):\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")"
        let buildEnvironment = CMakeBuildEnvironment(processEnvironment)

        let cmakeConfigProcess = Process()
        cmakeConfigProcess.executableURL = cmakeBin
        cmakeConfigProcess.environment = processEnvironment
        let sdkConfigurationArguments = [
            "-DCMAKE_BUILD_TYPE=\(try env.value("BUILD_TYPE", combination: combination).expected)",
            "-DPICO_SDK_PATH=\(try env.value("PICO_SDK_PATH", combination: combination).expected)",
            "-DPICOTOOL_PATH=\(try env.value("PICOTOOL_PATH", combination: combination).expected)",
            "-DBOARD_TYPE=\(try env.value("BOARD", combination: combination).expected)",
            "-DPROJECT_NAME=\(productName)",
            "-DTOOLCHAIN_VERSION=\(try env.value("TOOLCHAIN_VERSION", combination: combination).expected)",
            "-DSDK_VERSION=\(try env.value("SDK_VERSION", combination: combination).expected)",
            "-DIMPORTED_LIBS=\(importedLibs.joined(separator: ","))",
            "-DSTDIO_UART=\(stdioOptions.uart ? "1" : "0")",
            "-DSTDIO_USB=\(stdioOptions.usb ? "1" : "0")",
            "-DSTDIO_RTT=\(stdioOptions.rtt ? "1" : "0")",
            "-DCPICOSDK_CORE0_STACK_SIZE_BYTES=\(env.value("CPICOSDK_CORE0_STACK_SIZE_BYTES", combination: combination) ?? "8192")",
            "-DCPICOSDK_CORE1_STACK_SIZE_BYTES=\(env.value("CPICOSDK_CORE1_STACK_SIZE_BYTES", combination: combination) ?? "8192")",
        ]
        cmakeConfigProcess.arguments = ["-S", srcDir.path, "-B", buildDir.path, "-G", "Ninja"]
            + sdkConfigurationArguments + [
                "-DIMPORTED_LOCATION=\(buildArtifact.path)",
                "-DEXTRA_SWIFT_ARCHIVES=\(extraSwiftArchives.joined(separator: ";"))",
                "-DPREBUILT_PICO_SDK_ARCHIVE=\(sdkArtifactsDirectory?.appending(path: "libPicoSDK.a").path ?? "")",
            ] + embeddedResourceArguments

        let sdkState = SDKBuildState(arguments: sdkConfigurationArguments, environment: processEnvironment)
        if phase == .link {
            try sdkState.validate(in: try sdkArtifactsDirectory.expected)
        } else {
            let stateFile = SDKBuildState.file(in: buildDir)
            if fileManager.fileExists(atPath: stateFile.path) {
                try fileManager.removeItem(at: stateFile)
            }
        }
        print("[CPicoSDK] Copying CMake harness to working directory")
        let rsyncProcess = Process()
        rsyncProcess.executableURL = URL(filePath: try env.value("RSYNC_PATH").expected, directoryHint: .notDirectory)
        rsyncProcess.arguments = ["-rc", "\(cmakeHarness.path)", "\(workingDir.path)"]
        guard try await rsyncProcess.asyncRun() == 0 else { throw Error.rsyncFailed }

        try buildEnvironment.prepare(buildDir, clean: clean)
        print(phase == .link ? "[CPicoSDK] Configuring firmware link..." : "[CPicoSDK] Configuring and building Pico SDK...")
        guard try await cmakeConfigProcess.asyncRun() == 0 else { throw Error.cmakeConfigurationFailed }
        try buildEnvironment.record(in: buildDir)
        if phase != .link {
            try await buildCMakeTarget("cpicosdk_sdk", in: buildDir, cmake: cmakeBin, environment: processEnvironment)
            try sdkState.record(in: buildDir)
        }
        if phase == .sdk { return }

        try sdkState.validate(in: sdkArtifactsDirectory ?? buildDir)
        print("[CPicoSDK] Linking firmware and generating outputs...")
        try await buildCMakeTarget(productName, in: buildDir, cmake: cmakeBin, environment: processEnvironment)

        try fileManager.ensureDirectoryExists(at: outputDir.path, isDirectory: true)

        print("[CPicoSDK] Output directory prepared at \(outputDir.path)")

        try? fileManager.removeItem(at: outputDir.appending(path: "\(productName).elf"))
        try fileManager.copyItem(
            at: buildDir.appending(path: "\(productName).elf"),
            to: outputDir.appending(path: "\(productName).elf")
        )
        print("[CPicoSDK] Copying \(buildDir.appending(path: "\(productName).elf").path) to \(outputDir.appending(path: "\(productName).elf").path)")

        try? fileManager.removeItem(at: outputDir.appending(path: "\(productName).uf2"))
        try fileManager.copyItem(
            at: buildDir.appending(path: "\(productName).uf2"),
            to: outputDir.appending(path: "\(productName).uf2")
        )
        print("[CPicoSDK] Copying \(buildDir.appending(path: "\(productName).uf2").path) to \(outputDir.appending(path: "\(productName).uf2").path)")

        for suffix in ["bin", "elf.map"] {
            let destination = outputDir.appending(path: "\(productName).\(suffix)")
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: buildDir.appending(path: "\(productName).\(suffix)"), to: destination)
        }
        print("[CPicoSDK] Build artifacts copied to output directory at \(outputDir.path)")
    }

    private func buildCMakeTarget(_ target: String, in directory: URL, cmake: URL, environment: [String: String]) async throws {
        let process = Process()
        process.executableURL = cmake
        process.environment = environment
        process.arguments = ["--build", directory.path, "--target", target]
        guard try await process.asyncRun() == 0 else { throw Error.cmakeBuildFailed }
    }

    private func makeEmbeddedResourceCMakeArguments(_ embeddedResources: [String: URL]) throws -> [String] {
        var names: [String] = []
        var paths: [String] = []

        for name in embeddedResources.keys.sorted() {
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(";") else {
                throw Error.invalidEmbeddedResourceName(name)
            }

            let resourceURL = try embeddedResources[name].expected
            guard resourceURL.isFileURL, resourceURL.path.hasPrefix("/") else {
                throw Error.invalidEmbeddedResourcePath(name, resourceURL)
            }
            guard !resourceURL.path.contains(";") else {
                throw Error.invalidEmbeddedResourcePath(name, resourceURL)
            }

            names.append(name)
            paths.append(resourceURL.path)
        }

        return [
            "-DCPICOSDK_EMBEDDED_RESOURCE_NAMES=\(names.joined(separator: ";"))",
            "-DCPICOSDK_EMBEDDED_RESOURCE_PATHS=\(paths.joined(separator: ";"))",
        ]
    }

    private func runNM(on buildArtifact: URL) async throws -> String {
        let nmProcess = Process()
        nmProcess.executableURL = URL(filePath: try env.value("NM_PATH").expected, directoryHint: .notDirectory)
        nmProcess.arguments = [buildArtifact.path]

        let (status, outputData, _) = try await nmProcess.asyncRun(captureStdout: true, captureStderr: false)
        guard status == 0, let outputData else { throw Error.nmFailed }

        guard let outputString = String(data: outputData, encoding: .utf8) else {
            throw Error.nmFailed
        }
        return outputString
    }

}
