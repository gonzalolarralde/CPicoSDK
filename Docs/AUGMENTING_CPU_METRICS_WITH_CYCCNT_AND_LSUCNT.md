# Augmenting CPU Metrics With CYCCNT And LSUCNT

## Context

`CPUStats` currently attributes elapsed wall time into three software buckets:

- `task`: time while the runtime scheduler has marked task execution active.
- `interrupt`: time while the interrupt-depth counter is non-zero.
- `idle`: time when neither task nor interrupt execution is marked active.

That classification is owned by `RuntimeCPUUsageMeter`. Hardware performance counters do not know about Swift tasks, scheduler state, or CPicoConcurrency's interrupt wrapping model.

`CYCCNT` and `LSUCNT` can still improve the metrics, but they should augment the existing accounting model rather than replace it.

## Key Distinction

The current meter answers:

- Where did elapsed wall time go?

Cycle and stall counters can add:

- How many core cycles elapsed in each software bucket?
- How many load/store stall counts accumulated in each bucket?
- Was apparent idle time spent sleeping/waiting, or burning core cycles?
- Was active execution compute-bound or memory/peripheral-stall-bound?

The counters improve measurement resolution and diagnostic context. They do not discover task/idle/interrupt state on their own.

## Platform Caveats

This package currently has RP2350-oriented targets and supports both Arm and RISC-V platform traits.

`CYCCNT` and `LSUCNT` are Arm Cortex-M DWT-style facilities. They are not the portable implementation path for `Platform_RP2350_riscv`.

Even on Arm, the generated RP2350 headers expose DWT register definitions but also include feature bits such as `NOCYCCNT` and `NOPRFCNT`. Any implementation should runtime-probe the relevant support bits and verify that counters advance before reporting them as available.

Recommended policy:

- Expose cycle/stall fields as optional values or behind an explicit capability bit.
- Keep existing wall-time fields authoritative and always available under `CPUMetrics`.
- Do not make the public API imply that cycle/stall counters are universally present.

## `CYCCNT` Semantics

`CYCCNT` is a monotonically increasing cycle counter when available and enabled.

It does not classify execution. Attribution would still follow the current software state machine:

```swift
let elapsedCycles = cyccntNow &- lastCyccnt

if interruptDepth > 0 {
    interruptCycles &+= elapsedCycles
} else if taskIsActive {
    taskCycles &+= elapsedCycles
} else {
    idleCycles &+= elapsedCycles
}
```

This gives cycle-accurate versions of the existing buckets:

- `taskCycles`: cycles elapsed while `taskIsActive == true` and `interruptDepth == 0`.
- `interruptCycles`: cycles elapsed while `interruptDepth > 0`.
- `idleCycles`: cycles elapsed while `taskIsActive == false` and `interruptDepth == 0`.
- `totalCycles`: sum of the cycle buckets, or the direct delta from the cycle counter over the reporting window.

Useful derived values:

- `taskCyclePercent = taskCycles / totalCycles`.
- `interruptCyclePercent = interruptCycles / totalCycles`.
- `idleCyclePercent = idleCycles / totalCycles`.
- `cyclesPerInterrupt = interruptCycles / interruptEvents`.
- `cyclesPerUs = totalCycles / totalTime` as a sanity check against system clock configuration.

## Interaction With `WFI` / `WFE`

Do not assume `CYCCNT` behaves the same across all wait/sleep states without validating on target hardware.

There are two useful possibilities:

- If `CYCCNT` continues through `WFI`/`WFE`, then `idleCycles` includes wait time and cycle percentages resemble wall-time percentages.
- If `CYCCNT` stops while the core is asleep or clock-gated, then `idleCycles` excludes some or all sleep time and represents awake/active idle cycles.

Both behaviors are useful, but they answer different questions.

The current wall-time meter should remain the source for elapsed-time attribution:

- `taskUsageTime + interruptUsageTime + idleUsageTime` should track wall time.

Cycle fields should be a separate dimension:

- `taskCycles + interruptCycles + idleCycles` tracks observed core cycles, subject to `CYCCNT` sleep behavior.

