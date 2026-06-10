/*
 * OpenPSK FIQ exception handler - the card-link (COM) interrupt veneer.
 *
 * The only FIQ source on the PocketStation is the serial COM/SPI controller (INT bit 6), raised when
 * the docked PlayStation clocks a card-link byte. The retail kernel's FIQ dispatch (@0x14D4) checks
 * that bit and runs the command engine; this is the open reimplementation.
 *
 *   - On FIQ entry the core is in FIQ mode with IRQ+FIQ masked, lr_fiq = resume_address + 4, spsr =
 *     the interrupted CPSR. r8-r14 are FIQ-banked, so the interrupted r8-r12 are safe; only the
 *     shared r0-r3 (and lr) need saving across the C engine call.
 *   - It confirms INT bit 6 is the pending+enabled source, then calls openpsk_com_service (com.c),
 *     which runs the whole card command (busy-polling COM ready between host exchanges).
 *   - Return is the `ldm {...,pc}^` form that restores CPSR from SPSR (the S-bit-with-r15 variant the
 *     core implements; `subs pc,lr,#4` is not usable - see irq.S).
 *
 * crt0 installs at WRAM 0x1C a trampoline "ldr pc,[pc,#0x18]" that loads &fiq_service from 0x3C.
 */

    .equ INT_LATCH,     0x0A000000     @ latched interrupt requests
    .equ INT_MASK_READ, 0x0A000008     @ interrupt enable mask
    .equ INT_COM_BIT,   0x40           @ bit 6 = COM/SPI FIQ

    .text
    .arm
    .global fiq_service
fiq_service:
    sub     lr, lr, #4                 @ FIQ link reg points 4 past resume; correct it
    stmfd   sp!, {r0, r1, r2, r3, r12, lr}  @ save the shared scratch regs + return address
    ldr     r0, =INT_LATCH
    ldr     r1, [r0]                   @ latched requests
    ldr     r0, =INT_MASK_READ
    ldr     r0, [r0]
    and     r1, r1, r0                 @ pending & enabled
    tst     r1, #INT_COM_BIT           @ is it the COM/SPI FIQ?
    beq     1f
    bl      openpsk_com_service        @ run the card command (C engine)
1:  ldmfd   sp!, {r0, r1, r2, r3, r12, pc}^  @ restore, pop resume into PC, CPSR <- SPSR
    .ltorg
