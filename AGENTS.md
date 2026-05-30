# Agent Device Workflow

This repo has a hardware-oriented example workflow. For this project, build and
device commands should be run from `Example/` unless noted otherwise.

When a debugging session produces a reusable general workflow lesson, add it to
this file under `Debugging Tips Log`. Classify each tip by area, such as
code/Swift, USB connection, OpenOCD/GDB, serial/RTT logging, build/package
wiring, or another specific category that fits the issue. Keep the tip concrete:
include the symptom, the command or code pattern that helped, and any known
limitation. Keep feature-specific investigation notes in `docs/`.

## Root Device Test Harness

The repo-root device test harness is the main exception to the `Example/`
working-directory rule. Its contributor documentation lives in
`README.md` under `Device Test Harness`, and test sources live under
`Tests/Device/**/*.swift`.

List available device tests from the repo root:

```sh
swift package --disable-sandbox test-in-device --list --allow-writing-to-package-directory --allow-network-connections all
```

Check that device tests generate, compile, and link without programming
hardware:

```sh
swift package --disable-sandbox test-in-device --build-only --allow-writing-to-package-directory --allow-network-connections all
```

Run the physical-device suite from the repo root only after confirming with the
user that a compatible board and CMSIS-DAP/OpenOCD probe are connected and that
it is OK to program the board:

```sh
swift package --disable-sandbox test-in-device --allow-writing-to-package-directory --allow-network-connections all
```

For focused checks, prefer `--filter <TestName>` before running all tests. Run
`--build-only` often when adding tests or changing device-facing CPicoSDK
behavior, traits, concurrency support, generated package wiring, finalization,
or linking. Run the physical tests occasionally when changing OpenOCD/RTT
capture or the harness itself. For documentation-only changes, do not program
the device unless the user asks for it.

## Build

Do not run a repo-root `./build`. Build the example like this:

```sh
cd Example
./build.sh
```

The build artifact used for flashing is:

```text
Example/.build/armv7em-none-none-eabi/release/Example.elf
```

The corresponding UF2 is in the same directory:

```text
Example/.build/armv7em-none-none-eabi/release/Example.uf2
```

## Finding Tool Binaries

Run `./build.sh` from `Example/` first. The build prepares the Pico SDK bundle
and cross toolchain under `Example/.build/plugins/PrepareEnvironmentPlugin`.

Find OpenOCD:

```sh
cd Example
find .build/plugins/PrepareEnvironmentPlugin/outputs \( -type f -o -type l \) \
  \( -name openocd.exe -o -name openocd \)
```

Find the OpenOCD scripts directory:

```sh
cd Example
find .build/plugins/PrepareEnvironmentPlugin/outputs -type d -path '*/openocd/*/scripts'
```

Find GDB and related ARM toolchain utilities:

```sh
cd Example
find .build/plugins/PrepareEnvironmentPlugin/outputs -type f \
  \( -name arm-none-eabi-gdb -o -name arm-none-eabi-addr2line -o -name arm-none-eabi-nm \)
```

Set shell variables from the discovered paths before running debug commands:

```sh
cd Example
ELF=".build/armv7em-none-none-eabi/release/Example.elf"
OPENOCD="$(find .build/plugins/PrepareEnvironmentPlugin/outputs \( -type f -o -type l \) \( -name openocd.exe -o -name openocd \) -print -quit)"
OPENOCD_SCRIPTS="$(find .build/plugins/PrepareEnvironmentPlugin/outputs -type d -path '*/openocd/*/scripts' -print -quit)"
ARM_GDB="$(find .build/plugins/PrepareEnvironmentPlugin/outputs -type f -name arm-none-eabi-gdb -print -quit)"
ARM_ADDR2LINE="$(find .build/plugins/PrepareEnvironmentPlugin/outputs -type f -name arm-none-eabi-addr2line -print -quit)"
ARM_NM="$(find .build/plugins/PrepareEnvironmentPlugin/outputs -type f -name arm-none-eabi-nm -print -quit)"
OPENOCD_HELPERS="$(find "$HOME/.vscode/extensions" -path '*/support/openocd-helpers.tcl' -print -quit 2>/dev/null)"
```

The Cortex-Debug OpenOCD helper script is optional for command-line debugging.
If `OPENOCD_HELPERS` is empty, remove the `-f "$OPENOCD_HELPERS"` argument from
the OpenOCD examples below.

