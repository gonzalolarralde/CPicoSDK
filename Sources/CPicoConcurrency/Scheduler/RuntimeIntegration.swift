import ConcurrencyShims
import CPicoSDK

/// Owns the core1 launch sequence.
///
/// This is behavior, not scheduler state. Keeping it outside `SchedulerTypes`
/// prevents the data model from collecting platform startup details.
enum MulticoreLauncher {
    /// Starts core1 and returns whether multicore scheduling is available.
    ///
    /// Pico owns the default core1 stack through its `.stack1` section and the
    /// linker-provided `__StackOne*` symbols. That keeps stack-bounds reporting
    /// aligned with `swift_threading_defer_current_stack_bounds`.
    static func start() -> Bool {
        multicore_reset_core1()
        multicore_launch_core1(cshims_scheduler_core1_entry)
        return true
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
        guard core == CoreID.current else {
            return
        }

        cshims_swift_task_clear_current()
    }
}

/// Entry point passed to Pico's core1 launcher.
///
/// Core1 clears inherited Swift runtime state, then runs the same scheduler
/// iteration used by core0 drain/donate hooks. Idle iterations call Pico's
/// tight-loop hook so the target remains friendly to SDK-level idle handling.
@_cdecl("cshims_scheduler_core1_entry")
func cshims_scheduler_core1_entry() {
    PlatformRuntimeIsolation.prepareCoreForSwiftRuntime(CoreID.current)
    while true {
        if cshimsRuntimeScheduler.coreLoopIteration() == 0 {
            for _ in 0..<256 {
                tight_loop_contents()
            }
        }
    }
}
