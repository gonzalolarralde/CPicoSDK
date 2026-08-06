import Foundation

struct SwiftSDKStager {
    private static let sdkIDs = ["cpicosdk-rp2040", "cpicosdk-rp2350"]
    private static let targetTriples = [
        "armv6m-none-none-eabi",
        "armv7em-none-none-eabi",
    ]

    let options: StageOptions
    private let fileManager = FileManager.default
    private let environment = ProcessInfo.processInfo.environment

    func stage() throws -> StageResult {
        try validateOptions()
        let swift = try resolveSwiftCompiler()
        let compiler = try inspectCompiler(swift)
        let destination = options.stagingRoot
            .appendingPathComponent("cpicosdk-rp2xxx.artifactbundle", isDirectory: true)

        try fileManager.createDirectory(at: options.stagingRoot, withIntermediateDirectories: true)
        let stagingLock = try CrossProcessFileLock(
            at: options.stagingRoot.appendingPathComponent(".cpicosdk-rp2xxx.lock")
        )
        return try withExtendedLifetime(stagingLock) {
            try stageWhileLocked(
                destination: destination,
                swift: swift,
                compiler: compiler
            )
        }
    }

    private func stageWhileLocked(
        destination: URL,
        swift: URL,
        compiler: CompilerInspection
    ) throws -> StageResult {
        try validatePicoPayload()
        let inputFingerprint = try makeInputFingerprint(compiler: compiler)

        if try isCurrentBundleValid(
            destination,
            swift: swift,
            compiler: compiler,
            expectedInputFingerprint: inputFingerprint
        ) {
            print("[CPicoSDK] Reusing staged Swift SDK bundle: \(destination.path)")
            return makeResult(destination: destination, swift: swift, compiler: compiler)
        }

        let workRoot = options.stagingRoot.appendingPathComponent(
            ".cpicosdk-rp2xxx.\(UUID().uuidString)",
            isDirectory: true
        )
        let workBundle = workRoot.appendingPathComponent(
            "cpicosdk-rp2xxx.artifactbundle",
            isDirectory: true
        )
        try fileManager.createDirectory(at: workBundle, withIntermediateDirectories: true)
        defer {
            try? removeManagedTemporaryTree(workRoot)
        }

        try createBundle(
            at: workBundle,
            swift: swift,
            compiler: compiler,
            inputFingerprint: inputFingerprint
        )
        try validateBundle(
            workBundle,
            sdkSearchPath: workRoot,
            swift: swift,
            compiler: compiler,
            expectedInputFingerprint: inputFingerprint
        )
        try publish(workBundle, to: destination)

        print("[CPicoSDK] Staged relocatable Swift SDK bundle: \(destination.path)")
        return makeResult(destination: destination, swift: swift, compiler: compiler)
    }

    private func validateOptions() throws {
        let identifiers = [
            "SDK_VERSION": options.sdkVersion,
            "TOOLCHAIN_VERSION": options.toolchainVersion,
            "CMAKE_VERSION": options.cmakeVersion,
            "NINJA_VERSION": options.ninjaVersion,
            "PICOTOOL_VERSION": options.picotoolVersion,
            "OPENOCD_VERSION": options.openocdVersion,
            "CPICOSDK_SWIFT_SDK_BUNDLE_VERSION": options.bundleVersion,
        ]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        for (name, value) in identifiers {
            guard !value.isEmpty,
                  value.unicodeScalars.allSatisfy({ allowed.contains($0) })
            else {
                throw EnvironmentToolError.invalidIdentifier(name: name, value: value)
            }
        }

        let requiredTemplates = [
            "swift-toolchain.txt",
            "info.json.in",
            "rp2040-swift-sdk.json.in",
            "rp2350-swift-sdk.json.in",
            "rp2xxx-toolset.json.in",
            "cpicosdk-layout.json.in",
            "stdatomic.h.in",
        ]
        for name in requiredTemplates {
            try requirePath(options.templateDirectory.appendingPathComponent(name))
        }
    }

