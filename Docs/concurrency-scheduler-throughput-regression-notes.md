# Concurrency Scheduler Throughput Regression Notes

## 2026-05-28 CPUMetrics-Off Throughput Recovery

Golden baseline commit `b0e2875` measured `bench-multi-throughput workPerSecond`
around `22k` with `CPUMetrics` off. The later branch measured around `13k`.

Focused three-pass device runs isolated two regressions:

- `a3a6e92 -> 3972dfb`: throughput dropped from about `22.2k` to `19.5k`.
  The only non-`CPUMetrics` production effect was the shared IRQ-original
  fallback in `IRQWrappers.c`. Keep that fallback compiled only for
  `CPUMetrics` builds unless a non-metrics caller needs it.
- `ee9a85a -> 6ad8a19`: throughput dropped from about `19k` to `13.3k`.
  The costly change was main-executor/core0-only routing, which made ready-queue
  pop and wait paths scan for runnable jobs instead of taking the queue head.

The current recovery keeps the useful test and CPUStats stream fixes but restores
the scheduler's O(1) ready queue path and the weak metrics-hook shape used by the
fast baseline. After the change, `SchedulerMulticoreBenchmarks-baseline --passes
10` measured `bench-multi-throughput workPerSecond avg=23773.80`.

## Deferred Correctness Work

- Main-executor core affinity may still be worth revisiting, but not with a
  `core0_only` flag that turns every global ready pop into a list scan. If this
  requirement becomes concrete, design a separate core0 queue or executor-specific
  transport and benchmark it against `SchedulerMulticoreBenchmarks-baseline`
  before merging.
- CPUMetrics-on throughput improved after moving scheduler metric hook symbols to
  C, especially the printing variant, but it still trails the metrics-off
  baseline. Further optimization should measure the cost of `time_us_64`, DWT
  reads, atomic exchanges, and report cadence separately.

## 2026-05-30 Hot-Path RAM Placement Notes

Treat one-function RAM/flash moves as layout experiments until proven
otherwise. In focused three-pass runs, moving individual scheduler functions
back to flash produced counterintuitive score swings that were not explained by
the function bodies alone.

Retained baseline for this investigation:

- C scheduler hot path in `.time_critical.cshims_scheduler`.
- Swift `Actor.cpp.o` text included in the RAM copy section through the
  generated linker script.
- Scheduler pools reduced to `CSHIMS_SCHEDULER_MAX_JOBS = 256` and
  `CSHIMS_SCHEDULER_MAX_OWNERS = 128`.

After the later cold-init offload described below, the retained shape measured:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23743.33
bench-yield-cadence totalWork avg=28725.67
.data=0x5324, .bss=0x7ae0, .data+.bss=0xce04
```

After reconnecting the CMSIS device and rerunning the full benchmark filter, the
retained shape remained in the same range:

```text
SchedulerMulticoreBenchmarks --passes 3
baseline:           workPerSecond avg=23711,    yield totalWork avg=28721.67, uf2=795kb
cpuMetrics:         workPerSecond avg=19318.67, yield totalWork avg=25754.67, uf2=816kb
cpuMetricsPrinting: workPerSecond avg=17743,    yield totalWork avg=25554,    uf2=846kb
.data=0x5324, .bss=0x7ae0, .cpicosdk_late_text=0x4a0
```

After the later delayed/deadline enqueue hook offload, the retained shape was:

```text
SchedulerMulticoreBenchmarks --passes 3
baseline:           workPerSecond avg=23721.67, yield totalWork avg=28762.33, uf2=795kb
cpuMetrics:         workPerSecond avg=19301,    yield totalWork avg=25748.67, uf2=816kb
cpuMetricsPrinting: workPerSecond avg=17815.33, yield totalWork avg=25574.33, uf2=846kb
.data=0x5274, .bss=0x7ae0, .cpicosdk_late_text=0x560
```

After also moving the zero-hit donate-thread hook, the current retained shape is:

```text
SchedulerMulticoreBenchmarks --passes 3
baseline:           workPerSecond avg=23732.67, yield totalWork avg=28726.33, uf2=795kb
cpuMetrics:         workPerSecond avg=19326.33, yield totalWork avg=25749.33, uf2=816kb
cpuMetricsPrinting: workPerSecond avg=17778,    yield totalWork avg=25577.33, uf2=846kb
.data=0x5254, .bss=0x7ae0, .cpicosdk_late_text=0x588
```

After rejecting and reverting the later Actor executor-check split, the retained
shape was revalidated:

```text
SchedulerMulticoreBenchmarks --passes 3
baseline:           workPerSecond avg=23727.67, yield totalWork avg=28707.67, uf2=795kb
cpuMetrics:         workPerSecond avg=19300.67, yield totalWork avg=25745.67, uf2=816kb
cpuMetricsPrinting: workPerSecond avg=17785.33, yield totalWork avg=25588.67, uf2=846kb
.data=0x5254, .bss=0x7ae0, .cpicosdk_late_text=0x588
```

Final acceptance run after the linker-script guard change, using the original
10-pass style:

```text
SchedulerMulticoreBenchmarks --passes 10
baseline:
  workPerSecond avg=23710.30, p95=23736, min=23659, max=23736
  allocationWorkPerSecond avg=16922.70
  resumptionsPerSecond avg=9446.80
  yield-cadence totalWork avg=28719.90
  uf2=795kb

cpuMetrics:
  workPerSecond avg=19317.10, p95=19348, min=19272, max=19348
  allocationWorkPerSecond avg=17302.20
  resumptionsPerSecond avg=7822.20
  yield-cadence totalWork avg=25723.10
  uf2=816kb

cpuMetricsPrinting:
  workPerSecond avg=17760, p95=17837, min=17619, max=17837
  allocationWorkPerSecond avg=14664
  resumptionsPerSecond avg=9142
  yield-cadence totalWork avg=25574.20
  uf2=846kb

Regenerated CPUMetrics-off baseline layout:
  .text=0x51144, .rodata=0xc498, .cpicosdk_late_text=0x588
  .data=0x5254, .bss=0x7ae0, .heap=0x800
  stack1_dummy=0x800, stack_dummy=0x800
