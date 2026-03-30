import Foundation

// TODO: Figure out how to share or keep synchronized between GenerateCPicoSDKPlugin and FinalizeBinaryPlugin

final actor SelfGatheringReadPipe {
    private let pipe: Pipe
    private var data = Data()
    private var isClosed = false
    private var dataWaiters: [CheckedContinuation<Data, Never>] = []

    init() {
        self.pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let actorSelf = self else { return }
            Task { [actorSelf, chunk] in
                await actorSelf.consume(chunk)
            }
        }
    }

    nonisolated var ioPipe: Pipe {
        pipe
    }

    func readDataToEndOfFile() async -> Data {
        if isClosed {
            return data
        }

        return await withCheckedContinuation { continuation in
            if isClosed {
                continuation.resume(returning: self.data)
            } else {
                dataWaiters.append(continuation)
            }
        }
    }

    private func consume(_ chunk: Data) {
        guard !isClosed else { return }

        if chunk.isEmpty {
            isClosed = true
            pipe.fileHandleForReading.readabilityHandler = nil

            let finalData = data
            let waiters = dataWaiters
            dataWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume(returning: finalData)
            }
            return
        }

        data.append(chunk)
    }
}

extension Process {
    func asyncRun() async throws -> Int32 {
        try await asyncRun(captureStdout: false, captureStderr: false).status
    }

    func asyncRun(captureStdout: Bool, captureStderr: Bool) async throws -> (status: Int32, stdout: Data?, stderr: Data?) {
        var stdoutGatherer: SelfGatheringReadPipe?
        if captureStdout {
            let gatherer = SelfGatheringReadPipe()
            self.standardOutput = gatherer.ioPipe
            stdoutGatherer = gatherer
        }

        var stderrGatherer: SelfGatheringReadPipe?
        if captureStderr {
            let gatherer = SelfGatheringReadPipe()
            self.standardError = gatherer.ioPipe
            stderrGatherer = gatherer
        }

        async let status: Int32 = try withCheckedThrowingContinuation { continuation in
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

        async let stdout = stdoutGatherer?.readDataToEndOfFile()
        async let stderr = stderrGatherer?.readDataToEndOfFile()

        self.terminationHandler = nil

        return (try await status, await stdout, await stderr)
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