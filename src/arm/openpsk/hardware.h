/*
 * OpenPSK - minimal hardware register map for the PocketStation (ARM7TDMI).
 *
 * This is the seed of the PocketStation SDK, the src/arm analog of src/mips. Register
 * addresses and the LCD_MODE bitfield are documented in psx-spx (docs/pocketstation.md).
 * Only the registers the boot/LCD path needs are defined here; the set grows as OpenPSK does.
 */
#pragma once

#define PSK_MMIO(addr) (*(volatile unsigned int *)(addr))
#define PSK_MMIO16(addr) (*(volatile unsigned short *)(addr))

/* Memory / FLASH control. Writing 3 (byte) to F_CTRL maps the 2 KiB WRAM over the boot shadow. */
#define F_CTRL 0x06000000

/* ---- Flash memory programming (PDA Hardware Spec, "Write accesses" + Appendix A) -----------------
 * Flash is read-only memory that is programmed through a controller. A plain store does NOT modify
 * it; the documented write sequence is: arm FLASH_CTRL (ENPRG|LOADPAGE), run the JEDEC unlock
 * (0xFFAA->0x080055AA, 0xFF55->0x08002A54, 0xFFA0->0x080055AA), write up to 64 halfwords to the
 * target sector, poll BUSY, then disarm. The command/data interface is at the PHYSICAL base
 * (0x08000000); SWI 3 (relative) translates app-relative addresses to physical before driving it. */
#define FLASH_CTRL 0x06000010    /* FLASHDataController */
#define FLASH_ENPRG    (1u << 0) /* enable programming */
#define FLASH_LOCK     (1u << 1) /* 1 = disable data writes */
#define FLASH_BUSY     (1u << 2) /* read: 1 = idle/done, 0 = write in progress */
#define FLASH_LOADPAGE (1u << 5) /* enable page (sector) writes */
#define FLASH_LOADSGN  (1u << 6) /* enable system-signature writes */

#define FLASH_BASE_ABS   0x08000000u /* physical flash; SWI 16 absolute sector 0. */
#define FLASH_BASE_REL   0x02000000u /* virtual app flash; SWI 3 relative sector 0. */
#define FLASH_UNLOCK_A   0x080055AAu /* JEDEC command address 1. */
#define FLASH_UNLOCK_B   0x08002A54u /* JEDEC command address 2. */
#define FLASH_SECTOR_BYTES 128       /* one sector = 128 bytes = 64 halfwords. */

/* LCD controller. VRAM is 128 bytes = 32x32 @ 1bpp, row-major, 4 bytes/row, LSB = column 0. */
#define LCD_MODE 0x0D000000 /* drawMode:3 cpen:1 refreshRate:2 enabled:bit6 rotate:bit7 */
#define LCD_VRAM 0x0D000100

/* Real-Time Clock (psx-spx docs/pocketstation.md). RTC_MODE selects the field that RTC_ADJUST
 * increments (and pauses the clock); RTC_TIME/RTC_DATE are read-only BCD views. */
#define RTC_MODE   0x0B800000 /* bit0 Pause(0=Run/1Hz,1=Pause/4096Hz), bits1-3 select adjust field */
#define RTC_ADJUST 0x0B800004 /* write-only: increments the RTC_MODE-selected field by one */
#define RTC_TIME   0x0B800008 /* R: sec:8 min:8 hour:8 dow:8 (all BCD; dow 1=Sun..7=Sat) */
#define RTC_DATE   0x0B80000C /* R: day:8 month:8 _:8 year:8 (BCD; 2-digit year, no century) */

/* RTC_MODE field selectors (bits 1-3), used with RTC_ADJUST while the RTC is paused. */
#define RTC_FIELD_SECOND 0
#define RTC_FIELD_MINUTE 1
#define RTC_FIELD_HOUR   2
#define RTC_FIELD_DOW    3
#define RTC_FIELD_DAY    4
#define RTC_FIELD_MONTH  5
#define RTC_FIELD_YEAR   6

/* Interrupt controller (psx-spx docs/pocketstation.md). INT_INPUT bits: 0=Fire, 9=RTC square
 * wave (~1Hz), 11=Docked. INT_MASK_SET enables; INT_ACK clears latched requests. */
#define INT_MASK_SET 0x0A000008 /* W: 1-bits enable the matching interrupt */
#define INT_MASK_CLR 0x0A00000C /* W: 1-bits disable */
#define INT_ACK      0x0A000010 /* W: 1-bits acknowledge (clear) latched requests */
#define INT_RTC      (1u << 9)  /* RTC square-wave IRQ - the sleep wake source for this milestone */
#define INT_FIRE     (1u << 0)  /* Fire button IRQ (also wakes from sleep) */
#define INT_DOCKED   (1u << 11) /* Docking IRQ */

/* Clock control. Writing bit0=1 to CLK_STOP halts the CPU until a wake IRQ occurs (sleep mode). */
#define CLK_STOP 0x0B000004

/* LCD_MODE value the retail kernel boots with: cpen=1, refreshRate=1, enabled=1. */
#define LCD_MODE_ENABLED 0x58

#define LCD_WIDTH 32
#define LCD_HEIGHT 32

/* One 32-bit word per row (bit c = pixel column c, LSB first). */
static inline volatile unsigned int *psk_vram_rows(void) { return (volatile unsigned int *)LCD_VRAM; }

static inline void psk_lcd_enable(void) { PSK_MMIO(LCD_MODE) = LCD_MODE_ENABLED; }

/* Enable the given INT_INPUT bits as wake/IRQ sources. */
static inline void psk_int_unmask(unsigned bits) { PSK_MMIO(INT_MASK_SET) = bits; }

/* Unmask IRQs at the CPU (System mode, I-bit clear, FIQ left disabled). Call once before sleeping
 * so the wake IRQ is actually taken by the installed handler. */
static inline void psk_enable_irq(void) { __asm__ volatile("msr cpsr_c, #0x5F" ::: "memory"); }

/* Enter sleep mode: stop the CPU clock until a wake IRQ. Returns once the handler has run and the
 * core resumed (i.e. after the next enabled interrupt - the RTC tick, a Fire press, or docking). */
static inline void psk_sleep(void) { PSK_MMIO(CLK_STOP) = 1; }
