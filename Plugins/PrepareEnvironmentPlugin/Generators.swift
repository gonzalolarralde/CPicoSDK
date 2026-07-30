import Foundation
import PackagePlugin

extension PrepareEnvironmentPlugin {
    // MARK: - Env Vars
    
    func generateEnvVars(
        given givenEnvVars: [String: String],
        packageEnv: Env,
        context: PackagePlugin.PluginContext,
        libraryProductName: String?,
        embeddedSwiftRuntimeVendorPath: String
    ) async -> [String: String] {
        let givenEnvVars = Dictionary(
            uniqueKeysWithValues: givenEnvVars
                .filter { key, value in Env.relevantEnvVars.contains(key) }
        )

        // Starts with user-given
        var newEnvVars: [String: String] = givenEnvVars
        
        // Then merges in global vars from env.json
        newEnvVars.merge(
            packageEnv.vars.filter { key, _ in key != "BOARD" },
            uniquingKeysWith: { old, _ in old }
        )

        let selectedCombinationName = await self.resolveSelectedCombination(
            givenEnvVars: givenEnvVars,
            packageEnv: packageEnv,
            context: context
        )

        let selectedCombinationVars = packageEnv.combinations[selectedCombinationName]!.vars
            .filter { !givenEnvVars.keys.contains($0.key) }
        newEnvVars.merge(selectedCombinationVars, uniquingKeysWith: { _, new in new })

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

        if newEnvVars["SWIFT_EMBEDDED_FALLBACK_MODULES"] == nil {
            newEnvVars["SWIFT_EMBEDDED_FALLBACK_MODULES"] = "0"
        }

        if newEnvVars["SWIFT_EMBEDDED_FALLBACK_MODULES"] != "1",
           newEnvVars["SWIFT_EMBEDDED_FALLBACK_PATH"] == nil
        {
            newEnvVars["SWIFT_EMBEDDED_FALLBACK_PATH"] = ""
        }

        if newEnvVars["CPICOSDK_CORE0_STACK_SIZE_BYTES"] == nil {
            newEnvVars["CPICOSDK_CORE0_STACK_SIZE_BYTES"] = "8192"
        }

        if newEnvVars["CPICOSDK_CORE1_STACK_SIZE_BYTES"] == nil {
            newEnvVars["CPICOSDK_CORE1_STACK_SIZE_BYTES"] = "8192"
        }

        let core1StackDefine = "-Xcc -DCPICOSDK_CORE1_STACK_SIZE_BYTES=\(newEnvVars["CPICOSDK_CORE1_STACK_SIZE_BYTES"]!)"
        if let extra = newEnvVars["EXTRA_CONFIG_PARAMS"] {
            if !extra.contains("CPICOSDK_CORE1_STACK_SIZE_BYTES=") {
                newEnvVars["EXTRA_CONFIG_PARAMS"] = extra + " " + core1StackDefine
            }
        } else {
            newEnvVars["EXTRA_CONFIG_PARAMS"] = core1StackDefine
        }

        if newEnvVars["SWIFT_EMBEDDED_FALLBACK_PATH"] == nil,
           newEnvVars["SWIFT_EMBEDDED_FALLBACK_MODULES"] == "1",
           let swiftVersion = newEnvVars["SWIFT_VERSION"] 
        {
            let fallbackPath = embeddedSwiftRuntimeVendorPath
                .appending("/\(swiftVersion)/usr/lib/swift/embedded")

            if !FileManager.default.fileExists(atPath: fallbackPath) {
                // Concurrency runtime needs to be included in the package. If this swift version is meant to be 
                // used in distribution this needs to be fixed before shipping, otherwise Linux users won't have
                // access to the Concurrency runtime.

                #if os(Linux)
                print("[CPicoSDK] ⚠️ \u{001B}[33mWARNING: No embedded Swift runtime found at \(fallbackPath). Swift doesn't ship the Concurrency runtime binaries for embedded targets on Linux, please extract the Concurrency runtime from another toolchain if you intend use concurrency.\u{001B}[0m")
                #else
                print("[CPicoSDK] ⚠️ \u{001B}[33mWARNING: No embedded Swift runtime found at \(fallbackPath). (This warning is only relevant to CPicoSDK maintainers, ignore otherwise)\u{001B}[0m")
                #endif
            }

            newEnvVars["SWIFT_EMBEDDED_FALLBACK_PATH"] = fallbackPath
        }

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

    private func embeddedFallbackSwiftCompilerFlags(envVars: [String: String]) -> [String] {
        guard envVars["SWIFT_EMBEDDED_FALLBACK_MODULES"] == "1" else {
            return []
        }

        if let fallbackPath = envVars["SWIFT_EMBEDDED_FALLBACK_PATH"],
           !fallbackPath.isEmpty,
           FileManager.default.fileExists(atPath: fallbackPath)
        {
            return ["-I", fallbackPath]
        }

        return []
    }

    private func jsonArrayString(_ values: [String], indentation: String = "                    ") throws -> String {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted])
        guard var json = String(data: data, encoding: .utf8) else {
            fatalError("[CPicoSDK] Failed to encode JSON array.")
        }