This enables an idle-efficiency signal:

- High `idleUsageTime` with low `idleCycles` suggests sleep-like idle.
- High `idleUsageTime` with high `idleCycles` suggests spin/busy idle.

`WFE` has an additional nuance: it can return immediately if the event register is already set. In that case both wall idle time and idle cycles may be small.

## `LSUCNT` / Load-Store Stall Semantics

`LSUCNT` is an 8-bit DWT profiling counter for load/store unit stall accounting when profiling counters are available.

The exact architectural wording should be checked against the target Arm documentation before naming the public field too strongly. Practically, it should be treated as a small wrapping counter whose deltas are accumulated into wider software counters.

Recommended internal model:

```swift
let elapsedLsu = UInt8(truncatingIfNeeded: lsuNow &- lastLsu)

if interruptDepth > 0 {
    interruptLsuStallCount &+= UInt64(elapsedLsu)
} else if taskIsActive {
    taskLsuStallCount &+= UInt64(elapsedLsu)
} else {
    idleLsuStallCount &+= UInt64(elapsedLsu)
}
```

Because the hardware counter is small, sampling once per reporting window is not enough. A one-second interval can wrap many times and lose data.

A first implementation should sample and accumulate `LSUCNT` at every existing accounting boundary:

- `record(event:)`
- `sample()`
- any future explicit sleep/wait instrumentation boundary

The same state machine used for time/cycle attribution can classify the stall deltas into task, interrupt, and idle buckets.

## Stall Stats To Expose

Start with aggregate and bucketed load/store stall counts:

```swift
public let loadStoreStallCount: UInt64?
public let taskLoadStoreStallCount: UInt64?
public let interruptLoadStoreStallCount: UInt64?
public let idleLoadStoreStallCount: UInt64?
```

If target validation confirms the counter represents cycles, the names could become `loadStoreStallCycles`, etc. Until then, `Count` is safer than `Cycles`.

Useful derived values when `CYCCNT` is also available:

```swift
loadStoreStallPercent = Double(loadStoreStallCount) / Double(totalCycles) * 100
activeLoadStoreStallPercent = Double(loadStoreStallCount) / Double(taskCycles + interruptCycles) * 100
taskLoadStoreStallPercent = Double(taskLoadStoreStallCount) / Double(taskCycles) * 100
interruptLoadStoreStallPercent = Double(interruptLoadStoreStallCount) / Double(interruptCycles) * 100
```

Interpretation:

- `loadStoreStallPercent`: fraction of the whole observed cycle window associated with load/store stalls.
- `activeLoadStoreStallPercent`: memory/peripheral stall pressure during non-idle execution.
- `taskLoadStoreStallPercent`: whether Swift task execution is memory/peripheral bound.
- `interruptLoadStoreStallPercent`: whether IRQ handlers are hitting slow memory/peripherals.

Example report shape:

```text
CPU(core: 0) usage: task=42%; irq=3%; idle=55%; total_us=1000000; irq_events=12
cycles: task=8400000; irq=600000; idle=11000000; total=20000000
stalls: lsu=1200000; lsu_pct=6.0%; active_lsu_pct=13.3%
```

## Why `LSUCNT` Alone Is Not Enough

`LSUCNT` can indicate that load/store operations are stalling, but not why they are stalling.

Possible causes include:

- XIP/flash wait states or contention.
- SRAM bank contention between cores or DMA.
- Peripheral/APB/FASTPERI wait states.
- DMA traffic contending with processor accesses.
- Cache, bridge, or bus arbitration effects depending on configuration.

To explain the cause, pair LSU stall counts with system-level counters later.

## RP2350 BUSCTRL Counters

RP2350 exposes `BUSCTRL` performance counters with four selectable counters. These can measure bus events such as access, contested access, upstream stall, and downstream stall for regions including:

- SIOB proc0/proc1
- APB
- FASTPERI
- SRAM banks
- XIP main ports
- ROM

This is likely the best follow-up after basic `LSUCNT` accounting because it can help explain memory/peripheral stall pressure.

