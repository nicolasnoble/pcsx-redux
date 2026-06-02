/*
 * OpenPSK - SWI-dispatch milestone. Boots, enables the LCD, draws a recognizable border+X, then
 * exercises the SWI exception path and renders the results so a VRAM dump proves the round-trip.
 *
 * The SWIs run BEFORE the border is fully committed below, but their results are stored into
 * dedicated rows AFTER drawing, so a correct dump means: (1) our code ran, (2) `swi #0` and
 * `swi #1` trapped to the 0x08 vector, dispatched through the table at 0xE0 by comment number,
 * (3) the argument round-tripped and the result returned, and (4) the `ldm {...,pc}^` exception
 * return restored state so main() kept running to completion (the border is intact).
 *
 * Proof rows (the harness checks these words exactly):
 *   row 2 == 0xABCD1234        (SWI #0 magic constant)
 *   row 3 == 0x55 + 0x100      (SWI #1 transform of the argument 0x55 -> 0x00000155)
 */

#include "hardware.h"
#include "swi.h"

void main(void) {
    psk_lcd_enable();

    /* Trap into the SWI handlers first; render their results last. */
    unsigned magic = psk_swi_magic();        /* expect 0xABCD1234 */
    unsigned xform = psk_swi_xform(0x55);     /* expect 0x00000155 */

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

    /* Overwrite two rows with the raw SWI return values so the harness can verify the round-trip. */
    vram[2] = magic;
    vram[3] = xform;

    for (;;) {
        /* boot + draw + SWI round-trip done; nothing else to do yet */
    }
}
