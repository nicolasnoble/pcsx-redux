/***************************************************************************
 *   Copyright (C) 2022 PCSX-Redux authors                                 *
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

#include <stdint.h>

#include "core/gpu.h"
#include "gpu/soft/raster-state.h"

namespace PCSX {

namespace SoftGPU {

// Compile-time write mode for the per-pixel writer policy. Picks which
// branches of the existing pixel-helper family the writer collapses to.
//
//  - Solid:   guaranteed !checkMask && !drawSemiTrans. The fast path
//             writes through with mask/blend disabled. Zero-texel halves
//             of a packed pair preserve the existing destination bits;
//             the source's mask bit gets ORed into the result. Matches
//             the legacy `getTextureTransCol*Solid` helpers.
//  - Default: handles checkMask and drawSemiTrans at runtime by reading
//             RasterState. Matches the legacy `getTextureTransCol*`
//             helpers without the Solid suffix.
//  - Semi:    drawSemiTrans known true at compile time. Matches
//             `getTextureTransColShadeSemi` / `getTextureTransColG32Semi`.
enum class WriteMode { Solid, Default, Semi };

// Per-pixel writer policy. Each specialization owns both a scalar (one
// 16-bit pixel) and a packed (a 32-bit pair, low halfword first) entry
// point. The packed entry must produce bit-equivalent output to two
// successive scalar entries against the same destination, modulo the
// existing fast-path optimizations the legacy code already encodes.
//
// Specializations exist only for the (Textured, Shading, WriteMode)
// triples that the rasterizer currently exercises. Adding a new one is
// the migration path for the next legacy helper.
template <bool Textured, GPU::Shading Shading, WriteMode WM>
struct PixelWriter;

// Textured, flat-shaded, Solid (!checkMask && !drawSemiTrans).
//
// Matches the legacy `getTextureTransColShadeSolid` (scalar) and
// `getTextureTransColShade32Solid` (pair) member helpers bit for bit.
// Modulation::Off folds in via the neutral 128 coefficients in
// RasterState.m1/m2/m3 (same multiply path as Modulation::On).
template <>
struct PixelWriter<true, GPU::Shading::Flat, WriteMode::Solid> {
    static inline void scalar(const RasterState &rs, uint16_t *pdest, uint16_t color) {
        if (color == 0) return;
        const uint16_t l = rs.setMask16 | (color & 0x8000);
        int32_t r = ((color & 0x1f) * rs.m1) >> 7;
        int32_t b = ((color & 0x3e0) * rs.m2) >> 7;
        int32_t g = ((color & 0x7c00) * rs.m3) >> 7;
        if (r & 0x7fffffe0) r = 0x1f;
        if (b & 0x7ffffc00) b = 0x3e0;
        if (g & 0x7fff8000) g = 0x7c00;
        *pdest = ((g & 0x7c00) | (b & 0x3e0) | (r & 0x1f)) | l;
    }

    static inline void packed(const RasterState &rs, uint32_t *pdest, uint32_t color) {
        if (color == 0) return;
        // Channels are extracted in packed-pair form: bits 0..4 of each
        // halfword for red, 5..9 for blue, 10..14 for green. Multiplying
        // by m1/m2/m3 (0..255) keeps both halves of the int32 valid as
        // long as we mask post-multiply with 0xff80ff80 before the >> 7
        // (otherwise the high half's overflow would bleed into the low
        // half's saturation check).
        int32_t r = (((color & 0x001f001f) * rs.m1) & 0xff80ff80) >> 7;
        int32_t b = ((((color >> 5) & 0x001f001f) * rs.m2) & 0xff80ff80) >> 7;
        int32_t g = ((((color >> 10) & 0x001f001f) * rs.m3) & 0xff80ff80) >> 7;
        if (r & 0x7fe00000) r = 0x1f0000 | (r & 0xffff);
        if (r & 0x7fe0) r = 0x1f | (r & 0xffff0000);
        if (b & 0x7fe00000) b = 0x1f0000 | (b & 0xffff);
        if (b & 0x7fe0) b = 0x1f | (b & 0xffff0000);
        if (g & 0x7fe00000) g = 0x1f0000 | (g & 0xffff);
        if (g & 0x7fe0) g = 0x1f | (g & 0xffff0000);
        const uint32_t flags = rs.setMask32 | (color & 0x80008000);
        const uint32_t packed_rgb = (g << 10) | (b << 5) | r;
        // Zero-texel-half preservation: an entirely-zero halfword of the
        // source color means "transparent texel", and the destination
        // halfword keeps its prior value.
        if ((color & 0xffff) == 0) {
            *pdest = (*pdest & 0xffff) | ((packed_rgb | flags) & 0xffff0000);
            return;
        }
        if ((color & 0xffff0000) == 0) {
            *pdest = (*pdest & 0xffff0000) | ((packed_rgb | flags) & 0xffff);
            return;
        }
        *pdest = packed_rgb | flags;
    }
};

}  // namespace SoftGPU

}  // namespace PCSX
