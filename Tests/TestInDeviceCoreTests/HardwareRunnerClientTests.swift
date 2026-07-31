import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

import Testing
@testable import TestInDeviceCore

private let profileID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let poolID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let bundleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
private let jobID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
private let itemID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
private let attemptID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
private let streamID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
private let journalStreamID = UUID(
    uuidString: "88888888-8888-8888-8888-888888888888"
)!
private let earlierAttemptID = UUID(
    uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
)!
private let laterAttemptID = UUID(
    uuidString: "00000000-0000-0000-0000-000000000001"
)!

private let firmwareBytes = Data("ELF".utf8)
private let firmwareSHA256 =
    "706abe3c90152075e656b661079730facf323f3ebccda7547ee1935c90845a09"
private let captureBytes = Data("captured-output".utf8)
private let captureSHA256 =
    "cc87398727900235e08073aabde7d9b85f3dbec2c2408debeabaa6ace970b7aa"
private let secondFirmwareBytes = Data("ELF2".utf8)
private let secondFirmwareSHA256 =
    "405bbc59b50c6b5d6ed845b96b63f8d8aa8ba97c8f4b68bcf69ffe59053d4d90"
private let secondCaptureBytes = Data("captured-output-2".utf8)
private let secondCaptureSHA256 =
    "b46360b14d813601ef20440d6d3192de24db0cc65949401873d8145ee4663bba"
private let thirdCaptureBytes = Data("captured-output-3".utf8)
private let thirdCaptureSHA256 =
    "d79aee83dd1086cfa321d28a91448fa1bcfb30ff2c4341c9cbbec48dc403708d"
private let testToken = "test-token-that-must-never-appear"

private enum MockTransportError: Error, Sendable, CustomStringConvertible {
    case network(String)

    var description: String {
        switch self {
        case .network(let message): message
        }
    }
}

private struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let authorization: String?
    let idempotencyKey: String?
    let contentType: String?
    let contentSHA256: String?
    let body: Data?

    init(_ request: URLRequest) {
        method = request.httpMethod ?? "GET"
        url = request.url!
        authorization = request.value(forHTTPHeaderField: "Authorization")
        idempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key")
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        contentSHA256 = request.value(forHTTPHeaderField: "X-Content-SHA256")
        body = request.httpBody
    }
}

private actor ScriptedHTTPTransport: HardwareRunnerHTTPTransport {
    enum Step: Sendable {
        case response(HardwareRunnerHTTPResponse)
        case failure(MockTransportError)
    }

    private var steps: [Step]
    private var requests: [RecordedRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> HardwareRunnerHTTPResponse {
        requests.append(RecordedRequest(request))
        guard !steps.isEmpty else {
            fatalError("ScriptedHTTPTransport received more requests than expected")
        }
        switch steps.removeFirst() {
        case .response(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func recordedRequests() -> [RecordedRequest] {
        requests
    }
}

@available(macOS 12.0, *)
@Test func hardwareRunnerClientExecutesAndValidatesRawEvidence() async throws {
    let transport = ScriptedHTTPTransport([
        .response(objectResponse()),
        .response(bundleResponse()),
        .response(jobResponse(state: "queued")),
        .response(jobResponse(state: "running")),
        .failure(.network("temporary poll disconnect")),
        .response(.init(statusCode: 503)),
        .response(jobResponse(state: "completed")),
        .response(exportResponse()),
        .response(.init(statusCode: 200, body: captureBytes)),
    ])
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    let result = try await client.execute(
        firmwareURL: firmwareURL,
        testName: "Hello RTT",
        timeoutMilliseconds: 5_001
    )

    #expect(result.rawOutput == captureBytes)
    #expect(result.jobID == jobID)
    #expect(result.workItemID == itemID)
    #expect(result.attemptID == attemptID)
    #expect(abs((result.queueElapsed ?? -1) - 2) < 0.001)
    #expect(abs((result.programElapsed ?? -1) - 1) < 0.001)
    #expect(abs((result.captureElapsed ?? -1) - 2) < 0.001)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 9)
    #expect(requests.allSatisfy {
        $0.authorization == "Bearer \(testToken)"
    })

    let mutations = Array(requests.prefix(3))
    #expect(mutations.map(\.method) == ["POST", "POST", "POST"])
    #expect(mutations.allSatisfy { $0.idempotencyKey != nil })
    #expect(Set(mutations.compactMap(\.idempotencyKey)).count == 3)

    #expect(requests[0].url.path == "/api/v1/objects")
    #expect(requests[0].contentType == "application/x-elf")
    #expect(requests[0].contentSHA256 == firmwareSHA256)
    #expect(requests[0].body == firmwareBytes)
    #expect(requests[1].url.path == "/api/v1/bundles")
    #expect(requests[2].url.path == "/api/v1/jobs")

    let jobJSON = try #require(
        try JSONSerialization.jsonObject(with: requests[2].body ?? Data())
            as? [String: Any]
    )
    #expect(jobJSON["executionPolicy"] as? String == "fair")
    #expect(jobJSON["profileID"] as? String == profileID.uuidString)
    #expect(jobJSON["poolID"] as? String == poolID.uuidString)
    #expect(jobJSON["requiredCapabilities"] as? [String] == ["cmsis-dap", "rtt"])
    let capturePolicy = try #require(jobJSON["capturePolicy"] as? [String: Any])
    #expect(capturePolicy["hardDeadlineSeconds"] as? Int == 6)
    let encodedMarker = try #require(
        capturePolicy["endMarkerBase64"] as? String
    )
    #expect(
        Data(base64Encoded: encodedMarker)
            == Data(DeviceProtocol.captureEndMarker.utf8)
    )
    let workItems = try #require(jobJSON["workItems"] as? [[String: Any]])
    #expect(workItems.count == 1)

    #expect(
        requests[7].url.path
            == "/api/v1/jobs/\(jobID.uuidString.lowercased())/export"
    )
    #expect(
        requests[8].url.path
            == "/api/v1/jobs/\(jobID.uuidString.lowercased())/attempts/"
                + "\(attemptID.uuidString.lowercased())/streams/"
                + streamID.uuidString.lowercased()
    )
}

