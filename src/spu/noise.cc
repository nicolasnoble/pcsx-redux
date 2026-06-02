/***************************************************************************
                          noise.c  -  description
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

#include "spu/noise.h"

////////////////////////////////////////////////////////////////////////

// noise handler... just produces some noise data
// surely wrong... and no noise frequency (spuCtrl&0x3f00) will be used...
// and sometimes the noise will be used as fmod modulation... pfff

int PCSX::SPU::NoiseGenerator::getVal(Protobuf::Int32 *sb, int interpolationType) const {
    const int fa = (int16_t)m_val;

    if (interpolationType < 2)  // no gauss/cubic interpolation?
        sb[29].value = fa;      // -> store noise val in "current sample" slot
    return fa;
}

////////////////////////////////////////////////////////////////////////

void PCSX::SPU::NoiseGenerator::step() {
    // Noise Waveform - Dr. Hell (Xebra)
    static constexpr char NoiseWaveAdd[64] = {1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1,
                                              1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0,
                                              1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1};

    static constexpr unsigned short NoiseFreqAdd[5] = {0, 84, 140, 180, 210};

    unsigned int level;

    level = 0x8000 >> (m_clock >> 2);
    level <<= 16;

    m_count += 0x10000;

    // Dr. Hell - fraction
    m_count += NoiseFreqAdd[m_clock & 3];
    if ((m_count & 0xffff) >= NoiseFreqAdd[4]) {
        m_count += 0x10000;
        m_count -= NoiseFreqAdd[m_clock & 3];
    }

    if (m_count >= level) {
        while (m_count >= level) {
            m_count -= level;
        }

        // Dr. Hell - form
        m_val = (m_val << 1) | NoiseWaveAdd[(m_val >> 10) & 63];
    }
}
