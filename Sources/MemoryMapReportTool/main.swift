import Foundation

enum MemoryKind: String, CaseIterable {
    case flash = "Flash"
    case ram = "RAM"
    case other = "Other"
}

enum Category: String, CaseIterable {
    case user = "User program"
    case cpicoConcurrency = "CPicoConcurrency"
    case cpicoSDK = "CPicoSDK"
    case picoSDK = "Pico SDK"
    case swiftRuntime = "Swift runtime"
    case toolchainRuntime = "C/C++ runtime"
    case embeddedResource = "Embedded resources"
    case unknown = "Other/unknown"
}

struct Contribution {
    var category: Category
    var kind: MemoryKind
    var bytes: UInt64
    var address: UInt64
    var section: String
}

struct SectionSize {
    var name: String
    var bytes: UInt64
    var address: UInt64
}

struct Symbol {
    var name: String
    var value: UInt64
}

struct Options {
    var packageDir: URL?
    var cpicoSDKPath: URL?
    var elfPath: URL?
    var mapPath: URL?
    var verbose = false
    var showSections = true
}

@main
struct MemoryMapReportTool {
    static func main() {
        do {
            let options = try parseOptions()
            let packageDir = options.packageDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let cpicoSDKPath = options.cpicoSDKPath ?? packageDir
            let env = loadPreparedEnvironment(packageDir: packageDir)
            let artifact = try resolveArtifact(options: options, packageDir: packageDir, env: env)
            let tools = try resolveToolchain(env: env, packageDir: packageDir)

            let sections = try readSections(sizePath: tools.size, elfPath: artifact.elf)
            let symbols = try readSymbols(nmPath: tools.nm, elfPath: artifact.elf)
            let ownershipSectionNames = Set(sections.filter { section in
                memoryKind(address: section.address, section: section.name) != .other && !isHeapSection(section.name)
            }.map(\.name))
            let rawContributions = artifact.map.flatMap {
                parseMap($0, allowedOutputSections: ownershipSectionNames, productName: env["SWIFTPM_PRODUCT"], cpicoSDKPath: cpicoSDKPath.path)
            } ?? []
            let contributions = reconcileOwnershipTotals(rawContributions, sections: sections)

            printReport(
                packageDir: packageDir,
                env: env,
                elf: artifact.elf,
                map: artifact.map,
                sections: sections,
                symbols: symbols,
                contributions: contributions,
                showSections: options.showSections,
                verbose: options.verbose
            )
        } catch let error as ToolError {
            writeStandardError("\(error.description)\n")
            Foundation.exit(1)
        } catch {
            writeStandardError("[CPicoSDK] \(error)\n")
            Foundation.exit(1)
        }
    }
}

func parseOptions() throws -> Options {
    var options = Options()
    var positional: [String] = []
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--package-dir":
            options.packageDir = URL(fileURLWithPath: try takeValue(&args, for: arg))
        case "--cpicosdk-path":
            options.cpicoSDKPath = URL(fileURLWithPath: try takeValue(&args, for: arg))
        case "--elf":
            options.elfPath = URL(fileURLWithPath: try takeValue(&args, for: arg))
        case "--map":
            options.mapPath = URL(fileURLWithPath: try takeValue(&args, for: arg))
        case "--verbose":
            options.verbose = true
        case "--no-sections":
            options.showSections = false
        case "--help", "-h":
            printUsage()
            Foundation.exit(0)
        default:
            if arg.hasPrefix("-") {
                throw ToolError.message("Unknown argument: \(arg)")
            }
            positional.append(arg)
        }
    }
    if positional.count > 2 {
        throw ToolError.message("Expected at most two positional paths: <elf> [map]")
    }
    if let first = positional.first {
        if options.elfPath != nil {
            throw ToolError.message("Pass the ELF either positionally or with --elf, not both")
        }
        options.elfPath = URL(fileURLWithPath: first)
    }
    if positional.count == 2 {
        if options.mapPath != nil {
            throw ToolError.message("Pass the map either positionally or with --map, not both")
        }
        options.mapPath = URL(fileURLWithPath: positional[1])
    }
    return options
}

func takeValue(_ args: inout [String], for flag: String) throws -> String {
    guard !args.isEmpty else {
        throw ToolError.message("Missing value for \(flag)")
    }
    return args.removeFirst()
}

