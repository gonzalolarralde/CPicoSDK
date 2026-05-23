# Device Test Harness Vision

## Context

The current `test-in-device` harness is intentionally correctness-first:

- device tests live under `Tests/Device/**/*.swift`
- each test file is self-contained and has its own metadata block
- the harness generates one embedded SwiftPM package per test file
- `--build-only` generates and links firmware artifacts without hardware
- full runs build, program the target through OpenOCD, capture RTT output, and
  evaluate controller-side expectations

This is a good baseline because failures are easy to isolate. The tradeoff is
that build time scales poorly: every test file pays for its own generated
package, Swift build, CMake finalization, ELF, and UF2. In CI that currently
means several cold embedded builds in sequence.

## Direction

The long-term direction is to separate the harness into two concerns:

1. Build reusable firmware artifacts in normal cloud CI.
2. Run those artifacts on self-hosted hardware runners with attached RP2350
   boards and debug probes.

The main performance win should come from grouping compatible tests into a
single firmware image. Instead of producing one UF2 per test file, the build
stage can produce one UF2 per build-compatible group. The device-side runner
then selects which test to execute at runtime.

## Grouped Test Firmware

Group tests by a build signature that captures everything that can change the
generated binary:

- board, platform, and variant traits
- stdio transport traits
- concurrency requirement
- build type
- imported CPicoSDK modules and linked runtime libraries
- other linker or finalizer settings

For each group, generate:

- one SwiftPM package
- one device-side test registry
- one ELF, UF2, map file, and any other useful final artifacts
- one manifest entry describing the group and contained tests

The generated firmware should contain all tests in the group and expose a small
device-side command loop. The host runner asks the firmware to run a named test
or function, receives structured start/end/status lines over RTT, and applies
the same controller-side expectations used today.

RTT down-channel command input is the preferred design if it proves reliable.
If RTT input is not practical enough, alternatives to investigate are:

- a GDB/OpenOCD memory-write command buffer
- a reset-time selection value stored in RAM or scratch registers
- one selected test per reset while still reusing the same programmed firmware

## Execution Model

The fast path should avoid programming and resetting for every test:

1. Program the grouped UF2 once.
2. Start the device runner.
3. Request tests from the group one at a time.
4. Keep the target running between passing tests.
5. If a test fails, times out, or corrupts the harness protocol, reset and retry
   that test once in isolation.
6. If the retry passes, report the test as recovered/flaky with both
   transcripts. If it fails again, report it as failed.

Some tests will need stronger isolation. Add metadata later for policies such
as:

- `resetBefore: true`
- `resetAfter: true`
- `exclusive: true`

The default should stay optimized for reuse. Isolation should be opt-in when a
test touches global hardware state, clocks, flash, USB, multicore scheduling, or
other resources that are hard to restore.

## Build And Run Split

The build stage should be usable on normal GitHub-hosted runners and should not
require connected hardware.

Build output should include:

- grouped ELF and UF2 files
- map files and size reports
- a machine-readable manifest
- checksums for every emitted artifact
- the CPicoSDK revision, Swift toolchain version, `env.json` signature, and
  grouping inputs used to build the artifacts

The run stage should execute on a self-hosted GitHub runner connected to one or
more boards and debug probes.

The hardware runner should:

- download build artifacts from the cloud CI job
- read the manifest
- match each group to an available compatible board
- lock each probe while it is in use
- program, run, and collect results
- upload structured results, OpenOCD logs, RTT transcripts, timing data, and
  artifact checksums

The first hardware runner can be simple and local to one board type. Generalize
only after the artifact manifest and result format are stable.

## Result And Artifact Model

Keep host-side result semantics consistent with the current harness:

- build failure
- program failure
- timeout
- missing end marker
- device assertion failure
- controller expectation mismatch
- crash-like disconnect or protocol corruption

The manifest should let a later run job execute artifacts without rebuilding or
rediscovering tests from source. A future shape can include:

- schema version
- artifact build ID
- group ID
- required board/platform traits
- contained test names and source paths
- test isolation policy
- artifact paths and checksums
- expected control and output transports

Use UF2 size for artifact reporting, but also capture ELF footprint metrics for
regression tracking. UF2 size is useful as a build artifact signal; `arm-none-eabi-size`
and section/symbol reports are better for actual flash/RAM attribution.

## Efficiency Ideas

Several improvements can be layered in independently:

- Cache generated firmware artifacts by a content key that includes test source,
  generated runner source, CPicoSDK revision, `env.json`, traits, build type,
  and Swift toolchain.
- Add a `--dry-run-groups` or `--plan` command that prints grouping decisions
  and explains why tests did or did not share firmware.
- Prefer stable generated file paths and stable ordering so SwiftPM, CMake, and
  CI caches remain useful.
- Keep a small compatibility matrix for boards and probes so hardware runners
  can select the right target automatically.
- Record `arm-none-eabi-size` and top symbols for grouped firmware when a size
  regression is suspected.
- Consider a nightly full hardware run while pull requests run a smaller
  build-only or selected-hardware smoke suite.
- Preserve the current one-test-per-UF2 path as a debugging fallback while the
  grouped runner matures.

## Suggested Milestones

1. Add grouping analysis only: print the proposed groups without changing build
   output.
2. Generate grouped firmware for tests with identical traits and concurrency
   requirements.
3. Add a runtime test registry and execute a selected test after boot.
4. Add host-to-device selection without reflashing.
5. Emit an artifact manifest from the build stage.
6. Add an artifact-consuming hardware runner mode.
7. Wire cloud CI artifact production to a self-hosted runner job.

## Open Questions

- Is RTT down-channel reliable enough for test selection, or should the first
  implementation use a simpler reset-time selection mechanism?
- What is the minimum useful hardware inventory format for multiple local
  boards and probes?
- Which tests require hard reset isolation, and which can safely run in a reused
  process?
- Should flaky/recovered tests fail CI immediately, or report separately until
  the harness has enough history?
- How much of size reporting should happen in the build artifact job by default
  versus only in explicit size-analysis workflows?

## Recommendation

Do not optimize the current v1 harness by making every build parallel by
default. The larger architectural win is to reduce the number of firmware images
that need to be built and programmed. Parallelism can still be useful later, but
grouping and build/run separation should come first because they reduce work
rather than just doing the same work concurrently.
