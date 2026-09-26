# Automated creation of a Cortex-M33 TrustZone QEMU box

An ARMv8-M system with TrustZone enabled, running on the `mps2-an505`
machine emulated by QEMU.

## Additional requirements (see root project folder)

- `curl` (only needed when `$ELF_URL` is set)
- `qemu-system-arm`

**Note:** the guest runs under TCG emulation, so this box does not need KVM
and works on any machine QEMU itself runs on.

## Project structure

```
embedded/trustzone/          # Cortex-M33 / TrustZone QEMU box
├── trustzone_box.sh         #   Main script (setup, boot)
├── .gitignore               #   Ignores the firmware
└── README.md
```

Dropping a firmware named `$ELF_NAME` in this directory is all the box needs
to have something to run; it is ignored by `.gitignore`.

`trustzone_box.sh` sources the output helpers shared by the whole
repository, which live in [../../lib/output.sh](../../lib/output.sh) — keep
that relative path in mind when copying the script somewhere else. The
presentation details (rule width, characters, wording of the messages) are
tweakable at the top of that file, and `./trustzone_box.sh -h` lists every
setting of this box along with its current value.

## Options

| Option | Effect |
|--------|--------|
| `-s`, `--setup` | Download the firmware, if any, and stop |
| `-b`, `--boot` | Download the firmware, if any, and boot (default) |
| `-d`, `--debug` | Boot with the cpu halted, waiting for gdb on port 1234 |
| `-h`, `--help` | Print the help message |

## The machine

`mps2-an505` models the IoTKit FPGA image of application note
[AN505](https://developer.arm.com/documentation/dai0505/latest/): a single
Cortex-M33 with a Secure and a Non-secure world, which makes it the usual way
of playing with TrustZone without any hardware.

QEMU builds that board on its own, which is why this box needs no download to
run.

## Quickstart

```bash
# From this directory
./trustzone_box.sh      # boots the bare machine
```

The box then does nothing at all, which is the one thing an empty board
cannot avoid: QEMU gives you the cpu, its TrustZone extensions, the SAU, the
memory map and the UART, but not the code that would use them. QEMU does not
fill the board with anything by itself either — an unwritten vector table is
zeroes, and the core lockups on them within a few instructions, which QEMU
reports as a fatal error and then aborts the whole vm:

```
qemu: fatal: Lockup: can't escalate 3 to HardFault (current priority -1)
```

So that the box stays usable with nothing to hand, it writes the smallest
firmware that keeps the board alive: twelve bytes holding an initial stack
pointer, a reset vector, and a `b .` that spins. That is what the machine
boots when there is no `$ELF_NAME` to load. Add a firmware to make the box
interesting:

```bash
cp /path/to/your/image.elf AN505_TrustZone_Demo.elf
./trustzone_box.sh      # boots it this time
```

## Firmware

**No firmware is bundled, and `$ELF_URL` is empty by default.** The
CMSIS-CoreValidation demo that the box was originally written against is not
published anymore: Arm archived
[ARM-software/CMSIS_5](https://github.com/ARM-software/CMSIS_5) and removed
the branch that hosted the prebuilt `CoreValidation.elf`, so the URL that used
to be hardcoded now returns 404. Hence the empty variable, which is there for
you to point at a mirror rather than for the box to use out of the box.

Any ARMv8-M image built for that machine will do. To get one, either:

1. **Build the CMSIS-CoreValidation demo.** The sources are still part of
   CMSIS_5, under `CMSIS/CoreValidation`, together with the board
   configuration for the AN505. They are meant to be built with
   [CMSIS-Build](https://github.com/Open-CMSIS-Pack/cmsis-toolbox), which
   supports both Arm Compiler 6 and GCC.
2. **Build a minimal image of your own** with `arm-none-eabi-gcc`. A TrustZone
   image needs a Secure and a Non-secure world, each one with its own vector
   table, and an SAU telling the core which parts of memory are reachable
   from the Non-secure world. As far as the memory map is concerned, QEMU
   boots the cpu expecting the Secure vector table at `0x10000000`, and the
   same 4 MiB of SSRAM is aliased for the Non-secure world at `0x00000000`;
   linking the Secure code in the upper half and the Non-secure one in the
   lower half is therefore the easy way in.
3. **Point `$ELF_URL` at a mirror you trust**, and leave `$ELF_SHA256` empty
   unless you know the checksum of the file being downloaded.

Either way, the file is expected to be named `$ELF_NAME` in `$WORK_DIR`, and
`-device loader,file=...` is only added to the QEMU command line when the
file is actually there.

## Notes

- **The firmware is loaded at `$LOAD_ADDR`, and that address is not a detail.**
  On reset the Secure core takes its vector table from `0x10000000`, which is
  the secure alias of the same 4 MiB of SSRAM the Non-secure world sees at
  `0x00000000`. An image linked somewhere else is not where the core looks,
  and the result is the lockup above. `mps2-an547` is the exception, with its
  vector table at `0x00000000`; changing `$MACHINE` means changing
  `$LOAD_ADDR` to match.
- **The image is loaded as an ELF** (`-device loader,file=...`), so a raw
  binary would have to be turned into an ELF first.
- **There are no credentials to log in with.** There is no operating system
  and no login: the firmware is bare metal, so whatever it prints on the
  console is all there is. For anything interactive, use `-d` and drive it
  through gdb.
- **There is no bootloader involved.** Whatever the image does after reset is
  what the terminal shows; most demo images print their results and either
  halt or loop.
- **`$MACHINE` and `$CPU` are configurable.** `mps2-an521` and
  `mps2-an524` are the dual-core variants of the same family, and
  `mps2-an547` is the Cortex-M55 one.
