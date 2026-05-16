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

// Saturating helper for packed-pair 5-bit channels.
//
// The packed writers represent one color channel as an int32_t whose two
// 16-bit halfwords each carry a 5-bit value in bits 0..4. The value
// arrives there post-modulate, typically as
//
//     int32_t r = (((color & 0x001f001f) * factor) & 0xff80ff80) >> 7;
//
// which leaves each halfword in 0..0x3f. saturate5Pair clamps each
// halfword to 31: if any of bits 5..14 of a halfword are set, that
// halfword's low five bits become 0x1f. The opposite halfword is
// preserved bit-for-bit. The two halves are tested independently so a
// single helper covers both lanes; the carry behaviour is identical to
// the open-coded six-line pattern this replaces.
struct PackedPair555 {
    static inline int32_t saturate5Pair(int32_t c) {
        if (c & 0x7fe00000) c = 0x1f0000 | (c & 0xffff);
        if (c & 0x7fe0) c = 0x1f | (c & 0xffff0000);
        return c;
    }
};

// Native-position channel traits for the BGR555 layout.
//
// The PSX 16-bit pixel layout keeps each colour channel in a fixed
// position: R in bits 0..4, B in bits 5..9, G in bits 10..14, mask in
// bit 15. The scalar pixel writers do per-channel math entirely at
// native position - extract via `color & Mask`, multiply by a 0..255
// modulation factor, shift right by 7, then saturate. The saturate is
// the same shape across all three channels: probe whether any bit
// above the channel's native top is set, and clamp to the channel's
// max value if so.
//
// Channel555::R / B / G expose `mask` (native-position extract /
// max-value) and `saturateNative(c)` (post-multiply clamp). Use the
// channel type for both the extract and the saturate so the two halves
// of the round-trip stay consistent.
namespace Channel555 {

template <uint32_t Mask, uint32_t Overflow>
struct Trait {
    static constexpr uint32_t mask = Mask;
    static constexpr uint32_t overflowMask = Overflow;
    static inline int32_t saturateNative(int32_t c) {
        if (c & Overflow) c = Mask;
        return c;
    }
};

using R = Trait<0x1f, 0x7fffffe0>;
using B = Trait<0x3e0, 0x7ffffc00>;
using G = Trait<0x7c00, 0x7fff8000>;

}  // namespace Channel555

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
        r = Channel555::R::saturateNative(r);
        b = Channel555::B::saturateNative(b);
        g = Channel555::G::saturateNative(g);
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
        r = PackedPair555::saturate5Pair(r);
        b = PackedPair555::saturate5Pair(b);
        g = PackedPair555::saturate5Pair(g);
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

