# Agent Device Workflow

This repo has a hardware-oriented example workflow. For this project, build and
device commands should be run from `Example/` unless noted otherwise.

When a debugging session produces a reusable general workflow lesson, add it to
this file under `Debugging Tips Log`. Classify each tip by area, such as
code/Swift, USB connection, OpenOCD/GDB, serial/RTT logging, build/package
wiring, or another specific category that fits the issue. Keep the tip concrete:
include the symptom, the command or code pattern that helped, and any known
limitation. Keep feature-specific investigation notes in `docs/`.

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
find .build/plugins/PrepareEnvironmentPlugin/outputs -type f -name openocd.exe
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
OPENOCD="$(find .build/plugins/PrepareEnvironmentPlugin/outputs -type f -name openocd.exe -print -quit)"
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
- For one-shot reset commands, include `-c "init"` before `-c "reset run"`.
  Without `init`, OpenOCD can report `invalid command name "reset"`.
- If ports are already bound by stale debug sessions, use
  `pkill -f /openocd.exe` before starting OpenOCD again.
- GDB may print missing DWO/PCH or `.debug_names` warnings. Those warnings are
  not necessarily fatal; `info threads` and `thread apply all bt` can still
  provide useful PCs and backtraces.

### Serial And RTT Logging

- Check for `pyserial` with `python3 -m pip show pyserial`; install it with
  `python3 -m pip install pyserial` if needed.
- Start `miniterm` first, then reset the board from another shell to capture a
  clean boot log.
- Serial output can contain stale or interleaved bytes after reset. Trust logs
  more when a fresh boot banner appears.
- Keep diagnostic log lines short. Long `print` output can make serial debugging
  feel stalled and can hide the actual crash point.

### Build And Package Wiring

- Build the device example from `Example/` with `./build.sh`. Do not use a
  repo-root `./build`.
- If local package edits appear to have no effect, check
  `Example/Package.swift` and run `swift package show-dependencies` from
  `Example/`. The example must depend on the local package path, not a released
  remote package.
