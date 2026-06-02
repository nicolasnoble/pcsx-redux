# OpenPSK - minimal open-source PocketStation kernel (the src/arm analog of src/mips/openbios).
#
# Builds a 16 KiB ROM image that boots from the ARM7 reset vector and draws to the LCD. Loaded
# into the emulator via PCSX::PocketStation::setKernel() in place of the retail kernel.bin.
#
# Kept out of the host Redux build by EXTENSION: this tree uses .c/.S only, and the host Makefile
# discovers sources via rwildcard(src/,*.cc). Build standalone with `make -C src/arm/openpsk`.

PREFIX  ?= arm-none-eabi
CC       = $(PREFIX)-gcc
OBJCOPY  = $(PREFIX)-objcopy

TARGET   = openpsk
ROMSIZE  = 16384

ARCHFLAGS = -march=armv4t -marm
CFLAGS    = $(ARCHFLAGS) -ffreestanding -nostdlib -fno-builtin -Os -Wall -Wextra -std=c11 \
            -fomit-frame-pointer
LDFLAGS   = $(ARCHFLAGS) -nostdlib -T openpsk.ld -Wl,--build-id=none

OBJS = crt0.o swi.o irq.o swi_handlers.o main.o

all: $(TARGET).bin

crt0.o: crt0.S
	$(CC) $(ARCHFLAGS) -c $< -o $@

swi.o: swi.S
	$(CC) $(ARCHFLAGS) -c $< -o $@

irq.o: irq.S
	$(CC) $(ARCHFLAGS) -c $< -o $@

swi_handlers.o: swi_handlers.c hardware.h
	$(CC) $(CFLAGS) -c $< -o $@

main.o: main.c hardware.h swi.h
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET).elf: $(OBJS) openpsk.ld
	$(CC) $(LDFLAGS) $(OBJS) -o $@

# Raw binary, padded/truncated to exactly 16 KiB (the PocketStation kernel ROM size).
$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@
	truncate -s $(ROMSIZE) $@
	@echo "openpsk.bin: $$(stat -c%s $@) bytes (ROM = $(ROMSIZE))"

clean:
	rm -f $(OBJS) $(TARGET).elf $(TARGET).bin

.PHONY: all clean