// Textured, flat-shaded, Default (runtime checkMask + drawSemiTrans).
//
// Matches the legacy `getTextureTransColShade` (scalar) and
// `getTextureTransColShade32` (pair) member helpers bit for bit.
// Reads checkMask, drawSemiTrans, and abr from RasterState at runtime;
// handles all four BlendFunction cases (HalfBackAndHalfFront,
// FullBackAndFullFront, FullBackSubFullFront, HalfBackAndQuarter).
//
// Semantic differences vs Solid:
//   - scalar honors checkMask via an early return when the destination
//     mask bit is already set
//   - both entry points blend with the destination color when the
//     source mask bit is set and drawSemiTrans is true
//   - packed handles checkMask after the math, with per-halfword
//     destination preservation when the destination's mask bit is set
//     or the corresponding source halfword is zero
template <>
struct PixelWriter<true, GPU::Shading::Flat, WriteMode::Default> {
    static inline void scalar(const RasterState &rs, uint16_t *pdest, uint16_t color) {
        if (color == 0) return;
        if (rs.checkMask && *pdest & 0x8000) return;
        const uint16_t l = rs.setMask16 | (color & 0x8000);
        int32_t r, g, b;
        if (rs.drawSemiTrans && (color & 0x8000)) {
            if (rs.abr == GPU::BlendFunction::HalfBackAndHalfFront) {
                // (B + F_modulated) / 2 per channel, in 5-bit space. The
                // historical `((B|F) & 0x7bde) >> 1` shortcut drops the
                // bit-0 carry term: hardware preserves it (verified on
                // SCPH-5501 via gpu-raster-phase12 abr0_tri_b31_f31).
                const int32_t Br = *pdest & 0x1f;
                const int32_t Bb = (*pdest >> 5) & 0x1f;
                const int32_t Bg = (*pdest >> 10) & 0x1f;
                const int32_t Fr = ((color & 0x1f) * rs.m1) >> 7;
                const int32_t Fb = (((color >> 5) & 0x1f) * rs.m2) >> 7;
                const int32_t Fg = (((color >> 10) & 0x1f) * rs.m3) >> 7;
                r = (Br + Fr) >> 1;
                b = ((Bb + Fb) >> 1) << 5;
                g = ((Bg + Fg) >> 1) << 10;
            } else if (rs.abr == GPU::BlendFunction::FullBackAndFullFront) {
                r = (*pdest & 0x1f) + (((color & 0x1f) * rs.m1) >> 7);
                b = (*pdest & 0x3e0) + (((color & 0x3e0) * rs.m2) >> 7);
                g = (*pdest & 0x7c00) + (((color & 0x7c00) * rs.m3) >> 7);
            } else if (rs.abr == GPU::BlendFunction::FullBackSubFullFront) {
                r = (*pdest & 0x1f) - (((color & 0x1f) * rs.m1) >> 7);
                b = (*pdest & 0x3e0) - (((color & 0x3e0) * rs.m2) >> 7);
                g = (*pdest & 0x7c00) - (((color & 0x7c00) * rs.m3) >> 7);
                if (r & 0x80000000) r = 0;
                if (b & 0x80000000) b = 0;
                if (g & 0x80000000) g = 0;
            } else {
                r = (*pdest & 0x1f) + ((((color & 0x1f) >> 2) * rs.m1) >> 7);
                b = (*pdest & 0x3e0) + ((((color & 0x3e0) >> 2) * rs.m2) >> 7);
                g = (*pdest & 0x7c00) + ((((color & 0x7c00) >> 2) * rs.m3) >> 7);
            }
        } else {
            r = ((color & 0x1f) * rs.m1) >> 7;
            b = ((color & 0x3e0) * rs.m2) >> 7;
            g = ((color & 0x7c00) * rs.m3) >> 7;
        }
        r = Channel555::R::saturateNative(r);
        b = Channel555::B::saturateNative(b);
        g = Channel555::G::saturateNative(g);
        *pdest = ((g & 0x7c00) | (b & 0x3e0) | (r & 0x1f)) | l;
    }

