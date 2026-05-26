# Concurrency Scheduler Scores

Scores below are physical `pico2` device runs from the root device-test
harness. Commit hashes are filled in after the scored implementation is
committed, because a commit cannot contain its own stable hash.

## 2026-05-26 Clean-Room C Scheduler

- Implementation commit: `b0e2875`
- Full device suite: `18/18` passing, including raw multicore sequential
  baseline test.
- Scheduled multicore, 10 passes:
  - command: `swift package --disable-sandbox test-in-device --filter SchedulerMulticoreBenchmarks --passes 10 --allow-writing-to-package-directory --allow-network-connections all`
  - `bench-multi-throughput workPerSecond`: avg `22247.40`, p95 `23018`, min
    `22037`, max `23018`
  - `bench-multi-throughput coreBalance`: avg `998.50/1000`, p95 `999/1000`
  - `bench-continuation resumptionsPerSecond`: avg `7111`, p95 `7111`
  - `bench-yield-cadence totalWork`: avg `26831.30`, p95 `26934`
  - `bench-allocation allocationWorkPerSecond`: avg `16770.90`, p95 `17454`
- Single-core raw sequential baseline:
  - `bench-sequential-throughput workPerSecond`: `21050`
  - raw: `units=14735, elapsedMs=700, core=0, checksum=32455612`
- Single-core scheduled baseline:
  - `bench-single-throughput workPerSecond`: `9641`
  - raw: `workers=4, units=6759, elapsedMs=701, coreHits=6759/0, checksum=1415365314`
- Multicore raw continuous baseline:
  - `bench-multicore-sequential-throughput workPerSecond`: `40617`
  - `bench-multicore-sequential-throughput coreBalance`: `1000/1000`
  - raw: `units=28432, elapsedMs=700, coreUnits=14216/14216, checksum=3876963196/1885458051`
