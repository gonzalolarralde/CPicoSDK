To continue this session, run codex resume 019d65c7-0fcd-7c43-a861-3564cee97b50


# Swift Embedded Concurrency Shim Notes

This document captures the current state of `Sources/CShims/ConcurrencyShims.c`, what was changed, what is confirmed, what is still uncertain, and the upstream Swift ABI references that were used to get here.

The current direction is no longer "fake enough of the whole runtime to make custom executors work." The working setup is:

- use the toolchain-provided `libswift_Concurrency.a`
- provide a very small Pico-specific hook layer in `Sources/CShims/ConcurrencyShims.c`
- drive the runtime queue manually from synchronous `main`
- avoid custom executors for now

## Scope

This notes file is only about:

- `Sources/CShims/ConcurrencyShims.c`
- the embedded `_Concurrency` ABI surface that Swift-generated code expects
- the runtime hook layer required to make generic embedded concurrency run on Pico

It is explicitly not about:

- changing generated Pico SDK headers
- changing Swift compiler output
- matching every detail of the upstream Swift runtime
- making custom executors work on this toolchain

The user explicitly asked not to "fix" generated headers just because host Clang or Swift module importing disagreed with them. Work since then has stayed confined to the concurrency shim.

## Current status

At the time of writing:

- The project links against the toolchain's embedded [libswift_Concurrency.a](/Users/gonzalo/Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2026-04-01-a.xctoolchain/usr/lib/swift/embedded/armv7em-none-none-eabi/libswift_Concurrency.a).
- `Sources/CShims/ConcurrencyShims.c` supplies only the small platform/executor hook surface that archive expects.
- A synchronous `main` can now launch a plain `Task { ... }` and make progress by repeatedly calling `cshims_swift_task_poll_once()`.
- Plain async/await and continuations are therefore working far enough to run real code on device.
- Custom executors are not currently usable on this toolchain/target.

The working entry pattern is:

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

and `asyncMain` must not be isolated to a custom executor / global actor backed by `SerialExecutor`.

## Most important conclusion

The earlier assumption that a custom `SerialExecutor` would let us bypass the low-level C/runtime surface was wrong for this toolchain.

What actually happens:

- `Task { ... }` still goes through the embedded Swift concurrency runtime.
- The runtime uses low-level hooks like `swift_task_enqueueGlobalImpl`, `swift_task_getMainExecutorImpl`, and `swift_job_run`.
- A custom actor backed by a custom `SerialExecutor` eventually reaches `swift_task_enqueueImpl`.
- On this embedded runtime, that path traps with `swift_unreachable`.

Debugger evidence:

- after switching the app to poll `cshims_swift_task_poll_once()`, the task started running
- but any `@PicoActor` / custom executor path hit:
  - `swift_task_enqueueImpl`
  - `swift_unreachable`
  - hardfault

Conclusion:

- generic embedded concurrency works
- custom executors do not work here yet
- keep the runtime on the generic executor path for now

## What changed in `ConcurrencyShims.c`

### 1. The old fake-runtime implementation was discarded

Earlier versions tried to fake large parts of Swift task layout and runtime behavior in C.

That approach turned out to be the wrong direction once it became clear that:

- the embedded toolchain already ships `libswift_Concurrency.a`
- the missing piece is mostly the platform hook surface and queue driving

The current file is a clean replacement, not an evolution of the fake-task code.

### 2. The file is now a minimal runtime hook layer

The current shim provides:

- a tiny single-queue scheduler for runtime-enqueued jobs
- implementations of the required `...Impl` executor hooks
- a few utility/runtime stubs that `libswift_Concurrency.a` references

The important exported hooks are:

- `swift_task_enqueueGlobalImpl`
- `swift_task_enqueueMainExecutorImpl`
- `swift_task_enqueueGlobalWithDelayImpl`
- `swift_task_enqueueGlobalWithDeadlineImpl`
- `swift_task_donateThreadToGlobalExecutorUntilImpl`
- `swift_task_getMainExecutorImpl`
- `swift_task_isMainExecutorImpl`
- `swift_task_checkIsolatedImpl`
- `swift_task_isIsolatingCurrentContextImpl`
- `swift_task_asyncMainDrainQueueImpl`

It also provides tiny helper shims for:

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

### 3. The queue that matters is the C runtime queue

One of the biggest turning points was realizing that the app was pumping the wrong queue.

What happened:

- `Task { ... }` created work via the embedded runtime
- the runtime called `swift_task_enqueueGlobalImpl`
- the shim stored the job in its C queue
- the app was polling a separate Swift-side queue from `PicoSerialExecutor`

So tasks were being created and enqueued correctly, but never drained.

Switching the main loop to:

```swift
while true {
    _ = cshims_swift_task_poll_once()
}
```

immediately changed the behavior from "nothing happens" to "task runs far enough to hit custom-executor limitations."

### 4. The finalize plugin now auto-links the correct Swift archive

`Plugins/FinalizeBinaryPlugin/FinalizeBinaryPlugin.swift` was updated so `getExtraSwiftArchives(from:)` detects concurrency runtime symbol usage and links:

- `libswift_Concurrency.a`

The default executor archive is intentionally not linked:

- `libswift_ConcurrencyDefaultExecutor.a`

because it pulls in host-style timing / libc++ / POSIX dependencies such as:

- `std::chrono`
- `_nanosleep`
- `__error`

Those are not the right abstraction for the Pico target.

### 5. The finalize CMake harness now links archives as a group

The linker originally failed even though the shim implementations were present in `libExample.a`.

That turned out to be a static archive order problem:

- `libExample.a` provided the shim symbols
- `libswift_Concurrency.a` referenced them later
- GNU ld would not go back and re-scan earlier archives

The harness now wraps the app archive plus extra Swift archives in:

- `-Wl,--start-group`
- `-Wl,--end-group`

so the symbols can resolve in both directions.

## Parts that are reasonably confirmed

These are not guesses anymore; they are backed either by debugger observations or by direct upstream/runtime evidence.

### A. The embedded toolchain already provides the core concurrency runtime

Checked locally with `nm` on:

- [libswift_Concurrency.a](/Users/gonzalo/Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2026-04-01-a.xctoolchain/usr/lib/swift/embedded/armv7em-none-none-eabi/libswift_Concurrency.a)

It already exports symbols like:

- `swift_task_alloc`
- `swift_task_dealloc`
- `swift_task_switch`
- `swift_task_create`
- `swift_job_run`
- `swift_continuation_init`
- `swift_continuation_await`
- `swift_continuation_throwingResume`

So the main requirement is not "reimplement the runtime", but "supply the environment/hooks it expects."

### B. The app really is using the runtime queue

Confirmed in the debugger:

- `Task { ... }` breakpoint hits
- `swift_task_create` hits
- `swift_task_enqueueGlobalImpl` hits

That proves generic task creation and runtime enqueue are happening.

### C. Polling the Swift-side custom executor queue was wrong

Confirmed behavior:

- polling `PicoConcurrency.pollOnce()` did not reach `cshims_swift_task_poll_once()`
- switching the main loop to call `cshims_swift_task_poll_once()` made the task run

Conclusion:

- the active runtime queue is the C shim queue
- the Swift `PicoSerialExecutor` queue was a separate, mostly irrelevant queue for this path

### D. Custom executors currently trap on this embedded runtime

Confirmed via stack trace:

- the program runs when using plain `Task { ... }`
- when trying to use `@PicoActor` / custom executor isolation, execution reaches:
  - `swift_task_enqueueImpl`
  - `swift_unreachable`
  - hardfault

Conclusion:

- this runtime/toolchain combination supports generic concurrency paths
- it does not support the custom executor path we tried to use