## OpenOCD

The OpenOCD binary and script bundle come from the example build output. Use
the variables from `Finding Tool Binaries`.

```sh
"$OPENOCD" \
  -c "gdb_port 50000" \
  -c "tcl_port 50001" \
  -c "telnet_port 50002" \
  -s "$OPENOCD_SCRIPTS" \
  -f "$OPENOCD_HELPERS" \
  -f interface/cmsis-dap.cfg \
  -f target/rp2350.cfg \
  -c "adapter speed 5000"
```

Leave that command running when you want persistent GDB or telnet access.

If the target has recently hardfaulted or OpenOCD reports
`Error connecting DP: cannot read IDR`, retry with `adapter speed 1000` before
assuming the wiring or probe is wrong. Some wedged states still require a
physical reconnect or power-cycle of the board before OpenOCD can regain DP
access.

If stale OpenOCD processes are holding ports, stop them with:

```sh
pkill -f /openocd.exe
```

## Flash

After building from `Example/`, flash the ELF with:

```sh
"$OPENOCD" \
  -c "gdb_port 50000" \
  -c "tcl_port 50001" \
  -c "telnet_port 50002" \
  -s "$OPENOCD_SCRIPTS" \
  -f "$OPENOCD_HELPERS" \
  -f interface/cmsis-dap.cfg \
  -f target/rp2350.cfg \
  -c "adapter speed 5000" \
  -c "program $ELF verify reset exit"
```

During fault-recovery sessions, use the same command with
`-c "adapter speed 1000"`. The slower adapter speed can be more reliable after
hardfaults.

To reset without reflashing, include `init` before `reset run`:

```sh
"$OPENOCD" \
  -c "gdb_port 50000" \
  -c "tcl_port 50001" \
  -c "telnet_port 50002" \
  -s "$OPENOCD_SCRIPTS" \
  -f "$OPENOCD_HELPERS" \
  -f interface/cmsis-dap.cfg \
  -f target/rp2350.cfg \
  -c "adapter speed 5000" \
  -c "init" \
  -c "reset run" \
  -c "exit"
```

Without `init`, one-shot OpenOCD reset commands can fail with
`invalid command name "reset"`.

If reset commands keep failing after a hardfault, physically reconnect the board
and then rerun OpenOCD at `adapter speed 1000`.

## Serial Logs

Make sure `pyserial` is installed before using `miniterm`:

```sh
python3 -m pip show pyserial
```

If that fails, install it:

```sh
python3 -m pip install pyserial
```

Find likely serial devices on macOS:

```sh
ls -1 /dev/tty.* /dev/cu.* 2>/dev/null
```

Useful candidates usually look like one of these:

```text
/dev/tty.usbmodem*
/dev/cu.usbmodem*
/dev/tty.usbserial-...
/dev/cu.usbserial-...
```

Prefer a `tty.usbmodem*`, `cu.usbmodem*`, `tty.usbserial*`, or
`cu.usbserial*` device that appeared after plugging in or resetting the board.
The exact suffix is not stable, so do not hard-code a specific device name.

Connect by substituting the selected device path:

```sh
SERIAL_DEVICE="$(ls -1 /dev/tty.usbmodem* /dev/cu.usbmodem* /dev/tty.usbserial* /dev/cu.usbserial* 2>/dev/null | head -n 1)"
python3 -m serial.tools.miniterm "$SERIAL_DEVICE" 115200
```

Exit miniterm with `Ctrl-]`.

A useful boot-log capture pattern is:

1. Start `miniterm`.
2. In another shell, run the reset-only OpenOCD command above.
3. Watch serial output from boot.

RTT stdio is enabled in the example via `StdIO_RTT`, but USB serial on
the discovered `/dev/tty.*` or `/dev/cu.*` device was also useful for logs.

Serial output can include stale or interleaved bytes after reset. Prefer short
log lines and sanity-check that a fresh boot banner appears.

## OpenOCD Telnet

When the persistent OpenOCD process is running, use telnet port `50002` through
`nc`.

Check target state:

```sh
/bin/zsh -lc "{ sleep 1; printf 'targets\r\nrp2350.cm0 curstate\r\nrp2350.cm1 curstate\r\nexit\r\n'; sleep 1; } | nc 127.0.0.1 50002"
```

Reset through the telnet server:

