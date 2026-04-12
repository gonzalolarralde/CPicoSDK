# Embedded Concurrency Notes

This document captures the current state of embedded Swift concurrency support in this repository after the recent investigation.

The short version:

- generic embedded `async`/`await` now works on device
- the project links against the toolchain-provided `libswift_Concurrency.a`
- custom executors are still not usable on this toolchain
- the runtime hook surface remains in C
- the scheduling backend now lives in Swift and uses Pico SDK `async_context`

## Current Architecture

The runtime is now split in two layers.

### 1. C ABI shim

File:

- [Sources/ConcurrencyShims/ConcurrencyShims.c](../Sources/ConcurrencyShims/ConcurrencyShims.c)

This file is intentionally minimal. It exists because the embedded Swift concurrency runtime expects a set of exported low-level hook symbols with the right ABI.

It currently provides:

- `swift_task_enqueueGlobalImpl`
- `swift_task_enqueueMainExecutorImpl`
- `swift_task_enqueueGlobalWithDelayImpl`
- `swift_task_enqueueGlobalWithDeadlineImpl`
- `swift_task_donateThreadToGlobalExecutorUntilImpl`
- `swift_task_checkIsolatedImpl`
- `swift_task_isIsolatingCurrentContextImpl`
- `swift_task_getMainExecutorImpl`
- `swift_task_isMainExecutorImpl`
- `swift_task_asyncMainDrainQueueImpl`
- `swift_getObjectType`
- `swift_compareWitnessTables`
- `_task_serialExecutor_getExecutorRef`
- `_task_serialExecutor_isSameExclusiveExecutionContext`
- `_task_serialExecutor_checkIsolated`
- `_task_serialExecutor_isIsolatingCurrentContext`
- `_swift_shouldReportFatalErrorsToDebugger`
- `_swift_reportToDebugger`
- `memset_s`
- `clock_gettime`
- `clock_getres`

It also provides a tiny bridge surface for the Swift scheduler:

- `cshims_swift_task_poll_once`
- `cshims_swift_task_drain`
- `cshims_run_job_bridge`
- `cshims_enter_critical`
- `cshims_exit_critical`

The important design constraint is:

- the C file owns the runtime hook exports
- it should not own scheduler policy or Pico SDK type definitions

### 2. Swift scheduler backend

Files:

- [Sources/CPicoConcurrency/RuntimeScheduler.swift](/Users/gonzalo/src/CPicoSDK/Sources/CPicoConcurrency/RuntimeScheduler.swift)
- [Sources/CPicoConcurrency/ConcurrencyHelpers.swift](/Users/gonzalo/src/CPicoSDK/Sources/CPicoConcurrency/ConcurrencyHelpers.swift)

`RuntimeScheduler.swift` owns the actual work scheduling policy.

It currently:

- creates and owns one `async_context_poll_t`
- pre-registers `async_when_pending_worker_t` workers for immediate work
- schedules delayed work via `async_at_time_worker_t`
- stores runnable work in a fixed slot pool
- calls back into `cshims_run_job_bridge(...)` when a job is ready to run

This was done specifically to avoid keeping a duplicate handwritten copy of Pico SDK `async_context` internals in C.

The important design constraint is:

- scheduler logic belongs in Swift
- ABI glue belongs in C

## What Actually Works

The following is now confirmed.

### Generic embedded concurrency works

The project links the embedded runtime archive from the toolchain:

- `libswift_Concurrency.a`

The finalize plugin was updated to detect when concurrency runtime symbols are needed and link that archive automatically.

The working execution pattern is:

```swift
static func main() {
    Task {
        try! await asyncMain()
    }

    while true {
        _ = cshims_swift_task_poll_once()
    }
}
```

This is the key observation:

- `Task { ... }` really does go through the embedded Swift runtime
- the runtime calls into the C hook layer
- the hook layer now forwards to the Swift `async_context` scheduler
- polling `cshims_swift_task_poll_once()` is what drives progress

### The active queue is the runtime queue

One major debugging step was realizing the app had been draining the wrong queue.

What was happening earlier:

- the runtime enqueued jobs through `swift_task_enqueueGlobalImpl`
- those jobs were stored in the runtime-side scheduler
- the app was polling a separate Swift queue from the earlier custom executor experiment

After switching the main loop to call `cshims_swift_task_poll_once()`, tasks started running.

This is the correct queue to pump for the current design.

### Toolchain runtime support already existed

The embedded toolchain already ships the core concurrency runtime. Local `nm` inspection confirmed that `libswift_Concurrency.a` exports symbols such as:

- `swift_task_alloc`
- `swift_task_dealloc`
- `swift_task_switch`
- `swift_task_create`
- `swift_job_run`
- `swift_continuation_init`
- `swift_continuation_await`
- `swift_continuation_throwingResume`

That changed the implementation strategy completely.

The project does not need to reimplement the Swift concurrency runtime. It only needs:

- the right runtime hook surface
- a platform scheduler
- the correct build/link integration

## What Does Not Work

### Custom executors

Custom executors are still not usable on this toolchain.

When the code tried to hop onto a custom executor-backed actor, execution reached:

- `swift_task_enqueueImpl`
- `swift_unreachable`
- hardfault

Upstream runtime source confirmed this is deliberate in embedded mode. In `stdlib/public/Concurrency/Actor.cpp`, the embedded branch traps for:

- task executors
- custom serial executors

So the current status is:

