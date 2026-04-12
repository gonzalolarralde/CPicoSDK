import Foundation
import PackagePlugin

extension PrepareEnvironmentPlugin {
    // MARK: - Env Vars
    
    func generateEnvVars(given givenEnvVars: [String: String], packageEnv: Env, context: PackagePlugin.PluginContext, libraryProductName: String?) async throws -> [String: String] {
        let givenEnvVars = Dictionary(
            uniqueKeysWithValues: givenEnvVars
                .filter { key, value in Env.relevantEnvVars.contains(key) }
        )

        // Starts with user-given
        var newEnvVars: [String: String] = givenEnvVars
        
        // Then merges in global vars from env.json
        newEnvVars.merge(packageEnv.vars, uniquingKeysWith: { old, _ in old })

        // Some basic checks
        guard let buildType = BuildType(rawValue: newEnvVars["BUILD_TYPE"] ?? "") else {
            fatalError("[CPicoSDK] Couldn't find a valid BUILD_TYPE. Supported types are: 'Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel', got \(newEnvVars["BUILD_TYPE"] ?? "null")")
        }

        // Some dynamically generated vars are provided
        if newEnvVars["SWIFT_BUILD_TYPE"] == nil {
            newEnvVars["SWIFT_BUILD_TYPE"] = buildType.swiftBuildType
        }

        if newEnvVars["EXTRA_CONFIG_PARAMS"] == nil {
            newEnvVars["EXTRA_CONFIG_PARAMS"] = buildType.extraConfigParams
        }

        // TODO: Remove this when upgrading to Swift 6.3
        // https://github.com/swiftlang/swift/issues/81272
        #if os(Linux)
        let linuxSwiftPMFlags = "--disable-sandbox --disable-build-manifest-caching --manifest-cache none"
        if let extra = newEnvVars["EXTRA_CONFIG_PARAMS"] {
            if !extra.contains("--disable-sandbox") {
                newEnvVars["EXTRA_CONFIG_PARAMS"] = extra + " " + linuxSwiftPMFlags
            }
        } else {
            newEnvVars["EXTRA_CONFIG_PARAMS"] = linuxSwiftPMFlags
        }
        #endif

        if newEnvVars["TOOLSET_PATH"] == nil {
            newEnvVars["TOOLSET_PATH"] = context.package.directoryURL.relativePath.appending("/toolset.json")
        }

        if newEnvVars["PACKAGE_PATH"] == nil {
            newEnvVars["PACKAGE_PATH"] = context.package.directoryURL.relativePath
        }

        if newEnvVars["PLUGIN_OUTPUT_PATH"] == nil {
            newEnvVars["PLUGIN_OUTPUT_PATH"] = context.pluginWorkDirectoryURL.relativePath
        }
        
        if newEnvVars["SWIFTPM_PRODUCT"] == nil {
            newEnvVars["SWIFTPM_PRODUCT"] = libraryProductName ?? ""
        }
        
        if newEnvVars["RELEVANT_ENV_VARS"] == nil {
            newEnvVars["RELEVANT_ENV_VARS"] = Env.relevantEnvVars.joined(separator: ",")
        }

        try await self.enrichSwiftToolchainPaths(envVars: &newEnvVars)

        // Show some information about given vars first
        for (envVar, value) in givenEnvVars {
            print("[CPicoSDK] Using provided env var \(envVar): \(value)")
        }

        newEnvVars = self.resolve(envVars: newEnvVars)

        for (envVar, value) in newEnvVars.filter({ !givenEnvVars.keys.contains($0.key) }) {
            print("[CPicoSDK] Using default env var \(envVar): \(value)")
            output += "export \(envVar)=\"\(value)\"\n"
        }

        var combinationsWithErrors = false
        
        for (name, combination) in packageEnv.combinations {
            print("[CPicoSDK] Specializing env vars for combination: \(name)")
            
            let combinationSpecializedVars = combination.vars
                .filter { !givenEnvVars.keys.contains($0.key) } // Don't override given vars, only globals.
            
            // Make sure overrides are resolved against globals + given.
            let resolvedCombinationSpecializedVars = self.resolve(
                envVars: newEnvVars.merging(
                    combinationSpecializedVars,
                    uniquingKeysWith: { _, new in new }
                )
            )
            
            // Print and dump vars after resolving
            for envVar in combinationSpecializedVars.keys {
                print(
                    "[CPicoSDK] \(newEnvVars.keys.contains(envVar) ? "Overriding" : "Using") specialized env var CPICOSDK_\(name)_\(envVar): \(resolvedCombinationSpecializedVars[envVar]!)"
                )
                output += "export CPICOSDK_\(name)_\(envVar)=\"\(resolvedCombinationSpecializedVars[envVar]!)\"\n"
            }
            
            // Make sure all relevant env vars are complete for this combination.
            let missingEnvVars = Env.relevantEnvVars.filter { !resolvedCombinationSpecializedVars.keys.contains($0) }
            if missingEnvVars.count > 0 {
                print("[CPicoSDK] ERROR: Missing env variables: [\(missingEnvVars.joined(separator: ", "))] - (Combination: \(name))")
                combinationsWithErrors = true
            }
        }
        
        guard !combinationsWithErrors else { fatalError("[CPicoSDK] Some of the mandatory env variables are missing. Please check logs.")}
        
        return newEnvVars
    }
    
