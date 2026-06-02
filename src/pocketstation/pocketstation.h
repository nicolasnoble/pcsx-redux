/***************************************************************************
 *   Copyright (C) 2022 PCSX-Redux authors                                 *
 *                                                                         *
 *   This program is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 *   This program is distributed in the hope that it will be useful,       *
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of        *
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *
 *   GNU General Public License for more details.                          *
 *                                                                         *
 *   You should have received a copy of the GNU General Public License     *
 *   along with this program; if not, write to the                         *
 *   Free Software Foundation, Inc.,                                       *
 *   51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.           *
 ***************************************************************************/

#pragma once

#include <cstddef>
#include <cstdint>

#include "bus.h"
#include "cpu.h"
#include "lcd.h"

namespace PCSX {
namespace PocketStation {

// Headless PocketStation device. Owns the ARM7 core, the bus (kernel + flash + MMIO),
// and the LCD. No I/O happens in construction; the kernel and flash images are injected
// before reset(). This replaces the donor's Qt-bound Pocketstation class.
//
// The catch-up entry point is runCycles(): the host (a Redux scheduler event) advances
// the ARM7 by a cycle delta, and the device steps the core that far. The LCD framebuffer
// is read out via vram()/lcdMode()/lcdEnabled().
class PocketStation {
  public:
    PocketStation();  // builds the ARM/Thumb LUTs; no I/O.

    void setKernel(const uint8_t* data, size_t len);  // 16 KiB; call before reset().
    void setFlash(const uint8_t* data, size_t len);   // 128 KiB card image; call before reset().

    void reset();  // power-on; donor reset order (cpu, bus, lcd).

    void runCycles(uint64_t armCycles);  // step the ARM core forward N cycles.

    const uint8_t* vram() const;  // 128 bytes, 32x32 @ 1bpp.
    uint32_t lcdMode() const;
    bool lcdEnabled() const;

    void setButtons(uint32_t mask);  // bits 0..4 -> INT_INPUT.0..4 (live levels).

  private:
    // Init order matters: LCD first, then Bus(lcd), then CPU(bus). Members are constructed
    // in declaration order, so this declaration order IS the construction contract.
    ::LCD m_lcd;
    ::Bus m_bus;
    ::CPU m_cpu;

    uint32_t m_buttons = 0;  // latched button mask, reflected into INT bits 0..4 per frame.

    // ---- TEMPORARY SCAFFOLDING ----------------------------------------------------------
    // The donor's Qt render() loop spoon-fed the kernel fake timer IRQs every frame so it
    // would boot without real timers (which never tick yet). With the Qt loop gone, we
    // reproduce that injection here on a cycle cadence. REMOVE ALL OF THIS once real
    // Timer0/Timer1/Timer2 + the RTC square wave land; the kernel must then boot on real
    // hardware events, not on a stopwatch.
    static constexpr uint32_t kArmClock = 3997696;          // donor's default clock (Hz).
    static constexpr uint32_t kCyclesPerFrame = kArmClock / 60;  // ~66628 cycles ~= one 60Hz frame.
    uint64_t m_frameAccum = 0;  // cycles accumulated toward the next scaffolding "frame".
    int m_poop = 1;             // donor's INT7 alternation counter (named to match the donor).
    void frameScaffolding();    // fires the fake timer IRQs + reflects buttons; called per frame.
    // -------------------------------------------------------------------------------------
};

}  // namespace PocketStation
}  // namespace PCSX
