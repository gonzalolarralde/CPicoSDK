# Volatile MMIO Import Plan

This note captures the current direction for making Pico SDK MMIO register
blocks usable from Swift with minimal overlay code.

## Goal

The goal is to make imported C hardware register structs usable directly from
Swift, so code like this works:

```swift
let t1 = timer0_hw.timerawl
let gpio = sio_hw.gpio_out
```

and writes like this work:

```swift
sio_hw.gpio_oe = sio_hw.gpio_oe | (1 << 25)
sio_hw.gpio_out = sio_hw.gpio_out ^ (1 << 25)
```

The design target is:

- keep the imported C layout types as the source of truth
- avoid generating large Swift overlay types when the imported C surface is
  already sufficient
- preserve direct access to the real MMIO-backed storage
- keep generated Swift shims narrow and mechanical

## What Made The Current Experiment Work

The current working hypothesis is:

1. register block structs that model MMIO need to be imported as `~Copyable`
2. loads and stores still need to go through volatile-aware access paths
3. once the importer preserves the right value model, direct imported member
   access becomes usable for many register fields

The practical unlock was adding:

```c
typedef struct __attribute__((swift_attr("~Copyable"))) {
    io_ro_32 gpio_in;
    io_rw_32 gpio_out;
    io_rw_32 gpio_oe;
} sio_hw_t;
```

and similarly for other hardware structs such as `timer_hw_t`.

Without `~Copyable`, Swift can treat imported struct values as ordinary
copyable values, which makes `self`-based or field-based access suspect for
MMIO. With `~Copyable`, the imported type better matches the intended hardware
identity model.

## Core Rules

### 1. Mark MMIO register block structs as `~Copyable`

This should apply to C structs that are intended to represent live hardware
register storage.

Examples:

```c
typedef struct __attribute__((swift_attr("~Copyable"))) {
    io_wo_32 timehw;
    io_wo_32 timelw;
    io_ro_32 timehr;
    io_ro_32 timelr;
    io_ro_32 timerawh;
    io_ro_32 timerawl;
} timer_hw_t;
```

```c
typedef struct __attribute__((swift_attr("~Copyable"))) {
    io_ro_32 gpio_in;
    io_rw_32 gpio_out;
    io_rw_32 gpio_oe;
} sio_hw_t;
```

Do not apply this blindly to every struct in the SDK. It should be limited to
hardware-layout structs that model MMIO register blocks or MMIO sub-blocks.

### 2. Detect MMIO structs by volatile-qualified member storage

Do not rely only on the literal `volatile` keyword appearing inline in the
struct body. In this SDK, volatile register fields are usually written via
typedefs such as:

```c
typedef volatile uint32_t io_rw_32;
typedef const volatile uint32_t io_ro_32;
typedef volatile uint32_t io_wo_32;
```

So the detection rule for "this struct is an MMIO register block" should
include fields whose types resolve to:

- `volatile T`
- `const volatile T`
- typedefs such as `io_rw_*`, `io_ro_*`, `io_wo_*`

Examples:

```c
typedef struct {
    io_rw_32 reset;
    io_rw_32 wdsel;
    io_ro_32 reset_done;
} resets_hw_t;
```

```c
typedef struct {
    io_ro_32 gpio_in;
    io_rw_32 gpio_out;
    io_rw_32 gpio_oe;
} sio_hw_t;
```

### 3. Cover nested hardware structs too

Some hardware structs are used as nested blocks inside larger hardware blocks.
Those nested structs should also be considered for `~Copyable` if Swift code is
expected to use them directly.

Example:

```c
typedef struct {
    io_rw_32 accum[2];
    io_rw_32 base[3];
    io_ro_32 pop[3];
    io_rw_32 ctrl[2];
} interp_hw_t;
```

If Swift is expected to project and use `interp_hw_t` directly, it should be
treated as a hardware value type too.

### 4. Prefer `UnsafeMutablePointer<T>` for hardware entry points

If Swift shims are needed for hardware base macros, use mutable pointers:

```swift
@inlinable @inline(__always)
public var sio_hw: UnsafeMutablePointer<sio_hw_t> {
    .init(bitPattern: UInt(SIO_BASE))!
}
```

This is the right default because most register blocks contain at least one
read-write or write-only member.

`UnsafePointer<T>` is only appropriate for truly read-only blocks, and should
not be the default.

