import Foundation

public enum DeviceExecutionMode: String, Sendable, Equatable {
    case local
    case remote

    public init(_ value: String) throws {
        guard let mode = Self(rawValue: value.lowercased()) else {
            throw DeviceTestHarnessError.invalidMetadata(
                "unknown execution mode '\(value)'; expected local or remote"
            )
        }
        self = mode
    }
}

/// Command-line values which, when present, take precedence over environment
/// configuration. Strings remain unvalidated until the final execution mode is
/// known so local, list-only, and build-only commands ignore remote-only state.
public struct DeviceExecutionOverrides: Sendable, Equatable {
    public var mode: String?
    public var hardwareRunnerURL: String?
    public var hardwareRunnerToken: String?
    public var hardwareRunnerProfileID: String?
    public var hardwareRunnerPoolID: String?
    public var hardwareRunnerCapabilities: String?
    public var hardwareRunnerCaptureChannel: String?

    public init(
        mode: String? = nil,
        hardwareRunnerURL: String? = nil,
        hardwareRunnerToken: String? = nil,
        hardwareRunnerProfileID: String? = nil,
        hardwareRunnerPoolID: String? = nil,
        hardwareRunnerCapabilities: String? = nil,
        hardwareRunnerCaptureChannel: String? = nil
    ) {
        self.mode = mode
        self.hardwareRunnerURL = hardwareRunnerURL
        self.hardwareRunnerToken = hardwareRunnerToken
        self.hardwareRunnerProfileID = hardwareRunnerProfileID
        self.hardwareRunnerPoolID = hardwareRunnerPoolID
        self.hardwareRunnerCapabilities = hardwareRunnerCapabilities
        self.hardwareRunnerCaptureChannel = hardwareRunnerCaptureChannel
    }
}

public struct ResolvedDeviceExecutionOptions: Sendable, Equatable {
    public let mode: DeviceExecutionMode
    public let hardwareRunnerURL: URL?
    public let hardwareRunnerToken: String?
    public let hardwareRunnerProfileID: UUID?
    public let hardwareRunnerPoolID: UUID?
    public let hardwareRunnerCapabilities: [String]
    public let hardwareRunnerCaptureChannel: String
}

public enum DeviceExecutionOptionsResolver {
    public static func resolve(
        environment: [String: String],
        overrides: DeviceExecutionOverrides,
        target: DeviceTestTarget,
        performsPhysicalRun: Bool
    ) throws -> ResolvedDeviceExecutionOptions {
        // An explicit command-line mode wins even when the environment value is
        // invalid. This keeps `--local` a reliable escape hatch from stale CI
        // configuration.
        let modeValue = overrides.mode.map(trimmed)
            ?? nonEmpty(environment["CPICOSDK_DEVICE_TEST_EXECUTION"])
            ?? DeviceExecutionMode.local.rawValue
        let mode = try DeviceExecutionMode(modeValue)
        let willExecuteRemotely = mode == .remote && performsPhysicalRun

        guard willExecuteRemotely else {
            return ResolvedDeviceExecutionOptions(
                mode: mode,
                hardwareRunnerURL: nil,
                hardwareRunnerToken: nil,
                hardwareRunnerProfileID: nil,
                hardwareRunnerPoolID: nil,
                hardwareRunnerCapabilities: [],
                hardwareRunnerCaptureChannel: "rtt"
            )
        }

        let urlValue = selectedValue(
            override: overrides.hardwareRunnerURL,
            environment: environment,
            primary: "HARDWARE_RUNNER_URL",
            fallback: "CPICOSDK_HARDWARE_RUNNER_URL"
        )
        let tokenValue = selectedValue(
            override: overrides.hardwareRunnerToken,
            environment: environment,
            primary: "HARDWARE_RUNNER_TOKEN",
            fallback: "CPICOSDK_HARDWARE_RUNNER_TOKEN"
        )
        let profileValue = selectedValue(
            override: overrides.hardwareRunnerProfileID,
            environment: environment,
            primary: "HARDWARE_RUNNER_PROFILE_ID",
            fallback: "CPICOSDK_HARDWARE_RUNNER_PROFILE_ID"
        )
        let poolValue = selectedValue(
            override: overrides.hardwareRunnerPoolID,
            environment: environment,
            primary: "HARDWARE_RUNNER_POOL_ID",
            fallback: "CPICOSDK_HARDWARE_RUNNER_POOL_ID"
        )
        let capabilitiesValue = selectedValue(
            override: overrides.hardwareRunnerCapabilities,
            environment: environment,
            primary: "HARDWARE_RUNNER_CAPABILITIES",
            fallback: "CPICOSDK_HARDWARE_RUNNER_CAPABILITIES"
        )
        let captureChannelValue = selectedValue(
            override: overrides.hardwareRunnerCaptureChannel,
            environment: environment,
            primary: "HARDWARE_RUNNER_CAPTURE_CHANNEL",
            fallback: "CPICOSDK_HARDWARE_RUNNER_CAPTURE_CHANNEL"
        )

        var capabilities = commaSeparated(capabilitiesValue)
        if capabilities.isEmpty {
            capabilities = [
                target.rawValue,
                "cmsis-dap",
                "rtt",
            ]
        }
        let captureChannel = captureChannelValue ?? "rtt"
        guard !captureChannel.isEmpty else {
            throw DeviceTestHarnessError.invalidMetadata(
                "--hardware-runner-capture-channel cannot be empty"
            )
        }

        return ResolvedDeviceExecutionOptions(
            mode: mode,
            hardwareRunnerURL: try parseURL(
                urlValue,
                option: "HARDWARE_RUNNER_URL/--hardware-runner-url"
            ),
            hardwareRunnerToken: nonEmpty(tokenValue),
            hardwareRunnerProfileID: try parseUUID(
                profileValue,
                option: "HARDWARE_RUNNER_PROFILE_ID/--hardware-runner-profile-id"
            ),
            hardwareRunnerPoolID: try parseUUID(
                poolValue,
                option: "HARDWARE_RUNNER_POOL_ID/--hardware-runner-pool-id"
            ),
            hardwareRunnerCapabilities: capabilities,
            hardwareRunnerCaptureChannel: captureChannel
        )
    }

    private static func selectedValue(
        override: String?,
        environment: [String: String],
        primary: String,
        fallback: String
    ) -> String? {
        if let override {
            // Preserve an explicitly empty CLI value so validation can reject
            // it instead of silently falling back to environment configuration.
            return trimmed(override)
        }
        return nonEmpty(environment[primary]) ?? nonEmpty(environment[fallback])
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value.map(trimmed), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseURL(_ value: String?, option: String) throws -> URL? {
        guard let value = nonEmpty(value) else { return nil }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            throw DeviceTestHarnessError.invalidMetadata(
                "\(option) must be an absolute HTTP or HTTPS URL"
            )
        }
        return url
    }

    private static func parseUUID(_ value: String?, option: String) throws -> UUID? {
        guard let value = nonEmpty(value) else { return nil }
        guard let uuid = UUID(uuidString: value) else {
            throw DeviceTestHarnessError.invalidMetadata(
                "\(option) must be a UUID"
            )
        }
        return uuid
    }

    private static func commaSeparated(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
