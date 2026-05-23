import Foundation

public enum DeviceTestParser {
    public static func load(fileURL: URL) throws -> DeviceTestSource {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        return try load(source: source, fileURL: fileURL)
    }

    public static func load(source: String, fileURL: URL) throws -> DeviceTestSource {
        if source.contains("import Testing") || source.contains("@Test") || source.contains("#expect") {
            throw DeviceTestHarnessError.unsupportedSwiftTestingSyntax(fileURL.path)
        }

        var metadata = try parseMetadata(from: source, fallbackName: fallbackName(for: fileURL), path: fileURL.path)
        let functions = discoverFunctions(in: source)
        guard !functions.isEmpty else {
            throw DeviceTestHarnessError.noCallableTests(fileURL.path)
        }
        if functions.contains(where: \.isAsync) {
            metadata.concurrency = true
        }
        return DeviceTestSource(fileURL: fileURL, source: source, metadata: metadata, functions: functions)
    }

    public static func discoverFiles(packageDirectory: URL) -> [URL] {
        let testsDirectory = packageDirectory.appendingPathComponent("Tests/Device", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: testsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    public static func parseMetadata(from source: String, fallbackName: String, path: String = "<memory>") throws -> DeviceTestMetadata {
        let metadataLines = try metadataLines(from: source, path: path)
        var metadata = DeviceTestMetadata(name: fallbackName)
        var stdout = StdoutExpectation()
        var hasStdout = false
        var duration = DurationExpectation()
        var hasDuration = false
        var section: String?
        var subsection: String?

        for rawLine in metadataLines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" || line == "-- test yaml" {
                continue
            }

            if !rawLine.hasPrefix(" ") && line.hasSuffix(":") {
                section = String(line.dropLast())
                subsection = nil
                continue
            }

            if rawLine.hasPrefix("  ") && !rawLine.hasPrefix("    ") && line.hasSuffix(":") {
                subsection = String(line.dropLast())
                continue
            }

            if section == nil {
                if let value = scalarValue(line, key: "name") {
                    metadata.name = parseString(value)
                } else if let value = scalarValue(line, key: "timeout") {
                    metadata.timeoutMilliseconds = try parseDurationMilliseconds(value)
                } else if let value = scalarValue(line, key: "concurrency") {
                    metadata.concurrency = try parseBool(value)
                }
                continue
            }

            switch section {
            case "traits":
                if let value = scalarValue(line, key: "add") {
                    metadata.traits.add = parseStringArray(value)
                } else if let value = scalarValue(line, key: "remove") {
                    metadata.traits.remove = parseStringArray(value)
                }
            case "expect":
                if subsection == "stdout" {
                    hasStdout = true
                    if let value = scalarValue(line, key: "equals") {
                        stdout.equals = parseString(value)
                    } else if let value = scalarValue(line, key: "contains") {
                        stdout.contains = parseString(value)
                    } else if let value = scalarValue(line, key: "regex") {
                        stdout.regex = parseString(value)
                    }
                } else if subsection == "durationMs" {
                    hasDuration = true
                    if let value = scalarValue(line, key: "min") {
                        duration.minMilliseconds = Int(parseString(value))
                    } else if let value = scalarValue(line, key: "max") {
                        duration.maxMilliseconds = Int(parseString(value))
                    }
                }
            default:
                break
            }
        }

        if hasStdout {
            metadata.expectations.stdout = stdout
        }
        if hasDuration {
            metadata.expectations.duration = duration
        }
        return metadata
    }

    public static func discoverFunctions(in source: String) -> [DeviceTestFunction] {
        source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).compactMap { lineSubsequence in
            let line = String(lineSubsequence)
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
            guard line.hasPrefix("func ") || line.hasPrefix("public func ") else { return nil }
            guard let funcRange = line.range(of: "func ") else { return nil }
            let suffix = line[funcRange.upperBound...]
            guard let paren = suffix.firstIndex(of: "(") else { return nil }
            let name = String(suffix[..<paren]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix("__") else { return nil }
            guard let closeParen = suffix[paren...].firstIndex(of: ")") else { return nil }
            let params = suffix[suffix.index(after: paren)..<closeParen].trimmingCharacters(in: .whitespaces)
            guard params.isEmpty else { return nil }
            let remainder = suffix[closeParen...]
            let isAsync = remainder.contains("async")
            let isThrowing = remainder.contains("throws")
            return DeviceTestFunction(name: name, isAsync: isAsync, isThrowing: isThrowing)
        }
    }

    private static func metadataLines(from source: String, path: String) throws -> [String] {
        var lines: [String] = []
        var inBlock = false

        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.hasPrefix("//%") else {
                if inBlock {
                    break
                }
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    continue
                }
                break
            }

            let payloadStart = line.index(line.startIndex, offsetBy: 3)
            var payload = String(line[payloadStart...])
            if payload.hasPrefix(" ") {
                payload.removeFirst()
            }
            if payload.hasPrefix("-----------") {
                return lines
            }
            if payload.hasPrefix("--") {
                inBlock = true
                continue
            }
            if inBlock {
                lines.append(payload)
            }
        }

        throw DeviceTestHarnessError.missingMetadataBlock(path)
    }

    private static func fallbackName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func scalarValue(_ line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func parseBool(_ value: String) throws -> Bool {
        switch parseString(value).lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: throw DeviceTestHarnessError.invalidMetadata("expected boolean, got \(value)")
        }
    }

    private static func parseDurationMilliseconds(_ value: String) throws -> Int {
        let string = parseString(value)
        if string.hasSuffix("ms"), let value = Int(string.dropLast(2)) {
            return value
        }
        if string.hasSuffix("s"), let value = Double(string.dropLast()) {
            return Int(value * 1_000)
        }
        if let value = Int(string) {
            return value
        }
        throw DeviceTestHarnessError.invalidMetadata("expected duration like 500ms or 5s, got \(string)")
    }

    private static func parseStringArray(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return trimmed.isEmpty ? [] : [parseString(trimmed)]
        }
        let inner = trimmed.dropFirst().dropLast()
        return inner.split(separator: ",").map { parseString(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    private static func parseString(_ value: String) -> String {
        var string = value.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("\""), string.hasSuffix("\""), string.count >= 2 {
            string = String(string.dropFirst().dropLast())
            string = string
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return string
    }
}
