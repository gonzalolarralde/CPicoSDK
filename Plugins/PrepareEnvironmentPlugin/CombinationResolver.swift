import Foundation
import PackagePlugin

extension PrepareEnvironmentPlugin {
    private struct ConsumerBuildConfiguration: Decodable {
        let combination: String?
        let environment: [String: String]?
    }

    func resolveSelectedCombination(
        givenEnvVars: [String: String],
        packageEnv: Env,
        context: PackagePlugin.PluginContext
    ) -> String {
        if let selectedCombination = givenEnvVars["CPICOSDK_COMBINATION"] {
            guard packageEnv.combinations[selectedCombination] != nil else {
                let available = packageEnv.combinations.keys.sorted().joined(separator: ", ")
                fatalError("[CPicoSDK] Unknown CPICOSDK_COMBINATION '\(selectedCombination)'. Available combinations: \(available)")
            }

            print("[CPicoSDK] Using provided CPICOSDK_COMBINATION: \(selectedCombination)")
            return selectedCombination
        }

        if let selectedBoard = givenEnvVars["BOARD"] {
            guard packageEnv.combinations[selectedBoard] != nil else {
                let available = packageEnv.combinations.keys.sorted().joined(separator: ", ")
                fatalError("[CPicoSDK] Unknown BOARD '\(selectedBoard)'. Available combinations: \(available)")
            }

            print("[CPicoSDK] Using provided BOARD as combination: \(selectedBoard)")
            return selectedBoard
        }

        if let configuredCombination = self.configuredCombination(
            givenEnvVars: givenEnvVars,
            context: context
        ) {
            guard packageEnv.combinations[configuredCombination] != nil else {
                let available = packageEnv.combinations.keys.sorted().joined(separator: ", ")
                fatalError("[CPicoSDK] Unknown combination '\(configuredCombination)' in CPICOSDK_BUILD_CONFIGURATION. Available combinations: \(available)")
            }
            print("[CPicoSDK] Using combination from consumer build configuration: \(configuredCombination)")
            return configuredCombination
        }

        return self.resolveDefaultCombination(packageEnv: packageEnv)
    }

    private func configuredCombination(
        givenEnvVars: [String: String],
        context: PackagePlugin.PluginContext
    ) -> String? {
        let configuredPath = givenEnvVars["CPICOSDK_BUILD_CONFIGURATION"]
            ?? ProcessInfo.processInfo.environment["CPICOSDK_BUILD_CONFIGURATION"]
        guard let configuredPath, !configuredPath.isEmpty else {
            return nil
        }
        let url = configuredPath.hasPrefix("/")
            ? URL(fileURLWithPath: configuredPath)
            : context.package.directoryURL.appending(path: configuredPath)
        do {
            return try JSONDecoder().decode(
                ConsumerBuildConfiguration.self,
                from: Data(contentsOf: url)
            ).combination
        } catch {
            fatalError("[CPicoSDK] Couldn't read CPICOSDK_BUILD_CONFIGURATION at \(url.path): \(error)")
        }
    }

    func configuredEnvironment(
        givenEnvVars: [String: String],
        context: PackagePlugin.PluginContext
    ) -> [String: String] {
        let configuredPath = givenEnvVars["CPICOSDK_BUILD_CONFIGURATION"]
            ?? ProcessInfo.processInfo.environment["CPICOSDK_BUILD_CONFIGURATION"]
        guard let configuredPath, !configuredPath.isEmpty else {
            return [:]
        }
        let url = configuredPath.hasPrefix("/")
            ? URL(fileURLWithPath: configuredPath)
            : context.package.directoryURL.appending(path: configuredPath)
        do {
            return try JSONDecoder().decode(
                ConsumerBuildConfiguration.self,
                from: Data(contentsOf: url)
            ).environment ?? [:]
        } catch {
            fatalError("[CPicoSDK] Couldn't read CPICOSDK_BUILD_CONFIGURATION at \(url.path): \(error)")
        }
    }

    private func resolveDefaultCombination(packageEnv: Env) -> String {
        guard let defaultCombination = packageEnv.vars["BOARD"] else {
            fatalError("[CPicoSDK] Could not find CPicoSDK dependency traits and env.json does not define a default BOARD. Set BOARD=<combination> to override.")
        }

        guard packageEnv.combinations[defaultCombination] != nil else {
            let available = packageEnv.combinations.keys.sorted().joined(separator: ", ")
            fatalError("[CPicoSDK] Default BOARD '\(defaultCombination)' is not a known combination. Available combinations: \(available)")
        }

        print("[CPicoSDK] ⚠️ \u{001B}[33mWARNING: No board was selected in cpicosdk-build.json or BOARD. Falling back to env.json BOARD: \(defaultCombination).\u{001B}[0m")
        return defaultCombination
    }
}