Potential fixed presets:

- XIP stall or contested access: flash execution/data pressure.
- SRAM contested access: multicore or DMA contention.
- APB or FASTPERI stall: peripheral bus pressure.
- SRAM access: baseline memory traffic.

Constraints:

- Only four counters can be selected at once.
- The counters are system-level resources, not private to `RuntimeCPUUsageMeter`.
- Counter ownership should be explicit to avoid clobbering application or debugger configuration.

A conservative implementation should either use a fixed preset documented as owned by `CPUMetrics`, or require an opt-in configuration before touching `BUSCTRL`.

## DMA Activity

DMA activity is related to stalls, but direct DMA accounting is harder unless CPicoConcurrency owns or wraps DMA setup APIs.

Cheap, low-risk observations:

- `dmaActiveChannelMask`: sample each channel's `CTRL_TRIG.BUSY` bit.
- `dmaBusyTime`: accumulate elapsed wall time while at least one channel is busy.
- `dmaBusyChannelMask`: expose the most recent busy mask.
- `dmaInterruptEvents`: count DMA IRQs if they are wrapped or explicitly instrumented.

More detailed but less reliable without ownership:

- Reading `TRANS_COUNT` to estimate transfer progress.
- Inferring bytes transferred from remaining transfer count.
- Per-channel lifetime accounting.

Those become fragile because channels can be chained, self-triggered, endless, reconfigured by external code, or configured with different transfer sizes.

Direct DMA byte/transfer accounting should wait until there is a CPicoSDK-owned DMA abstraction or explicit instrumentation hooks around DMA setup and completion.

## Suggested Public API Shape

Keep existing fields unchanged and add optional fields for hardware-assisted metrics:

```swift
public struct CPUStats {
    public let taskUsageTime: UInt64
    public let interruptUsageTime: UInt64
    public let idleUsageTime: UInt64
    public let totalTime: UInt64

    public let taskCycles: UInt64?
    public let interruptCycles: UInt64?
    public let idleCycles: UInt64?
    public let totalCycles: UInt64?

    public let loadStoreStallCount: UInt64?
    public let taskLoadStoreStallCount: UInt64?
    public let interruptLoadStoreStallCount: UInt64?
    public let idleLoadStoreStallCount: UInt64?

    public let dmaActiveChannelMask: UInt32?
    public let dmaBusyTime: UInt64?
    public let busCounters: BusMetrics?
}
```

Optionals keep the API honest across:

- Arm vs RISC-V builds.
- Secure vs non-secure configurations.
- Debug/security configurations that disable DWT access.
- Targets where counters are present in headers but not implemented or not advancing.

## Implementation Notes

A minimal cycle/stall implementation should:

1. Probe DWT availability during metrics initialization.
2. Enable cycle and profiling counters only if the probe succeeds.
3. Sample wall time, `CYCCNT`, and `LSUCNT` together at every accounting boundary.
4. Use wrapping subtraction for hardware counters.
5. Accumulate hardware-counter deltas into wide software counters.
6. Keep wall-time fields as the compatibility baseline.
7. Report optional fields only when the corresponding counter is known to be working.

For `LSUCNT`, sampling frequency is critical because the counter is only 8 bits. Existing event boundaries are likely enough for active task/interrupt transitions, but long-running task execution without accounting boundaries could still lose wraps. If this becomes a problem, add a periodic sampling point before trying to infer lost wraps.

## Validation Checklist

1. Confirm the DWT feature bits indicate `CYCCNT` and profiling counters are available.
2. Confirm `CYCCNT` advances during normal execution.
3. Confirm whether `CYCCNT` advances during `WFI`/`WFE` on the target configuration.
4. Confirm `LSUCNT` changes under a workload expected to create load/store stalls.
5. Confirm `LSUCNT` does not report impossible values under a tight register-only loop.
6. Confirm bucket totals remain internally consistent: task + irq + idle equals total for each enabled dimension.
7. Confirm metrics code does not introduce heap allocation or significant ISR overhead.
8. Confirm RISC-V builds either omit these fields or report them as unavailable.
