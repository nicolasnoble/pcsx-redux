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

#include "pocketstation.h"

namespace PCSX {
namespace PocketStation {

// Member init order: m_lcd, then m_bus(m_lcd), then m_cpu(m_bus). Declaration order in the
// header enforces this; the init list just supplies the references. The CPU ctor builds the
// ARM/Thumb LUTs and resizes the page tables -- no file I/O.
PocketStation::PocketStation() : m_bus(m_lcd), m_cpu(m_bus) {}

void PocketStation::setKernel(const uint8_t* data, size_t len) { m_bus.setKernel(data, len); }

void PocketStation::setFlash(const uint8_t* data, size_t len) { m_bus.setFlash(data, len); }

void PocketStation::reset() {
    // Donor reset order: cpu first (lays down the bios/flash page tables), then bus
    // (remaps flash banks, applies the 0x65E boot patch), then lcd.
    m_cpu.reset();
    m_bus.reset();
    m_lcd.reset();
    m_frameAccum = 0;
    m_poop = 1;
}

void PocketStation::runCycles(uint64_t armCycles) {
    for (uint64_t i = 0; i < armCycles; i++) {
        m_cpu.step();
        // Scaffolding cadence: every ~66628 steps == one 60Hz frame, inject the fake IRQs.
        // Skip it while the core is halted: CLK_STOP stops Timer0-2 (psx-spx), so the fake timer
        // IRQs must NOT fire during sleep -- only the RTC (ticked in CPU::step) wakes the device.
        if (++m_frameAccum >= kCyclesPerFrame) {
            m_frameAccum = 0;
            if (!m_bus.halted) frameScaffolding();
        }
    }
}

// ---- TEMPORARY SCAFFOLDING --------------------------------------------------------------
// Faithful reproduction of the donor render() IRQ injection. The kernel boots only because
// it is fed these on a stopwatch; remove once real timers + RTC square wave exist.
void PocketStation::frameScaffolding() {
    if (++m_poop & 1) m_bus.requestInterrupt(7);  // fake Timer0 ~30Hz.
    m_bus.requestInterrupt(13);                   // fake Timer2 FIQ ~60Hz.

    // Reflect the latched button mask into INT bits 0..4 as live levels: held -> request,
    // released -> clear. read32Slow(INT_INPUT) returns irqFlags, so this drives INT_INPUT.
    for (int key = 0; key < 5; key++) {
        if (m_buttons & (1u << key)) {
            m_bus.requestInterrupt(key);
        } else {
            m_bus.irqFlags &= ~(1u << key);
        }
    }
}
// -----------------------------------------------------------------------------------------

void PocketStation::setButtons(uint32_t mask) { m_buttons = mask; }

const uint8_t* PocketStation::vram() const { return m_lcd.vram.data(); }

uint32_t PocketStation::lcdMode() const { return m_lcd.mode.raw; }

bool PocketStation::lcdEnabled() const { return m_lcd.mode.enabled; }

}  // namespace PocketStation
}  // namespace PCSX
