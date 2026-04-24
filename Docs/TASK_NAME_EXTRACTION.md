# Task Name Extraction from SwiftJob*

This document describes how to derive a task name from an opaque `SwiftJob*`
pointer in the context of embedded Swift concurrency shims.  It covers the
runtime type hierarchy, the available runtime APIs, the memory layout of the
job header, the symbol availability constraints specific to embedded builds,
and the practical helpers exposed by `ConcurrencyShims`.

All of the techniques described here are based on Swift runtime internals.
**They are not stable ABI.**  Read the caveats section before using any of
this in your own code.

---

## Background: The Swift Job Type Hierarchy

The Swift concurrency runtime enqueues work as *jobs*.  A `SwiftJob*` is an
opaque pointer to a `Job` object allocated by the runtime.  Not every job is
a `Task`: some are lower-level work items dispatched by the runtime itself
(e.g. actor message deliveries).

```
HeapObject          ← root of all reference-counted Swift objects
  └─ Job            ← base class for all concurrency work items
       └─ AsyncTask ← a full Swift Task with stack, locals, name, ...
```

Only an `AsyncTask` carries a name field.  A raw `Job` does not.

The `Flags` word embedded in every `Job` header contains a `JobKind` field in
its low 8 bits that identifies which subtype a job actually is:

| JobKind value | Meaning                                    |
|---------------|--------------------------------------------|
| 0             | Unknown / internal placeholder             |
| 1             | **AsyncTask** — a Swift `Task { }` closure |
| 2             | JobDispatch — a non-task enqueued item     |

---

## Memory Layout of a SwiftJob (ARMv7-EM, 32-bit pointers)

The layout below was verified against Swift runtime sources (main branch,
2026) for `armv7em-none-none-eabi` with 32-bit pointer width.

```
Byte offset  Size  C type       Field
-----------  ----  ----------   ----------------------------------------
0x00          4    void *       HeapObject.metadata
                                  Pointer to the type's metadata record.
                                  For an AsyncTask this points to the task
                                  type descriptor, not to user type info.
0x04          4    uint32_t     HeapObject.refCounts
                                  Inline reference count (InlineRefCounts).
0x08          4    uint32_t     Job.Flags
                                  Bit-packed flags word (see layout below).
0x0C          4    void *       Job.SchedulerPrivate[0]
                                  Scheduler-private linkage word.
0x10          4    void *       Job.SchedulerPrivate[1]
                                  Scheduler-private linkage word.
0x14          4    void *       Job.RunFunction
                                  Pointer to the job's continuation function.
```

### Job.Flags bit layout

```
Bit range   Field             Notes
---------   -----             -----
[7:0]       JobKind           0=Unknown, 1=Task, 2=JobDispatch
[15:8]      JobPriority       Maps to TaskPriority enum values
[31:16]     Kind-specific     Depends on JobKind; do not interpret portably
```

Reading `Flags` directly via pointer arithmetic is possible but fragile.
Prefer the `swift_job_getKind` runtime API (see below) which abstracts the
exact field offset.

---

## Available Runtime APIs

The following symbols were confirmed present in the vendored
`libswift_Concurrency.a` (main-snapshot-2026-04-01,
`armv7em-none-none-eabi`) by `nm` inspection.

### Plain C symbols (unmangled, directly callable from C)