    private func resolveSwiftCompiler() throws -> URL {
        if let explicit = nonempty(environment["CPICOSDK_SWIFT"]) {
            return try executableURL(explicit)
        }

        let pinnedSelector = try readTrimmed(
            options.templateDirectory.appendingPathComponent("swift-toolchain.txt")
        )
        let selector = nonempty(environment["CPICOSDK_SWIFT_TOOLCHAIN"])
            ?? nonempty(environment["SWIFTPM_PREVIEW_TOOLCHAIN"])
            ?? pinnedSelector

        if !selector.isEmpty {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
            guard selector.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw EnvironmentToolError.invalidIdentifier(
                    name: "Swift-toolchain-selector",
                    value: selector
                )
            }
            let swiftly = try resolveSwiftly()
            if let resolved = try resolveSwift(selector: selector, swiftly: swiftly) {
                return resolved
            }

            print("[CPicoSDK] Installing required Swift toolchain \(selector)...")
            try ProcessRunner.runInheritingIO(
                executable: swiftly,
                arguments: ["install", selector, "--assume-yes"]
            )
            guard let resolved = try resolveSwift(selector: selector, swiftly: swiftly) else {
                throw EnvironmentToolError.invalidCompiler(
                    "Swiftly installed \(selector), but could not resolve its swift executable"
                )
            }
            return resolved
        }