```

Shrinking the pools from `768/512` to `256/128` saved about `16.9 KiB` of
`.bss` and was neutral for the three-pass throughput score.

Surprising function-move observations:

- Moving `cshims_scheduler_start_multicore` to flash without changing the
  benchmark measured about `22.7k` throughput. Symbol comparison showed the
  main Swift worker bodies stayed fixed, so this was not a simple worker-code
  layout shift. A temporary minimal readiness probe that spawned two tiny tasks
  and required both cores to report hits before the scored window measured about
  `24.5k` with `start_multicore` in RAM and about `23.6k` with it in flash. A
  heavier temporary warmup that ran two short throughput workers before the
  scored window measured about `23.8k` in RAM and about `25.3k` in flash.
  Conclusion: the original `22.7k` result was start-state sensitive; do not use
  it as proof that `start_multicore` itself must stay in RAM. The difference
  between the minimal readiness probe and throughput-worker warmup also shows
  workload/code-cache warmup affects this benchmark, so changing the benchmark
  start gate is a benchmark-design decision rather than a scheduler fix.
  A later attempt to wait for core1 entry with a C counter contaminated the hot
  layout itself and dropped the RAM-placement throughput to about `21.2k`, so
  that probe was discarded. A benchmark-only `Task.yield()` delay before the
  scored timer was also not a clean readiness gate: with `start_multicore` in
  RAM it measured about `19.1k`, but with `start_multicore` in flash under the
  same delayed-start benchmark it measured about `23.8k` while yield-cadence
  fell to about `25.2k`. Conclusion: pre-window async yielding changes task or
  scheduler state enough to dominate this measurement. Do not "fix" the
  benchmark by adding an async warmup unless the intended state change is part
  of the benchmark definition.
  A cleaner isolate later moved only `cshims_scheduler_start_multicore` to
  flash while replacing its original RAM slot with an unused `0x310` pad. That
  kept `cshims_scheduler_core1_entry_c`, `cshims_scheduler_enqueue_job`,
  `swift_job_run`, and `ProcessOutOfLineJob::process` at the retained-baseline
  addresses. It still measured lower than baseline:
  `bench-multi-throughput workPerSecond avg=22815.33` and
  `bench-yield-cadence totalWork avg=25941`. Conclusion: this function should
  stay in the RAM hot section for now; the slowdown is not explained by simple
  downstream symbol movement.
  A later startup-readiness probe tested the more specific hypothesis that the
  score loss came from starting the timed window before core1 had drained any
  Swift work. The probe spawned eight tiny yielding tasks, waited until all
  completed and both cores had recorded hits, then reset counters before the
  real throughput timer. This was not a neutral wait: with `start_multicore` in
  RAM it measured `workPerSecond avg=24005.33`, allocation/continuation scores
  improved, but yield cadence fell to `25419.67`. With `start_multicore` in
  flash under the same readiness gate it measured only `20677`; adding a
  `0x310` RAM pad to keep `core1_entry_c`, `enqueue_job`, `swift_job_run`, and
  `ProcessOutOfLineJob::process` at the RAM-control addresses still measured
  `20680.33`. The readiness gate therefore changes benchmark state/cache enough
  to be a separate benchmark variant, and it does not explain the flash
  slowdown. Disassembly of the RAM and flash/padded builds showed the
  `start_multicore` body was instruction-for-instruction the same apart from
  section address and call targets: the RAM version used linker veneers for
  flash-resident Pico SDK/helper calls, while the flash version branched
  directly in flash. The remaining hypothesis is flash/call-target/cache shape
  around startup, not downstream hot symbol addresses and not simple core1
  readiness.
- Moving `cshims_scheduler_alarm_callback` to flash measured about `19.6k`.
  Symbol comparison showed `swift_job_run`, `flagAsRunning`, and
  `ProcessOutOfLineJob::process` shifted by roughly the callback size. A
  temporary RAM padding probe restored some Actor/runtime addresses but also
  shifted scheduler RAM functions, so it did not isolate cleanly. Temporary
  counter runs reported `alarmCallbacks=0` during every benchmark phase,
  including `bench-alarm-jitter`; `Task.sleep(us:)` in this package uses the
  Pico timeout manager / ISR trampoline path, not this runtime delayed-enqueue
  callback. Conclusion: the alarm callback cannot be the direct cause of the
  throughput score change. Keep it in RAM for now, but treat the bad score as
  unresolved layout/cache sensitivity rather than proven callback execution
  cost.
  A later paired padding probe made the layout picture sharper. Moving the real
  callback to flash without padding kept early C scheduler functions at their
  baseline addresses but shifted Swift runtime text earlier by `0x2e0`; that
  measured `bench-multi-throughput workPerSecond avg=19627.33` and
  `bench-yield-cadence totalWork avg=25373`. Adding an unused `0x2e0` RAM pad
  restored `swift_job_run` / `ProcessOutOfLineJob::process` to baseline
  addresses, but the linker placed the pad at the front of the time-critical
  section, shifting the C scheduler functions by `+0x2e0`; that measured
  `workPerSecond avg=19834.67` and `yield-cadence avg=25684`. Both variants
  stayed near the bad score. This means the callback is effectively preserving
  a fragile relative placement between C scheduler code and Swift runtime code;
  preserving only one side was not enough. A cleaner proof would require
  explicit linker ordering for subregions, not another source-order padding
  guess.
  Uniform front-of-section padding told a different story: adding unused RAM
  pads of `0x20`, `0x100`, and `0x2e0` bytes shifted the entire C scheduler plus
  Swift runtime hot block together. All three stayed in the good throughput
  range (`0x20`: `23609.33`, `0x100`: `23605.67`, `0x2e0`: `23651.67`). This
  rules out simple absolute address alignment as the main cause of the callback
  experiment. The regression appears when the relative placement between the C
  scheduler portion and the Swift runtime portion changes.
  A linker-script gap of `0x2e0` inserted between `*(.time_critical*)` and
  `*(.text*)` kept all real functions in RAM, kept C scheduler addresses at the
  retained baseline, and moved only the Actor/runtime side later. It stayed in
  the good range (`workPerSecond avg=23601.67`, `yield-cadence avg=28675.33`),
  so moving the runtime side later is not inherently bad. The strongest isolate
  moved only the callback body to flash while using that same linker gap to
  restore the C scheduler addresses, Swift runtime addresses, `.data`, `.bss`,
  and heap start to the retained baseline. That still measured only
  `workPerSecond avg=19647` and `yield-cadence avg=25398.67`. Disassembly of
  `cshims_scheduler_enqueue_job` showed the hot body was almost identical, but
  the callback's section placement changed linker-generated veneers/literals
  around the hot enqueue path. A small hot/cold split that moved delayed alarm
  scheduling out of line partially recovered the flash-callback variant
  (`22322.33`) but also degraded the callback-in-RAM control (`22622`), so it
  was reverted. Net conclusion: the callback is not executed by this benchmark,
  but its RAM placement currently participates in favorable linker/codegen
  shape for the hot enqueue path. Do not move it out of the RAM hot section
  without a better linker/code layout strategy and fresh device measurements.
  A later isolate narrowed this further. A fresh `alarm_callback`-to-flash run
  measured `workPerSecond avg=19746.67`, `allocationWorkPerSecond avg=12258`,
  and `yield-cadence avg=25374.67`. The C scheduler RAM hot symbols stayed at
  the retained addresses, while the callback appeared in flash and the flash
  veneer island moved by about `0x2e0`. Keeping the real callback in RAM and
  adding an unused `0x2e0` naked flash-text probe reproduced the bad score:
  `workPerSecond avg=19685`, `allocationWorkPerSecond avg=12800`, and
  `yield-cadence avg=25474`. Keeping the real callback in RAM and adding a
  retained `0x2e0` rodata probe did not reproduce it:
  `workPerSecond avg=23588`, `allocationWorkPerSecond avg=15786.67`, and
  `yield-cadence avg=28620`. This rules out "the callback body executed",
  "the image is larger", and "RAM hot symbols moved" as sufficient
  explanations. The current best explanation is flash `.text`/veneer placement
  sensitivity: inserting code before the flash veneer/code region changes the
  instruction-fetch/cache shape seen by hot Swift worker/runtime paths even
  when that inserted code is never called.
- Moving `cshims_scheduler_wait_for_work_forever` to flash measured about
  `25.1k` throughput, but worsened other metrics: continuation throughput
  dropped from about `10.7k` to `9.1k`, allocation throughput from about `16.9k`
  to `15.0k`, and yield cadence from about `28.7k` to `27.0k`. Symbol
  comparison showed later RAM hot paths shifted by `0x384`. Temporary phase
  counters showed `waitForWork` was called only `1-2` times in most benchmark
  phases, but `66` times in `bench-continuation`. Conclusion: this is a real
  tradeoff, not a free SRAM offload; the primary throughput bump is likely a
  downstream layout win, while continuation-heavy phases repeatedly pay the
  flash-resident wait path.
  A cleaner isolate moved the wait body to flash while replacing its original
  RAM slot with an unused `0x384` pad. The pad landed exactly at the retained
  `wait_for_work_forever` address (`0x20001c44`), and downstream symbols such
  as `start_multicore`, `enqueue_job`, `swift_job_run`, and
  `ProcessOutOfLineJob::process` stayed at retained-baseline addresses. That
  still measured high throughput (`25115.67`, then `25122.33` on a repeat),
  while allocation stayed lower (`~15.2k`), continuation parsed around `9.1k`,
  and yield cadence stayed around `27.0k`. This means the primary throughput
  bump is not just downstream symbol movement. The wait body's absence from RAM
  at that point, or the altered call/veneer/cache shape for the wait path, is
  part of the effect. It remains a tradeoff because wake-heavy phases still
  regress.
  A later isolate separated those causes. Moving the wait body to flash and
  replacing its RAM slot with a `0x384` pad again measured high throughput
  (`workPerSecond avg=25142`), while secondary metrics regressed relative to
  the retained baseline (`allocationWorkPerSecond avg=15163`,
  continuation around `9142`, `yield-cadence avg=27004`). Then the real wait
  loop was put back in RAM and an unused `0x384` flash-text probe was inserted
  at the same source location. That kept `cshims_scheduler_wait_for_work_forever`
  in RAM at `0x20001c44`, kept the benchmark Swift worker functions at the same
  flash addresses, and shifted the flash veneer/runtime region almost exactly
  like the wait-flash build. It reproduced the high-throughput/low-secondary
  profile: `workPerSecond avg=25095.67`, `allocationWorkPerSecond avg=15376.33`,
  and `yield-cadence avg=27032.67`. Conclusion: the throughput bump is
  primarily a flash `.text`/veneer placement effect, not evidence that the wait
  loop itself should live in flash. Because the same text-placement win worsens
  allocation, continuation, and yield-cadence scores, do not keep this as an
  optimization without a broader benchmark objective.
  A small sweep of unused flash-text pad sizes at the same source location
  showed the effect is not monotonic. With the real wait loop still in RAM and
  worker function addresses unchanged, a `0x100` text pad shifted veneers by
  `0x100` and measured `workPerSecond avg=23175.33`,
  `allocationWorkPerSecond avg=15573.33`, `yield-cadence avg=26975.33`. A
  `0x200` pad measured `workPerSecond avg=21117`,
  `allocationWorkPerSecond avg=15573.33`, `yield-cadence avg=25985.33`. A
  `0x300` pad measured `workPerSecond avg=21112.67`,
  `allocationWorkPerSecond avg=13094`, `yield-cadence avg=25343`. The earlier
  `0x384` pad measured `workPerSecond avg=25095.67` but still hurt allocation
  and yield. This looks like a narrow flash fetch/cache placement artifact, not
  a useful code-size direction.
  The local Pico SDK headers make that hypothesis plausible: RP2350 XIP cache
  line size is `8` bytes, XIP cache size is `16 KiB`, and the cache pinning
  docs say lines are selected by address modulo `XIP_CACHE_SIZE`. In these
  probes the hot Swift worker entry addresses stayed fixed, while the flash
  veneer island moved through different modulo-`0x4000` offsets. For example,
  `__swift_task_switch_veneer` was at `0x10050fe8` in the retained baseline,
  `0x100510e8` with a `0x100` pad, `0x100511e8` with a `0x200` pad,
  `0x100512e8` with a `0x300` pad, and `0x10051368` with the `0x384` pad.
  This does not prove a specific set conflict, but it explains why adding a
  few hundred bytes of never-executed `.text` can move throughput
  non-monotonically. A temporary XIP-counter probe then instrumented
  `XIP_CTR_HIT`/`XIP_CTR_ACC` around the same benchmark window. The first
  version rounded both baseline and pad to `xipHitPermille=999`, which was not
  discriminating enough. A second version logged misses and accesses directly.
  With that identical instrumentation, the no-pad baseline measured
  `workPerSecond avg=22591.67`, `xipAccesses avg=96323223.33`, and
  `xipMisses avg=125563.67`; the `0x384` flash-text pad measured
  `workPerSecond avg=21577`, `xipAccesses avg=92002566`, and
  `xipMisses avg=163689.33`. This supports XIP/cache sensitivity in the
  direction of the score, but the instrumentation itself changed layout enough
  that the earlier uninstrumented `0x384` throughput uplift did not reproduce.
  Treat XIP counters as useful evidence only in matched instrumented variants,
  not as a drop-in measurement of the uninstrumented binary.
- Moving the tiny startup-only `cshims_scheduler_prepare_lock` helper to flash
  saved only `0x0e` bytes from RAM and still measured lower:
  `bench-multi-throughput workPerSecond avg=22831` with
  `bench-yield-cadence totalWork avg=28283.33`. This is not a useful SRAM
  tradeoff and reinforces that even small source-order/linker changes can
  perturb this benchmark.
- Moving `cshims_scheduler_enqueue_deferred` to flash saved a larger RAM body
  (`0x328` bytes), but measured worse on the current three-pass run:
  `bench-multi-throughput workPerSecond avg=23292`,
  `bench-allocation allocationWorkPerSecond avg=14966`, and
  `bench-yield-cadence totalWork avg=25744`. Reverted; deferred enqueue is not
  a free offload candidate.

Next investigation should use explicit linker-script ordering for the RAM hot
section instead of source-order toggles. Source-order moves conflate function
placement, downstream RAM code alignment, veneers, and benchmark start-state
effects.

A follow-up explicit ordering probe placed
`*libswift_Concurrency.a:Actor.cpp.o(.text*)` before `*(.time_critical*)` in
the generated linker script. That did move `swift_job_run` and
`ProcessOutOfLineJob::process` before the C scheduler hot functions, but it was
catastrophic on device: `bench-multi-throughput workPerSecond avg=495` over
three passes and `explicitContinuationThroughput` failed each pass. This rules
out the simple hypothesis that "earlier Actor/runtime text is always better."
The experiment was reverted; any future linker-order work should be narrower
than moving the whole Actor object ahead of the scheduler C path.

Another probe forced `cshims_scheduler_init_locked` out of line after noticing
that its large initialization loops were inlined into
`cshims_scheduler_wait_for_work_forever`. Moving that helper to flash shrank
`wait_for_work_forever` from `0x384` to `0xa0` bytes and reduced `.data` from
`0x67cc` to `0x54b4`, but throughput fell to about `19.3k`. Keeping the helper
out of line but still in RAM reduced `.data` to `0x57dc` and measured a clean
three-pass `bench-multi-throughput workPerSecond avg=23416.67` with
`bench-yield-cadence totalWork avg=28567.33`. That is close but still worse
than the retained baseline, so the probe was not kept. The useful conclusion is
that reducing RAM bytes is not enough; the exact placement of the following
Swift runtime text is a major part of the score.

A later, narrower initialization probe did hold up. `SchedulerSystem.init()`
already calls `cshims_scheduler_prepare_lock()` before normal runtime hooks are
used, so initialization was moved there and the repeated
`cshims_scheduler_init_locked()` calls were removed from enqueue, poll, wait,
finish, alarm, and start paths. This avoided carrying the cold setup loops in
hot functions rather than merely moving the helper out of line. The symbol
effect was large:

```text
before: .data=0x67cc, poll_once=0x834, wait_for_work_forever=0x384, start_multicore=0x310, UF2=803kb
after:  .data=0x57d4, poll_once=0x2ec, wait_for_work_forever=0x0b8, start_multicore=0x064, UF2=796kb
```

Focused physical-device measurements with the eager-init patch:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23735.67
bench-yield-cadence totalWork avg=28727

SchedulerMulticoreBenchmarks-cpuMetrics --passes 3
bench-multi-throughput workPerSecond avg=19323.67
bench-yield-cadence totalWork avg=25757.67

SchedulerMulticoreBenchmarks-cpuMetricsPrinting --passes 3
bench-multi-throughput workPerSecond avg=17817.67
bench-yield-cadence totalWork avg=25589.33
```

