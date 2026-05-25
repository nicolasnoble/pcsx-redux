TARGET = drawing-offset-y
TYPE = ps-exe

# Note: this build path deliberately does NOT include common/syscalls/printf.s.
# We provide our own ramsyscall_printf in ../sio1-printf.c that streams to
# SIO1 instead of going through BIOS A0:0x3F. spicyjpeg-only build for use
# with loaders that lack BIOS TTY redirection.
SRCS += \
../sio1-printf.c \
../../common/crt0/memory-s.s \
../../common/crt0/memory-c.c \
../../common/crt0/crt0.s \
drawing-offset-y.c \

include ../../common.mk
