/*

MIT License

Copyright (c) 2026 PCSX-Redux authors

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

/* On-die MMIO read-cost probe.
 *
 * Measures the CPU-cycle cost of a single `lw` from an on-die MMIO register.
 * The R3000A has no data cache (that silicon is repurposed as the scratchpad),
 * so every data load is a real bus access and the pipeline stalls on the load
 * result. This isolates that stall for the on-die MMIO fabric - the interrupt
 * controller, the DMA controller, and the root counters - which all share the
 * CPU die's MMIO decoder. On real hardware every on-die register reads at the
 * same cost: 5 CPU cycles (1 issue + 4 stall), i.e. 4 cycles more than a nop.
 *
 * Deliberately NOT covered here: the off-die GPU (GPUSTAT) and the SBUS
 * devices (SPU / CD-ROM / expansion), which ride different, slower paths with
 * programmable per-device delay.
 *
 * Method: root counter 2 in system-clock mode ticks once per CPU cycle
 * (16-bit). A fully-unrolled block of N identical `lw`s is bracketed by two
 * counter reads; a structurally identical N-nop block is the baseline. The two
 * bracketing counter reads are themselves on-die MMIO reads, so their cost is
 * common to both measurements and cancels in the subtraction - and "read
 * RCNT2" is one of the targets, so the instrument measures its own cost as a
 * cross-check. The icache is warmed (first run discarded) and the minimum over
 * several runs is taken to reject stray stalls; interrupts are masked suite-
 * wide.
 *
 * This is a hardware-timing test: on the emulator the modelled MMIO read cost
 * does not match silicon, so every check here is a CESTER_MAYBE_TEST and is
 * skipped under PCSX_TESTS.
 */

#ifndef PCSX_TESTS
#define PCSX_TESTS 0
#endif

#if PCSX_TESTS
#define CESTER_MAYBE_TEST CESTER_SKIP_TEST
#else
#define CESTER_MAYBE_TEST CESTER_TEST
#endif

#include "common/hardware/counters.h"
#include "common/syscalls/syscalls.h"

#undef unix
#define CESTER_NO_SIGNAL
#define CESTER_NO_TIME
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#include "exotic/cester.h"

// clang-format off

/* Number of back-to-back reads per measured block. 256 * 4 bytes = 1 KiB of
   unrolled code, comfortably inside the 4 KiB icache, and 256 * ~5 cyc stays
   well under the counter's 16-bit wrap. */
#define N_READS 256

#define REP4(x)   x x x x
#define REP16(x)  REP4(x)  REP4(x)  REP4(x)  REP4(x)
#define REP64(x)  REP16(x) REP16(x) REP16(x) REP16(x)
#define REP256(x) REP64(x) REP64(x) REP64(x) REP64(x)

/* On-die MMIO targets, all via the uncached KSEG1 mirror. */
#define ADDR_ISTAT  0xbf801070u  /* interrupt controller I_STAT */
#define ADDR_D2MADR 0xbf8010a0u  /* DMA channel 2 MADR          */
#define ADDR_RCNT0  0xbf801100u  /* root counter 0 value        */
#define ADDR_RCNT2  0xbf801108u  /* root counter 2 value        */

CESTER_BODY(
    static int s_interruptsWereEnabled;

    /* N_READS back-to-back `lw` from an uncached MMIO address, bracketed by
       counter-2 reads. Returns the 16-bit cycle delta for the whole block. */
    static uint32_t timed_read(volatile void *p) {
        register uint32_t sink;
        uint16_t before, after;
        before = COUNTERS[2].value;
        __asm__ volatile(REP256("lw %0, 0(%1)\n") : "=&r"(sink) : "r"(p) : "memory");
        after = COUNTERS[2].value;
        (void)sink;
        return (uint16_t)(after - before);
    }

    /* Structurally identical baseline: same operands, same bracket, N_READS nops. */
    static uint32_t timed_nop(volatile void *p) {
        register uint32_t sink;
        uint16_t before, after;
        before = COUNTERS[2].value;
        __asm__ volatile(REP256("nop\n") : "=&r"(sink) : "r"(p) : "memory");
        after = COUNTERS[2].value;
        (void)sink;
        return (uint16_t)(after - before);
    }

    /* Warm the icache (first call discarded), then take the min over 8 runs. */
    static uint32_t bench(uint32_t (*fn)(volatile void *), volatile void *p) {
        uint32_t best = 0xffffu;
        fn(p);
        for (int i = 0; i < 8; i++) {
            uint32_t d = fn(p);
            if (d < best) best = d;
        }
        return best;
    }
)

