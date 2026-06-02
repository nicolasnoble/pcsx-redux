/*
 * OpenPSK crt0 - ARM7TDMI reset/startup for the open-source PocketStation kernel.
 *
 * Mirrors the retail PocketStation kernel boot (reverse-engineered in the project notes;
 * spec in psx-spx docs/pocketstation.md, memory map ~256-340). Sequence:
 *
 *   1. Reset begins executing at physical address 0, where the 16 KiB ROM is shadow-mapped.
 *      The first instruction jumps into ROM address space (0x04000000) so we stop depending
 *      on the address-0 shadow before we replace it.
 *   2. Byte-write 3 to F_CTRL (0x06000000) to swap the 2 KiB WRAM in over that shadow.
 *      Must be a *byte* store: the emulator only remaps WRAM on an 8-bit write of 3, exactly
 *      as the retail kernel does (mov r0,#3 / strb r0,[r6]).
 *   3. Set up the per-mode stacks in WRAM (FIQ top 0x200, IRQ/SVC top 0x180), then run main
 *      in System mode with the user stack at the top of WRAM (0x800). Interrupts stay masked
 *      for this first boot+draw milestone.
 *   4. Copy .data ROM->RAM and zero .bss, then call main(). main() does not return.
 */

    .section .text.reset, "ax"
    .arm
    .global _reset
_reset:
    ldr     pc, =_start            @ leave the address-0 shadow, run from ROM (0x04000000)
    .ltorg

    .text
    .arm
    .global _start
_start:
    /* Map the 2 KiB WRAM (0x0000..0x0800) over the boot shadow. Byte store of 3 to F_CTRL. */
    mov     r0, #3
    mov     r1, #0x06000000        @ F_CTRL
    strb    r0, [r1]

    /*
     * Install the SWI exception vector + dispatch-table pointer in WRAM (retail-faithful layout).
     *   0x08 = SWI vector opcode "ldr pc,[pc,#0x18]" -> loads the absolute service-routine
     *          address from 0x28 (when it executes, PC = 0x08+8, so [PC,#0x18] = [0x28]).
     *          A direct branch can't reach the ROM service routine at 0x040000xx from low WRAM,
     *          so the retail kernel uses this same load-PC-from-a-literal vectoring.
     *   0x28 = absolute address of swi_service (the literal the trampoline loads).
     *   0xE0 = pointer to the SWI dispatch table (the slot the retail kernel uses; the service
     *          routine indexes *(0xE0) by the 8-bit SWI comment).
     */
    ldr     r0, =0xE59FF018        @ opcode: ldr pc,[pc,#0x18]
    mov     r1, #0x08
    str     r0, [r1]               @ WRAM[0x08] = SWI vector trampoline
    ldr     r0, =swi_service
    str     r0, [r1, #0x20]        @ WRAM[0x28] = &swi_service
    ldr     r0, =swi_table
    mov     r1, #0xE0
    str     r0, [r1]               @ WRAM[0xE0] = &swi_table

    /* Per-mode stacks in WRAM (mirror the retail boot). CPSR control byte: mode + I/F bits. */
    msr     cpsr_c, #0xD1          @ FIQ  mode, IRQ+FIQ disabled
    ldr     sp, =0x200
    msr     cpsr_c, #0xD2          @ IRQ  mode, IRQ+FIQ disabled
    ldr     sp, =0x180
    msr     cpsr_c, #0xD3          @ SVC  mode, IRQ+FIQ disabled
    ldr     sp, =0x180
    msr     cpsr_c, #0xDF          @ System mode, IRQ+FIQ disabled (main runs here)
    ldr     sp, =0x800             @ top of 2 KiB WRAM

    /* Copy initialized data from ROM to RAM (empty for now; kept so the SDK can grow). */
    ldr     r0, =__data_load
    ldr     r1, =__data_start
    ldr     r2, =__data_end
1:  cmp     r1, r2
    ldrlo   r3, [r0], #4
    strlo   r3, [r1], #4
    blo     1b

    /* Zero the .bss segment. */
    ldr     r0, =__bss_start
    ldr     r1, =__bss_end
    mov     r2, #0
2:  cmp     r0, r1
    strlo   r2, [r0], #4
    blo     2b

    bl      main
hang:
    b       hang
    .ltorg