- generic embedded concurrency works
- custom executors do not

That is why the current scheduler architecture does not try to revive the earlier `SerialExecutor` design.

### Replacing the hook exports with Swift `@_silgen_name`

A narrow experiment was run to see whether the simplest runtime hook exports could be defined directly in Swift using `@_silgen_name`.

The attempted targets were:

- `swift_task_enqueueGlobalImpl`
- `swift_task_enqueueMainExecutorImpl`

This failed in practice:

- first with linkage mismatches
- then with undefined references
- then with a compiler crash in the embedded pipeline:
  - `cannot make a private external symbol`
  - `UNREACHABLE executed ... SILModule.cpp`

Conclusion:

- the runtime hook exports should stay in C
- Swift should only own the scheduler backend behind that boundary

That experiment should be considered closed unless the toolchain behavior changes upstream.

## Build and Link Notes

### Finalize plugin archive selection

`Plugins/FinalizeBinaryPlugin/FinalizeBinaryPlugin.swift` was updated so the finalize flow links:

- `libswift_Concurrency.a`

It intentionally does not link:

- `libswift_ConcurrencyDefaultExecutor.a`

That archive pulled in dependencies like:

- `std::chrono`
- `_nanosleep`
- `__error`

which are the wrong model for this target.

### Static archive grouping

The CMake harness now links the app archive and extra Swift archives inside:

- `-Wl,--start-group`
- `-Wl,--end-group`

This was required because:

- `libExample.a` provides the shim symbols
- `libswift_Concurrency.a` references them
- GNU ld otherwise would not rescan earlier archives

Without grouping, valid symbols present in the build were still reported as unresolved.

## Current Sharp Edges

### The `_cpicosdk_*` marker duplication issue still exists

The fixed-name marker globals in [Sources/CPicoSDK/CPicoSDK.swift](/Users/gonzalo/src/CPicoSDK/Sources/CPicoSDK/CPicoSDK.swift) remain fragile:

- `_cpicosdk_combination_*`
- `_cpicosdk_trait_*`

This investigation triggered that problem again once `CPicoConcurrency` started importing `CPicoSDK` and doing real work with it.

`nm` showed duplicate definitions in multiple object files, for example:

- `CPicoSDK.swift.o`
- `Example.swift.o`
- `ConcurrencyHelpers.swift.o`

At the user’s direction, those markers were not moved out of Swift.

The current mitigation attempt is:

- `private import CPicoSDK` inside [RuntimeScheduler.swift](/Users/gonzalo/src/CPicoSDK/Sources/CPicoConcurrency/RuntimeScheduler.swift)

This area is still fragile and should be treated carefully.

### Host `swift build` is not a meaningful validation path

A plain host-side `swift build` is not representative for this work.

Reasons:

- the generated Pico SDK module headers contain ARM-only inline asm
- the generated hardware structs assume target-specific layout
- host Clang sees 64-bit layout and rejects those `_Static_assert`s

So the meaningful build path for this work remains the real embedded target build / finalize flow, not generic host compilation.

## Current Recommended Direction

The current implementation direction should remain:

1. Keep the runtime hook exports in [ConcurrencyShims.c](/Users/gonzalo/src/CPicoSDK/Sources/ConcurrencyShims/ConcurrencyShims.c) as small as possible.
2. Keep scheduler policy in [RuntimeScheduler.swift](/Users/gonzalo/src/CPicoSDK/Sources/CPicoConcurrency/RuntimeScheduler.swift).
3. Continue using Pico SDK `async_context` rather than rebuilding another custom queue.
4. Avoid custom executors until the embedded runtime itself supports them.
5. Validate changes through the embedded build path, not host `swift build`.

## Current File Map

Relevant files as of now:

- [Sources/ConcurrencyShims/ConcurrencyShims.c](/Users/gonzalo/src/CPicoSDK/Sources/ConcurrencyShims/ConcurrencyShims.c)
- [Sources/ConcurrencyShims/include/ConcurrencyShims.h](/Users/gonzalo/src/CPicoSDK/Sources/ConcurrencyShims/include/ConcurrencyShims.h)
- [Sources/CPicoConcurrency/RuntimeScheduler.swift](/Users/gonzalo/src/CPicoSDK/Sources/CPicoConcurrency/RuntimeScheduler.swift)
- [Sources/CPicoConcurrency/ConcurrencyHelpers.swift](/Users/gonzalo/src/CPicoSDK/Sources/CPicoConcurrency/ConcurrencyHelpers.swift)
- [Sources/CPicoConcurrency/PicoSerialExecutor.swift](/Users/gonzalo/src/CPicoSDK/Sources/CPicoConcurrency/PicoSerialExecutor.swift)
- [Plugins/FinalizeBinaryPlugin/FinalizeBinaryPlugin.swift](/Users/gonzalo/src/CPicoSDK/Plugins/FinalizeBinaryPlugin/FinalizeBinaryPlugin.swift)
- [Plugins/FinalizeBinaryPluginTool/CMakeHarness/CMakeLists.txt](/Users/gonzalo/src/CPicoSDK/Plugins/FinalizeBinaryPluginTool/CMakeHarness/CMakeLists.txt)

## Bottom Line

The project is past the earlier fake-runtime stage.

The current system is:

- real embedded Swift concurrency runtime
- thin C hook layer
- Swift-owned Pico `async_context` scheduler
- manual runtime polling from sync `main`

That is the current working model.