This patch was kept because it saves hot RAM/code size and does not reproduce
the counterintuitive throughput regressions seen with one-function RAM/flash
moves. The full generated device-test build-only sweep also passed for all 26
tests after the change. If a future C-only caller bypasses `SchedulerSystem`,
it must call `cshims_scheduler_prepare_lock()` before using scheduler enqueue or
poll hooks; the Swift-facing path already does this through the global
`SchedulerSystem` initializer.

After eager init, moving only `cshims_scheduler_prepare_lock()` /
`cshims_scheduler_init_locked()` back to flash was tested as a follow-up SRAM
save. It reduced the benchmark `.data` further (`0x57d4 -> 0x54fc`) and UF2
size by about 1 KiB, but was not neutral:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=20330.33
bench-allocation allocationWorkPerSecond avg=12387
bench-yield-cadence totalWork avg=25621
```

That result was questioned with a matched isolate: the init code was restored to
RAM, and an unused `0x2d4` flash-text probe was inserted so the RAM hot symbols
stayed at the eager-init addresses while flash veneers/text shifted like the
bad flash-init build. This reproduced the bad profile:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=20074.67
bench-allocation allocationWorkPerSecond avg=12829.33
bench-yield-cadence totalWork avg=25186
```

Conclusion: after eager init, the extra regression from moving init/prepare to
flash is primarily flash `.text`/veneer placement sensitivity. Do not take that
SRAM save without a linker strategy that can preserve the favorable flash
layout.

