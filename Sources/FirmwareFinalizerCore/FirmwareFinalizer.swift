import Foundation

public struct FirmwareFinalizer {
    public enum Error: Swift.Error, CustomStringConvertible {
        case cmakeBuildFailed
        case cmakeConfigurationFailed
        case invalidEmbeddedResourceName(String)
        case invalidEmbeddedResourcePath(String, String)
        case missingArtifact(String)
        case multipleCombinationsFound(Set<String>)
        case noCombinationFound
        case nmFailed
        case swiftlyResolutionFailed
        case unsupportedRequestSchema(Int)

        public var description: String {
            switch self {
            case .cmakeBuildFailed:
                return "CMake build process failed"
            case .cmakeConfigurationFailed:
                return "CMake configuration process failed"
            case .invalidEmbeddedResourceName(let name):
                return "Embedded resource name must not be empty or contain path/list separators, got: \(name)"
            case .invalidEmbeddedResourcePath(let name, let path):
                return "Embedded resource '\(name)' must use an absolute path without CMake list separators, got: \(path)"
            case .missingArtifact(let path):
                return "Final firmware build did not produce expected artifact: \(path)"
            case .multipleCombinationsFound(let combinations):
                return "Multiple combinations found in the build artifact: \(combinations)"
            case .noCombinationFound:
                return "No combination found in the build artifact"
            case .nmFailed:
                return "nm process failed"
            case .swiftlyResolutionFailed:
                return "swiftly run which swift failed"
            case .unsupportedRequestSchema(let version):
                return "Unsupported firmware finalization request schema: \(version)"
            }
        }
    }

    private let request: FirmwareFinalizationRequest
    private let environment: FinalizationEnvironment

    public init(request: FirmwareFinalizationRequest) {
        self.request = request
        self.environment = FinalizationEnvironment(variables: request.environment)
    }

    public func run() async throws {
        guard request.schemaVersion == FirmwareFinalizationRequest.currentSchemaVersion else {
            throw Error.unsupportedRequestSchema(request.schemaVersion)
        }
        let buildArtifact = URL(
            filePath: request.productArchivePath,
            directoryHint: .notDirectory
        )
        let nmOutput = try await runNM(on: buildArtifact)
        let combination = try getCombination(from: nmOutput)
        let stdioOptions = getStdioOptions(from: nmOutput, combination: combination)
        let extraSwiftArchives = try await getExtraSwiftArchives(from: nmOutput)

        print(
            "[CPicoSDK] Finalizing build for \(request.productName), combination: \(combination)..."
        )

        try await runBuild(
            combination: combination,
            stdioOptions: stdioOptions,
            extraSwiftArchives: extraSwiftArchives,
            buildArtifact: buildArtifact
        )
    }

    func getCombination(from nmOutput: String) throws -> String {
        let combinationRegex = /_cpicosdk_combination_([a-zA-Z0-9_]+)/
        let combinations = Set(
            nmOutput.matches(of: combinationRegex).map { String($0.output.1) }
        )

        guard combinations.count == 1, let combination = combinations.first else {
            throw combinations.isEmpty
                ? Error.noCombinationFound
                : Error.multipleCombinationsFound(combinations)
        }
        return combination
    }

    func getStdioOptions(
        from nmOutput: String,
        combination: String
    ) -> (uart: Bool, usb: Bool, rtt: Bool) {
        func hasTrait(_ name: String) -> Bool {
            nmOutput.contains("_cpicosdk_trait_\(name.lowercased())")
        }

        if hasTrait("stdio_automatic") {
            switch environment.value("AUTO_STDIO") {
            case .some("uart"):
                print("[CPicoSDK] StdIO automatically selected UART.")
                return (true, false, false)
            case .some("usb"):
                print("[CPicoSDK] StdIO automatically selected USB.")
                return (false, true, false)
            case .some("rtt"):
                print("[CPicoSDK] StdIO automatically selected RTT.")
                return (false, false, true)
            case .some(let other):
                print(
                    "[CPicoSDK] StdIO automatical selection enabled, but unknown value provided by tool (\(other)). Defaulting to USB."
                )
                return (false, true, false)
            case .none:
                print(
                    "[CPicoSDK] StdIO automatical selection enabled, but no value provided by tool. Defaulting to USB."
                )
                return (false, true, false)
            }
        }

        let options = (
            uart: hasTrait("stdio_uart"),
            usb: hasTrait("stdio_usb"),
            rtt: hasTrait("stdio_rtt")
        )
        print(
            "[CPicoSDK] StdIO manual selection: UART=\(options.uart), USB=\(options.usb), RTT=\(options.rtt)."
        )
        return options
    }

