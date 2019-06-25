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

#include "imgui.h"

#include "core/system.h"
#include "gpu/debug.h"
#include "gpu/prim.h"

void PCSX::GPU::Debugger::show() {
    if (!ImGui::Begin(_("GPU Debugger"), &m_show, ImGuiWindowFlags_MenuBar)) {
        ImGui::End();
        return;
    }

    if (ImGui::BeginMenuBar()) {
        if (ImGui::BeginMenu(_("File"))) {
            ImGui::EndMenu();
        }
        if (ImGui::BeginMenu(_("Debug"))) {
            ImGui::MenuItem(_("Enable frame capture"), nullptr, &m_frameCapture);
            ImGui::MenuItem(_("Capture invalid and empty commands"), nullptr, &m_captureInvalidAndEmpty);
            ImGui::Separator();
            ImGui::MenuItem(_("Breakpoint on end of frame"), nullptr, &m_breakOnFrame);
            ImGui::MenuItem(_("Also break on empty frame"), nullptr, &m_breakOnEmptyFrame);
            ImGui::EndMenu();
        }
        ImGui::EndMenuBar();
    }

    if (ImGui::Button(_("Resume"))) g_system->resume();

    for (const auto &cmd : m_lastFrameEvents) {
        std::string title = cmd->title();
        ImGui::Text("%s", title.c_str());
    }

    ImGui::End();
}

std::string PCSX::GPU::Debug::VRAMRead::title() {
    char address[9];
    std::snprintf(address, 9, "%08x", m_to);
    return std::string("VRAM read (") + std::to_string(m_x) + ", " + std::to_string(m_y) + ") +(" +
           std::to_string(m_width) + ", " + std::to_string(m_height) + ") " + std::to_string(m_size) + " bytes @0x" +
           address;
}

std::string PCSX::GPU::Debug::VRAMWrite::title() {
    char address[9];
    std::snprintf(address, 9, "%08x", m_from);
    return std::string("VRAM write (") + std::to_string(m_x) + ", " + std::to_string(m_y) + ") +(" +
           std::to_string(m_width) + ", " + std::to_string(m_height) + ") " + std::to_string(m_size) + " bytes @0x" +
           address;
}

std::string PCSX::GPU::Debug::DMASetup::title() {
    switch (m_direction) {
        case 0:
            return _("WriteSatus CMD 0x04 DMA Setup - disabled");
        case 2:
            return _("WriteSatus CMD 0x04 DMA Setup - CPU -> GPU");
        case 3:
            return _("WriteSatus CMD 0x04 DMA Setup - GPU -> CPU");
        default:
            return _("WriteSatus CMD 0x04 DMA Setup - unknown mode: ") + std::to_string(m_direction);
    }
}

std::string PCSX::GPU::Debug::DisplayStart::title() {
    uint16_t x = m_data & 0x3ff;
    uint16_t y = (m_data >> 10) & 0x1ff;
    uint16_t extra = m_data >> 19;
    if (extra) {
        char extraC[3];
        std::snprintf(extraC, 3, "%02x", extra);
        return _("WriteSatus CMD 0x05 Display Start (") + std::to_string(x) + ", " + std::to_string(y) +
               _(") extra: ") + extraC;
    } else {
        return _("WriteSatus CMD 0x05 Display Start (") + std::to_string(x) + ", " + std::to_string(y) + ")";
    }
}

std::string PCSX::GPU::Debug::HDispRange::title() {
    uint16_t x1 = m_data & 0xfff;
    uint16_t x2 = (m_data >> 12) & 0xfff;
    return _("WriteSatus CMD 0x06 Horizontal Display Range ") + std::to_string(x1) + " - " + std::to_string(x2);
}

std::string PCSX::GPU::Debug::VDispRange::title() {
    uint16_t y1 = m_data & 0x3ff;
    uint16_t y2 = (m_data >> 10) & 0x3ff;
    uint16_t extra = m_data >> 20;
    if (extra) {
        char extraC[3];
        std::snprintf(extraC, 3, "%02x", extra);
        return _("WriteSatus CMD 0x07 Vertical Display Range ") + std::to_string(y1) + " - " + std::to_string(y2) +
               _(" - extra: ") + extraC;
    } else {
        return _("WriteSatus CMD 0x07 Vertical Display Range ") + std::to_string(y1) + " - " + std::to_string(y2);
    }
}

std::string PCSX::GPU::Debug::SetDisplayMode::title() {
    uint8_t w0 = m_data & 3;
    bool h = (m_data >> 2) & 1;
    bool mode = (m_data >> 3) & 1;
    bool rgb = (m_data >> 4) & 1;
    bool inter = (m_data >> 5) & 1;
    bool w1 = (m_data >> 6) & 1;
    bool reverse = (m_data >> 7) & 1;

    uint16_t extra = m_data >> 8;

    std::string ret = _("WriteSatus CMD 0x08 Set Display Mode; width: ");
    ret += std::to_string(w0);
    ret += _("; height: ");
    ret += h ? "1" : "0";
    ret += _("; mode: ");
    ret += mode ? "1" : "0";
    ret += rgb ? _("; RGB888") : _("; RGB555");
    ret += inter ? _("; interlaced") : _("; not interlaced");
    ret += "; w1: ";
    ret += w1 ? "1" : "0";
    ret += _("; reverse: ");
    ret += reverse ? "true" : "false";

    if (extra) {
        char C[5];
        std::snprintf(C, 5, "%04x", extra);
        ret += _("; extra: ") + std::string(C);
    }

    return ret;
}

std::string PCSX::GPU::Debug::GetDisplayInfo::title() {
    return _("WriteSatus CMD 0x10 Get Display Info; index: ") + std::to_string(m_data);
}

class GenericPrim : public PCSX::GPU::Debug::Command {
  public:
    GenericPrim(uint8_t cmd) : m_cmd(cmd) {}
    std::string title() {
        char cmd[3];
        std::snprintf(cmd, 3, "%02x", m_cmd);
        return _("DMA command 0x") + std::string(cmd);
    }

  private:
    uint8_t m_cmd;
};

static PCSX::GPU::Debug::Command *genericPrim(uint8_t cmd) { return new GenericPrim(cmd); }

PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgCmdSTP(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgCmdTexturePage(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgCmdTextureWindow(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgCmdDrawAreaStart(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgCmdDrawAreaEnd(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgCmdDrawOffset(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimLoadImage(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimStoreImage(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimBlkFill(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimMoveImage(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimTileS(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimTile1(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimTile8(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimTile16(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimSprt8(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimSprt16(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimSprtS(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimPolyF4(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimPolyG4(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimPolyFT3(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimPolyFT4(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimPolyGT3(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimPolyG3(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimPolyGT4(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimPolyF3(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimLineGSkip(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimLineGEx(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimLineG2(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimLineFSkip(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimLineFEx(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimLineF2(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
PCSX::GPU::Debug::Command *PCSX::GPU::Prim::dbgPrimNI(uint8_t cmd, uint8_t *baseAddr) { return genericPrim(cmd); }
