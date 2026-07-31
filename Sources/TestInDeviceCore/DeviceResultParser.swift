import Foundation

public enum DeviceProtocol {
    public static let prefix = "__CPICOSDK_DEVICE_TEST__|"
    public static let diagnosticPrefix = "__CPICOSDK_DEVICE_DIAGNOSTIC__|"
    public static let scorePrefix = "__S__|"
    public static let captureEndEvent = "capture-end"
    public static let captureEndMarker = prefix + captureEndEvent
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
    public var scores: [DeviceScore]
    public var sawRunEnd: Bool
    public var runPassed: Bool
    public var durationMilliseconds: Int?
    public var functionDurations: [DeviceFunctionDuration]

    public init(
        events: [DeviceProtocolEvent],
        stdout: String,
        diagnostics: [String] = [],
        scores: [DeviceScore] = [],
        sawRunEnd: Bool,
        runPassed: Bool,
        durationMilliseconds: Int?,
        functionDurations: [DeviceFunctionDuration] = []
    ) {
        self.events = events
        self.stdout = stdout
        self.diagnostics = diagnostics
        self.scores = scores
        self.sawRunEnd = sawRunEnd
        self.runPassed = runPassed
        self.durationMilliseconds = durationMilliseconds
        self.functionDurations = functionDurations
    }
}

public struct DeviceScore: Equatable, Hashable {
    public var metric: String
    public var rawLine: String
    public var score: String
    public var value: Double
    public var context: String

    public init(metric: String, rawLine: String, score: String, value: Double, context: String) {
        self.metric = metric
        self.rawLine = rawLine
        self.score = score
        self.value = value
        self.context = context
    }
}

public enum DeviceResultParser {
    public static func parse(_ rawOutput: String) -> DeviceTranscript {
        let normalized = rawOutput.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var stdout = ""
        var diagnostics: [String] = []
        var scores: [DeviceScore] = []
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
            case .score:
                if let score = parseScore(payload) {
                    scores.append(score)
                }
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
            scores: scores,
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
        case score
    }

    private static func nextMarker(in string: String, from cursor: String.Index) -> (kind: MarkerKind, range: Range<String.Index>)? {
        let searchRange = string[cursor...]
        let eventRange = searchRange.range(of: DeviceProtocol.prefix)
        let diagnosticRange = searchRange.range(of: DeviceProtocol.diagnosticPrefix)
        let scoreRange = searchRange.range(of: DeviceProtocol.scorePrefix)
        let candidates = [
            eventRange.map { (kind: MarkerKind.event, range: $0) },
            diagnosticRange.map { (kind: MarkerKind.diagnostic, range: $0) },
            scoreRange.map { (kind: MarkerKind.score, range: $0) },
        ].compactMap { $0 }

        guard let first = candidates.min(by: { $0.range.lowerBound < $1.range.lowerBound }) else {
            return nil
        }
        return first
    }

    private static func parseScore(_ payload: String) -> DeviceScore? {
        let directParts = payload.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        if directParts.count == 5,
           isScoreIdentifier(directParts[0]),
           isScoreIdentifier(directParts[1]),
           !directParts[4].isEmpty,
           let value = Double(directParts[2]) {
            return DeviceScore(
                metric: directParts[0],
                rawLine: directParts[4],
                score: directParts[1],
                value: value,
                context: directParts[3]
            )
        }

        let event = parseEvent(payload)
        guard let metric = event.fields["metric"],
              let rawLine = event.fields["raw"],
              let score = event.fields["score"],
              let valueString = event.fields["value"],
              let value = Double(valueString) else {
            return nil
        }
        return DeviceScore(
            metric: metric,
            rawLine: rawLine,
            score: score,
            value: value,
            context: event.fields["context"] ?? ""
        )
    }

    private static func isScoreIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func debug(_ string: String) -> String {
        "\"\(string.replacingOccurrences(of: "\n", with: "\\n"))\""
    }
}
