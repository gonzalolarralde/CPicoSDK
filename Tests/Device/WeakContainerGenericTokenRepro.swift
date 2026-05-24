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

private func makeGenericTokenContainer<T>(_ value: sending T) -> UnsafeWeaklyTypedContainer {
    UnsafeWeaklyTypedContainer(value)
}

private func loadGenericTokenPayload(from container: UnsafeWeaklyTypedContainer) -> GenericTokenPayload? {
    container.load(as: GenericTokenPayload.self)
}
