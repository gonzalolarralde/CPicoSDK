# XNU Clutch Scheduler Experiment

## Purpose

This experiment compares three policies while preserving CPicoSDK's existing
Swift-task execution model:

1. The current weighted five-priority sequence (`9/3/2/1/1`).
2. A compact clean-room implementation of XNU Clutch's timeshare root policy.
3. A source-derived XNU implementation that retains the pairing heap and the
   root selector's update and branch ordering.

None of the variants imports Mach threads, preemption, AST/IPI machinery,
processor sets, thread groups, or XNU's fixed-priority scheduling. A Swift job
still runs indivisibly until `swift_job_run` returns.

## Policy mapping

Swift's five runtime priority buckets map directly to XNU's timeshare buckets:

| CPicoSDK bucket | XNU bucket | WCEL | Warp | Starvation window |
|---|---|---:|---:|---:|
| high | foreground | 0 us | 8,000 us | 10,000 us |
| user initiated | interactive | 37,500 us | 4,000 us | 8,000 us |
| default | default | 75,000 us | 2,000 us | 6,000 us |
| utility | utility | 150,000 us | 1,000 us | 4,000 us |
| background | background | 250,000 us | 0 us | 2,000 us |

The initial comparison preserves XNU's absolute wall-clock windows. It does
not debit per-core cycle counts: doing so would double-charge cluster-wide
service when both RP2350 cores run simultaneously and would no longer match
XNU's root policy.

## Integration boundary

The policy sees only three locked events:

- a priority FIFO transitions from empty to runnable;
- a scheduler poll chooses one runnable priority;
- claiming a job leaves that FIFO empty.

The fixed job pool, owner-private FIFO, same-task serialization, delayed alarm
delivery, deferred work, SIO lock, `WFE`/`SEV`, and job execution remain common.
The ready-only lifecycle mirrors XNU's run queue: when the final ready job is
claimed, empty-bucket handling preserves any partially used warp and active
starvation window. CPicoSDK has no preempted/current-thread candidate to feed
back into the next selection.

## Implementations

`SchedulerClutchLite` enables a structure-of-arrays implementation with fixed
five-entry scans and bitmaps. `SchedulerXNUClutch` enables the APSL-covered
source-derived implementation. The latter is pinned to XNU commit
`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`.

`SchedulerPolicyComparison` is benchmark-only. It links all three policies and
uses a non-constant selector byte so the same dispatch, functions, state, and
addresses are retained in each alternative. Every selector value is non-zero,
keeping the byte in `.data` instead of moving the weighted alternative into
`.bss`.

The benchmark also builds the same workload three more times without the
comparison trait: no scheduler trait, `SchedulerClutchLite`, and
`SchedulerXNUClutch`. Those direct builds measure the production-shaped hot
paths. In particular, the direct weighted build does not pay for a clock read,
policy transition callbacks, or volatile selector dispatch. The controlled
matrix isolates policy behavior and layout; the direct matrix answers what a
real trait selection costs.

The default build enables none of these traits and retains the existing
weighted scheduler path.

## Validation

The host tests use an injected microsecond clock and run both Clutch
implementations through exact warp/starvation boundaries, reason-code oracles,
empty/reopen state, a deterministic equal-deadline pairing-heap lifecycle, and
a 100-seed, 100,000-operation differential corpus with unique deadlines.
The device comparison records:

- same-priority yield handoffs per second and core balance;
- interactive burst start latency under background pressure;
- first service and maximum service gap for background work under sustained
  foreground pressure.

All physical runs must identify the same device and verified firmware digest.
The controlled comparison binaries are also checked for equal size, common
symbol addresses, and matching executable bytes before timing results are
attributed to policy implementation rather than linker/XIP layout. The direct
builds intentionally permit dead stripping and layout differences and are
reported separately.

Static Thumb-2 inspection is supporting evidence rather than a cycle model.
In the reviewed build, the compact policy's three runtime entry points occupied
1,268 bytes and 392 static instructions. The source-derived pairing-heap
variant occupied 1,416 bytes and 493 static instructions across its entry
points and helpers. Its selector itself was smaller (420 versus 888 bytes),
but heap maintenance added calls and pointer traffic. State was 296 bytes for
the source-derived variant versus 168 bytes for the compact variant.

