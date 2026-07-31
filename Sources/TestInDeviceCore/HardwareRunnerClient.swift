import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HardwareRunnerClientConfiguration: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let baseURL: URL
    public let profileID: UUID
    public let poolID: UUID?
    public let capabilities: [String]
    public let captureChannel: String
    public let pollIntervalMilliseconds: UInt64
    public let retryBaseDelayMilliseconds: UInt64

    fileprivate let token: String

    public init(
        baseURL: URL,
        token: String,
        profileID: UUID,
        poolID: UUID? = nil,
        capabilities: [String] = [],
        captureChannel: String = "rtt",
        pollIntervalMilliseconds: UInt64 = 1_000,
        retryBaseDelayMilliseconds: UInt64 = 250
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil
        else {
            throw HardwareRunnerClientError.invalidConfiguration(
                "baseURL must be an HTTP(S) origin or path without credentials, query, or fragment"
            )
        }
        guard !token.isEmpty else {
            throw HardwareRunnerClientError.invalidConfiguration("token cannot be empty")
        }
        guard !captureChannel.isEmpty,
              !captureChannel.hasPrefix("__hr."),
              !captureChannel.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw HardwareRunnerClientError.invalidConfiguration(
                "captureChannel must be a non-reserved channel name"
            )
        }
        guard capabilities.allSatisfy({
            !$0.isEmpty
                && !$0.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }) else {
            throw HardwareRunnerClientError.invalidConfiguration(
                "capabilities cannot be empty or contain control characters"
            )
        }

        self.baseURL = baseURL
        self.token = token
        self.profileID = profileID
        self.poolID = poolID
        self.capabilities = Array(Set(capabilities)).sorted()
        self.captureChannel = captureChannel
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
        self.retryBaseDelayMilliseconds = retryBaseDelayMilliseconds
    }

    public var description: String {
        "HardwareRunnerClientConfiguration(baseURL: \(baseURL.absoluteString), "
            + "token: <redacted>, profileID: \(profileID), poolID: \(String(describing: poolID)), "
            + "capabilities: \(capabilities), captureChannel: \(captureChannel))"
    }

    public var debugDescription: String { description }
}

public struct HardwareRunnerExecutionResult: Sendable, Equatable {
    public let rawOutput: Data
    public let queueElapsed: TimeInterval?
    public let programElapsed: TimeInterval?
    public let captureElapsed: TimeInterval?
    public let jobID: UUID
    public let workItemID: UUID
    public let attemptID: UUID

    public init(
        rawOutput: Data,
        queueElapsed: TimeInterval?,
        programElapsed: TimeInterval?,
        captureElapsed: TimeInterval?,
        jobID: UUID,
        workItemID: UUID,
        attemptID: UUID
    ) {
        self.rawOutput = rawOutput
        self.queueElapsed = queueElapsed
        self.programElapsed = programElapsed
        self.captureElapsed = captureElapsed
        self.jobID = jobID
        self.workItemID = workItemID
        self.attemptID = attemptID
    }
}

public struct HardwareRunnerExecutionInput: Sendable, Equatable {
    public let callerItemID: String
    public let firmwareURL: URL
    public let testName: String
    public let timeoutMilliseconds: Int
    public let runs: Int

    public init(
        callerItemID: String,
        firmwareURL: URL,
        testName: String,
        timeoutMilliseconds: Int,
        runs: Int = 1
    ) {
        self.callerItemID = callerItemID
        self.firmwareURL = firmwareURL
        self.testName = testName
        self.timeoutMilliseconds = timeoutMilliseconds
        self.runs = runs
    }
}

public struct HardwareRunnerBatchExecutionResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case success(HardwareRunnerExecutionResult)
        case failure(HardwareRunnerClientError)
    }

    public let callerItemID: String
    public let runIndex: Int
    public let outcome: Outcome

    public init(
        callerItemID: String,
        runIndex: Int,
        outcome: Outcome
    ) {
        self.callerItemID = callerItemID
        self.runIndex = runIndex
        self.outcome = outcome
    }
}

