/*

MIT License

Copyright (c) 2022 PCSX-Redux authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

*/

#include "common/hardware/cdrom.h"
#include "common/hardware/hwregs.h"
#include "common/hardware/irq.h"

#undef unix
#define CESTER_NO_SIGNAL
#define CESTER_NO_TIME
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#include "exotic/cester.h"

#include "cester-hw.c"

// clang-format off

CESTER_TEST(cdlInitBasic, test_instance,
    initializeTime();

    uint32_t imask = IMASK;

    IMASK = imask | IRQ_CDROM;

    CDROM_REG0 = 1;
    CDROM_REG3 = 0x1f;
    CDROM_REG0 = 1;
    CDROM_REG2 = 0x1f;
    CDROM_REG0 = 0;
    CDROM_REG1 = CDL_INIT;

    uint32_t ackTime = waitCDRomIRQ();
    uint8_t cause1 = ackCDRomCause();
    uint8_t stat1 = getCDRomStat();

    uint32_t completeTime = waitCDRomIRQ() - ackTime;
    uint8_t cause2 = ackCDRomCause();
    uint8_t stat2 = getCDRomStat();

    cester_assert_uint_eq(3, cause1);
    cester_assert_uint_eq(2, cause2);
    cester_assert_uint_eq(0, stat1);
    cester_assert_uint_eq(0, stat2);
    cester_assert_uint_ge(ackTime, 800);
    cester_assert_uint_lt(ackTime, 5000);
    // These may be a bit flaky on real hardware, depending on the motors status when starting.
    cester_assert_uint_ge(completeTime, 50000);
    cester_assert_uint_lt(completeTime, 150000);
    ramsyscall_printf("CD-Rom controller initialized, ack in %ius, complete in %ius\n", ackTime, completeTime);

    IMASK = imask;
)
