/*
 * OpenPSK - card-link (COM) command engine.
 *
 * This is what makes OpenPSK a real PocketStation kernel rather than a sleep demo: its own
 * implementation of the serial card-link command engine the PlayStation drives. When the PDA is
 * docked in a PS Memory Card slot, the PS clocks SPI bytes at the device; the COM hardware raises a
 * FIQ (INT bit 6), and this engine answers - serving the standard PS1 Memory Card protocol
 * (read 0x52 / write 0x57 / get-id 0x53) in software, exactly as the retail kernel does.
 *
 * Reimplemented from the contract (KERNEL-MAP.md cluster 4/6/7 - the retail engine at 0x1058, the
 * com_exchange primitive at 0x1570, and card_read at 0x91E), NOT transliterated. The byte protocol
 * and the COM-register handshake are the parts that must match silicon; the control flow is ours.
 *
 * Model (verified by the COM-bridge work against the retail kernel):
 *   - COM_DATA is a single shift register each direction; COM_STAT2.bit0 (ready) is set when a host
 *     exchange completes and cleared when the kernel loads the next TX byte.
 *   - The whole command runs inside one FIQ invocation, busy-polling ready for each byte: the host
 *     feeds the next byte (another exchange) while the ARM core spins on ready between catch-up steps.
 *   - com_exchange(tx) loads TX, arms the link, and waits for the exchange to complete (bailing if the
 *     device is undocked or the link errors); the caller then reads COM_DATA for the received byte.
 *
 * Deferred to the next chunk (they need the application-FUNC dispatch / file directory): the PDA
 * commands 0x50 and 0x58-0x5F, including the FUNC execute handshake (0x5B/0x5C) that is the FF8
 * Chocobo World sync.
 */
#include "hardware.h"
#include "kernel_state.h"
#include "com.h"

/* One SPI byte exchange. Loads tx, arms the link (COM_MODE 1 then 3), and waits for the transfer to
 * complete. Returns 0 = ok (the received byte is now in COM_DATA), 1 = abort (undocked or link error).
 * Mirrors the retail com_exchange@0x1570; the caller reads COM_DATA afterwards for the RX byte. */
static int com_exchange(unsigned tx) {
    PSK_MMIO(COM_CTRL2) = 1;
    PSK_MMIO(COM_DATA) = tx;
    PSK_MMIO(COM_MODE) = 1;
    PSK_MMIO(COM_MODE) = 3;
    for (;;) {
        if (!(PSK_MMIO(INT_INPUT) & INT_DOCKED)) { PSK_MMIO(COM_CTRL2) = 1; return 1; }
        if (PSK_MMIO(COM_STAT1) & 2u)            { PSK_MMIO(COM_CTRL2) = 1; return 1; }
        if (PSK_MMIO(COM_STAT2) & 1u)            { PSK_MMIO(COM_CTRL2) = 1; return 0; }
    }
}

static inline unsigned com_rx(void) { return PSK_MMIO(COM_DATA) & 0xFFu; }

/* Memory Card read (command 0x52). Entered after the engine has consumed the 0x81 device-select and
 * the 0x52 command byte and sent the 0x5A 0x5D id-ack. Drives the rest of the standard protocol:
 * receive the sector address (MSB,LSB), send the command ack (0x5C 0x5D), echo the address back,
 * stream the 128 data bytes of that sector from flash while accumulating an XOR checksum, then send
 * the checksum (XORed with the address bytes) and the 0x47 'G' end byte. */
static void card_read(void) {
    if (com_exchange(0)) return;
    unsigned msb = com_rx();
    if (com_exchange(0)) return;
    unsigned lsb = com_rx();
    if (com_exchange(0x5C)) return;
    for (volatile int d = 250; d; d--) { }          /* inter-byte settle (retail busy-wait) */
    if (com_exchange(0x5D)) return;
    if (msb >= 4) { com_exchange(0xFF); com_exchange(0xFF); return; }  /* address out of range */
    if (com_exchange(msb)) return;                  /* echo the address back to the host */
    if (com_exchange(lsb)) return;
    unsigned sector = (msb << 8) | lsb;
    const unsigned char *data = (const unsigned char *)(FLASH_BASE_ABS + sector * 128u);
    unsigned chk = 0;
    for (int i = 0; i < 128; i++) {
        if (com_exchange(data[i])) return;
        chk ^= data[i];
    }
    chk ^= msb; chk ^= lsb;
    if (com_exchange(chk)) return;
    com_exchange(0x47);                             /* 'G' = good */
}

/* Memory Card write (command 0x57). Symmetric to the read: receive the sector address, ack, then
 * receive 128 data bytes into the sector buffer (verifying the running checksum the host sends), and
 * if it matches program the flash sector. Reports the standard end byte: 'G' ok / 'N' bad checksum. */
