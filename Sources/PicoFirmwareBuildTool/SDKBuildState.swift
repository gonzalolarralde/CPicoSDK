import Foundation

// The link command must consume the exact configuration built by the SDK command.
struct SDKBuildState: Codable, Equatable {
    let arguments: [String]
    let environment: [String: String]

    static func file(in directory: URL) -> URL {
        directory.appending(path: "sdk-build.json")
    }

    func record(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file(in: directory), options: .atomic)
    }

    func validate(in directory: URL) throws {
        let previous = (try? Data(contentsOf: Self.file(in: directory)))
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        guard previous == self,
              FileManager.default.fileExists(atPath: directory.appending(path: "libPicoSDK.a").path) else {
            throw StateError.sdkBuildRequired
        }
    }

    enum StateError: Error, LocalizedError {
        case sdkBuildRequired

        var errorDescription: String? {
            "Pico SDK build is missing or its configuration changed. Run the sdk phase before linking."
        }
    }
}
