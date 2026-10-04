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
    ) async throws -> [String: String] {
        let givenEnvVars = Dictionary(
            uniqueKeysWithValues: givenEnvVars
                .filter { key, value in Env.relevantEnvVars.contains(key) }
        )

        let selectedCombinationName = await self.resolveSelectedCombination(
            givenEnvVars: givenEnvVars,
            packageEnv: packageEnv,
            context: context
        )

        var supplied = givenEnvVars
        supplied["SWIFTPM_PRODUCT"] = supplied["SWIFTPM_PRODUCT"] ?? libraryProductName ?? ""
        let sdkPackagePath = URL(fileURLWithPath: embeddedSwiftRuntimeVendorPath)
            .deletingLastPathComponent().deletingLastPathComponent().path
        let request: [String: Any] = [
            "defaults": try JSONSerialization.jsonObject(with: JSONEncoder().encode(packageEnv)),
            "given": supplied,
            "board": selectedCombinationName,
            "context": [
                "packagePath": context.package.directoryURL.path,
                "pluginOutputPath": context.pluginWorkDirectoryURL.path,
                "sdkPackagePath": sdkPackagePath,
            ],
        ]
        let input = context.pluginWorkDirectoryURL.appending(path: "configuration-request.json")
        let result = context.pluginWorkDirectoryURL.appending(path: "configuration-result.json")
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted, .sortedKeys])
        _ = try overwriteOrCreateIfNeeded(path: input.path, matchingContent: requestData)
        let process = Process()
        process.executableURL = try context.tool(named: "PicoBuildConfigurationTool").url
        process.arguments = ["prepare", "--request", input.path, "--output", result.path]
        guard try await process.asyncRun() == 0 else {
            throw NSError(domain: "CPicoSDK.Configuration", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to resolve preparation configuration.",
            ])
        }
        let resultData = try Data(contentsOf: result)
        let response = try JSONDecoder().decode(ResolvedPreparation.self, from: resultData)
        let newEnvVars = response.variables
        guard let resultObject = try JSONSerialization.jsonObject(with: resultData) as? [String: Any],
              let installation = resultObject["installation"] as? [String: Any] else {
            throw NSError(domain: "CPicoSDK.Configuration", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Configuration resolver did not return an installation record.",
            ])
        }
        installationConfiguration = try JSONSerialization.data(
            withJSONObject: installation, options: [.prettyPrinted, .sortedKeys]
        )

        // Show some information about given vars first
        for (envVar, value) in givenEnvVars {
            print("[CPicoSDK] Using provided env var \(envVar): \(value)")
        }

        for (envVar, value) in newEnvVars.filter({ !givenEnvVars.keys.contains($0.key) }).sorted(by: { $0.key < $1.key }) {
            print("[CPicoSDK] Using default env var \(envVar): \(value)")
            output += "export \(envVar)=\(shellQuote(value))\n"
        }

        for (name, specializedVars) in response.specializations.sorted(by: { $0.key < $1.key }) {
            print("[CPicoSDK] Specializing env vars for combination: \(name)")
            
            for envVar in specializedVars.keys.sorted() {
                print(
                    "[CPicoSDK] \(newEnvVars.keys.contains(envVar) ? "Overriding" : "Using") specialized env var CPICOSDK_\(name)_\(envVar): \(specializedVars[envVar]!)"
                )
                output += "export CPICOSDK_\(name)_\(envVar)=\(shellQuote(specializedVars[envVar]!))\n"
            }
        }
        
        return newEnvVars
    }

    private struct ResolvedPreparation: Decodable {
        let variables: [String: String]
        let specializations: [String: [String: String]]
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    
    // MARK: - Bash Functions
    
    func generateBashFunctions() {
        self.output += """
        function configure_rp2xxx_stdio {
            if [[ "${1:-}" == "--flash" || "${1:-}" == "--picotool" ]]; then
                export AUTO_STDIO="usb"
            elif [[ "${1:-}" == "--cortex-debug" ]]; then
                export AUTO_STDIO="uart"
            else
                echo "[CPicoSDK] Warning: Launcher not specified. Defaulting to USB stdio." >&2
                export AUTO_STDIO="usb"
            fi
        }

        function configure_rp2xxx_build {
            "$SWIFTLY_PATH" install || return
            local compiler="${CPICOSDK_SWIFT_EXEC:-}"
            if [[ -z "$compiler" ]]; then
                compiler="$("$SWIFTLY_PATH" run which swiftc)" || return
            fi
            if [[ ! -x "$compiler" ]]; then
                echo "[CPicoSDK] Swift compiler is not executable: $compiler" >&2
                return 1
            fi
            export CPICOSDK_SWIFT_EXEC="$compiler"

            # Bind the generated toolset only after swiftly install has run.
            local toolchain="$PLUGIN_OUTPUT_PATH/generated/swift-toolchain"
            local prefix="$(dirname -- "$(dirname -- "$compiler")")"
            mkdir -p "$(dirname -- "$toolchain")" || return
            if [[ -e "$toolchain" && ! -L "$toolchain" ]]; then
                echo "[CPicoSDK] Expected a toolchain symlink: $toolchain" >&2
                return 1
            fi
            if [[ "$(readlink "$toolchain" || true)" != "$prefix" ]]; then
                ln -sfn "$prefix" "$toolchain" || return
            fi

            configure_rp2xxx_stdio "$@"
        }

        function finalize_rp2xxx_binary {
            configure_rp2xxx_stdio "$@"
            "$SWIFTLY_PATH" run swift package \\
                -Xswiftc -Xfrontend -Xswiftc -disable-availability-checking \\
                finalize-rp2xxx-binary "$SWIFTPM_PRODUCT" \\
                "$@" \\
                --allow-writing-to-package-directory
        }

        function firmware_products_directory {
            local configuration
            case "$SWIFT_BUILD_TYPE" in
                debug) configuration=Debug ;;
                release) configuration=Release ;;
                *) echo "Unsupported Swift build configuration: $SWIFT_BUILD_TYPE" >&2; return 1 ;;
            esac

            # Published outputs of this experiment's Firmware wrapper package.
            printf '%s\\n' "Firmware/.build/out/Products/${configuration}-none-${SWIFTPM_TRIPLE%%-*}"
        }

        function memory_map_report {
            local products_directory
            if products_directory="$(firmware_products_directory)" &&
                sh ../utils/swiftpm-experimental.sh package memory-map-report \\
                --elf "$products_directory/$SWIFTPM_PRODUCT.elf" \\
                --artifact-stats --no-sections; then
                return 0
            fi

            echo "[CPicoSDK] Warning: Memory map report failed; firmware build is unaffected. See diagnostics above." >&2
            return 0
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

                "$PICOTOOL_PATH" load "$(firmware_products_directory)/${SWIFTPM_PRODUCT}.uf2"
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
            "-Xcc", "-isystem",
            "-Xcc", "\(envVars["SDK_PATH"]!)/include",
        ] + embeddedFallbackSwiftCompilerFlags(envVars: envVars) + [
            "-wmo",
        ]
        let swiftCompilerFlagsJSON = try jsonArrayString(swiftCompilerFlags)
        let compilerPath = envVars["CPICOSDK_SWIFT_EXEC"]
            ?? "\(envVars["PLUGIN_OUTPUT_PATH"]!)/generated/swift-toolchain/bin/swiftc"
        let compilerPathJSON = String(decoding: try JSONEncoder().encode(compilerPath), as: UTF8.self)

        let toolsetJSON = """
        {
            "schemaVersion": "1.0",
            "swiftCompiler": {
                "path": \(compilerPathJSON),
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
            },
            "librarian": {
                "path": "\(envVars["PICO_TOOLCHAIN_PATH"]!)/bin/arm-none-eabi-ar"
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