`cshims_scheduler_enqueue_deferred` was retested after eager init because the
old "do not move it" result came from a different code shape. With eager init,
the body is only `0x74` bytes. Moving only that function to flash saved
`0x78` bytes from benchmark `.data` (`0x57d4 -> 0x575c`) and reduced UF2 size
by about 1 KiB, but still regressed the physical benchmark:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=19121.33
bench-allocation allocationWorkPerSecond avg=16000
bench-yield-cadence totalWork avg=27215.33
```

The result was isolated the same way: restore the real deferred enqueue body to
RAM, insert an unused `0x74` flash-text probe, and verify the RAM hot symbols
stayed at the eager-init addresses while the flash veneer/text region shifted
like the bad offload. That reproduced the bad profile:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=19154.33
bench-allocation allocationWorkPerSecond avg=16000
bench-yield-cadence totalWork avg=27228.33
```

Conclusion: `enqueue_deferred` is not proven hot in this benchmark; the offload
is bad because this tiny flash-text shift lands the rest of the image in a worse
XIP/veneer layout. Keep it in the RAM hot section unless linker placement is
controlled more explicitly.

The late-flash section changed that conclusion. After `start_multicore` proved
safe in `.cpicosdk_late_text`, `cshims_scheduler_enqueue_deferred` was moved to
the same late section instead of normal early `.text`. In the focused benchmark
artifact, `.data` dropped from `0x574c` to `0x56dc` while early veneers stayed
stable enough to preserve the score. Physical measurements:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23730.33
bench-yield-cadence totalWork avg=28701.33

SchedulerMulticoreBenchmarks-cpuMetrics --passes 3
bench-multi-throughput workPerSecond avg=19367.67
bench-yield-cadence totalWork avg=25778

SchedulerMulticoreBenchmarks-cpuMetricsPrinting --passes 3
bench-multi-throughput workPerSecond avg=17807.67
bench-yield-cadence totalWork avg=25566.67
```

Conclusion: the normal-flash `enqueue_deferred` regression was also a placement
problem. Late flash placement can reclaim this small RAM body without the old
score collapse.

`cshims_scheduler_alarm_callback` was also retested after eager init. The eager
init patch shrank this callback to `0x2e` bytes, so the old large-regression
result needed rechecking. Moving only the callback to flash saved `0x30` bytes
from `.data` and added a RAM-to-flash callback veneer at the delayed-enqueue
call site. It still regressed:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=22060.33
bench-allocation allocationWorkPerSecond avg=16695
bench-yield-cadence totalWork avg=27994.33
```

A matched isolate restored the real callback to RAM and inserted an unused
`0x2e` flash-text probe. That kept RAM hot symbols at the eager-init addresses
while shifting flash text/veneers close to the callback-offload build, without
adding the RAM-to-flash callback call. It measured similarly:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=22275.67
bench-allocation allocationWorkPerSecond avg=16000
bench-yield-cadence totalWork avg=27980.67
```

Conclusion: after eager init, moving the alarm callback is less catastrophic
than before, but it is still a net loss. Most of the loss is explained by the
tiny flash `.text`/veneer placement shift, not by callback execution in the
throughput benchmark. Keep the callback in RAM unless the flash layout can be
held constant or optimized explicitly.

Late-flash placement also made the alarm callback safe to offload. After
`start_multicore` and `enqueue_deferred` were already in `.cpicosdk_late_text`,
moving `cshims_scheduler_alarm_callback` to the same late section reduced
focused benchmark `.data` from `0x56dc` to `0x56ac` while keeping the early
veneer island stable. Physical measurements:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23709.67
bench-yield-cadence totalWork avg=28750.33

SchedulerMulticoreBenchmarks-cpuMetrics --passes 3
bench-multi-throughput workPerSecond avg=19387
bench-yield-cadence totalWork avg=25706.33

SchedulerMulticoreBenchmarks-cpuMetricsPrinting --passes 3
bench-multi-throughput workPerSecond avg=17793
bench-yield-cadence totalWork avg=25563.33
```

Conclusion: normal-flash alarm callback placement was bad for the same reason
as the other small offloads. With controlled late placement, this tiny body can
move out of the RAM hot copy without measurable benchmark loss.

The "unused callback changed performance" claim was rechecked with source-free
GDB counting on the retained focused benchmark ELF. Hardware breakpoints were
set on both callback paths:

```text
cshims_scheduler_alarm_callback = 0x1005dadc
sleep_alarm_callback            = 0x1002e76c
```

After loading the retained ELF, resetting, running until both cores were back in
scheduler wait/lock code, and interrupting, GDB reported:

```text
scheduler delayed-enqueue callback hits: 0
Pico sleep/ISR trampoline callback hits: 39
```

This is stronger than the earlier source counter because it did not change the
firmware layout. It confirms that the scheduler delayed-enqueue callback was
not executed in that benchmark run, while timer-backed `Task.sleep(us:)` used
the separate Pico sleep callback repeatedly. The normal-flash callback
regression should therefore be treated as flash `.text`/veneer/cache placement
sensitivity, not callback body execution cost.

`cshims_scheduler_start_multicore` was retested after eager init as well. The
eager-init patch shrank this function from `0x310` to `0x64`, so the old
startup-only result needed rechecking. Moving only `start_multicore` to flash
saved about `0x88` bytes from benchmark `.data` (`0x57d4 -> 0x574c`) and
reduced UF2 size by about 1 KiB, but the score became lower and noisy:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=21381.33
bench-allocation allocationWorkPerSecond avg=16231.67
bench-yield-cadence totalWork avg=27428.67
```

A matched isolate restored the real `start_multicore` body to RAM and inserted
an unused `0x64` flash-text probe. That kept RAM hot symbols at the eager-init
addresses while shifting the flash text/veneer region close to the flash-start
build. It reproduced the drop:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=21173
bench-allocation allocationWorkPerSecond avg=16695
bench-yield-cadence totalWork avg=27398
```

Conclusion: after eager init, the remaining `start_multicore` flash regression
is still primarily flash `.text`/veneer placement sensitivity, not delayed core1
readiness or executing the startup function from flash during the scored window.
Keep it in RAM until linker placement can be controlled.

That linker-placement caveat was then tested directly. A new
`.cpicosdk_late_text` output section was inserted after `.rodata` and before
`.ARM.extab`, and a `CSHIMS_SCHEDULER_LATE_FLASH` annotation placed
`cshims_scheduler_start_multicore` there instead of in normal early `.text`.
This preserves the early flash/veneer island much better than the normal flash
offload. In the focused benchmark artifact, `start_multicore` moved to
`0x1005d688`, `.data` dropped from `0x57d4` to `0x574c`, and UF2 size dropped
from `796kb` to `795kb`. The early flash veneers stayed essentially at the
retained addresses:

```text
retained:        __swift_task_switch_veneer=0x10050fe8, __swift_job_run_veneer=0x10051100
late flash move: __swift_task_switch_veneer=0x10050fe8, __swift_job_run_veneer=0x100510f8
normal flash move previously shifted the same region more and measured badly
```

Physical measurements held up across the three benchmark variants:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23743.33
bench-yield-cadence totalWork avg=28779.67

SchedulerMulticoreBenchmarks-cpuMetrics --passes 3
bench-multi-throughput workPerSecond avg=19360
bench-yield-cadence totalWork avg=25699.33

SchedulerMulticoreBenchmarks-cpuMetricsPrinting --passes 3
bench-multi-throughput workPerSecond avg=17850
bench-yield-cadence totalWork avg=25531
```

Conclusion: the bad normal-flash `start_multicore` result was not an argument
that the function body must execute from RAM. It was an argument that arbitrary
early flash-text insertion is dangerous. A late flash section can reclaim this
startup-only RAM without losing the benchmark score, and is the first measured
positive direction for future cold scheduler offloads.

The benchmark start-state question was audited separately because "startup-only"
can still contaminate a fixed-window score. In
`multicoreBusyWorkThroughputOverFixedWindow`, the sequence is:

```swift
ConcurrencyRuntime.startMulticore()
resetMulticoreThroughputCounters()
let startedUs = time_us_64()
for workerID in UInt32(0)..<workerCount { Task { ... } }
```

There is no explicit acknowledgement that core1 has entered
`cshims_scheduler_core1_entry_c` before `startedUs` is taken. The existing
`coreHits` assertion is post-hoc; it proves core1 eventually ran benchmark
work, not that core1 was ready before the window opened. Each worker computes
its own deadline at first execution, so delayed worker start can also change
the denominator (`elapsedMs`) rather than only reducing units.

That means a readiness hypothesis was a legitimate question, not something to
dismiss from the word "startup". It still does not explain the measured
ordinary-flash regression by itself:

- the normal-`.text` move regressed;
- restoring the real `start_multicore` body to late flash and inserting an
  unused ordinary `.text` pad also regressed, even though the startup body was
  no longer executed from ordinary flash;
- late-flash placement of the real function preserved the score.

So the current evidence says the benchmark has no clean pre-window core1
readiness fence, but the bad ordinary-flash result is mostly early
`.text`/veneer placement. A future readiness experiment should avoid changing
the scored workload; the least invasive shape would be a C-side core1-entry
flag or counter observed before `startedUs`, plus a matched-layout control,
because previous Swift-task warmups changed allocation/continuation/yield
state enough to become separate benchmark variants.

`cshims_scheduler_wait_for_work_forever` was retested after eager init because
the old pre-eager-init experiment showed a surprising throughput bump while
hurting secondary metrics. Eager init shrank the wait loop from `0x384` to
`0xb8`, changing the layout enough that the old result no longer applies.
Moving only the wait loop to flash saved about `0xb0` bytes from benchmark
`.data` (`0x57d4 -> 0x5724`) and reduced neither UF2 size nor the broad score:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=19355.33
bench-allocation allocationWorkPerSecond avg=14769
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=26936.67
```

A matched isolate restored the real wait loop to RAM and inserted an unused
`0xb8` flash-text probe. That kept RAM hot symbols at the eager-init addresses
while shifting flash text/veneers like the flash-wait build. It reproduced the
bad profile:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=19050.33
bench-allocation allocationWorkPerSecond avg=14769
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=26993.67
```

Conclusion: after eager init, the wait-loop flash move is no longer a
throughput/secondary-metric tradeoff; it is simply worse for this benchmark
suite. The regression is again explained by flash `.text`/veneer placement, not
by executing the wait loop from flash.

Late-flash placement changed this result too. After the other small cold
scheduler bodies were already in `.cpicosdk_late_text`, moving
`cshims_scheduler_wait_for_work_forever` to the late section reduced focused
benchmark `.data` from `0x56ac` to `0x55fc`. It did introduce a RAM veneer for
the wait call, so this needed physical validation rather than assuming the
matched-pad result was enough. Measurements:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23763.67
bench-allocation allocationWorkPerSecond avg=16695
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=28691.67

SchedulerMulticoreBenchmarks-cpuMetrics --passes 3
bench-multi-throughput workPerSecond avg=19370
bench-yield-cadence totalWork avg=25724

SchedulerMulticoreBenchmarks-cpuMetricsPrinting --passes 3
bench-multi-throughput workPerSecond avg=17788
bench-yield-cadence totalWork avg=25531.67
```

Conclusion: the normal-flash wait-loop regression was also dominated by early
flash/veneer placement. Late flash can reclaim this RAM body while keeping the
current benchmark profile in range, although continuation-heavy behavior should
remain a watch point because the wait loop can actually execute in those paths.

After the wait-loop late-flash result, the remaining large cold scheduler block
was startup initialization. Moving `cshims_scheduler_prepare_lock` and its
inlined `cshims_scheduler_init_locked` body into `.cpicosdk_late_text` reduced
focused benchmark `.data` from `0x55d4` to `0x5324`. This needed a real device
run because earlier normal-flash experiments showed that even unused flash text
can perturb the hot benchmark. Measurements:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23739
bench-allocation allocationWorkPerSecond avg=17201
bench-continuation resumptionsPerSecond avg=9650
bench-yield-cadence totalWork avg=28708.33