@available(macOS 12.0, *)
@Test func mutationRetries408429And5xxExactlyThreeTimes() async throws {
    let transport = ScriptedHTTPTransport([
        .response(.init(statusCode: 408)),
        .response(.init(statusCode: 429)),
        .response(.init(statusCode: 500)),
        .response(objectResponse()),
        .response(bundleResponse()),
        .response(jobResponse(state: "completed")),
        .response(exportResponse()),
        .response(.init(statusCode: 200, body: captureBytes)),
    ])
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    _ = try await client.execute(
        firmwareURL: firmwareURL,
        testName: "Retry",
        timeoutMilliseconds: 1_000
    )

    let requests = await transport.recordedRequests()
    #expect(requests.count == 8)
    let uploadAttempts = Array(requests.prefix(4))
    #expect(uploadAttempts.allSatisfy { $0.url.path == "/api/v1/objects" })
    #expect(Set(uploadAttempts.compactMap(\.idempotencyKey)).count == 1)
}

@available(macOS 12.0, *)
@Test func jobSubmissionRetriesIdempotencyInProgressConflict() async throws {
    let inProgressReason = "An equivalent request is already being processed"
    let transport = ScriptedHTTPTransport([
        .response(objectResponse()),
        .response(bundleResponse()),
        .response(.init(
            statusCode: 409,
            body: try json(["error": true, "reason": inProgressReason])
        )),
        .response(jobResponse(state: "completed")),
        .response(exportResponse()),
        .response(.init(statusCode: 200, body: captureBytes)),
    ])
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    _ = try await client.execute(
        firmwareURL: firmwareURL,
        testName: "In-progress replay",
        timeoutMilliseconds: 1_000
    )

    let requests = await transport.recordedRequests()
    let jobRequests = requests.filter { $0.url.path == "/api/v1/jobs" }
    #expect(jobRequests.count == 2)
    #expect(Set(jobRequests.compactMap(\.idempotencyKey)).count == 1)
    #expect(jobRequests[0].body == jobRequests[1].body)
}

@available(macOS 12.0, *)
@Test func jobSubmissionDoesNotRetryIndeterminateConflict() async throws {
    let indeterminateReason =
        "The earlier mutation has an indeterminate outcome; inspect resource state before using a new key"
    let transport = ScriptedHTTPTransport([
        .response(objectResponse()),
        .response(bundleResponse()),
        .response(.init(
            statusCode: 409,
            body: try json(["error": true, "reason": indeterminateReason])
        )),
    ])
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    do {
        _ = try await client.execute(
            firmwareURL: firmwareURL,
            testName: "Indeterminate",
            timeoutMilliseconds: 1_000
        )
        Issue.record("Expected an indeterminate idempotency failure")
    } catch let error as HardwareRunnerClientError {
        #expect(error == .httpFailure(
            statusCode: 409,
            reason: indeterminateReason
        ))
    }

    let requests = await transport.recordedRequests()
    #expect(requests.filter { $0.url.path == "/api/v1/jobs" }.count == 1)
}

