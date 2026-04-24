#ifndef SWIFT_JOB_INTERNALS_H
#define SWIFT_JOB_INTERNALS_H

// ============================================================================
// SwiftJobInternals.h — Unstable, Debug-Only Task Introspection
// ============================================================================
//
// This header exposes C-accessible definitions that mirror private Swift
// runtime internals, allowing low-level inspection of a SwiftJob pointer
// inside the executor shim layer.
//
// SOURCE REFERENCES (swiftlang/swift@8104e4c3ae46d1211755afa5a709f6b8624c1c79)
// ============================================================================
//
// (1) JOB KIND — where it is defined and extracted
//
//   File: include/swift/ABI/MetadataValues.h
//
//   • enum class JobKind : size_t { Task = 0, ... }
//     All schedulable job kinds. A value of 0 means the job is an AsyncTask.
//
//   • class JobFlags : public FlagSet<uint32_t>
//     The flag word carried by every Job:
//       enum { Kind = 0, Kind_width = 8, ... Task_HasInitialTaskName = 30 }
//     Accessor: getKind() returns the JobKind from bits 0–7.
//     Bit 30 is set when the task was created with a name.
//
//   File: include/swift/ABI/Task.h
//
//   • class Job : public HeapObject
//     Carries the field:
//       JobFlags Flags;   // WARNING: DO NOT MOVE — schedulers rely on its offset.
//     The "WARNING: DO NOT MOVE" comment in Task.h makes this the most stable
//     field for a scheduler to read.
//
// (2) TASK NAME METADATA — where it is stored
//
//   File: include/swift/ABI/TaskOptions.h
//
//   • class InitialTaskNameTaskOptionRecord : public TaskOptionRecord
//       const char* TaskName;
//     This is the creation-time option record passed by the Swift compiler
//     when a task is spawned with a name (Builtin.createTask(taskName:...)).
//     Kind: TaskOptionRecordKind::InitialTaskName = 7.
//
//   File: include/swift/ABI/TaskStatus.h
//
//   • class TaskNameStatusRecord : public TaskStatusRecord
//       const char *Name;
//     This is the runtime status record that stores the name after task
//     creation. It lives in the task's status record chain for the entire
//     lifetime of the task (even after completion, unlike other records).
//     Kind: TaskStatusRecordKind::TaskName = 6.
//
//   File: stdlib/public/Concurrency/TaskStatus.cpp
//
//   • AsyncTask::pushInitialTaskName(const char* taskName)
//     Called during task creation (Task.cpp, around line 800) when
//     jobFlags.task_hasInitialTaskName() is true.
//     Allocates a copy of the name string and a TaskNameStatusRecord on the
//     task's allocator, then links it as the innermost status record.
//     IMPORTANT: This must be the FIRST allocation on the task allocator stack.
//
//   • AsyncTask::getTaskName()
//     Checks the flag first; if set, acquires the status record lock and
//     walks the record chain looking for TaskStatusRecordKind::TaskName (6).
//
//   File: stdlib/public/Concurrency/Task.cpp (≈ line 753)
//
//   • The option-record loop inside swift_task_create_commonImpl dispatches:
//       case TaskOptionRecordKind::InitialTaskName:
//         taskName = cast<InitialTaskNameTaskOptionRecord>(option)->getTaskName();
//         jobFlags.task_setHasInitialTaskName(true);
//         break;
//     and then, after the task allocation:
//       if (jobFlags.task_hasInitialTaskName()) {
//         task->pushInitialTaskName(taskName);
//       }
//
// CONNECTION PATH: SwiftJob* → task name
// ============================================================================
//
//   1. void *job
//      → read uint32_t JobFlags at byte offset CSHIMS_JOB_FLAGS_OFFSET
//
//   2. Check bits 0–7 of JobFlags == 0 (JobKind::Task)
//      If not zero, the job is not an AsyncTask; return NULL.
//
//   3. Check bit 30 of JobFlags (Task_HasInitialTaskName)
//      If not set, the task has no name; return NULL.
//
//   4. Treat void* as AsyncTask*.
//      → read TaskStatusRecord* from byte offset CSHIMS_ASYNC_TASK_RECORD_OFFSET
//        (= AsyncTask::Private offset + ActiveTaskStatus offset + Record offset)
//
//   5. Walk the singly-linked TaskStatusRecord chain (via Parent pointers).
//      For each record read bits 0–7 of its Flags (TaskStatusRecordFlags).
//      Stop when kind == 6 (TaskStatusRecordKind::TaskName).
//
//   6. Cast that record to TaskNameStatusRecord.
//      → read const char* at byte offset CSHIMS_NAME_RECORD_NAME_OFFSET
//      Return that pointer.
//
// ============================================================================
// STABILITY WARNING
// ============================================================================
//
// These offsets are ONLY valid for:
//
//   • ARM Cortex-M (armv7em-none-none-eabi), 32-bit pointers
//   • Embedded Swift without priority escalation
//   • swiftlang/swift commit 8104e4c3ae46d1211755afa5a709f6b8624c1c79
//
// They WILL break if any of the following change:
//   • sizeof(void*) (e.g. 64-bit host builds)
//   • Job gains or loses Voucher / Reserved fields
//   • SWIFT_CONCURRENCY_ENABLE_PRIORITY_ESCALATION is enabled
//   • PrivateStorage layout changes in the runtime
//
// All APIs in this header are guarded by
//   #if defined(__arm__) || defined(__thumb__)
// so they produce a compile error on non-ARM targets rather than silently
// computing wrong offsets.
//
// ============================================================================

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// JobFlags bit layout (MetadataValues.h — class JobFlags)
// ---------------------------------------------------------------------------

