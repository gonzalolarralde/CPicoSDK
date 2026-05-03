/// A resource embedded into the final firmware image.
///
/// Add a `.codeasset` file to a target that uses the `AssetCompiler` plugin, and
/// the plugin generates a static accessor named after the file stem. For example,
/// `sample.codeasset` becomes `Asset.sample`.
///
/// ```swift
/// let asset = Asset.sample
///
/// print("Embedded asset bytes: \(asset.data.count)")
/// print("Embedded asset address: \(String(UInt(bitPattern: asset.data.baseAddress!), radix: 16))")
/// print("Embedded asset content: \(String(decoding: asset.data, as: UTF8.self))")
/// ```
///
/// The underlying bytes are provided by linker symbols generated from `objcopy`.
/// They point at the embedded resource in the firmware image instead of a Swift
/// byte array, so reading an asset does not require storing a duplicate copy of
/// the resource in SRAM.
public struct Asset: ~Copyable, @unchecked Sendable {
    public let name: String
    public let data: UnsafeRawBufferPointer

    @_spi(AssetCompiler) public init(name: String, data: UnsafeRawBufferPointer) {
        self.name = name
        self.data = data
    }
}