### C. Closure entry decoding as a raw absolute function pointer was wrong

Evidence:

- `entry->function` interpreted directly looked like `0xf0009961`
- calling it as absolute code caused hardfault
- decoding it as signed relative from the closure record produced `0x1000b851`, which is a plausible Thumb flash address

Conclusion:

- the closure record contains a compact/relative function reference, not a native absolute function pointer

### D. `stdatomic.h` cannot be relied on in this environment

Evidence:

- embedded compile failed in `<stdatomic.h>` with many missing integer typedefs

Conclusion:

- avoiding `<stdatomic.h>` in this shim is the correct short-term move

### E. Thread-local storage cannot be relied on in this environment

Evidence:

- linker errors for `__tls_get_addr`

Conclusion:

- `_Thread_local` is not viable here for the current runtime shim

## Parts that are still uncertain

These are the likely remaining problem areas.

### 1. Initial async frame layout

This is currently the biggest open item.

We now allocate `initialContextSize`, but the shim still does only minimal initialization:

- `context->parent = NULL`
- `context->resumeParent = completeFutureTask` or `completeTaskWithClosure`

This may be insufficient.

The generated async function may expect additional frame/header fields in that initial context memory beyond the minimal `AsyncContext` prefix.

Symptoms that would fit:

- the task no longer crashes immediately
- stepping into the async entrypoint behaves strangely
- code does not appear to run or complete normally

### 2. Result buffer handling for future tasks

In the debugger, one observed future prefix had:

- `indirectResult = 0x0`

That may be fine if the async function has no indirect result requirement for this case. It may also be wrong if the future path expects storage and our `ResultTypeInfo` discovery is incomplete.

Needs confirmation:

- what is `resultTypeInfo.size` at task creation for the relevant call?
- should this closure be indirect-result or direct-result?

### 3. Generic `Job` layout correctness

The local `SwiftJob` is still a pragmatic ABI guess, not a verified exact struct definition for this toolchain build.

What seems good enough so far:

- the generic/fake-task split avoids the worst miscasts
- the invoke slot now has the right conceptual union

What is still uncertain:

- exact offsets for `runJob`
- exact header layout for all enqueued non-task jobs

If generic jobs become important later, this may need a stricter ABI copy from upstream headers.

### 4. Continuation / future wait semantics

The continuation and future-wait portions are still intentionally minimal. They may be logically wrong even if they are now ABI-shaped.

Areas most likely to be incomplete:

- `swift_continuation_init`
- `swift_continuation_await`
- `swift_continuation_resume`
- `swift_task_future_wait`
- `swift_task_future_wait_throwing`

The current implementation is closer to "plausible serial scheduler behavior" than "verified Swift runtime behavior".

### 5. Whether `swift_task_create_common` is being used in the same way as upstream

The local `swift_task_create_common` is not a real port of upstream allocation logic. It is a simplification.

Upstream uses:

- richer task/job flags
- larger header fragments
- allocator slab logic
- task executor preference handling
- task status / future fragments

The local version only preserves the minimum shape needed to get farther into execution.

## What the current file is trying to do

The current model is:

- maintain a tiny serial queue of opaque jobs
- fabricate a local fake `SwiftAsyncTask` for tasks we create ourselves
- let generic runtime jobs stay opaque and invoke them through the generic job callback
- keep a global "current task" and "current executor"
- use `swift_task_asyncMainDrainQueue()` as the main serial event loop

This is not a full runtime. It is a compatibility shell around:

- task creation
- basic queueing
- completion
- some continuation/wait handling

## The current debugger-guided timeline

This is the rough order of failures and fixes so far.

1. Initial complaint: async runtime signatures in `ConcurrencyShims.c` looked wrong.

2. Confirmed by comparison with Swift's runtime function database:

- several signatures did not match `RuntimeFunctions.def`
- especially around executors, task creation, and continuation functions

