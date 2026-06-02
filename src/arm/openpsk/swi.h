/*
 * OpenPSK SWI call wrappers (C side). These emit `swi #n` and marshal r0 as arg-in / result-out,
 * matching the dispatcher in swi.S. The milestone SWIs are custom; the documented PocketStation
 * ABI (SWI 00h-18h + the FUNC sub-dispatch) is layered on top of this same mechanism later.
 */
#pragma once

/* SWI #0: return a fixed magic constant. */
static inline unsigned psk_swi_magic(void) {
    register unsigned r0 __asm__("r0");
    __asm__ volatile("swi #0" : "=r"(r0) : : "r1", "r2", "r3", "memory");
    return r0;
}

/* SWI #1: return (x + 0x100). Proves the argument reaches the handler and the result comes back. */
static inline unsigned psk_swi_xform(unsigned x) {
    register unsigned r0 __asm__("r0") = x;
    __asm__ volatile("swi #1" : "+r"(r0) : : "r1", "r2", "r3", "memory");
    return r0;
}