    static inline void packed(const RasterState &rs, uint32_t *pdest, uint32_t color) {
        if (color == 0) return;
        const uint32_t l = rs.setMask32 | (color & 0x80008000);
        int32_t r, g, b;
        if (rs.drawSemiTrans && (color & 0x80008000)) {
            if (rs.abr == GPU::BlendFunction::HalfBackAndHalfFront) {
                // X32TCOL1(*pdest) is (*pdest & 0x001f001f) << 7 (red scaled up
                // so we can add the multiplied source without losing range).
                r = ((((*pdest & 0x001f001f) << 7) + ((color & 0x001f001f) * rs.m1)) & 0xff00ff00) >> 8;
                b = ((((*pdest & 0x03e003e0) << 2) + (((color >> 5) & 0x001f001f) * rs.m2)) & 0xff00ff00) >> 8;
                g = ((((*pdest & 0x7c007c00) >> 3) + (((color >> 10) & 0x001f001f) * rs.m3)) & 0xff00ff00) >> 8;
            } else if (rs.abr == GPU::BlendFunction::FullBackAndFullFront) {
                r = (*pdest & 0x001f001f) + ((((color & 0x001f001f) * rs.m1) & 0xff80ff80) >> 7);
                b = ((*pdest >> 5) & 0x001f001f) + (((((color >> 5) & 0x001f001f) * rs.m2) & 0xff80ff80) >> 7);
                g = ((*pdest >> 10) & 0x001f001f) + (((((color >> 10) & 0x001f001f) * rs.m3) & 0xff80ff80) >> 7);
            } else if (rs.abr == GPU::BlendFunction::FullBackSubFullFront) {
                int32_t t;
                r = (((color & 0x001f001f) * rs.m1) & 0xff80ff80) >> 7;
                t = (*pdest & 0x001f0000) - (r & 0x003f0000);
                if (t & 0x80000000) t = 0;
                r = (*pdest & 0x0000001f) - (r & 0x0000003f);
                if (r & 0x80000000) r = 0;
                r |= t;

                b = ((((color >> 5) & 0x001f001f) * rs.m2) & 0xff80ff80) >> 7;
                t = ((*pdest >> 5) & 0x001f0000) - (b & 0x003f0000);
                if (t & 0x80000000) t = 0;
                b = ((*pdest >> 5) & 0x0000001f) - (b & 0x0000003f);
                if (b & 0x80000000) b = 0;
                b |= t;

                g = ((((color >> 10) & 0x001f001f) * rs.m3) & 0xff80ff80) >> 7;
                t = ((*pdest >> 10) & 0x001f0000) - (g & 0x003f0000);
                if (t & 0x80000000) t = 0;
                g = ((*pdest >> 10) & 0x0000001f) - (g & 0x0000003f);
                if (g & 0x80000000) g = 0;
                g |= t;
            } else {
                // HalfBackAndQuarter: X32BCOL1(color) is color & 0x001c001c
                // (drops bits 0-1 so >> 2 stays lossless).
                r = (*pdest & 0x001f001f) + (((((color & 0x001c001c) >> 2) * rs.m1) & 0xff80ff80) >> 7);
                b = ((*pdest >> 5) & 0x001f001f) + (((((color >> 5) & 0x001c001c) >> 2) * rs.m2) & 0xff80ff80) >> 7;
                g = ((*pdest >> 10) & 0x001f001f) + (((((color >> 10) & 0x001c001c) >> 2) * rs.m3) & 0xff80ff80) >> 7;
            }

            // If only one half of the source has its mask bit set, the other
            // half still needs to be multiplied as if it were a non-blended
            // texel. Patch the corresponding halfword of r/b/g afterwards.
            if (!(color & 0x8000)) {
                r = (r & 0xffff0000) | ((((color & 0x001f001f) * rs.m1) & 0x0000ff80) >> 7);
                b = (b & 0xffff0000) | (((((color >> 5) & 0x001f001f) * rs.m2) & 0x0000ff80) >> 7);
                g = (g & 0xffff0000) | (((((color >> 10) & 0x001f001f) * rs.m3) & 0x0000ff80) >> 7);
            }
            if (!(color & 0x80000000)) {
                r = (r & 0xffff) | ((((color & 0x001f001f) * rs.m1) & 0xFF800000) >> 7);
                b = (b & 0xffff) | (((((color >> 5) & 0x001f001f) * rs.m2) & 0xFF800000) >> 7);
                g = (g & 0xffff) | (((((color >> 10) & 0x001f001f) * rs.m3) & 0xFF800000) >> 7);
            }
        } else {
            r = (((color & 0x001f001f) * rs.m1) & 0xff80ff80) >> 7;
            b = ((((color >> 5) & 0x001f001f) * rs.m2) & 0xff80ff80) >> 7;
            g = ((((color >> 10) & 0x001f001f) * rs.m3) & 0xff80ff80) >> 7;
        }

        r = PackedPair555::saturate5Pair(r);
        b = PackedPair555::saturate5Pair(b);
        g = PackedPair555::saturate5Pair(g);

        const uint32_t packed_rgb = (g << 10) | (b << 5) | r;
        if (rs.checkMask) {
            const uint32_t ma = *pdest;
            *pdest = packed_rgb | l;
            if ((color & 0xffff) == 0) *pdest = (ma & 0xffff) | (*pdest & 0xffff0000);
            if ((color & 0xffff0000) == 0) *pdest = (ma & 0xffff0000) | (*pdest & 0xffff);
            if (ma & 0x80000000) *pdest = (ma & 0xffff0000) | (*pdest & 0xffff);
            if (ma & 0x00008000) *pdest = (ma & 0xffff) | (*pdest & 0xffff0000);
            return;
        }
        if ((color & 0xffff) == 0) {
            *pdest = (*pdest & 0xffff) | ((packed_rgb | l) & 0xffff0000);
            return;
        }
        if ((color & 0xffff0000) == 0) {
            *pdest = (*pdest & 0xffff0000) | ((packed_rgb | l) & 0xffff);
            return;
        }
        *pdest = packed_rgb | l;
    }
};

