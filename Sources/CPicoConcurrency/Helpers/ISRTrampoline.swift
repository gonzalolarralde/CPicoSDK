#if Platform_RP2040
    #error("Platform_RP2040 does not support Concurrency yet.")
#endif

import _Concurrency
import ConcurrencyShims
import CPicoSDK

/// Helper class to allow scheduling work from an ISR onto the shared async context, with support
/// for passing data from the ISR to the async context without allocations. This is used internally
/// for the sleep implementation, but can also be used directly by users for other IRQ handling scenarios.
public actor ISRTrampoline<UserData: Sendable, CriticalData: Sendable> {
    /// Creates a new trampoline with the given user data and post-ISR handler, and returns the trampoline 
    /// along with an opaque pointer that can be passed to C code and later consumed to trigger the trampoline.
    /// 
    /// Example:
    /// ```swift
    /// @c func someHandlingFunction(pointer: UnsafeMutableRawPointer?) {
    ///     ISRTrampoline.consume(pointer) { userData in
    ///         // This runs in IRQ context. Do minimal work here, just prepare any data you need to pass to postISR and return it.
    ///         return prepareCriticalDataFromIRQ(userData)
    ///     }
    /// }
    /// 
    /// let (trampoline, pointer) = ISRTrampoline.create(value: someUserData) { criticalData in
    ///     // This runs in async_context worker context, NOT in IRQ. You can safely interact with Swift concurrency primitives here.
    ///     handleCriticalData(criticalData)
    /// }
    /// 
    /// setIRQHandler(someHandlingFunction, pointer)
    /// ```
    /// 
    /// The data flow is as follows:
    /// - The trampoline is created with some user data and a post-ISR handler. An opaque pointer to the trampoline is returned.
    /// - The pointer is passed to C code and stored there (e.g. as an IRQ handler argument).
    /// - When the C code calls the handler with the pointer, `ISRTrampoline.consume` is called to obtain the userData, handle the critical section in the ISR, and obtain an output named criticalData.
    /// - The post-ISR handler is scheduled on the async context with the criticalData, allowing safe interaction with Swift concurrency primitives.
    /// - The trampoline is automatically cleaned up when the post-ISR handler runs, but it can also be manually cancelled if needed to free resources earlier.
    /// 
    /// When the trampoline is created User Data comes in > When the ISR is triggered Critical Data is prepared > Post-ISR handler is executed with Critical Data
    /// 
    /// Note: The trampoline is designed to be signaled only once. If the trampoline is signaled multiple times, it will trigger an assertion failure and ignore subsequent signals after the first one.
    public static func create(value: sending UserData, postISR: @Sendable @escaping @isolated(any) (sending CriticalData) async -> Void) -> sending (ISRTrampoline, UnsafeMutableRawPointer) {
        let trampoline = ISRTrampoline(value: value, postISR: postISR)
        return (trampoline, Unmanaged.passRetained(trampoline).toOpaque())
    }

    /// Consumes the trampoline pointer, executes the critical section in the ISR, and signals the post-ISR handler with the resulting critical data.
    /// This function is designed to be called from C code with the opaque pointer obtained from `ISRTrampoline.create`. It will handle the necessary 
    /// conversions and scheduling to ensure that the post-ISR handler is executed on the async context with the critical data prepared in the ISR.
    /// 
    /// Example:
    /// ```swift
    /// @c func someHandlingFunction(pointer: UnsafeMutableRawPointer?) {
    ///     ISRTrampoline.consume(pointer) { userData in
    ///         // This runs in IRQ context. Do minimal work here, just prepare any data you need to pass to postISR and return it.
    ///         return prepareCriticalDataFromIRQ(userData)
    ///     }
    /// }
    /// ```
    public static func consume(_ pointer: UnsafeMutableRawPointer?, criticalSection: (sending UserData) -> sending CriticalData) {
        guard let pointer else {
            assertionFailure("[CPicoSDK] ISRTrampoline consume called with null pointer.")
            return
        }

        let trampoline = Unmanaged<ISRTrampoline<UserData, CriticalData>>.fromOpaque(pointer).takeUnretainedValue()

        trampoline.signal(criticalData: criticalSection(trampoline.value))
    }

    /// Preallocated async-context work item to avoid allocations in the ISR path.
    nonisolated(unsafe) private let postISRWorkItem: AsyncContextWorkItem
    nonisolated(unsafe) private var signaled = false
    private let value: UserData
    nonisolated(unsafe) private let criticalData: UnsafeMutablePointer<CriticalData?> = .allocate(capacity: 1)
    private var postISR: (@isolated(any) (sending CriticalData) async -> Void)?

    private init(value: sending UserData, postISR: @Sendable @escaping @isolated(any) (sending CriticalData) async -> Void) {
        self.value = value
        self.postISR = postISR
        self.postISRWorkItem = AsyncContextWorkItem()
        self.criticalData.pointee = nil

        let rawSelf: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()
        postISRWorkItem.configure {
            Task {
                await self.run()
            }
        } finalizer: {
            Unmanaged<ISRTrampoline<UserData, CriticalData>>.fromOpaque(rawSelf).release()
        }

        cshimsRuntimeScheduler.executor(for: .core0).register(postISRWorkItem)
    }

    nonisolated private func signal(criticalData: sending CriticalData) {
        guard !self.signaled else {
            assertionFailure("[CPicoSDK] ISRTrampoline signaled more than once. This is not supported.")
            return
        }

        self.signaled = true
        self.criticalData.deinitialize(count: 1)
        self.criticalData.initialize(to: criticalData)
        postISRWorkItem.signal()
    }

    private func run() async {
        guard let postISR = self.postISR.take() else {
            assertionFailure("[CPicoSDK] ISRTrampoline postISR handler is gone, the trampoline was signaled more than once.")
            return
        }

        guard let criticalData = criticalData.pointee else {
            assertionFailure("[CPicoSDK] ISRTrampoline critical data is missing. This is unexpected.")
            return
        }

        await postISR(criticalData)
    }

    /// Cancels the trampoline, preventing the post-ISR handler from being called if the trampoline is still pending, and freeing resources. 
    /// If the trampoline has already been signaled, this has no effect.
    public func cancel() {
        postISRWorkItem.cancel()
    }

    deinit {
        if criticalData.pointee != nil {
            criticalData.deinitialize(count: 1)
        }
        criticalData.deallocate()
    }
}

/// Schedules a one-shot block onto the shared async context. It cannot be cancelled.
/// This is useful for scheduling work from an ISR or other non-async contexts without 
/// needing to manage continuations or trampolines, but it should be used with care as 
/// it does not provide any guarantees about when the block will be executed.
/// 
/// Prefer using `ISRTrampoline` if you need to pass data from the ISR context avoiding
/// allocations.
/// 
/// Example usage:
/// ```swift
/// @c func someIRQHandler() {
///     executeLater {
///         // This runs in async_context worker context.
///         continuation.resume()
///     }
/// }
/// ```
public func executeLater(_ block: @escaping () -> Void) {
    cshimsRuntimeScheduler.schedule(block)
}
