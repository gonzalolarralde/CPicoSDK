@_exported import _Concurrency

// This is for a future exploration.

// @globalActor
// public actor CPU0Actor {
//     public static let shared = CPU0Actor()
// }

// @globalActor
// public actor CPU1Actor {
//     public static let shared = CPU1Actor()
// }

/// The main actor is responsible for executing tasks on the main thread.
/// This is added just to provide some level of compatibility with existing 
/// Swift code, but it doesn't have any special meaning in our runtime yet.
/// 
/// TODO: Ensure that tasks scheduled on the MainActor actually run on cpu0
/// and not on a random worker thread. This will likely require some changes
/// to our runtime scheduler.
@globalActor
public actor MainActor {
    public static let shared = MainActor()
}
