import Foundation
#if os(Linux)
import Glibc
#endif

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
    // TODO: Remove this workaround when upgrading to Swift 6.3+
    // https://github.com/swiftlang/swift/issues/81272
    private func unblockSigchldBeforeSpawnIfNeeded() {
        #if os(Linux)
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGCHLD)
        _ = pthread_sigmask(SIG_UNBLOCK, &set, nil)
        #endif
    }

    // TODO: Move to shared package
    func asyncRun() async throws -> Int32 {
        self.unblockSigchldBeforeSpawnIfNeeded()
        try self.run()

        return await withCheckedContinuation { continuation in
            let waiter = Thread {
                self.waitUntilExit()
                continuation.resume(returning: self.terminationStatus)
            }
            waiter.start()
        }
    }
}
