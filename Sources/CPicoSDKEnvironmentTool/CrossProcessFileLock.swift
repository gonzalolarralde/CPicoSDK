import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An advisory lock whose lifetime is tied to an open file descriptor.
///
/// `flock` locks are released by the kernel when the process exits, including
/// abnormal exits. The explicit `unlock()` in `deinit` makes the normal path
/// deterministic while retaining that crash-safety property.
final class CrossProcessFileLock {
    private var descriptor: Int32
    private let path: String

    init(at url: URL) throws {
        path = url.path
        descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw EnvironmentToolError.lockFailed(path: path, errorNumber: errno)
        }

        guard flock(descriptor, LOCK_EX) == 0 else {
            let errorNumber = errno
            close(descriptor)
            descriptor = -1
            throw EnvironmentToolError.lockFailed(path: path, errorNumber: errorNumber)
        }
    }

    deinit {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}
