/*
 * OpenPSK - kernel syscall handlers, batch 2 (the status/serial/app-state SWIs).
 *
 * These complete the documented PocketStation system-call surface (PDA Kernel Spec, Table 3) beyond
 * the callback / RTC / flash / clock handlers in swi_handlers.c. They run in SVC mode, reached from
 * the swi.S dispatcher via `bx`, args in r0-r3, result in r0.
 *
 * Each is written from the contract - the kernel-spec signature plus the behaviour recovered from
 * the retail kernel disassembly (KERNEL-MAP.md) - NOT transliterated from the assembly. Where the
 * retail kernel reaches a fixed WRAM address, we use the kernel-state model (kernel_state.h) so the
 * ABI those addresses form stays compatible with real applications and a real PlayStation.
 *
 * Deferred to the COM-engine chunk (they drive the comm-enable/disable + app-launch machinery that
 * is not yet implemented): SWI 5 (Switch kernel mode), 9 (Terminate/suspend app), 17 (Control PS
 * communication), 18 (Get application status).
 */
#include "hardware.h"
#include "kernel_state.h"

/* SWI 6 - Get PDA status (Table 3 #6). Returns a pointer to the kernel status block. The retail
 * kernel returns &ComFlags (0xC0); callers read the communication/UI flags through it. */
unsigned swi_handler_get_pda_status(void) {
    return PSK_COMFLAGS;
}

/* SWI 7 - (undocumented; absent from the public Table 3 but implemented in the retail kernel).
 * Read-modify-write of ComFlags bits 16-18 from r0: ComFlags = (ComFlags & ~0x70000)|(r0 & 0x70000).
 * These are kernel-internal UI/communication state bits. Returns nothing meaningful (r0 unspecified). */
unsigned swi_handler_set_comflags_internal(unsigned bits) {
    unsigned cf = psk_comflags();
    cf = (cf & ~PSK_CF_INTERNAL_16_18) | (bits & PSK_CF_INTERNAL_16_18);
    psk_comflags_set(cf);
    return cf;
}

/* SWI 8 - Application block number control (Table 3 #8). r0 = get/set spec (1 = set), r1 = block
 * number, r2 = app argument. On set, stores the active block number + argument; always returns the
 * current block number. (The retail kernel validates the block against the installed-app table on
 * set; that validation needs the app-launch layer, so OpenPSK accepts the value for now - TODO.) */
unsigned swi_handler_app_block_control(unsigned spec, unsigned block, unsigned arg) {
    if (spec == 1) {
        PSK_RAM16(PSK_APP_BLOCK) = (unsigned short)block;
        PSK_RAM32(PSK_APP_ARG) = arg;
    }
    return PSK_RAM16(PSK_APP_BLOCK);
}

/* SWI 10 - Read serial number (Table 3 #10). The 32-bit factory serial is (F_SN_HI << 16)|F_SN_LO. */
unsigned swi_handler_read_serial(void) {
    return ((unsigned)PSK_MMIO16(F_SN_HI) << 16) | (unsigned)PSK_MMIO16(F_SN_LO);
}

/* SWI 11 - Terminate file transfer with the PlayStation (Table 3 #11). Clears the internal
 * file-transfer flag (ComFlags bit 18) that the FUNC/BU transfer path sets. */
unsigned swi_handler_terminate_file_transfer(void) {
    psk_comflags_clr(PSK_CF_FILE_XFER_BIT18);
    return 0;
}

/* SWI 15 - Write serial number (Table 3 #15). LOCKED OUT. The retail kernel implements this as a
 * permanent hang (the body is nothing but self-branches): the factory serial cannot be rewritten in
 * production. OpenPSK refuses cleanly instead of bricking the device, returning failure. */
unsigned swi_handler_write_serial(unsigned serial) {
    (void)serial;
    return 1;  /* refuse: the factory serial is read-only (retail hangs here; we decline) */
}

/* SWI 19 - Get user-interface status (Table 3 #19). Returns a pointer to the UI status struct. */
unsigned swi_handler_get_ui_status(void) {
    return PSK_UI_STRUCT;
}

/* SWI 20 - Get system call table (Table 3 #20). Returns the address of the word that holds the
 * dispatch-table pointer (0xE0), not the table itself - matching the retail kernel and letting a
 * caller both read and (in principle) hook the table base. */
unsigned swi_handler_get_syscall_table(void) {
    return PSK_SWI_TABLE_PTR;
}

/* SWI 21 - (undocumented; absent from Table 3). Get/set a selection byte (WRAM 0xCE) gated on the
 * active application block number. r0 = 1 sets: store r1 only if it matches the current app block#
 * (the retail kernel validates via the SWI 22 handler); always returns the current 0xCE byte. */
unsigned swi_handler_gated_select_byte(unsigned spec, unsigned value) {
    if (spec == 1 && (value & 0xFFu) == PSK_RAM16(PSK_APP_BLOCK)) {
        PSK_RAM8(PSK_SELECT_BYTE) = (unsigned char)value;
    }
    return PSK_RAM8(PSK_SELECT_BYTE);
}

/* SWI 22 - Get application block number (Table 3 #22). Returns the active application's block#. */
unsigned swi_handler_get_app_block(void) {
    return PSK_RAM16(PSK_APP_BLOCK);
}

/* SWI 23 - (undocumented; absent from Table 3). Returns a pointer to the kernel status struct at
 * 0xC8 (a sibling accessor to SWI 6's 0xC0 / SWI 19's 0xD8). */
unsigned swi_handler_get_status_ptr(void) {
    return PSK_STATUS_STRUCT;
}

/* SWI 24 - Get application flag (Table 3 #24). r0 = program number (1..15) -> that program's PDA
 * flag byte. The retail kernel indexes a per-program table (128 bytes/entry) populated as apps are
 * installed in flash. OpenPSK has no installed-app table yet, so it reports 0 (no app) - TODO once
 * the app-launch / flash-directory layer exists. */
unsigned swi_handler_get_app_flag(unsigned program) {
    (void)program;
    return 0;
}
