/*
 * OpenPSK - card-link (COM) command engine interface.
 */
#pragma once

/* COM FIQ service body - runs one whole card command. Called from fiq.S on INT bit 6. */
void openpsk_com_service(void);

/* Enter card-link communication mode (init COM hardware, unmask COM FIQ, set ComFlags.9). The caller
 * must also enable FIQs at the CPU (psk_enable_fiq) for the engine to be reached. */
void openpsk_comm_enable(void);
