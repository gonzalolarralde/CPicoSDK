# Third-Party Notices

## Apple XNU Clutch scheduler experiment

`Sources/SchedulerPolicies/XNUClutchPolicy.c` and the source-derived
declarations in `Sources/SchedulerPolicies/include/SchedulerPolicies.h`
contain a modified, freestanding adaptation of portions of Apple XNU. They
are derived from:

- `libkern/c++/priority_queue.cpp`
- `osfmk/kern/priority_queue.h`
- `osfmk/kern/sched_clutch.c`

The experiment is pinned to upstream commit
`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea` from
`apple-oss-distributions/xnu`.

Those source-derived portions are covered by the Apple Public Source License
2.0, not the repository's MIT license. The complete license is included at
`LICENSES/APSL-2.0.txt`; the modified sources retain Apple's notice and
describe the CPicoSDK changes. The compact implementation in
`ClutchLitePolicy.c` is a separate clean-room implementation based on the
published scheduler design.
