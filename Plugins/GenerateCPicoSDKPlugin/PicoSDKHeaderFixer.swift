import Foundation

enum PicoSDKHeaderFixer {
    typealias HardwareEntrypoint = (
        accessor: String,
        type: String,
        addressExpression: String
    )

    private struct FilteredDeclaration {
        var symbol: String
        var pattern: String
    }

    private static let filteredDeclarations = [
        FilteredDeclaration(
            symbol: "max_align_t",
            pattern: #"(?m)^#define\s+_GCC_MAX_ALIGN_T\s*\n(?:typedef\s+)?struct\s*\{\s*\n\s*long\s+long\s+__max_align_ll\b[^\n]*\n\s*long\s+double\s+__max_align_ld\b[^\n]*\n\}\s*max_align_t\s*;\s*\n?"#
        ),
    ]

    static func fixHeader(content: String) -> String {
        let unsignedRegex = try! NSRegularExpression(
            pattern: #"_u\(\s*((?:0x)?[0-9a-fA-F]+)\s*\)"#
        )

        let normalizedUnsignedContent = unsignedRegex.stringByReplacingMatches(
            in: content,
            range: NSRange(content.startIndex..., in: content),
            withTemplate: "$1u"
        )

        let hardwareEntrypointAccessors = Set(
            extractHardwareEntrypoints(content: normalizedUnsignedContent)
                .map(\.accessor)
        )
        let availableHardwareAliasTargets = hardwareEntrypointAccessors.union(
            extractIndexedHardwareAliasAccessors(content: normalizedUnsignedContent)
        )

        let rewrittenHardwareEntrypointsContent = rewriteHardwareEntrypoints(
            content: normalizedUnsignedContent
        )
        let rewrittenHardwareAliasesContent = rewriteHardwareAliases(
            content: rewrittenHardwareEntrypointsContent,
            availableHardwareAliasTargets: availableHardwareAliasTargets
        )
        let filteredContent = filterDeclarations(content: rewrittenHardwareAliasesContent)

        return "#pragma GCC system_header\n" +
            filteredContent
    }

    static func filterDeclarations(content: String) -> String {
        filteredDeclarations.reduce(content) { currentContent, declaration in
            let regex = try! NSRegularExpression(
                pattern: declaration.pattern,
                options: []
            )
            return regex.stringByReplacingMatches(
                in: currentContent,
                range: NSRange(currentContent.startIndex..., in: currentContent),
                withTemplate: ""
            )
        }
    }

