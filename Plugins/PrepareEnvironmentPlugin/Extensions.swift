import Foundation

extension FileManager {
    func envs(from file: String) -> [String: String]? {
        if FileManager().fileExists(atPath: file),
           let envsContent = FileManager().contents(atPath: file),
           let envs = try? JSONDecoder().decode([String: String].self, from: envsContent)
        {
            return envs
        } else {
            return nil
        }
    }

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
        try await withUnsafeThrowingContinuation { continuation in
            self.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try self.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