```sh
/bin/zsh -lc "{ sleep 1; printf 'reset run\r\nexit\r\n'; sleep 1; } | nc 127.0.0.1 50002"
```

Check RTT state:

```sh
/bin/zsh -lc "{ sleep 1; printf 'rtt status\r\nrtt channels\r\nexit\r\n'; sleep 1; } | nc 127.0.0.1 50002"
```

The telnet reset form assumes OpenOCD is already initialized and running.

## GDB

With persistent OpenOCD running, attach and collect basic state:

```sh
"$ARM_GDB" \
  "$ELF" \
  -ex "target remote 127.0.0.1:50000" \
  -ex "monitor halt" \
  -ex "info threads" \
  -ex "thread apply all bt" \
  -ex "detach" \
  -ex "quit"
```

The local sandbox may block GDB TCP connections with `Operation not permitted`.
If that happens, rerun the same GDB command with elevated permissions.

Debug info warnings about missing DWO/PCH files or `.debug_names` are not
necessarily fatal; GDB can still provide useful thread PCs and backtraces.

For address lookup, use the bundled `addr2line`:

```sh
"$ARM_ADDR2LINE" \
  -f \
  -e "$ELF" \
  0x10005e74
```

For symbols:

```sh
"$ARM_NM" \
  -n \
  "$ELF"
```

GDB may show PCs without the flash base, for example `0x00005e74`. For
`addr2line`, interpret that as `0x10005e74`.

## Debugging Tips Log

Add new reusable general debugging lessons here, grouped by category. Prefer
specific symptoms and exact commands over broad advice. Put feature-specific
design notes, experiments, and failure analysis in `docs/`.

### USB Connection

- Serial device suffixes are not stable. Discover devices with
  `ls -1 /dev/tty.* /dev/cu.* 2>/dev/null` and pick the `usbmodem` or
  `usbserial` device that appeared after plugging in or resetting the board.
- After a hardfault or bad device run, OpenOCD may fail with
  `Error connecting DP: cannot read IDR`. Try `adapter speed 1000`; if it still
  cannot connect, physically reconnect or power-cycle the board.

### OpenOCD And GDB

- Keep a persistent OpenOCD process running for repeated telnet/GDB operations.
  Use telnet port `50002` through `nc` for quick `reset run`, target-state, and
  RTT checks.
- If OpenOCD exits with `Error: unable to find a matching CMSIS-DAP device`,
  the harness reached the host debug layer but no compatible probe was visible.
  If the same OpenOCD command works in a normal shell, rerun command-plugin
  device tests as `swift package --disable-sandbox test-in-device ...`; the
  SwiftPM plugin sandbox can hide USB debug probes from OpenOCD.
- `Error: unable to find a matching CMSIS-DAP device` happens before OpenOCD
  talks to the target. Check that the CMSIS-DAP probe is visible over USB and
  use the discovered `openocd.exe` path from `Example/.build/...`; changing
  `adapter speed` only helps later target-connect failures such as
  `cannot read IDR`.
- For one-shot reset commands, include `-c "init"` before `-c "reset run"`.
  Without `init`, OpenOCD can report `invalid command name "reset"`.
- If ports are already bound by stale debug sessions, use
  `pkill -f /openocd.exe` before starting OpenOCD again.
- If a stale OpenOCD process is holding the CMSIS-DAP USB interface, a second
  OpenOCD instance on alternate ports can still fail with
  `could not claim interface: Access denied`. Stop the original session or
  physically reconnect the probe before retrying flash.
- In this workspace, the known-good OpenOCD launcher is the `openocd.exe`
  symlink under
  `Example/.build/plugins/PrepareEnvironmentPlugin/outputs/pico-sdk-bundle/openocd/0.12.0+dev/`.
  A `find -type f -name openocd.exe` command misses it because it is a symlink;
  include `-type l` or use that exact `openocd.exe` path when CMSIS-DAP probing
  unexpectedly fails with the plain `openocd` path.
- GDB may print missing DWO/PCH or `.debug_names` warnings. Those warnings are
  not necessarily fatal; `info threads` and `thread apply all bt` can still
  provide useful PCs and backtraces.
