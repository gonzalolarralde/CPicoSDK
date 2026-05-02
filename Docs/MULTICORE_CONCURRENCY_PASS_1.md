# Multicore Concurrency Pass 1

This is a first-pass notebook from the multicore scheduler proof of concept.
The attempted implementation was intentionally simple and not expected to be
correct. The useful result is mostly a list of constraints and failure modes for
a cleaner second approach.

## What Was Tried

The initial scheduler was single-core:

- Swift global jobs enqueue into one `async_context_poll_t`.
- Core0 owns that context.
- Delayed jobs and deadline jobs also go through that core0 async context.
- IRQ trampolines use scheduled blocks to re-enter Swift task creation on core0.

The multicore PoC added:

- A C-side core1 FIFO of Swift jobs.
- `multicore_reset_core1()` plus `multicore_launch_core1()` with a C entrypoint.
- Round-robin immediate global jobs between core0 and core1.
- Counters for core1 boots, jobs run, and queue overflows.
- A stress harness in `Example` that creates several Swift tasks and prints the
  executing core plus scheduler counters.

The C-side core1 entry loop looked roughly like:

```c
while (true) {
    if (pop_core1_job(&job)) {
        swift_job_run(job, executorFirst, executorSecond);
    } else {
        sleep_us(50);
    }
}
```

This was enough to prove core1 can receive and enter Swift jobs, but it was not
enough to make arbitrary Swift concurrency safe on core1.

## Build And Test Notes

The example must use the local package path. If `Example/Package.swift` points
at a released remote dependency, local scheduler changes are ignored and logs
will misleadingly show only the old behavior.

Build from `Example/`:

```sh
cd /Users/gonzalo/src/CPicoSDK/Example
./build.sh
```

Flashing with OpenOCD worked more reliably at `adapter speed 1000` after some
hardfaults. `adapter speed 5000` worked before the target got wedged, but after
faults it often failed with:

```text
Error: Error connecting DP: cannot read IDR
```

Serial logs were captured with:

```sh
python3 -m serial.tools.miniterm /dev/tty.usbmodem102 115200
```

The exact serial device is not stable. Enumerate devices first:

```sh
ls -1 /dev/tty.* /dev/cu.* 2>/dev/null
```

## Observed Runtime Behavior

The successful early signal looked like this:

```text
Starting multicore scheduler stress
App loop core=0
stress t=1 i=0 c=0 c0=1 c1=2 j=3 o=0
```

In that line:

- `c0` was the number of stress observations on core0.
- `c1` was the number of stress observations on core1.
- `j` was the C-side count of jobs run on core1.
- `o` was the C-side core1 queue overflow count.

This proved that jobs did reach core1 and execute far enough for Swift code to
observe `get_core_num() == 1`.

The run then became unstable in several different ways depending on which guard
was added.

## Failure Mode: Core1 Mutating Core0 Async Context

The earliest broad round-robin implementation allowed Swift jobs running on
core1 to call `Task.sleep`. The runtime hook for sleep eventually enqueues a
delayed or deadline job.

The original scheduler implementation always put delayed/deadline jobs into the
core0 `async_context_poll_t`. That means code running on core1 could mutate the
core0 async context while core0 was polling it.

This is a bad ownership model. The async context should be treated as owned by
one scheduler/core unless it is explicitly designed and locked for cross-core
access. The current `async_context_poll_t` path should be assumed single-owner.

Takeaway:

- Do not let a job on core1 directly add workers to core0's async context.
- Delayed work needs a same-owner path, a cross-core handoff primitive, or a
  central timer/IRQ owner that wakes the correct core.
- `Task.sleep` is not just a timer; it is also a scheduler enqueue operation.

## Failure Mode: Same-Core Re-Enqueue Loops

One experiment routed delayed jobs created on core1 back into a C-side core1
queue with wake timestamps. This avoided core1 mutating core0's async context.

That uncovered another issue: Swift jobs can re-enqueue null or sentinel jobs
through hooks that this PoC did not understand. GDB showed core1 trying to run:

