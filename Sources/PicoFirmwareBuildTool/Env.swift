import Foundation

// Explicit configuration for build plugins; process exports remain the legacy adapter.
struct Env: Sendable {
    let variables: [String: String]

    init(variables: [String: String] = ProcessInfo.processInfo.environment) {
        self.variables = variables
    }
    
    func value(_ name: String, combination: String? = nil) -> String? {
        if let combination, let specialized = variables["CPICOSDK_\(combination)_\(name)"] {
            specialized
        } else if let global = variables[name] {
            global
        } else {
            nil
        }
    }
    
    func combinedVars(for combination: String) throws -> [String: String] {
        let relevantEnvVars = Set(try value("RELEVANT_ENV_VARS", combination: combination)
            .expected
            .split(separator: ",")
            .map(String.init))

        let allVars = variables
        let prefix = "CPICOSDK_\(combination)_"
        
        let globalizedSpecializations = allVars
            .filter { $0.key.starts(with: prefix) }
            .map { key, value in (String(key[key.index(key.startIndex, offsetBy: prefix.count)...]), value) }
        
        return allVars
            .merging(globalizedSpecializations, uniquingKeysWith: { _, new in new })
            .filter { relevantEnvVars.contains($0.key) }
    }
}