- For RP2350 `NOCP` hard faults, decode the exception frame before assuming the
  visible PC is random. Symptom: core halts in a default ISR breakpoint,
  `HFSR=0x40000000`, and `CFSR` has bit 19 set; the stacked PC points at a VFP
  instruction such as `vpush {d8}` in an IRQ handler. Use GDB or telnet `mdw`
  to check `CPACR` at `0xe000ed88` and fault registers at `0xe000ed28` and
  `0xe000ed2c`. On RP2350 Arm builds using VFP instructions, `CPACR` must
  include CP10 and CP11 access bits; a healthy checked value was
  `0x00f0c303`, with `CFSR/HFSR` clear while both cores were running.
- After a batch GDB snapshot, verify that the target resumed. Symptom:
  OpenOCD telnet `targets` shows both `rp2350.cm0` and `rp2350.cm1` still
  halted after `detach`. Resume through telnet by selecting each target first:
  `targets rp2350.cm0`, `resume`, then `targets rp2350.cm1`, `resume`. The
  target-specific form `rp2350.cm0 resume` only prints target help in this
  OpenOCD build.
- On RP2350 dual-core firmware, a halted core1 PC near `0x000000da` can be
  misleading during OpenOCD/GDB inspection. Confirm liveness with firmware
  counters or CPUStats reports before concluding core1 failed to launch; in one
  CircularScreen run, core1 had entered the scheduler once and was reporting
  idle windows even though GDB showed the boot ROM WFE address.

### Code/Swift Multicore

- Pico SDK `queue_t` is safe for multicore and IRQ producer/consumer exchange;
  do not add an extra lock around `queue_try_add`/`queue_try_remove` unless a
  separate invariant requires it. A crash after a job is popped and
  `swift_job_run` starts, such as `freed pointer was not the last allocation`,
  points at Swift runtime or allocator concurrency instead of Pico queue
  corruption.
- The default Pico SDK core1 stack can be only `PICO_STACK_SIZE` (`0x800` in
  this workspace). If Swift or async-context code runs on core1, prefer
  `multicore_launch_core1_with_stack` with an explicit larger stack before
  treating low-address PCs or unusable stack registers as queue corruption.
- `global allocator fallback not available` is emitted by the embedded Swift
  concurrency runtime's `swift_task_alloc` cold path. If it appears after a
  core1 queue pop, it means Swift runtime/current-task state on core1 is the
  active boundary, not Pico `queue_t` synchronization.
- If multicore Swift stress reaches `freed pointer was not the last allocation`,
  the scheduler has likely reached Swift runtime/job execution. A naive Pico
  mutex around `swift_job_run` was tested and stalled the normal one-second
  alarm, so treat that lock as a failed proof step unless the runtime entry
  model changes.
- In the multicore scheduler stress logs, `r1=1` with `ps1>0`, `q1=0`, and
  `pa1=0` means core1 crashed after stealing a shared Swift runtime job before
  any core1-affine continuation could exist. Current-core affine routing avoids
  that path, but `q1=0`, `pa1=0`, and `r1=0` also means core1 is only draining
  shared probe messages, not Swift runtime jobs.
- For Swift job-affinity experiments, inspect the local Swift runtime source
  and consider `swift_task_getJobTaskId(job)` as a diagnostic key. It returns
  the full task id for `AsyncTask` jobs and the job id otherwise, but Swift's
  source describes it as primarily a debug utility, so validate raw `job`
  pointer plus task-id logs before depending on it as scheduler policy.
- Stable task-id affinity alone does not make core1 execution safe. A policy
  that alternated new post-launch task ids between core1 and core0 reproduced
  `freed pointer was not the last allocation` immediately after the multicore
  stress started. Test core1-originated seed tasks separately from stealing
  arbitrary core0-created Swift tasks.
- In the pass-2 seed-task logs, `r1=1`, `pa1=1`, and `seed11=1` showed that
  one Swift job created from core1 ran on core1. `seed10` then increased while
  `seed11` stayed at `1`, which means `Task.sleep` continuations resumed on
  core0 under the current task-id affinity policy. Treat that as a stable
  single-core1-job proof, not proof of sustained Swift execution on core1.
- Do not use `swift_task_getCurrent()` as a multicore affinity source on this
  embedded runtime without proving the current-task storage is per-core. A
  pass-2 experiment saw a core1-created seed task inherit core0 affinity when
  routing from `swift_task_getCurrent()`.