func printUsage() {
    print("""
    Usage: swift package memory-map-report [elf] [map] [--elf path] [--map path] [--verbose] [--no-sections]

    Reports flash/RAM section sizes and ownership for an existing CPicoSDK ELF.
    If an ELF path is provided without a map path, the tool first looks for a
    sibling .map file, such as app.elf.map or app.map.
    This command does not build. Run your project build first if no ELF exists.
    """)
}

func loadPreparedEnvironment(packageDir: URL) -> [String: String] {
    let envFile = packageDir.appendingPathComponent(".env_prep")
    guard FileManager.default.fileExists(atPath: envFile.path) else {
        return ProcessInfo.processInfo.environment
    }
    let script = "set -euo pipefail; source '\(shellQuote(envFile.path))'; /usr/bin/env -0"
    guard let output = try? run("/bin/bash", ["-lc", script]) else {
        return ProcessInfo.processInfo.environment
    }
    var env: [String: String] = [:]
    for part in output.split(separator: "\0", omittingEmptySubsequences: true) {
        guard let equal = part.firstIndex(of: "=") else { continue }
        env[String(part[..<equal])] = String(part[part.index(after: equal)...])
    }
    return env
}

struct Artifact {
    var elf: URL
    var map: URL?
}

func resolveArtifact(options: Options, packageDir: URL, env: [String: String]) throws -> Artifact {
    if let elfPath = options.elfPath {
        guard FileManager.default.fileExists(atPath: elfPath.path) else {
            throw ToolError.message("ELF not found: \(elfPath.path)")
        }
        return Artifact(elf: elfPath, map: try resolveMap(explicit: options.mapPath, elf: elfPath, packageDir: packageDir, productName: env["SWIFTPM_PRODUCT"]))
    }

    let product = env["SWIFTPM_PRODUCT"]
    let triple = env["SWIFTPM_TRIPLE"]
    let buildType = env["SWIFT_BUILD_TYPE"]
    if let product, let triple, let buildType {
        let exact = packageDir
            .appendingPathComponent(".build")
            .appendingPathComponent(triple)
            .appendingPathComponent(buildType)
            .appendingPathComponent("\(product).elf")
        if FileManager.default.fileExists(atPath: exact.path) {
            return Artifact(elf: exact, map: try resolveMap(explicit: options.mapPath, elf: exact, packageDir: packageDir, productName: product))
        }
    }

    let candidates = findFiles(under: packageDir.appendingPathComponent(".build")) { url in
        url.pathExtension == "elf" && (product == nil || url.lastPathComponent == "\(product!).elf")
    }
    guard let newest = newestFile(candidates) else {
        let buildHint = product.map { "./build.sh or swift package finalize-rp2xxx-binary \($0)" } ?? "./build.sh"
        throw ToolError.message("No existing CPicoSDK ELF found under \(packageDir.path)/.build. Build first with \(buildHint), then rerun memory-map-report.")
    }
    return Artifact(elf: newest, map: try resolveMap(explicit: options.mapPath, elf: newest, packageDir: packageDir, productName: product))
}

func resolveMap(explicit: URL?, elf: URL, packageDir: URL, productName: String?) throws -> URL? {
    if let explicit {
        guard FileManager.default.fileExists(atPath: explicit.path) else {
            throw ToolError.message("Map not found: \(explicit.path)")
        }
        return explicit
    }

    for sibling in siblingMapCandidates(for: elf) {
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
    }

    if let productName {
        let finalizerRoot = packageDir
            .appendingPathComponent(".build")
            .appendingPathComponent("plugins")
            .appendingPathComponent("FinalizeBinaryPlugin")
            .appendingPathComponent("outputs")
            .appendingPathComponent("CMakeHarness")
        if let board = loadPreparedEnvironment(packageDir: packageDir)["BOARD"] {
            let exact = finalizerRoot
                .appendingPathComponent("build_\(board)")
                .appendingPathComponent("\(productName).elf.map")
            if FileManager.default.fileExists(atPath: exact.path) {
                return exact
            }
        }
    }
    let maps = findFiles(under: packageDir.appendingPathComponent(".build")) { url in
        guard url.pathExtension == "map" else { return false }
        if let productName {
            return url.lastPathComponent == "\(productName).elf.map"
        }
        return url.lastPathComponent.hasSuffix(".elf.map")
    }
    return newestFile(maps)
}

func siblingMapCandidates(for elf: URL) -> [URL] {
    let directory = elf.deletingLastPathComponent()
    let basename = elf.lastPathComponent
    let stem = elf.deletingPathExtension().lastPathComponent
    return [
        directory.appendingPathComponent("\(basename).map"),
        directory.appendingPathComponent("\(stem).map"),
    ]
}

