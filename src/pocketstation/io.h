#pragma once

namespace IO {
enum {
    F_CTRL = 0x06000000,       // REGRemap (PDA HW spec): WRAM remap (write 3) + FLASHVIR/GENREM.
    F_STAT = 0x06000004,       // FLASHREMAPStatus.
    F_BANK_FLG = 0x06000008,   // FLASHACTIVEBlocks.
    F_WAIT1 = 0x0600000C,      // Undocumented (donor name kept).
    // FLASHDataController (PDA HW spec Appendix A, reset 0x14). Controls flash programming:
    //   bit0 ENPRG, bit1 LOCK, bit2 BUSY (read: 1=idle/done), bit3 STDBY, bit4 WAIT,
    //   bit5 LOADPAGE, bit6 LOADSGN. The flash data-write sequence arms it (ENPRG|LOADPAGE)
    //   then runs the JEDEC unlock; see Bus::flashProgramWrite. (Donor mislabelled this F_WAIT2.)
    FLASH_CTRL = 0x06000010,
    F_SN_LO = 0x06000300,
    F_SN_HI = 0x06000302,
    F_CAL = 0x06000308,
    INT_LATCH = 0x0A000000,
    INT_INPUT = 0x0A000004,
    INT_MASK_READ = 0x0A000008,
    INT_MASK_SET = 0x0A000008,
    INT_MASK_CLR = 0x0A00000C,
    INT_ACK = 0x0A000010,
    T0_RELOAD = 0x0A800000,
    T0_MODE = 0x0A800008,
    T1_RELOAD = 0x0A800010,
    T1_MODE = 0x0A800018,
    T2_RELOAD = 0x0A800020,
    T2_MODE = 0x0A800028,
    CLK_MODE = 0x0B000000,
    CLK_STOP = 0x0B000004,  // write bit0=1 -> stop the CPU clock (sleep) until a wake IRQ
    RTC_MODE = 0x0B800000,
    RTC_ADJUST = 0x0B800004,
    RTC_TIME = 0x0B800008,
    RTC_DATE = 0x0B80000C,
    COM_MODE = 0x0C000000,
    COM_STAT1 = 0x0C000004,  // bit1 = error
    COM_DATA = 0x0C000008,   // RX/TX byte
    COM_CTRL1 = 0x0C000010,
    COM_STAT2 = 0x0C000014,  // bit0 = ready (8 bits transferred)
    COM_CTRL2 = 0x0C000018,
    LCD_MODE = 0x0D000000,
    LCD_CAL = 0x0D000004,
    IOP_CTRL = 0x0D800000,
    IOP_STAT = 0x0D800004,
    IOP_STOP = 0x0D800004,
    IOP_START = 0x0D800008,
    IOP_DATA = 0x0D80000C,
    DAC_CTRL = 0x0D800010,
    DAC_DATA = 0x0D800014,
    BATT_CTRL = 0x0D800020,
};
} // End namespace IO