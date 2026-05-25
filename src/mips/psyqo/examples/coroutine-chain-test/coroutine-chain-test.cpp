/*

MIT License

Copyright (c) 2025 PCSX-Redux authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

*/

// Test case using real CDRomLoader to exercise the exact coroutine chaining
// pattern that causes corruption in the madnight engine.
// Uses the same 5-deep chain: initialLoad -> hardLoadingScreen -> loadAllFiles
// -> loadAsset -> loadFile -> CDRomLoader::readFile (ReadFileAwaiter + TaskQueue)
//
// Run with an ISO that has SYSTEM.CNF;1 (e.g. ssweep.iso).

#include <EASTL/fixed_string.h>

#include "common/syscalls/syscalls.h"
#include "psyqo/application.hh"
#include "psyqo/buffer.hh"
#include "psyqo/cdrom-device.hh"
#include "psyqo/coroutine.hh"
#include "psyqo/font.hh"
#include "psyqo/gpu.hh"
#include "psyqo/iso9660-parser.hh"
#include "psyqo/kernel.hh"
#include "psyqo/scene.hh"
#include "psyqo/xprintf.h"
#include "psyqo-paths/cdrom-loader.hh"

namespace {

class ChainTest final : public psyqo::Application {
    void prepare() override;
    void createScene() override;

  public:
    psyqo::Font<> m_font;
    psyqo::CDRomDevice m_cdrom;
    psyqo::ISO9660Parser m_isoParser = psyqo::ISO9660Parser(&m_cdrom);
    psyqo::paths::CDRomLoader m_cdromLoader;

    psyqo::Coroutine<> m_coroutine;
    eastl::fixed_string<char, 256> m_text;
    uint32_t m_passCount = 0;
    uint32_t m_failCount = 0;
    uint32_t m_iteration = 0;
    bool m_done = false;

    // The coroutine chain
    psyqo::Coroutine<> resetCDRom();
    psyqo::Coroutine<psyqo::Buffer<uint8_t>> loadFile(const char* filename);
    psyqo::Coroutine<psyqo::Buffer<uint8_t>> loadAsset(const char* filename);
    psyqo::Coroutine<> loadAllFiles();
    psyqo::Coroutine<> hardLoadingScreen();
    psyqo::Coroutine<> initialLoad();
};

class ChainTestScene final : public psyqo::Scene {
    void frame() override;
};

ChainTest app;
ChainTestScene scene;

}  // namespace

psyqo::Coroutine<> ChainTest::resetCDRom() {
    bool doneOnce = false;
    while (true) {
        using namespace psyqo::timer_literals;
        if (doneOnce) co_await gpu().delay(1_s);
        doneOnce = true;
        ramsyscall_printf("Resetting CD-ROM...\n");
        if (!co_await m_cdrom.reset()) {
            ramsyscall_printf("Reset failed, retrying...\n");
            continue;
        }
        ramsyscall_printf("CD-ROM reset OK\n");
        co_return;
    }
}

// Mirrors CDRomHelper::LoadFile:
// co_await the CDRomLoader readFile awaiter, return buffer via co_return.
psyqo::Coroutine<psyqo::Buffer<uint8_t>> ChainTest::loadFile(const char* filename) {
    ramsyscall_printf("    loadFile: reading %s\n", filename);
    auto buffer = co_await m_cdromLoader.readFile(filename, m_isoParser);
    ramsyscall_printf("    loadFile: got %u bytes\n", buffer.size());
    co_return eastl::move(buffer);
}

// Mirrors MeshManager::LoadMeshFromCDROM:
// co_await loadFile (a Coroutine<Buffer<uint8_t>> temporary), validate.
psyqo::Coroutine<psyqo::Buffer<uint8_t>> ChainTest::loadAsset(const char* filename) {
    ramsyscall_printf("  loadAsset: %s\n", filename);
    auto buffer = co_await loadFile(filename);
    if (buffer.empty()) {
        ramsyscall_printf("  loadAsset: EMPTY\n");
    } else {
        ramsyscall_printf("  loadAsset: OK (%u bytes, first=0x%02x)\n", buffer.size(), buffer[0]);
    }
    co_return eastl::move(buffer);
}