@available(macOS 12.0, *)
@Test func jobSubmissionStopsAfterInitialAttemptPlusThreeTransientRetries() async throws {
    let transport = ScriptedHTTPTransport([
        .response(objectResponse()),
        .response(bundleResponse()),
        .response(.init(statusCode: 503)),
        .response(.init(statusCode: 503)),
        .response(.init(statusCode: 503)),
        .response(.init(statusCode: 503)),
    ])
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    do {
        _ = try await client.execute(
            firmwareURL: firmwareURL,
            testName: "Unavailable submission",
            timeoutMilliseconds: 1_000
        )
        Issue.record("Expected job submission to exhaust its retries")
    } catch let error as HardwareRunnerClientError {
        #expect(error == .httpFailure(
            statusCode: 503,
            reason: "request failed"
        ))
    }

    let requests = await transport.recordedRequests()
    let jobRequests = requests.filter { $0.url.path == "/api/v1/jobs" }
    #expect(jobRequests.count == 4)
    #expect(Set(jobRequests.compactMap(\.idempotencyKey)).count == 1)
    #expect(jobRequests.dropFirst().allSatisfy {
        $0.body == jobRequests.first?.body
    })
}

@available(macOS 12.0, *)
@Test func transportFailureStopsAfterInitialAttemptPlusThreeRetries() async throws {
    let transport = ScriptedHTTPTransport([
        .failure(.network("network error mentioning \(testToken)")),
        .failure(.network("network error mentioning \(testToken)")),
        .failure(.network("network error mentioning \(testToken)")),
        .failure(.network("network error mentioning \(testToken)")),
    ])
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    do {
        _ = try await client.execute(
            firmwareURL: firmwareURL,
            testName: "Offline",
            timeoutMilliseconds: 1_000
        )
        Issue.record("Expected transport failure")
    } catch let error as HardwareRunnerClientError {
        guard case .transportFailure(let attempts, let message) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(attempts == 4)
        #expect(!message.contains(testToken))
        #expect(error.description.contains("<redacted>"))
    }

    let requests = await transport.recordedRequests()
    #expect(requests.count == 4)
    #expect(Set(requests.compactMap(\.idempotencyKey)).count == 1)
}

@available(macOS 12.0, *)
@Test func permanent4xxIsNotRetried() async throws {
    let transport = ScriptedHTTPTransport([
        .response(.init(
            statusCode: 422,
            body: try json(["error": true, "reason": "profile is incompatible"])
        ))
    ])
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    do {
        _ = try await client.execute(
            firmwareURL: firmwareURL,
            testName: "Permanent",
            timeoutMilliseconds: 1_000
        )
        Issue.record("Expected HTTP failure")
    } catch let error as HardwareRunnerClientError {
        #expect(error == .httpFailure(
            statusCode: 422,
            reason: "profile is incompatible"
        ))
    }
    #expect(await transport.recordedRequests().count == 1)
}

@available(macOS 12.0, *)
@Test func failedAttemptIsReportedAsInfrastructureFailure() async throws {
    let transport = ScriptedHTTPTransport(
        successfulPrelude()
            + [
                .response(exportResponse(
                    attemptState: "programFailed",
                    outcomeDetail: "probe unavailable",
                    streams: []
                ))
            ]
    )
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    do {
        _ = try await client.execute(
            firmwareURL: firmwareURL,
            testName: "Infrastructure",
            timeoutMilliseconds: 1_000
        )
        Issue.record("Expected infrastructure failure")
    } catch let error as HardwareRunnerClientError {
        #expect(error == .infrastructureFailure(
            state: "programFailed",
            detail: "cpico-single: probe unavailable"
        ))
    }
}

