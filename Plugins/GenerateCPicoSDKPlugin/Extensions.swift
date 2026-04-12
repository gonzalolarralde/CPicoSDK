import Foundation

// TODO: Figure out how to share or keep synchronized between GenerateCPicoSDKPlugin and FinalizeBinaryPlugin

extension Process {
    func asyncRun() async throws -> Int32 {
        defer {
            self.terminationHandler = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try self.run()
            } catch {
                self.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

enum OptionalError: Error {
    case valueNotFound
}

extension Optional {
    var expected: Wrapped {
        get throws {
            switch self {
            case .some(let value):
                return value
            case .none:
                throw OptionalError.valueNotFound
            }
        }
    }
}

extension Collection {
    var nonEmpty: Self? {
        if self.isEmpty {
            nil
        } else {
            self
        }
    }
}

extension Env {
    static func importedLibs(combination: String) throws -> [String] {
        var importedLibs =
            try Env.value("IMPORTED_LIBS", combination: combination).expected.split(separator: ",")
                .map(String.init)

        try importedLibs.append(
            contentsOf: Env.value("IMPORTED_LIBS_MORE", combination: combination).expected.split(separator: ",")
                .compactMap(\.nonEmpty)
                .map(String.init)
        )

        return importedLibs
    }
}

extension FileManager {
    func ensureDirectoryExists(at path: String, isDirectory: Bool) throws {
        let url = URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        try FileManager.default.createDirectory(
            at: isDirectory ? url : url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