SchedulerMulticoreBenchmarks-cpuMetrics --passes 3
bench-multi-throughput workPerSecond avg=19348
bench-yield-cadence totalWork avg=25763

SchedulerMulticoreBenchmarks-cpuMetricsPrinting --passes 3
bench-multi-throughput workPerSecond avg=17757
bench-yield-cadence totalWork avg=25542.67
```

Conclusion: moving the startup init block to the late flash section is a useful
SRAM recovery and does not reproduce the early-flash regression. The remaining
RAM-marked scheduler functions are either tiny runtime entry hooks or part of
the steady-state poll/enqueue/owner path, so treat further offloads as hot-path
experiments rather than obvious cold-code cleanup.

After reverting temporary probes and restoring the retained layout
(`.data = 0x5324`, `.bss = 0x7ae0`, `.cpicosdk_late_text = 0x4a0`), a fresh
three-pass device run measured:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23743.33
bench-allocation allocationWorkPerSecond avg=16948
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=28725.67

SchedulerMulticoreBenchmarks-cpuMetrics --passes 3
bench-multi-throughput workPerSecond avg=19318
bench-yield-cadence totalWork avg=25759

SchedulerMulticoreBenchmarks-cpuMetricsPrinting --passes 3
bench-multi-throughput workPerSecond avg=17762.33
bench-yield-cadence totalWork avg=25523
```

The linker-script RAM copy for Swift `Actor.cpp.o` was also challenged instead
of assumed. A reversible probe kept the C scheduler hot section and late-flash
section unchanged, but stopped excluding `*libswift_Concurrency.a:Actor.cpp.o`
from normal flash `.text`. That moved `swift_job_run`, `swift_task_switch`,
`ProcessOutOfLineJob::process`, and default-actor internals back to flash and
reduced focused benchmark `.data` to `0x440c`. It was not an acceptable SRAM
tradeoff:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3, first run
bench-multi-throughput workPerSecond avg=16474.33, min=14984, max=18977
bench-allocation allocationWorkPerSecond avg=14052.67
bench-continuation resumptionsPerSecond avg=7407.33
bench-yield-cadence totalWork avg=27356.33

SchedulerMulticoreBenchmarks-baseline --passes 3, repeat
bench-multi-throughput workPerSecond avg=15317.33, min=15062, max=15463
bench-allocation allocationWorkPerSecond avg=13725.67
bench-continuation resumptionsPerSecond avg=7111
bench-yield-cadence totalWork avg=27362
```

Conclusion: the `Actor.cpp.o` RAM placement is not just a broad "move more code
to RAM" artifact. Under the current scheduler layout, these Swift concurrency
runtime bodies are in the hot path and are required to keep the recovered
baseline throughput and continuation/allocation scores.

The object was inspected to see whether the retained linker rule can be made
more surgical. `Actor.cpp.o` is compiled with per-function sections such as
`.text.swift_job_run`, `.text.swift_task_switch`,
`.text._ZN12_GLOBAL__N_119ProcessOutOfLineJob7processEPN5swift3JobE`,
`.text.swift_defaultActor_enqueue`, and default-actor helper sections. The
object has about `5144` bytes of `.text*`, while the current whole-object RAM
placement costs about `0xf18` bytes in the focused benchmark compared with the
no-Actor-RAM counterfactual (`.data 0x5324 -> 0x440c`).

However, the generated Pico memmap consumes flash `.text` before the later RAM
copy section:

```ld
.text : {
    *(EXCLUDE_FILE(... *libswift_Concurrency.a:Actor.cpp.o) .text*)
}
...
.data : {
    *(.time_critical*)
    *(.text*)
    *(.rodata*)
}
```

With the current low-risk linker-script approach, excluding only selected
sections from flash is not available as a simple inverse of `EXCLUDE_FILE`;
without excluding the archive member first, those selected sections are consumed
by the flash `.text` wildcard before `.data` can place them in RAM. A narrower
patch is still possible, but it is larger: either enumerate non-hot
`Actor.cpp.o` sections into a separate FLASH output before `.data`, or generate
a modified runtime object/archive with selected sections renamed into a RAM
section. Until that larger linker/object packaging work is justified, the
whole-`Actor.cpp.o` exclusion is the smallest robust patch that preserves the
measured baseline.

A first surgical probe enumerated only obviously cold-looking Actor runtime
sections into a separate FLASH output before the late scheduler section:
unexpected-executor/reporting helpers plus
`swift_defaultActor_initialize`, `swift_defaultActor_destroy`, and
`swift_defaultActor_deallocate`. This saved only about `0x90` bytes of
focused-benchmark `.data` (`0x5324 -> 0x5294`) and measured lower than the
retained baseline:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=22601.67
bench-allocation allocationWorkPerSecond avg=16695
bench-continuation resumptionsPerSecond avg=9650
bench-yield-cadence totalWork avg=28729
```

A matched linker-only control then put those lifecycle functions back in RAM
and inserted an unused `0x8c` FLASH hole at the same location, shifting the late
flash section by the same amount. That stayed in the retained score range:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23714.33
bench-allocation allocationWorkPerSecond avg=16695
bench-continuation resumptionsPerSecond avg=10158
bench-yield-cadence totalWork avg=28680.33
```

Conclusion: this selective Actor offload is not a useful tradeoff. The measured
loss was not reproduced by the flash-section shift alone, so either those
default-actor lifecycle functions are less cold than they look in this embedded
runtime, or the small RAM-side runtime relocation they cause matters. Keep the
whole `Actor.cpp.o` RAM rule unless a later section-level split saves
substantially more memory and is measured on device.

That conclusion was narrowed by a follow-up map-only probe. The reporting/error
sections from the attempted split
(`swift_task_reportUnexpectedExecutor`, `checkUnexpectedExecutorLogLevel`, and
the Actor-local `swift_asprintf`) are already discarded by the linker in the
focused benchmark; routing only those sections to a separate flash output
produced a zero-byte `.cpicosdk_actor_cold_text` and left `.data = 0x5324`.
The earlier `0x90` saving therefore came from the default-actor lifecycle
sections (`swift_defaultActor_initialize`, `swift_defaultActor_destroy`, and
`swift_defaultActor_deallocate`) plus alignment/unwind effects. That makes the
device regression more concrete: the part that looked cold but actually saved
RAM was the lifecycle block, not the already-discarded reporting code.

Static disassembly and a source-free GDB count then showed the lifecycle block
is not dead in the benchmark app. The final ELF has flash call sites from
`PicoTimeoutManager.shared` setup in `Sleep.swift` and from
`ISRTrampoline` setup/teardown paths:

```text
0x1002e64e -> swift_defaultActor_initialize  Sleep.swift:48
0x1002e990 -> swift_defaultActor_initialize  Sleep.swift:73
0x10024298 -> swift_defaultActor_destroy     ISRTrampoline.swift:132
0x100242a2 -> swift_defaultActor_deallocate  ISRTrampoline.swift:127
0x100249a4 -> swift_defaultActor_destroy     Sleep.swift:9
0x100249ae -> swift_defaultActor_deallocate  Sleep.swift:9
```

GDB hardware breakpoints at those flash call sites, with the retained benchmark
ELF loaded and run until both cores were waiting in scheduler code, counted:

```text
PicoTimeoutManager.shared initialize call site: 1
ISRTrampoline/PicoTimeoutManager initialize call site: 16
ISRTrampoline destroy/deallocate call site: 15
PicoTimeoutManager actor destroy/deallocate call site: 0
```

That count is not a phase-specific benchmark measurement, because the debugger
itself perturbs timing and the run was interrupted manually. It is enough to
rule out "these lifecycle functions are unused cold code" for this app shape.
Moving them to flash saves little RAM and adds runtime flash calls from
sleep/trampoline paths, so it remains a poor tradeoff unless a future linker
strategy can preserve layout and a workload proves those calls are irrelevant.

The late-flash section ordering was challenged separately. A reversible probe
put `cshims_scheduler_alarm_callback` in a named subsection and had the linker
place that subsection first inside `.cpicosdk_late_text`. This did not change
which functions were in RAM or flash, and kept `.data = 0x5324` and
`.cpicosdk_late_text = 0x4a0`; it only moved the callback from the end of the
late section to the front and shifted the other late-flash bodies by about
`0x30`.

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23733.67
bench-allocation allocationWorkPerSecond avg=16695
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=28747.67
```