    // MARK: - Bash Functions
    
    func generateBashFunctions() {
        self.output += """
        function finalize_rp2xxx_binary {
            if [[ "${1:-}" == "--flash" || "${1:-}" == "--picotool" ]]; then
                export AUTO_STDIO="usb"
            elif [[ "${1:-}" == "--cortex-debug" ]]; then
                export AUTO_STDIO="uart"
            else
                echo "[CPicoSDK] Warning: Launcher not specified. Defaulting to USB stdio." >&2
                export AUTO_STDIO="usb"
            fi

            "$SWIFTLY_PATH" run swift package finalize-rp2xxx-binary "$SWIFTPM_PRODUCT" \\
                "$@" \\
                --allow-writing-to-package-directory
        }

        function flash_if_needed {
            if [[ "${1:-}" == "--flash" ]]; then
                while true; do
                    if "$PICOTOOL_PATH" info >/dev/null 2>&1; then
                        echo "Device found!"
                        break
                    fi

                    echo "Waiting for device in BOOTSEL mode to become available. Connect the device while pushing the BOOT button... (trying again in 2 seconds)"
                    sleep 2
                done

                "$PICOTOOL_PATH" load ".build/${SWIFTPM_TRIPLE}/${SWIFT_BUILD_TYPE}/${SWIFTPM_PRODUCT}.uf2"
                "$PICOTOOL_PATH" reboot
            fi
        }
        """ + "\n"
    }

    // MARK: - toolset.json
    
    func generateToolset(envVars: [String: String], customResourceDir: String? = nil) throws {
        let toolsetPath = envVars["TOOLSET_PATH"]!
        let resourceDir = customResourceDir ?? envVars["SWIFT_RESOURCE_DIR"]!

        let toolsetJSON = """
        {
            "schemaVersion": "1.0",
            "swiftCompiler": {
                "extraCLIOptions": [
                    "-Xfrontend", "-disable-stack-protector",
                    "-enable-experimental-feature", "Embedded",
                    "-sdk", "\(envVars["SDK_PATH"]!)",
                    "-resource-dir", "\(resourceDir)",
                    "-wmo"
                ]
            },
            "cCompiler": {
                "extraCLIOptions": [
                    "--sysroot", "\(envVars["SDK_PATH"]!)"
                ]
            },
            "linker": {
                "path": "\(envVars["LD_PATH"]!)",
                "extraCLIOptions": [
                    "-static", "-L\(envVars["SDK_PATH"]!)/lib"
                ]
            }
        }
        """.data(using: .utf8)

        if try self.overwriteOrCreateIfNeeded(path: toolsetPath, matchingContent: toolsetJSON) {
            print("[CPicoSDK] Generated/Updated toolset.json at \(toolsetPath). Disable this generation with --disable-toolset.")
        } else {
            print("[CPicoSDK] Not generating new toolset.json as existing one is up-to-date.")
        }
    }

    // MARK: - Embedded _Concurrency shim

