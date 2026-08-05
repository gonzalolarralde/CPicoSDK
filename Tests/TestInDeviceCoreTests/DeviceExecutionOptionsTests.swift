import Foundation
import Testing
@testable import TestInDeviceCore

private let malformedRemoteEnvironment = [
    "HARDWARE_RUNNER_URL": "not a URL",
    "HARDWARE_RUNNER_PROFILE_ID": "not-a-uuid",
    "HARDWARE_RUNNER_POOL_ID": "also-not-a-uuid",
    "HARDWARE_RUNNER_CAPTURE_CHANNEL": "",
]

@Test func deviceExecutionDefaultsToLocalAndIgnoresRemoteEnvironment() throws {
    let options = try DeviceExecutionOptionsResolver.resolve(
        environment: malformedRemoteEnvironment,
        overrides: DeviceExecutionOverrides(),
        target: .rp2350,
        performsPhysicalRun: true
    )

    #expect(options.mode == .local)
    #expect(options.hardwareRunnerURL == nil)
    #expect(options.hardwareRunnerToken == nil)
    #expect(options.hardwareRunnerProfileID == nil)
    #expect(options.hardwareRunnerPoolID == nil)
    #expect(options.hardwareRunnerCapabilities.isEmpty)
    #expect(options.hardwareRunnerCaptureChannel == "rtt")
}

@Test func explicitLocalModeOverridesInvalidEnvironmentMode() throws {
    var environment = malformedRemoteEnvironment
    environment["CPICOSDK_DEVICE_TEST_EXECUTION"] = "not-a-mode"

    let options = try DeviceExecutionOptionsResolver.resolve(
        environment: environment,
        overrides: DeviceExecutionOverrides(mode: "local"),
        target: .rp2350,
        performsPhysicalRun: true
    )

    #expect(options.mode == .local)
    #expect(options.hardwareRunnerURL == nil)
}

@Test func listAndBuildOnlyRemoteSelectionsIgnoreRemoteConfiguration() throws {
    var environment = malformedRemoteEnvironment
    environment["CPICOSDK_DEVICE_TEST_EXECUTION"] = "remote"

    let listOptions = try DeviceExecutionOptionsResolver.resolve(
        environment: environment,
        overrides: DeviceExecutionOverrides(),
        target: .rp2350,
        performsPhysicalRun: false
    )
    let buildOnlyOptions = try DeviceExecutionOptionsResolver.resolve(
        environment: environment,
        overrides: DeviceExecutionOverrides(mode: "remote"),
        target: .rp2040,
        performsPhysicalRun: false
    )

    #expect(listOptions.mode == .remote)
    #expect(listOptions.hardwareRunnerURL == nil)
    #expect(buildOnlyOptions.mode == .remote)
    #expect(buildOnlyOptions.hardwareRunnerProfileID == nil)
}

@Test func physicalRemoteExecutionValidatesAndResolvesConfiguration() throws {
    let profileID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let poolID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    let environment = [
        "HARDWARE_RUNNER_URL": "   ",
        "CPICOSDK_HARDWARE_RUNNER_URL": "https://runner.example/base",
        "HARDWARE_RUNNER_TOKEN": "token",
        "HARDWARE_RUNNER_PROFILE_ID": "   ",
        "CPICOSDK_HARDWARE_RUNNER_PROFILE_ID": profileID.uuidString,
        "HARDWARE_RUNNER_POOL_ID": "   ",
        "CPICOSDK_HARDWARE_RUNNER_POOL_ID": poolID.uuidString,
        "HARDWARE_RUNNER_CAPABILITIES": "RP2350, CMSIS-DAP, rtt",
        "HARDWARE_RUNNER_CAPTURE_CHANNEL": "rtt",
    ]

    let options = try DeviceExecutionOptionsResolver.resolve(
        environment: environment,
        overrides: DeviceExecutionOverrides(mode: "remote"),
        target: .rp2350,
        performsPhysicalRun: true
    )

    #expect(options.mode == .remote)
    #expect(options.hardwareRunnerURL?.absoluteString == "https://runner.example/base")
    #expect(options.hardwareRunnerToken == "token")
    #expect(options.hardwareRunnerProfileID == profileID)
    #expect(options.hardwareRunnerPoolID == poolID)
    #expect(options.hardwareRunnerCapabilities == ["rp2350", "cmsis-dap", "rtt"])
    #expect(options.hardwareRunnerCaptureChannel == "rtt")
}

@Test func physicalRemoteExecutionRejectsMalformedConfiguration() {
    do {
        _ = try DeviceExecutionOptionsResolver.resolve(
            environment: malformedRemoteEnvironment,
            overrides: DeviceExecutionOverrides(mode: "remote"),
            target: .rp2350,
            performsPhysicalRun: true
        )
        Issue.record("Expected malformed HardwareRunner URL to be rejected")
    } catch let error as DeviceTestHarnessError {
        #expect(error == .invalidMetadata(
            "HARDWARE_RUNNER_URL/--hardware-runner-url must be an absolute HTTP or HTTPS URL"
        ))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
