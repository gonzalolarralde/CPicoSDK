# Core Stack Investigation

## Question

Why does moving the Swift scheduler core1 stack into Pico SDK `.stack1`
(`SCRATCH_X`) make multicore device tests hang, and how large does the core0
stack need to be when stack guards are enabled?

## Core1 Findings

`SCRATCH_X` is 4 KiB on RP2350. The Pico SDK linker script places input
sections matching `.stack1*` into `.stack1_dummy > SCRATCH_X`, then derives:

```text
__StackOneTop = ORIGIN(SCRATCH_X) + LENGTH(SCRATCH_X)
__StackOneBottom = __StackOneTop - SIZEOF(.stack1_dummy)
```

The scheduler launches core1 with `multicore_launch_core1_with_stack()` using
`cshims_scheduler_core1_stack_bottom()` and
`cshims_scheduler_core1_stack_size_bytes()`. Moving the actual
`swift_pico_scheduler_core1_stack` symbol into `.stack1.*` keeps the launch
pointer and `swift_threading_defer_current_stack_bounds()` synchronized. The
failure is not a stale-symbol mismatch.

The failure is stack capacity. The stable stack is 16 KiB in `.bss`. The
scratch experiment necessarily reduced it to 4 KiB, because `.stack1` must fit
inside `SCRATCH_X`.

## Core1 Evidence

`MulticoreSchedulerBehavior` with a 4 KiB scheduler core1 stack in normal
`.bss` failed with a missing run-end marker after the baseline subtest. GDB on
the hung image showed core1 inside `stdout_serialize_begin()`, with
`print_mutex` immediately below the scheduler stack and its spinlock pointer
corrupted to `0x100090a1`, a flash/code address:

```text
print_mutex                         0x200054fc
swift_pico_scheduler_core1_stack    0x20005580..0x20006580
core1 msp                           0x20005f14
```

That is consistent with a downward-growing core1 stack overflowing below its
bottom and corrupting adjacent `.bss`.

The same test with an 8 KiB scheduler core1 stack in `.bss` passed all subtests,
which separated stack size from scratch placement for that one workload: 4 KiB
failed before scratch was involved, while 8 KiB was enough for
`MulticoreSchedulerBehavior`.

The exact scratch experiment used:

```c
#define SWIFT_PICO_SCHEDULER_CORE1_STACK_SIZE_BYTES (4u * 1024u)
static uint32_t swift_pico_scheduler_core1_stack[...] \
    __attribute__((section(".stack1.swift_pico_scheduler_core1_stack"), aligned(16)));
```

and `PICO_CORE1_STACK_SIZE=0u` to avoid also linking Pico SDK's default
`core1_stack` into `.stack1`. It failed with a missing run-end marker. GDB
showed core1 hardfaulted with:

```text
swift_pico_scheduler_core1_stack    0x20080000..0x20081000
__StackOneBottom                    0x20080000
__StackOneTop                       0x20081000
core1 msp at hardfault              0x20080fd0
```

The low end of `swift_pico_scheduler_core1_stack` contained saved frame/code
pointer data, showing the 4 KiB stack had been consumed down to the bottom.

## Conclusion

Moving the scheduler core1 Swift stack into `SCRATCH_X` fails because
`SCRATCH_X` is only 4 KiB, and current Swift job execution on core1 can require
more than 4 KiB of C/Swift stack. The observed failures are stack overflow /
corruption, not linker-symbol desynchronization.

## Core0 Evidence

Pico SDK stack guards were enabled with `PICO_USE_STACK_GUARDS=1` to turn the
core0 lower stack bound into a hardware limit (`MSPLIM` on RP2350/M33). That
changed the earlier "2 KiB works" interpretation: without guards, core0 can
silently consume adjacent scratch space or otherwise fail later; with guards,
undersized stacks fault close to the configured lower bound.

Observed focused runs:

```text
core0 2 KiB guarded stack:
  SchedulerSingleCoreBenchmarks PASS
  SingleCoreConcurrencyConfiguration FAIL
  __StackBottom=0x20081800, __StackTop=0x20082000
  hardfault SP around 0x20081940

core0 4 KiB guarded stack:
  SingleCoreConcurrencyConfiguration FAIL
  __StackBottom=0x20081000, __StackTop=0x20082000
  hardfault SP around 0x20081168
  backtrace passed through AllocatorManager.allocator(for:), free,
  swift_deallocClassInstance, and String interpolation/growth cleanup.

core0 5 KiB guarded stack, moved to top of main RAM:
  SingleCoreConcurrencyConfiguration PASS

core0 6 KiB guarded stack, moved to top of main RAM:
  SingleCoreConcurrencyConfiguration PASS
  SchedulerSingleCoreBenchmarks PASS
  MulticoreSchedulerBehavior PASS
  AsyncMixed PASS
  CPUStatsUsageEvents PASS
  MulticoreSchedulerShimStress PASS

core0 8 KiB guarded stack, moved to top of main RAM:
  10-pass SchedulerMulticoreBenchmarks PASS
  full 26-test physical device suite PASS
```

The final linker layout is now size-tiered instead of always moving core0 to
main RAM:

```text
core0 <= 4 KiB:
  core0 uses SCRATCH_Y.
  core1, when enabled, starts at the top of SCRATCH_X and extends into main RAM
  if it is larger than 4 KiB.

4 KiB < core0 <= 8 KiB:
  core0 uses contiguous SCRATCH_X + SCRATCH_Y.
  core1, when enabled, uses the top of main RAM.

core0 > 8 KiB:
  core0 still ends at the top of SCRATCH_Y and extends downward through both
  scratch banks into main RAM.
  core1, when enabled, sits below core0 in main RAM.
  The heap is capped below the lowest main-RAM stack.
```

The default generated layout is now 8 KiB core0 and 8 KiB core1. Symbols from a
default `SchedulerMulticoreBenchmarks` build showed:

```text
__end__           0x20009820
__HeapLimit       0x2007e000
__StackOneBottom  0x2007e000
__StackOneTop     0x20080000
__StackBottom     0x20080000
__StackLimit      0x20080000
__StackTop        0x20082000
```

That means the default core0 stack is the full 8 KiB scratch range
`0x20080000..0x20082000`, while the default core1 scheduler stack is the 8 KiB
main-RAM range immediately below scratch. No separate
`swift_pico_scheduler_core1_stack` storage symbol remains; core1 launch and
stack-bound reporting use `__StackOneBottom`/`__StackOneTop`.

The 10-pass `SchedulerMulticoreBenchmarks` score with the default 8 KiB/8 KiB
scratch-first layout was lower than the previous 8 KiB core0 / 16 KiB core1
main-RAM-core0 layout:

```text
baseline:
  bench-multi-throughput workPerSecond: avg=21146, p95=21320, min=20825, max=21320
  bench-priority priorityWeight: avg=3355.44, p95=3356, min=3355, max=3356

cpuMetrics:
  bench-multi-throughput workPerSecond: avg=17841, p95=19707, min=17358, max=19707

cpuMetricsPrinting:
  bench-multi-throughput workPerSecond: avg=15871.70, p95=15940, min=15774, max=15940
```

So the scratch-first placement is useful for exposing a configurable,
bus-independent stack option, but it is not currently the fastest measured
scheduler benchmark layout.

With `CPICOSDK_CORE1_STACK_SIZE_BYTES=0`, a focused single-core benchmark build
showed `__StackOneBottom == __StackOneTop == 0x20080000`, no
`swift_pico_scheduler_core1_stack` symbol, and `cshims_scheduler_start_multicore`
compiled down to `movs r0, #0; bx lr`.

With `CPICOSDK_CORE0_STACK_SIZE_BYTES=12288` and
`CPICOSDK_CORE1_STACK_SIZE_BYTES=8192`, a build-only check showed the larger
core0 stack still anchored at the top of SCRATCH_Y:

```text
__end__           0x20008a84
__HeapLimit       0x2007d000
__StackOneBottom  0x2007d000
__StackOneTop     0x2007f000
__StackBottom     0x2007f000
__StackLimit      0x2007f000
__StackTop        0x20082000
```