static void card_write(void) {
    if (com_exchange(0)) return;
    unsigned msb = com_rx();
    if (com_exchange(0)) return;
    unsigned lsb = com_rx();
    unsigned chk = msb ^ lsb;
    volatile unsigned char *buf = psk_ram8_p(PSK_SECTOR_BUF);
    for (int i = 0; i < 128; i++) {
        if (com_exchange(0)) return;
        unsigned b = com_rx();
        buf[i] = (unsigned char)b;
        chk ^= b;
    }
    if (com_exchange(0)) return;
    unsigned host_chk = com_rx();                   /* host's checksum byte */
    if (com_exchange(0x5C)) return;
    if (com_exchange(0x5D)) return;
    if (msb >= 4 || host_chk != chk) { com_exchange((host_chk != chk) ? 'N' : 0xFF); return; }
    /* program the sector into flash (absolute), then acknowledge */
    extern unsigned swi_handler_write_flash_absolute(unsigned dest, unsigned src);
    unsigned sector = (msb << 8) | lsb;
    unsigned ok = swi_handler_write_flash_absolute(FLASH_BASE_ABS + sector * 128u,
                                                   (unsigned)PSK_SECTOR_BUF);
    com_exchange(ok == 0 ? 0x47 : 'N');             /* 'G' ok / 'N' fail */
}

/* Memory Card get-id (command 0x53). Returns the fixed card identity / capacity descriptor that the
 * PS BIOS expects from a standard card: the 0x5C 0x5D ack followed by the card geometry bytes and
 * the 0x47 'G' end byte. */
static void card_getid(void) {
    static const unsigned char id[] = { 0x5C, 0x5D, 0x04, 0x00, 0x00, 0x80, 0x00, 0x80, 0x47 };
    for (unsigned i = 0; i < sizeof(id); i++) {
        if (com_exchange(id[i])) return;
    }
}

/* ---- FUNC execute handshake (card commands 0x5B / 0x5C) - the PS<->PDA application sync ----------
 * The PlayStation invokes a numbered function on the PDA and exchanges a data block with it. Command
 * 0x5B transfers PS<-PDA (the PDA produces data), 0x5C transfers PS->PDA (the PDA consumes data).
 * Each calls the function's handler TWICE: pre-data (set up the buffer/length) then post-data (commit),
 * distinguished by mode bit 4 (0=pre, 1=post); mode bit 2 flags a bad transfer. This is the mechanism
 * FF8 Chocobo World uses to sync.
 *
 * Functions 0x00-0x7F are kernel built-ins (descriptor table in ROM); 0x80-0xFF are an application's
 * own handlers from its file header. OpenPSK has no application loaded yet, so only the kernel
 * built-ins resolve - currently FUNC 0x00 (read date/time), which is what the PS reads to sync the
 * clock. The application-FUNC routing (0x80-0xFF) lands with the app-launch layer; the full FF8
 * sync is then validated against a real capture from the hardware in the rig. */
typedef struct { unsigned ptr; unsigned len; } func_result;

extern unsigned swi_handler_get_bcd_date(void);
extern unsigned swi_handler_get_bcd_time(void);

/* FUNC 0x00 - read date/time. Pre-data fills the sector buffer with {date:u32, time:u32} (8 bytes,
 * the same {0x368 date, 0x390 time} the retail kernel returns); post-data is a no-op. */
static func_result func00_datetime(unsigned mode) {
    func_result r = { PSK_SECTOR_BUF, 8 };
    if (mode & 4u) { r.len = 0; return r; }             /* bad transfer */
    if (!(mode & 0x10u)) {                              /* pre-data (bit4 clear): produce the data */
        PSK_RAM32(PSK_SECTOR_BUF + 0) = swi_handler_get_bcd_date();
        PSK_RAM32(PSK_SECTOR_BUF + 4) = swi_handler_get_bcd_time();
    }
    return r;
}

/* Resolve a function number to {param-byte count (LEN1), handler}. Kernel built-ins only for now. */
typedef func_result (*func_handler)(unsigned mode);
static func_handler func_lookup(unsigned func, unsigned *len1) {
    switch (func) {
        case 0x00: *len1 = 0; return func00_datetime;
        default:   *len1 = 0; return 0;                 /* 0x01-0x7F builtin / 0x80+ app: not yet */
    }
}

/* Command 0x5B - execute function, transfer data PDA->PS. Read the function number + its LEN1 param
 * bytes, run the pre-data call to get {ptr,len}, send the length byte then the data, then post-data. */
static void func_exec_to_ps(void) {
    if (com_exchange(0xFF)) return;
    unsigned func = com_rx();
    if (func >= 0x100u) return;
    unsigned len1;
    func_handler h = func_lookup(func, &len1);
    if (!h) return;
    if (com_exchange(len1)) return;                     /* send LEN1 (param count) - retail two-length framing */
    volatile unsigned char *buf = psk_ram8_p(PSK_SECTOR_BUF);
    for (unsigned i = 0; i < len1; i++) {               /* read the LEN1 parameter bytes */
        if (com_exchange(0)) return;
        buf[i] = (unsigned char)com_rx();
    }
    func_result res = h(9u);                            /* pre-data (mode 0x09) */
    if (res.len == 0) return;
    unsigned len = res.len > 0x80u ? 0x80u : res.len;
    volatile unsigned char *d = psk_ram8_p(res.ptr);
    if (com_exchange(len)) return;                      /* length byte */
    for (unsigned i = 0; i < len; i++) {
        if (com_exchange(d[i])) return;                 /* the data */
    }
    h(0x11u);                                           /* post-data (mode 0x11) */
}

