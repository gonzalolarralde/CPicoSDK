# Clean-Room Prompt: Embedded Swift Concurrency Scheduler

You are implementing the embedded Swift concurrency scheduler for CPicoSDK. Do
not treat the existing scheduler internals as authoritative. Preserve the public
surface and the required `_Concurrency` integration points, but choose whatever
internal architecture makes the tests pass and produces the best benchmark
scores.

## Public Surface To Preserve

Keep these APIs source-compatible:

- `ConcurrencyRuntime.startMulticore()`
- `Configurator.core1Enabled`
- `CPUStats.enabled`
- `CPUStats.usageEvents(for:)`
- `CPUStats.usageEvents()`
- `_spi(Internal) callWithAsyncContext(_:)` while any existing helper still
  needs an async-context pointer.

Do not add public app-facing scheduler APIs unless tests or existing CPicoSDK
behavior require them.

## Required `_Concurrency` Boundary

The runtime hooks in `ConcurrencyShims.c` are the required entrypoints from
Swift `_Concurrency` into this package:

- `swift_task_enqueueGlobalImpl`
- `swift_task_enqueueMainExecutorImpl`
- `swift_task_enqueueGlobalWithDelayImpl`
- `swift_task_enqueueGlobalWithDeadlineImpl`
- `swift_task_donateThreadToGlobalExecutorUntilImpl`
- `swift_task_asyncMainDrainQueueImpl`
- executor/isolation hooks such as `swift_task_checkIsolatedImpl`,
  `swift_task_isIsolatingCurrentContextImpl`, and main-executor helpers.

Those hooks may call C, Swift, or mixed scheduler code. The scheduler must
eventually call `swift_job_run(job, executorFirst, executorSecond)` exactly once
for every runnable job accepted from `_Concurrency`.

## Runtime Job Semantics

Implement the scheduler around these invariants:

- Accept immediate, delayed, and deadline jobs from the runtime hooks.
- Resolve job priority with `swift_job_getPriority` through
  `cshims_job_priority`.
- Resolve logical task identity with `cshims_job_owner_task`.
- Jobs with a known task identity must not run concurrently on both cores.
- Jobs with an unknown identity may run concurrently because the scheduler
  cannot serialize them safely.
- Known identities should own a FIFO waiting queue. Completion of an active job
  releases at most one waiting continuation for that identity.
- Priority ordering applies among runnable jobs from different identities, not
  within one identity's private FIFO continuation order.
- Do not drop Swift jobs. Fixed-size queues may fatal on overflow for v1.

## Core And Timer Behavior

- Core0 is the only scheduler consumer until
  `ConcurrencyRuntime.startMulticore()` is called.
- `startMulticore()` must launch core1 with the scheduler-owned stack exposed by
  `cshims_scheduler_core1_stack_bottom()` and
  `cshims_scheduler_core1_stack_size_bytes()`.
- Core1 must clear inherited Swift runtime current-task state before running
  scheduler work.
- Both cores should compete for globally runnable jobs once multicore is
  enabled.
- Delayed/deadline jobs must not run Swift code in IRQ context. Timer firing
  should make the job enter the same runnable path used by immediate jobs.
- You may use Pico alarms, `async_context`, custom rings, `queue_t`,
  `multicore_fifo` wake nudges, direct C execution, Swift execution, or a hybrid
  design. Choose based on correctness and measured score.

## CPU Usage Metrics

Keep the CPU metrics surface working when `CPUMetrics` is enabled:

- `CPUStats.usageEvents(for:)` reports samples for the requested core.
- `CPUStats.usageEvents()` reports samples for all active cores.
- Preserve task, interrupt, idle, total-time, interrupt-event, and memory-stat
  fields.
- Preserve interrupt entry/exit cdecl hooks used by `IRQWrappers.c`.
- IRQ wrapping may be approximate, but existing CPU stats tests must pass and
  reports must remain coherent.

## Optimization Target

Do not remove tests. The implementation is successful only when the existing
device tests pass and score runs improve or hold steady.

Use repeated runs:

```sh
swift package --disable-sandbox test-in-device --filter SchedulerMulticoreBenchmarks --passes 10 --allow-writing-to-package-directory --allow-network-connections all
```

Primary score:

- `bench-multi-throughput workPerSecond`

Secondary scores:

- `bench-continuation resumptionsPerSecond`
- `bench-yield-cadence totalWork`
- `bench-allocation allocationWorkPerSecond`
- `bench-priority priorityWeight`
- `bench-burst lastWorkerLatencyUs`
- `bench-alarm-jitter averageWakeLatenessUs`
- memory growth/loss metrics

Use averages and p95 values, not single runs, to decide whether a change is an
improvement.

## Known Starting Point

This branch intentionally contains a compile-only scheduler shell. Runtime paths
fatal with messages beginning:

```text
[CPicoConcurrency] clean-room scheduler shell:
```

Replace those shells with a real implementation. The prompt above is the
contract; the shell code is only a linkable starting point.
