import Foundation

extension FileManager {
    func ensureDirectoryExists(at path: String, isDirectory: Bool) throws {
        let url = URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        try FileManager.default.createDirectory(
            at: isDirectory ? url : url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

extension Process {
    // TODO: Move to shared package
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