// Mirrors LoadingScene::LoadFiles:
psyqo::Coroutine<> ChainTest::loadAllFiles() {
    // Load files matching the madnight engine's exact pattern:
    // 1. TEXTURES/STREET.TIM;1 (~17kB texture)
    // 2. MODELS/STREET.MB;1 (~19kB mesh)
    // The corruption reportedly hits on the larger file.
    static const char* files[] = {
        "TEXTURES/STREET.TIM;1",
        "MODELS/STREET.MB;1",
    };
    for (int i = 0; i < 2; i++) {
        ramsyscall_printf("  Load #%d:\n", i);
        auto buffer = co_await loadAsset(files[i]);
        if (!buffer.empty()) {
            m_passCount++;
            ramsyscall_printf("  Load #%d: PASS (%u bytes)\n", i, buffer.size());
        } else {
            m_failCount++;
            ramsyscall_printf("  Load #%d: FAIL (%s)\n", i, files[i]);
        }
    }
    co_return;
}

// Mirrors MadnightEngine::HardLoadingScreen:
psyqo::Coroutine<> ChainTest::hardLoadingScreen() {
    co_await loadAllFiles();
    co_return;
}

// Mirrors MadnightEngine::InitialLoad:
psyqo::Coroutine<> ChainTest::initialLoad() {
    co_await resetCDRom();

    for (unsigned i = 0; i < 5; i++) {
        m_iteration = i + 1;
        fsprintf(m_text, "Iteration %u/5...", m_iteration);
        ramsyscall_printf("=== Iteration %u ===\n", m_iteration);
        co_await hardLoadingScreen();
    }

    if (m_failCount == 0) {
        fsprintf(m_text, "ALL PASSED (%u loads)", m_passCount);
        ramsyscall_printf("\n*** ALL PASSED (%u loads) ***\n", m_passCount);
    } else {
        fsprintf(m_text, "FAILED: %u/%u corrupted", m_failCount, m_passCount + m_failCount);
        ramsyscall_printf("\n*** FAILED: %u/%u corrupted ***\n", m_failCount, m_passCount + m_failCount);
    }
    m_done = true;
    ramsyscall_printf("pcsx:ings1\n");
    co_return;
}

void ChainTest::prepare() {
    psyqo::GPU::Configuration config;
    config.set(psyqo::GPU::Resolution::W320)
        .set(psyqo::GPU::VideoMode::AUTO)
        .set(psyqo::GPU::ColorMode::C15BITS)
        .set(psyqo::GPU::Interlace::PROGRESSIVE);
    gpu().initialize(config);
    m_cdrom.prepare();
}

void ChainTest::createScene() {
    m_font.uploadSystemFont(gpu());
    pushScene(&scene);
    m_text = "Starting CD-ROM chain test...";
    ramsyscall_printf("Coroutine chain test (real CDRomLoader)\n");
    ramsyscall_printf("5-deep chain with actual CD-ROM I/O, 5 iterations x 3 files\n\n");
    m_coroutine = initialLoad();
    m_coroutine.resume();
}

void ChainTestScene::frame() {
    auto& gpu = app.gpu();
    gpu.clear({{.r = 0, .g = 64, .b = 91}});
    auto c = psyqo::Color{{.r = 255, .g = 255, .b = 255}};
    app.m_font.print(gpu, app.m_text, {{.x = 4, .y = 32}}, c);

    if (app.m_done) {
        auto rc = app.m_failCount == 0 ? psyqo::Color{{.r = 0, .g = 255, .b = 0}}
                                        : psyqo::Color{{.r = 255, .g = 0, .b = 0}};
        eastl::fixed_string<char, 64> summary;
        fsprintf(summary, "Pass: %u  Fail: %u", app.m_passCount, app.m_failCount);
        app.m_font.print(gpu, summary, {{.x = 4, .y = 64}}, rc);
    }
}

int main() { return app.run(); }