@available(macOS 12.0, *)
@Test func latestAttemptPreservesExportOrderWhenWireTimestampsTie() async throws {
    let tiedTimestamp = "2026-07-30T10:00:02Z"
    let earlierAttempt: [String: Any] = [
        "id": earlierAttemptID.uuidString,
        "itemID": itemID.uuidString,
        "state": "programFailed",
        "startedAt": tiedTimestamp,
        "finishedAt": tiedTimestamp,
        "programExitCode": 1,
        "outcomeDetail": "first attempt failed",
        "streams": [],
    ]
    let laterAttempt: [String: Any] = [
        "id": laterAttemptID.uuidString,
        "itemID": itemID.uuidString,
        "state": "captureCompleted",
        "startedAt": tiedTimestamp,
        "finishedAt": tiedTimestamp,
        "programExitCode": 0,
        "verifyExitCode": 0,
        "streams": [
            journalStream(),
            captureStream(forAttemptID: laterAttemptID),
        ],
    ]
    let transport = ScriptedHTTPTransport(
        successfulPrelude() + [
            .response(exportResponse(attempts: [
                earlierAttempt,
                laterAttempt,
            ])),
            .response(.init(statusCode: 200, body: captureBytes)),
        ]
    )
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    let result = try await client.execute(
        firmwareURL: firmwareURL,
        testName: "Retry ordering",
        timeoutMilliseconds: 1_000
    )

    #expect(result.attemptID == laterAttemptID)
    #expect(result.rawOutput == captureBytes)
}

@available(macOS 12.0, *)
@Test func truncatedCaptureIsRejectedWithoutDownloadingIt() async throws {
    let stream = captureStream(truncated: true)
    let transport = ScriptedHTTPTransport(
        successfulPrelude() + [
            .response(exportResponse(streams: [journalStream(), stream]))
        ]
    )
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    do {
        _ = try await client.execute(
            firmwareURL: firmwareURL,
            testName: "Truncated",
            timeoutMilliseconds: 1_000
        )
        Issue.record("Expected truncated stream failure")
    } catch let error as HardwareRunnerClientError {
        #expect(error == .truncatedCaptureStream("rtt"))
    }
    #expect(await transport.recordedRequests().count == 4)
}

@available(macOS 12.0, *)
@Test func captureManifestSizeMismatchIsRejected() async throws {
    let stream = captureStream(
        byteSize: Int64(captureBytes.count),
        totalByteCount: Int64(captureBytes.count + 1)
    )
    let transport = ScriptedHTTPTransport(
        successfulPrelude() + [
            .response(exportResponse(streams: [stream]))
        ]
    )
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    do {
        _ = try await client.execute(
            firmwareURL: firmwareURL,
            testName: "Size",
            timeoutMilliseconds: 1_000
        )
        Issue.record("Expected size mismatch")
    } catch let error as HardwareRunnerClientError {
        #expect(error == .captureSizeMismatch(
            expected: Int64(captureBytes.count),
            actual: Int64(captureBytes.count + 1)
        ))
    }
}

@available(macOS 12.0, *)
@Test func downloadedCaptureSizeMismatchIsRejected() async throws {
    let transport = ScriptedHTTPTransport(
        successfulPrelude() + [
            .response(exportResponse()),
            .response(.init(statusCode: 200, body: Data("wrong".utf8))),
        ]
    )
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    do {
        _ = try await client.execute(
            firmwareURL: firmwareURL,
            testName: "Download size",
            timeoutMilliseconds: 1_000
        )
        Issue.record("Expected downloaded size mismatch")
    } catch let error as HardwareRunnerClientError {
        #expect(error == .captureSizeMismatch(
            expected: Int64(captureBytes.count),
            actual: 5
        ))
    }
}

@available(macOS 12.0, *)
@Test func downloadedCaptureDigestMismatchIsRejected() async throws {
    let sameSizeWrongBytes = Data(repeating: 0, count: captureBytes.count)
    let transport = ScriptedHTTPTransport(
        successfulPrelude() + [
            .response(exportResponse()),
            .response(.init(statusCode: 200, body: sameSizeWrongBytes)),
        ]
    )
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    do {
        _ = try await client.execute(
            firmwareURL: firmwareURL,
            testName: "Digest",
            timeoutMilliseconds: 1_000
        )
        Issue.record("Expected digest mismatch")
    } catch let error as HardwareRunnerClientError {
        guard case .captureDigestMismatch(let expected, let actual) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(expected == captureSHA256)
        #expect(actual != expected)
    }
}

@available(macOS 12.0, *)
@Test func reservedInfrastructureStreamsAreNeverUsedAsTestOutput() async throws {
    let transport = ScriptedHTTPTransport(
        successfulPrelude() + [
            .response(exportResponse(streams: [journalStream()]))
        ]
    )
    let (client, firmwareURL) = try makeClient(transport: transport)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }

    do {
        _ = try await client.execute(
            firmwareURL: firmwareURL,
            testName: "No RTT",
            timeoutMilliseconds: 1_000
        )
        Issue.record("Expected missing capture stream")
    } catch let error as HardwareRunnerClientError {
        #expect(error == .missingCaptureStream("rtt"))
    }
}

