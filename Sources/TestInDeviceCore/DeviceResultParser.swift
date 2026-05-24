import Foundation

public enum DeviceProtocol {
    public static let prefix = "__CPICOSDK_DEVICE_TEST__|"
    public static let diagnosticPrefix = "__CPICOSDK_DEVICE_DIAGNOSTIC__|"
}

public struct DeviceProtocolEvent: Equatable {
    public var name: String
    public var fields: [String: String]

    public init(name: String, fields: [String: String]) {
        self.name = name
        self.fields = fields
    }
}

public struct DeviceTranscript: Equatable {
    public var events: [DeviceProtocolEvent]
    public var stdout: String
    public var diagnostics: [String]
    public var sawRunEnd: Bool
    public var runPassed: Bool
    public var durationMilliseconds: Int?
    public var functionDurations: [DeviceFunctionDuration]

    public init(
        events: [DeviceProtocolEvent],
        stdout: String,
        diagnostics: [String] = [],
        sawRunEnd: Bool,
        runPassed: Bool,
        durationMilliseconds: Int?,
        functionDurations: [DeviceFunctionDuration] = []
    ) {
        self.events = events
        self.stdout = stdout
        self.diagnostics = diagnostics
        self.sawRunEnd = sawRunEnd
        self.runPassed = runPassed
        self.durationMilliseconds = durationMilliseconds
        self.functionDurations = functionDurations
    }
}

public enum DeviceResultParser {
    public static func parse(_ rawOutput: String) -> DeviceTranscript {
        let normalized = rawOutput.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var stdout = ""
        var diagnostics: [String] = []
        var events: [DeviceProtocolEvent] = []
        var sawRunEnd = false
        var runPassed = false
        var durationMilliseconds: Int?
        var functionDurations: [DeviceFunctionDuration] = []

        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            guard let marker = nextMarker(in: normalized, from: cursor) else {
                stdout += String(normalized[cursor...])
                break
            }

            stdout += String(normalized[cursor..<marker.range.lowerBound])
            let payloadStart = marker.range.upperBound
            let nextNewline = normalized[payloadStart...].firstIndex(of: "\n")
            let nextMarker = nextMarker(in: normalized, from: payloadStart)?.range.lowerBound
            let payloadEnd = [nextNewline, nextMarker].compactMap { $0 }.min() ?? normalized.endIndex
            let payload = String(normalized[payloadStart..<payloadEnd])

            switch marker.kind {
            case .event:
                let event = parseEvent(payload)
                if event.name == "run-end" {
                    if let status = event.fields["status"],
                       let duration = event.fields["durationMs"].flatMap(Int.init) {
                        sawRunEnd = true
                        runPassed = status == "passed"
                        durationMilliseconds = duration
                    }
                } else if event.name == "test-end",
                          let name = event.fields["name"],
                          let status = event.fields["status"],
                          let duration = event.fields["durationMs"].flatMap(Int.init) {
                    functionDurations.append(DeviceFunctionDuration(
                        name: name,
                        durationMilliseconds: duration,
                        passed: status == "passed"
                    ))
                }
                events.append(event)
            case .diagnostic:
                diagnostics.append(payload)
            }

            if payloadEnd < normalized.endIndex, normalized[payloadEnd] == "\n" {
                cursor = normalized.index(after: payloadEnd)
            } else {
                cursor = payloadEnd
            }
        }

        return DeviceTranscript(
            events: events,
            stdout: stdout,
            diagnostics: diagnostics,
            sawRunEnd: sawRunEnd,
            runPassed: runPassed,
            durationMilliseconds: durationMilliseconds,
            functionDurations: functionDurations
        )
    }

    public static func evaluate(transcript: DeviceTranscript, expectations: DeviceExpectations) -> DeviceTestEvaluation {
        guard transcript.sawRunEnd else {
            return DeviceTestEvaluation(passed: false, reason: "missing run-end marker")
        }
        guard transcript.runPassed else {
            let failed = transcript.events.first { $0.name == "test-end" && $0.fields["status"] == "failed" }
            let error = failed?.fields["error"].map { ": \($0)" } ?? ""
            return DeviceTestEvaluation(passed: false, reason: "device test failed\(error)")
        }

        if let stdout = expectations.stdout {
            if let expected = stdout.equals, transcript.stdout != expected {
                return DeviceTestEvaluation(passed: false, reason: "stdout mismatch; expected \(debug(expected)), got \(debug(transcript.stdout))")
            }
            if let expected = stdout.contains, !transcript.stdout.contains(expected) {
                return DeviceTestEvaluation(passed: false, reason: "stdout did not contain \(debug(expected))")
            }
            if let pattern = stdout.regex {
                do {
                    let regex = try NSRegularExpression(pattern: pattern)
                    let range = NSRange(transcript.stdout.startIndex..<transcript.stdout.endIndex, in: transcript.stdout)
                    if regex.firstMatch(in: transcript.stdout, range: range) == nil {
                        return DeviceTestEvaluation(passed: false, reason: "stdout did not match regex \(debug(pattern))")
                    }
                } catch {
                    return DeviceTestEvaluation(passed: false, reason: "invalid stdout regex \(debug(pattern)): \(error)")
                }
            }
        }

        if let duration = expectations.duration, let actual = transcript.durationMilliseconds {
            if let minimum = duration.minMilliseconds, actual < minimum {
                return DeviceTestEvaluation(passed: false, reason: "duration \(actual)ms was below \(minimum)ms")
            }
            if let maximum = duration.maxMilliseconds, actual > maximum {
                return DeviceTestEvaluation(passed: false, reason: "duration \(actual)ms exceeded \(maximum)ms")
            }
        }

        return DeviceTestEvaluation(passed: true)
    }

    private static func parseEvent(_ payload: String) -> DeviceProtocolEvent {
        var parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let name = parts.isEmpty ? "" : parts.removeFirst()
        var fields: [String: String] = [:]
        for part in parts {
            guard let separator = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<separator])
            let value = String(part[part.index(after: separator)...])
            fields[key] = value
        }
        return DeviceProtocolEvent(name: name, fields: fields)
    }

    private enum MarkerKind {
        case event
        case diagnostic
    }

    private static func nextMarker(in string: String, from cursor: String.Index) -> (kind: MarkerKind, range: Range<String.Index>)? {
        let searchRange = string[cursor...]
        let eventRange = searchRange.range(of: DeviceProtocol.prefix)
        let diagnosticRange = searchRange.range(of: DeviceProtocol.diagnosticPrefix)

        switch (eventRange, diagnosticRange) {
        case (nil, nil):
            return nil
        case (let eventRange?, nil):
            return (.event, eventRange)
        case (nil, let diagnosticRange?):
            return (.diagnostic, diagnosticRange)
        case (let eventRange?, let diagnosticRange?):
            if eventRange.lowerBound <= diagnosticRange.lowerBound {
                return (.event, eventRange)
            }
            return (.diagnostic, diagnosticRange)
        }
    }

    private static func debug(_ string: String) -> String {
        "\"\(string.replacingOccurrences(of: "\n", with: "\\n"))\""
    }
}
