import Foundation

public struct FirmwareFinalizationRequest: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public struct EmbeddedResource: Codable, Hashable, Sendable {
        public let name: String
        public let path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    public let schemaVersion: Int
    public let productName: String
    public let productArchivePath: String
    public let nativeSupportArchivePath: String?
    public let pioasmPackageDirectoryPath: String?
    public let outputDirectoryPath: String
    public let workingDirectoryPath: String
    public let cmakeHarnessDirectoryPath: String
    public let packageDirectoryPath: String
    public let cpicoSDKDirectoryPath: String
    public let memoryMapToolPath: String
    public let swiftBuildType: String
    public let platformTriple: String
    public let embeddedResources: [EmbeddedResource]
    public let incremental: Bool
    public let environment: [String: String]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        productName: String,
        productArchivePath: String,
        nativeSupportArchivePath: String?,
        pioasmPackageDirectoryPath: String?,
        outputDirectoryPath: String,
        workingDirectoryPath: String,
        cmakeHarnessDirectoryPath: String,
        packageDirectoryPath: String,
        cpicoSDKDirectoryPath: String,
        memoryMapToolPath: String,
        swiftBuildType: String,
        platformTriple: String,
        embeddedResources: [EmbeddedResource],
        incremental: Bool,
        environment: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.productName = productName
        self.productArchivePath = productArchivePath
        self.nativeSupportArchivePath = nativeSupportArchivePath
        self.pioasmPackageDirectoryPath = pioasmPackageDirectoryPath
        self.outputDirectoryPath = outputDirectoryPath
        self.workingDirectoryPath = workingDirectoryPath
        self.cmakeHarnessDirectoryPath = cmakeHarnessDirectoryPath
        self.packageDirectoryPath = packageDirectoryPath
        self.cpicoSDKDirectoryPath = cpicoSDKDirectoryPath
        self.memoryMapToolPath = memoryMapToolPath
        self.swiftBuildType = swiftBuildType
        self.platformTriple = platformTriple
        self.embeddedResources = embeddedResources
        self.incremental = incremental
        self.environment = environment
    }
}
