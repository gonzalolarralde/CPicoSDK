import ConcurrencyShims
import CPicoSDK

/// Placeholder slot type retained so existing scheduler callback symbols compile.
struct JobSlot {}

/// Placeholder executor type retained only as a compile-time boundary.
final class CoreExecutor {
    let core: CoreID
    var context = async_context_poll_t()

    init(core: CoreID) {
        self.core = core
        guard async_context_poll_init_with_defaults(&context) else {
            fatalError("[CPicoConcurrency] clean-room scheduler shell: failed to initialize placeholder executor context")
        }
    }

#if CPUMetrics
    func recordInterruptCPUUsage(event: RuntimeCPUUsageMeter.Event) {
        _ = event
    }

    func cpuUsageReportIfNeeded() -> CPUStats? {
        nil
    }
#endif

    func pollOnce() {
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement core executor poll")
    }

    func schedule(_ envelope: JobEnvelope) {
        _ = envelope
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement job scheduling")
    }

    func schedule(_ block: @escaping () -> Void) {
        _ = block
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement deferred block scheduling")
    }

    func enqueueDeferred(_ item: DeferredWorkItem) {
        _ = item
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement deferred item enqueue")
    }

    func drainDeferredWork() {
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement deferred work drain")
    }

    func waitForWork() {
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement core wait")
    }

    func run(slot: UnsafeMutablePointer<JobSlot>, scheduler: SchedulerSystem) {
        _ = slot
        _ = scheduler
        fatalError("[CPicoConcurrency] clean-room scheduler shell: implement slot execution")
    }
}

@_cdecl("cshims_scheduler_deferred_work_worker")
func cshims_scheduler_deferred_work_worker(
    _ context: UnsafeMutablePointer<async_context_t>?,
    _ worker: UnsafeMutablePointer<async_when_pending_worker_t>?
) {
    _ = context
    _ = worker
    fatalError("[CPicoConcurrency] clean-room scheduler shell: implement deferred worker callback")
}

@_cdecl("cshims_scheduler_pending_worker")
func cshims_scheduler_pending_worker(
    _ context: UnsafeMutablePointer<async_context_t>?,
    _ worker: UnsafeMutablePointer<async_when_pending_worker_t>?
) {
    _ = context
    _ = worker
    fatalError("[CPicoConcurrency] clean-room scheduler shell: implement pending worker callback")
}

@_cdecl("cshims_scheduler_delayed_worker")
func cshims_scheduler_delayed_worker(
    _ context: UnsafeMutablePointer<async_context_t>?,
    _ worker: UnsafeMutablePointer<async_at_time_worker_t>?
) {
    _ = context
    _ = worker
    fatalError("[CPicoConcurrency] clean-room scheduler shell: implement delayed worker callback")
}
