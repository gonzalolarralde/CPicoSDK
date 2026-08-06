import Foundation

struct FinalizationEnvironment: Sendable {
    let variables: [String: String]

    func value(_ name: String, combination: String? = nil) -> String? {
        if let combination,
           let specialized = variables["CPICOSDK_\(combination)_\(name)"]
        {
            return specialized
        }
        return variables[name]
    }

    func combinedVariables(for combination: String) throws -> [String: String] {
        let relevantVariables = Set(
            try value("RELEVANT_ENV_VARS", combination: combination)
                .expected
                .split(separator: ",")
                .map(String.init)
        )
        let prefix = "CPICOSDK_\(combination)_"
        let specializedVariables = variables
            .filter { $0.key.hasPrefix(prefix) }
            .map { key, value in
                (String(key.dropFirst(prefix.count)), value)
            }

        return variables
            .merging(specializedVariables, uniquingKeysWith: { _, specialized in specialized })
            .filter { relevantVariables.contains($0.key) }
    }

    func importedLibraries(combination: String) throws -> [String] {
        var libraries = try value("IMPORTED_LIBS", combination: combination)
            .expected
            .split(separator: ",")
            .map(String.init)
        libraries.append(
            contentsOf: try value("IMPORTED_LIBS_MORE", combination: combination)
                .expected
                .split(separator: ",")
                .compactMap(\.nonEmpty)
                .map(String.init)
        )
        return libraries
    }
}