public struct HardwareRunnerHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        var normalizedHeaders: [String: String] = [:]
        for (name, value) in headers {
            normalizedHeaders[name.lowercased()] = value
        }
        self.headers = normalizedHeaders
        self.body = body
    }
}

public protocol HardwareRunnerHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HardwareRunnerHTTPResponse
}

@available(macOS 12.0, *)
public struct URLSessionHardwareRunnerHTTPTransport: HardwareRunnerHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HardwareRunnerHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HardwareRunnerClientError.invalidResponse(
                "HardwareRunner returned a non-HTTP response"
            )
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HardwareRunnerHTTPResponse(
            statusCode: response.statusCode,
            headers: headers,
            body: data
        )
    }
}

public enum HardwareRunnerClientError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidConfiguration(String)
    case unreadableFirmware(String)
    case emptyFirmware
    case transportFailure(attempts: Int, message: String)
    case httpFailure(statusCode: Int, reason: String)
    case invalidResponse(String)
    case jobTerminated(state: String)
    case infrastructureFailure(state: String, detail: String?)
    case missingCaptureStream(String)
    case ambiguousCaptureStream(String)
    case truncatedCaptureStream(String)
    case captureSizeMismatch(expected: Int64, actual: Int64)
    case captureDigestMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            "invalid HardwareRunner configuration: \(message)"
        case .unreadableFirmware(let message):
            "could not read firmware: \(message)"
        case .emptyFirmware:
            "firmware is empty"
        case .transportFailure(let attempts, let message):
            "HardwareRunner transport failed after \(attempts) attempts: \(message)"
        case .httpFailure(let statusCode, let reason):
            "HardwareRunner returned HTTP \(statusCode): \(reason)"
        case .invalidResponse(let message):
            "invalid HardwareRunner response: \(message)"
        case .jobTerminated(let state):
            "HardwareRunner job terminated in state \(state)"
        case .infrastructureFailure(let state, let detail):
            "HardwareRunner attempt failed in state \(state)"
                + (detail.map { ": \($0)" } ?? "")
        case .missingCaptureStream(let name):
            "HardwareRunner result did not contain capture stream \(name)"
        case .ambiguousCaptureStream(let name):
            "HardwareRunner result contained multiple capture streams named \(name)"
        case .truncatedCaptureStream(let name):
            "HardwareRunner capture stream \(name) was truncated"
        case .captureSizeMismatch(let expected, let actual):
            "HardwareRunner capture size mismatch: expected \(expected), got \(actual)"
        case .captureDigestMismatch(let expected, let actual):
            "HardwareRunner capture digest mismatch: expected \(expected), got \(actual)"
        }
    }
}

@available(macOS 12.0, *)
public struct HardwareRunnerClient: Sendable {
    public static let maximumLogicalRunsPerJob = 10_000

    private static let maximumRetries = 3
    private static let idempotencyInProgressReason =
        "An equivalent request is already being processed"
    private static let successfulAttemptStates: Set<String> = [
        "captureCompleted",
        "captureDeadlineReached",
    ]
    private static let terminalJobStates: Set<String> = [
        "completed",
        "canceled",
        "expired",
    ]

    private let configuration: HardwareRunnerClientConfiguration
    private let transport: any HardwareRunnerHTTPTransport