- `Task.sleep(ms:)` in this package uses `PicoTimeoutManager` and
  `ISRTrampoline`, not the Swift global delayed enqueue hook. If core1 sleep
  continuations resume on core0 and `h1d=0`, investigate trampoline/actor
  ownership rather than `swift_task_enqueueGlobalWithDelayImpl`.
- A core1 seed loop using `Task.yield()` is a direct test of sustained Swift job
  chaining on core1. It reproduced `freed pointer was not the last allocation`,
  so the current safe PoC should keep the sleep-based seed and treat sustained
  core1 Swift execution as blocked by the Swift task allocator/runtime edge.
- `Task.yield()` is not a clean same-task migration probe. The continuation can
  be enqueued while the task is still marked running, so active affinity should
  keep it on the same owner. To test non-overlapping migration of one async
  function, suspend with an explicit continuation and resume it later from
  worker tasks on either core.
- A pass-3 suspension-boundary migration probe moved the sleep-based seed
  `AsyncTask` from core0 to core1 after its first core0 run returned. Serial
  showed `seed11=2`, matching seed/current owner tokens, then reproduced
  `freed pointer was not the last allocation`. Treat this as evidence that the
  embedded Swift task allocator is not safely migratable between cores even when
  the scheduler avoids overlapping runs of the same `AsyncTask`.
- Before core1 is launched, scheduler load-balancing must not assign any Swift
  task id to core1. Symptom: boot reaches `Scheduling 1 second alarm...` and
  then core0 sits in `async_context_wait_for_work_until` while core1 has not
  started. The fix is to make the task-owner load policy return core0 until
  `startRuntimeSchedulerMulticore()` has actually launched core1.
- A pass-3 task-id ownership table with `queuedCount`/`runningCount` prevented
  obvious same-task routing across cores, but the device still reproduced
  `freed pointer was not the last allocation` once stress jobs began running on
  core1. Treat this as evidence that task-id serialization alone is not enough
  for arbitrary core0-created Swift work on core1.
- If multicore stress hardfaults in `_free_r` with another core blocked in the
  Swift `malloc` wrapper mutex, check the linked newlib `__malloc_lock` and
  `__malloc_unlock` symbols. In this workspace they initially disassembled to
  no-op `bx lr` stubs, so direct libc allocation paths could corrupt the heap
  even though `__wrap_malloc`/`__wrap_free` had a Swift-side mutex. A strong
  C implementation of `__malloc_lock`/`__malloc_unlock` with a recursive
  per-core spin lock fixed the observed `_free_r` hardfault in a 120-second
  multicore `Task.yield()` soak.
- In pass-3 multicore stress, a direct owner-queue transport for core0/core1
  removed the shared-FIFO wrong-owner churn. Healthy logs showed
  `d0=0 d1=0`, both `r0` and `r1` increasing, and `full=0 null=0`.
- Do not compute scheduler placement load by calling `queue_get_level` on
  owner queues from the enqueue path. A device hang showed core0 stuck in
  `spin_lock_unsafe_blocking` inside `queue_get_level` while core1 was polling;
  use accepted affinity `queuedCount`/`runningCount` as the placement load
  signal and leave `queue_t` as transport only.
- Per-loop diagnostic probes can fill the scheduler queue and hide the real
  runtime signal. Throttle probes to periodic stats snapshots; the symptom was
  `scheduler owner queue full` from `enqueueRuntimeSchedulerMulticoreProbe()`.
- Avoid `try!` inside long-running device stress tasks. A task like
  `Task { try! await blinkLeds() }` can hardfault through
  `swift_unexpectedErrorTyped` if cancellation or corruption reaches the error
  path; use `try?` or explicit error handling so the stress signal is not hidden
  by the forced-error trap.
- For alarm-backed same-task migration tests, observing a spawned child task can
  produce a false negative where all `Task.sleep(us:)` resumptions occur on the
  child task's first owner core. To prove the current async task can migrate
  without touching scheduler internals, run the observed sleep loop inline in
  the test task while background pressure tasks are active.
- A multicore `AsyncStream` producer/consumer stress can fail as a missing
  device run-end marker before a clean assertion is emitted. Keep that probe
  isolated or disabled while debugging; first confirm simpler current-task,
  actor-executor, sleep-cancellation, and task-lifetime tests still pass so the
  failure points at continuation stream traffic rather than a general scheduler
  outage.
