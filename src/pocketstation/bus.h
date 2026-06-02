#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <vector>
#include "types.h"
#include "lcd.h"
#include "timer.h"

class Bus {
    static constexpr u32 KB = 1024;
    static constexpr u32 MB = 1024 * KB;
    static constexpr u32 sectorSize = 0x2000;

    LCD& lcd;
    std::array<Timer, 3> timers;
    u32 iopData;
    u32 iopCtrl;
    u32 dacCtrl;
    u32 clkMode;

    u32 rtcMode;
    struct RTC {
        u32 seconds, minutes, hours, dayOfWeek, days, months, years;

        u32 getDate() {
            return days | (months << 8) | (years << 16);
        }

        u32 getTime() {
            return seconds | (minutes << 8) | (hours << 16) | (dayOfWeek << 24);
        }

        void reset() {
            seconds = 0;
            minutes = 0;
            hours = 0;
            dayOfWeek = 1;
            days = 1;
            months = 1;
            years = 0x99;
        }
    } rtc;

    void remapFLASH();

public:
    u32 irqMask;  // Enabled interrupts
    u32 irqFlags; // Requested interrupts (raw INT_INPUT signal levels)
    u32 irqLatch; // Latched edge-triggered requests (drives CPU dispatch; cleared by INT_ACK)
    std::atomic<u32> pressedButtons = 0; // The GUI thread writes here

    // The CPU core uses software fastmem
    // Splitting the address space into 2KiB (2^11) pages, so 0x200000 pages
    // Here are our page tables
    std::vector<uintptr_t> readTable;
    std::vector<uintptr_t> writeTable;

    struct {
        u32 enabledBanks;
        // For each of the 16 physical flash banks, we can choose which virtual bank to map it to
        std::array<u32, 16> bankMappings;
        std::vector<u8> data;

        // Undocumented FLASH control registers
        u32 f_wait1;
        u32 f_wait2;
    } flash;

    std::array<u8, 2 * KB> wram;
    std::vector<u8> bios;

    // ---- COM link (card slot SPI bridge to the PSX) ------------------------------------------
    // The PS1<->card link is bidirectional SPI, master = PS1. COM_DATA is a single shift register
    // each direction (NOT a queue): rx = the last byte clocked in from the PS1 (kernel reads it via
    // COM_DATA), tx = the byte the kernel has loaded for the PS1 (host reads it on the next
    // exchange = the inherent one-transaction SPI pipeline delay). A FIFO is WRONG here: the kernel
    // does not read every incoming byte (it ignores the dummy bytes during the data phase), so a
    // queue would accumulate unread bytes and mis-align the kernel's later address reads. On real
    // hardware an unread RX byte is simply overwritten by the next exchange. See learnings sio.md
    // "COM bridge IMPL". The kernel handles a whole bu_cmd in one FIQ-6 entry, busy-polling
    // COM_STAT2.ready (set when the host completes a transfer, cleared when the kernel loads the
    // next TX) to pace itself to one byte per host exchange.
    struct Com {
        u8 rx = 0xFF;          // MOSI shift reg: last byte from PS1 (kernel reads via COM_DATA).
        u8 tx = 0xFF;          // MISO shift reg: byte kernel loaded (host reads on next exchange).
        u32 mode = 0;          // COM_MODE
        u32 ctrl1 = 0;         // COM_CTRL1
        u32 ctrl2 = 0;         // COM_CTRL2
        bool ready = false;    // COM_STAT2.bit0: a byte transfer completed (kernel TX-pacing flag).
        bool txFresh = false;  // kernel loaded a new TX since the last exchange (else host underrun).
        bool error = false;    // COM_STAT1.bit1.
        bool cmdActive = false;  // a bu_cmd FIQ is in progress (don't re-fire FIQ-6 per byte).
        u32 hostUnderruns = 0;   // exchanges where the kernel had no fresh reply (pipeline metric).
        void reset() {
            rx = tx = 0xFF;
            mode = ctrl1 = ctrl2 = 0;
            ready = txFresh = error = cmdActive = false;
            hostUnderruns = 0;
        }
    } com;

