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

// clang-format off

CESTER_TEST(raceGetLocPAndNop, test_instances,
    int resetDone = resetCDRom();
    if (!resetDone) {
        cester_assert_true(resetDone);
        return;
    }

    int seekDone = seekPTo(0x70, 0x19, 0x73);
    if (!seekDone) {
        cester_assert_true(seekDone);
        return;
    }

    initializeTime();
    CDROM_REG0 = 0;
    CDROM_REG1 = CDL_GETLOCP;
    CDROM_REG1 = CDL_NOP;
    uint8_t ctrl0 = CDROM_REG0 & ~3;

    uint32_t ackTime = waitCDRomIRQ();
    uint8_t cause1 = ackCDRomCause();
    uint8_t ctrl1 = CDROM_REG0 & ~3;
    uint8_t response1[16];
    uint8_t responseSize1 = readResponse(response1);
    uint8_t ctrl2 = CDROM_REG0 & ~3;
    CDROM_REG0 = 1;
    uint8_t cause1b = CDROM_REG3_UC;

    initializeTime();
    uint32_t timeout = 150000;
    int gotIRQ = waitCDRomIRQWithTimeout(&timeout);

    cester_assert_uint_eq(3, cause1);
    cester_assert_uint_eq(0xe0, cause1b);
    cester_assert_uint_eq(0x98, ctrl0);
    cester_assert_uint_eq(0x38, ctrl1);
    cester_assert_uint_eq(0x18, ctrl2);
    cester_assert_uint_eq(2, response1[0]);
    cester_assert_uint_eq(1, responseSize1);
    cester_assert_false(gotIRQ);
    cester_assert_uint_ge(ackTime, 500);
    cester_assert_uint_lt(ackTime, 7000);
    ramsyscall_printf("GetLocP followed by Nop, ack in %ius\n", ackTime);
)

CESTER_TEST(raceNopAndGetLocP, test_instances,
    int resetDone = resetCDRom();
    if (!resetDone) {
        cester_assert_true(resetDone);
        return;
    }

    int seekDone = seekPTo(0x70, 0x19, 0x73);
    if (!seekDone) {
        cester_assert_true(seekDone);
        return;
    }

    initializeTime();
    CDROM_REG0 = 0;
    CDROM_REG1 = CDL_NOP;
    CDROM_REG1 = CDL_GETLOCP;
    uint8_t ctrl0 = CDROM_REG0 & ~3;

    uint32_t ackTime = waitCDRomIRQ();
    uint8_t cause1 = ackCDRomCause();
    uint8_t ctrl1 = CDROM_REG0 & ~3;
    uint8_t response1[16];
    uint8_t responseSize1 = readResponse(response1);
    uint8_t ctrl2 = CDROM_REG0 & ~3;
    CDROM_REG0 = 1;
    uint8_t cause1b = CDROM_REG3_UC;

    initializeTime();
    uint32_t timeout = 150000;
    int gotIRQ = waitCDRomIRQWithTimeout(&timeout);

    cester_assert_uint_eq(3, cause1);
    cester_assert_uint_eq(0xe0, cause1b);
    cester_assert_uint_eq(0x98, ctrl0);
    cester_assert_uint_eq(0x38, ctrl1);
    cester_assert_uint_eq(0x18, ctrl2);
    cester_assert_uint_eq(5, response1[0]);
    cester_assert_uint_eq(0, response1[1]);
    cester_assert_uint_eq(8, responseSize1);
    cester_assert_false(gotIRQ);
    cester_assert_uint_ge(ackTime, 500);
    cester_assert_uint_lt(ackTime, 7000);
    ramsyscall_printf("Nop followed by GetLocP, ack in %ius\n", ackTime);
)

CESTER_TEST(raceNopAndGetTD1, test_instance,
    uint32_t imask = IMASK;

    IMASK = imask | IRQ_CDROM;

    int resetDone = resetCDRom();
    if (!resetDone) {
        cester_assert_true(resetDone);
        return;
    }

    initializeTime();

    CDROM_REG0 = 0;
    CDROM_REG2 = 1;
    CDROM_REG1 = CDL_NOP;
    CDROM_REG1 = CDL_GETTD;
    uint8_t ctrl0 = CDROM_REG0 & ~3;

    uint32_t ackTime = waitCDRomIRQ();
    uint8_t cause1 = ackCDRomCause();
    uint8_t ctrl1 = CDROM_REG0 & ~3;
    uint8_t response1[16];
    uint8_t responseSize1 = readResponse(response1);
    uint8_t ctrl2 = CDROM_REG0 & ~3;
    CDROM_REG0 = 1;
    uint8_t cause1b = CDROM_REG3_UC;

    initializeTime();
    uint32_t timeout = 150000;
    int gotIRQ = waitCDRomIRQWithTimeout(&timeout);

    cester_assert_uint_eq(3, cause1);
    cester_assert_uint_eq(0xe0, cause1b);
    cester_assert_uint_eq(2, response1[0]);
    cester_assert_uint_eq(0, response1[1]);
    cester_assert_uint_eq(2, response1[2]);
    cester_assert_uint_eq(3, responseSize1);
    cester_assert_uint_eq(0x90, ctrl0);
    cester_assert_uint_eq(0x38, ctrl1);
    cester_assert_uint_eq(0x18, ctrl2);
    cester_assert_false(gotIRQ);
    cester_assert_uint_ge(ackTime, 500);
    cester_assert_uint_lt(ackTime, 7000);
    ramsyscall_printf("Nop followed by GetTD1: ack in %ius\n", ackTime);

    IMASK = imask;
)

