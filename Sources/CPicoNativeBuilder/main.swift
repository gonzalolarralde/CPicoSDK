import CPicoExternalBuildSupport
import Foundation

enum BuilderError: Error, CustomStringConvertible {
    case commandFailed([String], Int32)
    case invalidExternalSource(String)
    case missingArgument(String)
    case missingEnvironment(String)
    case missingOutput(String)

    var description: String {
        switch self {
        case .commandFailed(let command, let status):
            "command failed (\(status)): \(command.joined(separator: " "))"
        case .invalidExternalSource(let path):
            "external source is not under CPicoSDK/External: \(path)"
        case .missingArgument(let name):
            "missing argument: \(name)"
        case .missingEnvironment(let name):
            "missing environment: \(name)"
        case .missingOutput(let path):
            "builder did not produce expected output: \(path)"
        }
    }
}

@main
struct CPicoNativeBuilder {
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            throw BuilderError.missingArgument("plugin work directory")
        }
        guard CommandLine.arguments.count > 2 else {
            throw BuilderError.missingArgument("external source directory")
        }

        let processEnvironment = ProcessInfo.processInfo.environment
        let swiftConfiguration = try required(
            "SWIFT_CONFIGURATION",
            in: processEnvironment
        )
        let platform = processEnvironment["SWIFT_PLATFORM"] ?? ""
        let externalSource = URL(
            fileURLWithPath: CommandLine.arguments[2],
            isDirectory: true
        ).standardizedFileURL
        let externalDirectory = externalSource.deletingLastPathComponent()
        guard externalDirectory.lastPathComponent == "External" else {
            throw BuilderError.invalidExternalSource(externalSource.path)
        }
        let derivedCPicoSDKDirectory = externalDirectory.deletingLastPathComponent()
        let cpicoSDKDirectory = processEnvironment["CPICOSDK_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        } ?? derivedCPicoSDKDirectory
        let buildConfiguration = processEnvironment["CPICOSDK_BUILD_CONFIGURATION"]
            .flatMap { path -> URL? in
                guard !path.isEmpty else {
                    return nil
                }
                return URL(fileURLWithPath: path, isDirectory: false)
                    .standardizedFileURL
            }
        let resolution = try ExternalBuildEnvironmentResolver(
            processEnvironment: processEnvironment,
            configurationURL: buildConfiguration,
            cpicoSDKDirectory: cpicoSDKDirectory
        ).resolve()
        let environment = resolution.environment

        let outputDirectory = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        ).appendingPathComponent(swiftConfiguration + platform, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let cmakeDirectory = try required("CMAKE_PATH", in: environment)
        let cmake = URL(fileURLWithPath: cmakeDirectory, isDirectory: true)
            .appendingPathComponent("cmake").path
        let ninjaDirectory = try required("NINJA_PATH", in: environment)
        let ninja = URL(fileURLWithPath: ninjaDirectory, isDirectory: true)
            .appendingPathComponent("ninja").path
        let expectedArchive = outputDirectory.appendingPathComponent("libCPicoNativeSupport.a")
        let picoSDKPath = try required("PICO_SDK_PATH", in: environment)
        let sdkVersion = try required("SDK_VERSION", in: environment)
        #if os(macOS)
        let hostSDKRoot = macOSSDKRoot() ?? ""
        #else
        let hostSDKRoot = ""
        #endif
        let hostToolCacheIdentity = [
            picoSDKPath,
            ProcessInfo.processInfo.operatingSystemVersionString,
            hostArchitecture,
            cmake,
            ninja,
            hostSDKRoot,
            environment["CC"] ?? "",
            environment["CXX"] ?? "",
        ].joined(separator: "\0")

        // Build Pico's generator as an explicit host tool. Letting the
        // bare-metal CMake graph create this nested project loses host SDK
        // selection under SwiftBuild's destination custom task.
        let hostToolsDirectory = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
            .appendingPathComponent("host-tools", isDirectory: true)
            .appendingPathComponent(
                "pioasm-\(sdkVersion)-\(cacheKey(for: hostToolCacheIdentity))",
                isDirectory: true
            )
        let pioasmBuildDirectory = hostToolsDirectory
            .appendingPathComponent("pioasm-build", isDirectory: true)
        let pioasmInstallDirectory = hostToolsDirectory
            .appendingPathComponent("pioasm-install", isDirectory: true)
        var pioasmConfiguration = [
            cmake,
            "-S", URL(fileURLWithPath: picoSDKPath, isDirectory: true)
                .appendingPathComponent("tools/pioasm", isDirectory: true).path,
            "-B", pioasmBuildDirectory.path,
            "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_MAKE_PROGRAM=\(ninja)",
            "-DCMAKE_INSTALL_PREFIX=\(pioasmInstallDirectory.path)",
            "-DPIOASM_FLAT_INSTALL=1",
            "-DPIOASM_VERSION_STRING=\(sdkVersion)",
        ]
        #if os(macOS)
        if !hostSDKRoot.isEmpty {
            pioasmConfiguration.append("-DCMAKE_OSX_SYSROOT=\(hostSDKRoot)")
        }
        #endif
        try run(pioasmConfiguration, environment: environment)
        try run(
            [cmake, "--build", pioasmBuildDirectory.path],
            environment: environment
        )
        try run(
            [cmake, "--install", pioasmBuildDirectory.path],
            environment: environment
        )
        let pioasmPackageDirectory = pioasmInstallDirectory
            .appendingPathComponent("pioasm", isDirectory: true)

        try run(
            [
                cmake,
                "-S", externalSource.path,
                "-B", outputDirectory.path,
                "-G", "Ninja",
                "-DCMAKE_BUILD_TYPE=\(environment["BUILD_TYPE"] ?? "RelWithDebInfo")",
                "-DCMAKE_MAKE_PROGRAM=\(ninja)",
                "-DCPICOSDK_ROOT=\(cpicoSDKDirectory.path)",
                "-DPICO_SDK_PATH=\(picoSDKPath)",
                "-DPICO_TOOLCHAIN_PATH=\(try required("PICO_TOOLCHAIN_PATH", in: environment))",
                "-DPICOTOOL_PATH=\(try required("PICOTOOL_PATH", in: environment))",
                "-Dpioasm_DIR=\(pioasmPackageDirectory.path)",
                "-DBOARD_TYPE=\(try required("BOARD", in: environment))",
                "-DIMPORTED_LIBS=\(try required("IMPORTED_LIBS", in: environment))",
                "-DIMPORTED_LIBS_MORE=\(environment["IMPORTED_LIBS_MORE"] ?? "")",
                "-DSTDIO_UART=\(environment["CPICO_EXTERNAL_STDIO_UART"] ?? "0")",
                "-DSTDIO_USB=\(environment["CPICO_EXTERNAL_STDIO_USB"] ?? "1")",
                "-DSTDIO_RTT=\(environment["CPICO_EXTERNAL_STDIO_RTT"] ?? "0")",
                "-DCPICOSDK_CORE1_STACK_SIZE_BYTES=\(environment["CPICOSDK_CORE1_STACK_SIZE_BYTES"] ?? "8192")",
            ],
            environment: environment
        )
        try run(
            [cmake, "--build", outputDirectory.path, "--target", "CPicoNativeSupport"],
            environment: environment
        )

        guard FileManager.default.fileExists(atPath: expectedArchive.path) else {
            throw BuilderError.missingOutput(expectedArchive.path)
        }
        let pioasmPackagePathFile = outputDirectory
            .appendingPathComponent("pioasm-package-path.txt")
        let pioasmPackagePath = pioasmPackageDirectory.path
        if (try? String(contentsOf: pioasmPackagePathFile, encoding: .utf8))
            != pioasmPackagePath
        {
            try pioasmPackagePath.write(
                to: pioasmPackagePathFile,
                atomically: true,
                encoding: .utf8
            )
        }
        print("[CPicoSDK] External native archive: \(expectedArchive.path)")
        print("[CPicoSDK] Host pioasm package: \(pioasmPackageDirectory.path)")
    }

    private static func required(
        _ key: String,
        in environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw BuilderError.missingEnvironment(key)
        }
        return value
    }

    private static func cacheKey(for value: String) -> String {
        // CMake caches source, compiler, generator, and host SDK paths. Key the
        // host-tool directory by that complete identity so a restored scratch
        // directory cannot cross host/tool installations.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #elseif arch(arm)
        "arm"
        #else
        "unknown"
        #endif
    }

    private static func run(
        _ command: [String],
        environment baseEnvironment: [String: String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        var environment = baseEnvironment
        // SwiftBuild's custom task inherits a toolchain-style DEVELOPER_DIR,
        // which prevents Pico SDK host tools from finding the macOS SDK.
        environment.removeValue(forKey: "DEVELOPER_DIR")
        #if os(macOS)
        // A destination build can also contribute (for example)
        // XROS_DEPLOYMENT_TARGET. Apple Clang uses those environment variables
        // to choose its target even when CMake passes a macOS -isysroot, which
        // makes a host-tool build accidentally compile as visionOS. The ARM
        // compiler ignores these host settings, so sanitize every child task.
        for key in environment.keys where key.hasSuffix("_DEPLOYMENT_TARGET") {
            environment.removeValue(forKey: key)
        }
        // CMake resolves /usr/bin/c++ to Xcode's underlying compiler. Unlike
        // the xcrun shim, that path does not infer an SDK for Pico's host-side
        // pioasm sub-build, so make the SDK explicit.
        if let sdkRoot = macOSSDKRoot() {
            environment["SDKROOT"] = sdkRoot
        }
        #endif
        process.environment = environment
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BuilderError.commandFailed(command, process.terminationStatus)
        }
    }

    #if os(macOS)
    private static func macOSSDKRoot() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DEVELOPER_DIR")
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}
