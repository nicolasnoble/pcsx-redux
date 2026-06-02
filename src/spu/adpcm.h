/***************************************************************************
                          adpcm.h  -  description
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

// Self-contained per-voice ADPCM decoder. Owns the decode cursor into sound RAM
// (start/current/loop pointers) and the two-sample IIR decode history, and
// turns a 16-byte ADPCM block into 28 PCM samples. Extracted out of the SPUCHAN
// per-voice struct and the MainThread synthesis loop; the math and the cursor
// bookkeeping are unchanged. The loop/stop flag resolution and the SPU IRQ check
// stay in MainThread, which owns the SPU-wide state they need; this class just
// exposes the cursor so that code can keep driving it.
class AdpcmDecoder {
  public:
    // Key-on: rewind the decode cursor to the sample start and clear the IIR
    // history, exactly as StartSound used to do inline.
    void keyOn() {
        m_curr = m_start;
        m_s1 = 0;
        m_s2 = 0;
    }

    // Clear all decode state (voice wipe).
    void reset() {
        m_start = nullptr;
        m_curr = nullptr;
        m_loop = nullptr;
        m_s1 = 0;
        m_s2 = 0;
    }

    // Decode cursor accessors (raw pointers into sound RAM).
    uint8_t *start() const { return m_start; }
    uint8_t *curr() const { return m_curr; }
    uint8_t *loop() const { return m_loop; }
    void setStart(uint8_t *p) { m_start = p; }
    void setCurr(uint8_t *p) { m_curr = p; }
    void setLoop(uint8_t *p) { m_loop = p; }

    // IIR decode-history accessors (used only by savestate serialization; the
    // history is otherwise private to decodeBlock()).
    int32_t history1() const { return m_s1; }
    int32_t history2() const { return m_s2; }
    void setHistory(int32_t s1, int32_t s2) {
        m_s1 = s1;
        m_s2 = s2;
    }

    // Decode one 16-byte ADPCM block beginning at `block` into the first 28
    // entries of `sb` (the per-voice sample buffer). Advances the IIR history,
    // sets `blockEnd` to one past the block (16 bytes on), and returns the
    // block's flag byte (loop/repeat/end bits) for the caller's IRQ check and
    // loop handling.
    int decodeBlock(uint8_t *block, Protobuf::Int32 *sb, uint8_t *&blockEnd);

  private:
    // ADPCM IIR filter coefficient pairs, indexed by the block's predictor.
    static constexpr int f[5][2] = {{0, 0}, {60, 0}, {115, -52}, {98, -55}, {122, -60}};

    uint8_t *m_start = nullptr;  // start ptr into sound mem
    uint8_t *m_curr = nullptr;   // current pos in sound mem
    uint8_t *m_loop = nullptr;   // loop ptr in sound mem
    int32_t m_s1 = 0;            // last decoded sample  (IIR history)
    int32_t m_s2 = 0;            // next-to-last decoded sample (IIR history)
};

}  // namespace SPU

}  // namespace PCSX
