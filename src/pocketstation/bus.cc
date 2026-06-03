#include "bus.h"
#include "io.h"

#include <ctime>

// Focused COM/INT tracing for reversing the kernel's handshake. Gated by comTrace. COM register
// accesses are always logged; INT mask/ack writes always; INT_INPUT/LATCH reads only while a
// command is active (they fire every loop iteration otherwise and would flood the log).
static const char* pskRegName(u32 addr) {
    switch (addr) {
        case IO::COM_MODE: return "COM_MODE";
        case IO::COM_STAT1: return "COM_STAT1";
        case IO::COM_DATA: return "COM_DATA";
        case IO::COM_CTRL1: return "COM_CTRL1";
        case IO::COM_STAT2: return "COM_STAT2";
        case IO::COM_CTRL2: return "COM_CTRL2";
        case IO::INT_INPUT: return "INT_INPUT";
        case IO::INT_LATCH: return "INT_LATCH";
        case IO::INT_MASK_SET: return "INT_MASK_SET/READ";
        case IO::INT_MASK_CLR: return "INT_MASK_CLR";
        case IO::INT_ACK: return "INT_ACK";
        default: return "?";
    }
}

void Bus::reset() {
    com.reset();
    irqMask = 0;
    irqFlags = 0;
    irqLatch = 0;
    iopData = 0;
    iopCtrl = 0;
    dacCtrl = 0; // Mute audio
    clkMode = 7; // Set CPU to 3.997696 MHz

    rtc.reset();              // deterministic fallback values...
    seedRtcFromHostClock();   // ...then overwrite with the real host wall-clock time.
    rtcMode = 0;

    flash.enabledBanks = 0; // Disable all FLASH banks
    flash.bankMappings.fill(0);
    flash.f_wait1 = 0;
    flash.dataCtrl = kFlashWAIT;  // reset value 0x14 = WAIT(bit4) | BUSY(bit2, synthesised on read).
    flash.progState = 0;
    remapFLASH();

    for (auto& e : timers) {
        e.reset();
    }

    rtcCountdown = kRtcHalfPeriodPaused;  // restart the RTC square-wave phase brisk (bit 9 low).
    halted = false;                       // power-on: CPU clock running.
}

// ---- RTC time-of-day -----------------------------------------------------------------------------
// The RTC fields are stored as BCD bytes (00h..99h) in u32 slots, matching the RTC_TIME/RTC_DATE
// register layout and the RTC_ADJUST increment path.
static u8 bcdToBin(u8 v) { return u8((v >> 4) * 10 + (v & 0x0f)); }

