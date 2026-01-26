struct CompiledSource: Codable {
    struct InOut: Codable {
        let pinCount: Int
        let right: Bool
        let autopush: Bool
        let threshold: Int
    }

    struct Sideset: Codable {
        let size: Int
        let optional: Bool
        let pindirs: Bool
    }

    struct Instruction: Codable {
        let hex: String
        let instruction: String
    }

    struct MovStatus: Codable {
        let type: String
        let n: Int
    }

    struct ClockDiv: Codable {
        let int: Int
        let frac: Int
    }

    struct CodeBlock: Codable {
        let lang: String
        let contents: String
    }

    struct LangOpt: Codable {
        let lang: String
        let name: String
        let value: String
    }

    struct Program: Codable {
        let name: String
        let pioVersion: Int
        let wrapTarget: Int
        let wrap: Int
        let origin: Int
        let usedGPIORanges: Int

        let publicSymbols: [String: Int32]
        let publicLabels: [String: Int32]

        let `in`: InOut?
        let out: InOut?

        let setCount: Int?
        let sideset: Sideset?
        let movStatus: MovStatus?
        let fifo: String?
        let clockDiv: ClockDiv?

        let instructions: [Instruction]

        let codeBlocks: [CodeBlock]
        let langOpts: [LangOpt]
    }

    let pioASMVersion: String
    let publicSymbols: [String: Int32]
    let programs: [Program]
}