// Bits 0–7: JobKind.  A value of 0 means the job is an AsyncTask (Task = 0).
#define CSHIMS_JOB_KIND_MASK   ((uint32_t)0xFFu)
#define CSHIMS_JOB_KIND_TASK   ((uint32_t)0u)

// Bit 30: Task_HasInitialTaskName — set when a name was given at spawn time.
#define CSHIMS_JOB_FLAG_HAS_TASK_NAME  ((uint32_t)(1u << 30))

// ---------------------------------------------------------------------------
// TaskStatusRecordFlags bit layout (MetadataValues.h — TaskStatusRecordKind)
// ---------------------------------------------------------------------------

// Bits 0–7: TaskStatusRecordKind.  6 = TaskName.
#define CSHIMS_RECORD_KIND_MASK      ((size_t)0xFFu)
#define CSHIMS_RECORD_KIND_TASK_NAME ((size_t)6u)

// ---------------------------------------------------------------------------
// Memory layout offsets — ARM Cortex-M embedded 32-bit ONLY
//
// Derivation (see header comment and Task.h / TaskPrivate.h source):
//
//  Job (embedded, no Voucher/Reserved):
//    HeapObject  { void *metadata (4);  uint32_t refcount (4); }  =  8 bytes
//    void *SchedulerPrivate[2]                                      =  8 bytes
//    uint32_t Flags   ← CSHIMS_JOB_FLAGS_OFFSET = 16
//    uint32_t Id      = 4 bytes
//    void *RunJob     = 4 bytes
//    (tail padding 4 bytes, reused by AsyncTask::ResumeContext)
//
//  AsyncTask (32-bit embedded):
//    [Job — 28 bytes content, 4 bytes tail padding used below]
//    AsyncContext *ResumeContext  @ offset 28
//    OpaquePrivateStorage Private @ offset 32 = CSHIMS_TASK_PRIVATE_OFFSET
//
//  OpaquePrivateStorage.Storage layout (TaskPrivate.h comment):
//    6 × void*   (24 bytes)  — TaskAllocator / LocalValues / etc.
//    16 bytes of non-pointer data  (BasePriority, etc.)
//     8 bytes of padding
//    ActiveTaskStatus  (8 bytes on 32-bit/no-escalation) @ Storage offset 48
//      uint32_t Flags              @ ActiveTaskStatus offset 0
//      TaskStatusRecord *Record    @ ActiveTaskStatus offset 4
//                                         → CSHIMS_ACTIVE_STATUS_RECORD_OFFSET = 4
//    RecursiveMutex  (follows ActiveTaskStatus)
//
//  Full offset of the Record pointer from the start of AsyncTask:
//    CSHIMS_TASK_PRIVATE_OFFSET + 48 + CSHIMS_ACTIVE_STATUS_RECORD_OFFSET
//    = 32 + 48 + 4 = 84 = CSHIMS_ASYNC_TASK_RECORD_OFFSET
//
//  TaskStatusRecord (base class):
//    size_t  Flags   @ offset 0  (bits 0–7 = TaskStatusRecordKind)
//    TaskStatusRecord *Parent  @ offset sizeof(size_t) = 4
//
//  TaskNameStatusRecord (derived, immediately after base):
//    const char *Name  @ offset 2 × sizeof(void*) = 8
// ---------------------------------------------------------------------------