        json = json.replacingOccurrences(of: "\n", with: "\n\(indentation)")
        return json
    }

    // MARK: - Generated newlib overlay

    func generateNewlibOverlayHeader(envVars: [String: String]) throws -> String {
        let overlayDir = URL(fileURLWithPath: envVars["PLUGIN_OUTPUT_PATH"]!)
            .appending(path: "generated/newlib_overlay")
            .path
        let overlayHeaderPath = overlayDir + "/stdatomic.h"
        let newlibIncludeDir = "\(envVars["SDK_PATH"]!)/include"
        let overlayHeader = """
        #pragma once
        
        #include "\(newlibIncludeDir)/stdint.h"
        #include "\(newlibIncludeDir)/inttypes.h"
        #include "\(newlibIncludeDir)/stdatomic.h"
        """

        if try self.overwriteOrCreateIfNeeded(path: overlayHeaderPath, matchingContent: overlayHeader.data(using: .utf8)) {
            print("[CPicoSDK] Generated/Updated newlib overlay header at \(overlayHeaderPath).")
        } else {
            print("[CPicoSDK] Not updating newlib overlay header as existing one is up-to-date.")
        }

        return overlayDir
    }
    
    func generateToolset(envVars: [String: String], newlibOverlayDir: String) throws {
        let toolsetPath = envVars["TOOLSET_PATH"]!

        let swiftCompilerFlags = [
            "-Xfrontend", "-disable-stack-protector",
            "-enable-experimental-feature", "Embedded",
            "-sdk", envVars["SDK_PATH"]!,
            "-Xcc", "-isystem",
            "-Xcc", newlibOverlayDir,
        ] + embeddedFallbackSwiftCompilerFlags(envVars: envVars) + [
            "-wmo",
        ]
        let swiftCompilerFlagsJSON = try jsonArrayString(swiftCompilerFlags)

        let toolsetJSON = """
        {
            "schemaVersion": "1.0",
            "swiftCompiler": {
                "extraCLIOptions": \(swiftCompilerFlagsJSON)
            },
            "cCompiler": {
                "extraCLIOptions": [
                    "--sysroot", "\(envVars["SDK_PATH"]!)",
                    "-isystem", "\(newlibOverlayDir)"
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
                    "device": "\(envVars["OPENOCD_DEVICE"]!)",
                    "configFiles": [
                        "interface/cmsis-dap.cfg",
                        "\(envVars["OPENOCD_TARGET"]!)"
                    ],
                    "svdFile": "\(envVars["SVD_FILE"]!)",
                    "runToEntryPoint": "main",
                    // Fix for no_flash binaries, where monitor reset halt doesn't do what is expected
                    // also works fine for flash binaries
                    "overrideLaunchCommands": [
                        "monitor reset init",
                        "load \\"${workspaceFolder}/.build/\(envVars["SWIFTPM_TRIPLE"]!)/\(envVars["SWIFT_BUILD_TYPE"]!)/\(envVars["SWIFTPM_PRODUCT"]!).elf\\""
                    ],
                    "openOCDLaunchCommands": [
                        "adapter speed 5000"
                    ],
                    "rttConfig": {
                        "enabled": true,
                        "address": "auto",
                        "decoders": [
                            {
                                "label": "",
                                "port": 0,
                                "type": "console"
                            }
                        ]
                    }
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
        let swiftCompilerFlags = [
            "-enable-experimental-feature", "Embedded",
        ] + embeddedFallbackSwiftCompilerFlags(envVars: envVars)
        let swiftCompilerFlagsJSON = try jsonArrayString(swiftCompilerFlags)

        let sourceKitLSPSettings = """
        {
            "swiftPM": {
                "configuration": "\(envVars["SWIFT_BUILD_TYPE"]!)",
                "triple": "\(envVars["SWIFTPM_TRIPLE"]!)",
                "toolsets": ["\(envVars["TOOLSET_PATH"]!)"],
                "swiftCompilerFlags": \(swiftCompilerFlagsJSON)
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