    public init(
        configuration: HardwareRunnerClientConfiguration,
        transport: any HardwareRunnerHTTPTransport =
            URLSessionHardwareRunnerHTTPTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public static func logicalRunCount(
        for inputs: [HardwareRunnerExecutionInput]
    ) throws -> Int {
        var total = 0
        for input in inputs {
            guard input.runs > 0 else {
                throw HardwareRunnerClientError.invalidConfiguration(
                    "runs must be positive"
                )
            }
            let (updatedTotal, overflowed) =
                total.addingReportingOverflow(input.runs)
            guard !overflowed else {
                throw HardwareRunnerClientError.invalidConfiguration(
                    "total logical run count overflowed"
                )
            }
            total = updatedTotal
        }
        guard total <= maximumLogicalRunsPerJob else {
            throw HardwareRunnerClientError.invalidConfiguration(
                "a job cannot exceed \(maximumLogicalRunsPerJob) logical runs"
            )
        }
        return total
    }

    public func execute(
        firmwareURL: URL,
        testName: String,
        timeoutMilliseconds: Int
    ) async throws -> HardwareRunnerExecutionResult {
        let callerItemID = "cpico-single"
        let results = try await execute(inputs: [
            HardwareRunnerExecutionInput(
                callerItemID: callerItemID,
                firmwareURL: firmwareURL,
                testName: testName,
                timeoutMilliseconds: timeoutMilliseconds
            )
        ])
        guard let result = results.first,
              results.count == 1,
              result.runIndex == 1
        else {
            throw HardwareRunnerClientError.invalidResponse(
                "single-item execution did not return exactly one result"
            )
        }
        switch result.outcome {
        case .success(let execution):
            return execution
        case .failure(let error):
            throw error
        }
    }

    public func execute(
        inputs: [HardwareRunnerExecutionInput]
    ) async throws -> [HardwareRunnerBatchExecutionResult] {
        guard !inputs.isEmpty else {
            throw HardwareRunnerClientError.invalidConfiguration(
                "at least one execution input is required"
            )
        }
        guard inputs.allSatisfy({ $0.timeoutMilliseconds > 0 }) else {
            throw HardwareRunnerClientError.invalidConfiguration(
                "timeoutMilliseconds must be positive"
            )
        }
        let totalLogicalRuns = try Self.logicalRunCount(for: inputs)
        let callerItemIDs = inputs.map(\.callerItemID)
        guard callerItemIDs.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 200
                && !$0.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }) else {
            throw HardwareRunnerClientError.invalidConfiguration(
                "callerItemID must contain 1...200 non-control UTF-8 bytes"
            )
        }
        guard Set(callerItemIDs).count == callerItemIDs.count else {
            throw HardwareRunnerClientError.invalidConfiguration(
                "callerItemID values must be unique within a batch"
            )
        }

        var firmwareByDigest: [String: Data] = [:]
        var digestOrder: [String] = []
        var digestByCallerItemID: [String: String] = [:]
        var firstTestNameByDigest: [String: String] = [:]
        for input in inputs {
            let firmware: Data
            do {
                firmware = try Data(
                    contentsOf: input.firmwareURL,
                    options: .mappedIfSafe
                )
            } catch {
                throw HardwareRunnerClientError.unreadableFirmware(
                    "\(input.callerItemID): \(redact(String(describing: error)))"
                )
            }
            guard !firmware.isEmpty else {
                throw HardwareRunnerClientError.emptyFirmware
            }
            let digest = SHA256.hexDigest(firmware)
            digestByCallerItemID[input.callerItemID] = digest
            if firmwareByDigest[digest] == nil {
                firmwareByDigest[digest] = firmware
                digestOrder.append(digest)
                firstTestNameByDigest[digest] = input.testName
            }
        }

        for digest in digestOrder {
            guard let firmware = firmwareByDigest[digest] else {
                throw HardwareRunnerClientError.invalidResponse(
                    "internal firmware digest mapping was incomplete"
                )
            }
            let object = try await upload(firmware: firmware, digest: digest)
            guard object.digest.lowercased() == digest else {
                throw HardwareRunnerClientError.invalidResponse(
                    "uploaded object digest did not match the ELF bytes"
                )
            }
        }

        var bundleIDByDigest: [String: UUID] = [:]
        for digest in digestOrder {
            let bundle = try await createBundle(
                objectDigest: digest,
                testName: firstTestNameByDigest[digest] ?? "CPicoSDK device test"
            )
            bundleIDByDigest[digest] = bundle.id
        }

