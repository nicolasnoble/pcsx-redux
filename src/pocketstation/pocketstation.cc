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
    m_buttons = 0;  // bus.reset() clears irqFlags, so the reflected button levels start clear too.
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
    // NOTE: button -> INT_INPUT reflection is NOT done here anymore. It lives in setButtons()
    // (edge-driven) so it works while the core is halted (CLK_STOP sleep) -- frameScaffolding is
    // skipped during sleep, so reflecting here could never wake a sleeping device on a Fire press.
}
// -----------------------------------------------------------------------------------------

void PocketStation::setButtons(uint32_t mask) {
    // Reflect the 5 buttons (bits 0..4 = Fire/Right/Left/Down/Up) into INT_INPUT as raw signal
    // LEVELS, edge-detected against the previously latched mask. A press (0->1) raises the level
    // AND latches the IRQ via requestInterrupt() (the latch only takes if the kernel has that bit
    // unmasked); a release (1->0) drops the level only. INT_ACK preserves these level bits (like
    // the dock/RTC levels), so the kernel acking a Fire IRQ does not falsely "release" a held key.
    //
    // Doing this HERE -- not in frameScaffolding(), which is skipped while halted -- is what lets a
    // Fire press wake a sleeping (CLK_STOP) device: the press latches IRQ-0, satisfying CPU::step()'s
    // wake condition (irqLatch & irqMask). psx-spx: buttons are polled directly from INT_INPUT,
    // except in Sleep mode where the Fire-button IRQ wakes the device. Edge-detecting against
    // m_buttons keeps a per-frame setButtons(sameMask) a no-op, so a held key can't re-latch / storm.
    const uint32_t changed = (mask ^ m_buttons) & 0x1F;
    for (int key = 0; key < 5; key++) {
        const uint32_t bit = 1u << key;
        if (!(changed & bit)) continue;
        if (mask & bit) {
            m_bus.requestInterrupt(key);  // press edge: raise level + latch (if unmasked).
        } else {
            m_bus.irqFlags &= ~bit;       // release edge: drop the level only.
        }
    }
    m_buttons = mask;
}

const uint8_t* PocketStation::vram() const { return m_lcd.vram.data(); }

uint32_t PocketStation::lcdMode() const { return m_lcd.mode.raw; }

bool PocketStation::lcdEnabled() const { return m_lcd.mode.enabled; }

}  // namespace PocketStation
}  // namespace PCSX
