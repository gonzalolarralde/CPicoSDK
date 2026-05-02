import Foundation

@main
struct AssetCompilerTool {
    enum Error: Swift.Error, CustomStringConvertible {
        case invalidArgumentCount(Int)
        case invalidUTF8Path(String)

        var description: String {
            switch self {
            case .invalidArgumentCount(let count):
                return "Expected 3 arguments: <input> <swift-output> <content-output>; got \(count)"
            case .invalidUTF8Path(let path):
                return "Path is not valid UTF-8: \(path)"
            }
        }
    }

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else {
            throw Error.invalidArgumentCount(arguments.count)
        }

        let inputURL = URL(fileURLWithPath: arguments[0], isDirectory: false)
        let swiftOutputURL = URL(fileURLWithPath: arguments[1], isDirectory: false)
        let contentOutputURL = URL(fileURLWithPath: arguments[2], isDirectory: false)

        let resourceName = inputURL.lastPathComponent
        let propertyName = swiftIdentifier(from: inputURL.deletingPathExtension().lastPathComponent)
        let startSymbol = objcopyBinarySymbol(for: resourceName, suffix: "start")
        let endSymbol = objcopyBinarySymbol(for: resourceName, suffix: "end")
        let startVariable = swiftIdentifier(from: startSymbol)
        let endVariable = swiftIdentifier(from: endSymbol)
        let assetData = try Data(contentsOf: inputURL)

        try writeSwiftOutput(
            to: swiftOutputURL,
            resourceName: resourceName,
            propertyName: propertyName,
            startSymbol: startSymbol,
            endSymbol: endSymbol,
            startVariable: startVariable,
            endVariable: endVariable
        )

        try writeContentOutput(
            to: contentOutputURL,
            inputURL: inputURL,
            resourceName: resourceName,
            byteCount: assetData.count,
            base64Content: assetData.base64EncodedString()
        )
    }

    private static func writeSwiftOutput(
        to outputURL: URL,
        resourceName: String,
        propertyName: String,
        startSymbol: String,
        endSymbol: String,
        startVariable: String,
        endVariable: String
    ) throws {
        let source = """
        @_spi(AssetCompiler) import CPicoSDK

        @_silgen_name("\(startSymbol)")
        nonisolated(unsafe) private var \(startVariable): UInt8
        @_silgen_name("\(endSymbol)")
        nonisolated(unsafe) private var \(endVariable): UInt8

        extension Asset {
            public static var \(propertyName): Asset {
                let start = withUnsafePointer(to: &\(startVariable)) { UnsafeRawPointer($0) }
                let end = withUnsafePointer(to: &\(endVariable)) { UnsafeRawPointer($0) }
                return Asset(
                    name: \(swiftStringLiteral(resourceName)),
                    data: UnsafeRawBufferPointer(start: start, count: start.distance(to: end))
                )
            }
        }

        """

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try source.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private static func writeContentOutput(
        to outputURL: URL,
        inputURL: URL,
        resourceName: String,
        byteCount: Int,
        base64Content: String
    ) throws {
        var lines = [
            "// CPicoSDK embedded asset content sidecar.",
            "// source: \(inputURL.path)",
            "// resource-name: \(resourceName)",
            "// byte-count: \(byteCount)",
            "// base64:",
        ]

        var chunkStart = base64Content.startIndex
        while chunkStart < base64Content.endIndex {
            let chunkEnd = base64Content.index(chunkStart, offsetBy: 100, limitedBy: base64Content.endIndex) ?? base64Content.endIndex
            lines.append("// \(base64Content[chunkStart..<chunkEnd])")
            chunkStart = chunkEnd
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private static func objcopyBinarySymbol(for resourceName: String, suffix: String) -> String {
        let sanitized = resourceName.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return Character(scalar)
            default:
                return "_"
            }
        }
        return "_binary_\(String(sanitized))_\(suffix)"
    }

    // Raw identifiers (SE-0451, Swift 6.2) allow any characters inside backticks
    // except the backtick itself and backslash, so we can map resource names
    // directly to Swift identifiers without sanitizing, keyword-checking, or
    // digit-prefix handling.
    private static func swiftIdentifier(from value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "`", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return "`\(sanitized.isEmpty ? "_" : sanitized)`"
    }

    private static func swiftStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

}