- Do not add production API, SPI, or scheduler/executor pass-through plumbing
  solely to make an internal retention detail testable. Symptom: a test wants
  to prove a negative such as "this `AsyncStream` continuation is no longer
  retained" and starts adding counters through layers like
  `CPUStats -> SchedulerSystem -> CoreExecutor -> RuntimeCPUUsageMeter`. That is
  too much reach for a test. Prefer public behavioral checks such as churn under
  pressure, later streams still receiving reports, and memory staying bounded.
  If exact lifecycle proof is truly required, first extract the owning component
  into a separately testable unit instead of punching diagnostic holes through
  production scheduler boundaries. It is acceptable to leave an internal detail
  less directly tested when the alternative makes the architecture worse.
- A global-pull scheduler invalidates probes that assume enqueue-time per-core
  placement. Symptom: `MulticoreForcedSameTaskMigrationProbe` may show the
  continuation resumed from core1 while the resumed task segment is still pulled
  by core0 (`resumes=1 r1=1 c0=2 c1=0`). Treat that as expected under global
  ready queues; use behavior tests such as alarm-backed same-task migration and
  overlap checks to validate safety, not resume-core ownership.
- For Swift job priorities, keep the ABI bridge narrow: expose the raw
  `swift_job_getPriority(job)` value from C and map buckets in Swift using
  `TaskPriority` raw values. Do not duplicate priority threshold constants in
  C shims unless the runtime bridge is unavailable and the fallback is
  explicitly documented.
- `Task { ... }` created from an `@MainActor` app setup inherits the main actor.
  Symptom: a diagnostics stream prints its startup lines but never receives
  later async reports while a display/GIF loop keeps printing. Check whether the
  display loop has an overrun path with no `await`; add an explicit
  `await Task.yield()` after each work unit or move unrelated diagnostics into a
  `nonisolated` helper before creating the task.
- CPUMetrics IRQ wrappers must not call Swift metering code from IRQ context.
  Symptom: an idle async `Task.sleep(us:)` test prints before the sleep, then
  times out with a missing run-end marker; GDB shows core0 interrupted inside
  `alarm_pool_add_alarm_at_force_in_context` and entering
  `_cpicosdk_record_runtime_scheduler_exit_interrupt` through
  `cshims_irq_wrapper_3`. Keep the generic IRQ wrapper C-only and nonblocking
  for event counts, leave Pico timer alarm and USB IRQ vectors unwrapped, and
  record explicit event/time samples inside known handler paths such as the
  `Task.sleep` alarm callback.
- If an IRQ vector table may be shared between cores, a multicore IRQ wrapper
  must not depend only on per-core original-handler slots. Symptom: with
  CPUMetrics enabled, core1 can install a wrapper for a shared vector first,
  then core0 dispatches the wrapped IRQ and finds no core0-local original
  handler. Keep per-core originals for core-local vector tables, plus a shared
  fallback for the shared-vector case, or otherwise key originals by actual
  vector table identity.
- If a scheduler uses a fixed SIO hardware spinlock directly, clear the lock
  once during scheduler startup before the first blocking read. A stale locked
  hardware register can make the next flashed image hang in `startMulticore()`
  before core1 launches. On this RP2350 SDK build, `spin_lock_init()` returns a
  software-spinlock byte in SRAM because `PICO_USE_SW_SPIN_LOCKS=1`, so do not
  treat that returned pointer as an SIO spinlock register.
- Keep benchmark-only C helpers out of the scheduler hot-path translation unit.
  Moving a raw multicore baseline helper into `ConcurrencyShims.c` changed code
  layout enough to drop `SchedulerMulticoreBenchmarks` throughput from roughly
  22k to 14k; putting it in a separate C file restored the score range.
- For RP2350 scheduler throughput regressions after tiny cold-path changes,
  check linker layout before blaming the branch itself. Compare `nm`, map, and
  disassembly for `__wrap_malloc`, `cshims_scheduler_poll_once`,
  `swift_job_run`, and `swift_task_alloc`; in one IRQ-allocation warning fix,
  moving cold warning/configuration code to `.flashdata.*` restored the 22k
  score range while preserving the warning behavior.
