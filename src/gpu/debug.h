/***************************************************************************
 *   Copyright (C) 2019 PCSX-Redux authors                                 *
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

#include <functional>
#include <string>
#include <vector>

#include "core/system.h"

namespace PCSX {

namespace GPU {

namespace Debug {

class Command {
  public:
    virtual ~Command() {}
    virtual std::string title() = 0;
};

}  // namespace Debug

class Debugger {
  public:
    Debugger(bool& show) : m_show(show) {}
    void show();

    void nextFrame() {
        if (m_breakOnFrame) {
            if (!m_breakOnEmptyFrame) {
                if (!m_currentFrameEvents.empty()) g_system->pause();
            } else {
                g_system->pause();
            }
        }
        m_lastFrameEvents.clear();
        m_currentFrameEvents.swap(m_lastFrameEvents);
    }

    void addEvent(std::function<Debug::Command*()> commandGenerator, bool isInvalidOrEmpty = false) {
        if (!m_frameCapture) return;
        if (isInvalidOrEmpty && !m_captureInvalidAndEmpty) return;
        if (!commandGenerator) return;
        Debug::Command* cmd = commandGenerator();
        if (!cmd) return;
        m_currentFrameEvents.emplace_back(cmd);
    }

  private:
    bool& m_show;
    bool m_frameCapture = false;
    bool m_captureInvalidAndEmpty = false;
    bool m_breakOnFrame = false;
    bool m_breakOnEmptyFrame = false;
    std::vector<std::unique_ptr<Debug::Command>> m_currentFrameEvents;
    std::vector<std::unique_ptr<Debug::Command>> m_lastFrameEvents;
};

namespace Debug {
class Invalid : public Command {
  public:
    Invalid(const char* reason) : m_reason(reason) {}
    Invalid(const std::string& reason) : m_reason(reason) {}
    Invalid(std::string&& reason) : m_reason(std::move(reason)) {}
    std::string title() final { return m_reason; }

  private:
    std::string m_reason;
};

class Verbose : public Command {
  public:
    Verbose(const char* message) : m_message(message) {}
    Verbose(const std::string& message) : m_message(message) {}
    Verbose(std::string&& message) : m_message(std::move(message)) {}
    std::string title() final { return m_message; }

  private:
    std::string m_message;
};

class VRAMRead : public Command {
  public:
    VRAMRead(uint32_t to, int size, int16_t x, int16_t y, int16_t width, int16_t height)
        : m_to(to), m_size(size), m_x(x), m_y(y), m_width(width), m_height(height) {}
    std::string title() final;

  private:
    uint32_t m_to;
    int m_size;
    int16_t m_x, m_y, m_width, m_height;
};

class VRAMWrite : public Command {
  public:
    VRAMWrite(uint32_t from, int size, int16_t x, int16_t y, int16_t width, int16_t height)
        : m_from(from), m_size(size), m_x(x), m_y(y), m_width(width), m_height(height) {}
    std::string title() final;

  private:
    uint32_t m_from;
    int m_size;
    int16_t m_x, m_y, m_width, m_height;
};

class Reset : public Command {
    std::string title() final { return _("WriteSatus CMD 0x00 GPU Reset"); }
};

class DisplayEnable : public Command {
  public:
    DisplayEnable(bool enabled) : m_enabled(enabled) {
        if (enabled) {
            m_enabledStr = _("Enabled");
        } else {
            m_enabledStr = _("Disabled");
        }
    }
    std::string title() final { return _("WriteSatus CMD 0x03 Display ") + m_enabledStr; }

  private:
    bool m_enabled;
    std::string m_enabledStr;
};

class DMASetup : public Command {
  public:
    DMASetup(uint32_t direction) : m_direction(direction) {}
    std::string title() final;

  private:
    uint32_t m_direction;
};

class DisplayStart : public Command {
  public:
    DisplayStart(uint32_t data) : m_data(data) {}
    std::string title() final;

  private:
    uint32_t m_data;
};

class HDispRange : public Command {
  public:
    HDispRange(uint32_t data) : m_data(data) {}
    std::string title() final;

  private:
    uint32_t m_data;
};

class VDispRange : public Command {
  public:
    VDispRange(uint32_t data) : m_data(data) {}
    std::string title() final;

  private:
    uint32_t m_data;
};

class SetDisplayMode : public Command {
  public:
    SetDisplayMode(uint32_t data) : m_data(data) {}
    std::string title() final;

  private:
    uint32_t m_data;
};

class GetDisplayInfo : public Command {
  public:
    GetDisplayInfo(uint32_t data) : m_data(data) {}
    std::string title() final;

  private:
    uint32_t m_data;
};

// ---- dma packets

class ClearCache : public Command {
    std::string title() final { return _("DMA CMD - ClearCache"); }
};

class BlockFill : public Command {
  public:
    BlockFill(uint32_t color, int16_t x, int16_t y, int16_t w, int16_t h)
        : m_color(color), m_x(x), m_y(y), m_w(w), m_h(h) {}
    std::string title() final;

  private:
    const uint32_t m_color;
    const int16_t m_x, m_y, m_w, m_h;
};

class Polygon : public Command {
  public:
    Polygon(bool iip, bool vtx, bool tme, bool abe, bool tge)
        : m_iip(iip), m_vtx(vtx), m_tme(tme), m_abe(abe), m_tge(tge) {}
    void setColor(uint32_t c, unsigned idx) { m_colors[idx] = c; }
    void setX(int16_t x, unsigned idx) { m_x[idx] = x; }
    void setY(int16_t y, unsigned idx) { m_y[idx] = y; }
    void setU(uint8_t u, unsigned idx) { m_u[idx] = u; }
    void setV(uint8_t v, unsigned idx) { m_v[idx] = v; }
    void setClutID(uint16_t clutID) { m_clutID = clutID; }
    void setTexturePage(uint16_t texturePage) { m_texturePage = texturePage; }
    std::string title() final;

  private:
    const bool m_iip, m_vtx, m_tme, m_abe, m_tge;
    uint32_t m_colors[4];
    int16_t m_x[4];
    int16_t m_y[4];
    uint8_t m_u[4];
    uint8_t m_v[4];
    uint16_t m_clutID;
    uint16_t m_texturePage;
};

class Line : public Command {
  public:
    Line(bool iip, bool pll, bool abe) : m_iip(iip), m_pll(pll), m_abe(abe) {}
    void setColors(const std::vector<uint32_t>& colors) { m_colors = colors; }
    void setX(const std::vector<int16_t>& x) { m_x = x; }
    void setY(const std::vector<int16_t>& y) { m_y = y; }
    std::string title() final;

  private:
    const bool m_iip, m_pll, m_abe;
    std::vector<uint32_t> m_colors;
    std::vector<int16_t> m_x;
    std::vector<int16_t> m_y;
};

class Sprite : public Command {
  public:
    Sprite(bool tme, bool abe, uint32_t color, int16_t x, int16_t y, uint8_t u, uint8_t v, uint16_t clutID, int16_t w,
           int16_t h)
        : m_tme(tme), m_abe(abe), m_color(color), m_x(x), m_y(y), m_u(u), m_v(v), m_clutID(clutID), m_w(w), m_h(h) {}
    std::string title() final;

  private:
    bool m_tme, m_abe;
    uint32_t m_color;
    int16_t m_x, m_y;
    uint8_t m_u, m_v;
    uint16_t m_clutID;
    int16_t m_w, m_h;
};

class Blit : public Command {
  public:
    Blit(int16_t sx, int16_t sy, int16_t dx, int16_t dy, int16_t w, int16_t h)
        : m_sx(sx), m_sy(sy), m_dx(dx), m_dy(dy), m_w(w), m_h(h) {}
    std::string title() final;

  private:
    int16_t m_sx, m_sy, m_dx, m_dy, m_w, m_h;
};

class VRAMWriteCmd : public Command {
  public:
    VRAMWriteCmd(int16_t x, int16_t y, int16_t w, int16_t h) : m_x(x), m_y(y), m_w(w), m_h(h) {}
    std::string title() final;

  private:
    int16_t m_x, m_y, m_w, m_h;
};

class VRAMReadCmd : public Command {
  public:
    VRAMReadCmd(int16_t x, int16_t y, int16_t w, int16_t h) : m_x(x), m_y(y), m_w(w), m_h(h) {}
    std::string title() final;

  private:
    int16_t m_x, m_y, m_w, m_h;
};

class DrawModeSetting : public Command {
  public:
    DrawModeSetting(uint8_t tx, uint8_t ty, uint8_t abr, uint8_t tp, bool dtd, bool dfe, bool td, bool txflip, bool tyflip)
        : m_tx(tx), m_ty(ty), m_abr(abr), m_tp(tp), m_dtd(dtd), m_dfe(dfe), m_td(td), m_txflip(txflip), m_tyflip(tyflip) {}
    std::string title() final;

  private:
    bool m_dtd, m_dfe, m_td, m_txflip, m_tyflip;
    uint8_t m_tx, m_ty, m_abr, m_tp;
};

class TextureWindowSetting : public Command {
  public:
    TextureWindowSetting(uint8_t twmx, uint8_t twmy, uint8_t twox, uint8_t twoy)
        : m_twmx(twmx), m_twmy(twmy), m_twox(twox), m_twoy(twoy) {}
    std::string title() final;

  private:
    uint8_t m_twmx, m_twmy, m_twox, m_twoy;
};

class SetDrawingAreaTopLeft : public Command {
  public:
    SetDrawingAreaTopLeft(uint16_t x, uint16_t y) : m_x(x), m_y(y) {}
    std::string title() final;

  private:
    uint16_t m_x, m_y;
};

class SetDrawingAreaBottomRight : public Command {
  public:
    SetDrawingAreaBottomRight(uint16_t x, uint16_t y) : m_x(x), m_y(y) {}
    std::string title() final;

  private:
    uint16_t m_x, m_y;
};

class SetDrawingOffset : public Command {
  public:
    SetDrawingOffset(uint16_t x, uint16_t y) : m_x(x), m_y(y) {}
    std::string title() final;

  private:
    uint16_t m_x, m_y;
};

class SetMaskSettings : public Command {
  public:
    SetMaskSettings(bool setMask, bool useMask) : m_setMask(setMask), m_useMask(useMask) {}
    std::string title() final;

  private:
    bool m_setMask, m_useMask;
};

}  // namespace Debug

}  // namespace GPU

}  // namespace PCSX
