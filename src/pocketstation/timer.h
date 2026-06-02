#pragma once
#include "types.h"

struct Timer {
    u32 mode;
    u16 counter;
    u16 reload;

    void reset() {
        mode = 0;
        counter = 0;
        reload = 0;
    }
};