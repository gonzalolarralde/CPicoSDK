# Binary Size Analysis

This document describes a practical workflow to analyze RP2xxx binary growth (`.elf` / `.uf2`) and attribute size changes to concrete sections/symbols.

## What To Measure First

1. `ELF` load image size (flash + RAM metadata).
2. `UF2` file size (container format, usually much larger than raw flash payload).
3. Flash-driving sections (`.text`, `.rodata`, loadable `.data`).
4. Largest symbols in the final linked image.

## Tools Used

- `ls -lh`
- `arm-none-eabi-size`
- `arm-none-eabi-objdump`
- `arm-none-eabi-nm`
- `rg` (optional filtering)

In this repo, the toolchain binaries are typically under:

`Example/.build/plugins/PrepareEnvironmentPlugin/outputs/pico-sdk-bundle/toolchain/14_2_Rel1/bin/`

## Core Commands

```bash
# 1) Quick artifact sizes
ls -lh Example/.build/armv7em-none-none-eabi/release/Example.elf \
       Example/.build/armv7em-none-none-eabi/release/Example.uf2

# 2) Aggregate ELF memory classes
arm-none-eabi-size Example/.build/armv7em-none-none-eabi/release/Example.elf

# 3) Section-level breakdown
arm-none-eabi-size -A Example/.build/armv7em-none-none-eabi/release/Example.elf | sort -k2 -nr

# 4) Full section table with addresses (VMA/LMA)
arm-none-eabi-objdump -h Example/.build/armv7em-none-none-eabi/release/Example.elf

# 5) Largest symbols in final image
arm-none-eabi-nm -S --size-sort --radix=d \
  Example/.build/armv7em-none-none-eabi/release/Example.elf | tail -n 120
```

## How To Read Conclusions

1. `UF2` is not raw payload size.
2. `UF2` often looks close to ~2x flash payload due block framing/padding.
3. `ELF` includes debug sections (`.debug_*`), so do not use raw ELF file size as device footprint.
4. Use `arm-none-eabi-size` (`text`, `data`, `bss`) + section/symbol views for footprint attribution.
5. If one large symbol dominates (firmware blobs/tables), optimize feature set first, not micro-optimizing app code.

## Quick Case Analysis (Current)

Observed artifacts:

- `Example.uf2`: ~`1.0 MiB`
- `Example.elf`: ~`4.0 MiB` (includes debug info)
- `arm-none-eabi-size`:
  - `text=530076`
  - `data=68`
  - `bss=51200`
  - `dec=581344`

Key section signal (`-A`):

- `.text`: `232540`
- `.rodata`: `276388`
- `.data`: `15484`
- Debug sections are very large in ELF but do not explain UF2 growth.

Top symbol signal (`nm --size-sort`):

- `w43439A0_7_95_49_00_combined`: `225240` bytes (`.rodata`, CYW43 firmware blob)
- Significant Unicode normalization tables are also present in `.rodata`.
- `PSRAMAllocator` symbols are comparatively small (order of a few KiB total text), and `TLSF` is also much smaller than the firmware blob.

### Practical conclusion

The jump from ~`450 KiB` UF2 class to ~`1028 KiB` UF2 class is not primarily from PSRAM allocator logic itself. The dominant growth is from linked feature/data payloads (notably CYW43 firmware blob, plus Unicode/table data), while allocator code is a minor contributor.

## Recommended A/B Method (General)

To validate any hypothesis, compare two builds and diff:

1. `arm-none-eabi-size` output.
2. `arm-none-eabi-size -A` section totals.
3. Top `nm` symbols.

Store outputs:

```bash
arm-none-eabi-size Example.elf > size.txt
arm-none-eabi-size -A Example.elf | sort -k2 -nr > sections.txt
arm-none-eabi-nm -S --size-sort --radix=d Example.elf > symbols.txt
```

Then diff `size.txt`, `sections.txt`, `symbols.txt` between build A and B.