func boardNameFromMapPath(_ map: URL) -> String? {
    let directory = map.deletingLastPathComponent().lastPathComponent
    guard directory.hasPrefix("build_") else {
        return nil
    }
    return String(directory.dropFirst("build_".count))
}

struct Toolchain {
    var size: String
    var nm: String
}

func resolveToolchain(env: [String: String], packageDir: URL) throws -> Toolchain {
    let searchRoots = [
        env["PICO_TOOLCHAIN_PATH"],
        env["PICO_SDK_BUNDLE_PATH"].map { "\($0)/toolchain" },
        "\(packageDir.path)/.build/plugins/PrepareEnvironmentPlugin/outputs",
        "\(NSHomeDirectory())/.pico-sdk/toolchain",
    ].compactMap { $0 }

    let size = findExecutable(named: "arm-none-eabi-size", roots: searchRoots)
    let nm = findExecutable(named: "arm-none-eabi-nm", roots: searchRoots)
    guard let size, let nm else {
        throw ToolError.message("Could not find arm-none-eabi-size and arm-none-eabi-nm. Run prepare-rp2xxx-environment or pass an ELF from a prepared project.")
    }
    return Toolchain(size: size.path, nm: nm.path)
}

func readSections(sizePath: String, elfPath: URL) throws -> [SectionSize] {
    let output = try run(sizePath, ["-A", elfPath.path])
    return output.split(separator: "\n").compactMap { line in
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 3,
              let bytes = UInt64(parts[1]),
              let address = UInt64(parts[2]) else {
            return nil
        }
        return SectionSize(name: String(parts[0]), bytes: bytes, address: address)
    }
}

func readSymbols(nmPath: String, elfPath: URL) throws -> [Symbol] {
    let output = try run(nmPath, ["-n", elfPath.path])
    return output.split(separator: "\n").compactMap { line in
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 3,
              let value = UInt64(parts[0], radix: 16) else {
            return nil
        }
        return Symbol(name: String(parts[2]), value: value)
    }
}

func parseMap(_ url: URL, allowedOutputSections: Set<String>, productName: String?, cpicoSDKPath: String) -> [Contribution] {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
        return []
    }
    return parseMapContent(content, allowedOutputSections: allowedOutputSections, productName: productName, cpicoSDKPath: cpicoSDKPath)
}

func parseMapContent(_ content: String, allowedOutputSections: Set<String>, productName: String?, cpicoSDKPath: String) -> [Contribution] {
    var contributions: [Contribution] = []
    var currentOutputSection: String?
    var pendingSplitInputSectionOutput: String?
    var coveredRangesBySection: [String: [ClosedRange<UInt64>]] = [:]

    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let startsIndented = line.first?.isWhitespace == true
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)

        if !startsIndented, let first = parts.first, first.hasPrefix(".") {
            currentOutputSection = first
            pendingSplitInputSectionOutput = nil
            continue
        }

        if startsIndented, let first = parts.first, first.hasPrefix(".") {
            if parts.count >= 4, parseHex(parts[1]) != nil, parseHex(parts[2]) != nil {
                pendingSplitInputSectionOutput = nil
            } else {
                pendingSplitInputSectionOutput = currentOutputSection
                continue
            }
        }

        guard let parsed = parseMapContributionLine(line, currentOutputSection: currentOutputSection, pendingSplitInputSectionOutput: pendingSplitInputSectionOutput) else {
            continue
        }
        pendingSplitInputSectionOutput = nil
        guard parsed.address != 0, parsed.bytes > 0 else {
            continue
        }
        guard allowedOutputSections.contains(parsed.section) else {
            continue
        }
        let uncoveredBytes = recordUncoveredBytes(
            address: parsed.address,
            bytes: parsed.bytes,
            ranges: &coveredRangesBySection[parsed.section, default: []]
        )
        guard uncoveredBytes > 0 else {
            continue
        }
        let category = classifyObject(parsed.object, productName: productName, cpicoSDKPath: cpicoSDKPath)
        let kind = memoryKind(address: parsed.address, section: parsed.section)
        guard kind != .other else {
            continue
        }
        contributions.append(Contribution(category: category, kind: kind, bytes: uncoveredBytes, address: parsed.address, section: parsed.section))
    }
    return contributions
}

