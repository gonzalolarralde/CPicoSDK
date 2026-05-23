import Foundation

public enum DevicePackageGenerator {
    public static let productName = "DeviceTestApp"

    public static func generate(
        source: DeviceTestSource,
        cpicoSDKPath: URL,
        outputRoot: URL,
        target: DeviceTestTarget = .rp2350
    ) throws -> GeneratedPackage {
        let safeName = sanitize(source.metadata.name)
        let packageDirectory = outputRoot
            .appendingPathComponent(target.rawValue, isDirectory: true)
            .appendingPathComponent(safeName, isDirectory: true)
        let sourcesDirectory = packageDirectory.appendingPathComponent("Sources/\(productName)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)

        let manifestChanged = try FileManager.default.writeIfChanged(
            packageManifest(for: source, cpicoSDKPath: cpicoSDKPath, target: target),
            to: packageDirectory.appendingPathComponent("Package.swift")
        )
        let sourceChanged = try FileManager.default.writeIfChanged(
            source.source,
            to: sourcesDirectory.appendingPathComponent("DeviceTest.swift")
        )
        let runnerChanged = try FileManager.default.writeIfChanged(
            runnerSource(for: source),
            to: sourcesDirectory.appendingPathComponent("Runner.swift")
        )

        let elfURL = packageDirectory.appendingPathComponent(".build/\(target.swiftPMTriple)/release/\(productName).elf")
        return GeneratedPackage(
            packageDirectory: packageDirectory,
            elfURL: elfURL,
            productName: productName,
            inputsChanged: manifestChanged || sourceChanged || runnerChanged
        )
    }

    public static func packageManifest(
        for source: DeviceTestSource,
        cpicoSDKPath: URL,
        target: DeviceTestTarget = .rp2350
    ) -> String {
        let traitLines = source.metadata.traits.resolvedTraits(defaultTraits: target.defaultTraits)
            .map { "                .init(name: \"\(escapeSwiftString($0))\")," }
            .joined(separator: "\n")

        var dependencyLines = [
            "                .product(name: \"CPicoSDK\", package: \"CPicoSDK\"),"
        ]
        if source.metadata.concurrency {
            dependencyLines.append("                .product(name: \"CPicoConcurrency\", package: \"CPicoSDK\"),")
        }

        return """
        // swift-tools-version: 6.2

        import PackageDescription

        let package = Package(
            name: "\(productName)",
            products: [
                .library(name: "\(productName)", type: .static, targets: ["\(productName)"]),
            ],
            dependencies: [
                .package(
                    path: "\(escapeSwiftString(cpicoSDKPath.path))",
                    traits: [
        \(traitLines)
                    ]
                ),
            ],
            targets: [
                .target(
                    name: "\(productName)",
                    dependencies: [
        \(dependencyLines.joined(separator: "\n"))
                    ]
                ),
            ]
        )
        """
    }

    public static func runnerSource(for source: DeviceTestSource) -> String {
        let calls = source.functions.map { function in
            let invocation = testInvocation(for: function)
            if source.metadata.concurrency {
                return "        passed = await __runDeviceTest(\"\(escapeSwiftString(function.name))\") { \(invocation) } && passed"
            } else {
                return "        passed = __runDeviceTest(\"\(escapeSwiftString(function.name))\") { \(invocation) } && passed"
            }
        }.joined(separator: "\n")

        if source.metadata.concurrency {
            return """
            import CPicoSDK
            import CPicoConcurrency

            public struct DeviceTestFailure: Error, CustomStringConvertible {
                public let description: String
                public init(_ description: String) {
                    self.description = description
                }
            }

            public func deviceExpect(_ condition: @autoclosure () -> Bool, _ message: String = "device expectation failed") throws {
                if !condition() {
                    throw DeviceTestFailure(message)
                }
            }

            @discardableResult
            func __runDeviceTest(_ name: String, _ body: () async throws -> Void) async -> Bool {
                print("__CPICOSDK_DEVICE_TEST__|test-start|name=\\(name)")
                let started = to_ms_since_boot(get_absolute_time())
                do {
                    try await body()
                    let duration = to_ms_since_boot(get_absolute_time()) - started
                    print("__CPICOSDK_DEVICE_TEST__|test-end|name=\\(name)|status=passed|durationMs=\\(duration)")
                    return true
                } catch {
                    let duration = to_ms_since_boot(get_absolute_time()) - started
                    print("__CPICOSDK_DEVICE_TEST__|test-end|name=\\(name)|status=failed|durationMs=\\(duration)|error=thrown")
                    return false
                }
            }

            @main
            struct DeviceTestMain: EmbeddedAsyncApp {
                static func setup() async {
                    stdio_init_all()
                    sleep_ms(1000)
                    let started = to_ms_since_boot(get_absolute_time())
                    print("__CPICOSDK_DEVICE_TEST__|run-start|name=\(escapeSwiftString(source.metadata.name))")
                    var passed = true
            \(calls)
                    let duration = to_ms_since_boot(get_absolute_time()) - started
                    print("__CPICOSDK_DEVICE_TEST__|run-end|status=\\(passed ? "passed" : "failed")|durationMs=\\(duration)")
                }

                static func loop() async {
                    try? await Task.sleep(ms: 1000)
                }
            }
            """
        } else {
            return """
            import CPicoSDK

            public struct DeviceTestFailure: Error, CustomStringConvertible {
                public let description: String
                public init(_ description: String) {
                    self.description = description
                }
            }

            public func deviceExpect(_ condition: @autoclosure () -> Bool, _ message: String = "device expectation failed") throws {
                if !condition() {
                    throw DeviceTestFailure(message)
                }
            }

            @discardableResult
            func __runDeviceTest(_ name: String, _ body: () throws -> Void) -> Bool {
                print("__CPICOSDK_DEVICE_TEST__|test-start|name=\\(name)")
                let started = to_ms_since_boot(get_absolute_time())
                do {
                    try body()
                    let duration = to_ms_since_boot(get_absolute_time()) - started
                    print("__CPICOSDK_DEVICE_TEST__|test-end|name=\\(name)|status=passed|durationMs=\\(duration)")
                    return true
                } catch {
                    let duration = to_ms_since_boot(get_absolute_time()) - started
                    print("__CPICOSDK_DEVICE_TEST__|test-end|name=\\(name)|status=failed|durationMs=\\(duration)|error=thrown")
                    return false
                }
            }

            @main
            struct DeviceTestMain: EmbeddedApp {
                static func setup() {
                    stdio_init_all()
                    sleep_ms(1000)
                    let started = to_ms_since_boot(get_absolute_time())
                    print("__CPICOSDK_DEVICE_TEST__|run-start|name=\(escapeSwiftString(source.metadata.name))")
                    var passed = true
            \(calls)
                    let duration = to_ms_since_boot(get_absolute_time()) - started
                    print("__CPICOSDK_DEVICE_TEST__|run-end|status=\\(passed ? "passed" : "failed")|durationMs=\\(duration)")
                }

                static func loop() {
                    sleep_ms(1000)
                }
            }
            """
        }
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return result.isEmpty ? "DeviceTest" : result
    }

    private static func testInvocation(for function: DeviceTestFunction) -> String {
        switch (function.isAsync, function.isThrowing) {
        case (true, true):
            return "try await \(function.name)()"
        case (true, false):
            return "await \(function.name)()"
        case (false, true):
            return "try \(function.name)()"
        case (false, false):
            return "\(function.name)()"
        }
    }

    private static func escapeSwiftString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

extension FileManager {
    func writeIfChanged(_ contents: String, to url: URL) throws -> Bool {
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing == contents {
            return false
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
