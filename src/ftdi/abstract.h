/***************************************************************************
 *   Copyright (C) 2020 PCSX-Redux authors                                 *
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

#include <atomic>
#include <functional>
#include <string>

#include "gui/gui.h"
#include "support/slice.h"

namespace PCSX {

namespace FTDI {

class Devices;
namespace Private {
class DeviceData;
}
class Device {
  public:
    Device();
    ~Device();
    bool isLocked() const { return m_locked; }
    bool isHighSpeed() const { return m_highSpeed; }
    uint16_t getVendorID() const { return m_vendorID; }
    uint16_t getDeviceID() const { return m_deviceID; }
    uint32_t getType() const { return m_type; }
    const std::string& getSerial() const { return m_serial; }
    const std::string& getDescription() const { return m_description; }

    bool isOpened() const;
    bool isBusy() const;

    void open();
    void close();

    // technically private, but difficult to enforce properly
    void asyncCallback() {}
    void asyncCloseCallback() { m_asyncClosed = true; }

  private:
    bool m_locked = false;
    bool m_highSpeed = false;
    uint16_t m_vendorID = 0;
    uint16_t m_deviceID = 0;
    uint32_t m_type = 0;
    std::string m_serial = "";
    std::string m_description = "";

    Private::DeviceData* m_private = nullptr;

    static const unsigned SLICES_COUNT = 256;
    Slice m_slices[SLICES_COUNT];
    std::atomic_uint16_t m_slicesIndexes = 0;

    uv_async_t m_async;
    bool m_asyncClosed = false;

    unsigned usedSlices() {
        uint16_t indexes = m_slicesIndexes.load();
        unsigned first = indexes & 0xff;
        unsigned last = (indexes >> 8) & 0xff;
        if (last < first) last += 256;
        return last - first;
    }

    unsigned availableSlices() { return 256 - usedSlices(); }

    Slice& allocateSlice() {
        while (availableSlices() == 0)
            ;
        uint16_t indexes = m_slicesIndexes.fetch_add(0x100);
        return m_slices[(indexes >> 8) & 0xff];
    }

    friend class Devices;
};

class Devices {
  public:
    static void scan();
    static void shutdown();
    static void iterate(std::function<bool(Device&)>);
    static bool isThreadRunning();
    static void startThread();
    static void stopThread();
    static void setGUI(GUI*);

    // technically private, but difficult to enforce properly
    static void threadProc();
};

}  // namespace FTDI

}  // namespace PCSX
