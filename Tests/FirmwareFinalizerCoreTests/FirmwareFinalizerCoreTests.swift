import Foundation
import Testing
@testable import FirmwareFinalizerCore

@Suite("Firmware finalizer request and policy")
struct FirmwareFinalizerCoreTests {
    @Test("request encoding is stable and round trips")
    func requestRoundTrip() throws {
        let request = makeRequest(
            resources: [
                .init(name: "sample.codeasset", path: "/tmp/sample.codeasset")
            ]
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(FirmwareFinalizationRequest.self, from: data)

        #expect(decoded.productName == "Example")
        #expect(decoded.schemaVersion == FirmwareFinalizationRequest.currentSchemaVersion)
        #expect(decoded.productArchivePath == "/tmp/libExample.a")
        #expect(decoded.nativeSupportArchivePath == "/tmp/libNative.a")
        #expect(decoded.embeddedResources == request.embeddedResources)
        #expect(decoded.environment["BOARD"] == "pico2")
    }

    @Test("combination variables override globals and remain allowlisted")
    func combinationEnvironment() throws {
        let environment = FinalizationEnvironment(variables: [
            "RELEVANT_ENV_VARS": "BOARD,IMPORTED_LIBS,IMPORTED_LIBS_MORE",
            "BOARD": "pico2",
            "IMPORTED_LIBS": "pico_stdlib,hardware_gpio",
            "IMPORTED_LIBS_MORE": "",
            "CPICOSDK_pico_BOARD": "pico",
            "CPICOSDK_pico_IMPORTED_LIBS_MORE": "pico_multicore",
            "SECRET_NOT_ALLOWLISTED": "do-not-forward",
        ])

        let combined = try environment.combinedVariables(for: "pico")
        #expect(combined["BOARD"] == "pico")
        #expect(combined["SECRET_NOT_ALLOWLISTED"] == nil)
        #expect(
            try environment.importedLibraries(combination: "pico")
                == ["pico_stdlib", "hardware_gpio", "pico_multicore"]
        )
    }

    @Test("embedded resource arguments are sorted and validated")
    func embeddedResourceArguments() throws {
        let resources: [FirmwareFinalizationRequest.EmbeddedResource] = [
            .init(name: "z.codeasset", path: "/tmp/z.codeasset"),
            .init(name: "a.codeasset", path: "/tmp/a.codeasset"),
        ]
        let finalizer = FirmwareFinalizer(
            request: makeRequest(resources: resources)
        )

        let arguments = try finalizer.makeEmbeddedResourceCMakeArguments(resources)
        #expect(
            arguments == [
                "-DCPICOSDK_EMBEDDED_RESOURCE_NAMES=a.codeasset;z.codeasset",
                "-DCPICOSDK_EMBEDDED_RESOURCE_PATHS=/tmp/a.codeasset;/tmp/z.codeasset",
            ]
        )
    }

    @Test("archive discovery skips toolchain lookup when no runtime is needed")
    func noRuntimeArchiveLookup() async throws {
        let finalizer = FirmwareFinalizer(
            request: makeRequest(resources: [])
        )

        #expect(try await finalizer.getExtraSwiftArchives(from: "") == [])
    }

    private func makeRequest(
        resources: [FirmwareFinalizationRequest.EmbeddedResource]
    ) -> FirmwareFinalizationRequest {
        FirmwareFinalizationRequest(
            productName: "Example",
            productArchivePath: "/tmp/libExample.a",
            nativeSupportArchivePath: "/tmp/libNative.a",
            pioasmPackageDirectoryPath: "/tmp/pioasm",
            outputDirectoryPath: "/tmp/output",
            workingDirectoryPath: "/tmp/work",
            cmakeHarnessDirectoryPath: "/tmp/harness",
            packageDirectoryPath: "/tmp/package",
            cpicoSDKDirectoryPath: "/tmp/cpicosdk",
            memoryMapToolPath: "/tmp/memory-map-report",
            swiftBuildType: "release",
            platformTriple: "armv7em-none-none-eabi",
            embeddedResources: resources,
            incremental: false,
            environment: ["BOARD": "pico2"]
        )
    }
}