    bool comTrace = false;  // when set, cpu.cc/bus.cc log every COM/INT reg access with PC.
    u32 curPC = 0;          // last instruction fetch PC; CPU stashes it when comTrace is on.

    // Host (PS1) side of one SPI byte exchange. Returns the byte the PocketStation had loaded
    // BEFORE this exchange (one-transaction pipeline delay), pushes the incoming byte for the
    // kernel, and arms the COM FIQ if no command is already running. Non-blocking: does NOT run
    // the ARM7 (the catch-up owns arm7.step()).
    u8 comExchange(u8 in) {
        // One SPI byte exchange. The host receives the byte the kernel had loaded (tx); if the
        // kernel hasn't loaded a fresh reply since the last exchange, that's an underrun (a couple
        // at the pipeline start is expected; sustained underruns mean the catch-up isn't giving
        // the ARM7 enough cycles per byte). The incoming byte overwrites the rx shift register, and
        // the completed transfer sets ready (the kernel's pacing signal).
        if (!com.txFresh) com.hostUnderruns++;
        const u8 out = com.tx;
        com.txFresh = false;
        com.rx = in;
        com.ready = true;
        if (!com.cmdActive) {
            com.cmdActive = true;
            requestInterrupt(6);  // FIQ-6 (COM): start of a new command.
        }
        return out;
    }

    // Called by the host when the card is (de)selected. Deselect ends any in-progress command so
    // the next byte re-arms FIQ-6, and lets the kernel see /SEL go inactive.
    void comDeselect() {
        com.cmdActive = false;
        com.ready = false;
        com.txFresh = false;
        com.rx = com.tx = 0xFF;
    }

    // Docking: INT_INPUT.11 reflects dock status (level), and a transition fires IRQ-11 so the
    // kernel's IOP handler runs (which, via the GUI's per-frame SWI 05h, enables COM).
    void setDocked(bool docked) {
        const bool was = (irqFlags & (1u << 11)) != 0;
        if (docked == was) return;
        if (docked) {
            // requestInterrupt sets the INT_INPUT.11 level AND latches the edge (so the IOP IRQ
            // fires once). The level then stays set while docked (INT_ACK preserves bit 11), so
            // the handler can read docked=1; the latch is acked normally -> no storm.
            requestInterrupt(11);
        } else {
            irqFlags &= ~(1u << 11);          // level goes low on undock.
            irqLatch |= (1u << 11) & irqMask;  // latch the 1->0 edge directly (don't re-set level).
        }
    }

    // ---- RTC square wave (INT_INPUT.9) -------------------------------------------------------
    // INT_INPUT bit 9 is the RTC square-wave LEVEL. psx-spx: ~1 Hz normally, 4096 Hz when the RTC
    // is paused via RTC_MODE.0 (0=Run/1Hz, 1=Pause/4096Hz); INT_INPUT reports the raw signal
    // levels. The retail kernel's early boot busy loop at bios 0x650..0x65e phase-aligns to this
    // edge: phase1 spins until bit 9 rises (bcc), phase2 (0x65e) spins until it falls (bcs). So the
    // bit MUST oscillate 1->0->1 as a live level, not latch. We drive it off the ARM7 cycle clock
    // (1 CPU step == 1 cycle in this fake-pipeline core) with a half-period countdown: each
    // half-period we toggle the level, firing the RTC IRQ latch on the RISING edge (so the running
    // kernel's RTC-IRQ path still works) and just dropping the level on the FALLING edge. The donor
    // instead latched bit 9 sticky (requestInterrupt(9) every 200 INT_INPUT reads); it never fell,
    // so phase2 hung forever, which is precisely why the donor NOP'd bios[0x65e]. This live square
    // wave is the faithful fix and lets the patch be deleted entirely.
    //
    // The rate MUST track RTC_MODE.0: the kernel pauses the RTC (4096 Hz) for the boot phase-align,
    // then runs it (1 Hz) for normal timekeeping. A fixed 4096 Hz floods the running kernel with an
    // RTC IRQ every ~976 cycles, which starves the GUI / COM handler (regression: the 52h read
    // underran). Half-periods at the 3.997696 MHz boot clock: 488 cycles == 4096 Hz (paused),
    // 1998848 cycles == ~1 Hz (running). TODO: calibrate the exact rate against real silicon and
    // rescale when CLK_MODE changes the system clock (cycle-accurate RTC freq waits for HW ground
    // truth per the bootstrap order).
    static constexpr u32 kRtcHalfPeriodPaused = 488;       // 4096 Hz @ 3.997696 MHz (RTC paused).
    static constexpr u32 kRtcHalfPeriodRunning = 1998848;  // ~1 Hz (3997696 / 2).
    u32 rtcCountdown = kRtcHalfPeriodPaused;