| Symbol                        | Signature (C approximation)               | Notes                                    |
|-------------------------------|-------------------------------------------|------------------------------------------|
| `swift_job_getKind`           | `uint32_t f(const void *job)`             | Returns the JobKind value.               |
| `swift_job_getPriority`       | `uint32_t f(const void *job)`             | Returns the TaskPriority value.          |
| `swift_task_getJobFlags`      | `uint32_t f(const void *job)`             | Returns the full raw Flags word.         |
| `swift_task_getCurrent`       | `void *f(void)`                           | Returns the currently running AsyncTask. |
| `swift_task_getCurrentTaskName` | `const char *f(void)`                  | Name of the currently running task.      |
| `swift_task_getJobTaskId`     | `uint64_t f(const void *job)`             | Numeric ID of the task (if it's a Task). |

All of these use the Swift calling convention (`swiftcall` / `SWIFT_CC_SWIFT`)
internally but on ARMv7-EM this is identical to the C calling convention for
integer/pointer arguments and return values.  Declare them with
`SWIFT_CC_SWIFT` (`__attribute__((swiftcall))`) for correctness.

### C++-mangled symbols (require the `__asm__` linkage trick)

| Demangled name                         | Mangled symbol                                   |
|----------------------------------------|--------------------------------------------------|
| `swift_task_getTaskName(AsyncTask*)`   | `_Z22swift_task_getTaskNamePN5swift9AsyncTaskE`  |

`swift_task_getTaskName` takes an arbitrary `AsyncTask*` (not just the current
one) and returns its name as a C string, or NULL.  **It was not exported with
C linkage in the embedded build.**  To call it from C you must use the
`__asm__` linkage-name attribute:

```c
#if defined(__clang__)
extern SWIFT_CC_SWIFT const char *my_alias(const void *task)
    __asm__("_Z22swift_task_getTaskNamePN5swift9AsyncTaskE");
#endif
```

This redirects the linker lookup to the mangled symbol while keeping the C
source readable.  The technique is supported by both Clang and GCC.

---

## When to Use `swift_task_getCurrentTaskName` vs `swift_task_getTaskName`

| Scenario                                             | Use                                   |
|------------------------------------------------------|---------------------------------------|
| Inside a job callback (job is currently running)     | `swift_task_getCurrentTaskName()`     |
| Before or after a job runs (job is queued/completed) | `cshims_job_get_task_name(job)`       |
| Log name at enqueue time in hook exports             | `cshims_job_get_task_name(job)`       |

`swift_task_getCurrentTaskName()` reads from the runtime's thread-local
current-task slot.  That slot is set by `swift_job_run` and cleared when the
job suspends or finishes.  It is therefore only valid from inside the callback
invoked by `swift_job_run`.  If you call it before `swift_job_run` the slot
will still hold whatever task ran last (or NULL), not the one you are about
to run.

---

## The `cshims_job_*` Helpers

`ConcurrencyShims` exposes two thin wrappers that compose the above:

```c
// Returns true if `job` is an AsyncTask.
bool cshims_job_is_task(const void *job);

// Returns the debug name of the task, or NULL.
const char *cshims_job_get_task_name(const void *job);
```

Declared in: `Sources/ConcurrencyShims/include/ConcurrencyShims.h`  
Implemented in: `Sources/ConcurrencyShims/ConcurrencyShims.c`

### Example: log task name at enqueue time

```c
// In your scheduler or hook override:
SWIFT_CC_SWIFT void swift_task_enqueueGlobalImpl(void *job) {
    const char *name = cshims_job_get_task_name(job);
    if (name != NULL) {
        // name is valid for the lifetime of the task.
        debug_log("enqueue task: %s", name);
    }
    cshims_scheduler_enqueue_immediate(job, NULL, NULL);
}
```

### Example: log task name just before running

```c
void cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond) {
    const char *name = cshims_job_get_task_name(job);
    if (name != NULL) {
        debug_log("running task: %s", name);
    }
    swift_job_run(job, executorFirst, executorSecond);
}
```

### Swift-side: how to give a task a name

In Swift 5.9+ (SE-0378) you can set an explicit task name at creation time:

```swift
Task(name: "my-sensor-loop") {
    // ...
}
```

Without an explicit `name:` argument, `swift_task_getTaskName` returns NULL.
Inferred names from `#function` or async stack frames are not automatically
populated in embedded builds.

---

## Caveats and Limitations

### ABI instability (the most important caveat)

The `JobKind` constant (1 for Task), the `Job.Flags` offset (0x08 on ARM32),
and the mangled symbol name of `swift_task_getTaskName` are all Swift runtime
internals.  They are **not** part of any stable ABI contract.  Any Swift
toolchain update can change them without notice.

`cshims_job_getKind` is more stable than a raw offset read because it goes
through the runtime's own accessor, but the accessor itself is still an
internal API.

### Task names in embedded mode

In embedded Swift the `Task(name:)` initialiser is available but name
tracking requires the runtime to allocate and maintain `TaskNameStatusRecord`
entries on the task's status record list.  Builds that aggressively strip
unused metadata or that omit the name feature will return NULL from
`swift_task_getTaskName`.

### NULL is not an error

Both `cshims_job_is_task` and `cshims_job_get_task_name` return conservative
results on failure.  A NULL name does not mean the job is broken; it just
means name information was not retained.

### Not safe from ISR context

`swift_job_getKind` and `swift_task_getTaskName` are ordinary runtime
functions that access heap memory.  Do not call them from interrupt handlers
or from contexts where reentrancy into the Swift runtime is not safe.

### Host builds

A plain host-side `swift build` will not link `libswift_Concurrency.a` for
the embedded target, so the `cshims_job_*` helpers will not be reachable
during host compilation.  They are only meaningful in the full embedded
finalize build.

---

## Raw Offset Approach (Informational)

If you cannot use the runtime APIs (for example, when porting to a different
embedded environment where `libswift_Concurrency.a` is not available), you
can read the `Flags` word directly:

```c
// FRAGILE: assumes ARMv7-EM layout from Swift 5.9+ (2024-04-01 snapshot).
#define CSHIMS_RAW_JOB_FLAGS_OFFSET  8u   // bytes from the start of the job
#define CSHIMS_RAW_JOB_KIND_MASK     0xFFu
#define CSHIMS_RAW_JOB_KIND_TASK     1u

static bool raw_job_is_task(const void *job) {
    uint32_t flags;
    memcpy(&flags, (const char *)job + CSHIMS_RAW_JOB_FLAGS_OFFSET, 4);
    return (flags & CSHIMS_RAW_JOB_KIND_MASK) == CSHIMS_RAW_JOB_KIND_TASK;
}
```

This is **more fragile** than calling `swift_job_getKind` because it relies
on the exact byte offset remaining stable.  Prefer the runtime API.

---

## Relationship to Existing Architecture

The `cshims_job_*` helpers follow the same design principle as the rest of
`ConcurrencyShims`:

- ABI glue and low-level inspections belong in C.
- Scheduler policy belongs in Swift.

The helpers are additive: they do not change any scheduling behaviour.
They exist purely as a debug/diagnostic surface.

For a broader view of the concurrency architecture, see
[CONCURRENCY_NOTES.md](CONCURRENCY_NOTES.md).