// Textured, gouraud-shaded, Solid (!checkMask && !drawSemiTrans && !ditherMode).
//
// Matches the legacy `getTextureTransColShadeXSolid` (scalar) and
// `getTextureTransColShadeX32Solid` (pair) member helpers bit for bit.
// The "X" suffix in the legacy names is the family marker for "modulation
// passed per-call as int16_t m1/m2/m3 args" rather than from
// RasterState.m1/m2/m3 - that's what makes this the Gouraud specialization.
//
// The packed entry takes m1/m2/m3 as int16_t parameters; callers pack the
// gouraud-interpolated integer parts of two consecutive pixels via
// `(c >> 16) | ((c + dif) & 0xff0000)`. Sign-extension during the int16_t
// promotion drops the high half, so both pixels of a packed pair end up
// using the first pixel's modulation - a documented PS1-emulation
// approximation also present in the legacy helpers.
template <>
struct PixelWriter<true, GPU::Shading::Gouraud, WriteMode::Solid> {
    static inline void scalar(const RasterState &rs, uint16_t *pdest, uint16_t color, int16_t m1, int16_t m2,
                              int16_t m3) {
        if (color == 0) return;
        int32_t r = ((color & 0x1f) * m1) >> 7;
        int32_t b = ((color & 0x3e0) * m2) >> 7;
        int32_t g = ((color & 0x7c00) * m3) >> 7;
        r = Channel555::R::saturateNative(r);
        b = Channel555::B::saturateNative(b);
        g = Channel555::G::saturateNative(g);
        *pdest = ((g & 0x7c00) | (b & 0x3e0) | (r & 0x1f)) | rs.setMask16 | (color & 0x8000);
    }

