import Foundation

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