```text
swift_job_run(job=0x0, executorFirst=0x0, executorSecond=0x0)
```

After adding a null-job guard, the specific null run was avoided, but it did not
make the overall approach correct.

Takeaway:

- Treat `job == NULL` as invalid for this bridge and do not call
  `swift_job_run` with it.
- Do not assume every runtime enqueue hook carries an ordinary runnable job.
- A correct bridge needs a better understanding of Swift's enqueue contracts,
  not just a raw `void *` FIFO.

## Failure Mode: Serializing `swift_job_run`

To avoid concurrent Swift runtime access, one experiment wrapped
`swift_job_run` in a global mutex. This prevented simultaneous entry from core0
and core1.

That made one class of crash less likely, but it introduced a deadlock/stall:

- A long-lived Swift task on core1 entered `swift_job_run`.
- That task awaited/yielded/slept or otherwise did not return promptly.
- The global `swift_job_run` mutex stayed held.
- Core0 could no longer run Swift jobs, so the app stopped after:

```text
Starting multicore scheduler stress
App loop core=0
```

Takeaway:

- `swift_job_run` can run a job that suspends or schedules more work.
- A global mutex around `swift_job_run` is not a viable synchronization model.
- The scheduler must not assume a job is a short, bounded critical section.

## Failure Mode: Running Swift Concurrently

Removing the mutex allowed core0 and core1 to run Swift jobs concurrently. This
unstuck core0, but the runtime/allocator failed quickly:

```text
Starting multicore scheduler stress
freed pointer was not the last allocation
```

GDB also showed hardfaults involving Swift allocation paths and task allocator
slabs. This suggests the current embedded Swift runtime, allocator path, or this
project's allocator integration is not safe for arbitrary concurrent Swift task
execution across both cores.

Takeaway:

- Arbitrary Swift jobs should not be run concurrently on both cores until the
  allocator/runtime invariants are understood and protected.
- A proof of multicore progress needs to distinguish "core1 can execute C" from
  "core1 can execute any Swift task safely."
- The allocator failure can happen before the stress task prints much, so a lack
  of logs does not mean core1 did not start.

## IRQ And Same-CPU Scheduling Notes

The existing IRQ trampoline pattern schedules Swift work back into the runtime
scheduler. In the current implementation, that effectively means core0.

That is a useful property: IRQ-originated Swift work should keep a clear owner.
For pass 1, letting IRQs enqueue onto arbitrary cores would create the same
cross-core context mutation problem as `Task.sleep`.

Relevant sequencing observations:

- IRQ or scheduled-block code may create Swift tasks.
- Creating Swift tasks can allocate.
- Allocating while memory is constrained can itself enter debug print paths,
  which allocate strings and can hardfault or recurse into failure handling.
- CPU metrics are IRQ-backed and report from core0 in the current setup.
- The one-second alarm and `Task.sleep` before enabling multicore worked
  normally, which points at the multicore handoff as the destabilizing step.

For a next pass, prefer a rule like:

- An interrupt on core0 enqueues into core0's scheduler only.
- Any interrupt or wake event that needs to wake core1 should use a small
  C-level signal, FIFO, semaphore, or event flag, not directly mutate a Swift
  async context from the wrong core.
- Delayed work should resume on the same scheduler/core that owns the suspended
  task unless there is an explicit migration protocol.

## Core Affinity Lessons

This PoC treated the global executor as if any global job could move to core1.
That was too broad.

A safer next approach probably needs explicit affinity:

- Core0 remains the only Swift runtime executor initially.
- Core1 starts as a C worker or dedicated executor with a constrained API.
- Only jobs known to be safe for core1 should be submitted there.
- Jobs that touch Swift allocation, task creation, task locals, string
  interpolation, `print`, or `Task.sleep` should initially remain on core0.

Potential forms:

- A dedicated `Core1Executor` for annotated work only.
- A C-only core1 worker queue for compute kernels.
- A mailbox where core1 requests core0 to create/resume Swift tasks.
- A separate scheduler context per core, but with strict ownership and explicit
  cross-core wakeups.

