# IRQ Vector Wrapping Strategy

## Context

We want CPU usage attribution that includes interrupt time even when IRQ handlers are installed by external SDK code or other consumers we do not control.

Registration-level wrapping is not sufficient in that scenario because not all installations flow through a single API surface.

## Chosen Approach

Use vector-table reconciliation as a global interception layer:

1. Periodically inspect each IRQ vector entry.
2. If the current vector handler is not our wrapper, store the current handler as the original.
3. Replace the vector entry with a stable wrapper handler for that IRQ index.
4. Wrapper calls the stored original handler.

This provides a global safety net even when handlers are replaced by code outside CPicoConcurrency.

## Why The First Pass Broke

Initial implementation dispatched wrapper calls into Swift. That is unsafe from ISR context and can quickly deadlock or wedge the system (symptoms included no USB stdio and early lockup).

Root cause: Swift runtime code in interrupt context.

## Current Safe Baseline

The IRQ wrapper dispatch remains C-driven, but it is not fully C-only end-to-end:

- Per-IRQ wrapper functions are defined in `Sources/ConcurrencyShims/IRQWrappers.c` (extracted from `ConcurrencyShims.c` for modularity).
- The wrapper dispatch and original-handler call chain are anchored in C so the actual IRQ forwarding logic does not depend on Swift.
- The wrapped dispatch path currently also invokes Swift runtime accounting hooks to record synthetic interrupt enter/exit events for usage attribution.
- Swift still performs periodic vector-table reconciliation from non-ISR context.

This preserves global interception and interrupt accounting, but it also means Swift is still entered from ISR context for bookkeeping.

## Reconciliation Constraints (Exclusive-Handler-Only Model)

The Pico SDK's `irq_set_exclusive_handler` asserts that the current vector entry is either `__unhandled_user_irq` or already the same handler being installed. This means we cannot blindly overwrite arbitrary vector entries.

To avoid the assert panic, reconciliation uses the following approach:

1. **Scan pass (no critical section):** Iterate `0..<NUM_IRQS`. Skip any IRQ that has no exclusive handler (`irq_get_exclusive_handler` returns nil) or that already points to our wrapper. Skip any IRQ with a shared handler (`irq_has_shared_handler` returns true).
2. **Apply pass (inside critical section):** Re-check each candidate. Use `irq_remove_handler` to remove the existing exclusive handler, then `irq_set_exclusive_handler` to install our wrapper. Store the displaced original handler in `cshims_irq_wrapper_originals[]`.

The scan/apply two-phase approach avoids holding interrupts disabled while iterating all IRQ slots, which would be a long critical section.

IRQs with shared handlers are intentionally skipped because the shared-handler dispatch table is managed by the SDK and cannot be wrapped through the exclusive-handler API.

## IRQ Accounting and `irq_events`

The wrapped dispatch path currently records a synthetic enter/exit interrupt pair in Swift via `recordRuntimeSchedulerEnterInterrupt` / `recordRuntimeSchedulerExitInterrupt`. This allows the CPU meter to count wrapped IRQ firings as `irq_events` and attribute their wall time to the `irq` bucket in usage reports.

Additionally, `sleep_alarm_callback` (which runs as a Pico SDK alarm IRQ) records a synthetic interrupt event using `runtimeSchedulerSyntheticAlarmInterrupt = UInt.max` as a sentinel IRQ number. This ensures alarm-driven wakeups are counted in `irq_events` even though the TIMER IRQ uses the shared-handler model and is not directly wrapped.

### Reentrancy and Print Interleaving

`reportIfNeeded` is called from both task context (`pollOnce`, `waitForever`) and IRQ context (alarm callback → `recordExternalEvent`). Because `print()` on embedded targets writes character-by-character without an atomic lock, an alarm IRQ can preempt an in-progress `print()` call and inject its own output mid-stream. This produces visibly interleaved report lines in the serial output. This is a known limitation; no fix has been applied as of this writing.

## Feature Gating

CPU metrics are gated behind the `CPUMetrics` Swift package trait (previously `CPU_USAGE_ENABLED` compiler define). The trait is declared in `Package.swift` and `Package.swift.template`. When the trait is absent:

- `CPUStats.enabled` returns `false`.
- `CPUStats.usageEvents(for:)` returns `nil` instead of a never-ending stream.
- All `#if CPUMetrics` blocks in `CPUMetrics.swift`, `RuntimeScheduler.swift`, and `Sleep.swift` are inactive.

## File Layout

| File | Role |
|---|---|
| `Sources/CPicoConcurrency/CPUMetrics.swift` | `RuntimeCPUUsageMeter` struct, reconcile logic, reporting, `CPUStats` public API |
| `Sources/ConcurrencyShims/IRQWrappers.c` | C-only per-IRQ wrapper functions, dispatch table, `cshims_irq_wrapper_originals[]` |
| `Sources/ConcurrencyShims/ConcurrencyShims.c` | Remaining shims (IRQ wrapper logic extracted to `IRQWrappers.c`) |
| `Sources/CPicoConcurrency/RuntimeScheduler.swift` | Calls `ensureIRQUsageVectorWrapping()` from `pollOnce()` and `waitForever()` |
| `Sources/CPicoConcurrency/Helpers/Sleep.swift` | Instruments alarm callback with synthetic interrupt enter/exit |

## Concurrency And Safety Notes

- Reconciliation apply-pass is guarded with a critical section when touching shared wrapper state.
- Global mutable state used for reconciliation (`irqWrapNextReconcileUs`) is marked `nonisolated(unsafe)` in Swift because synchronization is external (critical section in C shims).
- Wrapper table has 64 entries; reconciliation only iterates `0..<NUM_IRQS` (typically 52 on RP2xxx).

## Known Limitations

- **Shared-handler IRQs not wrapped.** Timer, DMA, and other SDK-managed shared-IRQ sources are not visible to the wrapper layer. Their activity is not attributed to the `irq` bucket unless a synthetic event is recorded manually (as done for alarm callbacks).
- **Print interleaving.** `reportIfNeeded` can fire from both task and IRQ context. Concurrent `print()` calls produce garbled output on UART/RTT.
- **Single-core.** CPU metrics currently track core 0 only. Per-core support is a future TODO.

## Validation Checklist

1. Build and flash with `CPUMetrics` trait enabled.
2. Confirm boot does not lock and USB stdio / RTT works.
3. Confirm wrapped vectors still invoke original handlers correctly.
4. Confirm no regressions in timer, DMA, GPIO, and USB IRQ-driven paths.
5. Verify that `task + irq + idle` tracks total wall time within expected measurement error.
6. Confirm `irq_events` increments when alarm-driven `Task.sleep` completes.
