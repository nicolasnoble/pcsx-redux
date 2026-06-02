/***************************************************************************
                       interpolation.h  -  description
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

// Self-contained per-voice resampler. Takes the freshly decoded ADPCM samples
// plus the fractional pitch position and produces one output sample at the
// emulator's 44.1kHz mixing rate, in one of four modes (none / "Pete's common
// sense" linear / hardware-accurate gaussian / cubic). Extracted out of the
// MainThread synthesis loop and the SPU impl; the math is unchanged.
//
// The interpolation working set lives in the tail of the per-voice sample
// buffer (SB[28]..SB[32]): the gaussian window is four int16 samples packed
// into SB[29]/SB[30] addressed by the ring index in SB[28], and the linear
// modes use SB[28]..SB[32] as delay slots and a recompute flag. That layout is
// shared with the savestate (the whole SB buffer serializes as one field), so
// the state stays in SB rather than moving into this class; the class owns the
// algorithms, not the storage. The methods take a raw `Protobuf::Int32 *sb`
// (the SB buffer) instead of the SPUCHAN type to avoid a types.h<->this-header
// include cycle, exactly as the ADPCM decoder does.
class Interpolator {
  public:
    // Key-on: clear the interpolation window and seed the fractional pitch
    // position `spos` (which lives in the channel) for the active mode, exactly
    // as StartSound used to do inline. Gauss/cubic start further ahead so the
    // four-tap window is primed before the first output sample.
    void keyOn(Protobuf::Int32 *sb, int32_t *spos, int interpolationType) {
        sb[29].value = 0;  // init our interpolation helpers
        sb[30].value = 0;

        if (interpolationType >= 2)  // gauss/cubic interpolation?
        {
            *spos = 0x30000L;
            sb[28].value = 0;
        }  // -> start with more decoding
        else {
            *spos = 0x10000L;
            sb[31].value = 0;
        }  // -> no/simple interpolation starts with one 44100 decoding
    }

    // A psx-pitch change happened: in simple-interpolation mode, flag that the
    // step must be recomputed on the next pass.
    void onFrequencyChanged(Protobuf::Int32 *sb, int interpolationType) {
        if (interpolationType == 1) sb[32].value = 1;
    }

    // Store one freshly decoded sample `fa` into the interpolation window so a
    // later getVal() can weight it. `fmod` is the channel's freq-mod mode (2 =
    // frequency-modulator source channel), `unmuted` is the SPU-wide unmute
    // control bit.
    void storeVal(Protobuf::Int32 *sb, int fa, int interpolationType, int fmod, bool unmuted);

    // Produce one resampled output sample for the current fractional pitch
    // position `spos` (gauss/cubic) / pitch increment `sinc` (linear).
    int getVal(Protobuf::Int32 *sb, int32_t spos, int32_t sinc, int interpolationType, int fmod);

  private:
    static void interpolateUp(Protobuf::Int32 *sb, int32_t sinc);
    static void interpolateDown(Protobuf::Int32 *sb, int32_t sinc);
};

}  // namespace SPU

}  // namespace PCSX
