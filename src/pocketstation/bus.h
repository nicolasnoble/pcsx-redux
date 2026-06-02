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
    u32 irqLatch;

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
    u32 irqFlags; // Requested interrupts
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

    u8 read8Slow(u32 addr);
    u16 read16Slow(u32 addr);
    u32 read32Slow(u32 addr);

    void write8Slow (u32 addr, u8 val);
    void write16Slow (u32 addr, u16 val);
    void write32Slow (u32 addr, u32 val);
};