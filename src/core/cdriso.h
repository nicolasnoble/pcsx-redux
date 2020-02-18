/***************************************************************************
 *   Copyright (C) 2007 PCSX-df Team                                       *
 *   Copyright (C) 2009 Wei Mingzhi                                        *
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

#pragma once

#include <stdio.h>

#include "core/plugins.h"
#include "core/psxemulator.h"
#include "support/file.h"

namespace PCSX {

class CDRiso {
  public:
    bool isLidOpened() { return m_cdOpenCaseTime < 0 || m_cdOpenCaseTime > (int64_t)time(NULL); }
    void setCdOpenCaseTime(int64_t time) { m_cdOpenCaseTime = time; }
    void init();
    void shutdown();
    bool open();
    void close();
    bool getTN(uint8_t* buffer);
    bool getTD(uint8_t track, uint8_t* buffer);
    bool readTrack(uint8_t* time);
    uint8_t* getBuffer();
    void play(uint8_t* time);
    void stop();
    uint8_t* getBufferSub();
    bool getStatus(CdrStat* stat);
    bool readCDDA(unsigned char m, unsigned char s, unsigned char f, unsigned char* buffer);

    bool isActive();

    unsigned m_cdrIsoMultidiskCount;
    unsigned m_cdrIsoMultidiskSelect;

    int LoadSBI(const char* filename);
    bool CheckSBI(const uint8_t* time);

  private:
    typedef ssize_t (CDRiso::*read_func_t)(File* f, unsigned int base, void* dest, int sector);

    int64_t m_cdOpenCaseTime = 0;
    bool m_useCompressed = false;

    File* m_subHandle = NULL;

    bool m_subChanMixed = false;
    bool m_subChanRaw = false;
    bool m_subChanMissing = false;

    bool m_multifile = false;
    bool m_isMode1ISO = false;  // TODO: use sector size/mode info from CUE also?

    uint8_t m_cdbuffer[2352];
    uint8_t m_subbuffer[96];

    bool m_playing = false;
    bool m_cddaBigEndian = false;
    uint32_t m_cddaCurPos = 0;
    /* Frame offset into CD image where pregap data would be found if it was there.
     * If a game seeks there we must *not* return subchannel data since it's
     * not in the CD image, so that cdrom code can fake subchannel data instead.
     * XXX: there could be multiple pregaps but PSX dumps only have one? */
    unsigned int m_pregapOffset;

    // compressed image stuff
    struct compr_img_t {
        unsigned char buff_raw[16][2352];
        unsigned char buff_compressed[2352 * 16 + 100];
        unsigned int* index_table;
        unsigned int index_len;
        unsigned int block_shift;
        unsigned int current_block;
        unsigned int sector_in_blk;
    }* m_compr_img = NULL;

    read_func_t m_cdimg_read_func = NULL;
    uint32_t m_prevsector;

    ////////////////////////////////////////////////////////////////////////////////
    //
    // LUTs used for computing ECC/EDC
    //
    uint8_t m_ecc_f_lut[256];
    uint8_t m_ecc_b_lut[256];
    uint32_t m_edc_lut[256];

    static inline const uint8_t ZEROADDRESS[4] = {0, 0, 0, 0};

    struct trackinfo {
        enum track_type_t { CLOSED = 0, DATA = 1, CDDA = 2 } type = CLOSED;
        uint8_t start[3] = {0, 0, 0};                                      // MSF-format
        uint8_t length[3] = {0, 0, 0};                                     // MSF-format
        File* handle = nullptr;                                            // for multi-track images CDDA
        enum cddatype_t { NONE = 0, BIN = 1, CCDDA = 2 } cddatype = NONE;  // BIN, WAV, MP3, APE
        char* decoded_buffer = nullptr;
        uint32_t len_decoded_buffer = 0;
        char filepath[256] = {0};
        uint32_t start_offset = 0;  // byte offset from start of above file
    };

    static const unsigned MAXTRACKS = 100;

    int m_numtracks = 0;
    struct trackinfo m_ti[MAXTRACKS];

    // redump.org SBI files
    uint8_t sbitime[256][3], sbicount;

    uint32_t get32lsb(const uint8_t* src);
    void put32lsb(uint8_t* dest, uint32_t value);
    void eccedc_init();
    uint32_t edc_compute(uint32_t edc, const uint8_t* src, size_t size);
    void ecc_writepq(const uint8_t* address, const uint8_t* data, size_t major_count, size_t minor_count,
                     size_t major_mult, size_t minor_inc, uint8_t* ecc);
    void ecc_writesector(const uint8_t* address, const uint8_t* data, uint8_t* ecc);
    void reconstruct_sector(uint8_t* sector, int8_t type);
    // get a sector from a msf-array
    static unsigned int msf2sec(const uint8_t* msf) { return ((msf[0] * 60 + msf[1]) * 75) + msf[2]; }
    static void sec2msf(unsigned int s, uint8_t* msf) {
        msf[0] = s / 75 / 60;
        s = s - msf[0] * 75 * 60;
        msf[1] = s / 75;
        s = s - msf[1] * 75;
        msf[2] = s;
    }
    static void tok2msf(char* time, char* msf);
    trackinfo::cddatype_t get_cdda_type(const char* str);
    void DecodeRawSubData();
    int do_decode_cdda(struct trackinfo* tri, uint32_t tracknumber);
    int parsetoc(const char* isofile);
    int parsecue(const char* isofile);
    int parseccd(const char* isofile);
    int parsemds(const char* isofile);
    int handlepbp(const char* isofile);
    int handlecbin(const char* isofile);
    int opensubfile(const char* isoname);
    ssize_t cdread_normal(File* f, unsigned int base, void* dest, int sector);
    ssize_t cdread_sub_mixed(File* f, unsigned int base, void* dest, int sector);
    ssize_t cdread_compressed(File* f, unsigned int base, void* dest, int sector);
    ssize_t cdread_2048(File* f, unsigned int base, void* dest, int sector);
    void PrintTracks();
    void UnloadSBI();
    int opensbifile(const char* isoname);
};

}  // namespace PCSX