    static func extractHardwareEntrypoints(content: String) -> [HardwareEntrypoint] {
        let defineRegex = try! NSRegularExpression(
            pattern: #"^\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)\s+\(\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\*\s*\)\s*(.+?)\)\s*$"#,
            options: [.anchorsMatchLines]
        )

        let fullRange = NSRange(content.startIndex..., in: content)

        return defineRegex.matches(in: content, range: fullRange).compactMap { match in
            guard
                let accessorRange = Range(match.range(at: 1), in: content),
                let typeRange = Range(match.range(at: 2), in: content),
                let expressionRange = Range(match.range(at: 3), in: content)
            else {
                return nil
            }

            let accessor = String(content[accessorRange])
            let type = String(content[typeRange])
            let addressExpression = String(content[expressionRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Keep pointer-style hardware/peripheral entrypoints and drop obvious noise like NULL.
            guard type != "void", addressExpression != "0" else {
                return nil
            }

            return (
                accessor: accessor,
                type: type,
                addressExpression: addressExpression
            )
        }
    }

    static func rewriteHardwareEntrypoints(content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                rewriteHardwareEntrypointLine(String(line))
            }
            .joined(separator: "\n")
    }

    static func extractIndexedHardwareAliasAccessors(content: String) -> Set<String> {
        let defineRegex = try! NSRegularExpression(
            pattern: #"^\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)\s+\(?\s*&\s*[A-Za-z_][A-Za-z0-9_]*\s*\[\s*[0-9]+\s*\]\s*\)?\s*$"#,
            options: [.anchorsMatchLines]
        )

        let fullRange = NSRange(content.startIndex..., in: content)

        return Set(defineRegex.matches(in: content, range: fullRange).compactMap { match in
            guard let accessorRange = Range(match.range(at: 1), in: content) else {
                return nil
            }

            return String(content[accessorRange])
        })
    }

    static func rewriteHardwareAliases(content: String, availableHardwareAliasTargets: Set<String>) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                rewriteHardwareAliasLine(String(line), availableHardwareAliasTargets: availableHardwareAliasTargets)
            }
            .joined(separator: "\n")
    }

    private static func rewriteHardwareEntrypointLine(_ line: String) -> String {
        let defineRegex = try! NSRegularExpression(
            pattern: #"^(\s*)#define\s+([A-Za-z_][A-Za-z0-9_]*)\s+\(\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\*\s*\)\s*(.+?)\)\s*$"#
        )

        let lineRange = NSRange(line.startIndex..., in: line)
        guard let match = defineRegex.firstMatch(in: line, range: lineRange),
              let indentationRange = Range(match.range(at: 1), in: line),
              let accessorRange = Range(match.range(at: 2), in: line),
              let typeRange = Range(match.range(at: 3), in: line),
              let expressionRange = Range(match.range(at: 4), in: line)
        else {
            return line
        }

        let indentation = String(line[indentationRange])
        let accessor = String(line[accessorRange])
        let type = String(line[typeRange])
        let addressExpression = String(line[expressionRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard type != "void", addressExpression != "0" else {
            return line
        }

        return "\(indentation)static \(type) * const \(accessor) = (\(type) *)\(addressExpression); // ORIGINAL: \(line.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private static func rewriteHardwareAliasLine(_ line: String, availableHardwareAliasTargets: Set<String>) -> String {
        let defineRegex = try! NSRegularExpression(
            pattern: #"^(\s*)#define\s+([A-Za-z_][A-Za-z0-9_]*)\s+(.+?)\s*$"#
        )

        let lineRange = NSRange(line.startIndex..., in: line)
        guard let match = defineRegex.firstMatch(in: line, range: lineRange),
              let indentationRange = Range(match.range(at: 1), in: line),
              let accessorRange = Range(match.range(at: 2), in: line),
              let expressionRange = Range(match.range(at: 3), in: line)
        else {
            return line
        }

        let indentation = String(line[indentationRange])
        let accessor = String(line[accessorRange])
        let expression = String(line[expressionRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        if shouldWarnAboutUnresolvedHardwareAlias(
            accessor: accessor,
            expression: expression,
            availableHardwareAliasTargets: availableHardwareAliasTargets
        ) {
            print("[CPicoSDK] ⚠️ \u{001B}[33mWARNING: Not rewriting hardware alias '\(accessor)' because it references '\(expression)', which was not found as a hardware entrypoint in the generated header.\u{001B}[0m")
        }

        guard shouldRewriteHardwareAlias(accessor: accessor, expression: expression, availableHardwareAliasTargets: availableHardwareAliasTargets) else {
            return line
        }

        return "\(indentation)static __typeof__(\(expression)) const \(accessor) = \(expression); // ORIGINAL: \(line.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private static func shouldRewriteHardwareAlias(accessor: String, expression: String, availableHardwareAliasTargets: Set<String>) -> Bool {
        let identifierRegex = try! NSRegularExpression(
            pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#
        )
        let indexedAliasRegex = try! NSRegularExpression(
            pattern: #"^\(?\s*&\s*[A-Za-z_][A-Za-z0-9_]*\s*\[\s*[0-9]+\s*\]\s*\)?$"#
        )

        let expressionRange = NSRange(expression.startIndex..., in: expression)
        if identifierRegex.firstMatch(in: expression, range: expressionRange) != nil {
            return (accessor.hasSuffix("_hw") || expression.hasSuffix("_hw"))
                && availableHardwareAliasTargets.contains(expression)
        }
        if indexedAliasRegex.firstMatch(in: expression, range: expressionRange) != nil {
            return accessor.hasSuffix("_hw") || expression.contains("_hw_array")
        }

        return false
    }

    private static func shouldWarnAboutUnresolvedHardwareAlias(accessor: String, expression: String, availableHardwareAliasTargets: Set<String>) -> Bool {
        let identifierRegex = try! NSRegularExpression(
            pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#
        )

        let expressionRange = NSRange(expression.startIndex..., in: expression)
        guard identifierRegex.firstMatch(in: expression, range: expressionRange) != nil else {
            return false
        }

        guard accessor.hasSuffix("_hw") || expression.hasSuffix("_hw") else {
            return false
        }

        return !availableHardwareAliasTargets.contains(expression)
    }
}
