import Foundation
import Testing
@testable import PicoFirmwareBuildTool

struct SDKBuildStateTests {
    let state = SDKBuildState(arguments: ["-DSTDIO_USB=1"], environment: ["BOARD": "pico2"])

    private func withBuildDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["build.ninja", "libPicoSDK.a"] {
            try Data().write(to: directory.appending(path: name))
        }
        try body(directory)
    }

    @Test func acceptsCompletedMatchingBuild() throws {
        try withBuildDirectory { directory in
            try state.record(in: directory)
            try state.validate(in: directory)
        }
    }

    @Test func rejectsChangedConfiguration() throws {
        try withBuildDirectory { directory in
            try state.record(in: directory)
            let changedArguments = SDKBuildState(arguments: ["-DSTDIO_USB=0"], environment: state.environment)
            let changedEnvironment = SDKBuildState(arguments: state.arguments, environment: ["BOARD": "pico"])
            #expect(throws: SDKBuildState.StateError.self) { try changedArguments.validate(in: directory) }
            #expect(throws: SDKBuildState.StateError.self) { try changedEnvironment.validate(in: directory) }
        }
    }

    @Test(arguments: ["sdk-build.json", "build.ninja", "libPicoSDK.a"])
    func rejectsMissingBuildOutput(name: String) throws {
        try withBuildDirectory { directory in
            try state.record(in: directory)
            try FileManager.default.removeItem(at: directory.appending(path: name))
            #expect(throws: SDKBuildState.StateError.self) { try state.validate(in: directory) }
        }
    }

    @Test func rejectsCorruptState() throws {
        try withBuildDirectory { directory in
            try Data("incomplete".utf8).write(to: SDKBuildState.file(in: directory))
            #expect(throws: SDKBuildState.StateError.self) { try state.validate(in: directory) }
        }
    }
}
