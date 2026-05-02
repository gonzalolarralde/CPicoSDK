# Multicore Concurrency Pass 3

This is a third-pass notebook from the multicore scheduler proof of concept.
Pass 3 moved from "can core1 run any Swift job?" to "can both cores run Swift
jobs without violating Swift task allocator and current-task invariants?"

## What Was Tried

The scheduler used:

- One shared Pico SDK `queue_t` as a scheduler input queue.
- One `async_context_poll_t` per CPU core.
- A task ownership table keyed by scheduler-visible task identity.
- Per-task `queuedCount` and `runningCount` bookkeeping.
- Sticky owner cores while a task has queued or running work.
- Linker-wrapped Swift runtime entry points for current-task and task allocator
  diagnostics.

The intended invariant was:

```text
Jobs belonging to the same Swift task must not be active on both cores at the
same time.
```

That invariant is still useful, but it was not the whole problem.

## Task Migration Versus Current-Task Isolation

A Swift task crossing cores is not inherently wrong. A valid runtime can suspend
a task on one thread or core and later resume it on another, as long as runtime
thread-local state is actually local to the executing thread or core.

The observed failure was different. The embedded Swift runtime build used here
does not provide real per-core storage for Swift concurrency's current-task
state. The relevant runtime state includes `ActiveTask` in
`stdlib/public/Concurrency/Actor.cpp`, exposed through:

```text
swift_task_getCurrent()
_swift_task_setCurrent(...)
_swift_task_clearCurrent()
```

On this target, that "thread-local" state behaved like global storage. The
failure pattern was:

1. Core1 started running Swift task `T`.
2. Core0 entered a Swift runtime path that called `swift_task_alloc`.
3. `swift_task_alloc` asked for `swift_task_getCurrent()`.
4. Core0 observed core1's current task `T`.
5. Core0 allocated from `T`'s task stack/slab allocator while core1 was also
   using task `T`.
6. A later deallocation violated the stack allocator's LIFO rule and hit:

```text
freed pointer was not the last allocation
```

So the dangerous condition is not "task `T` ran on core0 and later ran on
core1." The dangerous condition is "two cores can observe or mutate the same
current-task runtime state at the same time."

## Stack Allocator Finding

The crash came from Swift's task stack/slab allocator, in
`stdlib/public/runtime/StackAllocator.h`.

The task allocator identity is the `AsyncTask *`, not the scheduler's numeric
task id. `swift_task_getJobTaskId(job)` is useful diagnostics, but allocator
ownership follows the `AsyncTask` object.

The important allocator signal was:

```text
jr  c=1 cur=200107C8 job=200107C8 jt=200107C8
tds c=1 cur=200107C8 rt=200107C8 p=200108A0 s=35 ok=1
tap c=0 t=200107C8 p=200108D0 sz=16 s=37
freed pointer was not the last allocation
```

This showed core0 allocating against the same task core1 was running.

## TLS Probe

A small C probe temporarily set current-task state on core0 and core1.

Before current-task wrapping, core1's fake current task leaked into core0:

```text
currentprobe done=1 saved=2000ACC8 c0b=c0000000 c0a=c1000001 c1b=c0000000 c1a=c1000001 leaked=1
```

After wrapping exported current-task entry points, the probe stopped leaking:

```text
currentprobe done=1 saved=2000ACD8 c0b=c0000000 c0a=c0000000 c1b=0 c1a=c1000001 leaked=0
```

This proves the wrapper can protect exported calls. It does not prove that all
Swift runtime internal accesses are fixed.

## Linker-Wrap Experiment

The finalizer CMake harness wrapped these Swift symbols:

```text
swift_task_getCurrent
_ZN5swift22_swift_task_setCurrentEPNS_9AsyncTaskE
_ZN5swift24_swift_task_clearCurrentEv
swift_task_alloc
swift_task_dealloc
swift_task_dealloc_through
swift_continuation_init
swift_continuation_resume
swift_job_run
_ZN5swift26_swift_task_alloc_specificEPNS_9AsyncTaskEj
_ZN5swift28_swift_task_dealloc_specificEPNS_9AsyncTaskEPv
```

The shim keeps a small per-core current-task array indexed by
`get_core_num() & 1`.

This mitigated exported `swift_task_getCurrent()` users and the task allocator
diagnostic path. It is not a complete TLS backend. Linker `--wrap` does not
rewrite same-object references inside Swift runtime object files, so code in
`Actor.cpp` can still directly use the embedded runtime's global `ActiveTask`
storage.

Serial logs still showed the distinction:

```text
jr c=1 cur=200102F8 real=2000ACD8 job=200102F8 jt=200102F8
```

Here `cur` is the shim's per-core current task, while `real` is the original
Swift runtime current task. Seeing `real` cross cores means the runtime build
still lacks true per-core current-task state.

## Scheduler Findings

Task ownership bookkeeping alone was not enough. The shared FIFO input queue
introduced a second issue.

Originally, each core popped one message, checked owner core, and if ownership
did not match, requeued the message and stopped scanning. With a single shared
FIFO and two consumers, core1 could repeatedly pop core0-owned work, requeue it,
and exit without reaching core1-owned messages behind it.

The symptom was:

```text
p1=1 r1=1 d1=<rapidly increasing>
```

That meant core1 was alive and spinning through the input queue, but mostly
deferring owner-mismatched work.

Two scheduler changes improved this:

- Continue scanning a bounded number of input-queue messages after a deferral.
- For jobs with their own `AsyncTask` identity, choose owner by outstanding
  work instead of blindly inheriting the current task's owner. Current-task
  inheritance remains a fallback for jobs without an async-task identity.

After that change, core1 ran more than the seed job:

```text
jr c=1 cur=200107B0 real=2000ACD8 job=200107B0 jt=200107B0
jr c=1 cur=200114B0 real=2000ACD8 job=200114B0 jt=200114B0
jr c=1 cur=200102F8 real=200102F8 job=200102F8 jt=200102F8
```

## Current PoC Status

Pass 3 demonstrates sustained Swift job execution on both cores in the tested
window, without immediately reproducing:

```text
freed pointer was not the last allocation
```

The proof is still provisional:

- The runtime still has internal global current-task state.
- The current linker-wrap approach is a mitigation, not a real TLS backend.
- Serial logging from both cores interleaves heavily and should be reduced for
  longer soak tests.
- The shared FIFO plus scan/requeue model is inefficient. Per-core queues or an
  owner-aware dispatcher would be cleaner.
- A production-quality solution should provide true per-core/thread-local Swift
  concurrency state for embedded RP2350, or rebuild the Swift embedded runtime
  with a threading backend that maps `SWIFT_THREAD_LOCAL_TYPE` correctly.

## Practical Conclusion

Task migration is a desired end goal and is not ruled out by this pass. The
technical limitation observed here is narrower: Swift concurrency's embedded
current-task/TLS implementation is not per-core on this target, and the task
allocator assumes it is. Until that is fixed, arbitrary task migration remains
risky even if scheduler-level task ownership prevents two visible jobs from the
same task running at once.
