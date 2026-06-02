/*
 * OpenPSK linker script. Code/rodata live in the 16 KiB ROM at 0x04000000 (the PocketStation
 * kernel ROM, also shadow-mapped at address 0 on reset). Data/bss/stacks live in the 2 KiB
 * WRAM at 0x00000000..0x00000800. The reset vector (.text.reset) is forced first so image
 * offset 0 is the instruction the ARM7 executes out of reset.
 */

OUTPUT_FORMAT("elf32-littlearm")
OUTPUT_ARCH(arm)
ENTRY(_reset)

MEMORY {
    ROM (rx)  : ORIGIN = 0x04000000, LENGTH = 16K
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 2K
}

SECTIONS {
    .text 0x04000000 : {
        KEEP(*(.text.reset))
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > ROM

    /* Initialized data: stored in ROM, copied to RAM by crt0. Empty for now, kept for growth. */
    .data : {
        . = ALIGN(4);
        __data_start = .;
        *(.data*)
        . = ALIGN(4);
        __data_end = .;
    } > RAM AT > ROM
    __data_load = LOADADDR(.data);

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.note*) }
}