### 5. Treat read-only and write-only member semantics as real constraints

Even when the hardware block entry point is an `UnsafeMutablePointer<T>`, the
individual register fields still have access modes:

- `io_ro_*`: read-only
- `io_rw_*`: read-write
- `io_wo_*`: write-only

This matters for codegen and for any future higher-level API. The pointer
mutability alone should not be mistaken for member-level read/write permission.

### 6. Do not assume every volatile use case is solved by this plan

This plan is aimed at register-block structs and their direct hardware entry
points. It does not automatically solve all volatile uses in the Pico SDK.

Separate categories still exist, especially:

- function parameters like `volatile void *`
- function parameters like `volatile uint32_t *`
- synchronization/lock types such as `spin_lock_t`
- inline asm `volatile`

These may still require separate importer handling or Swift wrappers.

## Hardware Entry Point Shims

### Simple base-address macros

When the SDK has a simple macro like:

```c
#define sio_hw ((sio_hw_t *)SIO_BASE)
```

the Swift shim should be:

```swift
@inlinable @inline(__always)
public var sio_hw: UnsafeMutablePointer<sio_hw_t> {
    .init(bitPattern: UInt(SIO_BASE))!
}
```

Likewise:

```c
#define timer0_hw ((timer_hw_t *)TIMER0_BASE)
#define timer1_hw ((timer_hw_t *)TIMER1_BASE)
```

becomes:

```swift
@inlinable @inline(__always)
public var timer0_hw: UnsafeMutablePointer<timer_hw_t> {
    .init(bitPattern: UInt(TIMER0_BASE))!
}

@inlinable @inline(__always)
public var timer1_hw: UnsafeMutablePointer<timer_hw_t> {
    .init(bitPattern: UInt(TIMER1_BASE))!
}
```

### Complex macro forms are a known importer limitation

Some hardware aliases are not simple `((T *)BASE)` macros. Examples include:

```c
#define interp_hw_array ((interp_hw_t *)(SIO_BASE + SIO_INTERP0_ACCUM0_OFFSET))
#define interp0_hw (&interp_hw_array[0])
#define interp1_hw (&interp_hw_array[1])
```

Those more complex forms are not reliably transported by the importer today.
This is a known limitation.

For those cases, Swift shims should be generated explicitly.

Example:

```swift
@inlinable @inline(__always)
public var interp_hw_array: UnsafeMutablePointer<interp_hw_t> {
    .init(bitPattern: UInt(SIO_BASE + SIO_INTERP0_ACCUM0_OFFSET))!
}

@inlinable @inline(__always)
public var interp0_hw: UnsafeMutablePointer<interp_hw_t> {
    interp_hw_array
}

@inlinable @inline(__always)
public var interp1_hw: UnsafeMutablePointer<interp_hw_t> {
    interp_hw_array + 1
}
```

More generally, codegen should handle at least:

- `((T *)BASE)`
- `((T *)(BASE + OFFSET))`
- `(&array_macro[index])`

## What To Generate And What Not To Generate

### Generate

- `~Copyable` annotation for hardware MMIO structs
- Swift hardware entry point shims for `*_hw`-style macros when the importer
  does not already provide a usable surface
- Swift hardware entry point shims for complex aliases such as indexed or
  derived macros

### Avoid generating by default

- large parallel Swift overlay register-block types when imported C works
- duplicate naming layers unless required
- ad hoc hand-written wrappers for every peripheral

The preferred direction is to use imported C MMIO structs directly once their
value model is correct.

## Direct Validation Strategy

The current experiments validated both reads and writes using real hardware.

### Read validation using a changing hardware register

Timer read registers are good for proving that reads are hitting live MMIO:

```swift
let t1 = timer0_hw.timerawl
sleep_ms(10)
let t2 = timer0_hw.timerawl
print(t1, t2, t1 != t2)
```

Expected behavior:

- `t2` should differ from `t1`
- values should increase over time

### Write validation using GPIO

GPIO is a good write target because it produces a visible and measurable
hardware effect.

Example:

```swift
let gpioMask: UInt32 = 1 << 25

gpio_set_function(25, GPIO_FUNC_SIO)

let sio = sio_hw
let originalOE = sio.gpio_oe
let originalOut = sio.gpio_out

sio.gpio_oe = originalOE | gpioMask
sio.gpio_out = originalOut | gpioMask

let outHigh = sio.gpio_out
let inHigh = sio.gpio_in

sio.gpio_out = originalOut & ~gpioMask

let outLow = sio.gpio_out
let inLow = sio.gpio_in
```

