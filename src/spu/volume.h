/***************************************************************************
                          volume.h  -  description
                             -------------------
    begin                : Wed May 15 2002
    copyright            : (C) 2002 by Pete Bernert
    email                : BlackDove@addcom.de
 ***************************************************************************/

/***************************************************************************
 *                                                                         *
 *   This program is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version. See also the license.txt file for *
 *   additional informations.                                              *
 *                                                                         *
 ***************************************************************************/

#pragma once

#include <stdint.h>

namespace PCSX {

namespace SPU {

// Per-voice left/right output volume. Owns both the raw 16-bit value last
// written to a voice's volume register and the effective 0..0x3fff level the
// mixer and reverb stages multiply by, plus the register decode that maps one
// to the other (fixed mode, phase invert, and the approximated sweep mode).
// Extracted out of the SPU impl's SetVolumeL/SetVolumeR register handlers and
// the SPUCHAN per-voice struct; the arithmetic is unchanged.
//
// Note: the PS1's global main L/R volume is not emulated (those register writes
// are logged only, no state is kept), so unlike the noise generator there is no
// global counterpart to fold in here - this type is purely per-voice, like the
// ADSR envelope and the ADPCM decoder.
class VoiceVolume {
  public:
    // Decode a left/right volume register write (was impl::SetVolumeL and
    // impl::SetVolumeR, which were byte-for-byte identical): store the raw
    // value, then recompute the effective level.
    void setLeft(int16_t raw) {
        m_leftRaw = raw;
        m_left = decode(raw);
    }
    void setRight(int16_t raw) {
        m_rightRaw = raw;
        m_right = decode(raw);
    }

    // Effective 0..0x3fff volume the mixer and reverb stages apply.
    int left() const { return m_left; }
    int right() const { return m_right; }

    void reset() {
        m_left = m_right = 0;
        m_leftRaw = m_rightRaw = 0;
    }

    // Savestate bridge (freeze.cc only): the four values mirror into the
    // per-channel savestate message as scalar fields, unchanged by this
    // extraction.
    int leftRaw() const { return m_leftRaw; }
    int rightRaw() const { return m_rightRaw; }
    void setLeftComputed(int vol) { m_left = vol; }
    void setRightComputed(int vol) { m_right = vol; }
    void setLeftRaw(int raw) { m_leftRaw = raw; }
    void setRightRaw(int raw) { m_rightRaw = raw; }

  private:
    struct VolumeFlags {
        enum : uint16_t {
            VolumeMode = 1 << 15,      // 15 1=Sweep Mode
            SweepMode = 1 << 14,       // 14 0=Linear, 1=Exponential
            SweepDirection = 1 << 13,  // 13 0=Increase, 1=Decrease
            SweepPhase = 1 << 12,      // 12 0=Positive, 1=Negative
            Unknown = 0xf80,           // 7-11 Not used? (should be zero)
            SweepShiftMask = 0x7c,     // 6-2 0..1Fh = Fast..Slow
            SweepStepMask = 0x3        // 1-0 0..3 = "+7,+6,+5,+4" or "-8,-7,-6,-5") (inc/dec)
        };
    };

    // The shared register decode used by both channels. sweep and phase invert
    // are approximated (see the in-body notes), but the behavior is unchanged
    // from the original SetVolumeL/SetVolumeR handlers.
    static int decode(int16_t vol);

    int m_left = 0;      // effective left level (0..0x3fff)
    int m_right = 0;     // effective right level (0..0x3fff)
    int m_leftRaw = 0;   // raw left volume register value
    int m_rightRaw = 0;  // raw right volume register value
};

}  // namespace SPU

}  // namespace PCSX