@available(macOS 12.0, *)
@Test func batchUsesOneFairJobDeduplicatesArtifactsAndPreservesCallerOrder()
    async throws
{
    let secondBundleID = UUID(
        uuidString: "33333333-3333-3333-3333-333333333334"
    )!
    let firstItemID = UUID(
        uuidString: "55555555-5555-5555-5555-555555555551"
    )!
    let secondItemID = UUID(
        uuidString: "55555555-5555-5555-5555-555555555552"
    )!
    let thirdItemID = UUID(
        uuidString: "55555555-5555-5555-5555-555555555553"
    )!
    let firstAttemptID = UUID(
        uuidString: "66666666-6666-6666-6666-666666666661"
    )!
    let secondAttemptID = UUID(
        uuidString: "66666666-6666-6666-6666-666666666662"
    )!
    let thirdAttemptID = UUID(
        uuidString: "66666666-6666-6666-6666-666666666663"
    )!
    let firstStreamID = UUID(
        uuidString: "77777777-7777-7777-7777-777777777771"
    )!
    let secondStreamID = UUID(
        uuidString: "77777777-7777-7777-7777-777777777772"
    )!
    let thirdStreamID = UUID(
        uuidString: "77777777-7777-7777-7777-777777777773"
    )!

    func stream(
        id: UUID,
        attemptID: UUID,
        bytes: Data,
        digest: String
    ) -> [String: Any] {
        [
            "id": id.uuidString,
            "name": "rtt",
            "sha256": digest,
            "byteSize": bytes.count,
            "totalByteCount": bytes.count,
            "truncated": false,
            "firstByteAt": "2026-07-30T10:00:03Z",
            "lastByteAt": "2026-07-30T10:00:05Z",
            "downloadURL":
                "/api/v1/jobs/\(jobID.uuidString.lowercased())/attempts/"
                + "\(attemptID.uuidString.lowercased())/streams/"
                + id.uuidString.lowercased(),
        ]
    }

    func attempt(
        id: UUID,
        itemID: UUID,
        stream: [String: Any]
    ) -> [String: Any] {
        [
            "id": id.uuidString,
            "itemID": itemID.uuidString,
            "state": "captureCompleted",
            "startedAt": "2026-07-30T10:00:02Z",
            "finishedAt": "2026-07-30T10:00:06Z",
            "programExitCode": 0,
            "verifyExitCode": 0,
            "outcomeDetail": NSNull(),
            "streams": [stream],
        ]
    }

    let firstStream = stream(
        id: firstStreamID,
        attemptID: firstAttemptID,
        bytes: captureBytes,
        digest: captureSHA256
    )
    let secondStream = stream(
        id: secondStreamID,
        attemptID: secondAttemptID,
        bytes: secondCaptureBytes,
        digest: secondCaptureSHA256
    )
    let thirdStream = stream(
        id: thirdStreamID,
        attemptID: thirdAttemptID,
        bytes: thirdCaptureBytes,
        digest: thirdCaptureSHA256
    )
    let shuffledWorkItems: [[String: Any]] = [
        ["id": thirdItemID.uuidString, "clientItemID": "third"],
        ["id": firstItemID.uuidString, "clientItemID": "first"],
        ["id": secondItemID.uuidString, "clientItemID": "second"],
    ]
    let batchJobResponse = HardwareRunnerHTTPResponse(
        statusCode: 200,
        body: try json([
            "id": jobID.uuidString,
            "state": "completed",
            "submittedAt": "2026-07-30T10:00:00Z",
            "workItems": shuffledWorkItems,
        ])
    )
    let batchExport = HardwareRunnerHTTPResponse(
        statusCode: 200,
        body: try json([
            "attempts": [
                attempt(
                    id: secondAttemptID,
                    itemID: secondItemID,
                    stream: secondStream
                ),
                attempt(
                    id: thirdAttemptID,
                    itemID: thirdItemID,
                    stream: thirdStream
                ),
                attempt(
                    id: firstAttemptID,
                    itemID: firstItemID,
                    stream: firstStream
                ),
            ]
        ])
    )
    let transport = ScriptedHTTPTransport([
        .response(objectResponse()),
        .response(.init(
            statusCode: 201,
            body: try json(["digest": secondFirmwareSHA256])
        )),
        .response(bundleResponse()),
        .response(.init(
            statusCode: 201,
            body: try json(["id": secondBundleID.uuidString])
        )),
        .response(batchJobResponse),
        .response(batchExport),
        .response(.init(statusCode: 200, body: captureBytes)),
        .response(.init(statusCode: 200, body: secondCaptureBytes)),
        .response(.init(statusCode: 200, body: thirdCaptureBytes)),
    ])

    let firstFirmwareURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cpico-batch-first-\(UUID().uuidString).elf")
    let secondFirmwareURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cpico-batch-second-\(UUID().uuidString).elf")
    try firmwareBytes.write(to: firstFirmwareURL, options: .atomic)
    try secondFirmwareBytes.write(to: secondFirmwareURL, options: .atomic)
    defer {
        try? FileManager.default.removeItem(at: firstFirmwareURL)
        try? FileManager.default.removeItem(at: secondFirmwareURL)
    }

    let client = HardwareRunnerClient(
        configuration: try makeConfiguration(),
        transport: transport
    )
    let results = try await client.execute(inputs: [
        .init(
            callerItemID: "first",
            firmwareURL: firstFirmwareURL,
            testName: "First",
            timeoutMilliseconds: 1_000
        ),
        .init(
            callerItemID: "second",
            firmwareURL: secondFirmwareURL,
            testName: "Second",
            timeoutMilliseconds: 2_500
        ),
        .init(
            callerItemID: "third",
            firmwareURL: firstFirmwareURL,
            testName: "Third",
            timeoutMilliseconds: 1_800
        ),
    ])

    #expect(results.map(\.callerItemID) == ["first", "second", "third"])
    let executions: [HardwareRunnerExecutionResult] = results.compactMap { result in
        guard case .success(let execution) = result.outcome else {
            return nil
        }
        return execution
    }
    #expect(executions.count == 3)
    #expect(executions.map(\.rawOutput) == [
        captureBytes,
        secondCaptureBytes,
        thirdCaptureBytes,
    ])
    #expect(executions.map(\.workItemID) == [
        firstItemID,
        secondItemID,
        thirdItemID,
    ])

    let requests = await transport.recordedRequests()
    #expect(requests.count == 9)
    let uploads = requests.filter { $0.url.path == "/api/v1/objects" }
    #expect(uploads.count == 2)
    #expect(uploads.map(\.body) == [firmwareBytes, secondFirmwareBytes])
    #expect(uploads.map(\.contentSHA256) == [
        firmwareSHA256,
        secondFirmwareSHA256,
    ])
    #expect(requests.filter { $0.url.path == "/api/v1/bundles" }.count == 2)
    let jobRequests = requests.filter { $0.url.path == "/api/v1/jobs" }
    #expect(jobRequests.count == 1)

    let jobJSON = try #require(
        try JSONSerialization.jsonObject(with: jobRequests[0].body ?? Data())
            as? [String: Any]
    )
    #expect(jobJSON["executionPolicy"] as? String == "fair")
    let jobPolicy = try #require(jobJSON["capturePolicy"] as? [String: Any])
    #expect(jobPolicy["hardDeadlineSeconds"] as? Int == 3)
    let items = try #require(jobJSON["workItems"] as? [[String: Any]])
    #expect(items.count == 3)
    #expect(items.compactMap { $0["clientItemID"] as? String } == [
        "first", "second", "third",
    ])
    #expect(items.compactMap { $0["bundleID"] as? String } == [
        bundleID.uuidString,
        secondBundleID.uuidString,
        bundleID.uuidString,
    ])
    #expect(items.compactMap {
        ($0["capturePolicy"] as? [String: Any])?["hardDeadlineSeconds"] as? Int
    } == [1, 3, 2])
}

