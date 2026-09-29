import Foundation
import Testing
@testable import PicoFirmwareBuildTool

struct FirmwareRequestTests {
    let arguments = [
        "--product", "Example", "--archive", "/tmp/with spaces/libExample.a",
        "--output-directory", "/tmp/output", "--work-directory", "/tmp/work",
        "--package-directory", "/tmp/package", "--sdk-directory", "/tmp/sdk",
        "--memory-map-tool", "/tmp/report",
    ]

    @Test func incrementalByDefault() throws {
        let request = try FirmwareRequest(arguments: arguments)
        #expect(request.product == "Example")
        #expect(request.archive.path == "/tmp/with spaces/libExample.a")
        #expect(!request.clean)
        #expect(request.resources.isEmpty)
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
