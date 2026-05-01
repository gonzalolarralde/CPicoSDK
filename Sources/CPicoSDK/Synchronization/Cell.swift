// FIXME: This is being recreated because _Cell doesn't seem to be included in
// the Embedded build of Synchronization. The CMakeList.txt file in Synchronization
// seems to indicate that it should, but for some reason it isn't.
//
// CPicoSDK/Sources/CPicoSDK/Synchronization/Mutex.swift:44:14: error: cannot find type '_Cell' in scope

@frozen
public struct _Cell<Value: ~Copyable>: ~Copyable {
  public let _address: UnsafeMutablePointer<Value>

  @_alwaysEmitIntoClient
  @_transparent
  public init(_ initialValue: consuming Value) {
    _address = .allocate(capacity: 1)
    unsafe _address.initialize(to: initialValue)
  }

  @_alwaysEmitIntoClient
  @inlinable
  deinit {
    unsafe _address.deinitialize(count: 1)
    _address.deallocate()
  }
}
