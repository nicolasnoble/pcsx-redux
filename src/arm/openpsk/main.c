/*
 * OpenPSK - RTC date/time milestone. Boots, enables the LCD, draws a border+X, then exercises the
 * documented date/time SWIs and renders the results so a VRAM dump proves both the SWI ABI and the
 * emulator's RTC actually ticking:
 *
 *   1. GetBcdTime() once (t0), spin enough emulated cycles for >= 1 RTC second to pass (the RTC runs
 *      at 1 Hz, ~3997696 ARM cycles/second), GetBcdTime() again (t1). t1 != t0 proves the RTC clock
 *      ADVANCED on its own - the de-fake of the previously-static rtc struct.
 *   2. SetBcdDateTime() to a known date/time via the RTC_MODE/RTC_ADJUST path, then GetBcdTime()/
 *      GetBcdDate() read it back, proving the set path round-trips.
 *   3. A custom SWI (1Ah) confirms dispatch still reaches the high table slots after renumbering.
 *
 * Proof rows the harness checks (one 32-bit word per VRAM row, LSB = column 0):
 *   row 2 = t0                 (GetBcdTime, host-seeded)
 *   row 3 = t1                 (GetBcdTime after the spin)        -> TICK pass if t1 != t0
 *   row 4 = d0                 (GetBcdDate, host-seeded; informational)
 *   row 5 = t2                 (GetBcdTime after SetBcdDateTime)  -> SET-time pass if min/hour/dow match
 *   row 6 = d2                 (GetBcdDate after SetBcdDateTime)  -> SET-date pass if == DATE_SET
 *   row 7 = magic              (SWI 1Ah)                          -> == 0xABCD1234
 */

#include "hardware.h"
#include "swi.h"

/* Known values to program via SWI 0Ch, in the 0Dh/0Eh formats (all BCD).
 * time: seconds 0x30, minutes 0x45, hours 0x12, day-of-week 0x03 (Tuesday). */
#define TIME_SET 0x03124530u
/* date: day 0x02, month 0x06, year (4-digit) 0x2026. SetBcdDateTime stores the low 2 year digits in
 * RTC_DATE; GetBcdDate re-attaches the 0x20 century, so the read-back equals DATE_SET exactly. */
#define DATE_SET 0x20260602u

void main(void) {
    psk_lcd_enable();

    /* (1) Prove the RTC ticks: read, burn >= 1 emulated second, read again. */
    unsigned t0 = psk_swi_get_bcd_time();
    unsigned d0 = psk_swi_get_bcd_date();

    /* ~4M iterations of a volatile loop is well over 3997696 ARM cycles, so at least one 1 Hz RTC
     * rising edge falls inside the window and the second read must differ from the first. */
    for (volatile unsigned i = 0; i < 4000000u; i++) {
    }

    unsigned t1 = psk_swi_get_bcd_time();

    /* (2) Prove the set path: program a known date/time, then read it back. */
    psk_swi_set_bcd_date_time(DATE_SET, TIME_SET);
    unsigned t2 = psk_swi_get_bcd_time();
    unsigned d2 = psk_swi_get_bcd_date();

    /* (3) Custom SWI dispatch still reaches the renumbered high slots. */
    unsigned magic = psk_swi_magic();

    volatile unsigned int *vram = psk_vram_rows();  /* one 32-bit word per row, LSB = column 0 */

    for (int row = 0; row < LCD_HEIGHT; row++) {
        unsigned int bits = 0;
        for (int col = 0; col < LCD_WIDTH; col++) {
            int lit = (row == 0) || (row == LCD_HEIGHT - 1) ||      /* top/bottom edges */
                      (col == 0) || (col == LCD_WIDTH - 1) ||       /* left/right edges */
                      (row == col) ||                               /* main diagonal */
                      (row == LCD_WIDTH - 1 - col);                 /* anti-diagonal */
            if (lit) bits |= (1u << col);
        }
        vram[row] = bits;  /* 32-bit store; the emulator's VRAM path is word-granular */
    }

    /* Overwrite proof rows with the raw SWI results so the harness can verify them. */
    vram[2] = t0;
    vram[3] = t1;
    vram[4] = d0;
    vram[5] = t2;
    vram[6] = d2;
    vram[7] = magic;

    for (;;) {
        /* boot + draw + date/time round-trip done */
    }
}
