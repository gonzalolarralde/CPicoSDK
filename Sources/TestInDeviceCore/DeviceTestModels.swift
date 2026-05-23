import Foundation

public enum DeviceTestHarnessError: Error, CustomStringConvertible, Equatable {
    case missingMetadataBlock(String)
    case invalidMetadata(String)
    case noCallableTests(String)
    case unsupportedSwiftTestingSyntax(String)
    case asyncTestRequiresConcurrency(String)
    case processFailed(command: String, status: Int32, output: String)
    case missingTool(String)

    public var description: String {
        switch self {
        case .missingMetadataBlock(let path):
            return "missing //% metadata block in \(path)"
        case .invalidMetadata(let message):
            return "invalid metadata: \(message)"
        case .noCallableTests(let path):
            return "no top-level no-argument test functions found in \(path)"
        case .unsupportedSwiftTestingSyntax(let path):
            return "Swift Testing syntax is not supported by this embedded harness yet: \(path)"
        case .asyncTestRequiresConcurrency(let name):
            return "async test '\(name)' requires metadata concurrency: true"
        case .processFailed(let command, let status, let output):
            return "command failed with status \(status): \(command)\n\(output)"
        case .missingTool(let name):
            return "required tool not found: \(name)"
        }
    }
}

public struct DeviceTestMetadata: Equatable {
    public var name: String
    public var timeoutMilliseconds: Int
    public var concurrency: Bool
    public var traits: TraitSelection
    public var expectations: DeviceExpectations

    public init(
        name: String,
        timeoutMilliseconds: Int = 5_000,
        concurrency: Bool = false,
        traits: TraitSelection = TraitSelection(),
        expectations: DeviceExpectations = DeviceExpectations()
    ) {
        self.name = name
        self.timeoutMilliseconds = timeoutMilliseconds
        self.concurrency = concurrency
        self.traits = traits
        self.expectations = expectations
    }
}

public struct TraitSelection: Equatable {
    public var add: [String]
    public var remove: [String]

    public init(add: [String] = [], remove: [String] = []) {
        self.add = add
        self.remove = remove
    }

    public static let defaultTraits = [
        "BootStage2_W25Q080",
        "StdIO_RTT",
        "Platform_RP2350",
        "Variant_RP2350A",
        "Radio_None",
    ]

    public func resolvedTraits() -> [String] {
        var result = Self.defaultTraits
        for removed in remove {
            result.removeAll { $0 == removed }
        }
        for added in add where !result.contains(added) {
            if added.hasPrefix("StdIO_") {
                result.removeAll { $0.hasPrefix("StdIO_") }
            }
            result.append(added)
        }
        if !result.contains(where: { $0.hasPrefix("StdIO_") }) {
            result.append("StdIO_RTT")
        }
        return result
    }
}

public struct DeviceExpectations: Equatable {
    public var stdout: StdoutExpectation?
    public var duration: DurationExpectation?

    public init(stdout: StdoutExpectation? = nil, duration: DurationExpectation? = nil) {
        self.stdout = stdout
        self.duration = duration
    }
}

public struct StdoutExpectation: Equatable {
    public var equals: String?
    public var contains: String?
    public var regex: String?

    public init(equals: String? = nil, contains: String? = nil, regex: String? = nil) {
        self.equals = equals
        self.contains = contains
        self.regex = regex
    }
}

public struct DurationExpectation: Equatable {
    public var minMilliseconds: Int?
    public var maxMilliseconds: Int?

    public init(minMilliseconds: Int? = nil, maxMilliseconds: Int? = nil) {
        self.minMilliseconds = minMilliseconds
        self.maxMilliseconds = maxMilliseconds
    }
}

public struct DeviceTestFunction: Equatable {
    public var name: String
    public var isAsync: Bool
    public var isThrowing: Bool

    public init(name: String, isAsync: Bool, isThrowing: Bool) {
        self.name = name
        self.isAsync = isAsync
        self.isThrowing = isThrowing
    }
}

public struct DeviceTestSource: Equatable {
    public var fileURL: URL
    public var source: String
    public var metadata: DeviceTestMetadata
    public var functions: [DeviceTestFunction]

    public init(fileURL: URL, source: String, metadata: DeviceTestMetadata, functions: [DeviceTestFunction]) {
        self.fileURL = fileURL
        self.source = source
        self.metadata = metadata
        self.functions = functions
    }
}

public struct GeneratedPackage: Equatable {
    public var packageDirectory: URL
    public var elfURL: URL
    public var productName: String
    public var inputsChanged: Bool

    public init(packageDirectory: URL, elfURL: URL, productName: String, inputsChanged: Bool = true) {
        self.packageDirectory = packageDirectory
        self.elfURL = elfURL
        self.productName = productName
        self.inputsChanged = inputsChanged
    }
}

public struct DeviceTestEvaluation: Equatable {
    public var passed: Bool
    public var reason: String?

    public init(passed: Bool, reason: String? = nil) {
        self.passed = passed
        self.reason = reason
    }
}

public struct DeviceFunctionDuration: Equatable {
    public var name: String
    public var durationMilliseconds: Int
    public var passed: Bool

    public init(name: String, durationMilliseconds: Int, passed: Bool = true) {
        self.name = name
        self.durationMilliseconds = durationMilliseconds
        self.passed = passed
    }
}
