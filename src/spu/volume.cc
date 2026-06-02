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

////////////////////////////////////////////////////////////////////////

// please note: sweep and phase invert are wrong... but I've never seen
// them used

int PCSX::SPU::VoiceVolume::decode(int16_t vol) {
    if (vol & VolumeFlags::VolumeMode)  // sweep?
    {
        int16_t sInc;
        if (vol & VolumeFlags::SweepDirection) {
            sInc = -1;  // Decrease
        } else {
            sInc = 1;  // Increase
        }
        if (vol & VolumeFlags::SweepPhase) {
            // Negative Phase
            vol ^= 0xffff;  // -> mmm... phase inverted? have to investigate this
        }
        vol = ((vol & 0x7f) + 1) / 2;  // -> sweep: 0..127 -> 0..64
        vol += vol / (2 * sInc);  // -> HACK: we don't sweep right now, so we just raise/lower the volume by the half!
        vol *= 128;
    } else  // no sweep:
    {
        if (vol & 0x4000)  // -> mmm... phase inverted? have to investigate this
        {
            vol = (vol & 0x3fff) - 0x4000;
        }
    }

    vol &= 0x3fff;
    return vol;
}
