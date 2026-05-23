import ConcurrencyShims
import CPicoSDK

func launchSchedulerCore1() {
    let stack = cshims_scheduler_core1_stack_bottom().assumingMemoryBound(to: UInt32.self)
    let stackSizeBytes = Int(cshims_scheduler_core1_stack_size_bytes())
    multicore_launch_core1_with_stack(
        cshims_scheduler_core1_entry,
        stack,
        stackSizeBytes
    )
}

/// Starts core1 and returns whether multicore scheduling is available.
///
/// Swift scheduler work needs more stack than Pico's default core1 launch path
/// provides, so the scheduler owns a larger persistent stack.
func startCore1() -> Bool {
    multicore_reset_core1()
    launchSchedulerCore1()
    return true
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
        if cshimsRuntimeScheduler.pollOnce() == 0 {
            for _ in 0..<256 {
                tight_loop_contents()
            }
        }
    }
}
