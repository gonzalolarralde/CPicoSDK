import Foundation
import PackagePlugin

extension PrepareEnvironmentPlugin {
    func resolveSelectedCombination(
        givenEnvVars: [String: String],
        packageEnv: Env,
        context: PackagePlugin.PluginContext
    ) async -> String {
        if let selectedBoard = givenEnvVars["BOARD"] {
            guard packageEnv.combinations[selectedBoard] != nil else {
                let available = packageEnv.combinations.keys.sorted().joined(separator: ", ")
                fatalError("[CPicoSDK] Unknown BOARD '\(selectedBoard)'. Available combinations: \(available)")
            }

            print("[CPicoSDK] Using provided BOARD as combination: \(selectedBoard)")
            return selectedBoard
        }

        guard let dependencyTraits = await self.resolveCPicoSDKDependencyTraits(context: context) else {
            return self.resolveDefaultCombination(packageEnv: packageEnv)
        }

        let boardTraits = Env.boardDefiningTraits(from: dependencyTraits)

        guard !boardTraits.isEmpty else {
            fatalError("[CPicoSDK] CPicoSDK dependency does not declare board-selection traits. Set BOARD=<combination> or add Platform_*, Variant_*, and Radio_* traits to the CPicoSDK dependency.")
        }

        let matches = packageEnv.combinations
            .filter { _, combination in
                Env.boardDefiningTraits(from: combination.traits).isSubset(of: boardTraits)
            }
            .map(\.key)
            .sorted()

        guard matches.count == 1, let match = matches.first else {
            if matches.isEmpty {
                fatalError("[CPicoSDK] No CPicoSDK combination matches dependency board traits: \(boardTraits.sorted().joined(separator: ", ")). Set BOARD=<combination> to override.")
            } else {
                fatalError("[CPicoSDK] Multiple CPicoSDK combinations match dependency board traits: \(matches.joined(separator: ", ")). Set BOARD=<combination> to disambiguate.")
            }
        }

        print("[CPicoSDK] Inferred CPicoSDK combination from dependency traits: \(match)")
        return match
    }

    private func resolveDefaultCombination(packageEnv: Env) -> String {
        guard let defaultCombination = packageEnv.vars["BOARD"] else {
            fatalError("[CPicoSDK] Could not find CPicoSDK dependency traits and env.json does not define a default BOARD. Set BOARD=<combination> to override.")
        }

        guard packageEnv.combinations[defaultCombination] != nil else {
            let available = packageEnv.combinations.keys.sorted().joined(separator: ", ")
            fatalError("[CPicoSDK] Default BOARD '\(defaultCombination)' is not a known combination. Available combinations: \(available)")
        }

        print("[CPicoSDK] ⚠️ \u{001B}[33mWARNING: Could not find CPicoSDK dependency traits. Falling back to default env.json BOARD: \(defaultCombination).\u{001B}[0m")
        return defaultCombination
    }

    private func resolveCPicoSDKDependencyTraits(context: PackagePlugin.PluginContext) async -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let scratchPath = context.pluginWorkDirectoryURL
            .appending(path: "dump-package-build")
            .relativePath
        process.arguments = [
            "swift",
            "package",
            "--scratch-path",
            scratchPath,
            "dump-package",
        ]
        process.currentDirectoryURL = context.package.directoryURL
        process.environment = ProcessInfo.processInfo.environment

        let status: Int32
        let outputData: Data?
        let errorData: Data?
        do {
            (status, outputData, errorData) = try await process.asyncRun(captureStdout: true, captureStderr: true)
        } catch {
            fatalError("[CPicoSDK] Failed to run 'swift package dump-package': \(error)")
        }

        guard status == 0, let outputData else {
            let stderr = errorData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            fatalError("[CPicoSDK] 'swift package dump-package' failed: \(stderr)")
        }

        do {
            let json = try JSONSerialization.jsonObject(with: outputData)
            guard
                let root = json as? [String: Any],
                let dependencies = root["dependencies"] as? [[String: Any]]
            else {
                fatalError("[CPicoSDK] Unexpected 'swift package dump-package' output.")
            }

            for dependency in dependencies {
                if let traits = self.cpicoSDKTraits(fromDumpDependency: dependency) {
                    return traits
                }
            }
        } catch {
            fatalError("[CPicoSDK] Failed to parse 'swift package dump-package' output: \(error)")
        }

        return nil
    }

    private func cpicoSDKTraits(fromDumpDependency dependency: [String: Any]) -> [String]? {
        for value in dependency.values {
            guard let packageReferences = value as? [[String: Any]] else { continue }

            for packageReference in packageReferences {
                guard self.isCPicoSDKPackageReference(packageReference) else { continue }

                guard let traitObjects = packageReference["traits"] as? [[String: Any]] else {
                    return []
                }

                return traitObjects.compactMap { $0["name"] as? String }
            }
        }

        return nil
    }

    private func isCPicoSDKPackageReference(_ packageReference: [String: Any]) -> Bool {
        if let identity = packageReference["identity"] as? String,
           identity.lowercased() == "cpicosdk"
        {
            return true
        }

        for key in ["path", "url"] {
            guard let value = packageReference[key] as? String else { continue }

            let normalized = value
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()

            if normalized.hasSuffix("/cpicosdk") || normalized == "cpicosdk" {
                return true
            }
        }

        return false
    }
}
