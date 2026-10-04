import Foundation
import Testing
@testable import PicoFirmwareBuildTool

struct FirmwareRequestTests {
    let arguments = [
        "--product", "Example", "--archive", "/tmp/with spaces/libExample.a",
        "--output-directory", "/tmp/output", "--work-directory", "/tmp/work",
        "--sdk-directory", "/tmp/sdk",
    ]

    @Test func incrementalByDefault() throws {
        let request = try FirmwareRequest(arguments: arguments)
        #expect(request.product == "Example")
        #expect(request.archive.path == "/tmp/with spaces/libExample.a")
        #expect(!request.clean)
        #expect(request.resources.isEmpty)
        #expect(request.phase == .all)
        #expect(request.configurationArchive == request.archive)
        #expect(request.buildConfiguration == nil)
        #expect(request.sdkArtifactsDirectory == nil)
    }

    @Test(arguments: FirmwareRequest.Phase.allCases)
    func acceptsBuildPhase(phase: FirmwareRequest.Phase) throws {
        let extra = phase == .link ? ["--sdk-artifacts-directory", "/tmp/sdk artifacts"] : []
        let request = try FirmwareRequest(arguments: arguments + ["--phase", phase.rawValue] + extra)
        #expect(request.phase == phase)
    }

    @Test func separatesConfigurationFromApplicationArchive() throws {
        let request = try FirmwareRequest(arguments: arguments + [
            "--phase", "link", "--configuration-archive", "/tmp/libCPicoSDKConfiguration.a",
            "--sdk-artifacts-directory", "/tmp/sdk artifacts",
            "--build-configuration", "/tmp/build configuration.json",
        ])
        #expect(request.configurationArchive.path == "/tmp/libCPicoSDKConfiguration.a")
        #expect(request.archive.path == "/tmp/with spaces/libExample.a")
        #expect(request.sdkArtifactsDirectory?.path == "/tmp/sdk artifacts")
        #expect(request.buildConfiguration?.path == "/tmp/build configuration.json")
    }

    @Test func linkRequiresPublishedSDK() {
        #expect(throws: FirmwareRequest.RequestError.self) {
            try FirmwareRequest(arguments: arguments + ["--phase", "link"])
        }
    }

    @Test func rejectsInvalidPhaseAndDestructiveLink() {
        #expect(throws: FirmwareRequest.RequestError.self) {
            try FirmwareRequest(arguments: arguments + ["--phase", "compile"])
        }
        #expect(throws: FirmwareRequest.RequestError.self) {
            try FirmwareRequest(arguments: arguments + ["--phase", "link", "--clean"])
        }
    }

    @Test func legacyResourcesAndClean() throws {
        let request = try FirmwareRequest(arguments: arguments + [
            "--clean", "--resource", "/tmp/one.codeasset", "--resource", "/tmp/two.codeasset",
        ])
        #expect(request.clean)
        #expect(request.resources.map(\.lastPathComponent) == ["one.codeasset", "two.codeasset"])
    }

    @Test func rejectsInvalidArguments() {
        #expect(throws: FirmwareRequest.RequestError.self) { try FirmwareRequest(arguments: []) }
        #expect(throws: FirmwareRequest.RequestError.self) {
            try FirmwareRequest(arguments: arguments + ["--product", "Other"])
        }
        #expect(throws: FirmwareRequest.RequestError.self) {
            try FirmwareRequest(arguments: arguments + ["--unknown", "value"])
        }
    }
}
