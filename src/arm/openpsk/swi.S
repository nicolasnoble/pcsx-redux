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
     * Milestone SWI handlers. These are deliberately CUSTOM (not the documented 00h-18h ABI yet):
     * just enough to prove the dispatch round-trips. They run in SVC mode and return via `bx lr`.
     * The documented PocketStation SWI table grows here as OpenPSK and the emulator co-evolve.
     */

    .global swi_handler_magic
swi_handler_magic:                 @ SWI #0: return a fixed magic constant (proves a SWI dispatched)
    ldr     r0, =0xABCD1234
    bx      lr

    .global swi_handler_xform
swi_handler_xform:                 @ SWI #1: return arg + 0x100 (proves arg-in/result-out round-trip
    add     r0, r0, #0x100         @         AND that comment 1 indexed a *different* table slot)
    bx      lr

swi_handler_default:               @ unused slots: a visibly-wrong sentinel so a stray SWI is obvious
    ldr     r0, =0xDEADBEEF
    bx      lr
    .ltorg                         @ literal pool for the ldr= pseudo-ops above

    .section .rodata
    .align  2
    .global swi_table
swi_table:                         @ indexed by SWI number; 8 slots, only 0/1 are live for now
    .word   swi_handler_magic      @ 0
    .word   swi_handler_xform      @ 1
    .word   swi_handler_default    @ 2
    .word   swi_handler_default    @ 3
    .word   swi_handler_default    @ 4
    .word   swi_handler_default    @ 5
    .word   swi_handler_default    @ 6
    .word   swi_handler_default    @ 7
