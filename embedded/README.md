# Embedded QEMU boxes

Boxes for the machines QEMU emulates for embedded targets. Unlike the x86
ones, these guests run under TCG emulation, so none of them needs KVM.

Each box is set up for development in one language, and builds the guest
side of the project itself: the C boxes compile with the cross toolchain,
and the Rust boxes with cargo. The box is the environment — the project
code is yours to write.

| Box | Language | Script | Machine | Guest |
|-----|----------|--------|---------|-------|
| [Raspberry Pi OS Lite](c/raspberry/) | C | `raspberry_pi_box.sh` | `raspi3b` (aarch64) | Linux (Bookworm) |
| [Cortex-M33 / TrustZone](c/trustzone/) | C | `trustzone_box.sh` | `mps2-an505` (ARMv8-M) | bare metal |
| [Raspberry Pi OS Lite](rust/raspberry/) | Rust | `raspberry_pi_box.sh` | `raspi3b` (aarch64) | Linux (Bookworm) |
| [Cortex-M33 / TrustZone](rust/trustzone/) | Rust | `trustzone_box.sh` | `mps2-an505` (ARMv8-M) | bare metal |

## Project structure

```
embedded/                     # Embedded QEMU boxes
├── c/                        # Boxes set up for C development
│   ├── raspberry/            #   Raspberry Pi OS Lite, kernel module
│   └── trustzone/           #   Cortex-M33 / TrustZone, --handover for both worlds
└── rust/                     # Boxes set up for Rust development
    ├── raspberry/            #   Raspberry Pi OS Lite, Rust kernel module
    └── trustzone/           #   Cortex-M33 / TrustZone, --handover for both worlds
```

Every box directory has a `README.md` of its own with the requirements, the
options, and the notes specific to that machine. All the box scripts source
the output helpers shared by the whole repository, in
[../../lib/output.sh](../../lib/output.sh), through a symlink in their own
directory.

## The two Pi boxes

The Raspberry Pi boxes differ in the kernel they build, because a Rust
kernel module needs a kernel with Rust support:

| | kernel | why |
|---|--------|-----|
| **C** | 5.4.51, built from source | matches the module, no `--force` needed |
| **Rust** | 7.2.8, built from source | Rust support on arm64, and new enough for a current `rustc` |

Both build the kernel from source and cache it, so the build only happens
once, and both boot the freshly built kernel. The device tree blob is built
out of that same tree rather than downloaded, so that it always describes the
board to the kernel sitting next to it.

Before every boot both boxes change the guest image offline, on the host: they
set the password in `/etc/shadow`, drop the `ssh` file in the boot partition,
and mask `userconfig.service`. That last one matters more than it looks. RPi OS
ships it as a configuration dialog on `/dev/tty8`, the framebuffer console, and
systemd restarts it on failure. There is no framebuffer in this machine, so it
fails, is retried forever, and `multi-user.target` never completes — nothing
after it starts, sshd least of all, and a guest that has booted quite happily
looks like one that has hung.

The Rust kernel is not a version that can just be set to anything.
`CONFIG_RUST` needs `HAVE_RUST`, which arm64 only selects from 6.9 onwards, and
that symbol is promptless — kconfig always recalculates it, so it cannot be
switched on from `.config`. It also has to be new enough for the `rustc` you
have: the kernel builds its own `core` from your toolchain's sources, so an
older kernel fails on *the toolchain's* code, with errors that name neither the
kernel nor anything you did. From 6.16 onwards it uses edition 2024 when `rustc`
is 1.87 or newer, which is what makes a current toolchain work. The box checks
`CONFIG_RUST` survived and stops with a message listing the possible causes
rather than carrying on and leaving Rust out. The
[Rust box's README](rust/raspberry/README.md) has the detail.