3. A first round of "shape fixes" was made.

4. User found crashes and pointed out suspicious queueing.

5. Re-check showed major semantic bugs:

- fabricated task/context confusion
- pointer-probing to find callbacks
- continuation context treated as a task

6. Rewrote the file into a minimal serial executor with local fake task structs.

7. Build failed on `<stdatomic.h>`.

8. Replaced atomics with interrupt-guarded state helpers.

9. Link failed on:

- `swift_task_getMainExecutor`
- `__tls_get_addr`

10. Fixed by:

- removing accidental internal linkage for `swift_task_getMainExecutor`
- removing thread-local globals

11. Debugger showed garbage `task->job` values.

12. Fixed by:

- treating queued entries as opaque jobs
- tagging local fake tasks
- splitting generic `runJob` from fake-task `resumeTask`

13. Debugger showed `job == 0x1` in `swift_job_run`.

14. Fixed by:

- adding `swiftcall` / `swiftasynccall`
- exploding executor arguments instead of passing a C struct

15. Debugger then reached `future_adapter` but crashed calling a bogus absolute function pointer.

16. Fixed by:

- decoding `closureEntry` as a closure record
- using `expectedContextSize`
- decoding compact relative function references

17. Current state:

- no immediate hardfault at that point
- async entrypoint now looks plausible
- still not confirmed to execute useful user code end-to-end

## Concrete debugger checks that were useful

If continuing this work, these are the best probes.

### At `swift_task_create`

Inspect:

- `closureEntry`
- first few machine words at `closureEntry`
- decoded function value
- decoded expected context size
- returned `created.task`
- returned `created.context`

Why:

- this confirms whether the closure record decode is still correct
- this confirms whether initial context allocation size matches what the compiler encoded

### At `swift_job_run`

Inspect:

- `job`
- `executorFirst`
- `executorSecond`
- whether the fake-task path or generic-job path is taken

Why:

- this distinguishes ABI mismatch from deeper runtime logic issues

### At `future_adapter`

Inspect:

- `prefix->asyncEntryPoint`
- `prefix->closureContext`
- `prefix->indirectResult`
- `context`
- memory around `context`

Why:

- this tells whether the remaining issue is entrypoint, result storage, or initial frame contents

### At completion / suspension points

Breakpoints:

- `completeFutureTask`
- `completeTaskWithClosure`
- `swift_task_switch`
- `swift_continuation_await`
- `swift_continuation_resume`

Why:

- this determines whether the async entrypoint is actually running and then suspending/completing

## Upstream references that were most useful

These were the primary references used to reconstruct the ABI shape.

### Swift runtime function database

Useful for exported symbol names, calling conventions, and argument shapes.

- `RuntimeFunctions.def` on Fossies:
  - https://fossies.org/linux/swift-swift/include/swift/Runtime/RuntimeFunctions.def

This was especially useful for confirming:

- `swift_task_create`
- `swift_task_switch`
- `swift_continuation_init`
- `swift_continuation_await`
- `swift_continuation_resume`
- executor-returning functions

### Swift `Task.cpp`

Useful for behavior and the high-level shape of task creation and job running.

- `Task.cpp` on Fossies:
  - https://fossies.org/linux/swift-swift/stdlib/public/Concurrency/Task.cpp

This was especially useful for:

- seeing `swift_job_run(this, SerialExecutorRef::generic())`
- task completion flow
- non-future and future adapters
- `swift_task_create`
- `swift_task_create_common`
- closure entry unpacking

### Swift `Executor.h`

Useful for the ABI of executors and async function pointers.

- `Executor.h` on Fossies:
  - https://fossies.org/dox/swift-swift-6.1.2-RELEASE/include_2swift_2ABI_2Executor_8h_source.html

Most important details found there:

- `SerialExecutorRef` is two words:
  - identity
  - implementation/witness