    /// On Linux, the Swift toolchain may ship `_Concurrency.swiftmodule` only for the host
    /// architecture (e.g. `x86_64-unknown-linux-gnu`) inside its `embedded/` directory.
    /// When the bare-metal target (e.g. `armv7em-none-none-eabi`) variant is absent, the
    /// Swift compiler emits "could not find module '_Concurrency' for target …" and the
    /// build fails.
    ///
    /// This method detects that situation and, when necessary:
    ///   1. Compiles a minimal `_Concurrency` stub for the embedded target using the same
    ///      toolchain (and `-parse-stdlib` so Builtin types are accessible).
    ///   2. Builds a shadow resource directory in the plugin work folder that mirrors the
    ///      real one via symlinks but replaces the `_Concurrency.swiftmodule` bundle with
    ///      a version that also contains the freshly compiled stub.
    ///   3. Returns the path of that shadow resource directory so the caller can pass it
    ///      to the Swift compiler as `-resource-dir`.
    ///
    /// Returns `nil` when no shim is needed (the module already exists, or on non-Linux).
    func setupConcurrencyShim(envVars: [String: String], pluginWorkDir: String) async throws -> String? {
        let embeddedModulesPath = envVars["SWIFT_EMBEDDED_MODULES_PATH"]!
        let realResourceDir = envVars["SWIFT_RESOURCE_DIR"]!
        let swiftcPath = envVars["SWIFT_TOOLCHAIN_PATH"]! + "/usr/bin/swiftc"

        // Determine the target triple for the stub.  The only embedded target that
        // currently ships without a _Concurrency module on Linux is armv7em.
        let embeddedTarget = "armv7em-none-none-eabi"
        let armv7emModulePath = embeddedModulesPath
            + "/_Concurrency.swiftmodule/\(embeddedTarget).swiftmodule"

        guard !FileManager.default.fileExists(atPath: armv7emModulePath) else {
            return nil // Module already present – nothing to do.
        }

        print("[CPicoSDK] _Concurrency module missing for \(embeddedTarget); generating shim resource dir.")

        // Paths inside the plugin work directory.
        let shimDir = pluginWorkDir + "/embedded-shims"
        let shimEmbeddedDir = shimDir + "/embedded"
        let concurrencyBundleDir = shimEmbeddedDir + "/_Concurrency.swiftmodule"
        let stubModuleOutputPath = concurrencyBundleDir + "/\(embeddedTarget).swiftmodule"
        let stubSourcePath = shimDir + "/_ConcurrencyStub.swift"

        let fileManager = FileManager.default

        // Create directory structure (idempotent).
        try fileManager.createDirectory(atPath: concurrencyBundleDir, withIntermediateDirectories: true)

        // --- Symlink shims/ from the real resource dir ---
        let shimsLink = shimDir + "/shims"
        if !fileManager.fileExists(atPath: shimsLink) {
            try fileManager.createSymbolicLink(
                atPath: shimsLink,
                withDestinationPath: realResourceDir + "/shims"
            )
        }

        // --- Symlink all embedded modules except _Concurrency.swiftmodule ---
        let realEmbeddedContents = (try? fileManager.contentsOfDirectory(atPath: embeddedModulesPath)) ?? []
        for item in realEmbeddedContents where item != "_Concurrency.swiftmodule" {
            let linkPath = shimEmbeddedDir + "/" + item
            if !fileManager.fileExists(atPath: linkPath) {
                try fileManager.createSymbolicLink(
                    atPath: linkPath,
                    withDestinationPath: embeddedModulesPath + "/" + item
                )
            }
        }

        // --- Symlink any existing arch-specific _Concurrency variants into our bundle ---
        let realBundleContents = (try? fileManager.contentsOfDirectory(
            atPath: embeddedModulesPath + "/_Concurrency.swiftmodule"
        )) ?? []
        for item in realBundleContents {
            let linkPath = concurrencyBundleDir + "/" + item
            if !fileManager.fileExists(atPath: linkPath) {
                try fileManager.createSymbolicLink(
                    atPath: linkPath,
                    withDestinationPath: embeddedModulesPath + "/_Concurrency.swiftmodule/" + item
                )
            }
        }

        // --- Compile the stub if not already done ---
        guard !fileManager.fileExists(atPath: stubModuleOutputPath) else {
            print("[CPicoSDK] Reusing existing _Concurrency shim at \(stubModuleOutputPath).")
            return shimDir
        }

        // Write the stub source file.
        let stubSource = Self.embeddedConcurrencyStubSource
        try stubSource.write(toFile: stubSourcePath, atomically: true, encoding: .utf8)

        // Compile stub → .swiftmodule for the embedded target.
        let compileProcess = Process()
        compileProcess.executableURL = URL(filePath: swiftcPath, directoryHint: .notDirectory)
        compileProcess.arguments = [
            "-enable-experimental-feature", "Embedded",
            "-target", embeddedTarget,
            "-I", embeddedModulesPath,
            "-parse-stdlib",
            "-wmo",
            "-module-name", "_Concurrency",
            "-emit-module",
            "-emit-module-path", stubModuleOutputPath,
            stubSourcePath,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        compileProcess.standardOutput = stdoutPipe
        compileProcess.standardError = stderrPipe

        let status = try await compileProcess.asyncRun()
        if status != 0 {
            let errOutput = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            print("[CPicoSDK] Warning: Failed to compile _Concurrency shim (exit \(status)):\n\(errOutput)")
            return nil
        }

        print("[CPicoSDK] Compiled _Concurrency shim for \(embeddedTarget) at \(stubModuleOutputPath).")
        return shimDir
    }

    // Source of the minimal _Concurrency module stub compiled for bare-metal embedded targets.
    // Uses -parse-stdlib so that Builtin types (Builtin.Executor, Builtin.NativeObject, etc.)
    // are accessible.  The declarations mirror the subset of _Concurrency that CPicoConcurrency
    // actually uses: Actor, GlobalActor, Task, UnsafeCurrentTask, UnsafeContinuation,
    // withUnsafeCurrentTask, withUnsafeContinuation, and CancellationError.
    private static let embeddedConcurrencyStubSource: String = #"""
        import Swift

        @frozen
        public struct UnownedSerialExecutor: @unchecked Sendable {
            @usableFromInline internal var executor: Builtin.Executor
            @_alwaysEmitIntoClient
            public init(_ executor: Builtin.Executor) { self.executor = executor }
            @_alwaysEmitIntoClient
            public init(ordinary executor: some SerialExecutor) {
                self.executor = Builtin.buildOrdinarySerialExecutorRef(executor)
            }
        }

        public protocol Executor : AnyObject, Sendable {
            func enqueue(_ job: consuming ExecutorJob)
        }
        public protocol SerialExecutor : Executor {}

        @frozen
        public struct ExecutorJob : @unchecked Sendable {
            @usableFromInline internal var context: Builtin.NativeObject
        }

        public protocol Actor : AnyObject, Sendable {
            nonisolated var unownedExecutor: UnownedSerialExecutor { get }
        }

        public protocol GlobalActor {
            associatedtype ActorType : Actor
            static var shared: ActorType { get }
        }

        @frozen
        public struct Task<Success: Sendable, Failure: Error>: Sendable {
            @usableFromInline internal let _task: Builtin.NativeObject
            @_alwaysEmitIntoClient
            internal init(_ task: Builtin.NativeObject) { self._task = task }
            public var isCancelled: Bool { @_silgen_name("swift_task_isCancelled") get }
        }

        @frozen
        public struct UnsafeCurrentTask: Sendable {
            @usableFromInline internal let _task: Builtin.NativeObject
            @_alwaysEmitIntoClient
            internal init(_ task: Builtin.NativeObject) { self._task = task }
            public var isCancelled: Bool { @_silgen_name("swift_task_isCancelled") get }
        }

        @_silgen_name("swift_task_getCurrent")
        @usableFromInline internal func _getCurrentAsyncTask() -> Builtin.NativeObject?

        @_alwaysEmitIntoClient
        public func withUnsafeCurrentTask<T>(
            body: (UnsafeCurrentTask?) throws -> T
        ) rethrows -> T {
            guard let task = _getCurrentAsyncTask() else { return try body(nil) }
            Builtin.retain(task)
            return try body(UnsafeCurrentTask(task))
        }

        @frozen
        public struct UnsafeContinuation<T, E: Error>: Sendable {
            @usableFromInline internal var context: Builtin.RawUnsafeContinuation
            @_alwaysEmitIntoClient
            internal init(_ context: Builtin.RawUnsafeContinuation) { self.context = context }
            @_alwaysEmitIntoClient
            public func resume(returning value: __owned T) where E == Never {
                Builtin.resumeNonThrowingContinuationReturning(context, value)
            }
            @_alwaysEmitIntoClient
            public func resume() where T == Void, E == Never { resume(returning: ()) }
        }

        @_alwaysEmitIntoClient
        public func withUnsafeContinuation<T>(
            _ fn: (UnsafeContinuation<T, Never>) -> Void
        ) async -> T {
            return await Builtin.withUnsafeContinuation {
                (continuation: Builtin.RawUnsafeContinuation) -> Void in
                fn(UnsafeContinuation<T, Never>(continuation))
            }
        }

        public struct CancellationError : Error {
            public init() {}
        }
        """#

    // MARK: - .swift-version
    
    func syncSwiftVersion(packageURL: String, envVars: [String: String]) throws {
        let swiftVersionFilePath = packageURL.appending("/.swift-version")
        let swiftVersion = envVars["SWIFT_VERSION"]!

        if try self.overwriteOrCreateIfNeeded(path: swiftVersionFilePath, matchingContent: swiftVersion.data(using: .utf8)!) {
            print("[CPicoSDK] Generated/Updated .swift-version to \(swiftVersion). Disable this generation with --disable-swift-version.")
        } else {
            print("[CPicoSDK] Not updating .swift-version as existing one is up-to-date.")
        }
    }

    // MARK: - .vscode

    func generateVSCodeSettings(context: PackagePlugin.PluginContext, envVars: [String: String]) throws {
        let vscodeTasksFilePath = ".vscode/tasks.json"
        let vscodeTasksSettings = """
        {
            "version": "2.0.0",
            "tasks": [
                {
                    "label": "Compile and Flash Project (cortex-debug) [CPicoSDK]",
                    "type": "process",
                    "command": "${workspaceFolder}/build.sh",
                    "args": ["--cortex-debug", "--incremental"],
                    "options": {
                        "cwd": "${workspaceFolder}",
                    },
                    "group": "build",
                    "presentation": {
                        "reveal": "always",
                        "panel": "dedicated"
                    },
                    "problemMatcher": "$swiftc",
                },
                {
                    "label": "Compile and Flash Project (picotool) [CPicoSDK]",
                    "type": "process",
                    "command": "${workspaceFolder}/build.sh",
                    "args": ["--flash", "--incremental"],
                    "options": {
                        "cwd": "${workspaceFolder}",
                    },
                    "group": "build",
                    "presentation": {
                        "reveal": "always",
                        "panel": "dedicated"
                    },
                    "problemMatcher": "$swiftc",
                },
            ]
        }
        """.data(using: .utf8)

        if try self.overwriteOrCreateIfNeeded(path: vscodeTasksFilePath, matchingContent: vscodeTasksSettings) {
            print("[CPicoSDK] Generated/Updated .vscode/tasks.json. Disable this generation with --disable-vscode-settings.")
        } else {
            print("[CPicoSDK] Not updating .vscode/tasks.json as existing one is up-to-date.")
        }

        let extensionsFilePath = ".vscode/extensions.json"
        let extensionsSettings = """
        {
            "recommendations": [
                "marus25.cortex-debug",
                "ms-vscode.vscode-serial-monitor",
                "raspberry-pi.raspberry-pi-pico",
                "swiftlang.swift-vscode"
            ]
        }
        """.data(using: .utf8)

        if try self.overwriteOrCreateIfNeeded(path: extensionsFilePath, matchingContent: extensionsSettings) {
            print("[CPicoSDK] Generated/Updated .vscode/extensions.json. Disable this generation with --disable-vscode-settings.")
        } else {
            print("[CPicoSDK] Not updating .vscode/extensions.json as existing one is up-to-date.")
        }

        let launchFilePath = ".vscode/launch.json"
        let launchSettings = """
        {
            "version": "0.2.0",
            "configurations": [
                {
                    // Same settings as pico-vscode.
                    "preLaunchTask": "Compile and Flash Project (cortex-debug) [CPicoSDK]",
                    "name": "SwiftPM: \(envVars["SWIFTPM_PRODUCT"]!) - Debug (Cortex-Debug) [CPicoSDK]",
                    "cwd": "\(envVars["OPENOCD_PATH"]!)/scripts",
                    "executable": "${workspaceFolder}/.build/\(envVars["SWIFTPM_TRIPLE"]!)/\(envVars["SWIFT_BUILD_TYPE"]!)/\(envVars["SWIFTPM_PRODUCT"]!).elf",
                    "request": "launch",
                    "type": "cortex-debug",
                    "servertype": "openocd",
                    "serverpath": "\(envVars["OPENOCD_PATH"]!)/openocd.exe",
                    "gdbPath": "\(envVars["GDB_PATH"]!)",
                    "device": "RP2350",
                    "configFiles": [
                        "interface/cmsis-dap.cfg",
                        "target/rp2350.cfg"
                    ],
                    "svdFile": "\(envVars["SDK_PATH"]!)/src/rp2350/hardware_regs/RP2350.svd",
                    "runToEntryPoint": "main",
                    // Fix for no_flash binaries, where monitor reset halt doesn't do what is expected
                    // also works fine for flash binaries
                    "overrideLaunchCommands": [
                    "monitor reset init",
                    "load \\"${workspaceFolder}/.build/\(envVars["SWIFTPM_TRIPLE"]!)/\(envVars["SWIFT_BUILD_TYPE"]!)/\(envVars["SWIFTPM_PRODUCT"]!).elf\\""
                    ],
                    "openOCDLaunchCommands": [
                    "adapter speed 5000"
                    ]
                },
                {
                    "preLaunchTask": "Compile and Flash Project (picotool) [CPicoSDK]",
                    "name": "SwiftPM: \(envVars["SWIFTPM_PRODUCT"]!) - Flash (picotool) [CPicoSDK]",
                    "request": "launch",
                    "type": "lldb",
                    "program": "/usr/bin/true", // Dummy program to satisfy cppdbg requirements
                    "cwd": "${workspaceFolder}",
                    "stopOnEntry": false
                },
            ]
        }
        """.data(using: .utf8)

        if try self.overwriteOrCreateIfNeeded(path: launchFilePath, matchingContent: launchSettings) {
            print("[CPicoSDK] Generated/Updated .vscode/launch.json. Disable this generation with --disable-vscode-settings.")
        } else {
            print("[CPicoSDK] Not updating .vscode/launch.json as existing one is up-to-date.")
        }
    }

    // MARK: - .sourcekit-lsp/config.json
    
    func generateSourceKitLSPSettings(packageURL: String, envVars: [String: String]) throws {
        let sourceKitLSPFilePath = packageURL.appending("/.sourcekit-lsp/config.json")

        let sourceKitLSPSettings = """
        {
            "swiftPM": {
                "configuration": "\(envVars["SWIFT_BUILD_TYPE"]!)",
                "triple": "\(envVars["SWIFTPM_TRIPLE"]!)",
                "toolsets": ["\(envVars["TOOLSET_PATH"]!)"],
                "swiftCompilerFlags": [
                    "-enable-experimental-feature", "Embedded"
                ]
            }
        }
        """.data(using: .utf8)

        if try self.overwriteOrCreateIfNeeded(path: sourceKitLSPFilePath, matchingContent: sourceKitLSPSettings) {
            print("[CPicoSDK] Generated/Updated .sourcekit-lsp/config.json. Disable this generation with --disable-sourcekit-lsp-settings.")
        } else {
            print("[CPicoSDK] Not updating .sourcekit-lsp/config.json as existing one is up-to-date.")
        }
    }

    // MARK: - Preparation Script

    func generatePreparationScript(dumpPrepScriptPath: String) throws {
        if try self.overwriteOrCreateIfNeeded(path: dumpPrepScriptPath, matchingContent: self.output.data(using: .utf8)) {
            print("[CPicoSDK] Generated/Updated preparation script at \(dumpPrepScriptPath).")
        } else {
            print("[CPicoSDK] Not updating preparation script as existing one is up-to-date.")
        }
    }

    func overwriteOrCreateIfNeeded(path: String, matchingContent: Data?) throws -> Bool {
        let fileManager = FileManager()
        try fileManager.ensureDirectoryExists(at: path, isDirectory: false)
        if fileManager.fileExists(atPath: path),
            let content = fileManager.contents(atPath: path),
            content == matchingContent
        {
            return false
        } else {
            guard fileManager.createFile(atPath: path, contents: matchingContent) else {
                fatalError("[CPicoSDK] Couldn't write file at path \(path).")
            }
            return true
        }
    }
}