func recordUncoveredBytes(address: UInt64, bytes: UInt64, ranges: inout [ClosedRange<UInt64>]) -> UInt64 {
    guard bytes > 0 else {
        return 0
    }
    var uncovered = [(start: address, end: address + bytes - 1)]
    for range in ranges {
        var next: [(start: UInt64, end: UInt64)] = []
        for fragment in uncovered {
            if range.upperBound < fragment.start || range.lowerBound > fragment.end {
                next.append(fragment)
                continue
            }
            if fragment.start < range.lowerBound {
                next.append((fragment.start, range.lowerBound - 1))
            }
            if fragment.end > range.upperBound {
                next.append((range.upperBound + 1, fragment.end))
            }
        }
        uncovered = next
        if uncovered.isEmpty {
            break
        }
    }
    for fragment in uncovered {
        ranges.append(fragment.start...fragment.end)
    }
    return uncovered.reduce(UInt64(0)) { total, fragment in
        total + fragment.end - fragment.start + 1
    }
}

func reconcileOwnershipTotals(_ contributions: [Contribution], sections: [SectionSize]) -> [Contribution] {
    var reconciled = contributions
    let sectionTotals = Dictionary(uniqueKeysWithValues: sections.map { ($0.name, $0) })
    let contributionTotals = Dictionary(grouping: contributions, by: \.section)
        .mapValues { $0.map(\.bytes).reduce(UInt64(0), +) }

    for section in sections {
        let kind = memoryKind(address: section.address, section: section.name)
        guard kind != .other && !isHeapSection(section.name) else {
            continue
        }
        let attributed = contributionTotals[section.name] ?? 0
        if section.bytes > attributed {
            reconciled.append(
                Contribution(
                    category: .unknown,
                    kind: kind,
                    bytes: section.bytes - attributed,
                    address: section.address + attributed,
                    section: section.name
                )
            )
        } else if attributed > section.bytes, sectionTotals[section.name] != nil {
            // The range de-duplication above should prevent this. Keep the branch
            // explicit so tests can assert summary/ownership consistency.
        }
    }
    return reconciled
}

func parseMapContributionLine(_ line: String, currentOutputSection: String?, pendingSplitInputSectionOutput: String?) -> (section: String, address: UInt64, bytes: UInt64, object: String)? {
    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard parts.count >= 3 else { return nil }

    if parts[0].hasPrefix("."),
       parts.count >= 4,
       let address = parseHex(parts[1]),
       let bytes = parseHex(parts[2]),
       let currentOutputSection {
        return (currentOutputSection, address, bytes, parts[3...].joined(separator: " "))
    }

    if let pendingSplitInputSectionOutput,
       let address = parseHex(parts[0]),
       let bytes = parseHex(parts[1]),
       parts.count >= 3 {
        return (pendingSplitInputSectionOutput, address, bytes, parts[2...].joined(separator: " "))
    }

    return nil
}

func classifyObject(_ object: String, productName: String?, cpicoSDKPath: String) -> Category {
    let lower = object.lowercased()
    let leaf = object.split(separator: "/").last.map(String.init) ?? object

    if lower.contains("cpicosdk_embedded_resources") || lower.contains(".codeasset.o") {
        return .embeddedResource
    }
    if lower.contains("libswift") || lower.contains("/usr/lib/swift/embedded/") || lower.contains("/embedded/swift/") {
        return .swiftRuntime
    }
    if lower.contains("libswift_concurrency") {
        return .swiftRuntime
    }
    if lower.contains("/pico-sdk-bundle/sdk/") || lower.contains("/pico-sdk/") || lower.contains("/sdk/2.") || lower.contains("libpico_") || lower.contains("libhardware_") {
        return .picoSDK
    }
    if lower.contains("libgcc.a") || lower.contains("libg.a") || lower.contains("libc.a") || lower.contains("libstdc++.a") || lower.contains("crt0.o") || lower.contains("crtbegin.o") {
        return .toolchainRuntime
    }
    if lower.contains("concurrencyshims") || lower.contains("concurrencycpumetricsshims") || lower.contains("cpicoconcurrency") ||
        lower.contains("schedulersystem.swift.o") || lower.contains("schedulertypes.swift.o") ||
        lower.contains("coreexecution.swift.o") || lower.contains("cpumetrics.swift.o") ||
        lower.contains("sleep.swift.o") || lower.contains("isrtrampoline.swift.o") ||
        lower.contains("threading.c.o") || lower.contains("irqwrappers.c.o") {
        return .cpicoConcurrency
    }
    let cpicoSourcesPrefix = cpicoSDKPath.hasSuffix("/") ? "\(cpicoSDKPath)Sources/" : "\(cpicoSDKPath)/Sources/"
    if object.hasPrefix(cpicoSourcesPrefix) || lower.contains("cpicosdk.swift.o") || lower.contains("picosdkimpl.swift.o") ||
        lower.contains("malloc.swift.o") || lower.contains("embeddedapp.swift.o") ||
        lower.contains("unsafeweaklytypedcontainer.swift.o") || lower.contains("armclib") ||
        lower.contains("cshims") || lower.contains("psram") || lower.contains("tlsf.c.o") ||
        lower.contains("memalign.c.o") || lower.contains("mmio.c.o") {
        return .cpicoSDK
    }
    if let productName, lower.contains("lib\(productName.lowercased()).a(") {
        return .user
    }
    if leaf.hasSuffix(".swift.o") || lower.contains("/sources/") {
        return .user
    }
    return .unknown
}

