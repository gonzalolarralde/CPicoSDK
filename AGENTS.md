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
- Keep diagnostic log lines short. Long `print` output can make serial debugging
  feel stalled and can hide the actual crash point.
- In multicore stress tests, let only core0 print periodic stress summaries and
  let core1 update counters. Printing full diagnostic lines from both cores can
  interleave bytes on USB serial and make otherwise useful counter snapshots
  unreadable.

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
