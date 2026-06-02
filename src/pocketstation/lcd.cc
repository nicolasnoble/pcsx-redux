#include "lcd.h"

void LCD::reset() {
    vram.fill(0);
    mode.raw = 0;
    calibrationValue = 0;
}