@available(macOS 12.0, *)
@Test func batchReturnsLaterEvidenceAfterEarlierItemFailure() async throws {
    let secondItemID = UUID(
        uuidString: "55555555-5555-5555-5555-555555555552"
    )!
    let secondAttemptID = UUID(
        uuidString: "66666666-6666-6666-6666-666666666662"
    )!
    let completedJob = HardwareRunnerHTTPResponse(
        statusCode: 200,
        body: try json([
            "id": jobID.uuidString,
            "state": "completed",
            "submittedAt": "2026-07-30T10:00:00Z",
            "workItems": [
                ["id": itemID.uuidString, "clientItemID": "first"],
                ["id": secondItemID.uuidString, "clientItemID": "second"],
            ],
        ])
    )
    let failedAttempt: [String: Any] = [
        "id": earlierAttemptID.uuidString,
        "itemID": itemID.uuidString,
        "state": "programFailed",
        "startedAt": "2026-07-30T10:00:02Z",
        "finishedAt": "2026-07-30T10:00:03Z",
        "programExitCode": 1,
        "outcomeDetail": "probe lost",
        "streams": [],
    ]
    let successfulAttempt: [String: Any] = [
        "id": secondAttemptID.uuidString,
        "itemID": secondItemID.uuidString,
        "state": "captureCompleted",
        "startedAt": "2026-07-30T10:00:04Z",
        "finishedAt": "2026-07-30T10:00:06Z",
        "programExitCode": 0,
        "verifyExitCode": 0,
        "outcomeDetail": NSNull(),
        "streams": [
            captureStream(forAttemptID: secondAttemptID)
        ],
    ]
    let completedExport = exportResponse(attempts: [
        failedAttempt,
        successfulAttempt,
    ])
    let transport = ScriptedHTTPTransport([
        .response(objectResponse()),
        .response(bundleResponse()),
        .response(completedJob),
        .response(completedExport),
        .response(.init(statusCode: 200, body: captureBytes)),
    ])
    let firmwareURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cpico-batch-partial-\(UUID().uuidString).elf")
    try firmwareBytes.write(to: firmwareURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }
    let client = HardwareRunnerClient(
        configuration: try makeConfiguration(),
        transport: transport
    )

    let results = try await client.execute(inputs: [
        .init(
            callerItemID: "first",
            firmwareURL: firmwareURL,
            testName: "First",
            timeoutMilliseconds: 1_000
        ),
        .init(
            callerItemID: "second",
            firmwareURL: firmwareURL,
            testName: "Second",
            timeoutMilliseconds: 1_000
        ),
    ])

    #expect(results.count == 2)
    #expect(results[0].callerItemID == "first")
    #expect(results[0].outcome == .failure(.infrastructureFailure(
        state: "programFailed",
        detail: "first: probe lost"
    )))
    #expect(results[1].callerItemID == "second")
    guard case .success(let laterExecution) = results[1].outcome else {
        Issue.record("Expected the later work item to return its capture")
        return
    }
    #expect(laterExecution.workItemID == secondItemID)
    #expect(laterExecution.attemptID == secondAttemptID)
    #expect(laterExecution.rawOutput == captureBytes)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 5)
    #expect(
        requests.last?.url.path
            == "/api/v1/jobs/\(jobID.uuidString.lowercased())/attempts/"
                + "\(secondAttemptID.uuidString.lowercased())/streams/"
                + streamID.uuidString.lowercased()
    )
}