        guard let swift = findExecutable(named: "swift") else {
            throw EnvironmentToolError.invalidCompiler("no Swift compiler was found")
        }
        return swift
    }

    private func resolveSwiftly() throws -> URL {
        if let explicit = nonempty(environment["SWIFTLY_PATH"]) {
            return try executableURL(explicit)
        }
        if let found = findExecutable(named: "swiftly") {
            return found
        }
        if let home = nonempty(environment["HOME"]) {
            for path in [
                "\(home)/.swiftly/bin/swiftly",
                "\(home)/.local/share/swiftly/bin/swiftly",
            ] where fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw EnvironmentToolError.invalidCompiler(
            "the pinned Swift toolchain requires Swiftly, but swiftly was not found"
        )
    }

    private func resolveSwift(selector: String, swiftly: URL) throws -> URL? {
        let output = try ProcessRunner.capture(
            executable: swiftly,
            arguments: ["run", "which", "swift", "+\(selector)"]
        )
        guard output.status == 0 else {
            return nil
        }
        let path = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return try executableURL(path)
    }

    private struct CompilerInspection {
        let version: String
        let hostTriple: String
        let compilerExecutable: URL
        let runtimeResourcePath: URL
        let embeddedRuntimePath: URL
        let rp2040ConcurrencySupported: Bool
        let rp2350ConcurrencySupported: Bool
    }

    private func inspectCompiler(_ swift: URL) throws -> CompilerInspection {
        let targetInfoOutput = try ProcessRunner.checkedCapture(
            executable: swift,
            arguments: ["-print-target-info"]
        )
        let targetInfo: SwiftTargetInfo
        do {
            targetInfo = try JSONDecoder().decode(SwiftTargetInfo.self, from: targetInfoOutput.stdout)
        } catch {
            throw EnvironmentToolError.invalidCompiler("could not decode -print-target-info: \(error)")
        }

        let versionOutput = try ProcessRunner.checkedCapture(
            executable: swift,
            arguments: ["--version"]
        )
        let version = versionOutput.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostTriple = targetInfo.target.unversionedTriple ?? targetInfo.target.triple
        try validateHostTriple(hostTriple)

        let runtimePath = URL(fileURLWithPath: targetInfo.paths.runtimeResourcePath, isDirectory: true)
        guard runtimePath.path.hasPrefix("/") else {
            throw EnvironmentToolError.invalidCompiler("runtimeResourcePath is not absolute")
        }
        let embeddedPath = runtimePath.appendingPathComponent("embedded", isDirectory: true)
        let compilerExecutable = swift.deletingLastPathComponent()
            .appendingPathComponent("swiftc", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: compilerExecutable.path) else {
            throw EnvironmentToolError.invalidCompiler(
                "swiftc is unavailable beside \(swift.path)"
            )
        }

        for triple in Self.targetTriples {
            for path in [
                embeddedPath.appendingPathComponent("Swift.swiftmodule/\(triple).swiftmodule"),
                embeddedPath.appendingPathComponent("Synchronization.swiftmodule/\(triple).swiftmodule"),
                embeddedPath.appendingPathComponent(triple, isDirectory: true),
                embeddedPath.appendingPathComponent("\(triple)/libswiftEmbeddedPlatformPOSIX.a"),
            ] {
                guard fileManager.fileExists(atPath: path.path) else {
                    throw EnvironmentToolError.invalidCompiler("missing \(path.path)")
                }
            }
        }

        func concurrencySupported(_ triple: String) -> Bool {
            fileManager.fileExists(
                atPath: embeddedPath.appendingPathComponent(
                    "_Concurrency.swiftmodule/\(triple).swiftmodule"
                ).path
            ) && fileManager.fileExists(
                atPath: embeddedPath.appendingPathComponent(
                    "\(triple)/libswift_Concurrency.a"
                ).path
            )
        }

        let rp2040Concurrency = concurrencySupported("armv6m-none-none-eabi")
        let rp2350Concurrency = concurrencySupported("armv7em-none-none-eabi")
        guard rp2350Concurrency else {
            throw EnvironmentToolError.invalidCompiler(
                "RP2350 Embedded Swift concurrency runtime is unavailable"
            )
        }
        if !rp2040Concurrency {
            print("[CPicoSDK] Note: selected Swift supports RP2040 base firmware but not its concurrency runtime.")
            if options.requireRP2040Concurrency {
                throw EnvironmentToolError.invalidCompiler(
                    "RP2040 Embedded Swift concurrency runtime is required but unavailable"
                )
            }
        }

        return CompilerInspection(
            version: version,
            hostTriple: hostTriple,
            compilerExecutable: compilerExecutable,
            runtimeResourcePath: runtimePath,
            embeddedRuntimePath: embeddedPath,
            rp2040ConcurrencySupported: rp2040Concurrency,
            rp2350ConcurrencySupported: rp2350Concurrency
        )
    }

    private func validatePicoPayload() throws {
        for path in requiredPayloadPaths(relativeTo: options.picoSDKBundle) {
            try requirePath(path)
        }
    }

    private func requiredPayloadPaths(relativeTo root: URL) -> [URL] {
        let toolchain = root.appendingPathComponent(
            "toolchain/\(options.toolchainVersion)",
            isDirectory: true
        )
        return [
            root.appendingPathComponent("sdk/\(options.sdkVersion)", isDirectory: true),
            toolchain.appendingPathComponent("arm-none-eabi", isDirectory: true),
            toolchain.appendingPathComponent("bin/arm-none-eabi-ar"),
            toolchain.appendingPathComponent("bin/arm-none-eabi-ld"),
            root.appendingPathComponent("cmake/v\(options.cmakeVersion)/bin/cmake"),
            root.appendingPathComponent("ninja/v\(options.ninjaVersion)/ninja"),
            root.appendingPathComponent(
                "picotool/\(options.picotoolVersion)/picotool/picotool"
            ),
            root.appendingPathComponent("openocd/\(options.openocdVersion)", isDirectory: true),
        ]
    }

    private func createBundle(
        at bundle: URL,
        swift: URL,
        compiler: CompilerInspection,
        inputFingerprint: String
    ) throws {
        for directory in [
            bundle.appendingPathComponent("generated/newlib_overlay", isDirectory: true),
            bundle.appendingPathComponent("rp2040", isDirectory: true),
            bundle.appendingPathComponent("rp2350", isDirectory: true),
            bundle.appendingPathComponent("toolsets", isDirectory: true),
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try renderMetadata(at: bundle, compiler: compiler)
        try copyPicoPayload(to: bundle)
        try copyEmbeddedRuntimeSubset(to: bundle, compiler: compiler)
        try compiler.version.write(
            to: bundle.appendingPathComponent("swift-compiler-version.txt"),
            atomically: true,
            encoding: .utf8
        )
        try writeInputFingerprint(inputFingerprint, to: bundle)
        try normalizeLinks(
            in: bundle,
            relocatedSourceRoot: options.picoSDKBundle.standardizedFileURL,
            relocatedDestinationRoot: bundle.appendingPathComponent(
                "pico-sdk-bundle",
                isDirectory: true
            )
        )
    }

    private func renderMetadata(at bundle: URL, compiler: CompilerInspection) throws {
        let replacements = [
            "@SDK_VERSION@": options.sdkVersion,
            "@TOOLCHAIN_VERSION@": options.toolchainVersion,
            "@CMAKE_VERSION@": options.cmakeVersion,
            "@NINJA_VERSION@": options.ninjaVersion,
            "@PICOTOOL_VERSION@": options.picotoolVersion,
            "@OPENOCD_VERSION@": options.openocdVersion,
            "@BUNDLE_VERSION@": options.bundleVersion,
            "@HOST_TRIPLE@": compiler.hostTriple,
            "@RP2040_CONCURRENCY_SUPPORTED@": String(compiler.rp2040ConcurrencySupported),
            "@RP2350_CONCURRENCY_SUPPORTED@": String(compiler.rp2350ConcurrencySupported),
        ]
        let files = [
            ("info.json.in", "info.json"),
            ("rp2040-swift-sdk.json.in", "rp2040/swift-sdk.json"),
            ("rp2350-swift-sdk.json.in", "rp2350/swift-sdk.json"),
            ("rp2xxx-toolset.json.in", "toolsets/rp2xxx.json"),
            ("cpicosdk-layout.json.in", "cpicosdk-layout.json"),
            ("stdatomic.h.in", "generated/newlib_overlay/stdatomic.h"),
        ]

        for (sourceName, destinationName) in files {
            let source = options.templateDirectory.appendingPathComponent(sourceName)
            var content = try String(contentsOf: source, encoding: .utf8)
            for (placeholder, value) in replacements {
                content = content.replacingOccurrences(of: placeholder, with: value)
            }
            guard !content.contains("@SDK_VERSION@"),
                  !content.contains("@TOOLCHAIN_VERSION@"),
                  !content.contains("@HOST_TRIPLE@")
            else {
                throw EnvironmentToolError.invalidMetadata(
                    "unresolved placeholder in \(source.path)"
                )
            }
            try content.write(
                to: bundle.appendingPathComponent(destinationName),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func copyPicoPayload(to bundle: URL) throws {
        let destination = bundle.appendingPathComponent("pico-sdk-bundle", isDirectory: true)
        try fileManager.copyItem(at: options.picoSDKBundle, to: destination)
    }

    private func copyEmbeddedRuntimeSubset(
        to bundle: URL,
        compiler: CompilerInspection
    ) throws {
        let resourceDestination = bundle.appendingPathComponent("swift-resources", isDirectory: true)
        let embeddedDestination = resourceDestination.appendingPathComponent("embedded", isDirectory: true)
        try fileManager.createDirectory(at: embeddedDestination, withIntermediateDirectories: true)

        try fileManager.copyItem(
            at: compiler.runtimeResourcePath.appendingPathComponent("shims", isDirectory: true),
            to: resourceDestination.appendingPathComponent("shims", isDirectory: true)
        )
        let clangSource = compiler.runtimeResourcePath
            .appendingPathComponent("clang", isDirectory: true)
            .resolvingSymlinksInPath()
        try fileManager.copyItem(
            at: clangSource,
            to: resourceDestination.appendingPathComponent("clang", isDirectory: true)
        )

        let embeddedChildren = try fileManager.contentsOfDirectory(
            at: compiler.embeddedRuntimePath,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        )
        for child in embeddedChildren {
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isRegularFile == true {
                try fileManager.copyItem(
                    at: child,
                    to: embeddedDestination.appendingPathComponent(child.lastPathComponent)
                )
            }
        }

        for triple in Self.targetTriples {
            try fileManager.copyItem(
                at: compiler.embeddedRuntimePath.appendingPathComponent(triple, isDirectory: true),
                to: embeddedDestination.appendingPathComponent(triple, isDirectory: true)
            )
        }

        for module in embeddedChildren where module.pathExtension == "swiftmodule" {
            let destination = embeddedDestination.appendingPathComponent(
                module.lastPathComponent,
                isDirectory: true
            )
            var copiedAny = false
            let moduleFiles = try fileManager.contentsOfDirectory(
                at: module,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            for file in moduleFiles where Self.targetTriples.contains(where: {
                file.lastPathComponent.hasPrefix("\($0).")
            }) {
                if !copiedAny {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    copiedAny = true
                }
                try fileManager.copyItem(
                    at: file,
                    to: destination.appendingPathComponent(file.lastPathComponent)
                )
            }
        }
    }

    private func isCurrentBundleValid(
        _ bundle: URL,
        swift: URL,
        compiler: CompilerInspection,
        expectedInputFingerprint: String
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: bundle.path) else { return false }
        do {
            try validateBundle(
                bundle,
                sdkSearchPath: options.stagingRoot,
                swift: swift,
                compiler: compiler,
                expectedInputFingerprint: expectedInputFingerprint
            )
            return true
        } catch {
            print("[CPicoSDK] Existing staged Swift SDK needs refresh: \(error)")
            return false
        }
    }

    private func validateBundle(
        _ bundle: URL,
        sdkSearchPath: URL,
        swift: URL,
        compiler: CompilerInspection,
        expectedInputFingerprint: String
    ) throws {
        try validateInputFingerprint(expectedInputFingerprint, in: bundle)

        let jsonPaths = [
            "info.json",
            "rp2040/swift-sdk.json",
            "rp2350/swift-sdk.json",
            "toolsets/rp2xxx.json",
            "cpicosdk-layout.json",
        ]
        for relativePath in jsonPaths {
            let url = bundle.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: url)
            let value: Any
            do {
                value = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw EnvironmentToolError.invalidMetadata("\(url.path): \(error)")
            }
            if let absolute = firstAbsolutePath(in: value) {
                throw EnvironmentToolError.invalidMetadata(
                    "\(relativePath) contains absolute path \(absolute)"
                )
            }
        }

        let layoutURL = bundle.appendingPathComponent("cpicosdk-layout.json")
        let layout = try JSONDecoder().decode(SDKLayout.self, from: Data(contentsOf: layoutURL))
        guard layout.schemaVersion == "1.0",
              layout.picoSDKPath == "pico-sdk-bundle/sdk/\(options.sdkVersion)",
              layout.picoToolchainPath == "pico-sdk-bundle/toolchain/\(options.toolchainVersion)",
              layout.cmakePath == "pico-sdk-bundle/cmake/v\(options.cmakeVersion)/bin/cmake",
              layout.ninjaPath == "pico-sdk-bundle/ninja/v\(options.ninjaVersion)/ninja",
              layout.picotoolPath == "pico-sdk-bundle/picotool/\(options.picotoolVersion)/picotool/picotool",
              layout.openocdPath == "pico-sdk-bundle/openocd/\(options.openocdVersion)",
              layout.rp2040ConcurrencySupported == compiler.rp2040ConcurrencySupported,
              layout.rp2350ConcurrencySupported == compiler.rp2350ConcurrencySupported
        else {
            throw EnvironmentToolError.invalidMetadata("staged layout does not match requested versions")
        }

        let recordedVersion = try readTrimmed(
            bundle.appendingPathComponent(layout.swiftCompilerVersionFile)
        )
        guard recordedVersion == compiler.version else {
            throw EnvironmentToolError.invalidCompiler(
                "staged runtime compiler version does not match selected compiler"
            )
        }

        for path in requiredPayloadPaths(
            relativeTo: bundle.appendingPathComponent("pico-sdk-bundle", isDirectory: true)
        ) {
            try requirePath(path)
        }
        for path in [
            bundle.appendingPathComponent(
                "swift-resources/embedded/Swift.swiftmodule/armv7em-none-none-eabi.swiftmodule"
            ),
            bundle.appendingPathComponent(
                "swift-resources/embedded/armv7em-none-none-eabi/libswift_Concurrency.a"
            ),
        ] {
            try requirePath(path)
        }

        try normalizeLinks(
            in: bundle,
            relocatedSourceRoot: nil,
            relocatedDestinationRoot: nil
        )
        let listed = try ProcessRunner.checkedCapture(
            executable: swift,
            arguments: ["sdk", "list", "--swift-sdks-path", sdkSearchPath.path]
        ).stdoutString.split(whereSeparator: \.isNewline).map(String.init)
        for sdkID in Self.sdkIDs where !listed.contains(sdkID) {
            throw EnvironmentToolError.invalidMetadata(
                "SwiftPM did not discover SDK ID \(sdkID) under \(sdkSearchPath.path)"
            )
        }
    }

    private func makeInputFingerprint(compiler: CompilerInspection) throws -> String {
        var builder = InputFingerprintBuilder()
        builder.addValue("fingerprint-format", "cpicosdk-swift-sdk-inputs-v1")
        builder.addValue("sdk-version", options.sdkVersion)
        builder.addValue("toolchain-version", options.toolchainVersion)
        builder.addValue("cmake-version", options.cmakeVersion)
        builder.addValue("ninja-version", options.ninjaVersion)
        builder.addValue("picotool-version", options.picotoolVersion)
        builder.addValue("openocd-version", options.openocdVersion)
        builder.addValue("bundle-version", options.bundleVersion)
        builder.addValue(
            "require-rp2040-concurrency",
            String(options.requireRP2040Concurrency)
        )
        builder.addValue("swift-compiler-version", compiler.version)
        builder.addValue("swift-host-triple", compiler.hostTriple)
        builder.addValue(
            "rp2040-concurrency-supported",
            String(compiler.rp2040ConcurrencySupported)
        )
        builder.addValue(
            "rp2350-concurrency-supported",
            String(compiler.rp2350ConcurrencySupported)
        )

        // These files are small, so hash their actual contents. This includes
        // every checked-in template/support file, not only the currently
        // required names, ensuring a template-side change invalidates reuse.
        try builder.addTemplateTree(options.templateDirectory)

        try builder.addMetadataFile(
            compiler.compilerExecutable,
            namespace: "swift-compiler",
            relativePath: compiler.compilerExecutable.lastPathComponent
        )
        try builder.addMetadataTree(
            compiler.runtimeResourcePath.appendingPathComponent("shims", isDirectory: true),
            namespace: "swift-resources/shims"
        )
        try builder.addMetadataTree(
            compiler.runtimeResourcePath
                .appendingPathComponent("clang", isDirectory: true)
                .resolvingSymlinksInPath(),
            namespace: "swift-resources/clang"
        )

        let embeddedChildren = try fileManager.contentsOfDirectory(
            at: compiler.embeddedRuntimePath,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in embeddedChildren {
            let values = try child.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                try builder.addMetadataFile(
                    child,
                    namespace: "swift-resources/embedded-root",
                    relativePath: child.lastPathComponent
                )
            }
        }

        for triple in Self.targetTriples {
            try builder.addMetadataTree(
                compiler.embeddedRuntimePath.appendingPathComponent(triple, isDirectory: true),
                namespace: "swift-resources/embedded-target/\(triple)"
            )
        }

        for module in embeddedChildren where module.pathExtension == "swiftmodule" {
            let moduleFiles = try fileManager.contentsOfDirectory(
                at: module,
                includingPropertiesForKeys: [.isRegularFileKey]
            ).filter { file in
                Self.targetTriples.contains { file.lastPathComponent.hasPrefix("\($0).") }
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in moduleFiles {
                try builder.addMetadataFile(
                    file,
                    namespace: "swift-resources/embedded-module/\(module.lastPathComponent)",
                    relativePath: file.lastPathComponent
                )
            }
        }

        // The Pico bundle is the large input. Metadata detects ordinary edits,
        // replacements, link changes, and tree-shape changes without rereading
        // the roughly 1.7 GB payload on every invocation.
        try builder.addMetadataTree(options.picoSDKBundle, namespace: "pico-sdk-bundle")
        return builder.finalize()
    }

    private func writeInputFingerprint(_ fingerprint: String, to bundle: URL) throws {
        let stamp = InputFingerprintStamp(
            schemaVersion: InputFingerprintStamp.currentSchemaVersion,
            algorithm: "sha256",
            digest: fingerprint
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(stamp)
        data.append(0x0A)
        try data.write(
            to: bundle.appendingPathComponent(InputFingerprintStamp.fileName),
            options: .atomic
        )
    }

    private func validateInputFingerprint(_ expected: String, in bundle: URL) throws {
        let stampURL = bundle.appendingPathComponent(InputFingerprintStamp.fileName)
        guard fileManager.fileExists(atPath: stampURL.path) else {
            throw EnvironmentToolError.invalidMetadata(
                "staged bundle has no input fingerprint"
            )
        }
        let stamp: InputFingerprintStamp
        do {
            stamp = try JSONDecoder().decode(
                InputFingerprintStamp.self,
                from: Data(contentsOf: stampURL)
            )
        } catch {
            throw EnvironmentToolError.invalidMetadata(
                "could not decode staged input fingerprint: \(error)"
            )
        }
        guard stamp.schemaVersion == InputFingerprintStamp.currentSchemaVersion,
              stamp.algorithm == "sha256",
              stamp.digest == expected
        else {
            throw EnvironmentToolError.invalidMetadata(
                "staged bundle input fingerprint does not match current inputs"
            )
        }
    }

    private func normalizeLinks(
        in bundle: URL,
        relocatedSourceRoot: URL?,
        relocatedDestinationRoot: URL?
    ) throws {
        let standardizedRoot = bundle.standardizedFileURL
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            throw EnvironmentToolError.invalidPath(bundle.path)
        }

        var links: [(url: URL, rawTarget: String)] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                links.append((
                    url: url,
                    rawTarget: try fileManager.destinationOfSymbolicLink(atPath: url.path)
                ))
            }
        }

        // Rewrite absolute links first. A relative link can point through one
        // of them, and should be validated only after that target is portable.
        links.sort { left, right in
            (left.rawTarget.hasPrefix("/") ? 0 : 1)
                < (right.rawTarget.hasPrefix("/") ? 0 : 1)
        }

        let sourceRoot = relocatedSourceRoot?.resolvingSymlinksInPath()
        let destinationRoot = relocatedDestinationRoot?.resolvingSymlinksInPath()
        if (sourceRoot == nil) != (destinationRoot == nil) {
            throw EnvironmentToolError.invalidPath("incomplete relocated symlink mapping")
        }
        for (link, rawTarget) in links {
            let resolvedTarget: URL
            if rawTarget.hasPrefix("/") {
                let absoluteTarget = URL(fileURLWithPath: rawTarget)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                if isContained(absoluteTarget, by: resolvedRoot) {
                    resolvedTarget = absoluteTarget
                } else if let sourceRoot,
                          let destinationRoot,
                          isContained(absoluteTarget, by: sourceRoot)
                {
                    let suffix = String(absoluteTarget.path.dropFirst(sourceRoot.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    resolvedTarget = suffix.isEmpty
                        ? destinationRoot
                        : destinationRoot.appendingPathComponent(suffix)
                } else {
                    throw EnvironmentToolError.escapedBundle(link: link.path, target: rawTarget)
                }
            } else {
                resolvedTarget = link.deletingLastPathComponent()
                    .appendingPathComponent(rawTarget)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
            }

            guard fileManager.fileExists(atPath: resolvedTarget.path) else {
                throw EnvironmentToolError.brokenLink(link: link.path, target: rawTarget)
            }
            guard isContained(resolvedTarget, by: resolvedRoot) else {
                throw EnvironmentToolError.escapedBundle(link: link.path, target: rawTarget)
            }

            if rawTarget.hasPrefix("/") {
                let replacement = relativePath(
                    from: link.deletingLastPathComponent(),
                    to: resolvedTarget
                )
                try fileManager.removeItem(at: link)
                try fileManager.createSymbolicLink(
                    atPath: link.path,
                    withDestinationPath: replacement
                )
            }
        }
    }

    private func publish(_ workBundle: URL, to destination: URL) throws {
        let backup = options.stagingRoot.appendingPathComponent(
            ".cpicosdk-rp2xxx.previous.\(UUID().uuidString)",
            isDirectory: true
        )
        var movedOldBundle = false
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
            movedOldBundle = true
        }

        do {
            try fileManager.moveItem(at: workBundle, to: destination)
            if movedOldBundle {
                try removeManagedTemporaryTree(backup)
            }
        } catch {
            if movedOldBundle,
               !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: backup.path)
            {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private func removeManagedTemporaryTree(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let root = options.stagingRoot.standardizedFileURL
        let candidate = url.standardizedFileURL
        let allowedPrefix = [".cpicosdk-rp2xxx.", ".cpicosdk-rp2xxx.previous."]
        guard candidate.deletingLastPathComponent() == root,
              allowedPrefix.contains(where: { candidate.lastPathComponent.hasPrefix($0) })
        else {
            throw EnvironmentToolError.unsafeRemoval(candidate.path)
        }
        try fileManager.removeItem(at: candidate)
    }

    private func makeResult(
        destination: URL,
        swift: URL,
        compiler: CompilerInspection
    ) -> StageResult {
        StageResult(
            schemaVersion: StageResult.currentSchemaVersion,
            swiftSDKsPath: options.stagingRoot.standardizedFileURL.path,
            artifactBundlePath: destination.standardizedFileURL.path,
            swiftCompilerExecutable: compiler.compilerExecutable.standardizedFileURL.path,
            swiftCompilerVersion: compiler.version,
            hostTriple: compiler.hostTriple,
            sdkIDs: Self.sdkIDs,
            rp2040ConcurrencySupported: compiler.rp2040ConcurrencySupported,
            rp2350ConcurrencySupported: compiler.rp2350ConcurrencySupported
        )
    }

    private func firstAbsolutePath(in value: Any) -> String? {
        if let string = value as? String, string.hasPrefix("/") {
            return string
        }
        if let array = value as? [Any] {
            return array.lazy.compactMap(firstAbsolutePath).first
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.lazy.compactMap(firstAbsolutePath).first
        }
        return nil
    }

    private func validateHostTriple(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw EnvironmentToolError.invalidIdentifier(name: "Swift-host-triple", value: value)
        }
    }

    private func requirePath(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw EnvironmentToolError.missingPath(url.path)
        }
    }

    private func executableURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw EnvironmentToolError.invalidCompiler("not executable: \(url.path)")
        }
        return url
    }

    private func findExecutable(named name: String) -> URL? {
        guard let path = environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func readTrimmed(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isContained(_ candidate: URL, by root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private func relativePath(from directory: URL, to destination: URL) -> String {
        let sourceComponents = directory.standardizedFileURL.pathComponents
        let destinationComponents = destination.standardizedFileURL.pathComponents
        var commonCount = 0
        while commonCount < sourceComponents.count,
              commonCount < destinationComponents.count,
              sourceComponents[commonCount] == destinationComponents[commonCount]
        {
            commonCount += 1
        }
        let parents = Array(repeating: "..", count: sourceComponents.count - commonCount)
        let children = Array(destinationComponents.dropFirst(commonCount))
        let components = parents + children
        return components.isEmpty ? "." : components.joined(separator: "/")
    }
}