#if defined(__arm__) || defined(__thumb__)

// Offset of Job::Flags from the start of any Job / AsyncTask.
#define CSHIMS_JOB_FLAGS_OFFSET         ((size_t)16u)

// Offset of AsyncTask::Private from the start of AsyncTask (embedded arm32).
#define CSHIMS_TASK_PRIVATE_OFFSET      ((size_t)32u)

// Offset of the Record pointer within ActiveTaskStatus (arm32, no escalation).
#define CSHIMS_ACTIVE_STATUS_RECORD_OFFSET  ((size_t)4u)

// Combined offset: Record ptr from AsyncTask* (32 + 48 + 4 = 84).
#define CSHIMS_ASYNC_TASK_RECORD_OFFSET \
    (CSHIMS_TASK_PRIVATE_OFFSET + (size_t)48u + CSHIMS_ACTIVE_STATUS_RECORD_OFFSET)

// Offset of TaskStatusRecord::Flags from the start of a status record.
#define CSHIMS_RECORD_FLAGS_OFFSET      ((size_t)0u)

// Offset of TaskStatusRecord::Parent from the start of a status record.
#define CSHIMS_RECORD_PARENT_OFFSET     ((size_t)sizeof(void*))

// Offset of TaskNameStatusRecord::Name (= base class size = 2 × sizeof(void*)).
#define CSHIMS_NAME_RECORD_NAME_OFFSET  ((size_t)(2u * sizeof(void*)))

// ---------------------------------------------------------------------------
// Inline helpers — ARM 32-bit only
// ---------------------------------------------------------------------------

// Read the JobFlags uint32_t from any Job-derived pointer (Job, AsyncTask, …).
static inline uint32_t cshims_job_read_flags(const void *job)
{
    if (!job) { return 0; }
    uint32_t flags;
    memcpy(&flags, (const uint8_t *)job + CSHIMS_JOB_FLAGS_OFFSET, sizeof(flags));
    return flags;
}

// Return 1 if the job is an AsyncTask (JobKind::Task == 0).
static inline int cshims_job_is_async_task(uint32_t job_flags)
{
    return (job_flags & CSHIMS_JOB_KIND_MASK) == CSHIMS_JOB_KIND_TASK;
}

// Return 1 if the task was created with a name (bit 30 of JobFlags is set).
static inline int cshims_job_has_initial_task_name(uint32_t job_flags)
{
    return (job_flags & CSHIMS_JOB_FLAG_HAS_TASK_NAME) != 0;
}

// Read the head of the status record chain from an AsyncTask pointer.
// Returns NULL if no records are present or task is NULL.
static inline void *cshims_async_task_get_record_head(const void *task)
{
    if (!task) { return NULL; }
    void *record;
    memcpy(&record,
           (const uint8_t *)task + CSHIMS_ASYNC_TASK_RECORD_OFFSET,
           sizeof(record));
    return record;
}

// Walk the TaskStatusRecord chain rooted at |record| and return the
// TaskNameStatusRecord's Name pointer, or NULL if not found.
static inline const char *cshims_find_task_name_in_records(void *record)
{
    while (record) {
        size_t rec_flags;
        memcpy(&rec_flags,
               (const uint8_t *)record + CSHIMS_RECORD_FLAGS_OFFSET,
               sizeof(rec_flags));

        if ((rec_flags & CSHIMS_RECORD_KIND_MASK) == CSHIMS_RECORD_KIND_TASK_NAME) {
            const char *name;
            memcpy(&name,
                   (const uint8_t *)record + CSHIMS_NAME_RECORD_NAME_OFFSET,
                   sizeof(name));
            return name;
        }

        // Advance to the parent (older) record.
        void *parent;
        memcpy(&parent,
               (const uint8_t *)record + CSHIMS_RECORD_PARENT_OFFSET,
               sizeof(parent));
        record = parent;
    }
    return NULL;
}

#endif /* __arm__ || __thumb__ */

#ifdef __cplusplus
}
#endif

#endif /* SWIFT_JOB_INTERNALS_H */
