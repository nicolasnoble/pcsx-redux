/*
 * OpenPSK SWI handlers (C side). These run in SVC mode, reached from the swi.S dispatcher via
 * `bx`, with arguments in r0-r3 and the result in r0 (standard SWI ABI). A C function is a valid
 * handler: AAPCS keeps args/result in r0-r3 and returns to the dispatcher's swi_return via lr, and
 * crt0 set the SVC stack (sp=0x180) so nested calls work.
 *
 * These are the first DOCUMENTED PocketStation SWIs (numbers from psx-spx docs/pocketstation.md):
 *   0Ch SetBcdDateTime(date,time)   0Dh GetBcdDate()   0Eh GetBcdTime()
 * The custom milestone SWIs (magic/xform) moved out of the way to 1Ah/1Bh so the documented
 * numbers sit at their real values.
 */
#include "hardware.h"

/* The century is NOT in RTC_DATE (psx-spx: bits 24-31 are "Unknown? this is NOT used as century").
 * On real hardware it lives in battery-backed kernel RAM. OpenPSK doesn't model that store yet, so
 * GetBcdDate() synthesises a fixed 20th-of-2000s century. TODO: back this with kernel RAM. */
#define PSK_RTC_CENTURY 0x20u

/* SWI 0Eh - GetBcdTime(): seconds/minutes/hours/day-of-week, straight from RTC_TIME. */
unsigned swi_handler_get_bcd_time(void) {
    return PSK_MMIO(RTC_TIME);
}

/* SWI 0Dh - GetBcdDate(): day/month from RTC_DATE; the 4-digit year (bits 16-31) is RTC_DATE's
 * 2-digit year combined with the century byte (here a constant, see above). */
unsigned swi_handler_get_bcd_date(void) {
    return (PSK_MMIO(RTC_DATE) & 0x00FFFFFFu) | (PSK_RTC_CENTURY << 24);
}

/* Read the current BCD value of one RTC field (an RTC_FIELD_* selector) out of RTC_TIME/RTC_DATE. */
static unsigned rtc_read_field(int field) {
    unsigned time = PSK_MMIO(RTC_TIME);
    unsigned date = PSK_MMIO(RTC_DATE);
    switch (field) {
        case RTC_FIELD_SECOND: return  time        & 0xFFu;
        case RTC_FIELD_MINUTE: return (time >>  8) & 0xFFu;
        case RTC_FIELD_HOUR:   return (time >> 16) & 0xFFu;
        case RTC_FIELD_DOW:    return (time >> 24) & 0xFFu;
        case RTC_FIELD_DAY:    return  date        & 0xFFu;
        case RTC_FIELD_MONTH:  return (date >>  8) & 0xFFu;
        case RTC_FIELD_YEAR:   return (date >> 16) & 0xFFu;
        default:               return 0;
    }
}

/* Set one RTC field to a target BCD value the only way the hardware allows: select it via RTC_MODE
 * (with the RTC paused), then write RTC_ADJUST - which increments the selected field by one - until
 * a read-back matches. The read-back gate makes this robust to the emulator's current RTC_ADJUST
 * model (it drops every other write); on silicon the same loop converges at one write per
 * increment. The bound stops a runaway if a target is outside the field's wrap range.
 *
 * TODO: psx-spx says one must wait for the RTC IRQ (INT_INPUT.9) to fall before each RTC_ADJUST
 * write. The emulator doesn't enforce it yet, so we don't poll it - confirm the real handshake
 * against silicon. */
static void rtc_set_field(int field, unsigned target) {
    PSK_MMIO(RTC_MODE) = (unsigned)((field << 1) | 1);  /* select field, pause (bit0=1) */
    target &= 0xFFu;
    for (int guard = 0; guard < 512; guard++) {
        if (rtc_read_field(field) == target) return;
        PSK_MMIO(RTC_ADJUST) = 1;  /* the written value is ignored; the write itself increments */
    }
}

/* SWI 0Ch - SetBcdDateTime(date, time): date/time use the SWI 0Dh / 0Eh formats. Sets every field
 * through the RTC_MODE/RTC_ADJUST path with the RTC paused, then resumes the 1 Hz run. The return
 * is documented as garbage (r0 = RTC_DATE/10000h); we hand that back. */
unsigned swi_handler_set_bcd_date_time(unsigned date, unsigned time) {
    rtc_set_field(RTC_FIELD_SECOND, time);
    rtc_set_field(RTC_FIELD_MINUTE, time >> 8);
    rtc_set_field(RTC_FIELD_HOUR,   time >> 16);
    rtc_set_field(RTC_FIELD_DOW,    time >> 24);
    rtc_set_field(RTC_FIELD_DAY,    date);
    rtc_set_field(RTC_FIELD_MONTH,  date >> 8);
    rtc_set_field(RTC_FIELD_YEAR,   date >> 16);
    PSK_MMIO(RTC_MODE) = 0;  /* resume Run / 1 Hz, field selector back to 0 */
    return PSK_MMIO(RTC_DATE) >> 16;
}