func printReport(
    packageDir: URL,
    env: [String: String],
    elf: URL,
    map: URL?,
    sections: [SectionSize],
    symbols: [Symbol],
    contributions: [Contribution],
    showSections: Bool,
    verbose: Bool
) {
    let flashBytes = sections.filter { memoryKind(address: $0.address, section: $0.name) == .flash }.map(\.bytes).reduce(0, +)
    let staticRAMBytes = sections.filter { section in
        memoryKind(address: section.address, section: section.name) == .ram && !isHeapSection(section.name)
    }.map(\.bytes).reduce(0, +)
    let stackRanges = stackSummary(symbols: symbols)
    let heapBytes = heapCapacity(symbols: symbols)

    print("CPicoSDK Memory Map Report")
    print("==========================")
    print("Product: \(env["SWIFTPM_PRODUCT"] ?? elf.deletingPathExtension().lastPathComponent)  Board: \(env["BOARD"] ?? map.flatMap(boardNameFromMapPath) ?? "unknown")  Build: \(env["SWIFT_BUILD_TYPE"] ?? "unknown")")
    print("Flash sections: \(formatKiB(flashBytes))  Static RAM sections: \(formatKiB(staticRAMBytes))  Heap capacity: \(heapBytes.map(formatKiB) ?? "unknown")")
    for line in stackRanges {
        print(line)
    }
    print("ELF: \(relative(elf, to: packageDir))")
    print("Map: \(map.map { relative($0, to: packageDir) } ?? "not found; ownership report is unavailable")")
    print("")

    if contributions.isEmpty {
        print("Ownership by source: unavailable without a linker map.")
    } else {
        print("Ownership by source")
        print(pad("Category", 22) + pad("Flash", 12) + "RAM")
        var totals: [Category: [MemoryKind: UInt64]] = [:]
        for contribution in contributions {
            totals[contribution.category, default: [:]][contribution.kind, default: 0] += contribution.bytes
        }
        for category in Category.allCases {
            let values = totals[category, default: [:]]
            let total = values.values.reduce(0, +)
            guard total > 0 else { continue }
            print(pad(category.rawValue, 22) + pad(formatKiB(values[.flash] ?? 0), 12) + formatKiB(values[.ram] ?? 0))
        }
    }
    print("")

    if showSections {
        print("Sections")
        print(pad("Section", 24) + pad("Size", 12) + "Address")
        for section in sections.sorted(by: { $0.address == $1.address ? $0.name < $1.name : $0.address < $1.address }) where section.bytes > 0 && (verbose || memoryKind(address: section.address, section: section.name) != .other) {
            print(pad(section.name, 24) + pad(formatKiB(section.bytes), 12) + "0x\(String(section.address, radix: 16))")
        }
    }

    if verbose, !contributions.isEmpty {
        print("")
        print("Classification note: source ownership comes from linker-map object paths. SwiftPM static libraries can mix user and dependency object files, so CPicoSDK/CPicoConcurrency objects are identified by known object/module names before remaining product objects are counted as user program.")
    }
}

func stackSummary(symbols: [Symbol]) -> [String] {
    let dict = symbolDictionary(symbols)
    var lines: [String] = []
    if let bottom = dict["__StackBottom"], let top = dict["__StackTop"], top >= bottom {
        lines.append("Core0 stack: \(formatKiB(top - bottom))  0x\(String(bottom, radix: 16))..0x\(String(top, radix: 16))")
    }
    if let bottom = dict["__StackOneBottom"], let top = dict["__StackOneTop"], top >= bottom {
        lines.append("Core1 stack: \(formatKiB(top - bottom))  0x\(String(bottom, radix: 16))..0x\(String(top, radix: 16))")
    }
    return lines
}

