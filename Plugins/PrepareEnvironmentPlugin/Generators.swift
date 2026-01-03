import Foundation
import PackagePlugin

extension PrepareEnvironmentPlugin {
    // MARK: - Env Vars
    
    func generateEnvVars(given givenEnvVars: [String: String], packageEnvs: [String: String], context: PackagePlugin.PluginContext) -> [String: String] {
        let givenEnvVars = Dictionary(
            uniqueKeysWithValues: givenEnvVars
                .filter { key, value in relevantEnvVars.contains(key) }
        )

        var newEnvVars: [String: String] = givenEnvVars
        newEnvVars.merge(packageEnvs, uniquingKeysWith: { old, _ in old })

        guard let buildType = BuildType(rawValue: newEnvVars["BUILD_TYPE"] ?? "") else {
            fatalError("Couldn't find a valid BUILD_TYPE. Supported types are: 'Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel', got \(newEnvVars["BUILD_TYPE"] ?? "null")")
        }

        if newEnvVars["SWIFT_BUILD_TYPE"] == nil {
            newEnvVars["SWIFT_BUILD_TYPE"] = buildType.swiftBuildType
        }

        if newEnvVars["TOOLSET_PATH"] == nil {
            newEnvVars["TOOLSET_PATH"] = context.package.directoryURL.relativePath.appending("/toolset.json")
        }

        if newEnvVars["PACKAGE_PATH"] == nil {
            newEnvVars["PACKAGE_PATH"] = context.package.directoryURL.relativePath
        }

        if newEnvVars["PLUGIN_OUTPUT_PATH"] == nil {
            newEnvVars["PLUGIN_OUTPUT_PATH"] = context.pluginWorkDirectoryURL.relativePath
        }
        
        let libraryProducts = context.package
            .products(ofType: LibraryProduct.self)
            .filter { $0.kind == .static }
            .filter { product in
                product.targets.contains(where: { target in
                    target.dependencies.contains(where: { dependency in
                        if case let .product(product) = dependency, product.name == "CPicoSDK" {
                            return true
                        } else {
                            return false
                        }
                    })
                })
            }
        
        guard let libraryProduct = libraryProducts.first else {
            fatalError("At least one static library product that depends on CPicoSDK is needed.")
        }
        
        if libraryProducts.count > 1 {
            print("[CPicoSDK] Warning: More than one static library product depends on CPicoSDK. Multiple targets are not yet supported. Using the first one found: \(libraryProduct.name). All targets: [\(libraryProducts.map(\.name).joined(separator: ", "))]")
        }
        
        newEnvVars["SWIFTPM_PRODUCT"] = libraryProduct.name

        for (envVar, value) in givenEnvVars {
            print("[CPicoSDK] Using provided env var \(envVar): \(value)")
        }

        let missingEnvVars = relevantEnvVars.filter { !newEnvVars.keys.contains($0) }
        if missingEnvVars.count > 0 {
            fatalError("Cannot continue. Missing env variables: [\(missingEnvVars.joined(separator: ", "))]")
        }

        newEnvVars = self.resolve(envVars: newEnvVars)

        for envVar in relevantEnvVars.filter({ !givenEnvVars.keys.contains($0) }) {
            print("[CPicoSDK] Using default env var \(envVar): \(newEnvVars[envVar]!)")
            output += "export \(envVar)=\"\(newEnvVars[envVar]!)\"\n"
        }

        return newEnvVars
    }

    func resolve(envVars: [String: String]) -> [String: String] {
        var resolvedEnvVars = envVars

        var iterations = 10
        let regex = /\$\{(.*?)\}/

        var varsToResolve = resolvedEnvVars.filter { $0.value.contains("$") }
        repeat {
            for (key, value) in varsToResolve {
                resolvedEnvVars[key] = value.replacing(regex) { match in
                    if let replacement = resolvedEnvVars[String(match.1)] {
                        replacement
                    } else {
                        String(match.0)
                    }
                }
            }
            varsToResolve = resolvedEnvVars.filter { $0.value.contains("$") }
            iterations -= 1
        } while iterations > 0 && varsToResolve.count > 0

        if varsToResolve.count > 0 {
            let unresolvedVars = varsToResolve.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            fatalError("Couldn't resolve all env variables. The only var replacement format accepted is ${VAR}. Remaining: [\(unresolvedVars)]")
        }

        return resolvedEnvVars
    }
    
    // MARK: - Bash Functions
    
    func generateBashFunctions() {
        self.output += """
        function finalize_rp2xxx_binary {
            "$SWIFTLY_PATH" run swift package finalize-rp2xxx-binary "$SWIFTPM_PRODUCT" \\
                --incremental \\
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
    
    func generateToolset(envVars: [String: String]) throws {
        let toolsetPath = envVars["TOOLSET_PATH"]!

        let toolsetJSON = """
        {
            "schemaVersion": "1.0",
            "swiftCompiler": {
                "extraCLIOptions": [
                    "-Xfrontend", "-disable-stack-protector",
                    "-enable-experimental-feature", "Embedded",
                    "-sdk", "\(envVars["SDK_PATH"]!)", "-wmo"
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
                    "label": "Compile Project [CPicoSDK]",
                    "type": "process",
                    "command": "${workspaceFolder}/build.sh",
                    "args": [],
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
                    "label": "Compile and Flash Project [CPicoSDK]",
                    "type": "process",
                    "command": "${workspaceFolder}/build.sh",
                    "args": ["--flash"],
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
                "raspberry-pi.raspberry-pi-pico"
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
                    "preLaunchTask": "Compile Project [CPicoSDK]",
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
                    "name": "SwiftPM: \(envVars["SWIFTPM_PRODUCT"]!) - Flash (picotool) [CPicoSDK]",
                    "request": "launch",
                    "type": "lldb",
                    "program": "/usr/bin/true", // Dummy program to satisfy cppdbg requirements
                    "cwd": "${workspaceFolder}",
                    "preLaunchTask": "Compile and Flash Project [CPicoSDK]",
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

    func overwriteOrCreateIfNeeded(path: String, matchingContent: Data?) throws -> Bool {
        let fileManager = FileManager()
        try fileManager.ensureDirectoryExists(at: path, isDirectory: false)
        if fileManager.fileExists(atPath: path),
            let content = fileManager.contents(atPath: path),
            content == matchingContent
        {
            return false
        } else {
            fileManager.createFile(atPath: path, contents: matchingContent)
            return true
        }
    }
}