## Results

The final matrix ran as HardwareRunner job
`ef30ba14-0559-4f2d-b1eb-aeb69d25ed6e` on device
`cmsis-dap:E6633861A323412C:rp2350`. All 60 attempts (six alternatives times ten
runs) programmed and verified successfully, completed through the configured
end sequence, and produced non-truncated RTT captures. There were no retries,
non-zero programmer/verify exits, or capture-digest mismatches.

The averages below are over ten interleaved physical runs. Lower latency and
gap values are better; higher handoff and foreground-unit values are better.

### Layout-controlled matrix

| Metric | weighted16 | compact | source-derived XNU |
|---|---:|---:|---:|
| same-priority handoffs/s | 54,551.8 | 53,084.6 | 52,794.0 |
| high-burst mean start latency | 578.6 us | 576.9 us | 562.7 us |
| high-burst maximum start latency | 885.3 us | 851.6 us | 834.7 us |
| background first-service latency | 259.9 us | 52.3 us | 58.9 us |
| background maximum service gap | 299.9 us | 156,656.4 us | 156,648.3 us |
| foreground work units in 650 ms | 21,101.1 | 28,230.3 | 27,703.2 |

Relative to weighted selection, compact Clutch lost 2.690% handoff throughput
and source-derived XNU lost 3.222%. The source-derived selector was 0.547%
slower than compact, but reduced mean and maximum high-burst latency by 2.461%
and 1.984%, respectively. Both Clutch variants completed roughly 31--34% more
foreground work under sustained pressure, but did so by allowing approximately
156.65 ms background service gaps instead of the weighted policy's 0.30 ms.
Their fast first background sample must therefore not be read as regular
background fairness.

The three controlled ELFs were each 3,583,844 bytes and had identical symbol
tables and identical `.text` bytes (SHA-256
`383246d73d6f619253410c408852c7bfc8e135b1f09533ae4226f40d167ea11a`).
Their `.data` images differed at exactly one byte: the selector at
`0x20004c7c`, containing `1`, `2`, or `3`. The reviewed XNU deadline-update
helper was resident in SRAM at `0x200025cc`, so no normal selection crossed a
flash veneer. This is the strongest policy-body comparison.

### Direct production-shaped matrix

| Metric | weighted | compact | source-derived XNU |
|---|---:|---:|---:|
| same-priority handoffs/s | 39,458.4 | 35,110.0 | 37,079.3 |
| high-burst mean start latency | 632.0 us | 616.9 us | 586.5 us |
| high-burst maximum start latency | 959.2 us | 915.4 us | 859.9 us |
| background first-service latency | 318.2 us | 59.7 us | 65.9 us |
| background maximum service gap | 400.5 us | 156,712.3 us | 156,710.0 us |
| foreground work units in 650 ms | 15,979.4 | 19,487.7 | 19,735.5 |

Here the source-derived build beat compact by 5.609% in handoff throughput,
4.928% in mean burst latency, and 6.063% in maximum burst latency. It still
trailed the direct weighted build by 6.029% in handoff throughput. These
absolute values are linker-layout sensitive: dead stripping changed text size
and moved `swift_job_run` from `0x20001ffc` (weighted) to `0x20002514`
(compact) and `0x200025ac` (XNU). Consequently, differences between the
controlled and direct tables are not estimates of dispatch overhead.

### Decision

Keep the existing weighted policy as the default. It won same-priority
throughput and, more importantly, provided service to continuously runnable
background work every few hundred microseconds rather than every ~157 ms.

Between the two imported-policy experiments, the actual XNU structure is the
better follow-up candidate: it was essentially tied with compact under matched
layout, had consistently lower high-burst latency, and improved direct-build
handoff throughput, burst latency, and foreground work relative to compact.
Compact retained slightly faster background first service. That is evidence
that some of the pairing-heap and branch-ordering shape survived the adaptation,
but not evidence that either Clutch variant is a better general CPicoSDK
scheduler yet. The next experiment should tune warp/starvation windows for
cooperative Swift jobs and require a background-gap bound before considering
promotion.