@available(macOS 12.0, *)
@Test func configurationAndErrorsRedactBearerToken() throws {
    let configuration = try makeConfiguration()
    #expect(!configuration.description.contains(testToken))
    #expect(!configuration.debugDescription.contains(testToken))
    #expect(configuration.description.contains("<redacted>"))

    do {
        _ = try HardwareRunnerClientConfiguration(
            baseURL: URL(string: "http://user:\(testToken)@runner.local")!,
            token: testToken,
            profileID: profileID
        )
        Issue.record("Expected URL credentials to be rejected")
    } catch let error as HardwareRunnerClientError {
        #expect(!error.description.contains(testToken))
    }
}

@available(macOS 12.0, *)
@Test func batchRejectsDuplicateOrMissingCallerIDsInJobResponse() async throws {
    let duplicateResponse = HardwareRunnerHTTPResponse(
        statusCode: 200,
        body: try json([
            "id": jobID.uuidString,
            "state": "completed",
            "submittedAt": "2026-07-30T10:00:00Z",
            "workItems": [
                ["id": itemID.uuidString, "clientItemID": "first"],
                [
                    "id": UUID().uuidString,
                    "clientItemID": "first",
                ],
            ],
        ])
    )
    let transport = ScriptedHTTPTransport([
        .response(objectResponse()),
        .response(bundleResponse()),
        .response(duplicateResponse),
    ])
    let firmwareURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cpico-batch-ids-\(UUID().uuidString).elf")
    try firmwareBytes.write(to: firmwareURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: firmwareURL) }
    let client = HardwareRunnerClient(
        configuration: try makeConfiguration(),
        transport: transport
    )

    do {
        _ = try await client.execute(inputs: [
            .init(
                callerItemID: "first",
                firmwareURL: firmwareURL,
                testName: "First",
                timeoutMilliseconds: 1_000
            ),
            .init(
                callerItemID: "second",
                firmwareURL: firmwareURL,
                testName: "Second",
                timeoutMilliseconds: 1_000
            ),
        ])
        Issue.record("Expected caller-item attribution validation failure")
    } catch let error as HardwareRunnerClientError {
        guard case .invalidResponse(let message) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(message.contains("did not exactly match"))
    }
    #expect(await transport.recordedRequests().count == 3)
}

