# PocketStation

Emulation of the Sony PocketStation (SCPH-4000): an ARM7TDMI-based memory-card
peripheral with a 32x32 mono LCD, RTC, IR, and a serial link to the PSX over the
memory-card slot.

## Origin and credit

The emulation core in this directory is based on **PocketBoyAdvance** by
wheremyfoodat (https://github.com/wheremyfoodat). Huge thanks for writing a clean
ARM7TDMI core and PocketStation I/O map and for making it available. The original
project lives at https://github.com/wheremyfoodat/PocketBoyAdvance.

What changed bringing it in-tree:

- Dropped the standalone Qt front-end; the LCD is surfaced through an
  OpenGL/ImGui window like the rest of pcsx-redux.
- Restructured into a flat module that drops into the normal `src/` build.
- The goal here is a *hardware-faithful* core: the scaffolding the original used
  to coax a retail kernel to boot (a patched kernel byte, hardcoded interrupt
  cadences) is being replaced with real timer/RTC/COM modeling so the retail
  kernel runs unpatched, and so a future open-source kernel can run on the same
  hardware model. See docs/pocketstation.md in the psx-spx documentation for the
  register and SWI reference this is built against.

## Layout

- `cpu.{h,cc}` + `cpu/` - ARM7TDMI core and the ARM/Thumb instruction tables.
- `bus.{h,cc}` - memory map, FLASH banking, I/O registers, interrupts.
- `lcd.{h,cc}` - 32x32 1bpp framebuffer.
- `io.h` - register address map.
