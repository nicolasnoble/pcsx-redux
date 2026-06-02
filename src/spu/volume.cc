/***************************************************************************
                          volume.c  -  description
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

#include "spu/volume.h"

namespace {
constexpr int16_t kVolumeMax = 0x3fff;     // effective level is 14 bits
constexpr int16_t kFixedSignBit = 0x4000;  // bit 14: fixed-mode negative phase
}  // namespace

// All arithmetic stays in int16_t on purpose: the sweep approximation below
// relies on the 16-bit wraparound the original peops code produced.
int PCSX::SPU::VoiceVolume::decode(int16_t vol) {
    if (vol & VolumeFlags::VolumeMode) {  // sweep mode
        // Redux does not run the hardware volume sweep envelope. A sweep-mode
        // write is folded into a single raised or lowered fixed level - an
        // approximation faithful to the original model and rarely hit by games.
        const int16_t direction = (vol & VolumeFlags::SweepDirection) ? -1 : 1;
        if (vol & VolumeFlags::SweepPhase) vol ^= 0xffff;  // approximated negative phase
        vol = ((vol & 0x7f) + 1) / 2;                      // sweep step 0..127 -> 0..64
        vol += vol / (2 * direction);                      // shift the level by half
        vol *= 128;
    } else if (vol & kFixedSignBit) {  // fixed mode, negative phase
        vol = (vol & kVolumeMax) - kFixedSignBit;
    }

    return vol & kVolumeMax;
}
