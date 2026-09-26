# Embedded QEMU boxes

Boxes for the machines QEMU emulates for embedded targets. Unlike the x86
ones, these guests run under TCG emulation, so none of them needs KVM.

| Box | Script | Machine | Guest |
|-----|--------|---------|-------|
| [Raspberry Pi OS Lite](raspberry/) | `raspberry_pi_box.sh` | `raspi3b` (aarch64) | Linux (Bookworm) |
| [Cortex-M33 / TrustZone](trustzone/) | `trustzone_box.sh` | `mps2-an505` (ARMv8-M) | bare metal |

## Project structure

```
embedded/                     # Embedded QEMU boxes
├── raspberry/                # Raspberry Pi OS Lite QEMU box
│   ├── raspberry_pi_box.sh   #   Main script (setup, boot)
│   ├── .gitignore
│   └── README.md
├── trustzone/                # Cortex-M33 / TrustZone QEMU box
│   ├── trustzone_box.sh      #   Main script (setup, boot)
│   ├── .gitignore
│   └── README.md
└── README.md                 # This file
```

Each box directory has a `README.md` of its own with the requirements, the
options, and the notes specific to that machine. Both scripts source the
output helpers shared by the whole repository, in
[../lib/output.sh](../lib/output.sh).
