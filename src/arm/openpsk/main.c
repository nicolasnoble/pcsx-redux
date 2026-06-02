/*
 * OpenPSK - CLK_STOP sleep milestone. Boots, enables the LCD, draws a static frame, then enters the
 * battery-faithful idle loop: instead of busy-spinning, it SLEEPS via CLK_STOP and wakes on the
 * 1 Hz RTC tick. Each wake it reads the current time (date/time SWI) and updates the LCD, proving:
 *
 *   - cheap idle:   the core executes ~no instructions while asleep (a handful per wake, not ~4M/s).
 *   - time advances: the RTC keeps ticking while the CPU clock is stopped (it runs off a separate
 *                    oscillator), so GetBcdTime returns a later value on each wake.
 *   - LCD updates:  the displayed time word changes across wakes; a wake counter increments.
 *
 * Wake path: crt0 installs the IRQ vector at 0x18 -> irq_service (irq.S), which acknowledges the
 * RTC request and returns. We unmask IRQ-9 (RTC) and clear the CPU I-bit before the first sleep.
 *
 * VRAM proof rows (one 32-bit word per row, LSB = column 0):
 *   row 2 = t0      (GetBcdTime before the first sleep)
 *   row 4 = tNow    (GetBcdTime after the latest wake)   -> advances past t0
 *   row 6 = wakes   (number of sleep/wake cycles)         -> increments ~once per second
 */

#include "hardware.h"
#include "swi.h"

void main(void) {
    psk_lcd_enable();

    volatile unsigned int *vram = psk_vram_rows();  /* one 32-bit word per row, LSB = column 0 */

    /* Static frame so the LCD is visibly on (border box + both diagonals), drawn once at boot. */
    for (int row = 0; row < LCD_HEIGHT; row++) {
        unsigned int bits = 0;
        for (int col = 0; col < LCD_WIDTH; col++) {
            int lit = (row == 0) || (row == LCD_HEIGHT - 1) ||
                      (col == 0) || (col == LCD_WIDTH - 1) ||
                      (row == col) || (row == LCD_WIDTH - 1 - col);
            if (lit) bits |= (1u << col);
        }
        vram[row] = bits;
    }

    unsigned t0 = psk_swi_get_bcd_time();
    vram[2] = t0;

    /* Arm the wake path: enable the RTC interrupt and unmask IRQs at the CPU. */
    psk_int_unmask(INT_RTC);
    psk_enable_irq();

    unsigned wakes = 0;
    for (;;) {
        /* Sleep until the next RTC tick. The CPU clock is stopped here - no host CPU burned -
         * yet the RTC advances, so the read after wakeup reflects a later time. */
        psk_sleep();

        vram[4] = psk_swi_get_bcd_time();  /* current time - advances each wake */
        vram[6] = ++wakes;                 /* wake counter - proves the loop iterates via sleep */
    }
}