    static inline void packed(const RasterState &rs, uint32_t *pdest, uint32_t color, int16_t m1, int16_t m2,
                              int16_t m3) {
        if (color == 0) return;
        int32_t r = (((color & 0x001f001f) * m1) & 0xff80ff80) >> 7;
        int32_t b = ((((color >> 5) & 0x001f001f) * m2) & 0xff80ff80) >> 7;
        int32_t g = ((((color >> 10) & 0x001f001f) * m3) & 0xff80ff80) >> 7;
        r = PackedPair555::saturate5Pair(r);
        b = PackedPair555::saturate5Pair(b);
        g = PackedPair555::saturate5Pair(g);
        const uint32_t flags = rs.setMask32 | (color & 0x80008000);
        const uint32_t packed_rgb = (g << 10) | (b << 5) | r;
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

// Textured, gouraud-shaded, Default (runtime checkMask + drawSemiTrans, no
// dither). Matches the legacy `getTextureTransColShadeX` (scalar) member
// helper bit for bit. Only a scalar entry point is provided because the
// gouraud slow path iterates one pixel at a time (color interpolation
// changes per pixel, the packed-pair fast path is unavailable for it).
//
// The dithered variant (matching `getTextureTransColShadeXDither`) lives in
// a separate Dither specialization because it operates on a different
// channel representation (right-aligned 8-bit channels via XCOL1D/2D/3D vs
// the native-position channels here) and dispatches through
// applyDither/applyDitherCached for the final write.
template <>
struct PixelWriter<true, GPU::Shading::Gouraud, WriteMode::Default> {
    static inline void scalar(const RasterState &rs, uint16_t *pdest, uint16_t color, int16_t m1, int16_t m2,
                              int16_t m3) {
        if (color == 0) return;
        if (rs.checkMask && *pdest & 0x8000) return;
        const uint16_t l = rs.setMask16 | (color & 0x8000);
        int32_t r, g, b;
        if (rs.drawSemiTrans && (color & 0x8000)) {
            if (rs.abr == GPU::BlendFunction::HalfBackAndHalfFront) {
                // Carry-preserving (B + F_modulated) / 2 per channel.
                // See PixelWriter<true, Flat, Default>::scalar for the
                // hardware rationale (phase-12 abr0_tri_b31_f31).
                const int32_t Br = *pdest & 0x1f;
                const int32_t Bb = (*pdest >> 5) & 0x1f;
                const int32_t Bg = (*pdest >> 10) & 0x1f;
                const int32_t Fr = ((color & 0x1f) * m1) >> 7;
                const int32_t Fb = (((color >> 5) & 0x1f) * m2) >> 7;
                const int32_t Fg = (((color >> 10) & 0x1f) * m3) >> 7;
                r = (Br + Fr) >> 1;
                b = ((Bb + Fb) >> 1) << 5;
                g = ((Bg + Fg) >> 1) << 10;
            } else if (rs.abr == GPU::BlendFunction::FullBackAndFullFront) {
                r = (*pdest & 0x1f) + (((color & 0x1f) * m1) >> 7);
                b = (*pdest & 0x3e0) + (((color & 0x3e0) * m2) >> 7);
                g = (*pdest & 0x7c00) + (((color & 0x7c00) * m3) >> 7);
            } else if (rs.abr == GPU::BlendFunction::FullBackSubFullFront) {
                r = (*pdest & 0x1f) - (((color & 0x1f) * m1) >> 7);
                b = (*pdest & 0x3e0) - (((color & 0x3e0) * m2) >> 7);
                g = (*pdest & 0x7c00) - (((color & 0x7c00) * m3) >> 7);
                if (r & 0x80000000) r = 0;
                if (b & 0x80000000) b = 0;
                if (g & 0x80000000) g = 0;
            } else {
                r = (*pdest & 0x1f) + ((((color & 0x1f) >> 2) * m1) >> 7);
                b = (*pdest & 0x3e0) + ((((color & 0x3e0) >> 2) * m2) >> 7);
                g = (*pdest & 0x7c00) + ((((color & 0x7c00) >> 2) * m3) >> 7);
            }
        } else {
            r = ((color & 0x1f) * m1) >> 7;
            b = ((color & 0x3e0) * m2) >> 7;
            g = ((color & 0x7c00) * m3) >> 7;
        }
        r = Channel555::R::saturateNative(r);
        b = Channel555::B::saturateNative(b);
        g = Channel555::G::saturateNative(g);
        *pdest = ((g & 0x7c00) | (b & 0x3e0) | (r & 0x1f)) | l;
    }
};

// Untextured, flat-shaded, Default (runtime checkMask + drawSemiTrans).
//
// Matches the legacy `getShadeTransCol` (scalar) and `getShadeTransCol32`
// (pair) member helpers bit for bit. Used by the untextured paths -
// drawPoly3Fi (flat triangle, slow path) and the line / fill / sprite
// helpers - where there is no texture sampler and `color` is the
// primitive's solid color, optionally blended with the destination on
// drawSemiTrans.
//
// No Modulation here: untextured writes the color through unchanged
// (modulation::On for an untextured primitive in the legacy code path
// is a no-op; the primitive's color word IS the final color). No
// modulation factors are consulted; the channel multiplies that the
// textured writers do are absent.
template <>
struct PixelWriter<false, GPU::Shading::Flat, WriteMode::Default> {
    static inline void scalar(const RasterState &rs, uint16_t *pdest, uint16_t color) {
        if (rs.checkMask && *pdest & 0x8000) return;
        if (rs.drawSemiTrans) {
            int32_t r, g, b;
            if (rs.abr == GPU::BlendFunction::HalfBackAndHalfFront) {
                // Carry-preserving (B + F) / 2 per channel. The legacy
                // `((B|F) & 0x7bde) >> 1` shortcut drops the bit-0
                // carry; hardware preserves it.
                const int32_t Br = *pdest & 0x1f;
                const int32_t Bb = (*pdest >> 5) & 0x1f;
                const int32_t Bg = (*pdest >> 10) & 0x1f;
                const int32_t Fr = color & 0x1f;
                const int32_t Fb = (color >> 5) & 0x1f;
                const int32_t Fg = (color >> 10) & 0x1f;
                r = (Br + Fr) >> 1;
                b = ((Bb + Fb) >> 1) << 5;
                g = ((Bg + Fg) >> 1) << 10;
            } else if (rs.abr == GPU::BlendFunction::FullBackAndFullFront) {
                r = (*pdest & 0x1f) + (color & 0x1f);
                b = (*pdest & 0x3e0) + (color & 0x3e0);
                g = (*pdest & 0x7c00) + (color & 0x7c00);
            } else if (rs.abr == GPU::BlendFunction::FullBackSubFullFront) {
                r = (*pdest & 0x1f) - (color & 0x1f);
                b = (*pdest & 0x3e0) - (color & 0x3e0);
                g = (*pdest & 0x7c00) - (color & 0x7c00);
                if (r & 0x80000000) r = 0;
                if (b & 0x80000000) b = 0;
                if (g & 0x80000000) g = 0;
            } else {
                r = (*pdest & 0x1f) + ((color & 0x1f) >> 2);
                b = (*pdest & 0x3e0) + ((color & 0x3e0) >> 2);
                g = (*pdest & 0x7c00) + ((color & 0x7c00) >> 2);
            }
            r = Channel555::R::saturateNative(r);
            b = Channel555::B::saturateNative(b);
            g = Channel555::G::saturateNative(g);
            *pdest = ((g & 0x7c00) | (b & 0x3e0) | (r & 0x1f)) | rs.setMask16;
        } else {
            *pdest = color | rs.setMask16;
        }
    }

    static inline void packed(const RasterState &rs, uint32_t *pdest, uint32_t color) {
        if (rs.drawSemiTrans) {
            int32_t r, g, b;
            if (rs.abr == GPU::BlendFunction::HalfBackAndHalfFront) {
                // Per-channel (B + F) / 2 across the two packed pixels.
                // Replaces the legacy `((p|color) & 0x7bde7bde) >> 1`
                // shortcut, which dropped each channel's bit-0 carry.
                // Hardware preserves it (phase-12 abr0_tri_b31_f31).
                const uint32_t Br = *pdest & 0x001f001f;
                const uint32_t Bb = (*pdest >> 5) & 0x001f001f;
                const uint32_t Bg = (*pdest >> 10) & 0x001f001f;
                const uint32_t Fr = color & 0x001f001f;
                const uint32_t Fb = (color >> 5) & 0x001f001f;
                const uint32_t Fg = (color >> 10) & 0x001f001f;
                if (!rs.checkMask) {
                    const uint32_t hr = ((Br + Fr) >> 1) & 0x001f001f;
                    const uint32_t hb = ((Bb + Fb) >> 1) & 0x001f001f;
                    const uint32_t hg = ((Bg + Fg) >> 1) & 0x001f001f;
                    *pdest = (hg << 10) | (hb << 5) | hr | rs.setMask32;
                    return;
                }
                r = ((Br + Fr) >> 1) & 0x001f001f;
                b = ((Bb + Fb) >> 1) & 0x001f001f;
                g = ((Bg + Fg) >> 1) & 0x001f001f;
            } else if (rs.abr == GPU::BlendFunction::FullBackAndFullFront) {
                r = (*pdest & 0x001f001f) + (color & 0x001f001f);
                b = ((*pdest >> 5) & 0x001f001f) + ((color >> 5) & 0x001f001f);
                g = ((*pdest >> 10) & 0x001f001f) + ((color >> 10) & 0x001f001f);
            } else if (rs.abr == GPU::BlendFunction::FullBackSubFullFront) {
                int32_t sr, sb, sg, src, sbc, sgc, c;
                src = color & 0x1f;
                sbc = color & 0x3e0;
                sgc = color & 0x7c00;
                c = (*pdest) >> 16;
                sr = (c & 0x1f) - src;
                if (sr & 0x8000) sr = 0;
                sb = (c & 0x3e0) - sbc;
                if (sb & 0x8000) sb = 0;
                sg = (c & 0x7c00) - sgc;
                if (sg & 0x8000) sg = 0;
                r = ((int32_t)sr) << 16;
                b = ((int32_t)sb) << 11;
                g = ((int32_t)sg) << 6;
                c = (*pdest) & 0xffff;
                sr = (c & 0x1f) - src;
                if (sr & 0x8000) sr = 0;
                sb = (c & 0x3e0) - sbc;
                if (sb & 0x8000) sb = 0;
                sg = (c & 0x7c00) - sgc;
                if (sg & 0x8000) sg = 0;
                r |= sr;
                b |= sb >> 5;
                g |= sg >> 10;
            } else {
                // HalfBackAndQuarter: X32BCOL1 = (x & 0x001c001c). Drops bits 0-1 so >> 2 stays lossless.
                r = (*pdest & 0x001f001f) + ((color & 0x001c001c) >> 2);
                b = ((*pdest >> 5) & 0x001f001f) + (((color >> 5) & 0x001c001c) >> 2);
                g = ((*pdest >> 10) & 0x001f001f) + (((color >> 10) & 0x001c001c) >> 2);
            }
            r = PackedPair555::saturate5Pair(r);
            b = PackedPair555::saturate5Pair(b);
            g = PackedPair555::saturate5Pair(g);
            const uint32_t packed_rgb = (g << 10) | (b << 5) | r;
            if (rs.checkMask) {
                const uint32_t ma = *pdest;
                *pdest = packed_rgb | rs.setMask32;
                if (ma & 0x80000000) *pdest = (ma & 0xffff0000) | (*pdest & 0xffff);
                if (ma & 0x00008000) *pdest = (ma & 0xffff) | (*pdest & 0xffff0000);
                return;
            }
            *pdest = packed_rgb | rs.setMask32;
        } else {
            if (rs.checkMask) {
                const uint32_t ma = *pdest;
                *pdest = color | rs.setMask32;
                if (ma & 0x80000000) *pdest = (ma & 0xffff0000) | (*pdest & 0xffff);
                if (ma & 0x00008000) *pdest = (ma & 0xffff) | (*pdest & 0xffff0000);
                return;
            }
            *pdest = color | rs.setMask32;
        }
    }
};

}  // namespace SoftGPU

}  // namespace PCSX