func heapCapacity(symbols: [Symbol]) -> UInt64? {
    let dict = symbolDictionary(symbols)
    guard let end = dict["__end__"], let limit = dict["__HeapLimit"], limit >= end else {
        return nil
    }
    return limit - end
}

func symbolDictionary(_ symbols: [Symbol]) -> [String: UInt64] {
    var result: [String: UInt64] = [:]
    for symbol in symbols {
        result[symbol.name] = symbol.value
    }
    return result
}

func memoryKind(address: UInt64, section: String) -> MemoryKind {
    if section.contains("stack") || section == ".bss" || section.hasPrefix(".bss.") || section == ".data" || section.hasPrefix(".data.") || section == ".heap" {
        return .ram
    }
    if (0x1000_0000..<0x2000_0000).contains(address) {
        return .flash
    }
    if (0x2000_0000..<0x2100_0000).contains(address) {
        return .ram
    }
    return .other
}

func isHeapSection(_ section: String) -> Bool {
    section == ".heap" || section.hasPrefix(".heap.")
}

func findFiles(under root: URL, matching predicate: (URL) -> Bool) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
        return []
    }
    var result: [URL] = []
    for case let url as URL in enumerator {
        let path = url.path
        if shouldPruneSearchPath(path) {
            enumerator.skipDescendants()
            continue
        }
        if predicate(url) {
            result.append(url)
        }
    }
    return result
}

func shouldPruneSearchPath(_ path: String) -> Bool {
    path.contains("/pico-sdk-bundle/sdk/") ||
        path.contains("/pico-sdk-bundle/toolchain/") ||
        path.contains("/pico-sdk-bundle/openocd/") ||
        path.contains("/pico-sdk-bundle/cmake/") ||
        path.contains("/pico-sdk-bundle/ninja/")
}

func newestFile(_ urls: [URL]) -> URL? {
    urls.max { lhs, rhs in
        let ldate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rdate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return ldate < rdate
    }
}

func findExecutable(named name: String, roots: [String]) -> URL? {
    for root in roots {
        let rootURL = URL(fileURLWithPath: root)
        let direct = rootURL.appendingPathComponent("bin").appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: direct.path) {
            return direct
        }
        let matches = findFiles(under: rootURL) { $0.lastPathComponent == name && FileManager.default.isExecutableFile(atPath: $0.path) }
        if let newest = newestFile(matches) {
            return newest
        }
    }
    return nil
}

func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    let outputURL = temporaryDirectory.appendingPathComponent("cpicosdk-memory-map-\(UUID().uuidString).stdout")
    let errorURL = temporaryDirectory.appendingPathComponent("cpicosdk-memory-map-\(UUID().uuidString).stderr")
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
          FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
        throw ToolError.message("Could not create temporary output files for \(executable)")
    }
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer {
        outputHandle.closeFile()
        errorHandle.closeFile()
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: errorURL)
    }
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    try process.run()
    process.waitUntilExit()
    outputHandle.closeFile()
    errorHandle.closeFile()
    let data = try Data(contentsOf: outputURL)
    let errorData = try Data(contentsOf: errorURL)
    guard process.terminationStatus == 0 else {
        let stderr = String(data: errorData, encoding: .utf8) ?? ""
        throw ToolError.message("\(executable) failed: \(stderr)")
    }
    return String(data: data, encoding: .utf8) ?? ""
}

func writeStandardError(_ message: String) {
    guard let data = message.data(using: .utf8) else {
        return
    }
    FileHandle.standardError.write(data)
}

func parseHex(_ value: String) -> UInt64? {
    if value.hasPrefix("0x") {
        return UInt64(value.dropFirst(2), radix: 16)
    }
    return nil
}

func formatKiB(_ bytes: UInt64) -> String {
    String(format: "%.2f KiB", Double(bytes) / 1024.0)
}

func pad(_ value: String, _ width: Int) -> String {
    if value.count >= width {
        return value + " "
    }
    return value + String(repeating: " ", count: width - value.count)
}

func relative(_ url: URL, to root: URL) -> String {
    let path = url.path
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    if path.hasPrefix(rootPath) {
        return String(path.dropFirst(rootPath.count))
    }
    return path
}

func shellQuote(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}

enum ToolError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value):
            return "[CPicoSDK] \(value)"
        }
    }
}