/* Command 0x5C - execute function, transfer data PS->PDA. Symmetric: pre-data gives the input buffer,
 * receive the data into it, post-data commits. (No consuming built-in yet; shell in place.) */
static void func_exec_from_ps(void) {
    if (com_exchange(0xFF)) return;
    unsigned func = com_rx();
    if (func >= 0x100u) return;
    unsigned len1;
    func_handler h = func_lookup(func, &len1);
    if (!h) return;
    if (com_exchange(len1)) return;                     /* send LEN1 (param count) - retail two-length framing */
    volatile unsigned char *buf = psk_ram8_p(PSK_SECTOR_BUF);
    for (unsigned i = 0; i < len1; i++) {
        if (com_exchange(0)) return;
        buf[i] = (unsigned char)com_rx();
    }
    func_result res = h(0x0Au);                         /* pre-data (mode 0x0A) */
    if (res.len == 0) return;
    unsigned len = res.len > 0x80u ? 0x80u : res.len;
    volatile unsigned char *d = psk_ram8_p(res.ptr);
    for (unsigned i = 0; i < len; i++) {
        if (com_exchange(0)) return;
        d[i] = (unsigned char)com_rx();
    }
    h(0x12u);                                           /* post-data (mode 0x12) */
}

/* COM FIQ service body (called from fiq.S on INT bit 6). Runs one whole card command. Gated on
 * ComFlags.9 (communication possible) just like the retail engine - if the link is not enabled and
 * docked, do nothing. */
void openpsk_com_service(void) {
    if (!(psk_comflags() & PSK_CF_COMM_POSSIBLE)) return;
    PSK_MMIO(COM_CTRL2) = 1;
    PSK_MMIO(COM_CTRL1) = 3;

    /* Wait (bounded) for the first byte the FIQ was raised for. */
    int tries = 30;
    while (tries > 0) {
        if (!(PSK_MMIO(INT_INPUT) & INT_DOCKED)) return;
        if (PSK_MMIO(COM_STAT1) & 2u) { tries--; continue; }
        if (PSK_MMIO(COM_STAT2) & 1u) break;
        tries--;
    }
    if (tries == 0) return;
    PSK_MMIO(COM_CTRL2) = 1;

    if (com_rx() != 0x81) return;                   /* device-select: must address the card */
    if (com_exchange(0x08)) return;                 /* FLAG status byte (card-status); RX = the command byte */
    unsigned cmd = com_rx();

    if (cmd == 0x52 || cmd == 0x57 || cmd == 0x53) {
        if (com_exchange(0x5A)) return;             /* card id-ack bytes */
        if (com_exchange(0x5D)) return;
        psk_comflags_or(PSK_CF_CMD_IN_PROGRESS);
        if (cmd == 0x52)      card_read();
        else if (cmd == 0x57) card_write();
        else                  card_getid();
        psk_comflags_clr(PSK_CF_CMD_IN_PROGRESS);
    } else if (cmd == 0x5B || cmd == 0x5C) {        /* FUNC execute (no 5A/5D ack, handler runs directly) */
        psk_comflags_or(PSK_CF_CMD_IN_PROGRESS);
        if (cmd == 0x5B) func_exec_to_ps();
        else             func_exec_from_ps();
        psk_comflags_clr(PSK_CF_CMD_IN_PROGRESS);
    }
    /* else: other PDA commands (0x50, 0x58-0x5A, 0x5D-0x5F) - next chunk. */
}

/* Enter card-link communication mode: initialize the COM hardware, unmask the COM FIQ, and set
 * ComFlags.9 (communication possible). The retail kernel reaches this state through the docking
 * handshake (the dock IRQ sets ComFlags.8, then SWI 17 / SetComOnOff enables the link); OpenPSK
 * exposes the enable directly here for now - the docking state machine that drives it is the next
 * chunk. After this the caller must have FIQs enabled at the CPU (psk_enable_fiq). */
void openpsk_comm_enable(void) {
    PSK_MMIO(COM_MODE) = 2;
    PSK_MMIO(COM_CTRL1) = 0;
    PSK_MMIO(COM_CTRL2) = 3;
    PSK_MMIO(COM_DATA) = 0xFF;
    PSK_MMIO(INT_MASK_SET) = INT_COM;               /* enable the COM FIQ (bit 6) */
    psk_comflags_or(PSK_CF_COMM_POSSIBLE);
}
