import Foundation
#if os(Linux)
import Glibc
#endif

// TODO: Figure out how to share or keep synchronized between GenerateCPicoSDKPlugin and FinalizeBinaryPlugin

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
