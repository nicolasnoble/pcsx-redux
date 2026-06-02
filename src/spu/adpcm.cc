/***************************************************************************
                          adpcm.c  -  description
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

#include "spu/adpcm.h"

void PCSX::SPU::AdpcmDecoder::saveTo(Protobuf::Int32 &history1, Protobuf::Int32 &history2, Protobuf::Int32 &startOffset,
                                    Protobuf::Int32 &currOffset, Protobuf::Int32 &loopOffset, uint8_t *ramBase) const {
    history1.value = m_s1;
    history2.value = m_s2;
    auto storeOffset = [ramBase](uint8_t *ptr, Protobuf::Int32 &offset) { offset.value = ptr ? ptr - ramBase : -1; };
    storeOffset(m_start, startOffset);
    storeOffset(m_curr, currOffset);
    storeOffset(m_loop, loopOffset);
}

void PCSX::SPU::AdpcmDecoder::loadFrom(const Protobuf::Int32 &history1, const Protobuf::Int32 &history2,
                                      const Protobuf::Int32 &startOffset, const Protobuf::Int32 &currOffset,
                                      const Protobuf::Int32 &loopOffset, uint8_t *ramBase) {
    m_s1 = history1.value;
    m_s2 = history2.value;
    auto restore = [ramBase](const Protobuf::Int32 &offset) -> uint8_t * {
        return offset.value == -1 ? nullptr : offset.value + ramBase;
    };
    m_start = restore(startOffset);
    m_curr = restore(currOffset);
    m_loop = restore(loopOffset);
}

PCSX::SPU::AdpcmDecoder::DecodeResult PCSX::SPU::AdpcmDecoder::decodeBlock(uint8_t *block, Protobuf::Int32 *sb) {
    int s_1 = m_s1;
    int s_2 = m_s2;

    int predict_nr = (int)*block;
    block++;
    int shift_factor = predict_nr & 0xf;
    predict_nr >>= 4;
    int flags = (int)*block;
    block++;

    // -------------------------------------- //
    for (unsigned nSample = 0; nSample < 28; block++) {
        int d = (int)*block;
        int s = ((d & 0xf) << 12);
        if (s & 0x8000) s |= 0xffff0000;

        int fa = (s >> shift_factor);
        fa = fa + ((s_1 * f[predict_nr][0]) >> 6) + ((s_2 * f[predict_nr][1]) >> 6);
        s_2 = s_1;
        s_1 = fa;
        s = ((d & 0xf0) << 8);

        sb[nSample++].value = fa;

        if (s & 0x8000) s |= 0xffff0000;
        fa = (s >> shift_factor);
        fa = fa + ((s_1 * f[predict_nr][0]) >> 6) + ((s_2 * f[predict_nr][1]) >> 6);
        s_2 = s_1;
        s_1 = fa;

        sb[nSample++].value = fa;
    }

    m_s1 = s_1;
    m_s2 = s_2;
    return {block, flags};
}
