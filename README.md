<p align="center">
  <img
        src="https://gitlab.com/qemu-project/qemu/-/raw/master/ui/icons/qemu_512x512.png"
        alt="QEMU logo" width="200"
  >
</p>

# qemu-boxes

[![hosted on Codeberg](https://img.shields.io/badge/Hosted_on-Codeberg-blue?logo=codeberg)](https://codeberg.org/danielcanencia/qemu-boxes)
[![available on GitHub](https://img.shields.io/badge/Available_on-GitHub-181717?logo=github&logoColor=white)](https://github.com/danielcanencia/qemu-boxes)

Automated creation and management of custom QEMU virtual machine boxes.

## Supported systems

| System | Status |
|--------|--------|
| [OpenBSD](openbsd/) | Supported |
| [Raspberry Pi OS Lite (aarch64, C)](embedded/c/raspberry/) | Supported |
| [Cortex-M33 / TrustZone (AN505, C)](embedded/c/trustzone/) | Supported |
| [Raspberry Pi OS Lite (aarch64, Rust)](embedded/rust/raspberry/) | Supported |
| [Cortex-M33 / TrustZone (AN505, Rust)](embedded/rust/trustzone/) | Supported |

## Requirements

- Linux with KVM support.
- [QEMU](https://www.qemu.org/) (`qemu-system-x86_64`, `qemu-img`).
  The Raspberry Pi boxes need `qemu-system-aarch64` and the TrustZone ones
  `qemu-system-arm`; all the embedded guests run under TCG emulation,
  without KVM.
- The embedded boxes additionally need a cross toolchain and a build tool:
  `aarch64-linux-gnu-gcc` and `arm-none-eabi-gcc` for the C boxes, and
  `rustup` for the Rust ones. See each box's `README.md`.

## Project structure

```
qemu-boxes/
├── lib/                          # Shared helpers
│   └── output.sh                 #   Output and prerequisite helpers
├── openbsd/                      # OpenBSD QEMU box
│   ├── openbsd_box.sh            #   Main script (setup, install, boot)
│   ├── install.conf              #   Autoinstall configuration
│   ├── custom_disklabel.conf     #   Custom disk partition layout
│   ├── site_build/               #   Post-install customization scripts
│   │   ├── install.site
│   │   └── etc/
│   │       └── doas.conf
│   ├── .gitignore
│   └── README.md
├── embedded/                     # Embedded QEMU boxes
│   ├── c/                        #   Boxes set up for C development
│   │   ├── raspberry/            #     Raspberry Pi OS Lite, kernel module
│   │   └── trustzone/           #     Cortex-M33 / TrustZone, --handover for both worlds
│   ├── rust/                     #   Boxes set up for Rust development
│   │   ├── raspberry/            #     Raspberry Pi OS Lite, Rust kernel module
│   │   └── trustzone/           #     Cortex-M33 / TrustZone, --handover for both worlds
│   └── README.md                 #   Index of the boxes above
├── .shellcheckrc                 # Shellcheck configuration
├── .github/                      # Mirror and pull request automation
│   └── workflows/
│       ├── forward-pr.yml
│       └── mirror.yml
├── .../                          # Other QEMU boxes
└── README.md
```

Each box has its own directory with a `README.md` of its own, and every box
directory carries a `.gitignore` for the files its `setup` downloads or
creates.

Every box sources the same helpers, so the whole repository speaks with one
voice. `lib/output.sh` is not executed, only sourced through the box's own
directory, which carries a symlink to it. That way the path in the script is
the same in every box, however deep the box sits:

```sh
# every box sources it this way, output.sh being a symlink to
# ../lib/output.sh, ../../lib/output.sh, ... as the depth requires
# shellcheck source=output.sh
. "$(dirname "$0")/output.sh"
```

It holds the presentation details (rule width, characters, wording of the
messages, tweak them at the top of the file) along with the few helpers the
boxes share: the output primitives, `fail`/`warn`, `sha256_of`, `fetch`, and
`set_password`.

## Documentation

Each box directory contains its own `README.md` with specific instructions.
See [openbsd/README.md](openbsd/README.md) and
[embedded/README.md](embedded/README.md), which indexes the four embedded
boxes.


## Adding a new system

1. Create a new directory for the box, either at the project root (e.g.,
   `freebsd/`, `netbsd/`) or grouped with related ones (as `embedded/` does).
2. Add a QEMU wrapper script and any necessary configuration files.
3. Symlink `lib/output.sh` into the box directory, counting the `../` needed
   to get back to the project root, and source it through that symlink as the
   existing boxes do, so that it looks and reads like the rest.
4. Add a `README.md` with system-specific instructions, and a `.gitignore`
   for whatever the box downloads or creates.
5. Update the supported systems table above, and the project structure above
   if the box was added to a group.

## Coding standards

Scripts must follow the coding standards described below.

### Language

The preferred language is **POSIX-compliant `sh`** (i.e. `/bin/sh`), for
portability across systems and ease of use. However, other languages may 
be accepted.

> **Note**
> Scripts can be written in any language, though shell script or shell-like 
> languages (e.g., sh, bash, zsh) are preferred for portability 
> and simplicity.

### Conventions

- Use `#!/usr/bin/env sh` as the shebang.
- Use tabs for indentation (4-column width).
- Use `name ()` function syntax, not `function name ()`.
- All variables that may vary must be configurable — never hardcode values.
  that the user is expected to change.
- Check syntax before committing: `sh -n script.sh`.

### Recommended tools

- `sh -n` — syntax check (available in base on all systems).
- `shellcheck` — static analysis; install it via your system's package
  manager (`pkg_add shellcheck` on OpenBSD, `apt install shellcheck` on
  Debian/Ubuntu, `dnf install shellcheck` on Fedora, etc.).
