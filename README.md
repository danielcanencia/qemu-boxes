<p align="center">
  <img
        src="https://gitlab.com/qemu-project/qemu/-/raw/master/ui/icons/qemu_512x512.png"
        alt="QEMU logo" width="200"
  >
</p>

# qemu-boxes

[![hosted on Codeberg](https://img.shields.io/badge/Hosted_on-Codeberg-blue?logo=codeberg)](https://codeberg.org/YOUR_USERNAME/qemu-boxes)

Automated creation and management of custom QEMU virtual machine boxes.

## Supported systems

| System | Status |
|--------|--------|
| [OpenBSD](openbsd/) | Supported |

## Requirements

- Linux with KVM support
- [QEMU](https://www.qemu.org/) (`qemu-system-x86_64`, `qemu-img`)

## Project structure

```
qemu-boxes/
├── openbsd/                  # OpenBSD QEMU box
├── .../                      # Other QEMU boxes
└── README.md
```

## Documentation

Each system directory contains its own `README.md` with specific instructions. 
See [openbsd/README.md](openbsd/README.md) for the OpenBSD box.


## Adding a new system

1. Create a new directory at the project root (e.g., `freebsd/`, `netbsd/`).
2. Add a QEMU wrapper script and any necessary configuration files.
3. Add a `README.md` with system-specific instructions.
4. Update the supported systems table above.

> **Note**: Scripts can be written in any language, though shell script or \
> shell-like languages (e.g., Bash, Fish, Zsh) are preferred for portability and simplicity.

## Coding standards

Scripts must follow the coding standards described below.

### Language

The preferred language is **POSIX-compliant `sh`** (i.e. `/bin/sh`), for
portability across systems and ease of use. Other languages are accepted, but
shell or shell-like languages are preferred whenever reasonable.

### Conventions

- Use `#!/usr/bin/env sh` as the shebang.
- Use tabs for indentation (8-column width), in line with OpenBSD style.
- Use `name ()` function syntax, not `function name ()`.
- All variables that may vary must be configurable — never hardcode values
  that the user is expected to change.
- Check syntax before committing: `sh -n script.sh`

### Recommended tools

- `sh -n` — syntax check (available in base on all systems).
- `shellcheck` — static analysis; install it via your system's package
  manager (`pkg_add shellcheck` on OpenBSD, `apt install shellcheck` on
  Debian/Ubuntu, `dnf install shellcheck` on Fedora, etc.).
