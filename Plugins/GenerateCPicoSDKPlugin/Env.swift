import Foundation

// TODO: Share this environment model with PrepareEnvironmentPlugin.

struct Env: Codable, Hashable {
    enum Error: Swift.Error {
        case fileNotFound(String)
    }

    struct Combination: Codable, Hashable {
        let traits: [String]
    }

    let combinations: [String: Combination]

    init(from file: String) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: file),
           let envsContent = fileManager.contents(atPath: file),
           let envs = try? JSONDecoder().decode(Self.self, from: envsContent)
        {
            self = envs
        } else {
            throw Error.fileNotFound(file)
        }
    }
    
    static func value(_ name: String, combination: String? = nil) -> String? {
        if let combination, let specialized = ProcessInfo.processInfo.environment["CPICOSDK_\(combination)_\(name)"] {
            specialized
        } else if let global = ProcessInfo.processInfo.environment[name] {
            global
        } else {
            nil
        }
    }
    
    static func combinedVars(for combination: String) throws -> [String: String] {
        let relevantEnvVars = Set(try Self.value("RELEVANT_ENV_VARS", combination: combination)
            .expected
            .split(separator: ",")
            .map(String.init))

        let allVars = ProcessInfo.processInfo.environment
        let prefix = "CPICOSDK_\(combination)_"
        
        let globalizedSpecializations = allVars
            .filter { $0.key.starts(with: prefix) }
            .map { key, value in (String(key[key.index(key.startIndex, offsetBy: prefix.count)...]), value) }
        
        return allVars
            .merging(globalizedSpecializations, uniquingKeysWith: { _, new in new })
            .filter { relevantEnvVars.contains($0.key) }
    }
}
