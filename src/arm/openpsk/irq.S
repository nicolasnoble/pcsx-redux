/*
 * OpenPSK IRQ exception handler - the wake path for CLK_STOP sleep.
 *
 * The PocketStation idles by writing CLK_STOP (sleep mode), which stops the CPU clock until an
 * interrupt occurs (psx-spx docs/pocketstation.md "0B000004h - CLK_STOP"). The 1 Hz RTC square
 * wave (INT_INPUT.9), the Fire button (IRQ-0) and Docking (IRQ-11) are the usual wake sources.
 * For this milestone we wake on the RTC tick: the device sleeps, the 1 Hz edge fires IRQ-9, the
 * core resumes, this handler acknowledges the request, and the main loop redraws + sleeps again.
 *
 * crt0 installs at WRAM 0x18 a trampoline "ldr pc,[pc,#0x18]" that loads &irq_service from 0x38.
 * On IRQ entry the core is in IRQ mode with IRQs masked, lr_irq = resume_address + 4, and spsr =
 * the interrupted CPSR. We adjust lr, save the scratch registers we touch, acknowledge the
 * interrupt, and return with the `ldm {...,pc}^` form (the S-bit-with-r15 variant the core
 * implements; note `subs pc, lr, #4` is NOT usable here - the fake-pipeline core panics on a data-
 * processing write to r15 with the S bit set).
 */

    .equ INT_ACK,  0x0A000010      @ write 1-bits to acknowledge (clear) the matching IRQ requests
    .equ WAKE_BITS, 0x200          @ bit 9 = RTC square wave (the wake source for this milestone)

    .text
    .arm
    .global irq_service
irq_service:
    sub     lr, lr, #4             @ IRQ link reg points 4 past the resume address; correct it.
    stmfd   sp!, {r0, r1, lr}      @ IRQ stack (sp=0x180): save scratch + the exception-return addr
    ldr     r1, =INT_ACK
    mov     r0, #WAKE_BITS
    str     r0, [r1]              @ acknowledge the RTC request so it doesn't immediately re-fire
    ldmfd   sp!, {r0, r1, pc}^     @ restore, pop resume addr into PC, CPSR <- SPSR (exception return)
    .ltorg
