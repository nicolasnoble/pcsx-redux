/*
 * OpenPSK SWI exception dispatch - the foundation of the PocketStation kernel ABI.
 *
 * Mechanism (mirrors the retail kernel's @0x1528 service routine, spec in psx-spx
 * docs/pocketstation.md "SWI service routine" + RAM map "0xE0 = pointer to SWI table"):
 *
 *   1. crt0 installs at WRAM 0x08 a trampoline "ldr pc,[pc,#0x18]" that loads the absolute
 *      address of swi_service (below) from WRAM 0x28, and stores &swi_table at WRAM 0xE0.
 *   2. An ARM/Thumb `swi #n` traps to the 0x08 vector in SVC mode with IRQs masked, lr_svc =
 *      return address, spsr = caller CPSR. The trampoline jumps here.
 *   3. swi_service reads the SWI comment field, indexes the table at *(0xE0), and calls the
 *      handler. r0-r3 carry arguments in and r0 carries the result out (standard SWI ABI).
 *   4. It returns with `ldmfd sp!,{...,pc}^` - the S-bit-with-r15 form that restores CPSR from
 *      SPSR as it pops the return address into PC, atomically leaving the exception.
 *
 * Two real hardware contracts the emulator must honor (both verified by running this):
 *   - the comment is fetched with a 16-bit `ldrh` (8-bit reads of most PocketStation memory
 *     return a garbage_byte; the retail routine uses ldrh for exactly this reason), and
 *   - the `ldm {...,pc}^` return performs the SPSR->CPSR restore.
 */

    .equ SWI_TABLE_PTR, 0xE0       @ WRAM word holding the dispatch table base (retail-faithful)

    .text
    .arm
    .global swi_service
swi_service:
    @ SVC mode, IRQ masked, lr = return address, spsr = caller CPSR. r0-r3 = args, r0 = result.
    stmfd   sp!, {r12, lr}         @ save a scratch reg + the exception-return address
    mrs     r12, spsr              @ caller CPSR, to test the Thumb (T) bit
    tst     r12, #0x20             @ T bit (bit 5): set => the `swi` was a Thumb halfword
    subne   r12, lr, #2            @ Thumb SWI instruction sits at lr-2
    subeq   r12, lr, #4            @ ARM   SWI instruction sits at lr-4
    ldrh    r12, [r12]             @ read the instruction's low halfword (ldrh = garbage_byte-safe)
    and     r12, r12, #0xFF        @ comment field, low 8 bits = SWI number
    mov     lr, #SWI_TABLE_PTR
    ldr     lr, [lr]               @ lr = *(0xE0) = table base
    ldr     r12, [lr, r12, lsl #2] @ r12 = table[number] = handler address
    adr     lr, swi_return         @ handlers return here via `bx lr`
    bx      r12                    @ call the handler (ARM); r0-r3 = args, r0 = result
swi_return:
    ldmfd   sp!, {r12, pc}^        @ restore r12, pop return addr into PC, CPSR <- SPSR (exception return)

    /*
     * Custom milestone SWI handlers. These prove the dispatch round-trips but are NOT part of the
     * documented PocketStation ABI, so they live at 1Ah/1Bh - clear of the documented 00h-18h range.
     * The documented SWIs (0Ch/0Dh/0Eh date-time so far) are C functions in swi_handlers.c, indexed
     * at their real numbers in the table below. They run in SVC mode and return via `bx lr`.
     */

    .global swi_handler_magic
swi_handler_magic:                 @ SWI 1Ah: return a fixed magic constant (proves a SWI dispatched)
    ldr     r0, =0xABCD1234
    bx      lr

    .global swi_handler_xform
swi_handler_xform:                 @ SWI 1Bh: return arg + 0x100 (proves arg-in/result-out round-trip
    add     r0, r0, #0x100         @          AND that the comment indexed a *different* table slot)
    bx      lr

    .global swi_handler_default
swi_handler_default:               @ unused slots: a visibly-wrong sentinel so a stray SWI is obvious
    ldr     r0, =0xDEADBEEF
    bx      lr
    .ltorg                         @ literal pool for the ldr= pseudo-ops above

    .section .rodata
    .align  2
    .global swi_table
    @ Indexed by SWI number (low 8 bits of the comment field). Names are the AUTHORITATIVE kernel
    @ spec (PDA Kernel Specification, Dev Ref 1.5, Table 3) - NOT the older reverse-engineered
    @ nocash/psx-spx names, which were wrong beyond date/time (the comms model SenseAutoCom/
    @ SetComOnOff/ComFlags is real kernel-internal behavior but NOT the public SWI numbering; the
    @ single public comms SWI is 17 "Control PlayStation communication"). Numbers are decimal in the
    @ spec; the hex label here is the same value the `swi #n` comment carries. Gaps (7, 21, 23) are
    @ not in the spec table.
swi_table:
    .word   swi_handler_default              @ 00h  0  Software reset                   (TODO)
    .word   swi_handler_default              @ 01h  1  Set user callback                (TODO)
    .word   swi_handler_default              @ 02h  2  Invoke user callback             (TODO)
    .word   swi_handler_write_flash_relative @ 03h  3  Write flash (relative sectors)
    .word   swi_handler_default              @ 04h  4  Set system clock frequency       (TODO)
    .word   swi_handler_default              @ 05h  5  Switch kernel mode               (TODO)
    .word   swi_handler_default              @ 06h  6  Get PDA status                   (TODO)
    .word   swi_handler_default              @ 07h  7  (not in spec table)
    .word   swi_handler_default              @ 08h  8  Application block number control (TODO)
    .word   swi_handler_default              @ 09h  9  Terminate/suspend application    (TODO)
    .word   swi_handler_default              @ 0Ah 10  Read serial number               (TODO)
    .word   swi_handler_default              @ 0Bh 11  Terminate file transfer w/ PS    (TODO)
    .word   swi_handler_set_bcd_date_time    @ 0Ch 12  Write real-time clock
    .word   swi_handler_get_bcd_date         @ 0Dh 13  Read calendar
    .word   swi_handler_get_bcd_time         @ 0Eh 14  Read clock
    .word   swi_handler_default              @ 0Fh 15  Write serial number              (TODO)
    .word   swi_handler_write_flash_absolute @ 10h 16  Write flash (absolute number)
    .word   swi_handler_default              @ 11h 17  Control PlayStation communication(TODO)
    .word   swi_handler_default              @ 12h 18  Get application status           (TODO)
    .word   swi_handler_default              @ 13h 19  Get user interface status        (TODO)
    .word   swi_handler_default              @ 14h 20  Get system call table            (TODO)
    .word   swi_handler_default              @ 15h 21  (not in spec table)
    .word   swi_handler_default              @ 16h 22  Get application block number     (TODO)
    .word   swi_handler_default              @ 17h 23  (not in spec table)
    .word   swi_handler_default              @ 18h 24  Get application flag             (TODO)
    .word   swi_handler_default              @ 19h 25  (unused)
    .word   swi_handler_magic                @ 1Ah custom: dispatch-proof magic constant
    .word   swi_handler_xform                @ 1Bh custom: dispatch-proof arg transform
    .word   swi_handler_default              @ 1Ch
    .word   swi_handler_default              @ 1Dh
    .word   swi_handler_default              @ 1Eh
    .word   swi_handler_default              @ 1Fh