    u32 rtcHalfPeriod() const { return (rtcMode & 1) ? kRtcHalfPeriodPaused : kRtcHalfPeriodRunning; }

    // Advance the RTC square wave by one ARM7 cycle. Called once per CPU::step().
    void tickRtc() {
        if (--rtcCountdown == 0) {
            rtcCountdown = rtcHalfPeriod();
            if (irqFlags & (1u << 9)) {
                irqFlags &= ~(1u << 9);  // falling edge: drop the level only (leave the latch).
            } else {
                requestInterrupt(9);     // rising edge: raise the level AND latch the RTC IRQ.
                // In RUN mode (RTC_MODE.0=0) the square wave is 1 Hz, so this rising edge is the
                // once-per-second calendar tick: advance the BCD clock. In PAUSE mode (4096 Hz) the
                // edge is just the fast wave the boot loop phase-aligns to and must NOT advance time
                // (otherwise the kernel's brisk field-set loop would clock real seconds under it).
                if ((rtcMode & 1) == 0) rtcAdvanceOneSecond();
            }
        }
    }

    // No I/O in the constructor: just allocate the kernel/flash backing buffers so the
    // pointers the CPU page tables hold are stable. The actual contents are injected
    // later via setKernel()/setFlash(), before reset(). This is what makes the module
    // usable in-tree (the donor loaded kernel.bin/memcard2.mcd from cwd here).
    Bus(LCD& lcd) : lcd(lcd) {
        bios.resize(16 * KB, 0);
        flash.data.resize(128 * KB, 0);
    }

    // Inject the 16 KiB PocketStation kernel. Must be called before reset().
    void setKernel(const u8* data, usize len) {
        if (len != 16 * KB) {
            Helpers::panic("setKernel: expected 16 KiB, got %zu bytes", len);
        }
        std::copy(data, data + len, bios.begin());
    }

    // Inject the 128 KiB flash image (the memory-card image). Must be called before reset().
    void setFlash(const u8* data, usize len) {
        if (len != 128 * KB) {
            Helpers::panic("setFlash: expected 128 KiB, got %zu bytes", len);
        }
        std::copy(data, data + len, flash.data.begin());
    }

    std::array<u8, 128>& getVRAM() {
        return lcd.vram;
    }

    void reset();
    void requestInterrupt(int bit);

    // RTC time-of-day de-fake. seedRtcFromHostClock() initialises the BCD calendar from the host
    // wall clock at reset (so the displayed time is real); rtcAdvanceOneSecond() propagates a
    // one-second carry through seconds/minutes/hours/day-of-week/day/month/year and is called from
    // tickRtc() on each 1 Hz RTC rising edge. (Cycle-exact realtime vs host drift is expected; exact
    // rate + calendar/century fidelity wait for HW ground truth per the bootstrap order.)
    void seedRtcFromHostClock();
    void rtcAdvanceOneSecond();

    u8 read8Slow(u32 addr);
    u16 read16Slow(u32 addr);
    u32 read32Slow(u32 addr);

    void write8Slow (u32 addr, u8 val);
    void write16Slow (u32 addr, u16 val);
    void write32Slow (u32 addr, u32 val);
};