#pragma once
#include <array>
#include "types.h"

union LCDMode {
    u32 raw;
    struct {
        unsigned drawMode: 3;
        unsigned cpen: 1; // Nobody knows what this is, just like everything else here
        unsigned refreshRate: 2;
        unsigned enabled: 1; // Shows whether the LCD is enabled
        unsigned rotate: 1;  // If 1 then flip the screen

        unsigned padding: 24;
    };
};
static_assert(sizeof(LCDMode) == 4);

struct LCD {
    LCDMode mode;
    u32 calibrationValue;
    std::array<u8, 128> vram;

    void reset();
};