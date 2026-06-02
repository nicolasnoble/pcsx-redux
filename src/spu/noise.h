/***************************************************************************
                          noise.h  -  description
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

#include "support/protobuf.h"

namespace PCSX {

namespace SPU {

// The SPU's single global noise generator. One LFSR, shared by every voice
// whose noise-mode bit is set: such a voice outputs the current noise level in
// place of its decoded/interpolated ADPCM sample. The shift+step bits of
// SPUCTRL select the clock that paces the LFSR. Extracted out of the MainThread
// synthesis loop and the SPU impl; the (Dr. Hell / Xebra) arithmetic is
// unchanged.
//
// Unlike the per-voice ADPCM/ADSR/interpolation helpers this is a single
// per-SPU instance, so it lives in the impl rather than in SPUCHAN. getVal()
// takes a raw `Protobuf::Int32 *sb` (the consuming voice's sample buffer)
// instead of the SPUCHAN type to avoid a types.h<->this-header include cycle,
// exactly as the ADPCM decoder and interpolator do.
class NoiseGenerator {
  public:
    // The SPUCTRL noise shift+step selector (register bits 13..8, already
    // shifted down). Recomputed on every SPUCTRL write.
    void setClock(uint32_t clock) { m_clock = clock; }

    // Advance the LFSR by one mixing sample (was impl::NoiseClock()). Called
    // once per output sample, before any voice consumes the level.
    void step();

    // The current noise output sample, sign-extended to 16 bits (was
    // impl::iGetNoiseVal()). In the no/simple interpolation modes the value is
    // also parked in the voice's "current sample" slot SB[29], exactly as
    // before, so the linear resampler sees it.
    int getVal(Protobuf::Int32 *sb, int interpolationType) const;

    // Savestate bridge (freeze.cc only): the LFSR state mirrors into the SPU
    // savestate message as three scalar fields, unchanged by this extraction.
    uint32_t clock() const { return m_clock; }
    uint32_t count() const { return m_count; }
    uint32_t value() const { return m_val; }
    void setCount(uint32_t count) { m_count = count; }
    void setValue(uint32_t val) { m_val = val; }

  private:
    uint32_t m_clock = 0;  // shift+step selector from SPUCTRL
    uint32_t m_count = 0;  // fractional accumulator pacing the LFSR
    uint32_t m_val = 1;    // LFSR state; the noise level lives in the low 16 bits
};

}  // namespace SPU

}  // namespace PCSX