CESTER_TEST(raceGetTD1AndNop, test_instance,
    uint32_t imask = IMASK;

    IMASK = imask | IRQ_CDROM;

    int resetDone = resetCDRom();
    if (!resetDone) {
        cester_assert_true(resetDone);
        return;
    }

    initializeTime();

    CDROM_REG0 = 0;
    CDROM_REG2 = 1;
    CDROM_REG1 = CDL_GETTD;
    CDROM_REG1 = CDL_NOP;
    uint8_t ctrl0 = CDROM_REG0 & ~3;

    uint32_t ackTime = waitCDRomIRQ();
    uint8_t cause1 = ackCDRomCause();
    uint8_t ctrl1 = CDROM_REG0 & ~3;
    uint8_t response1[16];
    uint8_t responseSize1 = readResponse(response1);
    uint8_t ctrl2 = CDROM_REG0 & ~3;
    CDROM_REG0 = 1;
    uint8_t cause1b = CDROM_REG3_UC;

    initializeTime();
    uint32_t timeout = 150000;
    int gotIRQ = waitCDRomIRQWithTimeout(&timeout);

    cester_assert_uint_eq(5, cause1);
    cester_assert_uint_eq(0xe0, cause1b);
    cester_assert_uint_eq(3, response1[0]);
    cester_assert_uint_eq(0x20, response1[1]);
    cester_assert_uint_eq(2, responseSize1);
    cester_assert_uint_eq(0x90, ctrl0);
    cester_assert_uint_eq(0x38, ctrl1);
    cester_assert_uint_eq(0x18, ctrl2);
    cester_assert_false(gotIRQ);
    cester_assert_uint_ge(ackTime, 500);
    cester_assert_uint_lt(ackTime, 7000);
    ramsyscall_printf("GetTD1 followed by Nop: ack in %ius\n", ackTime);

    IMASK = imask;
)

CESTER_TEST(cdlSeekP2to80, test_instance,
    uint32_t imask = IMASK;

    IMASK = imask | IRQ_CDROM;

    int resetDone = resetCDRom();
    if (!resetDone) {
        cester_assert_true(resetDone);
        return;
    }

    int seekDone = seekPTo(0, 2, 0);
    if (!seekDone) {
        cester_assert_true(seekDone);
        return;
    }

    int setLocDone = setLoc(0x80, 0, 0);
    if (!setLocDone) {
        cester_assert_true(setLocDone);
        return;
    }

    initializeTime();
    // wait 50ms for things to settle
    while (updateTime() < 50000);
    initializeTime();

    CDROM_REG0 = 0;
    CDROM_REG1 = CDL_SEEKP;
    uint8_t ctrl0 = CDROM_REG0 & ~3;

    uint32_t ackTime = waitCDRomIRQ();
    uint8_t cause1 = ackCDRomCause();
    uint8_t ctrl1 = CDROM_REG0 & ~3;
    uint8_t response1[16];
    uint8_t responseSize1 = readResponse(response1);
    uint8_t ctrl2 = CDROM_REG0 & ~3;
    CDROM_REG0 = 1;
    uint8_t cause1b = CDROM_REG3_UC;

    CDROM_REG0 = 0;
    CDROM_REG1 = CDL_NOP;
    uint8_t ctrl2b = CDROM_REG0 & ~3;

    initializeTime();
    uint32_t ackTime2 = waitCDRomIRQ();
    uint8_t cause2 = ackCDRomCause();
    uint8_t ctrl3 = CDROM_REG0 & ~3;
    uint8_t response2[16];
    uint8_t responseSize2 = readResponse(response2);
    uint8_t ctrl4 = CDROM_REG0 & ~3;
    CDROM_REG0 = 1;
    uint8_t cause2b = CDROM_REG3_UC;

    initializeTime();
    uint32_t timeout = 20000000;
    int gotIRQ = waitCDRomIRQWithTimeout(&timeout);
    uint8_t cause3 = ackCDRomCause();
    uint8_t ctrl5 = CDROM_REG0 & ~3;
    uint8_t response3[16];
    uint8_t responseSize3 = readResponse(response3);
    uint8_t ctrl6 = CDROM_REG0 & ~3;
    CDROM_REG0 = 1;
    uint8_t cause3b = CDROM_REG3_UC;

    cester_assert_uint_eq(3, cause1);
    cester_assert_uint_eq(3, cause2);
    cester_assert_uint_eq(0xe0, cause1b);
    cester_assert_uint_eq(0xe0, cause2b);
    cester_assert_uint_eq(2, response1[0]);
    cester_assert_uint_eq(1, responseSize1);
    cester_assert_uint_eq(2, response2[0]);
    cester_assert_uint_eq(1, responseSize2);
    cester_assert_uint_eq(6, response3[0]);
    cester_assert_uint_eq(0x10, response3[1]);
    cester_assert_uint_eq(2, responseSize3);
    cester_assert_uint_eq(0x98, ctrl0);
    cester_assert_uint_eq(0x38, ctrl1);
    cester_assert_uint_eq(0x18, ctrl2);
    cester_assert_uint_eq(0x98, ctrl2b);
    cester_assert_uint_eq(0x38, ctrl3);
    cester_assert_uint_eq(0x18, ctrl4);
    cester_assert_uint_eq(0x38, ctrl5);
    cester_assert_uint_eq(0x18, ctrl6);
    cester_assert_true(gotIRQ);
    cester_assert_uint_ge(ackTime, 500);
    cester_assert_uint_lt(ackTime, 7000);
    cester_assert_uint_ge(ackTime2, 500);
    cester_assert_uint_lt(ackTime2, 7000);
    ramsyscall_printf("SeekP from 00:02:00 to 80:00:00 with Nop in between: ack in %ius, ack2 in %ius, errored in %ius\n", ackTime, ackTime2, timeout);

    IMASK = imask;
)
