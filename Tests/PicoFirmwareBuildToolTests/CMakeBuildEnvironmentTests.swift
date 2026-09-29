import Foundation
import Testing
@testable import PicoFirmwareBuildTool

struct CMakeBuildEnvironmentTests {
    private func withBuildDirectory(_ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let object = directory.appendingPathComponent("existing.o")
        try Data([1, 2, 3]).write(to: object)
        try body(directory, object)
    }

    @Test func preservesMatchingEnvironment() throws {
        try withBuildDirectory { directory, object in
            let environment = CMakeBuildEnvironment(["PICO_SDK_PATH": "/sdk", "PATH": "/old"])
            try environment.record(in: directory)
            let next = CMakeBuildEnvironment(["PICO_SDK_PATH": "/sdk", "PATH": "/new"])
            try next.prepare(directory, clean: false)
            #expect(FileManager.default.fileExists(atPath: object.path))
        }
    }

    @Test(arguments: [
        "PICO_SDK_PATH", "SDK_VERSION", "PICO_TOOLCHAIN_PATH", "TOOLCHAIN_VERSION",
        "CMAKE_PATH", "CMAKE_VERSION", "NINJA_PATH", "NINJA_VERSION", "BOARD",
    ])
    func resetsChangedEnvironment(key: String) throws {
        try withBuildDirectory { directory, object in
            try CMakeBuildEnvironment([key: "old"]).record(in: directory)
            try CMakeBuildEnvironment([key: "new"]).prepare(directory, clean: false)
            #expect(!FileManager.default.fileExists(atPath: object.path))
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test func resetsUntrackedBuildDirectory() throws {
        try withBuildDirectory { directory, object in
            try CMakeBuildEnvironment([:]).prepare(directory, clean: false)
            #expect(!FileManager.default.fileExists(atPath: object.path))
        }
    }

    @Test func honorsExplicitClean() throws {
        try withBuildDirectory { directory, object in
            let environment = CMakeBuildEnvironment([:])
            try environment.record(in: directory)
            try environment.prepare(directory, clean: true)
            #expect(!FileManager.default.fileExists(atPath: object.path))
        }
    }
}
