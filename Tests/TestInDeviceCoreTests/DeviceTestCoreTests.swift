import Foundation
import Testing
@testable import TestInDeviceCore

@Test func parsesLeadingMetadataBlock() throws {
    let source = """
    //% -- test yaml
    //% name: HelloRTT
    //% timeout: 5s
    //% concurrency: false
    //% traits:
    //%   add: [StdIO_RTT, CPUMetrics]
    //% expect:
    //%   stdout:
    //%     equals: "hello\\n"
    //%   durationMs:
    //%     min: 0
    //%     max: 500
    //% -----------

    import CPicoSDK

    func hello() throws {
        print("hello")
    }
    """

    let metadata = try DeviceTestParser.parseMetadata(from: source, fallbackName: "Fallback")
    #expect(metadata.name == "HelloRTT")
    #expect(metadata.timeoutMilliseconds == 5_000)
    #expect(metadata.concurrency == false)
    #expect(metadata.traits.add == ["StdIO_RTT", "CPUMetrics"])
    #expect(metadata.expectations.stdout?.equals == "hello\n")
    #expect(metadata.expectations.duration?.maxMilliseconds == 500)
}

@Test func discoversTopLevelNoArgumentFunctions() {
    let source = """
    func first() {}
    public func second() async throws {}
        func nested() {}
    func hasArguments(_ value: Int) {}
    """

    let functions = DeviceTestParser.discoverFunctions(in: source)
    #expect(functions == [
        DeviceTestFunction(name: "first", isAsync: false, isThrowing: false),
        DeviceTestFunction(name: "second", isAsync: true, isThrowing: true),
    ])
}

@Test func resolvesTraitsWithRTTDefaultAndOverrides() {
    let defaultTraits = TraitSelection(add: [], remove: []).resolvedTraits()
    #expect(defaultTraits.contains("StdIO_RTT"))

    let uartTraits = TraitSelection(add: ["StdIO_UART"], remove: []).resolvedTraits()
    #expect(uartTraits.contains("StdIO_UART"))
    #expect(!uartTraits.contains("StdIO_RTT"))

    let removedThenForced = TraitSelection(add: [], remove: ["StdIO_RTT"]).resolvedTraits()
    #expect(removedThenForced.contains("StdIO_RTT"))
}

@Test func generatesPackageWithConcurrencyDependencyOnlyWhenRequested() throws {
    let metadata = DeviceTestMetadata(name: "Async", concurrency: true)
    let source = DeviceTestSource(
        fileURL: URL(fileURLWithPath: "/tmp/Async.swift"),
        source: "func asyncTest() async throws {}",
        metadata: metadata,
        functions: [DeviceTestFunction(name: "asyncTest", isAsync: true, isThrowing: true)]
    )

    let manifest = DevicePackageGenerator.packageManifest(for: source, cpicoSDKPath: URL(fileURLWithPath: "/repo/CPicoSDK"))
    #expect(manifest.contains(".product(name: \"CPicoConcurrency\""))
    #expect(manifest.contains("path: \"/repo/CPicoSDK\""))

    let runner = DevicePackageGenerator.runnerSource(for: source)
    #expect(runner.contains("EmbeddedAsyncApp"))
    #expect(runner.contains("try await asyncTest()"))
}

@Test func asyncFunctionsAutomaticallySelectConcurrency() throws {
    let source = """
    //% -- test yaml
    //% name: MixedAsync
    //% timeout: 5s
    //% -----------

    import CPicoSDK
    import CPicoConcurrency

    func asyncTest() async throws {}
    func syncTest() {}
    """

    let tempURL = URL(fileURLWithPath: "/tmp/MixedAsync.swift")
    let loaded = try DeviceTestParser.load(source: source, fileURL: tempURL)
    #expect(loaded.metadata.concurrency)

    let manifest = DevicePackageGenerator.packageManifest(for: loaded, cpicoSDKPath: URL(fileURLWithPath: "/repo/CPicoSDK"))
    #expect(manifest.contains(".product(name: \"CPicoConcurrency\""))

    let runner = DevicePackageGenerator.runnerSource(for: loaded)
    #expect(runner.contains("try await asyncTest()"))
    #expect(runner.contains("syncTest()"))
}

