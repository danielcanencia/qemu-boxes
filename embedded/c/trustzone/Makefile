# Build the dual-world TrustZone image with arm-none-eabi-gcc
CROSS_COMPILE ?= arm-none-eabi-
CC      = $(CROSS_COMPILE)gcc
OBJCOPY = $(CROSS_COMPILE)objcopy
SIZE    = $(CROSS_COMPILE)size

# Whether the Secure world hands the core over to the Non-secure one, 1 or 0.
# The box sets this from its --handover option, and 0 is the normal boot: the
# Secure world starts, does its own work, and stays put. Only with the
# handover on does it branch into the Non-secure world with a BLXNS.
#
# main.o is named after this rather than just "main.o" on purpose, and the
# link below is always redone. Make compares timestamps, and a setting that
# has been changed has no timestamp to compare: naming the object after the
# setting keeps the two builds apart, and relinking every time covers the
# step from one to the other. Only the link is repeated, the compile is
# still cached. Without this, turning the handover off after having built it
# with the handover on would leave the dual-world image in place and quietly
# boot the wrong one.
HANDOVER ?= 0

CFLAGS  = -mcpu=cortex-m33 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard
CFLAGS += -ffreestanding -nostdlib -Wall -Wextra -O2
CFLAGS += -Tlinker.x -DWITH_HANDOVER=$(HANDOVER)

all: AN505_TrustZone_Demo.elf

AN505_TrustZone_Demo.elf: FORCE main-$(HANDOVER).o world_switch.o
	$(CC) $(CFLAGS) -o $@ main-$(HANDOVER).o world_switch.o
	$(SIZE) $@

main-$(HANDOVER).o: main.c
	$(CC) $(CFLAGS) -c -o $@ $<

world_switch.o: world_switch.s
	$(CC) $(CFLAGS) -c -o $@ $<

# Prerequisite of the image that is never up to date, so that the link runs
# every time. A phony target with no recipe and no file.
FORCE:

clean:
	rm -f *.o AN505_TrustZone_Demo.elf

.PHONY: all clean FORCE