- Keep CPUMetrics implementation objects and scheduler-affinity experiments out
  of the CPUMetrics-off hot path until measured. Symptom: the clean C scheduler
  at `b0e2875` scored about `22k`, while later non-metrics builds dropped first
  to about `19k` after the shared IRQ fallback and then to about `13k` after
  `core0_only` ready-queue scanning. The recovery was to compile the shared IRQ
  fallback only under `CPUMetrics`, restore O(1) ready-queue pop/wait behavior,
  and keep scheduler metrics as weak hooks so the CPUMetrics-off baseline
  returned above `23k`.
- Do not remove or disable a valuable runtime feature, such as CPUMetrics IRQ
  vector wrapping, based only on a plausible correlation from logs. First make
  the smallest reversible experiment, validate it against the symptom and the
  relevant tests, then present the evidence and tradeoff before changing
  production behavior. A reasonable hunch is still a hunch until measured.
- Avoid Swift object lifetime work, allocation, and free from hard IRQ handlers
  unless the allocator path is proven IRQ-safe. Symptom: a stuck core0 halted in
  Handler mode with an IRQ handler backtrace entering `swift_release`/`free`
  while the interrupted frame is already in `free` or `mallocExit`; the handler
  then blocks in `mutex_enter_blocking` on the same allocator mutex and the
  interrupted code cannot resume to release it. Attach with GDB, collect
  `thread apply all bt`, and check for a `<signal handler called>` frame between
  the interrupted allocator path and the IRQ handler. Defer ownership release or
  buffer reclamation to thread/task context, or use a bounded IRQ-safe queue.
- To debug IRQ allocator use, watch for the one-shot `[CPicoSDK]` warning from
  the wrapped allocator entrypoints. The warning uses a static C string, so it
  does not allocate by itself, but it still goes through Pico stdio and the
  configured output driver; treat it as best-effort visibility. Enable the
  `GuardIRQAllocations` trait to trap in `trapIRQAllocatorUse`, then inspect
  `cshims_irq_allocator_operation`, `cshims_irq_allocator_exception`, and
  `cshims_irq_allocator_core` in GDB.
- `EmbeddedAsyncApp` can start the Swift scheduler on core1 before `setup()`
  runs when `Configurator.core1Enabled` is true. Symptom: startup appears stuck,
  GDB shows one core in `cyw43_arch_wifi_connect_blocking` from `WiFi.connect`
  and the other core in `cshims_scheduler_wait_for_work_forever`, with no IRQ
  allocator guard hit. If the WiFi async context is core0-owned, a setup
  continuation running on core1 can block while core0 waits for scheduler work
  instead of polling CYW43. Validate with a GDB backtrace before changing code;
  as a mitigation, disable core1 during setup or keep WiFi/lwIP setup work on
  the async-context owner core.

### Serial And RTT Logging

- Check for `pyserial` with `python3 -m pip show pyserial`; install it with
  `python3 -m pip install pyserial` if needed.
- For RTT capture, start the target first, wait for firmware to initialize
  stdio, then run `rtt start`. Running `rtt start` before `stdio_init_all()`
  can fail with `rtt: No control block found`; starting the host `nc` reader
  before the RTT server is listening can also miss early boot output, so retry
  the TCP connection or delay first device prints.
- Start `miniterm` first, then reset the board from another shell to capture a
  clean boot log.
- If `/dev/tty.usbmodem*` or `/dev/cu.usbmodem*` is present but pyserial fails
  with `Operation not permitted`, the agent sandbox may not have permission to
  open serial devices. This is different from a missing USB device; rerun the
  same serial command from a host terminal with device permissions.
- Serial output can contain stale or interleaved bytes after reset. Trust logs
  more when a fresh boot banner appears.
- When multiple `/dev/cu.usbmodem*` devices are present, do not assume
  `head -n 1` is the board just programmed through CMSIS-DAP/OpenOCD. Probe
  each serial device briefly and match the boot banner or reset behavior; a
  display board can keep streaming old firmware logs while OpenOCD is
  programming a separate CMSIS target.
- Keep diagnostic log lines short. Long `print` output can make serial debugging
  feel stalled and can hide the actual crash point.
- In multicore stress tests, let only core0 print periodic stress summaries and
  let core1 update counters. Printing full diagnostic lines from both cores can
  interleave bytes on USB serial and make otherwise useful counter snapshots
  unreadable.