@Test func normalizesStdoutAndParsesProtocolMarkers() {
    let raw = """
    __CPICOSDK_DEVICE_TEST__|run-start|name=Hello\r
    hello\r
    __CPICOSDK_DEVICE_TEST__|test-end|name=hello|status=passed|durationMs=1\r
    __CPICOSDK_DEVICE_TEST__|run-end|status=passed|durationMs=2\r
    """

    let transcript = DeviceResultParser.parse(raw)
    #expect(transcript.sawRunEnd)
    #expect(transcript.runPassed)
    #expect(transcript.durationMilliseconds == 2)
    #expect(transcript.stdout == "hello\n")
}

@Test func waitsForCompleteRunEndAndParsesEmbeddedMarkers() {
    let partial = "first__CPICOSDK_DEVICE_TEST__|run-end|status=passed"
    #expect(!DeviceResultParser.parse(partial).sawRunEnd)

    let raw = """
    first__CPICOSDK_DEVICE_TEST__|test-end|name=firstFunction|status=passed|durationMs=0
    second
    __CPICOSDK_DEVICE_TEST__|test-end|name=secondFunction|status=passed|durationMs=1
    __CPICOSDK_DEVICE_TEST__|run-end|status=passed|durationMs=27
    """
    let transcript = DeviceResultParser.parse(raw)
    #expect(transcript.sawRunEnd)
    #expect(transcript.runPassed)
    #expect(transcript.durationMilliseconds == 27)
    #expect(transcript.functionDurations == [
        DeviceFunctionDuration(name: "firstFunction", durationMilliseconds: 0),
        DeviceFunctionDuration(name: "secondFunction", durationMilliseconds: 1),
    ])
    #expect(transcript.stdout.contains("first"))
    #expect(transcript.stdout.contains("second"))
}

@Test func evaluatesStdoutAndDurationExpectations() {
    let transcript = DeviceTranscript(
        events: [DeviceProtocolEvent(name: "run-end", fields: ["status": "passed", "durationMs": "10"])],
        stdout: "hello\n",
        sawRunEnd: true,
        runPassed: true,
        durationMilliseconds: 10
    )

    let expectations = DeviceExpectations(
        stdout: StdoutExpectation(equals: "hello\n"),
        duration: DurationExpectation(minMilliseconds: 0, maxMilliseconds: 20)
    )
    #expect(DeviceResultParser.evaluate(transcript: transcript, expectations: expectations).passed)

    let mismatch = DeviceExpectations(stdout: StdoutExpectation(contains: "goodbye"))
    let failure = DeviceResultParser.evaluate(transcript: transcript, expectations: mismatch)
    #expect(!failure.passed)
    #expect(failure.reason?.contains("stdout did not contain") == true)
}

@Test func buildsOpenOCDArgumentsForRTT() {
    let args = OpenOCDCommandBuilder.arguments(
        paths: OpenOCDPaths(
            executable: URL(fileURLWithPath: "/tools/openocd.exe"),
            scriptsDirectory: URL(fileURLWithPath: "/tools/scripts"),
            helpersScript: URL(fileURLWithPath: "/helpers/openocd-helpers.tcl")
        ),
        elfURL: URL(fileURLWithPath: "/tmp/DeviceTestApp.elf"),
        ports: OpenOCDPorts(gdb: 1, tcl: 2, telnet: 3, rtt: 4),
        adapterSpeed: 1000
    )

    #expect(args.contains("adapter speed 1000"))
    #expect(args.contains("program /tmp/DeviceTestApp.elf verify"))
    #expect(args.contains("reset run"))
    #expect(args.contains("rtt server start 4 0"))
    #expect(args.contains("/helpers/openocd-helpers.tcl"))
}