    func getExtraSwiftArchives(from nmOutput: String) async throws -> [String] {
        var extraArchives: [String] = []
        let toolchainPath = try await resolveSwiftToolchainPath()

        func appendEmbeddedArchive(_ archiveName: String, reason: String) {
            if let fallbackRoot = environment.value("SWIFT_EMBEDDED_FALLBACK_PATH") {
                let fallbackArchivePath = URL(
                    filePath: fallbackRoot,
                    directoryHint: .isDirectory
                ).appending(path: "\(request.platformTriple)/\(archiveName)")
                if FileManager.default.fileExists(atPath: fallbackArchivePath.path) {
                    extraArchives.append(fallbackArchivePath.path)
                    print(
                        "[CPicoSDK] Linking vendored Swift embedded archive (\(reason)): \(fallbackArchivePath.path)"
                    )
                    return
                }
            }

            let archivePath = URL(
                filePath: toolchainPath,
                directoryHint: .isDirectory
            ).appending(
                path: "usr/lib/swift/embedded/\(request.platformTriple)/\(archiveName)"
            )
            if FileManager.default.fileExists(atPath: archivePath.path) {
                extraArchives.append(archivePath.path)
                print(
                    "[CPicoSDK] Linking extra Swift embedded archive (\(reason)): \(archivePath.path)"
                )
            } else {
                print(
                    "[CPicoSDK] Warning: \(reason) detected, but embedded archive was not found at \(archivePath.path)"
                )
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

    private func resolveSwiftToolchainPath() async throws -> String {
        let swiftlyProcess = Process()
        swiftlyProcess.executableURL = URL(
            filePath: try environment.value("SWIFTLY_PATH").expected,
            directoryHint: .notDirectory
        )
        swiftlyProcess.arguments = ["run", "which", "swift"]

        let (status, outputData, _) = try await swiftlyProcess.asyncRun(
            captureStdout: true,
            captureStderr: false
        )
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

    private func runBuild(
        combination: String,
        stdioOptions: (uart: Bool, usb: Bool, rtt: Bool),
        extraSwiftArchives: [String],
        buildArtifact: URL
    ) async throws {
        let fileManager = FileManager.default
        let cmakePath = try environment.value("CMAKE_PATH", combination: combination).expected
        let cmakeBinary = URL(filePath: cmakePath, directoryHint: .isDirectory)
            .appending(path: "cmake")
        let ninjaPath = try environment.value("NINJA_PATH", combination: combination).expected
        let sourceDirectory = URL(
            filePath: request.cmakeHarnessDirectoryPath,
            directoryHint: .isDirectory
        )
        let buildDirectory = URL(
            filePath: request.workingDirectoryPath,
            directoryHint: .isDirectory
        ).appending(path: "FirmwareFinalizer/build_\(combination)")

        try prepareBuildDirectory(
            buildDirectory,
            sourceDirectory: sourceDirectory,
            clean: !request.incremental
        )

        let importedLibraries = try environment.importedLibraries(combination: combination)
        let embeddedResourceArguments = try makeEmbeddedResourceCMakeArguments(
            request.embeddedResources
        )

        print("[CPicoSDK] Build directory prepared at \(buildDirectory.path)")
        print("[CPicoSDK] Imported libraries: \(importedLibraries)")
        if !extraSwiftArchives.isEmpty {
            print("[CPicoSDK] Extra Swift archives: \(extraSwiftArchives)")
        }

        var childEnvironment = try environment.combinedVariables(for: combination)
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        childEnvironment["PATH"] = "\(cmakePath):\(ninjaPath):\(inheritedPath)"

        print("[CPicoSDK] Running CMake configuration and build...")
        let cmakeConfiguration = Process()
        cmakeConfiguration.executableURL = cmakeBinary
        cmakeConfiguration.environment = childEnvironment
        cmakeConfiguration.arguments = [
            "-S", sourceDirectory.path,
            "-B", buildDirectory.path,
            "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=\(try environment.value("BUILD_TYPE", combination: combination).expected)",
            "-DPICO_SDK_PATH=\(try environment.value("PICO_SDK_PATH", combination: combination).expected)",
            "-DPICOTOOL_PATH=\(try environment.value("PICOTOOL_PATH", combination: combination).expected)",
            "-DBOARD_TYPE=\(try environment.value("BOARD", combination: combination).expected)",
            "-DPROJECT_NAME=\(request.productName)",
            "-DTOOLCHAIN_VERSION=\(try environment.value("TOOLCHAIN_VERSION", combination: combination).expected)",
            "-DSDK_VERSION=\(try environment.value("SDK_VERSION", combination: combination).expected)",
            "-DIMPORTED_LIBS=\(importedLibraries.joined(separator: ","))",
            "-DIMPORTED_LOCATION=\(buildArtifact.path)",
            "-DEXTRA_SWIFT_ARCHIVES=\(extraSwiftArchives.joined(separator: ";"))",
            "-DSTDIO_UART=\(stdioOptions.uart ? "1" : "0")",
            "-DSTDIO_USB=\(stdioOptions.usb ? "1" : "0")",
            "-DSTDIO_RTT=\(stdioOptions.rtt ? "1" : "0")",
            "-DCPICOSDK_CORE0_STACK_SIZE_BYTES=\(environment.value("CPICOSDK_CORE0_STACK_SIZE_BYTES", combination: combination) ?? "8192")",
            "-DCPICOSDK_CORE1_STACK_SIZE_BYTES=\(environment.value("CPICOSDK_CORE1_STACK_SIZE_BYTES", combination: combination) ?? "8192")",
            "-DCPICOSDK_NATIVE_SUPPORT_ARCHIVE=\(request.nativeSupportArchivePath ?? "")",
            "-Dpioasm_DIR=\(request.pioasmPackageDirectoryPath ?? "")",
        ] + embeddedResourceArguments

        guard try await cmakeConfiguration.asyncRun() == 0 else {
            throw Error.cmakeConfigurationFailed
        }

        let cmakeBuild = Process()
        cmakeBuild.executableURL = cmakeBinary
        cmakeBuild.environment = childEnvironment
        cmakeBuild.arguments = ["--build", buildDirectory.path]
        guard try await cmakeBuild.asyncRun() == 0 else {
            throw Error.cmakeBuildFailed
        }

        let outputDirectory = URL(
            filePath: request.outputDirectoryPath,
            directoryHint: .isDirectory
        )
        try fileManager.ensureDirectoryExists(at: outputDirectory.path, isDirectory: true)
        print("[CPicoSDK] Output directory prepared at \(outputDirectory.path)")

        for suffix in ["elf", "uf2", "bin", "hex", "elf.map", "dis"] {
            let source = buildDirectory.appending(path: "\(request.productName).\(suffix)")
            let destination = outputDirectory.appending(
                path: "\(request.productName).\(suffix)"
            )
            guard fileManager.fileExists(atPath: source.path) else {
                throw Error.missingArtifact(source.path)
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
            print("[CPicoSDK] Copying \(source.path) to \(destination.path)")
        }

        print("[CPicoSDK] Build artifacts copied to output directory at \(outputDirectory.path)")
        await printArtifactStats(
            outputDirectory: outputDirectory,
            buildDirectory: buildDirectory,
            combination: combination
        )
        print("[CPicoSDK] 🎉 Build completed successfully! 🎉")
    }

    private func prepareBuildDirectory(
        _ buildDirectory: URL,
        sourceDirectory: URL,
        clean: Bool
    ) throws {
        let fileManager = FileManager.default
        var shouldClean = clean

        if !shouldClean {
            let cache = buildDirectory.appending(path: "CMakeCache.txt")
            if let contents = try? String(contentsOf: cache, encoding: .utf8),
               let homeLine = contents.split(separator: "\n").first(where: {
                   $0.hasPrefix("CMAKE_HOME_DIRECTORY:INTERNAL=")
               })
            {
                let configuredSource = homeLine.dropFirst(
                    "CMAKE_HOME_DIRECTORY:INTERNAL=".count
                )
                shouldClean = configuredSource != sourceDirectory.path[...]
            }
        }

        if shouldClean {
            try? fileManager.removeItem(at: buildDirectory)
        }
        try fileManager.ensureDirectoryExists(at: buildDirectory.path, isDirectory: true)
    }

    func makeEmbeddedResourceCMakeArguments(
        _ embeddedResources: [FirmwareFinalizationRequest.EmbeddedResource]
    ) throws -> [String] {
        var names: [String] = []
        var paths: [String] = []

        for resource in embeddedResources.sorted(by: { $0.name < $1.name }) {
            guard !resource.name.isEmpty,
                  !resource.name.contains("/"),
                  !resource.name.contains("\\"),
                  !resource.name.contains(";")
            else {
                throw Error.invalidEmbeddedResourceName(resource.name)
            }
            guard resource.path.hasPrefix("/"), !resource.path.contains(";") else {
                throw Error.invalidEmbeddedResourcePath(resource.name, resource.path)
            }
            names.append(resource.name)
            paths.append(resource.path)
        }

        return [
            "-DCPICOSDK_EMBEDDED_RESOURCE_NAMES=\(names.joined(separator: ";"))",
            "-DCPICOSDK_EMBEDDED_RESOURCE_PATHS=\(paths.joined(separator: ";"))",
        ]
    }

    private func printArtifactStats(
        outputDirectory: URL,
        buildDirectory: URL,
        combination: String
    ) async {
        let fileManager = FileManager.default
        func formatSize(_ bytes: Int64) -> String {
            let kib = Double(bytes) / 1024.0
            return "\(bytes) B (\(String(format: "%.2f", kib)) KiB)"
        }

        let artifacts = [
            ("BIN payload size", "BIN", outputDirectory.appending(path: "\(request.productName).bin").path),
            ("UF2 file size", "UF2", outputDirectory.appending(path: "\(request.productName).uf2").path),
            ("Host Debug Binary Size", "ELF", outputDirectory.appending(path: "\(request.productName).elf").path),
        ]
        print("[CPicoSDK] Artifact stats:")
        for (label, kind, path) in artifacts {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber
            else {
                continue
            }
            print("[CPicoSDK]   - \(label): \(formatSize(size.int64Value)) (\(kind))")
        }

        do {
            let report = try await runMemoryMapReport(
                elfURL: buildDirectory.appending(path: "\(request.productName).elf"),
                mapURL: buildDirectory.appending(path: "\(request.productName).elf.map"),
                combination: combination
            )
            print("")
            print(report)
        } catch {
            print("[CPicoSDK]   - Memory map report: unavailable (\(error))")
        }
    }

    private func runMemoryMapReport(
        elfURL: URL,
        mapURL: URL,
        combination: String
    ) async throws -> String {
        let reportProcess = Process()
        reportProcess.executableURL = URL(
            filePath: request.memoryMapToolPath,
            directoryHint: .notDirectory
        )
        reportProcess.arguments = [
            "--package-dir", request.packageDirectoryPath,
            "--cpicosdk-path", request.cpicoSDKDirectoryPath,
            "--elf", elfURL.path,
            "--map", mapURL.path,
            "--no-sections",
        ]
        var reportEnvironment = ProcessInfo.processInfo.environment
        reportEnvironment["SWIFTPM_PRODUCT"] = request.productName
        reportEnvironment["BOARD"] = environment.value("BOARD", combination: combination)
        reportEnvironment["SWIFT_BUILD_TYPE"] = request.swiftBuildType
        reportProcess.environment = reportEnvironment

        let (status, outputData, errorData) = try await reportProcess.asyncRun(
            captureStdout: true,
            captureStderr: true
        )
        guard status == 0,
              let outputData,
              let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              output.nonEmpty != nil
        else {
            let stderr = errorData.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(
                domain: "CPicoSDK.MemoryMapReport",
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        stderr.nonEmpty ?? "memory-map-report exited with status \(status)"
                ]
            )
        }
        return output
    }

    private func runNM(on buildArtifact: URL) async throws -> String {
        let nmProcess = Process()
        nmProcess.executableURL = URL(
            filePath: try environment.value("NM_PATH").expected,
            directoryHint: .notDirectory
        )
        nmProcess.arguments = [buildArtifact.path]

        let (status, outputData, _) = try await nmProcess.asyncRun(
            captureStdout: true,
            captureStderr: false
        )
        guard status == 0,
              let outputData,
              let output = String(data: outputData, encoding: .utf8)
        else {
            throw Error.nmFailed
        }
        return output
    }
}
