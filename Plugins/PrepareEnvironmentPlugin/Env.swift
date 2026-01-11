import Foundation

struct Env: Codable, Hashable {
    enum Error: Swift.Error {
        case fileNotFound(String)
    }

    struct Combination: Codable, Hashable {
        let vars: [String: String]
        let traits: [String]
    }

    let vars: [String: String]
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
}
