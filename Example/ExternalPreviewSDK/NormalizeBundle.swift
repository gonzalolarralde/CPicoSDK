import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum NormalizationError: Error, CustomStringConvertible {
    case brokenLink(String, String)
    case escapedBundle(String, String)
    case invalidArguments

    var description: String {
        switch self {
        case .brokenLink(let link, let target):
            "symbolic link is broken: \(link) -> \(target)"
        case .escapedBundle(let link, let target):
            "symbolic link escapes the artifact bundle: \(link) -> \(target)"
        case .invalidArguments:
            "usage: swift NormalizeBundle.swift <artifact-bundle>"
        }
    }
}

func isContained(_ path: String, by root: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
}

func relativePath(from directory: URL, to destination: URL) -> String {
    let sourceComponents = directory.standardizedFileURL.pathComponents
    let destinationComponents = destination.standardizedFileURL.pathComponents
    var commonCount = 0
    while commonCount < sourceComponents.count,
          commonCount < destinationComponents.count,
          sourceComponents[commonCount] == destinationComponents[commonCount]
    {
        commonCount += 1
    }

    let parents = Array(repeating: "..", count: sourceComponents.count - commonCount)
    let children = Array(destinationComponents.dropFirst(commonCount))
    let components = parents + children
    return components.isEmpty ? "." : components.joined(separator: "/")
}

func normalizeBundle(at root: URL) throws {
    let fileManager = FileManager.default
    let standardizedRoot = root.standardizedFileURL
    let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
    let rootPath = resolvedRoot.path
    guard let enumerator = fileManager.enumerator(
        at: standardizedRoot,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: [],
        errorHandler: { url, error in
            fputs("failed to inspect \(url.path): \(error)\n", stderr)
            return false
        }
    ) else {
        throw NormalizationError.invalidArguments
    }

    var links: [URL] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            links.append(url)
        }
    }

    var normalizedCount = 0
    for link in links {
        let rawTarget = try fileManager.destinationOfSymbolicLink(atPath: link.path)
        let targetURL: URL
        if rawTarget.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: rawTarget)
        } else {
            targetURL = link.deletingLastPathComponent().appendingPathComponent(rawTarget)
        }
        let resolvedTarget = targetURL.standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: resolvedTarget.path) else {
            throw NormalizationError.brokenLink(link.path, rawTarget)
        }
        guard isContained(resolvedTarget.path, by: rootPath) else {
            throw NormalizationError.escapedBundle(link.path, rawTarget)
        }

        if rawTarget.hasPrefix("/") {
            let relativeSuffix = String(resolvedTarget.path.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let portableTarget = relativeSuffix.isEmpty
                ? standardizedRoot
                : standardizedRoot.appendingPathComponent(relativeSuffix)
            let replacement = relativePath(
                from: link.deletingLastPathComponent(),
                to: portableTarget
            )
            try fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: replacement)
            normalizedCount += 1
        }
    }

    print("[CPicoSDK] Validated \(links.count) in-bundle symbolic links; normalized \(normalizedCount) absolute links.")
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NormalizationError.invalidArguments
    }
    try normalizeBundle(at: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
} catch {
    fputs("[CPicoSDK] \(error)\n", stderr)
    exit(1)
}