Conclusion: the retained late-flash result is not fragile to this small
internal late-section reorder. The bad earlier normal-flash callback experiment
was more specifically about inserting executable text before the flash
veneer/runtime region, not about the callback's relative order among the late
cold scheduler bodies. The explicit ordering probe was reverted because it
added complexity without improving score or memory.

The late-section insertion point was then challenged directly. A linker-only
probe kept the exact same functions in `.cpicosdk_late_text`, but inserted that
section immediately after `.text` and before `.rodata` instead of after
`.rodata`. This moved the late section from `0x1005d678` to `0x10051148`; RAM
sizes and hot Swift runtime RAM symbols stayed fixed, and the important flash
veneers such as `__swift_task_switch_veneer` at `0x10050fe8` and
`__swift_job_run_veneer` at `0x100510e8` also stayed fixed.

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23729.33
bench-allocation allocationWorkPerSecond avg=16695
bench-continuation resumptionsPerSecond avg=10158
bench-yield-cadence totalWork avg=28699.33
```

Conclusion: placing the late cold scheduler text before `.rodata` is neutral
when it does not move the veneer island. The bad normal-flash probes were
therefore not caused by cold text merely having a lower flash address; the
stronger suspect is still perturbing flash veneers/literals and their cache
relationship to hot Swift runtime code. The probe was reverted because it
provided evidence but no memory or score improvement.

`cshims_scheduler_start_multicore` was then retested as ordinary `.text` under
the current eager-init/late-flash layout, because the earlier "startup-only but
not neutral" result was suspicious. Moving only that function out of
`.cpicosdk_late_text` and into ordinary `.text` kept hot Swift runtime bodies in
RAM, but grew `.text` by `0x60` and moved key veneers by `0x60`
(`__swift_task_switch_veneer`: `0x10050fe8 -> 0x10051048`,
`__swift_job_run_veneer`: `0x100510e8 -> 0x10051148`). The device score
regressed:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=20547.67
bench-allocation allocationWorkPerSecond avg=16463.33
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=27389.67
```

To isolate execution from layout, `start_multicore` was restored to late flash
and an unused retained `0x64` ordinary `.text` pad was inserted. That reproduced
the same veneer addresses as the bad plain-`.text` start probe while leaving
`start_multicore` itself in late flash. The score still regressed:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=22555.33
bench-allocation allocationWorkPerSecond avg=16463.33
bench-continuation resumptionsPerSecond avg=9142 (parsed 2/3)
bench-yield-cadence totalWork avg=27261.67
```

Conclusion: the `start_multicore` ordinary-flash regression is mostly a
`.text`/veneer layout effect, not evidence that the startup body itself executes
often enough to matter. Keeping it in late flash is still the smaller retained
patch, because that avoids perturbing the veneer island while reclaiming RAM.

`cshims_scheduler_alarm_callback` was isolated with the same pattern. Moving
only the callback from late flash to ordinary `.text` moved
`__swift_task_switch_veneer` from `0x10050fe8` to `0x10051018` and
`__swift_job_run_veneer` from `0x100510e8` to `0x10051120`; hot Swift runtime
text stayed in RAM. The score regressed:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=21925.67
bench-allocation allocationWorkPerSecond avg=16000
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=27966
```

Then the callback was restored to late flash and an unused retained `0x38`
ordinary `.text` pad was inserted. This matched
`__swift_job_run_veneer = 0x10051120` and put
`__swift_task_switch_veneer` one veneer slot away at `0x10051020`, while the
callback body stayed in late flash. The score mostly recovered throughput but
not all secondary metrics:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23510
bench-allocation allocationWorkPerSecond avg=16000
bench-continuation resumptionsPerSecond avg=10666
bench-yield-cadence totalWork avg=27938
```

Disassembly of `cshims_scheduler_enqueue_job` showed the instruction structure
was effectively the same between the plain-callback and matched-pad variants,
but several RAM veneer call targets moved, including the hot
`swift_job_getPriority` veneer and delayed-path `time_us_64` /
`alarm_pool_add_alarm_at` veneers. Conclusion: the callback ordinary-flash
regression is also primarily layout/veneer sensitive, but it is not captured by
only the two flash veneers checked in the `start_multicore` isolate. Keeping the
callback in late flash remains the smaller retained patch because it avoids both
ordinary `.text` growth and the secondary RAM-veneer reshuffle.

`cshims_scheduler_wait_for_work_forever` was challenged in the opposite
direction: the current retained build keeps it in late flash, so the probe moved
only that function back into the RAM hot section. This grew focused benchmark
`.data` from `0x5324` to `0x53d4` and shrank `.cpicosdk_late_text` from
`0x4a0` to `0x3e8`. The key flash veneers stayed fixed, while downstream RAM
runtime symbols moved by the wait body size (`swift_job_run`: `0x20001cec ->
0x20001da4`, `swift_task_switch`: `0x20001eac -> 0x20001f64`,
`ProcessOutOfLineJob::process`: `0x20002094 -> 0x2000214c`). Device score:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23693.67
bench-allocation allocationWorkPerSecond avg=16948
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=28700.33
```

Conclusion: under the current late-flash/eager-init layout, putting the wait
loop back in RAM is effectively neutral for the baseline metrics but costs about
`0xb0` bytes of RAM. Keeping it in late flash is therefore a real SRAM win, not
a hidden throughput tradeoff in the current measured baseline. Broader
continuation-heavy tests should still be watched because the wait path can
execute there, but the old pre-eager-init normal-flash tradeoff no longer
describes the retained build.

The retained late-flash wait path was also checked with GDB hardware
breakpoints in the focused benchmark image. Before interrupting the run,
`cshims_scheduler_wait_for_work_forever` had been entered `43` times,
the core1 call site had been hit `20` times, and the core1 entry function had
been hit once. The breakpoint counts perturb timing and are not a phase-specific
performance measurement, but they confirm the retained late-flash wait function
is live in this benchmark rather than dead startup code.

