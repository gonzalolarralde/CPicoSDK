//% -- test yaml
//% name: WeakContainerGenericTokenRepro
//% timeout: 5s
//% concurrency: false
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   durationMs:
//%     min: 0
//%     max: 5000
//% -----------

import CPicoSDK

private struct GenericTokenPayload {
    var value: UInt32
}

private struct SameLayoutPayload {
    var value: UInt32
}

private struct OtherSameLayoutPayload {
    var value: UInt32
}

/// Goal: isolate the generic type-token mechanism used by
/// `UnsafeWeaklyTypedContainer`. The value is stored through one generic
/// function and loaded through another function, which is the shape that exposed
/// the configuration-erasure mismatch on device.
func genericWeakContainerLoadSurvivesAcrossGenericBoundaries() throws {
    let container = makeGenericTokenContainer(GenericTokenPayload(value: 0x51A7_CAFE))
    let loaded = loadGenericTokenPayload(from: container)

    print("generic-token-repro loaded=\(loaded != nil) value=\(loaded?.value ?? 0)")
    try deviceExpect(loaded?.value == 0x51A7_CAFE, "generic weak container failed to reload the same payload type")
}

/// Goal: validate that the same concrete type gets a stable token across
/// independent generic containers and generic load call sites.
func genericWeakContainerTokenIsStableForSameType() throws {
    let first = makeGenericTokenContainer(GenericTokenPayload(value: 0x1111_2222))
    let second = makeGenericTokenContainer(GenericTokenPayload(value: 0x3333_4444))

    let firstLoaded = loadGenericTokenPayload(from: first)
    let secondLoaded = loadGenericTokenPayload(from: second)

    print("generic-token-stable first=\(firstLoaded?.value ?? 0) second=\(secondLoaded?.value ?? 0)")
    try deviceExpect(firstLoaded?.value == 0x1111_2222, "first same-type generic container did not reload")
    try deviceExpect(secondLoaded?.value == 0x3333_4444, "second same-type generic container did not reload")
}

/// Goal: validate that different concrete types cannot match just because their
/// memory layout is identical. `SameLayoutPayload` and `OtherSameLayoutPayload`
/// both contain one `UInt32`; loading one as the other must fail.
func genericWeakContainerRejectsDifferentTypeWithSameLayout() throws {
    let container = makeGenericTokenContainer(SameLayoutPayload(value: 0xABCD_EF01))
    let same = container.load(as: SameLayoutPayload.self)
    let other = container.load(as: OtherSameLayoutPayload.self)
    let integer = container.load(as: UInt32.self)

    print("generic-token-different same=\(same?.value ?? 0) other=\(other?.value ?? 0) integer=\(integer ?? 0)")
    try deviceExpect(same?.value == 0xABCD_EF01, "same-layout source type did not reload")
    try deviceExpect(other == nil, "different same-layout payload type incorrectly matched")
    try deviceExpect(integer == nil, "raw UInt32 incorrectly matched same-layout payload type")
}

private func makeGenericTokenContainer<T>(_ value: sending T) -> UnsafeWeaklyTypedContainer {
    UnsafeWeaklyTypedContainer(value)
}

private func loadGenericTokenPayload(from container: UnsafeWeaklyTypedContainer) -> GenericTokenPayload? {
    container.load(as: GenericTokenPayload.self)
}
