import Foundation
import Testing
@testable import MemoryMapReportTool

@Test func artifactStatsUsePublishedSiblingFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let elf = directory.appendingPathComponent("Example.elf")
    try Data(repeating: 0, count: 2048).write(to: elf)
    try Data(repeating: 0, count: 1024).write(to: directory.appendingPathComponent("Example.bin"))
    try Data(repeating: 0, count: 1536).write(to: directory.appendingPathComponent("Example.uf2"))
    #expect(artifactStats(elf: elf) == [
        "[CPicoSDK] Artifact stats:",
        "[CPicoSDK]   - BIN payload size: 1024 B (1.00 KiB) (BIN)",
        "[CPicoSDK]   - UF2 file size: 1536 B (1.50 KiB) (UF2)",
        "[CPicoSDK]   - Host Debug Binary Size: 2048 B (2.00 KiB) (ELF)",
    ])
    try FileManager.default.removeItem(at: directory.appendingPathComponent("Example.bin"))
    #expect(artifactStats(elf: elf).count == 3)
}

@Test func ownershipTotalsMatchReportedFlashAndStaticRAMSections() {
    let sections = [
        SectionSize(name: ".text", bytes: 100, address: 0x1000_0000),
        SectionSize(name: ".rodata", bytes: 40, address: 0x1000_0100),
        SectionSize(name: ".data", bytes: 24, address: 0x2000_0000),
        SectionSize(name: ".bss", bytes: 16, address: 0x2000_0100),
        SectionSize(name: ".heap", bytes: 32, address: 0x2000_0200),
    ]
    let allowed = Set(sections.map(\.name))
    let map = """
    .text           0x10000000       0x64
     .text          0x10000000       0x50 /project/.build/libApp.a(App.swift.o)
     .text.more
                    0x10000050       0x10 /project/CPicoSDK/Sources/CShims/foo.c.o
                    0x10000050       0x08 duplicate_symbol_that_must_not_count
    .rodata         0x10000100       0x28
     .rodata        0x10000100       0x1e /project/.build/libApp.a(App.swift.o)
     .rodata.str    0x10000100       0x1e /project/.build/libApp.a(App.swift.o)
    .data           0x20000000       0x18
     .data          0x20000000       0x10 /project/.build/libApp.a(App.swift.o)
    .bss            0x20000100       0x10
     .bss           0x20000100       0x10 /project/CPicoSDK/Sources/ConcurrencyShims.c.o
    .debug_info     0x00000000       0xffff
     .debug_info    0x00000000       0xffff /project/.build/libApp.a(App.swift.o)
    """

    let parsed = parseMapContent(map, allowedOutputSections: allowed, productName: "App", cpicoSDKPath: "/project/CPicoSDK")
    let reconciled = reconcileOwnershipTotals(parsed, sections: sections)

    let flashSections = sections
        .filter { memoryKind(address: $0.address, section: $0.name) == .flash }
        .map(\.bytes)
        .reduce(UInt64(0), +)
    let staticRAMSections = sections
        .filter { memoryKind(address: $0.address, section: $0.name) == .ram && !isHeapSection($0.name) }
        .map(\.bytes)
        .reduce(UInt64(0), +)
    let flashOwnership = reconciled
        .filter { $0.kind == .flash }
        .map(\.bytes)
        .reduce(UInt64(0), +)
    let ramOwnership = reconciled
        .filter { $0.kind == .ram }
        .map(\.bytes)
        .reduce(UInt64(0), +)

    #expect(flashOwnership == flashSections)
    #expect(ramOwnership == staticRAMSections)
}

@Test func heapCapacityIncludesReservedHeapSection() {
    let sections = [
        SectionSize(name: ".data", bytes: 0x100, address: 0x2000_0000),
        SectionSize(name: ".bss", bytes: 0x100, address: 0x2000_0100),
        SectionSize(name: ".heap", bytes: 0x800, address: 0x2000_0200),
    ]
    let symbols = [
        Symbol(name: "__end__", value: 0x2000_0200),
        Symbol(name: "__HeapLimit", value: 0x2008_0000),
    ]

    let staticRAMSections = sections
        .filter { memoryKind(address: $0.address, section: $0.name) == .ram && !isHeapSection($0.name) }
        .map(\.bytes)
        .reduce(UInt64(0), +)

    #expect(staticRAMSections == 0x200)
    #expect(heapCapacity(symbols: symbols) == 0x7fe00)
}