That is 12 KiB of core0 stack from `0x2007f000..0x20082000`: 4 KiB in main RAM
plus both 4 KiB scratch banks. Core1 is the 8 KiB main-RAM range immediately
below core0.

The final 10-pass `SchedulerMulticoreBenchmarks` score with this layout was
still in the expected range:

```text
baseline:
  bench-multi-throughput workPerSecond: avg=22949, p95=23021, min=22874, max=23021
  bench-priority priorityWeight: avg=3355.20, p95=3356, min=3355, max=3356

cpuMetrics:
  bench-multi-throughput workPerSecond: avg=19177.30, p95=19241, min=19108, max=19241

cpuMetricsPrinting:
  bench-multi-throughput workPerSecond: avg=17653.80, p95=17705, min=17592, max=17705
```

An 8 KiB scheduler core1 stack was tested with the CPU/memory stats print path.
The focused
`CPUStatsUsageEvents` run reproducibly failed with a missing run-end marker
after both earlier subtests passed and stdout stopped at:

```text
stats-print-start
```

Restoring only the scheduler core1 stack to 16 KiB in the earlier main-RAM
layout made the focused test pass:

```text
CPUStatsUsageEvents PASS
  combinedCPUUsageEventsReportsActiveCores PASS
  combinedCPUUsageEventsReportsCore1AfterIdleWait PASS
  cpuAndMemoryStatsPrintConsistently PASS
```

## Real Project Build Checks

The earlier 6 KiB guarded core0 stack layout was checked against the larger
projects under `/Users/gonzalo/src/swift-embedded-swiftpm`; the final 8 KiB
core0 layout lowers `__HeapLimit` by another 2 KiB:

```text
CircularScreen:
  result: build and finalization PASS
  linked image footprint: text=605624, data=140, bss=33700
  __end__=0x2000ce34, __HeapLimit=0x2007e800
  heap headroom before guarded core0 stack: 454.45 KiB

RadioPlayer:
  result: build and finalization PASS
  linked image footprint: text=869580, data=156, bss=77476
  __end__=0x20019374, __HeapLimit=0x2007e800
  heap headroom before guarded core0 stack: 405.14 KiB

SwiftByt:
  result: build and finalization PASS after removing stale SwiftByt target
          archive/object state that still referenced deleted RuntimeScheduler
          objects.
  linked image footprint: text=880288, data=128, bss=77608
  __end__=0x20017ca8, __HeapLimit=0x2007e800
  heap headroom before guarded core0 stack: 410.84 KiB
```

Those three ELF files had the same exported 6 KiB stack layout at the time:

```text
__StackBottom     0x2007e800
__StackLimit      0x2007e800
__HeapLimit       0x2007e800
__StackTop        0x20080000
__StackOneBottom  0x20080800
__StackOneTop     0x20081000
```

The `swift_pico_scheduler_core1_stack` symbol remained a 16 KiB `.bss`
allocation in each image. That means these checks validate the guarded core0
stack and heap cap, not a reduced core1 Swift scheduler stack.

## Fix Options

1. Keep the scheduler core1 Swift stack in main SRAM at 16 KiB. An 8 KiB stack
   passed some multicore scheduler behavior but failed the CPU/memory stats
   print path.
2. If scratch placement is required, do not use `SCRATCH_X` alone for arbitrary
   Swift job execution. A custom linker layout could dedicate both scratch
   banks to stacks, for example moving core0 out of `SCRATCH_Y` and giving
   core1 a contiguous 8 KiB scratch stack. That is a broader memory-layout
   change and must be validated against IRQ, USB, and app stack use.
3. Reduce core1 stack demand below 4 KiB before using `SCRATCH_X` alone. That
   likely means avoiding Swift `print`/stdio and other deep Swift/runtime paths
   on core1, or adding a policy that routes those jobs back to core0. This would
   be a scheduler/runtime behavior change, not just a linker change.
4. Keep core0 explicit and guarded. Current evidence supports 8 KiB as the
   practical default: 4 KiB failed, 5 KiB passed the focused repro, 6 KiB
   passed the broader focused suite, and 8 KiB passed the full physical device
   suite plus 10-pass scheduler benchmarks.
