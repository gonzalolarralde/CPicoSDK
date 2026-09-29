import Foundation

struct CMakeBuildEnvironment: Codable, Equatable {
    let values: [String: String]

    init(_ environment: [String: String]) {
        let keys: Set<String> = [
            "PICO_SDK_PATH", "SDK_VERSION", "PICO_TOOLCHAIN_PATH", "TOOLCHAIN_VERSION",
            "CMAKE_PATH", "CMAKE_VERSION", "NINJA_PATH", "NINJA_VERSION", "BOARD",
        ]
        values = environment.filter { keys.contains($0.key) }
    }

    private func stamp(in directory: URL) -> URL {
        directory.appendingPathComponent("cpicosdk-build-environment.json")
    }

    func prepare(_ directory: URL, clean: Bool) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let previous = (try? Data(contentsOf: stamp(in: directory)))
                .flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
            // Missing stamps include build directories created before cache tracking.
            if clean || previous != self {
                print("[CPicoSDK] Resetting CMake build directory: clean requested or SDK/toolchain environment changed.")
                try manager.removeItem(at: directory)
            }
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func record(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: stamp(in: directory), options: .atomic)
    }
}
