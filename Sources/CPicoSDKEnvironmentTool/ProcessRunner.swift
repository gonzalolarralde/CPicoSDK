import Foundation

struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ProcessRunner {
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func store(_ data: Data) {
            lock.lock()
            storage = data
            lock.unlock()
        }

        func load() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    static func capture(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> ProcessOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Read both pipes while the child is running. Waiting first can deadlock
        // when a diagnostic is larger than a pipe's kernel buffer.
        let outputGroup = DispatchGroup()
        let outputData = DataBox()
        let errorData = DataBox()
        outputGroup.enter()
        DispatchQueue.global().async {
            outputData.store(stdout.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global().async {
            errorData.store(stderr.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }

        process.waitUntilExit()
        outputGroup.wait()
        return ProcessOutput(
            status: process.terminationStatus,
            stdout: outputData.load(),
            stderr: errorData.load()
        )
    }

    static func checkedCapture(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> ProcessOutput {
        let result = try capture(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory
        )
        guard result.status == 0 else {
            throw EnvironmentToolError.commandFailed(
                executable: executable.path,
                arguments: arguments,
                status: result.status,
                stderr: result.stderrString
            )
        }
        return result
    }

    static func runInheritingIO(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EnvironmentToolError.commandFailed(
                executable: executable.path,
                arguments: arguments,
                status: process.terminationStatus,
                stderr: ""
            )
        }
    }
}