@available(macOS 12.0, *)
private func makeClient(
    transport: ScriptedHTTPTransport
) throws -> (HardwareRunnerClient, URL) {
    let firmwareURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cpicosdk-hardware-runner-\(UUID().uuidString).elf")
    try firmwareBytes.write(to: firmwareURL, options: .atomic)
    return (
        HardwareRunnerClient(
            configuration: try makeConfiguration(),
            transport: transport
        ),
        firmwareURL
    )
}

private func makeConfiguration() throws -> HardwareRunnerClientConfiguration {
    try HardwareRunnerClientConfiguration(
        baseURL: URL(string: "http://runner.local:8080")!,
        token: testToken,
        profileID: profileID,
        poolID: poolID,
        capabilities: ["rtt", "cmsis-dap", "rtt"],
        captureChannel: "rtt",
        pollIntervalMilliseconds: 0,
        retryBaseDelayMilliseconds: 0
    )
}

private func successfulPrelude() -> [ScriptedHTTPTransport.Step] {
    [
        .response(objectResponse()),
        .response(bundleResponse()),
        .response(jobResponse(state: "completed")),
    ]
}

private func objectResponse() -> HardwareRunnerHTTPResponse {
    .init(
        statusCode: 201,
        body: try! json(["digest": firmwareSHA256])
    )
}

private func bundleResponse() -> HardwareRunnerHTTPResponse {
    .init(
        statusCode: 201,
        body: try! json(["id": bundleID.uuidString])
    )
}

private func jobResponse(state: String) -> HardwareRunnerHTTPResponse {
    .init(
        statusCode: state == "queued" ? 202 : 200,
        body: try! json([
            "id": jobID.uuidString,
            "state": state,
            "submittedAt": "2026-07-30T10:00:00Z",
            "workItems": [[
                "id": itemID.uuidString,
                "clientItemID": "cpico-single",
            ]],
        ])
    )
}

private func exportResponse(
    attemptState: String = "captureCompleted",
    outcomeDetail: String? = nil,
    streams: [[String: Any]]? = nil
) -> HardwareRunnerHTTPResponse {
    let streamValues = streams ?? [journalStream(), captureStream()]
    var attempt: [String: Any] = [
        "id": attemptID.uuidString,
        "itemID": itemID.uuidString,
        "state": attemptState,
        "startedAt": "2026-07-30T10:00:02Z",
        "finishedAt": "2026-07-30T10:00:06Z",
        "programExitCode": 0,
        "verifyExitCode": 0,
        "streams": streamValues,
    ]
    attempt["outcomeDetail"] = outcomeDetail ?? NSNull()
    return .init(
        statusCode: 200,
        body: try! json(["attempts": [attempt]])
    )
}

private func exportResponse(
    attempts: [[String: Any]]
) -> HardwareRunnerHTTPResponse {
    .init(
        statusCode: 200,
        body: try! json(["attempts": attempts])
    )
}

private func captureStream(
    forAttemptID captureAttemptID: UUID = attemptID,
    truncated: Bool = false,
    byteSize: Int64 = Int64(captureBytes.count),
    totalByteCount: Int64 = Int64(captureBytes.count)
) -> [String: Any] {
    [
        "id": streamID.uuidString,
        "name": "rtt",
        "sha256": captureSHA256,
        "byteSize": byteSize,
        "totalByteCount": totalByteCount,
        "truncated": truncated,
        "firstByteAt": "2026-07-30T10:00:03Z",
        "lastByteAt": "2026-07-30T10:00:05Z",
        "downloadURL":
            "/api/v1/jobs/\(jobID.uuidString.lowercased())/attempts/"
            + "\(captureAttemptID.uuidString.lowercased())/streams/"
            + streamID.uuidString.lowercased(),
    ]
}

private func journalStream() -> [String: Any] {
    [
        "id": journalStreamID.uuidString,
        "name": "__hr.journal",
        "sha256": String(repeating: "0", count: 64),
        "byteSize": 0,
        "totalByteCount": 0,
        "truncated": false,
        "downloadURL": "/must-not-be-downloaded",
    ]
}

private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