- Follow a question > validate > plan > fix loop for debugging. Do not turn a
  plausible hunch directly into a code change. First state the concrete question
  the symptom raises, gather evidence that can confirm or reject the hunch using
  the same command, device run, log, or artifact that exposed the symptom, then
  plan the smallest fix. If validation does not confirm the hunch, loop back to
  the question instead of implementing. After fixing, rerun the original
  reproducer; synthetic/unit coverage is useful regression protection but is not
  proof that the original physical-run or integration symptom was fixed.

### Build And Package Wiring

- Build the device example from `Example/` with `./build.sh`. Do not use a
  repo-root `./build`.
- If local package edits appear to have no effect, check
  `Example/Package.swift` and run `swift package show-dependencies` from
  `Example/`. The example must depend on the local package path, not a released
  remote package.
- After switching `Example/Package.swift` from the released CPicoSDK package to
  a local path dependency, stale SwiftPM edit state can make resolution fail
  with `dependencies unresolved: 'cpicosdk'`. Remove generated workspace state
  with `rm -f Example/.build/workspace-state.json Example/.build/.lock` and
  rerun `swift package plugin --list` from `Example/`.
- For generated SwiftPM device-test packages, do not delete and recreate
  `Sources/` or `Package.swift` on every run. Write files only when contents
  change; otherwise SwiftPM and the CMake finalizer lose useful incremental
  state and every device test looks like a cold build.
- The finalizer defaults to a clean CMake build. For repeated generated device
  test runs, call `finalize_rp2xxx_binary <Product> --incremental`; otherwise
  the finalizer removes `CMakeHarness/build_<board>` and rebuilds native Pico
  SDK objects every time.
- For faster steady-state device tests, skip `prepare-rp2xxx-environment` when
  the generated package inputs and `env.json` are unchanged, and skip
  finalization when the generated static library is older than the existing
  ELF. The next flash can reuse the last ELF safely in that no-change case.
- The root `test-in-device` harness is documented in `README.md` under
  `Device Test Harness`. Use `--list` for a no-flash discovery check and
  `--build-only` for the frequent compile/link check. Ask the user before
  running non-`--build-only` device tests because they program the connected
  board through OpenOCD.
- When evaluating size, RAM pressure, stack layout, or code ownership changes,
  consider the memory map report before guessing from UF2 size alone. Run
  `swift package --disable-sandbox memory-map-report <elf>` for an existing
  finalized artifact, or add `--memory-map-report` to focused
  `test-in-device --build-only` runs to print a per-test report without
  programming hardware.
- Host-side Swift tools must compile on Linux CI with Swift 6 concurrency
  checks. Do not write errors with C stdio globals such as
  `fputs(message, stderr)`; Linux exposes `stderr` as shared mutable state and
  Swift can reject it as concurrency-unsafe. Use
  `FileHandle.standardError.write(Data(...))` or an existing logger instead,
  and run `CPICOSDK_HOST_TESTS=1 swift test` when touching host tools or
  plugins.
- Async embedded tests that use `try await Task.sleep(...)` can fail at link
  time with an undefined `Swift.CancellationError : Swift.Error` witness table
  (`$eScEs5ErrorsWP`). Use a non-throwing await point such as
  `await Task.yield()` when the goal is only to smoke-test async scheduling,
  or investigate the embedded concurrency runtime link set before relying on
  cancellation-aware sleeps.
- Command-plugin child-process stdout can be buffered until the plugin command
  exits. For long device runs, flush after each progress line and write directly
  to `/dev/tty` when stdout is not a TTY, with normal stdout as the fallback for
  redirected or CI runs.
- If a filtered `test-in-device` run reports the requested test name but prints
  subtests or UF2 sizes from another suite, check generated artifact selection
  before debugging the test. A broad `find .build -path "*/DeviceTestApp.elf"`
  can pick stale debug/release/finalizer output; return the exact
  `.build/$SWIFTPM_TRIPLE/$SWIFT_BUILD_TYPE/DeviceTestApp.elf` path and force
  finalization when generated inputs changed.
- After deleting or renaming package source files used by generated device
  tests, stale objects can remain in the generated package cache and link
  removed symbols, such as an old `SchedulerPerf.swift.o` referencing deleted
  scheduler types. Remove only the generated device-test build cache with
  `rm -rf .build/plugins/TestInDevicePlugin/outputs/GeneratedDeviceTests/rp2350/Current/.build`
  and rerun the focused `swift package --disable-sandbox test-in-device --build-only --filter <TestName> --allow-writing-to-package-directory --allow-network-connections all`.
