import ConcurrencyShims
import CPicoSDK

/// Stable identifier for one physical Pico CPU core.
enum CoreID: UInt8, CaseIterable, Hashable {
    case core0 = 0
    case core1 = 1

    static var current: CoreID {
        CoreID(rawValue: UInt8(get_core_num() & 1)) ?? .core0
    }

    var index: Int {
        Int(rawValue)
    }
}

/// Runtime scheduling mode for a Swift job.
enum JobKind {
    case immediate
    case delayed
    case deadline
}

/// Swift-style priority buckets. Lower raw values run first.
enum JobPriorityBucket: UInt8, CaseIterable {
    case userInteractiveOrHigher = 0
    case userInitiated = 1
    case `default` = 2
    case utility = 3
    case backgroundOrLower = 4

    static func resolve(job: UnsafeMutableRawPointer?) -> JobPriorityBucket {
        resolve(rawPriority: cshims_job_priority(job))
    }

    static func resolve(rawPriority priority: UInt8) -> JobPriorityBucket {
        if priority > TaskPriority.userInitiated.rawValue {
            return .userInteractiveOrHigher
        }
        if priority > TaskPriority.medium.rawValue {
            return .userInitiated
        }
        if priority > TaskPriority.utility.rawValue {
            return .default
        }
        if priority > TaskPriority.background.rawValue {
            return .utility
        }
        return .backgroundOrLower
    }
}

/// Logical identity used for task serialization.
struct TaskIdentity: Hashable {
    let rawValue: UInt

    static func resolve(job: UnsafeMutableRawPointer?) -> TaskIdentity? {
        guard let owner = cshims_job_owner_task(job) else {
            return nil
        }
        return TaskIdentity(rawValue: UInt(bitPattern: owner))
    }
}

/// Transport value for one Swift runtime job.
struct JobEnvelope {
    let kind: JobKind
    let job: UnsafeMutableRawPointer?
    let executorFirst: UnsafeMutableRawPointer?
    let executorSecond: UnsafeMutableRawPointer?
    let timeUs: UInt64
    let identity: TaskIdentity?
    let priorityBucket: JobPriorityBucket

    init(
        kind: JobKind,
        job: UnsafeMutableRawPointer?,
        executorFirst: UnsafeMutableRawPointer?,
        executorSecond: UnsafeMutableRawPointer?,
        timeUs: UInt64,
        identity: TaskIdentity?,
        priorityBucket: JobPriorityBucket
    ) {
        self.kind = kind
        self.job = job
        self.executorFirst = executorFirst
        self.executorSecond = executorSecond
        self.timeUs = timeUs
        self.identity = identity
        self.priorityBucket = priorityBucket
    }

}

/// Executes a small critical section using the C shim critical primitives.
func withCritical<T>(_ body: () -> T) -> T {
    let state = cshims_enter_critical()
    defer { cshims_exit_critical(state) }
    return body()
}
