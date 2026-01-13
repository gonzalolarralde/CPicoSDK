import Foundation
import PackagePlugin

@main
struct GenerateCPicoSDKPlugin: CommandPlugin {
    enum Error: Swift.Error {
        case picoSDKNotFound
        case libraryNotFound(String)
        case cmakeConfigurationFailed
        case cmakeBuildFailed

        var localizedDescription: String {
            switch self {
            case .picoSDKNotFound:
                return "PICO_SDK_PATH environment variable not set."
            case .libraryNotFound(let libName):
                return "Library \(libName) not found in PICO_SDK_PATH."
            case .cmakeConfigurationFailed:
                return "CMake configuration failed."
            case .cmakeBuildFailed:
                return "CMake build failed."
            }
        }
    }

    let fileManager = FileManager.default

    func performCommand(context: PackagePlugin.PluginContext, arguments: [String]) async throws {
        let env = try Env(from: context.package.directoryURL.appending(path: "env.json").relativePath)
        
        for combination in env.combinations.keys.sorted() {
            print("[CPicoSDK] Generating CPicoSDK for combination: \(combination)")
            try await generateCPicoSDK(
                combination: combination,
                pluginWorkingDir: context.pluginWorkDirectoryURL,
                cmakeProject: context.package.directoryURL.appending(path: "Plugins/GenerateCPicoSDKPluginTool/CMakeHarness"),
                packageDir: context.package.directoryURL
            )
        }
    }

    func headerFileEligible(fileName: String) -> Bool {
        guard fileName.hasSuffix(".h") else {
            return false
        }

        let excludedSubstrings = ["freertos"]
        for substring in excludedSubstrings {
            if fileName.lowercased().contains(substring) {
                return false
            }
        }
        return true
    }

    func findLibraryBasePath(packageDir: URL, libraryName: String, combination: String) throws -> URL {
        guard let picoSDKSrc = Env.value("PICO_SDK_PATH", combination: combination).flatMap(URL.init(fileURLWithPath:)) else {
            throw Error.picoSDKNotFound
        }

        let libDirs = try fileManager.subpathsOfDirectory(atPath: picoSDKSrc.path).filter { $0.hasSuffix("/" + libraryName) && !$0.contains("/host/") }
        guard let firstLibDir = libDirs.first else {
            throw Error.libraryNotFound(libraryName)
        }

        guard fileManager.fileExists(atPath: picoSDKSrc.appending(path: firstLibDir).appending(path: "include").path) else {
            throw Error.libraryNotFound(libraryName)
        }
        return picoSDKSrc.appending(path: firstLibDir).appending(path: "include")
    }

    func generateCPicoSDK(combination: String, pluginWorkingDir: URL, cmakeProject: URL, packageDir: URL) async throws {
        let workingCmakeDir = pluginWorkingDir.appending(path: cmakeProject.lastPathComponent)
        try? fileManager.removeItem(at: workingCmakeDir)
        try fileManager.copyItem(at: cmakeProject, to: workingCmakeDir)

        let srcDir = pluginWorkingDir.appending(path: "CMakeHarness")
        let buildDir = srcDir.appending(path: "build")
        let outputDir = pluginWorkingDir.appending(path: "output")
        let cmakeBin = try URL(fileURLWithPath: Env.value("CMAKE_PATH", combination: combination).expected).appending(
            component: "cmake"
        )
        let sourceHURL = srcDir.appending(path: "CPicoSDK_\(combination).source.h")
        
        print("[CPicoSDK] Creating output directory at \(outputDir.path)")
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        print("[CPicoSDK] Cleaning build directory at \(buildDir.path)")
        try? fileManager.removeItem(at: buildDir)
        try fileManager.createDirectory(at: buildDir, withIntermediateDirectories: true)

        print("[CPicoSDK] Writing source h file in \(sourceHURL.path)")

        let importedLibs = try Env.importedLibs(combination: combination)

        let sourceHContent = try generateSourceHeaderContent(
            importedLibs: importedLibs,
            packageDir: packageDir,
            combination: combination
        )

        try sourceHContent.write(to: sourceHURL, atomically: true, encoding: .utf8)
        print(sourceHContent)

        try await runCMakeBuildProcess(
            cmakeBin: cmakeBin,
            srcDir: srcDir,
            buildDir: buildDir,
            importedLibs: importedLibs,
            combination: combination
        )

        let destinationDir = packageDir.appending(path: "Sources/_CPicoSDK_\(combination)")
        try? fileManager.removeItem(at: destinationDir)
        try fileManager.ensureDirectoryExists(at: destinationDir.path, isDirectory: true)

        print("[CPicoSDK] Writing modulemap to \(pluginWorkingDir.appending(path: "output/module.modulemap").path)")
        let modulemapContent = """
        module _CPicoSDK_\(combination) [system] {
            umbrella header "include/CPicoSDK_\(combination).h"
            export *
        }
        """
        let modulemapURL = destinationDir.appending(path: "module.modulemap")
        try modulemapContent.write(to: modulemapURL, atomically: true, encoding: .utf8)

        let includeDir = destinationDir.appending(path: "include")
        try fileManager.createDirectory(at: includeDir, withIntermediateDirectories: true)
        
        let picoSDKHeaderURL = outputDir.appending(path: "include/CPicoSDK_\(combination).h")
        let builtHeaderURL = buildDir.appending(path: "CPicoSDK_\(combination).h")
        let picoSDKHeaderContent = self.fixPicoSDKHeader(content: try String(contentsOf: builtHeaderURL, encoding: .utf8))

        try picoSDKHeaderContent.write(
            to: destinationDir.appending(path: "include/CPicoSDK_\(combination).h"),
            atomically: true,
            encoding: .utf8
        )
    }

