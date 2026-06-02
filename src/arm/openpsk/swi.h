/*
 * OpenPSK SWI call wrappers (C side). These emit `swi #n` and marshal r0-r3 as args-in / r0 as
 * result-out, matching the dispatcher in swi.S. The documented PocketStation SWI numbers come from
 * psx-spx docs/pocketstation.md; the magic/xform pair are custom dispatch-proof SWIs at 1Ah/1Bh.
 */
#pragma once

/* SWI 0Ch - SetBcdDateTime(date, time): date is the SWI 0Dh format (day/month/year),
 * time is the SWI 0Eh format (sec/min/hour/day-of-week). Both in BCD. */
static inline void psk_swi_set_bcd_date_time(unsigned date, unsigned time) {
    register unsigned r0 __asm__("r0") = date;
    register unsigned r1 __asm__("r1") = time;
    __asm__ volatile("swi #0x0C" : "+r"(r0) : "r"(r1) : "r2", "r3", "memory");
}

/* SWI 0Dh - GetBcdDate(): day:8 month:8 _:8 year(4-digit):16 -> bits 0-7 day, 8-11 month, 16-31 year. */
static inline unsigned psk_swi_get_bcd_date(void) {
    register unsigned r0 __asm__("r0");
    __asm__ volatile("swi #0x0D" : "=r"(r0) : : "r1", "r2", "r3", "memory");
    return r0;
}

/* SWI 0Eh - GetBcdTime(): bits 0-7 seconds, 8-15 minutes, 16-23 hours, 24-31 day-of-week (BCD). */
static inline unsigned psk_swi_get_bcd_time(void) {
    register unsigned r0 __asm__("r0");
    __asm__ volatile("swi #0x0E" : "=r"(r0) : : "r1", "r2", "r3", "memory");
    return r0;
}

/* SWI 1Ah (custom): return a fixed magic constant. Proves a SWI dispatched through the table. */
static inline unsigned psk_swi_magic(void) {
    register unsigned r0 __asm__("r0");
    __asm__ volatile("swi #0x1A" : "=r"(r0) : : "r1", "r2", "r3", "memory");
    return r0;
}

/* SWI 1Bh (custom): return (x + 0x100). Proves the argument reaches the handler and comes back. */
static inline unsigned psk_swi_xform(unsigned x) {
    register unsigned r0 __asm__("r0") = x;
    __asm__ volatile("swi #0x1B" : "+r"(r0) : : "r1", "r2", "r3", "memory");
    return r0;
}