`cshims_scheduler_enqueue_deferred` was also moved back into RAM as a
counterfactual. This grew focused benchmark `.data` from `0x5324` to `0x539c`,
shrunk `.cpicosdk_late_text` from `0x4a0` to `0x428`, shifted downstream RAM
runtime symbols by the deferred-enqueue body size, and moved
`__swift_job_run_veneer` by only `0x8` while `__swift_task_switch_veneer` stayed
fixed. Device score:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23737
bench-allocation allocationWorkPerSecond avg=16948
bench-continuation resumptionsPerSecond avg=9650
bench-yield-cadence totalWork avg=28665.67
```

Conclusion: under the current layout, keeping deferred enqueue in late flash is
also a baseline-neutral SRAM win, saving about `0x78` bytes of RAM. If a future
deferred-heavy benchmark regresses, this function is worth rechecking with that
specific workload; the current scheduler baseline does not justify spending the
RAM.

The startup init block was also moved back to RAM as a counterfactual. Changing
`cshims_scheduler_prepare_lock` and the inlined `cshims_scheduler_init_locked`
body from late flash to RAM grew focused benchmark `.data` from `0x5324` to
`0x55fc` and shrank `.cpicosdk_late_text` from `0x4a0` to `0x1c8`. Runtime RAM
symbols moved by the init body size (`swift_job_run`: `0x20001cec ->
0x20001fc0`, `swift_task_switch`: `0x20001eac -> 0x20002180`,
`ProcessOutOfLineJob::process`: `0x20002094 -> 0x20002368`), while the key
flash veneers mostly stayed fixed apart from `__swift_job_run_veneer` moving by
`0x8`. Device score:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23738.33
bench-allocation allocationWorkPerSecond avg=17201
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=28762.67
```

Conclusion: moving the eager startup init block back to RAM is baseline-neutral
but spends about `0x2d8` bytes of RAM. Keeping it in late flash is the largest
single SRAM win in the retained cold-section set and does not hide a measured
baseline performance cost.

The Swift global delay/deadline enqueue hooks were then challenged. These are
not the normal `Task.sleep(us:)` path in this package, so the hypothesis was
that `swift_task_enqueueGlobalWithDelayImpl`,
`swift_task_enqueueGlobalWithDeadlineImpl`, and their tiny C wrappers could live
in late flash. The build changed as follows:

```text
before: .data=0x5324, .cpicosdk_late_text=0x4a0
after:  .data=0x5274, .cpicosdk_late_text=0x560
swift_job_run: 0x20001cec -> 0x20001c3c
swift_task_switch: 0x20001eac -> 0x20001dfc
ProcessOutOfLineJob::process: 0x20002094 -> 0x20001fe4
```

The downstream RAM runtime shift means this was still a layout experiment, not
pure proof from source intent. The physical baseline stayed in range:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23729
bench-allocation allocationWorkPerSecond avg=16948
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=28790.33
```

A GDB hardware-breakpoint count on the focused benchmark image then set
breakpoints at `swift_task_enqueueGlobalWithDelayImpl` and
`swift_task_enqueueGlobalWithDeadlineImpl`; both counters remained `0` during a
10-second run window. Conclusion: for the current scheduler benchmark, these
hooks are cold and can be retained in late flash for a small `0xb0` RAM win.
This does not prove delayed/deadline-heavy workloads are unaffected; if such a
test is added, rerun it specifically before generalizing the result.

`swift_task_donateThreadToGlobalExecutorUntilImpl` was checked next because it
was still in RAM but looked like a runtime bridge rather than the normal async
main drain path. A GDB hardware breakpoint on the retained focused benchmark
image counted `0` hits at `0x20001454` during a 10-second reset run. Moving only
that hook to late flash changed the layout as follows:

```text
before: .data=0x5274, .cpicosdk_late_text=0x560
after:  .data=0x5254, .cpicosdk_late_text=0x588
swift_job_run: 0x20001c3c -> 0x20001c1c
swift_task_switch: 0x20001dfc -> 0x20001ddc
ProcessOutOfLineJob::process: 0x20001fe4 -> 0x20001fc4
```

The focused baseline remained flat:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=23720.67
bench-allocation allocationWorkPerSecond avg=17201
bench-continuation resumptionsPerSecond avg=9142
bench-yield-cadence totalWork avg=28731.67
```

The full three-variant benchmark also stayed in range, so this is retained as a
tiny additional `0x20` RAM win. The limitation is important: if a workload calls
`swift_task_donateThreadToGlobalExecutorUntilImpl`, the hook itself contains a
poll/wait scheduler loop and should be remeasured specifically before assuming
late flash is acceptable there.

The zero-hit result was not enough to justify splitting more of `Actor.cpp.o`.
`swift_task_isCurrentExecutor` and `swift_task_isCurrentExecutorWithFlags`
looked attractive because they occupied `0x12a` bytes in RAM and GDB hardware
breakpoints counted `0` hits in a 10-second focused benchmark reset run. A
surgical linker-script split moved only those two sections to late flash:

```text
before: .data=0x5254, .cpicosdk_late_text=0x588
after:  .data=0x50ec, .cpicosdk_late_text=0x6b8
swift_task_isCurrentExecutor:          0x20001cb0 -> 0x1005d668
swift_task_isCurrentExecutorWithFlags: 0x20001ce4 -> 0x1005d69c
swift_task_switch:                     0x20001ddc -> 0x20001cb0
ProcessOutOfLineJob::process:          0x20001fc4 -> 0x20001e98
```

Despite the zero hit count, the physical score regressed:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=22894.67
bench-yield-cadence totalWork avg=28644.33
```

A matched-layout control then kept the executor-check sections in late flash but
inserted a `0x12c` RAM gap after `swift_job_run`, restoring
`swift_task_switch` to `0x20001ddc` and `ProcessOutOfLineJob::process` to
`0x20001fc4`. That still measured poorly:

```text
SchedulerMulticoreBenchmarks-baseline --passes 3
bench-multi-throughput workPerSecond avg=22765
bench-yield-cadence totalWork avg=28702.67
```

Conclusion: the drop was not explained by execution of these functions, nor by
the simple downstream RAM address shift for `swift_task_switch` and
`ProcessOutOfLineJob`. The split changed flash/veneer placement enough to hurt
the primary throughput benchmark. The experiment was reverted because a fragile
`0x40` effective RAM win is not worth adding a cryptic Actor-section linker
split.

The remaining tiny runtime hooks were also checked before trying another flash
move. `swift_task_enqueueGlobalImpl` and `swift_task_enqueueMainExecutorImpl`
are direct hot enqueue wrappers: each immediately branches into
`cshims_scheduler_enqueue_job`, so moving them would put part of every enqueue
on flash for only `0x28` bytes of possible RAM savings. The async main drain
hook is even less attractive: disassembly showed the symbol itself is the core0
drain loop head:

```text
swift_task_asyncMainDrainQueueImpl:
  bl  cshims_scheduler_poll_once
  cmp r0, #0
  bne swift_task_asyncMainDrainQueueImpl
  bl  cshims_scheduler_wait_for_work_forever
  b   swift_task_asyncMainDrainQueueImpl
```

This means the `0x0e` bytes are executed on every core0 drain iteration, not
only once at startup. It was left in RAM without a device move experiment
because the source, disassembly, and tiny possible SRAM saving all point the
same way.
