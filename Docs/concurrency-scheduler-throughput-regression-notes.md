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
