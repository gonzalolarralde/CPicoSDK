import Foundation

struct InputFingerprintStamp: Codable {
    static let currentSchemaVersion = 1
    static let fileName = ".cpicosdk-input-fingerprint.json"

    let schemaVersion: Int
    let algorithm: String
    let digest: String
}

struct InputFingerprintBuilder {
    private var hasher = SHA256Hasher()
    private let fileManager = FileManager.default

    mutating func addValue(_ name: String, _ value: String) {
        addField("value", name)
        addField("contents", value)
    }

    mutating func addTemplateTree(_ root: URL) throws {
        let entries = try treeEntries(root)
        for entry in entries {
            let url = entry.url
            addField("template-path", entry.relativePath)
            if entry.isSymbolicLink {
                addField("template-type", "symlink")
                addField(
                    "template-link-target",
                    try fileManager.destinationOfSymbolicLink(atPath: url.path)
                )
            } else if entry.isDirectory {
                addField("template-type", "directory")
            } else if entry.isRegularFile {
                addField("template-type", "file")
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while true {
                    let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                    if data.isEmpty { break }
                    hasher.update(data)
                }
                hasher.update(Data([0]))
            } else {
                addField("template-type", "other")
            }
        }
    }

    /// Records filesystem metadata rather than file contents. This makes reuse
    /// checks scale with entry count instead of the payload's byte size while
    /// still detecting additions, removals, replacements, and ordinary edits.
    mutating func addMetadataTree(_ root: URL, namespace: String) throws {
        for entry in try treeEntries(root) {
            addField("metadata-namespace", namespace)
            addField("metadata-path", entry.relativePath)
            try addMetadata(for: entry.url, entry: entry)
        }
    }

    mutating func addMetadataFile(_ url: URL, namespace: String, relativePath: String) throws {
        let entry = try treeEntry(url: url, relativePath: relativePath)
        addField("metadata-namespace", namespace)
        addField("metadata-path", relativePath)
        try addMetadata(for: url, entry: entry)
    }

    mutating func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func addMetadata(for url: URL, entry: TreeEntry) throws {
        if entry.isSymbolicLink {
            addField("metadata-type", "symlink")
            addField(
                "metadata-link-target",
                try fileManager.destinationOfSymbolicLink(atPath: url.path)
            )
            return
        }

        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        if entry.isDirectory {
            addField("metadata-type", "directory")
        } else if entry.isRegularFile {
            addField("metadata-type", "file")
        } else {
            addField("metadata-type", "other")
        }
        addField("metadata-size", String(values.fileSize ?? 0))
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        addField(
            "metadata-mtime",
            String(
                format: "%.9f",
                locale: Locale(identifier: "en_US_POSIX"),
                modified
            )
        )
    }

    private mutating func addField(_ name: String, _ value: String) {
        // Length-prefix both components so different field boundaries cannot
        // result in the same byte stream.
        hasher.update(Data("\(name.utf8.count):\(name)\(value.utf8.count):\(value)".utf8))
    }

    private struct TreeEntry {
        let url: URL
        let relativePath: String
        let isSymbolicLink: Bool
        let isDirectory: Bool
        let isRegularFile: Bool
    }

    private func treeEntries(_ root: URL) throws -> [TreeEntry] {
        var entries = [try treeEntry(url: root, relativePath: ".")]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isSymbolicLinkKey,
                .isDirectoryKey,
                .isRegularFileKey,
            ],
            options: []
        ) else {
            throw EnvironmentToolError.invalidPath(root.path)
        }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else {
                throw EnvironmentToolError.invalidPath(path)
            }
            entries.append(try treeEntry(
                url: url,
                relativePath: String(path.dropFirst(rootPath.count + 1))
            ))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private func treeEntry(url: URL, relativePath: String) throws -> TreeEntry {
        let values = try url.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isDirectoryKey,
            .isRegularFileKey,
        ])
        return TreeEntry(
            url: url,
            relativePath: relativePath,
            isSymbolicLink: values.isSymbolicLink == true,
            isDirectory: values.isDirectory == true,
            isRegularFile: values.isRegularFile == true
        )
    }
}

/// A small dependency-free SHA-256 implementation for deterministic cache
/// stamps. Keeping it local avoids making the environment bootstrap tool depend
/// on a package that itself may need the staged SDK.
private struct SHA256Hasher {
    private static let initialState: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state = initialState
    private var pending = Data()
    private var byteCount: UInt64 = 0

    mutating func update(_ data: Data) {
        byteCount &+= UInt64(data.count)
        pending.append(data)
        while pending.count >= 64 {
            process(Array(pending.prefix(64)))
            pending.removeFirst(64)
        }
    }

    mutating func finalize() -> [UInt8] {
        let bitCount = byteCount &* 8
        pending.append(0x80)
        while pending.count % 64 != 56 {
            pending.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            pending.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        while !pending.isEmpty {
            process(Array(pending.prefix(64)))
            pending.removeFirst(64)
        }
        return state.flatMap { word in
            [
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff),
            ]
        }
    }

    private mutating func process(_ block: [UInt8]) {
        var words = Array(repeating: UInt32(0), count: 64)
        for index in 0..<16 {
            let offset = index * 4
            words[index] = UInt32(block[offset]) << 24
                | UInt32(block[offset + 1]) << 16
                | UInt32(block[offset + 2]) << 8
                | UInt32(block[offset + 3])
        }
        for index in 16..<64 {
            let s0 = rotateRight(words[index - 15], by: 7)
                ^ rotateRight(words[index - 15], by: 18)
                ^ (words[index - 15] >> 3)
            let s1 = rotateRight(words[index - 2], by: 17)
                ^ rotateRight(words[index - 2], by: 19)
                ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for index in 0..<64 {
            let upperSigma1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
            let choice = (e & f) ^ ((~e) & g)
            let temporary1 = h &+ upperSigma1 &+ choice &+ Self.constants[index] &+ words[index]
            let upperSigma0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = upperSigma0 &+ majority

            h = g
            g = f
            f = e
            e = d &+ temporary1
            d = c
            c = b
            b = a
            a = temporary1 &+ temporary2
        }

        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
