import Foundation
import Testing
@testable import PicoBuildConfigurationCore

struct ConfigurationTests {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func request(board: String = "pico2", given: [String: String] = [:]) throws -> PreparationRequest {
        let defaults = try JSONDecoder().decode(ConfigurationDefaults.self, from: Data(contentsOf: root.appending(path: "env.json")))
        return PreparationRequest(
            defaults: defaults, given: ["HOME": "/tmp/home"].merging(given, uniquingKeysWith: { _, new in new }), board: board,
            context: ConfigurationContext(packagePath: "/tmp/project with spaces", pluginOutputPath: "/tmp/preparation", sdkPackagePath: root.path)
        )
    }

    @Test(arguments: ["pico", "pico_w", "pico2", "pico2_w", "pimoroni_pico_plus2_rp2350", "pimoroni_pico_plus2_w_rp2350"])
    func headerPreparationNeedsNoApplicationOrInstalledTools(board: String) throws {
        let input = try request(board: board)
        let result = try ConfigurationResolver.prepare(input)
        #expect(result.variables["SWIFTPM_PRODUCT"] == "")
        #expect(result.variables["BOARD"] == board)
        #expect(result.specializations.count == 6)
        for (name, combination) in input.defaults.combinations {
            let environment = result.variables.merging(result.specializations[name]!, uniquingKeysWith: { _, new in new })
            #expect(environment["BOARD"] == name)
            for (key, value) in combination.vars where !value.contains("${") {
                #expect(environment[key] == value)
            }
            #expect(!environment.values.contains { $0.contains("${") })
            #expect(environment["PICO_SDK_PATH"]?.contains("pico-sdk-bundle/sdk/") == true)
        }
    }

    @Test func explicitGlobalOverridesApplyToEveryBoard() throws {
        let input = try request(given: ["PICO_SDK_BUNDLE_PATH": "/tmp/sdk with spaces", "IMPORTED_LIBS": "pico_stdlib", "BOARD": "pico2", "NM_PATH": "${PICO_TOOLCHAIN_PATH}/bin/arm-none-eabi-nm"])
        let result = try ConfigurationResolver.prepare(input)
        for specialized in result.specializations.values {
            #expect(specialized["BOARD"] == nil)
            #expect(specialized["IMPORTED_LIBS"] == nil)
        }
        #expect(result.variables["PICO_SDK_PATH"] == "/tmp/sdk with spaces/sdk/\(input.defaults.vars["SDK_VERSION"]!)")
        #expect(result.installation.metadataInspectorPath == result.variables["PICO_TOOLCHAIN_PATH"]! + "/bin/arm-none-eabi-nm")
    }

    @Test func detectsUnresolvedAndCyclicVariables() throws {
        #expect(throws: ConfigurationError.self) { try ConfigurationResolver.expand(["A": "${MISSING}"]) }
        #expect(throws: ConfigurationError.self) { try ConfigurationResolver.expand(["A": "${B}", "B": "${A}"]) }
        #expect(try ConfigurationResolver.expand(["A": "one", "B": "${A}/two", "C": "${B}/three"])["C"] == "one/two/three")
    }

    @Test func resolvesMetadataAndExplicitStdioWithoutShellPreparation() throws {
        let input = try request()
        let installation = try ConfigurationResolver.prepare(input).installation
        let result = try ConfigurationResolver.resolveBuild(
            defaults: input.defaults, installation: installation,
            symbols: "T _cpicosdk_combination_pico2\nT _cpicosdk_trait_stdio_automatic", overrides: ["AUTO_STDIO": "uart"],
            triple: "armv7em-none-none-eabi", configuration: "Release"
        )
        #expect(result.board == "pico2")
        #expect(result.stdio == .init(uart: true, usb: false, rtt: false))
        #expect(result.variables["CPICOSDK_SWIFT_EXEC"] == installation.compilerPath)
        #expect(result.variables["OPENOCD_TARGET"] == nil)
    }

    @Test func retainsManualStdioAndDefaultAutomaticUSB() throws {
        let input = try request()
        let installation = try ConfigurationResolver.prepare(input).installation
        for automatic in [true, false] {
            let symbols = "T _cpicosdk_combination_pico2\n" + (automatic ? "T _cpicosdk_trait_stdio_automatic" : "T _cpicosdk_trait_stdio_uart\nT _cpicosdk_trait_stdio_rtt")
            let result = try ConfigurationResolver.resolveBuild(defaults: input.defaults, installation: installation, symbols: symbols, overrides: [:], triple: installation.targetTriple, configuration: "Release")
            #expect(result.stdio == .init(uart: !automatic, usb: automatic, rtt: !automatic))
        }
    }

    @Test func rejectsTripleAndCompileSettingChanges() throws {
        let input = try request()
        let installation = try ConfigurationResolver.prepare(input).installation
        for overrides in [["CPICOSDK_CORE1_STACK_SIZE_BYTES": "16384"], ["BOARD": "pico"], ["AUTO_STDIO": "invalid"]] {
            #expect(throws: ConfigurationError.self) {
                try ConfigurationResolver.resolveBuild(defaults: input.defaults, installation: installation, symbols: "T _cpicosdk_combination_pico2", overrides: overrides, triple: installation.targetTriple, configuration: "Release")
            }
        }
        #expect(throws: ConfigurationError.self) {
            try ConfigurationResolver.resolveBuild(defaults: input.defaults, installation: installation, symbols: "T _cpicosdk_combination_pico", overrides: [:], triple: installation.targetTriple, configuration: "Release")
        }
        let incompatibleInput = try request(board: "pico", given: ["SWIFTPM_TRIPLE": "armv7em-none-none-eabi"])
        let incompatibleInstallation = try ConfigurationResolver.prepare(incompatibleInput).installation
        #expect(throws: ConfigurationError.self) {
            try ConfigurationResolver.resolveBuild(defaults: incompatibleInput.defaults, installation: incompatibleInstallation, symbols: "T _cpicosdk_combination_pico", overrides: [:], triple: incompatibleInstallation.targetTriple, configuration: "Release")
        }
    }

    @Test func permitsNativeOnlyChangesAndDebugConfiguration() throws {
        let input = try request()
        let installation = try ConfigurationResolver.prepare(input).installation
        let result = try ConfigurationResolver.resolveBuild(defaults: input.defaults, installation: installation, symbols: "T _cpicosdk_combination_pico2", overrides: ["CPICOSDK_CORE0_STACK_SIZE_BYTES": "16384"], triple: installation.targetTriple, configuration: "Debug")
        #expect(result.variables["BUILD_TYPE"] == "Debug")
        #expect(result.variables["CPICOSDK_CORE0_STACK_SIZE_BYTES"] == "16384")
    }

    @Test func missingToolsAreDiagnosedWithoutInstallation() {
        #expect(throws: ConfigurationError.self) { try ConfigurationResolver.validateInstallation([:]) }
    }

    @Test func configurationWritesAreDeterministicAndPreserveUnchangedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "configuration.json")
        try ConfigurationResolver.writeJSON(["b": "2", "a": "1"], to: file)
        let oldDate = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        try ConfigurationResolver.writeJSON(["a": "1", "b": "2"], to: file)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == oldDate)
    }
}
