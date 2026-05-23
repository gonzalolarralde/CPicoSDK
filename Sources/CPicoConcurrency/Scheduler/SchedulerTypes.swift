import ConcurrencyShims

/// Stable identifier for one physical Pico CPU core.
///
/// `SchedulerSystem` and `PlacementPolicy` use this as the shared language for
/// ownership decisions. `CoreExecutor` uses it to bind an executor instance to
/// the async context and inbox belonging to that core.
enum CoreID: UInt8, CaseIterable, Hashable {
    case core0 = 0
    case core1 = 1

    /// Returns the core currently running this code.
    ///
    /// This is currently stubbed to core0 while the multicore pass is being
    /// wired. Once core1 is launched, this should become the single wrapper
    /// around Pico's current-core primitive.
    static var current: CoreID {
        .core0
    }

    /// Index used for fixed per-core storage.
    var index: Int {
        Int(rawValue)
    }
}

/// Runtime scheduling mode for a Swift job.
///
/// The kind is chosen by the Swift runtime hook, carried through `JobEnvelope`,
/// and interpreted only by `CoreExecutor` when it converts the job into Pico
/// async-context work.
enum JobKind {
    case immediate
    case delayed
    case deadline
}

/// Logical identity used for task affinity.
///
/// This should eventually resolve the owning Swift async task or continuation
/// from a runtime job. `SchedulerSystem` uses this identity to consult the
/// `AffinityTable` before choosing a destination core. Keeping resolution here
/// isolates ABI-sensitive job-layout knowledge from placement and execution.
struct TaskIdentity: Hashable {
    let rawValue: UInt

    /// Resolves a scheduler identity from a raw Swift runtime job pointer.
    ///
    /// Returning nil means the scheduler cannot safely associate the job with a
    /// logical task. In that case placement falls back to non-affine policy.
    static func resolve(job: UnsafeMutableRawPointer?) -> TaskIdentity? {
        _ = job
        return nil
    }
}

/// Transport value for one Swift runtime job.
///
/// Runtime hooks create this after resolving task identity and placement. The
/// selected core's `CoreInbox` carries it to the matching `CoreExecutor`, where
/// it is attached to a `JobSlot` and eventually passed to `swift_job_run` through
/// `cshims_run_job_bridge`.
struct JobEnvelope {
    let kind: JobKind
    let job: UnsafeMutableRawPointer?
    let executorFirst: UnsafeMutableRawPointer?
    let executorSecond: UnsafeMutableRawPointer?
    let timeUs: UInt64
    let identity: TaskIdentity?
}

/// Inputs needed by the placement policy to choose a destination core.
///
/// This separates the policy decision from the global scheduler object. The
/// policy can ask for per-core outstanding work without knowing how work is
/// stored or executed.
struct PlacementInput {
    let identity: TaskIdentity?
    let enqueueCore: CoreID
    let multicoreEnabled: Bool
    let outstandingWorkByCore: (CoreID) -> UInt32
}

/// Chooses the owner core for new work.
///
/// The policy does not enqueue, mutate affinity counts, or touch async-context
/// state. It only answers "which core should own this envelope?". Active
/// affinity from `AffinityTable` is supplied separately and always wins.
enum PlacementPolicy {
    /// Returns the destination core for a job.
    ///
    /// Multicore-disabled systems always use core0. Unknown identities stay on
    /// the enqueueing core. Known identities without an active owner go to the
    /// less-loaded core, with ties currently falling back to core0.
    static func chooseCore(for input: PlacementInput, existingOwner: CoreID?) -> CoreID {
        if !input.multicoreEnabled {
            return .core0
        }

        if let existingOwner {
            return existingOwner
        }

        guard input.identity != nil else {
            return input.enqueueCore
        }

        let core0Work = input.outstandingWorkByCore(.core0)
        let core1Work = input.outstandingWorkByCore(.core1)
        return core1Work < core0Work ? .core1 : .core0
    }
}

/// Bookkeeping entry for one logical task identity.
///
/// An entry is active while either queued or running work exists. During that
/// active window, all jobs for the identity must keep the same `ownerCore`.
/// Once idle, a future enqueue may be placed again by `PlacementPolicy`.
struct AffinityEntry {
    let identity: TaskIdentity
    var ownerCore: CoreID
    var queuedCount: UInt16
    var runningCount: UInt8
    var idleSinceUs: UInt64
}

/// Tracks temporary task-to-core ownership.
///
/// This table is the only scheduler entity that should own queued/running
/// counters. `SchedulerSystem` marks acceptance before enqueueing, `CoreExecutor`
/// calls back before and after `swift_job_run`, and the table preserves the
/// invariant that an active task identity runs on only one core.
struct AffinityTable {
    /// Returns the active owner for an identity, or nil if the identity is idle,
    /// unknown, or not tracked.
    mutating func owner(for identity: TaskIdentity?) -> CoreID? {
        _ = identity
        return nil
    }

    /// Records that a job has been accepted for the selected owner core.
    ///
    /// This happens before the envelope is pushed to a core inbox so later jobs
    /// for the same active identity reuse the same owner.
    mutating func markAccepted(identity: TaskIdentity?, ownerCore: CoreID, nowUs: UInt64) {
        _ = identity
        _ = ownerCore
        _ = nowUs
    }

    /// Moves one accepted job from queued to running state.
    ///
    /// `CoreExecutor` calls this immediately before invoking `swift_job_run`.
    /// A complete implementation should verify that `core` is the active owner.
    mutating func markStarting(identity: TaskIdentity?, core: CoreID) {
        _ = identity
        _ = core
    }

    /// Marks one running job as finished and records idle time when no work
    /// remains for the identity.
    mutating func markFinished(identity: TaskIdentity?, core: CoreID, nowUs: UInt64) {
        _ = identity
        _ = core
        _ = nowUs
    }

    /// Rolls back an accepted job if transport or scheduling fails after
    /// ownership has already been recorded.
    mutating func rollbackAccepted(identity: TaskIdentity?, ownerCore: CoreID) {
        _ = identity
        _ = ownerCore
    }
}

/// Executes a small critical section using the C shim critical primitives.
///
/// Shared scheduler structures use this for short mutations that may be touched
/// by ISR or cross-core paths. Callers should keep the body small and avoid
/// invoking arbitrary user code inside it.
func withCritical<T>(_ body: () -> T) -> T {
    let state = cshims_enter_critical()
    defer { cshims_exit_critical(state) }
    return body()
}
