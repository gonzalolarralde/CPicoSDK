/// Owns the core1 launch sequence.
///
/// This is behavior, not scheduler state. Keeping it outside `SchedulerTypes`
/// prevents the data model from collecting platform startup details such as
/// stack selection, runtime state clearing, and Pico multicore launch calls.
enum MulticoreLauncher {
    /// Starts core1 and returns whether multicore scheduling is available.
    ///
    /// The implementation is still a placeholder while the entity graph is
    /// being wired. A complete version should launch core1 with an explicit
    /// stack and arrange for it to call `cshims_scheduler_core_loop_iteration`.
    static func start(system: SchedulerSystem) -> Bool {
        _ = system
        return false
    }
}

/// Boundary for Swift runtime state that must be isolated per core.
///
/// The scheduler can keep one logical task from being run on two cores, but it
/// cannot by itself fix runtime state that behaves like global TLS. This behavior
/// entity is the explicit place for current-task/TLS setup and validation.
enum PlatformRuntimeIsolation {
    /// Prepares Swift runtime state before a core starts running scheduler work.
    static func prepareCoreForSwiftRuntime(_ core: CoreID) {
        _ = core
    }
}