CESTER_BEFORE_ALL(regread_tests,
    /* Mask interrupts across the timed regions, and set root counter 2 to the
       system-clock source (bits 8-9 = 00), free running. Writing mode resets
       the counter value to 0. */
    s_interruptsWereEnabled = enterCriticalSection();
    COUNTERS[2].mode = 0;
)

CESTER_AFTER_ALL(regread_tests,
    if (s_interruptsWereEnabled) leaveCriticalSection();
)

CESTER_BEFORE_EACH(regread_tests, testname, testindex,
)

CESTER_AFTER_EACH(regread_tests, testname, testindex,
)

/* Every on-die register reads at the same cost, and that cost is a small
   fixed stall the emulator does not model - hence CESTER_MAYBE_TEST. */
CESTER_MAYBE_TEST(onDieMmioReadCost, regread_tests,
    uint32_t base    = bench(timed_nop,  (volatile void *)ADDR_ISTAT);
    uint32_t r_istat = bench(timed_read, (volatile void *)ADDR_ISTAT);
    uint32_t r_dma   = bench(timed_read, (volatile void *)ADDR_D2MADR);
    uint32_t r_rcnt0 = bench(timed_read, (volatile void *)ADDR_RCNT0);
    uint32_t r_rcnt2 = bench(timed_read, (volatile void *)ADDR_RCNT2);

    /* centicycles = cycles * 100, so we can show 2 decimals with integer-only
       printf. abs = per-read incl. issue; marginal = read - nop. */
    uint32_t abs_cc  = (r_istat * 100u + N_READS / 2) / N_READS;
    uint32_t marg    = r_istat - base;
    uint32_t marg_cc = (marg * 100u + N_READS / 2) / N_READS;

    ramsyscall_printf("=== on-die MMIO read cost (N=%d, rcnt2 @ sysclk) ===\n", N_READS);
    ramsyscall_printf("  nop baseline : raw%d=%u\n", N_READS, base);
    ramsyscall_printf("  I_STAT  1f801070: raw%d=%u\n", N_READS, r_istat);
    ramsyscall_printf("  D2_MADR 1f8010a0: raw%d=%u\n", N_READS, r_dma);
    ramsyscall_printf("  RCNT0   1f801100: raw%d=%u\n", N_READS, r_rcnt0);
    ramsyscall_printf("  RCNT2   1f801108: raw%d=%u\n", N_READS, r_rcnt2);
    ramsyscall_printf("  per-read: abs=%u.%02u cyc, marginal(vs nop)=%u.%02u cyc\n",
                      abs_cc / 100u, abs_cc % 100u, marg_cc / 100u, marg_cc % 100u);

    /* Baseline sanity: nops run at ~1 cyc each (plus a tiny constant bracket). */
    cester_assert_true(base >= (uint32_t)N_READS && base <= (uint32_t)N_READS + 16u);

    /* One on-die decoder, one latency: every target must agree exactly. */
    cester_assert_uint_eq(r_istat, r_dma);
    cester_assert_uint_eq(r_istat, r_rcnt0);
    cester_assert_uint_eq(r_istat, r_rcnt2);

    /* The read stall: 4 cyc/read on hardware (band 3..5 to absorb any per-unit
       wobble). The emulator's near-free MMIO read falls well below this, which
       is why this test is hardware-only. */
    cester_assert_true(marg >= (uint32_t)N_READS * 3u && marg <= (uint32_t)N_READS * 5u);
)

CESTER_OPTIONS(
    CESTER_VERBOSE();
)