Expected behavior:

- `gpio_oe` bit becomes set
- `gpio_out` follows written high/low values
- `gpio_in` tracks the actual sampled pin level for the tested bit

For Pico 2 non-wireless, the onboard LED is on GPIO 25, so this gives a direct
visual confirmation too.

## Practical Implementation Checklist

1. In the generated header, identify MMIO register block structs by volatile
   member storage, including typedef-based volatile aliases.
2. Annotate those structs with `swift_attr("~Copyable")`.
3. Generate Swift hardware entry point vars for simple `*_hw` macros when
   needed.
4. Generate Swift hardware entry point vars for complex aliases that the
   importer does not transport.
5. Keep those entry points typed as `UnsafeMutablePointer<T>` unless there is a
   strong reason not to.
6. Validate with:
   `timerawl` for live changing reads
   `gpio_out` / `gpio_oe` / `gpio_in` for writes and observable state changes

## Current Working Assumption

The present evidence suggests that for many Pico SDK MMIO structs:

- `~Copyable` on the imported C register block type is the crucial value-model
  fix
- once that is in place, direct imported member access may be sufficient
- Swift-side overlays should be used sparingly, mainly to fill importer gaps

That is the intended direction unless later testing shows cases where direct
imported access is still insufficient.

## Testing code

```
func validateMMIO() {
    let t1 = timer0_hw.pointee.timerawl
    sleep_ms(10)
    let t2 = timer0_hw.pointee.timerawl

    print("MMIO timer read #1: \(t1)")
    print("MMIO timer read #2: \(t2)")
    print("MMIO timer changed: \(t1 != t2)")

    let hwcopy/*: NewClassName*/ = timer0_hw.pointee

    let xtt1 = hwcopy.timerawl
    sleep_ms(10)
    let xtt2 = hwcopy.timerawl


    print("MMIO timer read x#1: \(xtt1)")
    print("MMIO timer read x#2: \(xtt2)")
    print("MMIO timer changedx: \(xtt1 != xtt2) \(timer0_hw.pointee.ints)")

    let gpioMask: UInt32 = 1 << 25

    gpio_set_function(25, GPIO_FUNC_SIO)

    let originalOE = sio_hw.pointee.gpio_oe
    let originalOut = sio_hw.pointee.gpio_out

    print("MMIO gpio_oe initial:  0x\(String(originalOE, radix: 16))")
    print("MMIO gpio_out initial: 0x\(String(originalOut, radix: 16))")
    print("MMIO gpio_in initial:  0x\(String(sio_hw.pointee.gpio_in, radix: 16))")

    sio_hw.pointee.gpio_oe = originalOE | gpioMask
    let oeAfterEnable = sio_hw.pointee.gpio_oe
    print("MMIO gpio_oe after enabling GPIO25 output: 0x\(String(oeAfterEnable, radix: 16))")
    print("MMIO gpio_oe bit set validation: \((oeAfterEnable & gpioMask) != 0)")

    sio_hw.pointee.gpio_out = originalOut | gpioMask
    let outHigh = sio_hw.pointee.gpio_out
    let inHigh = sio_hw.pointee.gpio_in
    print("MMIO gpio_out after driving high: 0x\(String(outHigh, radix: 16))")
    print("MMIO gpio_in after driving high:  0x\(String(inHigh, radix: 16))")
    print("MMIO gpio_out high validation: \((outHigh & gpioMask) != 0)")
    print("MMIO gpio_in high observation:   \((inHigh & gpioMask) != 0)")

    sleep_ms(500)

    sio_hw.pointee.gpio_out = originalOut & ~gpioMask
    let outLow = sio_hw.pointee.gpio_out
    let inLow = sio_hw.pointee.gpio_in
    print("MMIO gpio_out after driving low: 0x\(String(outLow, radix: 16))")
    print("MMIO gpio_in after driving low:  0x\(String(inLow, radix: 16))")
    print("MMIO gpio_out low validation: \((outLow & gpioMask) == 0)")
    print("MMIO gpio_in low observation: \((inLow & gpioMask) == 0)")

    sio_hw.pointee.gpio_out = originalOut
    sio_hw.pointee.gpio_oe = originalOE
}
```