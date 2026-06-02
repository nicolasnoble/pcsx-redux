/*
 * OpenPSK - minimal first boot. Enable the LCD and draw a recognizable pattern, then spin.
 *
 * This is deliberately tiny: it is the "custom PocketStation code runs on the emulated device"
 * gate and the OpenPSK seed at once. The pattern (full border + an X) is unmistakable in the
 * 32x32 framebuffer, so a VRAM dump proves OUR code executed - distinct from the retail
 * kernel's font glyphs and from uninitialized garbage.
 */

#include "hardware.h"

void main(void) {
    psk_lcd_enable();

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

    for (;;) {
        /* boot+draw done; nothing else to do yet */
    }
}
