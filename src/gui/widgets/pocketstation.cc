/***************************************************************************
 *   Copyright (C) 2026 PCSX-Redux authors                                 *
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

#include "gui/widgets/pocketstation.h"

#include <stdint.h>

#include "core/system.h"
#include "imgui.h"
#include "pocketstation/pocketstation.h"

// Keyboard / gamepad -> PocketStation button map. The 5 buttons are INT_INPUT bits 0..4:
//   bit 0 Fire   <- Z / Enter / gamepad A (face-down)
//   bit 1 Right  <- Right arrow / D-pad right
//   bit 2 Left   <- Left arrow  / D-pad left
//   bit 3 Down   <- Down arrow  / D-pad down
//   bit 4 Up     <- Up arrow    / D-pad up
// Input is only sampled while the LCD window is focused; losing focus (or collapsing it) releases
// all buttons, so a held key can't get stuck when you tab away. setButtons() reflects the mask into
// INT_INPUT as live levels and latches a press (which is what wakes a sleeping device on Fire).
static uint32_t readButtonMask() {
    uint32_t mask = 0;
    if (ImGui::IsKeyDown(ImGuiKey_Z) || ImGui::IsKeyDown(ImGuiKey_Enter) ||
        ImGui::IsKeyDown(ImGuiKey_GamepadFaceDown))
        mask |= 1u << 0;  // Fire
    if (ImGui::IsKeyDown(ImGuiKey_RightArrow) || ImGui::IsKeyDown(ImGuiKey_GamepadDpadRight)) mask |= 1u << 1;
    if (ImGui::IsKeyDown(ImGuiKey_LeftArrow) || ImGui::IsKeyDown(ImGuiKey_GamepadDpadLeft)) mask |= 1u << 2;
    if (ImGui::IsKeyDown(ImGuiKey_DownArrow) || ImGui::IsKeyDown(ImGuiKey_GamepadDpadDown)) mask |= 1u << 3;
    if (ImGui::IsKeyDown(ImGuiKey_UpArrow) || ImGui::IsKeyDown(ImGuiKey_GamepadDpadUp)) mask |= 1u << 4;
    return mask;
}

void PCSX::Widgets::PocketStationLCD::draw(PocketStation::PocketStation* device, const char* title) {
    const bool open = ImGui::Begin(title, &m_show);

    // Feed button input every frame from the focus state: the held-key mask while focused, 0
    // otherwise (released on unfocus/collapse). Done before the early returns so buttons are always
    // released when the window isn't interactive.
    if (device != nullptr) {
        const uint32_t mask = (open && ImGui::IsWindowFocused()) ? readButtonMask() : 0;
        device->setButtons(mask);
    }

    if (!open) {
        ImGui::End();
        return;
    }

    if (device == nullptr) {
        ImGui::TextUnformatted(
            _("No PocketStation docked.\n"
              "Enable PocketStation mode on a memory card slot and set the\n"
              "PocketStation BIOS path in the configuration to dock one."));
        ImGui::End();
        return;
    }

    const bool enabled = device->lcdEnabled();
    const uint32_t mode = device->lcdMode();
    const bool rotate = (mode >> 7) & 1;  // LCDMode bit 7: flip the screen 180 degrees.
    const uint8_t* vram = device->vram();

    // Expand the 32x32 1bpp framebuffer to RGBA8. Bit set == lit (black on the physical LCD).
    // A disabled LCD renders blank. Rotate mirrors both axes (180-degree flip).
    static constexpr uint32_t kOn = 0xff202020;   // near-black lit pixel (ABGR for GL_RGBA/LE).
    static constexpr uint32_t kOff = 0xffc8dcb4;  // pale green LCD background.
    for (int row = 0; row < 32; row++) {
        uint32_t word = 0;
        if (enabled) {
            // vram is row-major, 4 bytes per row, bit `col` (LSB first) selects the pixel.
            word = static_cast<uint32_t>(vram[row * 4 + 0]) | (static_cast<uint32_t>(vram[row * 4 + 1]) << 8) |
                   (static_cast<uint32_t>(vram[row * 4 + 2]) << 16) | (static_cast<uint32_t>(vram[row * 4 + 3]) << 24);
        }
        for (int col = 0; col < 32; col++) {
            const bool on = (word >> col) & 1u;
            const int dstRow = rotate ? (31 - row) : row;
            const int dstCol = rotate ? (31 - col) : col;
            m_pixels[dstRow * 32 + dstCol] = on ? kOn : kOff;
        }
    }

    if (m_texture == 0) {
        glGenTextures(1, &m_texture);
        glBindTexture(GL_TEXTURE_2D, m_texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 32, 32, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    }
    glBindTexture(GL_TEXTURE_2D, m_texture);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 32, 32, GL_RGBA, GL_UNSIGNED_BYTE, m_pixels);

    const float scale = 6.0f;
    ImGui::Image((ImTextureID)(intptr_t)m_texture, ImVec2(32 * scale, 32 * scale));
    ImGui::Text(_("LCD mode: %08X (%s%s)"), mode, enabled ? _("on") : _("off"), rotate ? _(", rotated") : "");

    ImGui::End();
}
