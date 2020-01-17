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

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN

#include <assert.h>
#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <shared_mutex>
#include <thread>

#include "ftd2xx.h"
#include "ftdi/abstract.h"

namespace PCSX {
namespace FTDI {
namespace Private {
class DeviceData {
  public:
    FT_HANDLE m_handle = nullptr;
    HANDLE m_event = nullptr;
    enum {
        STATE_CLOSED,
        STATE_OPEN_PENDING,
        STATE_OPENED,
        STATE_CLOSE_PENDING,
    } m_state = STATE_CLOSED;
};
}  // namespace Private
}  // namespace FTDI
}  // namespace PCSX

static std::vector<PCSX::FTDI::Device> s_devices;
static HANDLE s_thread;
static std::atomic_bool s_exitThread;
static bool s_threadRunning = false;
static HANDLE s_kickEvent = nullptr;
static std::shared_mutex s_listLock;
static unsigned s_numOpened = 0;

PCSX::FTDI::Device::~Device() {
    assert(m_private->m_state == Private::DeviceData::STATE_CLOSED);
    assert(!m_private->m_event);
    assert(!m_private->m_handle);
    delete m_private;
}

void PCSX::FTDI::Device::open() {
    std::shared_lock<std::shared_mutex> guard(s_listLock);
    assert(m_private->m_state == Private::DeviceData::STATE_CLOSED);
    m_private->m_state = Private::DeviceData::STATE_OPEN_PENDING;
    SetEvent(s_kickEvent);
}
void PCSX::FTDI::Device::close() {
    std::shared_lock<std::shared_mutex> guard(s_listLock);
    assert(m_private->m_state == Private::DeviceData::STATE_OPENED);
    m_private->m_state = Private::DeviceData::STATE_CLOSE_PENDING;
    SetEvent(s_kickEvent);
}
bool PCSX::FTDI::Device::isOpened() const { return m_private->m_state == Private::DeviceData::STATE_OPENED; }

void PCSX::FTDI::Devices::scan() {
    FT_STATUS status;
    DWORD numDevs = 0;

    std::unique_lock<std::shared_mutex> guard(s_listLock);
    if (s_numOpened != 0) return;

    s_devices.clear();
    status = FT_CreateDeviceInfoList(&numDevs);

    if (status != FT_OK || numDevs == 0) return;

    FT_DEVICE_LIST_INFO_NODE* nodes = new FT_DEVICE_LIST_INFO_NODE[numDevs];

    status = FT_GetDeviceInfoList(nodes, &numDevs);

    if (status == FT_OK && numDevs != 0) {
        s_devices.resize(numDevs);
        for (DWORD i = 0; i < numDevs; i++) {
            const FT_DEVICE_LIST_INFO_NODE* n = nodes + i;
            s_devices[i].m_locked = n->Flags & FT_FLAGS_OPENED;
            s_devices[i].m_highSpeed = n->Flags & FT_FLAGS_HISPEED;
            s_devices[i].m_vendorID = (n->ID >> 16) & 0xffff;
            s_devices[i].m_deviceID = n->ID & 0xffff;
            s_devices[i].m_type = n->Type;
            s_devices[i].m_serial = n->SerialNumber;
            s_devices[i].m_description = n->Description;
            s_devices[i].m_private = new Private::DeviceData();
        }
    }

    delete[] nodes;
}

void PCSX::FTDI::Devices::iterate(std::function<bool(Device&)> iter) {
    std::shared_lock<std::shared_mutex> guard(s_listLock);
    for (auto& d : s_devices) {
        if (!iter(d)) break;
    }
}

void PCSX::FTDI::Devices::threadProc() {
    SetThreadDescription(GetCurrentThread(), L"abstract ftd2xx thread");
    while (!s_exitThread) {
        std::vector<HANDLE> objects;
        objects.push_back(s_kickEvent);
        {
            std::shared_lock<std::shared_mutex> guard(s_listLock);

            for (auto& device : s_devices) {
                switch (device.m_private->m_state) {
                    case Private::DeviceData::STATE_OPEN_PENDING:
                        s_numOpened++;
                        FT_OpenEx(const_cast<char*>(device.m_serial.c_str()), FT_OPEN_BY_SERIAL_NUMBER,
                                  &device.m_private->m_handle);
                        device.m_private->m_event = CreateEvent(nullptr, FALSE, FALSE, L"Event for FTDI device");
                        FT_SetEventNotification(device.m_private->m_handle,
                                                FT_EVENT_RXCHAR | FT_EVENT_MODEM_STATUS | FT_EVENT_LINE_STATUS,
                                                device.m_private->m_event);
                        device.m_private->m_state = Private::DeviceData::STATE_OPENED;
                    case Private::DeviceData::STATE_OPENED:
                        objects.push_back(device.m_private->m_event);
                        break;
                    case Private::DeviceData::STATE_CLOSE_PENDING:
                        s_numOpened--;
                        FT_Close(device.m_private->m_handle);
                        CloseHandle(device.m_private->m_event);
                        device.m_private->m_handle = nullptr;
                        device.m_private->m_event = nullptr;
                        device.m_private->m_state = Private::DeviceData::STATE_CLOSED;
                        break;
                }
            }
        }
        DWORD idx;
        do {
            assert(objects.size() <= MAXIMUM_WAIT_OBJECTS);
            idx = WaitForMultipleObjects(objects.size(), objects.data(), FALSE, INFINITE);
        } while (idx != WAIT_OBJECT_0);
    }
    CloseHandle(s_kickEvent);
    s_kickEvent = nullptr;
    s_exitThread = false;
    s_threadRunning = false;
}

static DWORD WINAPI threadProcTrampoline(LPVOID parameter) {
    PCSX::FTDI::Devices::threadProc();
    return 0;
}

void PCSX::FTDI::Devices::startThread() {
    assert(!s_threadRunning);
    s_kickEvent = CreateEvent(nullptr, FALSE, FALSE, L"abstract ftd2xx kick event");
    s_threadRunning = true;
    s_thread = CreateThread(nullptr, 0, threadProcTrampoline, nullptr, 0, nullptr);
}

void PCSX::FTDI::Devices::stopThread() {
    assert(s_threadRunning);
    s_exitThread = true;
    SetEvent(s_kickEvent);
    WaitForSingleObject(s_thread, INFINITE);
    s_thread = nullptr;
    assert(!s_threadRunning);
}

bool PCSX::FTDI::Devices::isThreadRunning() { return s_threadRunning; }

#endif