static u8 daysInMonthBin(u8 monthBin, u8 yearBin) {
    static const u8 dim[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (monthBin < 1 || monthBin > 12) return 31;
    u8 d = dim[monthBin - 1];
    // 2-digit year 00..99 -> 2000..2099, where every year%4==0 is a leap year (2000 included).
    // TODO: real century handling + the full Gregorian leap rule wait for HW ground truth.
    if (monthBin == 2 && (yearBin % 4) == 0) d = 29;
    return d;
}

// Seed the BCD calendar from the host wall clock so the displayed time is real. It then advances
// with emulated time via rtcAdvanceOneSecond(). TODO: this makes reset() non-deterministic (each
// run starts at a different time) - revisit when the module joins the savestate path.
void Bus::seedRtcFromHostClock() {
    const std::time_t t = std::time(nullptr);
    std::tm lt{};
#if defined(_WIN32)
    localtime_s(&lt, &t);
#else
    localtime_r(&t, &lt);
#endif
    const auto toBcd = [](int v) -> u32 { return u32(((v / 10) << 4) | (v % 10)); };
    rtc.seconds = toBcd(lt.tm_sec >= 60 ? 59 : lt.tm_sec);  // clamp a leap second into range.
    rtc.minutes = toBcd(lt.tm_min);
    rtc.hours = toBcd(lt.tm_hour);
    rtc.dayOfWeek = u32(lt.tm_wday + 1);  // tm_wday 0=Sunday -> RTC_TIME day-of-week 1=Sunday..7.
    rtc.days = toBcd(lt.tm_mday);
    rtc.months = toBcd(lt.tm_mon + 1);    // tm_mon is 0..11.
    rtc.years = toBcd(lt.tm_year % 100);  // RTC_DATE stores a 2-digit year (century lives elsewhere).
}

// Advance the BCD calendar by one second, propagating carries. Mirrors the field ranges the
// RTC_ADJUST path enforces (seconds/minutes 00..59, hours 00..23, day-of-week 1..7, day
// 01..len(month), month 01..12, year 00..99). Called once per 1 Hz RTC rising edge while running.
void Bus::rtcAdvanceOneSecond() {
    rtc.seconds = Helpers::incBCDByte(u8(rtc.seconds));
    if (rtc.seconds <= 0x59) return;
    rtc.seconds = 0;
    rtc.minutes = Helpers::incBCDByte(u8(rtc.minutes));
    if (rtc.minutes <= 0x59) return;
    rtc.minutes = 0;
    rtc.hours = Helpers::incBCDByte(u8(rtc.hours));
    if (rtc.hours <= 0x23) return;
    rtc.hours = 0;
    // A new day: advance day-of-week (1..7, wrapping) and the calendar day.
    rtc.dayOfWeek = (rtc.dayOfWeek % 7) + 1;
    rtc.days = Helpers::incBCDByte(u8(rtc.days));
    if (bcdToBin(u8(rtc.days)) <= daysInMonthBin(bcdToBin(u8(rtc.months)), bcdToBin(u8(rtc.years)))) return;
    rtc.days = 1;
    rtc.months = Helpers::incBCDByte(u8(rtc.months));
    if (rtc.months <= 0x12) return;
    rtc.months = 1;
    rtc.years = Helpers::incBCDByte(u8(rtc.years));
    if (rtc.years > 0x99) rtc.years = 0;
}

void Bus::requestInterrupt(int bit) {
    const u32 mask = 1 << bit;
    if ((irqFlags & mask) == 0) {
        irqFlags |= mask;
        // Latch seems to ignore masked out interrupts. 
        // Removing the & irqMask freezes the kernel when you press A
        irqLatch |= mask & irqMask;
    }
}

u16 Bus::read16Slow(u32 addr) {
    switch (addr) {
        // The following 2 registers seem to be some sort of serial number.
        // We return the same number as nocash.
        case IO::F_SN_LO: return 0x6BE7;
        case IO::F_SN_HI: return 0x426C;
        
        default: 
            Helpers::panic("16-bit read from unimplemented slow address: %08X\n", addr);
            break;
    }
}

void Bus::write16Slow(u32 addr, u16 val) {
    // Flash is omitted from the writeTable, so halfword writes to it land here: feed the documented
    // program sequence (JEDEC unlock + data phase). This is the path OpenPSK's flash-write SWIs use.
    if (addr >= kFlashBase && addr < kFlashBase + kFlashSize) {
        flashProgramWrite(addr, val);
        return;
    }
    Helpers::panic("16-bit write to unimplemented slow address: %08X (val %04X)\n", addr, val);
}

u32 Bus::read32Slow(u32 addr) {
    switch (addr) {
        // ---- COM link reads ------------------------------------------------------------------
        case IO::COM_DATA: {
            // Kernel reads the RX shift register (last byte clocked in). Reading does NOT change
            // ready: ready models "a byte transfer completed" and is the kernel's TX pacing signal
            // (cleared when it loads the next TX via a COM_DATA write, set when the host clocks the
            // next byte). The kernel only reads RX for bytes it cares about (command/address);
            // during the data phase it sends without reading, and those incoming dummies are simply
            // overwritten - no queue.
            if (comTrace) printf("[PSK] PC=%08X RD COM_DATA -> %02X\n", curPC, com.rx);
            return com.rx;
        }
        case IO::COM_STAT1:
            if (comTrace) printf("[PSK] PC=%08X RD COM_STAT1 -> %02X\n", curPC, com.error ? 2u : 0u);
            return com.error ? 0x2 : 0x0;  // bit1 = error.
        case IO::COM_STAT2:
            if (comTrace) printf("[PSK] PC=%08X RD COM_STAT2 -> %02X (ready=%d)\n", curPC, com.ready ? 1u : 0u, com.ready);
            return com.ready ? 0x1 : 0x0;  // bit0 = ready (a MOSI byte is waiting).
        case IO::COM_CTRL1:
            return com.ctrl1;
        case IO::COM_CTRL2:
            return com.ctrl2;
        case IO::COM_MODE:
            return com.mode;

        case IO::INT_INPUT:
            // Raw interrupt signal LEVELS. Bit 9 (the RTC square wave) is maintained as a live
            // oscillating level by Bus::tickRtc() off the cycle clock; the other bits are the
            // dock/button level reflectors and self-clearing IRQ sources. (The donor faked bit 9
            // here with a sticky requestInterrupt every 200 reads, which never fell and hung the
            // boot loop's falling-edge wait -- removed in favor of the real square wave.)
            if (comTrace && com.cmdActive) printf("[PSK] PC=%08X RD INT_INPUT -> %08X\n", curPC, irqFlags);
            return irqFlags;
        case IO::INT_LATCH: return irqLatch;
        case IO::INT_MASK_READ: return irqMask;
        case IO::RTC_TIME: return rtc.getTime();
        case IO::RTC_DATE: return rtc.getDate();
        case IO::LCD_MODE: return lcd.mode.raw;
        case IO::DAC_CTRL: return dacCtrl;
        case IO::F_BANK_FLG: return flash.enabledBanks;
        case IO::IOP_DATA: return iopData;
        case IO::IOP_CTRL: return iopCtrl;
        case IO::IOP_STAT: return 0; // Seems to always be 0
        case IO::CLK_MODE: {
            // Only turn on the "ready" bit after 4 reads.
            // Some games rely on reading 0 from the "ready" bit
            static int tries = 0;
            if (tries++ == 4) {
                clkMode |= 0x10;
            } else if (tries == 10) {
                tries = 0;
                clkMode &= ~0x10;
            }

            return clkMode; // Turn on ready flag
        }
        case IO::T1_MODE: return timers[1].mode;
        case IO::T2_MODE: return timers[2].mode;
        case IO::BATT_CTRL: return 0; // Undocumented
        case IO::F_CAL: return 0;
        case IO::F_CTRL: return 1; // No idea what this is meant to read. But bit 0 must be 1.
        case IO::F_STAT: return 0; // Undocumented
        case IO::F_WAIT1: return flash.f_wait1;
        case IO::FLASH_CTRL:
            // FLASHDataController. BUSY (bit2) reads 1 = "no write sequence active": our flash
            // writes complete instantly, so the device is always ready.
            return flash.dataCtrl | kFlashBUSY;

        default: {
            // FLASH bank mappings
            if (addr >= 0x06000100 && addr < 0x06000140) {
                const uint index = (addr & 0xff) >> 2;  // Index of the physical bank
                return flash.bankMappings[index];
            } else if (addr >= 0x0C800000 && addr < 0x0C800010) {
                printf("Read from %08X (stupid IR jazz)\n", addr);
                return 0;
            } else {
                Helpers::panic("32-bit read from unimplemented slow address: %08X\n", addr);
            }

            break;
        }
    }
}

void Bus::write32Slow(u32 addr, u32 val) {
    if (addr >= kFlashBase && addr < kFlashBase + kFlashSize) {
        // A 32-bit store into flash space = two halfword program writes (low then high). Flash is a
        // 16-bit device and the documented sequence is halfword-based; OpenPSK uses strh, but handle
        // word stores defensively so the program path is width-agnostic.
        flashProgramWrite(addr, u16(val & 0xFFFF));
        flashProgramWrite(addr + 2, u16(val >> 16));
        return;
    }
    if (addr >= 0x0D000100 && addr < 0x0D000180) {  // VRAM
        *(u32*)&lcd.vram[addr & 0x7f] = val;
    } else if (addr >= 0x06000100 && addr < 0x06000140) {
        const uint index = (addr & 0xff) >> 2;  // Index of the physical bank
        flash.bankMappings[index] = val & 0xf;
        remapFLASH();
        printf("Mapped physical FLASH bank %d to virtual bank %d\n", index, val & 0xf);
    } else if (addr >= 0x0C800000 && addr < 0x0C800010) {
        printf("Wrote %08X to %08X (IR jazz)\n", val, addr);
    } else {
        switch (addr) {
            case IO::INT_MASK_SET:
                irqMask |= val;
                if (comTrace && (val & 0x40)) printf("[PSK] PC=%08X WR INT_MASK_SET = %08X (COM-6 enabled)\n", curPC, val);
                break;

            case IO::INT_MASK_CLR:
                irqMask &= ~val;  // Clear interrupt masks based on value (1 = clear)
                if (comTrace && (val & 0x40)) printf("[PSK] PC=%08X WR INT_MASK_CLR = %08X (COM-6 disabled)\n", curPC, val);
                break;

            case IO::INT_ACK:  // Acknowledge interrupts (clear the latched REQUESTS only).
                // INT_INPUT holds raw signal LEVELS; ack must not disturb the bits that are
                // hardware-maintained physical/oscillating levels, only their latches:
                //   bits 0..4 = button levels (Fire/Right/Left/Down/Up -- pressed = high),
                //   bit 9     = RTC square wave (driven by tickRtc off the cycle clock), and
                //   bit 11    = Docked level (set while docked).
                // Clearing the bit-9 level here desyncs the square wave: tickRtc would then see
                // bit 9 == 0 at the next half-period and emit a fresh RISING edge (an extra IRQ +
                // calendar tick), so the RTC effectively runs at 2x. Clearing a button level on ack
                // would falsely "release" a still-held key (e.g. when the kernel acks the Fire IRQ
                // that woke it from sleep). Preserve all these levels; only the latch (irqLatch) is
                // acked, exactly matching the edge-triggered hardware.
                irqFlags &= (~val) | 0x1F | (1 << 9) | (1 << 11);
                irqLatch &= ~val;
                if (comTrace && (val & 0x40)) printf("[PSK] PC=%08X WR INT_ACK = %08X (ack COM-6)\n", curPC, val);
                break;

            case IO::LCD_MODE:
                lcd.mode.raw = val;
                break;

            case IO::LCD_CAL:
                lcd.calibrationValue = val & 0xFFFF;
                break;

            case IO::T0_RELOAD:
                timers[0].reload = val & 0xFFFF;
                printf("Wrote %08X to T0_RELOAD\n", val);
                break;

            case IO::T0_MODE:
                timers[0].mode = val;
                printf("Wrote %08X to T0_MODE\n", val);
                break;

            case IO::T1_RELOAD:
                timers[1].reload = val & 0xFFFF;
                printf("Wrote %08X to T1_RELOAD\n", val);
                break;

            case IO::T1_MODE:
                timers[1].mode = val;
                printf("Wrote %08X to T1_MODE\n", val);
                break;

            case IO::T2_RELOAD:
                timers[2].reload = val & 0xFFFF;
                printf("Wrote %08X to T2_RELOAD\n", val);
                break;

            case IO::T2_MODE:
                timers[2].mode = val;
                printf("Wrote %08X to T2_MODE\n", val);
                break;

            case IO::RTC_MODE:
                printf("Wrote %08X to RTC_MODE\n", val);
                rtcMode = val;
                break;

            case IO::COM_MODE:
                com.mode = val;
                if (comTrace) printf("[PSK] PC=%08X WR COM_MODE = %08X\n", curPC, val);
                break;

            case IO::COM_DATA:
                // Kernel loads its TX reply -> PS1 (MISO shift reg). One-byte SPI pipeline delay:
                // the host reads this on its NEXT exchange. Loading the next TX clears ready (the
                // kernel is now waiting for the host to clock this byte out, which re-sets ready)
                // and marks the reply fresh. This paces the kernel to one byte per host exchange.
                com.tx = val & 0xFF;
                com.txFresh = true;
                com.ready = false;
                if (comTrace) printf("[PSK] PC=%08X WR COM_DATA = %02X\n", curPC, val & 0xFF);
                break;

            case IO::COM_CTRL1:
                com.ctrl1 = val;
                if (comTrace) printf("[PSK] PC=%08X WR COM_CTRL1 = %08X\n", curPC, val);
                break;

            case IO::COM_CTRL2:
                com.ctrl2 = val;
                if (comTrace) printf("[PSK] PC=%08X WR COM_CTRL2 = %08X\n", curPC, val);
                break;

            case IO::IOP_CTRL:
                iopCtrl = val & 0xf;
                printf("Wrote %08X to IOP_CTRL\n", val);
                break;

            case IO::IOP_STOP:  // Why is this register even named like this...?
                iopData |= val;
                break;

            case IO::IOP_START:  // What is this name also
                iopData &= ~val;
                break;

            case IO::DAC_CTRL:
                dacCtrl = val;
                break;

            case IO::DAC_DATA:
                printf("Wrote %08X to DAC_DATA\n", val);
                break;

            case IO::BATT_CTRL:
                printf("Wrote %08X to BATT_CTRL\n", val);
                break;

            case IO::CLK_MODE:
                printf("Wrote %08X to CLK_MODE\n", val);
                clkMode = val & 0xF;
                break;

            case IO::CLK_STOP:
                // Sleep mode: bit0=1 stops the CPU clock until a wake IRQ (see Bus::halted). The
                // store completes normally; the very next CPU::step() observes halted and parks the
                // core (advancing only the RTC) until irqLatch & irqMask. Writing 0 is a no-op here
                // (the core never executes while halted, so software can't clear it from this side;
                // the wake path clears it). Keeps the system idle-cheap when undocked on battery.
                if (val & 1) halted = true;
                break;

            case IO::F_BANK_FLG:
                flash.enabledBanks = val & 0xffff;
                remapFLASH();
                printf("Wrote %08X to F_BANK_FLG\n", val);
                break;

            case IO::F_WAIT1:
                flash.f_wait1 = val;
                printf("Wrote %08X to F_WAIT1\n", val);
                break;

            case IO::FLASH_CTRL:
                // FLASHDataController write: latch the writable control bits. Disarming programming
                // (clearing ENPRG or LOADPAGE, e.g. step 6 of the write sequence) resets the JEDEC
                // unlock state machine so the next write must re-unlock.
                flash.dataCtrl = val & kFlashCtrlWritable;
                if (!((flash.dataCtrl & kFlashENPRG) && (flash.dataCtrl & kFlashLOADPAGE))) {
                    flash.progState = 0;
                }
                if (comTrace) printf("[PSK] PC=%08X WR FLASH_CTRL = %08X\n", curPC, val);
                break;

            case IO::F_CTRL:
                printf("Wrote %08X to F_CTRL\n", val);
                break;

            case IO::RTC_ADJUST: {
                printf("Wrote to stubbed RTC_ADJUST\n");
                static bool skip = false;
                if (skip) {
                    skip = false;
                    return;
                }

                const int field = (rtcMode >> 1) & 7;
                const auto incField = [](u32& f, u32 min, u32 max) {
                    f = Helpers::incBCDByte(f);
                    if (f > max) {
                        f = min;
                    }
                };

                switch (field) {
                    case 0:
                        incField(rtc.seconds, 0, 0x59);
                        break;

                    case 1:
                        incField(rtc.minutes, 0, 0x59);
                        break;

                    case 2:
                        incField(rtc.hours, 0, 0x23);
                        break;

                    case 3:
                        incField(rtc.dayOfWeek, 1, 0x7);
                        break;

                    case 4:
                        incField(rtc.days, 1, 0x31);
                        break;

                    case 5:
                        incField(rtc.months, 1, 0x12);
                        break;

                    case 6:
                        incField(rtc.years, 0, 0x99);
                        break;

                    default:
                        Helpers::panic("Editing field %d via RTC_ADJUST\n", field);
                }

                skip = true;
                break;
            }

            default:
                Helpers::panic("Unimplemented 32-bit write to %08X (val: %08X)\n", addr, val);
                break;
        }
    }
}

// bank: physical bank [0, 15]
// vbank: virtual bank [0, 15]
void Bus::remapFLASH() {
    u8 mappings[16] = { 0 }; // Index: virtual bank. Output: Corresponding physical bank
    for (int bank = 0; bank < 16; bank++) {
        const auto vbank = flash.bankMappings[bank];
        mappings[vbank] = bank;
    }

    for (int vbank = 0; vbank < 16; vbank++) {
        auto bank = mappings[vbank];
        const u32 vaddr = 0x0200'0000 + vbank * sectorSize;
        auto page = vaddr >> 11;

        if (flash.enabledBanks & (1 << bank))  { // Check if physical bank is mapped
            readTable[page++] = (uintptr_t)&flash.data[bank * sectorSize];
            readTable[page++] = (uintptr_t)&flash.data[bank * sectorSize + 0x800];
            readTable[page++] = (uintptr_t)&flash.data[bank * sectorSize + 0x1000];
            readTable[page] = (uintptr_t)&flash.data[bank * sectorSize + 0x1800];
        } else { // Disabled bank, map it all to slowmem
            readTable[page++] = 0;
            readTable[page++] = 0;
            readTable[page++] = 0;
            readTable[page] = 0;
        }
    }
}