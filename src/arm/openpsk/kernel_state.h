/*
 * OpenPSK - kernel state model (the WRAM system area, 0x00..0x200).
 *
 * The PocketStation kernel keeps its live state at FIXED low-WRAM addresses. These are not an
 * implementation detail we are free to move: PocketStation applications and the card-link command
 * engine reach into this region by absolute address (ComFlags at 0xC0, the syscall-table pointer at
 * 0xE0, the callback slots at 0xF8, ...), so the layout is ABI. OpenPSK reimplements the kernel from
 * the documented + reverse-engineered contract, but must preserve these addresses so retail apps and
 * a real PlayStation see the same memory the retail kernel exposed.
 *
 * Layout reconstructed from the retail kernel disassembly (KERNEL-MAP.md) and cross-checked against
 * psx-spx docs/pocketstation.md "Kernel RAM" + the PDA Kernel Specification:
 *
 *   0x00  exception vector opcodes (installed by crt0)
 *   0x20  exception vector target addresses
 *   0x40  sector / transfer buffer (128 bytes, used by the card-read/write + FUNC paths)
 *   0xC0  ComFlags (u32)            - communication / UI state bitfield (see PSK_CF_* below)
 *   0xC8  kernel status struct      - SWI 6 (Get PDA status) / SWI 23 return a pointer here
 *   0xCA  func-value byte           - PS_ChangeFuncValue (card cmd 0x50) stores its byte here
 *   0xCE  selection byte            - SWI 21 get/set, gated on the active application block number
 *   0xCF  RTC century byte          - the 2-digit-century the RTC hardware does not store
 *   0xD2  active application block#  (u16) - SWI 8 set / SWI 22 get
 *   0xD4  application argument       (u32) - SWI 8
 *   0xD8  user-interface status struct - SWI 19 returns a pointer here
 *   0xE0  pointer to the SWI dispatch table (= &swi_table); installed by crt0
 *   0xF0  COM TX-reply byte / 0xF1 COM countdown byte - the card-link engine's handshake registers
 *   0xF8  4 user-callback addresses (software / IRQ / FIQ / PS-transfer) - SWI 1; see hardware.h
 */
#pragma once

/* WRAM lives at 0x00..0x800, so the kernel legitimately dereferences very low addresses. -Warray-
 * bounds (under -Wextra) flags a literal small-integer dereference as a likely null-pointer bug,
 * which is a false positive here. Launder the address through an opaque inline accessor so the
 * provenance is a function return, not a constant - keeps -Wextra fully on without a near-zero warning. */
static inline volatile unsigned char  *psk_ram8_p (unsigned a) { __asm__("":"+r"(a)); return (volatile unsigned char  *)a; }
static inline volatile unsigned short *psk_ram16_p(unsigned a) { __asm__("":"+r"(a)); return (volatile unsigned short *)a; }
static inline volatile unsigned int   *psk_ram32_p(unsigned a) { __asm__("":"+r"(a)); return (volatile unsigned int   *)a; }
#define PSK_RAM8(addr)  (*psk_ram8_p(addr))
#define PSK_RAM16(addr) (*psk_ram16_p(addr))
#define PSK_RAM32(addr) (*psk_ram32_p(addr))

/* Fixed kernel-state addresses (WRAM system area). */
#define PSK_SECTOR_BUF   0x40u  /* 128-byte transfer buffer */
#define PSK_COMFLAGS     0xC0u  /* u32 */
#define PSK_STATUS_STRUCT 0xC8u /* SWI 6 / 23 return this pointer */
#define PSK_FUNCVAL_BYTE 0xCAu  /* PS_ChangeFuncValue target */
#define PSK_SELECT_BYTE  0xCEu  /* SWI 21 get/set */
#define PSK_CENTURY_BYTE 0xCFu  /* RTC century (BCD), e.g. 0x20 */
#define PSK_APP_BLOCK    0xD2u  /* u16 active app block number */
#define PSK_APP_ARG      0xD4u  /* u32 app argument */
#define PSK_UI_STRUCT    0xD8u  /* SWI 19 returns this pointer */
#define PSK_SWI_TABLE_PTR 0xE0u /* word holding &swi_table */
#define PSK_COM_TX_BYTE  0xF0u  /* card-link TX-reply byte */
#define PSK_COM_CNT_BYTE 0xF1u  /* card-link countdown byte */

/* ComFlags bits (PDA Kernel Spec "ComFlags", lines 707-714, + reverse-engineered internal bits).
 * The low documented bits are the application/PS-facing flags; bits 16-18 and 28-30 are kernel
 * internal state the command engine and IRQ paths maintain. */
#define PSK_CF_FLASH_WRITE_EN (1u << 0)  /* flash-write enabled */
#define PSK_CF_SPEAKER        (1u << 1)  /* speaker on */
#define PSK_CF_LED            (1u << 2)  /* LED on */
#define PSK_CF_IR_TRANSMIT    (1u << 3)  /* IR transmit */
#define PSK_CF_INSERTED       (1u << 8)  /* inserted into / removed from the PS (docking edge) */
#define PSK_CF_COMM_POSSIBLE  (1u << 9)  /* communication with the PS is possible (docked + enabled) */
#define PSK_CF_FILE_TRANSFER  (1u << 10) /* file-transfer in progress */
#define PSK_CF_APP_EXITED     (1u << 11) /* the PDA application has exited */
/* Kernel-internal (reverse-engineered from the retail command engine / SWIs): */
#define PSK_CF_INTERNAL_16_18 (7u << 16) /* SWI 7 read-modify-writes these three bits */
#define PSK_CF_FILE_XFER_BIT18 (1u << 18) /* SWI 11 (terminate file transfer) clears this */
#define PSK_CF_CMD_IN_PROGRESS (1u << 28) /* a card command is mid-flight */
#define PSK_CF_SET_CLOCK      (1u << 29) /* PS requested a clock-set: tail does write-RTC from buf */
#define PSK_CF_RESTART_MAIN   (1u << 30) /* app exited: FIQ tail tears down and re-enters main */

/* Typed accessors for the live kernel state. */
static inline unsigned psk_comflags(void)            { return PSK_RAM32(PSK_COMFLAGS); }
static inline void     psk_comflags_set(unsigned v)  { PSK_RAM32(PSK_COMFLAGS) = v; }
static inline void     psk_comflags_or(unsigned m)   { PSK_RAM32(PSK_COMFLAGS) |= m; }
static inline void     psk_comflags_clr(unsigned m)  { PSK_RAM32(PSK_COMFLAGS) &= ~m; }
