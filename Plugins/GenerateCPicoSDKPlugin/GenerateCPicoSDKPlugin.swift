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
        try await generateCPicoSDK(
            variantName: "pico2",
            pluginWorkingDir: context.pluginWorkDirectoryURL,
            cmakeProject: context.package.directoryURL.appending(path: "Plugins/GenerateCPicoSDKPluginTool/CMakeHarness"),
            packageDir: context.package.directoryURL,
            importedLibs: (ProcessInfo.processInfo.environment["IMPORTED_LIBS"] ?? "").split(separator: ",").map(String.init),
            board: ProcessInfo.processInfo.environment["BOARD"].expected
        )
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

    func findLibraryBasePath(packageDir: URL, libraryName: String) throws -> URL {
        guard let picoSDKSrc = ProcessInfo.processInfo.environment["PICO_SDK_PATH"].flatMap(URL.init(fileURLWithPath:)) else {
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

    func generateCPicoSDK(variantName: String, pluginWorkingDir: URL, cmakeProject: URL, packageDir: URL, importedLibs: [String], board: String) async throws {
        let workingCmakeDir = pluginWorkingDir.appending(path: cmakeProject.lastPathComponent)
        if fileManager.fileExists(atPath: workingCmakeDir.path) {
            try fileManager.removeItem(at: workingCmakeDir)
        }
        try fileManager.copyItem(at: cmakeProject, to: pluginWorkingDir.appending(path: cmakeProject.lastPathComponent))

        let srcDir = pluginWorkingDir.appending(path: "CMakeHarness")
        let buildDir = srcDir.appending(path: "build")
        let outputDir = pluginWorkingDir.appending(path: "output")
        let cmakeBin = try URL(fileURLWithPath: ProcessInfo.processInfo.environment["CMAKE_PATH"].expected).appending(component: "cmake")
        let sourceHURL = srcDir.appending(path: "CPicoSDK_\(variantName).source.h")

        print("Creating output directory at \(outputDir.path)")
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: buildDir.path) {
            try fileManager.removeItem(at: buildDir)
        }
        try fileManager.createDirectory(at: buildDir, withIntermediateDirectories: true)
        print("Writing source h file in \(sourceHURL.path)")

        let lwipInclude = !importedLibs.contains("pico_lwip_http") ? "" : """
        #include <lwip/apps/http_client.h>
        #include <lwip/altcp.h>
        #include <lwip/altcp_tls.h>
        #include <lwip/netif.h>
        #include <lwip/ip4_addr.h>
        """

        let libIncludes = try importedLibs.compactMap { lib -> String in
            var includes = "\n// MARK: - \(lib) headers\n"
            
            if let libBase = try? findLibraryBasePath(packageDir: packageDir, libraryName: lib) {
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

        let sourceHContent = """
        #define __ARM_ARCH_8M_MAIN__ 1

        #include <pico/async_context.h>
        #include <pico/async_context_poll.h>

        \(lwipInclude)
        \(libIncludes)
        """

        try sourceHContent.write(to: sourceHURL, atomically: true, encoding: .utf8)
        print(sourceHContent)

        print("Configuring CMake project in \(buildDir.path)")

        let cmakeConfigProcess = Process()
        cmakeConfigProcess.executableURL = cmakeBin
        cmakeConfigProcess.environment = ProcessInfo.processInfo.environment
        try cmakeConfigProcess.arguments = [
            "-S", srcDir.path,
            "-B", buildDir.path,
            "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=\(ProcessInfo.processInfo.environment["BUILD_TYPE"].expected)",
            "-DPICO_SDK_PATH=\(ProcessInfo.processInfo.environment["PICO_SDK_PATH"].expected)",
            "-DPICOTOOL_PATH=\(ProcessInfo.processInfo.environment["PICOTOOL_PATH"].expected)",
            "-DBOARD_TYPE=\(board)",
            "-DTOOLCHAIN_VERSION=\(ProcessInfo.processInfo.environment["TOOLCHAIN_VERSION"].expected)",
            "-DSDK_VERSION=\(ProcessInfo.processInfo.environment["SDK_VERSION"].expected)",
            "-DIMPORTED_LIBS=\(importedLibs.joined(separator: ","))",
            "-DVARIANT_NAME=\(variantName)",
        ]

        guard try await cmakeConfigProcess.asyncRun() == 0 else { throw Error.cmakeConfigurationFailed }

        print("Building CMake project in \(buildDir.path)")

        let cmakeBuildProcess = Process()
        cmakeBuildProcess.executableURL = cmakeBin
        cmakeBuildProcess.arguments = ["--build", buildDir.path]
        guard try await cmakeBuildProcess.asyncRun() == 0 else { throw Error.cmakeConfigurationFailed }

        print("Writing modulemap to \(pluginWorkingDir.appending(path: "output/module.modulemap").path)")
        let modulemapContent = """
        module _CPicoSDK_\(variantName) [system] {
            umbrella header "include/CPicoSDK_\(variantName).h"
            export *
        }
        """
        let modulemapURL = outputDir.appending(path: "module.modulemap")
        try modulemapContent.write(to: modulemapURL, atomically: true, encoding: .utf8)

        let includeDir = outputDir.appending(path: "include")
        try fileManager.createDirectory(at: includeDir, withIntermediateDirectories: true)
        
        let picoSDKHeaderURL = includeDir.appending(path: "CPicoSDK_\(variantName).h")
        var picoSDKHeaderContent = "#pragma GCC system_header\n"
        let builtHeaderURL = buildDir.appending(path: "CPicoSDK_\(variantName).h")
        picoSDKHeaderContent += try String(contentsOf: builtHeaderURL)
        try picoSDKHeaderContent.write(to: picoSDKHeaderURL, atomically: true, encoding: .utf8)

        let destinationDir = packageDir.appending(path: "Sources/_CPicoSDK_\(variantName)")
        if fileManager.fileExists(atPath: destinationDir.path) {
            try fileManager.removeItem(at: destinationDir)
        }
        try fileManager.copyItem(at: outputDir, to: destinationDir)
    }
}

extension Process {
    // TODO: Move to shared package
    func asyncRun() async throws -> Int32 {
        try await withUnsafeThrowingContinuation { continuation in
            self.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try self.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum OptionalError: Error {
    case valueNotFound
}

extension Optional {
    var expected: Wrapped {
        get throws {
            switch self {
            case .some(let value):
                return value
            case .none:
                throw OptionalError.valueNotFound
            }
        }
    }
}