## Logging Lessons

Long serial logs are not the primary cause of the stall, but they make debugging
harder. Short stress lines were more useful:

```text
stress t=1 i=0 c=0 c0=1 c1=2 j=3 o=0
```

Avoid printing from core1 in early experiments. Increment counters on core1 and
print from core0. `print` uses string interpolation and allocation, so it is a
poor primitive for validating allocator-sensitive multicore paths.

Useful low-risk counters:

- core1 boot count
- core1 jobs popped
- core1 null jobs dropped
- core1 queue overflow count
- last core1 job pointer, for GDB inspection
- handoff/wakeup count from core0 to core1

## What A Second Approach Should Avoid

Avoid:

- Running arbitrary Swift global jobs on core1.
- Calling `swift_job_run` concurrently from both cores without runtime support.
- Holding a mutex across `swift_job_run`.
- Letting core1 mutate core0's `async_context_poll_t`.
- Using `Task.sleep` or `Task.yield` inside a core1 Swift stress task as the
  first proof.
- Printing from core1 as part of the core correctness signal.

## What A Second Approach Should Try

Recommended narrower sequence:

1. Launch core1 with a pure C loop.
2. Prove core1 liveness with counters only.
3. Add a C mailbox from core0 to core1.
4. Run pure C compute jobs on core1 and publish results back to core0.
5. Have core0 observe and print the results.
6. Add one explicit Swift-facing API that submits a non-allocating C callback or
   function pointer to core1.
7. Only after that, consider a Swift executor model with clear allocator and
   async-context ownership rules.

For Swift concurrency specifically, investigate whether the embedded runtime can
support multiple threads/cores at all in this configuration. If it cannot, the
correct design may be "Swift tasks on core0, C workers on core1" rather than a
true multicore Swift global executor.

## Device Debugging Notes

The practical hardware workflow that worked best:

```sh
cd /Users/gonzalo/src/CPicoSDK/Example
./build.sh
```

Flash with OpenOCD at 1000 kHz:

```sh
/Users/gonzalo/src/CPicoSDK/Example/.build/plugins/PrepareEnvironmentPlugin/outputs/pico-sdk-bundle/openocd/0.12.0+dev/openocd.exe \
  -c "gdb_port 50000" \
  -c "tcl_port 50001" \
  -c "telnet_port 50002" \
  -s /Users/gonzalo/src/CPicoSDK/Example/.build/plugins/PrepareEnvironmentPlugin/outputs/pico-sdk-bundle/openocd/0.12.0+dev/scripts \
  -f /Users/gonzalo/.vscode/extensions/marus25.cortex-debug-1.12.1/support/openocd-helpers.tcl \
  -f interface/cmsis-dap.cfg \
  -f target/rp2350.cfg \
  -c "adapter speed 1000" \
  -c "program /Users/gonzalo/src/CPicoSDK/Example/.build/armv7em-none-none-eabi/release/Example.elf verify reset exit"
```

Open serial:

```sh
python3 -m serial.tools.miniterm /dev/tty.usbmodem102 115200
```

Then reset with OpenOCD:

```sh
/Users/gonzalo/src/CPicoSDK/Example/.build/plugins/PrepareEnvironmentPlugin/outputs/pico-sdk-bundle/openocd/0.12.0+dev/openocd.exe \
  -c "gdb_port 50000" \
  -c "tcl_port 50001" \
  -c "telnet_port 50002" \
  -s /Users/gonzalo/src/CPicoSDK/Example/.build/plugins/PrepareEnvironmentPlugin/outputs/pico-sdk-bundle/openocd/0.12.0+dev/scripts \
  -f /Users/gonzalo/.vscode/extensions/marus25.cortex-debug-1.12.1/support/openocd-helpers.tcl \
  -f interface/cmsis-dap.cfg \
  -f target/rp2350.cfg \
  -c "adapter speed 1000" \
  -c "init" \
  -c "reset run" \
  -c "exit"
```

When the target hardfaulted, OpenOCD sometimes lost DP access until the board
was physically reconnected.

