/*
 * OpenPSK - minimal hardware register map for the PocketStation (ARM7TDMI).
 *
 * This is the seed of the PocketStation SDK, the src/arm analog of src/mips. Register
 * addresses and the LCD_MODE bitfield are documented in psx-spx (docs/pocketstation.md).
 * Only the registers the boot/LCD path needs are defined here; the set grows as OpenPSK does.
 */
#pragma once

#define PSK_MMIO(addr) (*(volatile unsigned int *)(addr))

/* Memory / FLASH control. Writing 3 (byte) to F_CTRL maps the 2 KiB WRAM over the boot shadow. */
#define F_CTRL 0x06000000

/* LCD controller. VRAM is 128 bytes = 32x32 @ 1bpp, row-major, 4 bytes/row, LSB = column 0. */
#define LCD_MODE 0x0D000000 /* drawMode:3 cpen:1 refreshRate:2 enabled:bit6 rotate:bit7 */
#define LCD_VRAM 0x0D000100

/* LCD_MODE value the retail kernel boots with: cpen=1, refreshRate=1, enabled=1. */
#define LCD_MODE_ENABLED 0x58

#define LCD_WIDTH 32
#define LCD_HEIGHT 32

/* One 32-bit word per row (bit c = pixel column c, LSB first). */
static inline volatile unsigned int *psk_vram_rows(void) { return (volatile unsigned int *)LCD_VRAM; }

static inline void psk_lcd_enable(void) { PSK_MMIO(LCD_MODE) = LCD_MODE_ENABLED; }