- `TaskContinuationFunction` is `swiftasync`
- `JobInvokeFunction` is `swiftasync`
- `AsyncFunctionPointer` contains:
  - a compact function reference
  - `uint32_t ExpectedContextSize`

### Swift `Task.h`

Useful conceptually, although the local file is still a partial approximation.

The direct GitHub tree wasn’t available through the local filesystem/toolchain, but upstream references from searches and Fossies were used to confirm:

- `Job`
- `AsyncTask`
- `AsyncContext`
- continuation/future concepts

## Searches that turned out useful

These are the most relevant search queries used while narrowing things down.

### Runtime function signatures

- `site:fossies.org RuntimeFunctions.def swift_task_create`
- `site:fossies.org RuntimeFunctions.def swift_task_switch`
- `site:fossies.org RuntimeFunctions.def swift_continuation_init`
- `site:fossies.org RuntimeFunctions.def swift_job_run`

### Swift runtime implementation

- `fossies swift_task_run_inline Task.cpp`
- `fossies swift_task_create_common Task.cpp`
- `fossies swift_job_run Task.cpp`

### ABI types

- `site:fossies.org swift ABI Executor.h AsyncFunctionPointer ExpectedContextSize`
- `site:fossies.org swift ABI Executor.h JobInvokeFunction`
- `site:fossies.org swift ABI Executor.h TaskContinuationFunction`

## Important local assumptions

These assumptions are currently baked into the shim.

### Assumption 1: single serial execution context

The current executor is global, not thread-local.

This is deliberate and appropriate for the present bare-metal single-executor model.

### Assumption 2: generic executor can be treated as main executor

The shim currently normalizes generic executor requests to the local main executor sentinel.

This is a simplification, not a full Swift runtime behavior model.

### Assumption 3: fake tasks can be tagged by metadata pointer

The local task discrimination relies on:

```c
task->job.header.metadata = &gFakeTaskMetadataTag;
```

This is a private marker only used by the shim.

### Assumption 4: interrupt-guarded state changes are enough for the continuation state machine

For this current serial Pico model, this is acceptable.

It would not be sufficient for a real general-purpose Swift runtime.

## Things not to forget if you keep iterating

1. Do not "fix" generated Pico SDK headers as part of this problem unless you really intend to solve a separate header/module issue.

2. Be suspicious of any concurrency export that:

- returns or takes `SwiftExecutorRef` as a plain C aggregate
- lacks `swiftcall`
- stores plain C callbacks into async continuation slots

3. Be suspicious of any code that assumes:

- every queued object is a local fake task
- `closureEntry` is a raw function pointer
- the initial async context is just `sizeof(SwiftAsyncContext)` regardless of closure metadata

4. The next big unknown is likely frame initialization, not outer symbol naming.

## Likely next debugging steps

These would be the next practical checks.

1. Break at the decoded async entrypoint and at `completeFutureTask`.

2. Confirm whether the entrypoint actually runs and whether completion is ever reached.

3. Inspect the memory at `context` before the async entrypoint runs:

- does the function expect more than just `parent` and `resumeParent` to be initialized?

4. Inspect whether the async body calls `swift_task_switch`.

If yes, the next bug is probably in suspend/resume semantics.

5. Inspect `resultTypeInfo.size` for the specific task that "runs but seems to do nothing".

If nonzero while `prefix->indirectResult == NULL`, then result buffer setup is still wrong for that path.

## Summary

The shim is no longer in the completely blind/garbage state.

Confirmed progress:

- executor ABI handling is much closer
- job-vs-task handling is less wrong
- closure entrypoint decoding is materially better
- the code reaches `future_adapter` with plausible values

Still unresolved:

- whether the initial async frame is being initialized correctly
- whether future result storage is sufficient for the actual generated code
- whether the suspend/resume path matches what the generated async function expects

If picking this back up later, start by assuming the remaining issue is inside the initial async frame/task semantics, not in top-level exported symbol names.