    func generateSourceHeaderContent(importedLibs: [String], packageDir: URL, combination: String) throws -> String {
        let lwipInclude = !importedLibs.contains("pico_lwip_http") ? "" : """
        #include <lwip/apps/http_client.h>
        #include <lwip/altcp.h>
        #include <lwip/altcp_tls.h>
        #include <lwip/netif.h>
        #include <lwip/ip4_addr.h>
        """

        let libIncludes = try importedLibs.compactMap { lib -> String in
            var includes = "\n// MARK: - \(lib) headers\n"
            
            if let libBase = try? findLibraryBasePath(packageDir: packageDir, libraryName: lib, combination: combination) {
                let headerFiles = try fileManager.subpathsOfDirectory(atPath: libBase.path).filter { headerFileEligible(fileName: $0) }
                if !headerFiles.isEmpty {
                    for header in headerFiles {
                        includes += "#include <\(header)>\n"
                    }                
                } else {
                    includes += "// No headers found -- $ find \"\(libBase.path)\" -type f -name '*.h')\n"
                }
            } else {
                includes += "// Library not found: \(lib)\n"
            }
            return includes
        }.joined(separator: "\n")

        return """
        #define __ARM_ARCH_8M_MAIN__ 1

        #include <pico/async_context.h>
        #include <pico/async_context_poll.h>

        \(lwipInclude)
        \(libIncludes)
        """
    }

    func runCMakeBuildProcess(cmakeBin: URL, srcDir: URL, buildDir: URL, importedLibs: [String], combination: String) async throws {
        print("[CPicoSDK] Configuring CMake project in \(buildDir.path)")

        let cmakeConfigProcess = Process()
        cmakeConfigProcess.executableURL = cmakeBin
        cmakeConfigProcess.environment = ProcessInfo.processInfo.environment
        try cmakeConfigProcess.arguments = [
            "-S", srcDir.path,
            "-B", buildDir.path,
            "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=\(Env.value("BUILD_TYPE", combination: combination).expected)",
            "-DPICO_SDK_PATH=\(Env.value("PICO_SDK_PATH", combination: combination).expected)",
            "-DPICOTOOL_PATH=\(Env.value("PICOTOOL_PATH", combination: combination).expected)",
            "-DBOARD_TYPE=\(Env.value("BOARD", combination: combination).expected)",
            "-DTOOLCHAIN_VERSION=\(Env.value("TOOLCHAIN_VERSION", combination: combination).expected)",
            "-DSDK_VERSION=\(Env.value("SDK_VERSION", combination: combination).expected)",
            "-DIMPORTED_LIBS=\(importedLibs.joined(separator: ","))",
            "-DCOMBINATION=\(combination)",
        ]

        guard try await cmakeConfigProcess.asyncRun() == 0 else { throw Error.cmakeConfigurationFailed }

        print("[CPicoSDK] Building CMake project in \(buildDir.path)")

        let cmakeBuildProcess = Process()
        cmakeBuildProcess.executableURL = cmakeBin
        cmakeBuildProcess.arguments = ["--build", buildDir.path]
        guard try await cmakeBuildProcess.asyncRun() == 0 else { throw Error.cmakeConfigurationFailed }
    }

    func fixPicoSDKHeader(content: String) -> String {
        let unsignedRegex = /_u\(\s*((?:0x)?[0-9a-fA-F]+)\s*\)/

        var content = content.replacing(unsignedRegex) { match in
            "\(match.output.1)u"
        }

        return "#pragma GCC system_header\n" +
            content
    }
}