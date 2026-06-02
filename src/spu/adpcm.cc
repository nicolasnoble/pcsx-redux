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

int PCSX::SPU::AdpcmDecoder::decodeBlock(uint8_t *block, Protobuf::Int32 *sb, uint8_t *&blockEnd) {
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
    blockEnd = block;
    return flags;
}
