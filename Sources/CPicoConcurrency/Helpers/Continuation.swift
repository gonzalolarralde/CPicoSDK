import _Concurrency
import ConcurrencyShims
private import CPicoSDK

/// Embedded friendly wrapper of `UnsafeContinuation` and `CheckedContinuation` that supports typed 
/// error handling.
public struct EmbeddedContinuation<T: Sendable, E: Error> {
    private let continuation: @Sendable (sending Result<T, E>) -> Void

    fileprivate init(_ continuation: UnsafeContinuation<Result<T, E>, Never>) {
        self.continuation = continuation.resume(returning:)
    }

    fileprivate init(_ continuation: CheckedContinuation<Result<T, E>, Never>) {
        self.continuation = continuation.resume(returning:)
    }    

    public func resume(returning value: T) {
        continuation(.success(value))
    }

    public func resume(throwing error: E) {
        continuation(.failure(error))
    }

    public func resume(with result: Result<T, E>) {
        continuation(result)
    }
}

/// Embedded version of `withUnsafeContinuation` supporting typed error handling.
/// TODO: Remove when support is fixed in the standard library.
public func withEmbeddedUnsafeThrowingContinuation<T: Sendable, E: Error>(_ fn: (EmbeddedContinuation<T, E>) -> Void) async throws(E) -> sending T {
    let result: Result<T, E> = await withUnsafeContinuation { continuation in 
        fn(EmbeddedContinuation(continuation))
    }

    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    }
}

/// Embedded version of `withCheckedContinuation` supporting typed error handling.
/// TODO: Remove when support is fixed in the standard library.
public func withEmbeddedCheckedThrowingContinuation<T: Sendable, E: Error>(_ fn: (EmbeddedContinuation<T, E>) -> Void) async throws(E) -> sending T {
    let result: Result<T, E> = await withCheckedContinuation { continuation in 
        fn(EmbeddedContinuation(continuation))
    }

    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    }
}

extension Task where Success == Never, Failure == Never {
    /// Checks for cancellation in embedded contexts. This is a temporary replacement
    /// for `Task.checkCancellation()` which is currently not supported in embedded contexts.
    public static func checkEmbeddedCancellation() throws(CancellationError) {
        if Self.isCancelled {
            throw _Concurrency.CancellationError()
        }
    }
}
