# A Cortex-M33 TrustZone QEMU box for C firmware development

An ARMv8-M system with TrustZone enabled, running on the `mps2-an505`
machine emulated by QEMU, set up to build and run a dual-world bare-metal
image written in C.

## What this box does

1. Builds a TrustZone image from the C sources in this directory.
2. Boots the guest with that image loaded.

There is nothing to download: QEMU builds the board itself, and the firmware
is built from the sources here.

## Additional requirements (see root project folder)

- `qemu-system-arm`
- `arm-none-eabi-gcc` (cross compiler)
- `make`

## Project structure

```
embedded/c/trustzone/          # Cortex-M33 / TrustZone QEMU box (C)
├── trustzone_box.sh           #   Main script (setup, build, boot)
├── Makefile                   #   Builds the image with arm-none-eabi-gcc
├── linker.x                   #   Secure and Non-secure memory regions
├── world_switch.s             #   The SAU setup and the world switch
├── main.c                     #   The two worlds — your code here
├── .gitignore
└── README.md
```

## Options

`--handover` is a modifier rather than an action, so it comes before the
option it modifies. Only the first option is taken into account.

| Option | Effect |
|--------|--------|
| `--handover` | Hand the core over to the Non-secure world (off by default) |
| `build` | Compile the firmware and stop |
| `-s`, `--setup` | Prepare the box and stop |
| `-b`, `--boot` | Build and boot (default) |
| `-d`, `--debug` | Boot with the cpu halted, waiting for gdb on port 1234 |
| `-h`, `--help` | Print the help message |

## The image

The board has 4 MiB of SSRAM that can be reached through two aliases: the
Secure world sees it at `0x10000000`, and the Non-secure world sees the very
same memory at `0x00000000`. The core resets with its vector table at the
Secure alias, which is where the box loads the image.

The two worlds are therefore just two addresses into one piece of memory,
and the Security Attribution Unit is what tells them apart:

- `world_switch.s` programs the SAU to give the Non-secure world the 2 MiB
  at the Non-secure alias (`0x00100000` through `0x001FFFFF`), and keeps the
  rest Secure.
- The Secure world runs first, in `secure_main()`. It is the only one that
  may program the SAU, and it is where keys and other secrets belong.
- When it is done, it calls `switch_to_nonsecure()`, which is assembly
  because the exchange needs `BLXNS` — the only instruction that can leave
  the Secure state.
- The Non-secure world then runs in `nonsecure_main()`, and can only reach
  the region the SAU was told about.

A normal boot stops short of that: `secure_main()` starts, the SAU is
programmed, and the core stays in the Secure world. The handover is the branch
into the Non-secure one, and it is off unless you ask for it:

```
./trustzone_box.sh                  # normal boot: stays in the Secure world
./trustzone_box.sh --handover       # dual-world: hands over to the Non-secure one
```

It is compiled in rather than chosen at run time, since the branch out of the
Secure state is either in the image or it is not, so the firmware is rebuilt
when you turn it on or off. `make` cannot see that a setting changed — it
only compares timestamps, and a setting has none — so `main.o` is named after
`$HANDOVER` and the link is always redone. Without that, building with the
handover on and then turning it off would quietly leave the dual-world image
in place and boot that instead.

Which world a function ends up in is decided by the section it is compiled
into, not by `linker.x`. Mark a Secure-world function with `SECURE_FUNC` and a
Non-secure one with `NONSECURE_FUNC`, both defined at the top of `main.c`. A
function left in an ordinary `.text` matches no rule in the script, so the
linker keeps it as an orphan section and quietly places it next to the Secure
code: the image still links, and the only sign of it is that the Non-secure
world is empty and the handover branches into nothing. The `ASSERT`s at the
end of `linker.x` turn that into a link error naming the attribute to add.

Edit `main.c` and `world_switch.s`, then run `./trustzone_box.sh build` to
recompile the image.

## Notes

- **The handover target needs its Thumb bit set.** `BLXNS` reads bit 0 of the
  target register as the instruction set to branch into, and ARMv8-M has only
  Thumb, so branching to the bare address is a branch into ARM state: the core
  takes a SecureFault with `SFSR.INVEP` and the machine lockups.
  `switch_to_nonsecure()` adds 1 to the address for that reason. Worth
  knowing about, because with a debugger attached the fault can look like a
  handover that half worked — the breakpoint goes in before the branch is
  taken — so boot without one to check.
- **The firmware is loaded at `$LOAD_ADDR`, and that address is not a detail.**
  On reset the Secure core takes its vector table from `0x10000000`. An image
  linked somewhere else is not where the core looks, and the result is a
  lockup that QEMU reports as a fatal error. `mps2-an547` is the exception,
  with its vector table at `0x00000000`; changing `$MACHINE` means changing
  `$LOAD_ADDR` to match.
- **There are no credentials to log in with.** There is no operating system
  and no login: the firmware is bare metal, so it prints nothing and there is
  no prompt to type at. What the terminal takes over is QEMU's own monitor,
  where `info registers` and `x/8i $pc` work; for anything more, use `-d` and
  drive the guest through gdb. `info registers` is worth a look on its own:
  `R15` says which world the core is in, since the Secure world is linked
  above `0x10000000` and the Non-secure world below it — `0x1000000a` for a
  normal boot, `0x00100002` once the handover has happened. Do not read the
  `S` in the `XPSR` line for this: QEMU prints it either way.
- **The monitor gets the terminal through `-monitor stdio`, not through
  `-serial mon:stdio`.** On this board the usual mux form does not work: the
  machine claims stdio for its own UART first, so the monitor never gets it
  and the terminal sits there answering nothing. `-monitor stdio` is a
  separate request and is honoured. Two things follow: the guest's UART is
  discarded rather than muxed, which costs nothing while the firmware prints
  nothing, and `Ctrl+A`, then `X` does **not** quit — type `quit` at the
  monitor prompt instead.
- **There is no bootloader involved.** Whatever the image does after reset is
  what the terminal shows.
- **`$MACHINE` and `$CPU` are configurable.** `mps2-an521` and `mps2-an524`
  are the dual-core variants of the same family, and `mps2-an547` is the
  Cortex-M55 one.
