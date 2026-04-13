import Foundation
import PackagePlugin
#if os(Linux)
import Glibc
#endif

@main
struct FinalizeBinaryPlugin: CommandPlugin {
    enum Error: Swift.Error {
        case nmFailed
        case swiftlyResolutionFailed
        case rsyncFailed
        case cmakeConfigurationFailed
        case cmakeBuildFailed
        case noCombinationFound
        case multipleCombinationsFound(Set<String>)

        var localizedDescription: String {
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
            }
        }
    }

    func performCommand(context: PackagePlugin.PluginContext, arguments: [String]) async throws {
        guard arguments.count >= 1 else {
            fatalError("[CPicoSDK] Expected at one argument: A product name is expected. It should be a static library in the Product section of the package.")
        }

        var arguments = arguments
        let productName = arguments.removeFirst()

        let incremental = arguments.contains("--incremental")
        guard let picoSDKURL = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" })?.package.directoryURL else {
            fatalError("[CPicoSDK] Couldn't find CPicoSDK in the dependencies.")
        }
        
        let matchingProducts = context.package.products(ofType: LibraryProduct.self)
        guard let libProduct = matchingProducts.first(where: { $0.name == productName }) else {
            fatalError("[CPicoSDK] Couldn't find a viable static library Product, name couldn't be matched. Given: \(productName); Found: [\(matchingProducts.map(\.name).joined(separator: ","))]")
        }
        
        guard libProduct.kind == .static else {
            fatalError("[CPicoSDK] Only static libraries are supported.")
        }
        
        // TODO: Figure out how to expand this.
        guard libProduct.sourceModules.count == 1 else {
            fatalError("[CPicoSDK] Only libraries with one target are supported.")
        }

        let swiftBuildType = try Env.value("SWIFT_BUILD_TYPE").expected
        let platformTriple = try Env.value("SWIFTPM_TRIPLE").expected
        let outputDir = context.package.directoryURL.appending(path: "/.build/\(platformTriple)/\(swiftBuildType)")
        let buildArtifact = outputDir
            .appending(path: "lib\(libProduct.name).a")

        let combination = try await getCombination(from: buildArtifact)
        let stdioOptions = await getStdioOptions(from: buildArtifact, combination: combination)
        let extraSwiftArchives = try await getExtraSwiftArchives(from: buildArtifact)

        print("[CPicoSDK] Finalizing build for \(libProduct.name), combination: \(combination)...")

        try await self.runBuild(
            combination: combination,
            stdioOptions: stdioOptions,
            extraSwiftArchives: extraSwiftArchives,
            workingDir: context.pluginWorkDirectoryURL,
            cmakeHarness: picoSDKURL.appending(path: "Plugins/FinalizeBinaryPluginTool/CMakeHarness"),
            outputDir: outputDir,
            buildArtifact: buildArtifact,
            productName: libProduct.name,
            clean: !incremental
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
                switch Env.value("AUTO_STDIO") {
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
        let platformTriple = try Env.value("SWIFTPM_TRIPLE").expected

        func appendEmbeddedArchive(_ archiveName: String, reason: String) {
            let archivePath = URL(filePath: toolchainPath, directoryHint: .isDirectory)
                .appending(path: "usr/lib/swift/embedded/\(platformTriple)/\(archiveName)")

            if FileManager.default.fileExists(atPath: archivePath.path) {
                extraArchives.append(archivePath.path)
                print("[CPicoSDK] Linking extra Swift embedded archive (\(reason)): \(archivePath.path)")
            } else if let fallbackRoot = Env.value("SWIFT_EMBEDDED_FALLBACK_PATH") {
                let fallbackArchivePath = URL(filePath: fallbackRoot, directoryHint: .isDirectory)
                    .appending(path: "\(platformTriple)/\(archiveName)")
                if FileManager.default.fileExists(atPath: fallbackArchivePath.path) {
                    extraArchives.append(fallbackArchivePath.path)
                    print("[CPicoSDK] Linking vendored Swift embedded archive (\(reason)): \(fallbackArchivePath.path)")
                } else {
                    print("[CPicoSDK] Warning: \(reason) detected, but embedded archive was not found at \(archivePath.path) or vendored fallback \(fallbackArchivePath.path)")
                }
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
        let swiftlyProcess = Process()
        swiftlyProcess.executableURL = URL(filePath: try Env.value("SWIFTLY_PATH").expected, directoryHint: .notDirectory)
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

    // TODO: Remove this when upgrading to Swift 6.3
    // https://github.com/swiftlang/swift/issues/81272
    func unblockSigchldIfNeeded() {
        #if os(Linux)
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGCHLD)
        _ = sigprocmask(SIG_UNBLOCK, &set, nil)
        #endif
    }

    func runBuild(combination: String, stdioOptions: (uart: Bool, usb: Bool, rtt: Bool), extraSwiftArchives: [String], workingDir: URL, cmakeHarness: URL, outputDir: URL, buildArtifact: URL, productName: String, clean: Bool) async throws {
        let fileManager = FileManager.default
        let cmakePath = try Env.value("CMAKE_PATH", combination: combination).expected
        let cmakeBin = URL(filePath: cmakePath, directoryHint: .notDirectory).appending(path: "cmake")
        let ninjaPath = try Env.value("NINJA_PATH", combination: combination).expected

        print("[CPicoSDK] Copying CMake harness to working directory")

        let rsyncProcess = Process()
        rsyncProcess.executableURL = URL(filePath: try Env.value("RSYNC_PATH").expected, directoryHint: .notDirectory)
        rsyncProcess.arguments = ["-r", "-u", "\(cmakeHarness.path)", "\(workingDir.path)"]
        guard try await rsyncProcess.asyncRun() == 0 else { throw Error.rsyncFailed }

        let srcDir = workingDir.appending(path: "CMakeHarness")
        let buildDir = srcDir.appending(path: "build_\(combination)")

        try fileManager.ensureDirectoryExists(at: buildDir.path, isDirectory: true)
        print("[CPicoSDK] Build directory prepared at \(buildDir.path)")
        let importedLibs = try Env.importedLibs(combination: combination)

        print("[CPicoSDK] Imported libraries: \(importedLibs)")
        if !extraSwiftArchives.isEmpty {
            print("[CPicoSDK] Extra Swift archives: \(extraSwiftArchives)")
        }

        if clean {
            try? fileManager.removeItem(at: buildDir)
            try fileManager.ensureDirectoryExists(at: buildDir.path, isDirectory: true)
        }

        var env = try Env.combinedVars(for: combination)
        env["PATH"] = "\(cmakePath):\(ninjaPath):\(ProcessInfo.processInfo.environment["PATH"]!)"

        print("[CPicoSDK] Running CMake configuration and build...")

        let cmakeConfigProcess = Process()
        cmakeConfigProcess.executableURL = cmakeBin
        cmakeConfigProcess.environment = env
        cmakeConfigProcess.arguments = [
            "-S", "\(srcDir.path)",
            "-B", "\(buildDir.path)",
            "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=\(try Env.value("BUILD_TYPE", combination: combination).expected)",
            "-DPICO_SDK_PATH=\(try Env.value("PICO_SDK_PATH", combination: combination).expected)",
            "-DPICOTOOL_PATH=\(try Env.value("PICOTOOL_PATH", combination: combination).expected)",
            "-DBOARD_TYPE=\(try Env.value("BOARD", combination: combination).expected)",
            "-DPROJECT_NAME=\(productName)",
            "-DTOOLCHAIN_VERSION=\(try Env.value("TOOLCHAIN_VERSION", combination: combination).expected)",
            "-DSDK_VERSION=\(try Env.value("SDK_VERSION", combination: combination).expected)",
            "-DIMPORTED_LIBS=\(importedLibs.joined(separator: ","))",
            "-DIMPORTED_LOCATION=\(buildArtifact.path)",
            "-DEXTRA_SWIFT_ARCHIVES=\(extraSwiftArchives.joined(separator: ";"))",
            "-DSTDIO_UART=\(stdioOptions.uart ? "1" : "0")",
            "-DSTDIO_USB=\(stdioOptions.usb ? "1" : "0")",
            "-DSTDIO_RTT=\(stdioOptions.rtt ? "1" : "0")",
        ]

        unblockSigchldIfNeeded()
        guard try await cmakeConfigProcess.asyncRun() == 0 else { throw Error.cmakeConfigurationFailed }

        let cmakeBuildProcess = Process()
        cmakeBuildProcess.executableURL = cmakeBin
        cmakeBuildProcess.environment = env
        cmakeBuildProcess.arguments = ["--build", buildDir.path]
        unblockSigchldIfNeeded()
        guard try await cmakeBuildProcess.asyncRun() == 0 else { throw Error.cmakeBuildFailed }

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

        print("[CPicoSDK] Build artifacts copied to output directory at \(outputDir.path)")

        print("[CPicoSDK] 🎉 Finalization completed successfully! 🎉")
    }

    private func runNM(on buildArtifact: URL) async throws -> String {
        let nmProcess = Process()
        nmProcess.executableURL = URL(filePath: try Env.value("NM_PATH").expected, directoryHint: .notDirectory)
        nmProcess.arguments = [buildArtifact.path]

        let (status, outputData, _) = try await nmProcess.asyncRun(captureStdout: true, captureStderr: false)
        guard status == 0, let outputData else { throw Error.nmFailed }

        guard let outputString = String(data: outputData, encoding: .utf8) else {
            throw Error.nmFailed
        }
        return outputString
    }
}
