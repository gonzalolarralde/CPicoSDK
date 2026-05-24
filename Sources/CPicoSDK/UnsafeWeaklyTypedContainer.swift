public struct UniqueTypeIdentifier: Equatable {
    private let function: UnsafeRawPointer
    private let context: UnsafeRawPointer

    @inline(never) @_optimize(none)
    private static func tokenFunction<T>(_ value: T) {}

    public init<T>(for type: T.Type) {
        _ = type
        let functionValue = Self.tokenFunction as (T) -> Void
        let pair = unsafeBitCast(functionValue, to: (UnsafeRawPointer, UnsafeRawPointer).self)
        self.function = pair.0
        self.context = pair.1
    }
}

public final class UnsafeWeaklyTypedContainer: @unchecked Sendable {
    private let pointer: UnsafeMutableRawPointer
    private let deinitializer: (UnsafeMutableRawPointer) -> Void
    private let typeID: UniqueTypeIdentifier
    private let configurationID: Configuration.ID?

    public init<T>(_ value: sending T) {
        self.typeID = UniqueTypeIdentifier(for: T.self)
        self.configurationID = nil
        self.pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        let typedPointer = self.pointer.initializeMemory(as: T.self, to: value)

        self.deinitializer = { pointer in
            typedPointer.deinitialize(count: 1)
            pointer.deallocate()
        }
    }

    public init<C: Configuration>(_ value: sending C) {
        self.typeID = UniqueTypeIdentifier(for: C.self)
        self.configurationID = C.id
        self.pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<C>.size, alignment: MemoryLayout<C>.alignment)
        let typedPointer = self.pointer.initializeMemory(as: C.self, to: value)

        self.deinitializer = { pointer in
            typedPointer.deinitialize(count: 1)
            pointer.deallocate()
        }
    }

    public func load<T>(as type: T.Type) -> T? {
        let requestedTypeID = UniqueTypeIdentifier(for: type)
        guard typeID == requestedTypeID else {
            return nil
        }
        return pointer.load(as: T.self)
    }

    public func load<C: Configuration>(as type: C.Type) -> C? {
        guard configurationID == C.id else {
            return nil
        }
        return pointer.load(as: C.self)
    }

    deinit {
        deinitializer(pointer)
    }
}