        let submitted = try await submitJob(
            inputs: inputs,
            totalLogicalRuns: totalLogicalRuns,
            digestByCallerItemID: digestByCallerItemID,
            bundleIDByDigest: bundleIDByDigest
        )
        let responseCallerIDs = submitted.workItems.map(\.clientItemID)
        guard submitted.workItems.count == inputs.count,
              Set(responseCallerIDs).count == responseCallerIDs.count,
              Set(responseCallerIDs) == Set(callerItemIDs)
        else {
            throw HardwareRunnerClientError.invalidResponse(
                "submitted job work-item IDs did not exactly match the batch"
            )
        }
        let workItemByCallerID = Dictionary(
            uniqueKeysWithValues: submitted.workItems.map {
                ($0.clientItemID, $0)
            }
        )

        let terminalJob = try await waitForTerminalJob(
            initial: submitted,
            jobID: submitted.id
        )
        guard terminalJob.state == "completed" else {
            throw HardwareRunnerClientError.jobTerminated(state: terminalJob.state)
        }

        let export = try await fetchExport(jobID: submitted.id)
        var results: [HardwareRunnerBatchExecutionResult] = []
        results.reserveCapacity(totalLogicalRuns)
        for input in inputs {
            guard let workItem = workItemByCallerID[input.callerItemID] else {
                throw HardwareRunnerClientError.invalidResponse(
                    "missing work item \(input.callerItemID) after validation"
                )
            }
            for runIndex in 1...input.runs {
                do {
                    let execution = try await executionResult(
                        callerItemID: input.callerItemID,
                        runIndex: runIndex,
                        expectedRunCount: input.runs,
                        workItem: workItem,
                        submitted: submitted,
                        export: export
                    )
                    results.append(HardwareRunnerBatchExecutionResult(
                        callerItemID: input.callerItemID,
                        runIndex: runIndex,
                        outcome: .success(execution)
                    ))
                } catch let error as HardwareRunnerClientError {
                    results.append(HardwareRunnerBatchExecutionResult(
                        callerItemID: input.callerItemID,
                        runIndex: runIndex,
                        outcome: .failure(error)
                    ))
                }
            }
        }
        return results
    }

    private func executionResult(
        callerItemID: String,
        runIndex: Int,
        expectedRunCount: Int,
        workItem: JobResponse.Item,
        submitted: JobResponse,
        export: ExportResponse
    ) async throws -> HardwareRunnerExecutionResult {
        let resultIdentity = expectedRunCount == 1
            ? callerItemID
            : "\(callerItemID) run \(runIndex)"
        let matchingAttempts = export.attempts.enumerated().filter {
            guard $0.element.itemID == workItem.id else {
                return false
            }
            if let exportedRunIndex = $0.element.runIndex {
                return exportedRunIndex == runIndex
            }
            // Exports produced before HardwareRunner added run-level identity
            // represent exactly one run. Keep that wire format compatible only
            // for a single-run request; repeated runs must be explicitly fenced.
            return expectedRunCount == 1 && runIndex == 1
        }
        guard let attempt = matchingAttempts.max(by: {
            Self.attemptOrderingKey($0) < Self.attemptOrderingKey($1)
        })?.element else {
            throw HardwareRunnerClientError.infrastructureFailure(
                state: "missingAttempt",
                detail: "\(resultIdentity): "
                    + "the completed work item has no attempt evidence"
            )
        }
        guard Self.successfulAttemptStates.contains(attempt.state) else {
            throw HardwareRunnerClientError.infrastructureFailure(
                state: attempt.state,
                detail: "\(resultIdentity): "
                    + (attempt.outcomeDetail ?? "no infrastructure detail")
            )
        }
        if let exitCode = attempt.programExitCode, exitCode != 0 {
            throw HardwareRunnerClientError.infrastructureFailure(
                state: "programFailed",
                detail: "\(resultIdentity): "
                    + "programmer exited with status \(exitCode)"
            )
        }
        if let exitCode = attempt.verifyExitCode, exitCode != 0 {
            throw HardwareRunnerClientError.infrastructureFailure(
                state: "verifyFailed",
                detail: "\(resultIdentity): "
                    + "verification exited with status \(exitCode)"
            )
        }

        let streams = attempt.streams.filter {
            !$0.name.hasPrefix("__hr.")
                && $0.name == configuration.captureChannel
        }
        guard let stream = streams.first else {
            throw HardwareRunnerClientError.missingCaptureStream(
                configuration.captureChannel
            )
        }
        guard streams.count == 1 else {
            throw HardwareRunnerClientError.ambiguousCaptureStream(
                configuration.captureChannel
            )
        }
        guard !stream.truncated else {
            throw HardwareRunnerClientError.truncatedCaptureStream(stream.name)
        }
        guard stream.byteSize >= 0, stream.totalByteCount >= 0,
              stream.byteSize == stream.totalByteCount
        else {
            throw HardwareRunnerClientError.captureSizeMismatch(
                expected: stream.byteSize,
                actual: stream.totalByteCount
            )
        }

        let rawOutput = try await downloadStream(
            stream.downloadURL,
            jobID: submitted.id
        )
        guard Int64(rawOutput.count) == stream.byteSize else {
            throw HardwareRunnerClientError.captureSizeMismatch(
                expected: stream.byteSize,
                actual: Int64(rawOutput.count)
            )
        }
        let actualDigest = SHA256.hexDigest(rawOutput)
        guard actualDigest == stream.sha256.lowercased() else {
            throw HardwareRunnerClientError.captureDigestMismatch(
                expected: stream.sha256.lowercased(),
                actual: actualDigest
            )
        }

        let submittedAt = parseDate(submitted.submittedAt)
        let attemptStartedAt = parseDate(attempt.startedAt)
        let firstByteAt = stream.firstByteAt.flatMap(parseDate)
        let lastByteAt = stream.lastByteAt.flatMap(parseDate)

        return HardwareRunnerExecutionResult(
            rawOutput: rawOutput,
            queueElapsed: elapsed(from: submittedAt, to: attemptStartedAt),
            programElapsed: elapsed(from: attemptStartedAt, to: firstByteAt),
            captureElapsed: elapsed(from: firstByteAt, to: lastByteAt),
            jobID: submitted.id,
            workItemID: workItem.id,
            attemptID: attempt.id
        )
    }

    private static func attemptOrderingKey(
        _ indexedAttempt: EnumeratedSequence<[ExportResponse.Attempt]>.Element
    ) -> (Int, Int, Int) {
        let attempt = indexedAttempt.element
        return (
            attempt.runAttemptNumber ?? Int.min,
            attempt.attemptNumber ?? Int.min,
            indexedAttempt.offset
        )
    }

    private func upload(
        firmware: Data,
        digest: String
    ) async throws -> ObjectResponse {
        var request = try apiRequest(
            path: "objects",
            method: "POST",
            idempotencyKey: "cpico-object-\(UUID().uuidString.lowercased())"
        )
        request.setValue("application/x-elf", forHTTPHeaderField: "Content-Type")
        request.setValue(digest, forHTTPHeaderField: "X-Content-SHA256")
        request.httpBody = firmware
        return try decode(
            ObjectResponse.self,
            from: try await sendWithRetries(request)
        )
    }

    private func createBundle(
        objectDigest: String,
        testName: String
    ) async throws -> BundleResponse {
        let input = CreateBundleRequest(
            name: testName,
            parts: [
                .init(objectDigest: objectDigest, role: "firmware")
            ],
            metadata: ["testName": testName]
        )
        var request = try apiRequest(
            path: "bundles",
            method: "POST",
            idempotencyKey: "cpico-bundle-\(UUID().uuidString.lowercased())"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encode(input)
        return try decode(
            BundleResponse.self,
            from: try await sendWithRetries(request)
        )
    }

    private func submitJob(
        inputs: [HardwareRunnerExecutionInput],
        totalLogicalRuns: Int,
        digestByCallerItemID: [String: String],
        bundleIDByDigest: [String: UUID]
    ) async throws -> JobResponse {
        let policiesByCallerID = Dictionary(
            uniqueKeysWithValues: inputs.map {
                ($0.callerItemID, capturePolicy(
                    timeoutMilliseconds: $0.timeoutMilliseconds
                ))
            }
        )
        let maximumDeadline = policiesByCallerID.values
            .map(\.hardDeadlineSeconds)
            .max() ?? 1
        let input = CreateJobRequest(
            externalJobID: "cpico-\(UUID().uuidString.lowercased())",
            poolID: configuration.poolID,
            requiredCapabilities: configuration.capabilities,
            profileID: configuration.profileID,
            executionPolicy: "fair",
            priority: 0,
            maximumAttempts: 2,
            // HardwareRunner requires a job-level policy. It is the safe maximum
            // for the batch; every item below carries its exact test timeout.
            capturePolicy: CapturePolicyRequest(
                hardDeadlineSeconds: maximumDeadline,
                endMarkerBase64: captureEndMarkerBase64,
                finishOnTransportClose: true
            ),
            labels: ["producer": "CPicoSDK"],
            metadata: [
                "suite": "CPicoSDK device tests",
                "workItemCount": String(inputs.count),
                "runCount": String(totalLogicalRuns),
            ],
            workItems: try inputs.map { executionInput in
                guard let digest = digestByCallerItemID[
                    executionInput.callerItemID
                ],
                let bundleID = bundleIDByDigest[digest],
                let capturePolicy = policiesByCallerID[
                    executionInput.callerItemID
                ] else {
                    throw HardwareRunnerClientError.invalidResponse(
                        "internal batch artifact mapping was incomplete"
                    )
                }
                return .init(
                    clientItemID: executionInput.callerItemID,
                    bundleID: bundleID,
                    runs: executionInput.runs,
                    capturePolicy: capturePolicy,
                    metadata: ["testName": executionInput.testName]
                )
            }
        )
        var request = try apiRequest(
            path: "jobs",
            method: "POST",
            idempotencyKey: "cpico-job-\(UUID().uuidString.lowercased())"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encode(input)
        return try decode(
            JobResponse.self,
            from: try await sendWithRetries(request)
        )
    }

    private var captureEndMarkerBase64: String {
        Data(DeviceProtocol.captureEndMarker.utf8).base64EncodedString()
    }

    private func capturePolicy(
        timeoutMilliseconds: Int
    ) -> CapturePolicyRequest {
        let seconds = (UInt64(timeoutMilliseconds) + 999) / 1_000
        return CapturePolicyRequest(
            hardDeadlineSeconds: max(1, seconds),
            endMarkerBase64: captureEndMarkerBase64,
            finishOnTransportClose: true
        )
    }

    private func waitForTerminalJob(
        initial: JobResponse,
        jobID: UUID
    ) async throws -> JobResponse {
        var job = initial
        while !Self.terminalJobStates.contains(job.state) {
            try Task.checkCancellation()
            try await sleep(milliseconds: configuration.pollIntervalMilliseconds)
            job = try await pollJob(jobID: jobID)
        }
        return job
    }

    private func pollJob(jobID: UUID) async throws -> JobResponse {
        let request = try apiRequest(path: "jobs/\(jobID.uuidString.lowercased())")
        while true {
            try Task.checkCancellation()
            do {
                let response = try await transport.send(request)
                if isTransient(statusCode: response.statusCode) {
                    try await sleep(milliseconds: configuration.pollIntervalMilliseconds)
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw httpError(for: response)
                }
                return try decode(JobResponse.self, from: response)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HardwareRunnerClientError {
                switch error {
                case .httpFailure, .invalidResponse:
                    throw error
                default:
                    try await sleep(milliseconds: configuration.pollIntervalMilliseconds)
                }
            } catch {
                try await sleep(milliseconds: configuration.pollIntervalMilliseconds)
            }
        }
    }

    private func fetchExport(jobID: UUID) async throws -> ExportResponse {
        let request = try apiRequest(
            path: "jobs/\(jobID.uuidString.lowercased())/export"
        )
        return try decode(
            ExportResponse.self,
            from: try await sendWithRetries(request)
        )
    }

    private func downloadStream(
        _ downloadURL: String,
        jobID: UUID
    ) async throws -> Data {
        let url = try validatedDownloadURL(downloadURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(configuration.token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(
            jobID.uuidString.lowercased(),
            forHTTPHeaderField: "X-CPicoSDK-Job-ID"
        )
        return try await sendWithRetries(request).body
    }

    private func apiRequest(
        path: String,
        method: String = "GET",
        idempotencyKey: String? = nil
    ) throws -> URLRequest {
        let url = configuration.baseURL
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(
            "Bearer \(configuration.token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        return request
    }

    private func sendWithRetries(
        _ request: URLRequest
    ) async throws -> HardwareRunnerHTTPResponse {
        var retryCount = 0
        while true {
            try Task.checkCancellation()
            do {
                let response = try await transport.send(request)
                if isRetryable(response, for: request) {
                    if retryCount < Self.maximumRetries {
                        try await retryDelay(retryCount: retryCount)
                        retryCount += 1
                        continue
                    }
                    throw httpError(for: response)
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw httpError(for: response)
                }
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HardwareRunnerClientError {
                switch error {
                case .httpFailure, .invalidResponse:
                    throw error
                default:
                    if retryCount < Self.maximumRetries {
                        try await retryDelay(retryCount: retryCount)
                        retryCount += 1
                        continue
                    }
                    throw HardwareRunnerClientError.transportFailure(
                        attempts: 1 + Self.maximumRetries,
                        message: redact(String(describing: error))
                    )
                }
            } catch {
                if retryCount < Self.maximumRetries {
                    try await retryDelay(retryCount: retryCount)
                    retryCount += 1
                    continue
                }
                throw HardwareRunnerClientError.transportFailure(
                    attempts: 1 + Self.maximumRetries,
                    message: redact(String(describing: error))
                )
            }
        }
    }

    private func retryDelay(retryCount: Int) async throws {
        let multiplier = UInt64(1) << UInt64(min(retryCount, 20))
        let (delay, overflow) =
            configuration.retryBaseDelayMilliseconds
            .multipliedReportingOverflow(by: multiplier)
        try await sleep(milliseconds: overflow ? UInt64.max : delay)
    }

    private func sleep(milliseconds: UInt64) async throws {
        guard milliseconds > 0 else { return }
        let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(
            by: 1_000_000
        )
        try await Task.sleep(nanoseconds: overflow ? UInt64.max : nanoseconds)
    }

    private func isTransient(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private func isRetryable(
        _ response: HardwareRunnerHTTPResponse,
        for request: URLRequest
    ) -> Bool {
        if isTransient(statusCode: response.statusCode) {
            return true
        }
        guard response.statusCode == 409,
              request.value(forHTTPHeaderField: "Idempotency-Key") != nil,
              let apiError = try? JSONDecoder().decode(
                  APIErrorResponse.self,
                  from: response.body
              )
        else {
            return false
        }
        return apiError.reason == Self.idempotencyInProgressReason
    }

    private func httpError(
        for response: HardwareRunnerHTTPResponse
    ) -> HardwareRunnerClientError {
        let reason: String
        if let apiError = try? JSONDecoder().decode(
            APIErrorResponse.self,
            from: response.body
        ) {
            reason = apiError.reason
        } else if let body = String(data: response.body, encoding: .utf8),
                  !body.isEmpty
        {
            reason = String(body.prefix(2_048))
        } else {
            reason = "request failed"
        }
        return .httpFailure(
            statusCode: response.statusCode,
            reason: redact(reason)
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw HardwareRunnerClientError.invalidResponse(
                "could not encode request: \(redact(String(describing: error)))"
            )
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from response: HardwareRunnerHTTPResponse
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw HardwareRunnerClientError.invalidResponse(
                "could not decode HTTP \(response.statusCode) body as \(type): "
                    + redact(String(describing: error))
            )
        }
    }

    private func validatedDownloadURL(_ string: String) throws -> URL {
        let resolved: URL?
        if let candidate = URL(string: string), candidate.scheme != nil {
            resolved = candidate
        } else {
            resolved = URL(string: string, relativeTo: configuration.baseURL)?
                .absoluteURL
        }
        guard let resolved,
              sameOrigin(resolved, configuration.baseURL)
        else {
            throw HardwareRunnerClientError.invalidResponse(
                "capture download URL is not on the configured HardwareRunner origin"
            )
        }
        return resolved
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
            && lhs.user == nil && lhs.password == nil
    }

    private func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }

    private func elapsed(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    private func redact(_ message: String) -> String {
        message.replacingOccurrences(
            of: configuration.token,
            with: "<redacted>"
        )
    }
}

private struct ObjectResponse: Decodable {
    let digest: String
}

private struct CreateBundleRequest: Encodable {
    struct Part: Encodable {
        let objectDigest: String
        let role: String
    }

    let name: String
    let parts: [Part]
    let metadata: [String: String]
}

private struct BundleResponse: Decodable {
    let id: UUID
}

private struct CapturePolicyRequest: Encodable {
    let hardDeadlineSeconds: UInt64
    let endMarkerBase64: String
    let finishOnTransportClose: Bool
}

private struct CreateJobRequest: Encodable {
    struct Item: Encodable {
        let clientItemID: String
        let bundleID: UUID
        let runs: Int
        let capturePolicy: CapturePolicyRequest
        let metadata: [String: String]
    }

    let externalJobID: String
    let poolID: UUID?
    let requiredCapabilities: [String]
    let profileID: UUID
    let executionPolicy: String
    let priority: Int
    let maximumAttempts: Int
    let capturePolicy: CapturePolicyRequest
    let labels: [String: String]
    let metadata: [String: String]
    let workItems: [Item]
}

private struct JobResponse: Decodable {
    struct Item: Decodable {
        let id: UUID
        let clientItemID: String
    }

    let id: UUID
    let state: String
    let submittedAt: String
    let workItems: [Item]
}

private struct ExportResponse: Decodable {
    struct Attempt: Decodable {
        struct Stream: Decodable {
            let id: UUID
            let name: String
            let sha256: String
            let byteSize: Int64
            let totalByteCount: Int64
            let truncated: Bool
            let firstByteAt: String?
            let lastByteAt: String?
            let downloadURL: String
        }

        let id: UUID
        let itemID: UUID
        let attemptNumber: Int?
        let runIndex: Int?
        let runAttemptNumber: Int?
        let state: String
        let startedAt: String
        let finishedAt: String?
        let programExitCode: Int?
        let verifyExitCode: Int?
        let outcomeDetail: String?
        let streams: [Stream]
    }

    let attempts: [Attempt]
}

private struct APIErrorResponse: Decodable {
    let reason: String
}

private enum SHA256 {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hexDigest(_ data: Data) -> String {
        var bytes = [UInt8](data)
        let bitCount = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }

        var hash = initialHash
        var schedule = [UInt32](repeating: 0, count: 64)
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            for index in 0..<16 {
                let start = offset + index * 4
                schedule[index] =
                    UInt32(bytes[start]) << 24
                    | UInt32(bytes[start + 1]) << 16
                    | UInt32(bytes[start + 2]) << 8
                    | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(schedule[index - 15], by: 7)
                    ^ rotateRight(schedule[index - 15], by: 18)
                    ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], by: 17)
                    ^ rotateRight(schedule[index - 2], by: 19)
                    ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16]
                    &+ s0
                    &+ schedule[index - 7]
                    &+ s1
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]

            for index in 0..<64 {
                let sum1 = rotateRight(e, by: 6)
                    ^ rotateRight(e, by: 11)
                    ^ rotateRight(e, by: 25)
                let choice = (e & f) ^ (~e & g)
                let temporary1 = h
                    &+ sum1
                    &+ choice
                    &+ constants[index]
                    &+ schedule[index]
                let sum0 = rotateRight(a, by: 2)
                    ^ rotateRight(a, by: 13)
                    ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = sum0 &+ majority

                h = g
                g = f
                f = e
                e = d &+ temporary1
                d = c
                c = b
                b = a
                a = temporary1 &+ temporary2
            }

            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }

        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
