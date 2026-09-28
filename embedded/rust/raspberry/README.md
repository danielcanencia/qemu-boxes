# A Raspberry Pi OS Lite QEMU box for Rust kernel module development

Raspberry Pi OS Lite (aarch64) running on the `raspi3b` machine emulated by
QEMU, set up to build and load a Linux kernel module written in Rust.

## What this box does

1. Downloads the Raspberry Pi OS Lite image.
2. Builds a Linux kernel from source, with Rust support switched on, and the
   device tree blob for the emulated board out of that same tree.
3. Builds every module in `modules/` and `drivers/` against that kernel.
4. Boots the guest with the freshly built kernel.

Rust support on arm64 is what makes a Rust kernel module possible at all, and
it is not as settled as it looks: the kernel builds its own `core` from your
`rustc`'s sources, so the kernel's age and your compiler's age have to suit
each other. The box ships a version that works with a current toolchain. See
[Why this kernel](#why-this-kernel) before changing it.

Because the modules and the kernel they are loaded into are the same one, they
load without `--force`.

## Choosing the kernel

These variables near the top of `raspberry_pi_box.sh` control the kernel:

| Variable | Effect |
|----------|--------|
| `$KERNEL_VERSION` | The version to build, as a string. |
| `$KERNEL_URL` | The tarball to download it from. Derived from the version by default; set it yourself if your mirror puts it somewhere else. |
| `$KERNEL_SRC` | A kernel source tree that is already on disk. Set this to use your own tree — or the kernel you are already running — and neither the tarball nor the download is touched. |
| `$KERNEL_DEFCONFIG` | The defconfig to start from. It has to come first of all: every other config target merges into the `.config` it creates, and refuses to run without one. |
| `$KERNEL_OPTIONS` | Anything else the box needs, one `SYMBOL=value` per line. See below. |
| `$KERNEL_OPTIONS_OFF` | Symbols to switch off, one per line. `$KERNEL_OPTIONS` turns things on, this turns them off. |
| `$KERNEL_DTB` | The device tree blob, as a make target inside the tree. It is built rather than downloaded, so that it always describes the board to the kernel next to it. |
| `$GUEST_UNITS_TO_MASK` | systemd units to mask in the image before the first boot, one name per line, or empty for none. See below. |

The tree is cached in the work directory, so the build only happens once.

### Why this kernel

Four things have to line up before a Rust module will build, and none of them
are on by default. The box checks the first one and stops with a message
naming the rest.

- **`CONFIG_RUST` needs `HAVE_RUST`, and arm64 only selects that from Linux
  6.9 onwards.** `HAVE_RUST` is a promptless symbol, which kconfig always
  recalculates from whatever selects it, so there is no way to switch it on
  from `.config`. On anything older than 6.9 the box cannot build a kernel
  with Rust in it, and says so rather than carrying on without it.
- **The kernel has to be new enough for your `rustc`.** This is the one that
  catches people. The kernel compiles `core` from the sources in your Rust
  toolchain, using its own edition setting, so a kernel that predates your
  compiler fails on the *toolchain's* code — errors like `let chains are only
  allowed in Rust 2024 or later` or `error[E0700]`, pointing into
  `~/.rustup/toolchains/.../library/core/`, which look nothing like a kernel
  problem. From **Linux 6.16** the kernel compiles `core` with edition 2024
  whenever `rustc` is 1.87 or newer, which is what makes a current toolchain
  work. Below that, you need an older `rustc` — `rustup toolchain install` and
  `rustup default` — and the version the kernel expects is printed at the top
  of the build.
- **`CONFIG_RUST` refuses to be built alongside certain options.** Which ones
  moves between kernel versions: it was `!GCC_PLUGINS`, and from 6.14 it is
  `!RANDSTRUCT` and `!GCC_PLUGIN_RANDSTRUCT`. arm64's `defconfig` enables some
  of them, so `$KERNEL_OPTIONS_OFF` lists every name that has ever blocked it
  and switches them all off. A kernel that has never heard of one ignores the
  line, so the list is safe on any version.
- **`CONFIG_RUST` needs a Rust toolchain**: `rustc`, plus matching LLVM and
  libclang. `make ARCH=arm64 rustavailable` says exactly what is wrong with
  the one you have.

`$KERNEL_OPTIONS` is a separate list because those options are the box's own
requirements rather than anything to do with Rust. It is the USB networking
driver that QEMU's `-device usb-net` presents; see the networking section.

## Additional requirements (see root project folder)

- `curl`, `xz`, `e2fsprogs` (for `debugfs`), `openssl`
- `qemu-system-aarch64`
- `aarch64-linux-gnu-gcc` (cross compiler)
- `rustup`, with the `aarch64-unknown-linux-gnu` target installed
- `make`, `flex`, `bison`, and the OpenSSL headers (to build the kernel)
- `rustc` and `bindgen` (to build the Rust module)
- `mtools` (to enable sshd in the guest; see below)
- `dnsmasq` and `nftables` (or `iptables`) — only for `$NETWORK=tap`

## Project structure

```
embedded/rust/raspberry/          # Raspberry Pi OS Lite QEMU box (Rust)
├── raspberry_pi_box.sh           #   Main script (setup, build, boot)
├── Makefile                      #   Builds every module in modules/ and drivers/
├── modules/                      #   Your kernel modules — one directory each
├── drivers/                      #   Your drivers, if you keep them separate
├── .gitignore
└── README.md
```

The box is the skeleton: the script downloads the image, builds the kernel,
and boots, and the Makefile builds whatever you put in `modules/` and
`drivers/`. Both folders start empty.

## Options

| Option | Effect |
|--------|--------|
| `build` | Compile the Rust kernel module and stop |
| `-s`, `--setup` | Download the files and stop |
| `-b`, `--boot` | Download, build, and boot (default) |
| `-d`, `--debug` | Boot with the cpu halted, waiting for gdb on port 1234 |
| `-h`, `--help` | Print the help message |

## Your modules

Every directory in `modules/` and `drivers/` is one module: a Makefile in the
kbuild style, naming the object or objects to build.

A Rust module, where the Rust sources are built by the kernel's own Rust
support:

```
modules/
└── rust_hello/
    ├── Makefile               #   obj-m += rust_hello.o
    │                          #   rust_hello-objs += rust_hello_core.o
    └── rust_hello_core.rs     #   the module
```

Add a directory, run `make` (or `./raspberry_pi_box.sh build`), and the module
is built against the kernel the box compiled. To load it:

```bash
scp -P 2222 modules/rust_hello/rust_hello.ko pi@localhost:/tmp/   # the box forwards the guest's ssh port
```

Then, inside the guest:

```bash
sudo insmod /tmp/rust_hello.ko
dmesg | tail -n 1                 # "rust_hello: the module is loaded"
sudo rmmod rust_hello
dmesg | tail -n 1                 # "rust_hello: the module is going away"
```

## Notes

- **The kernel is built from source, once.** The box downloads the tarball
  named by `$KERNEL_URL`, configures it from `$KERNEL_DEFCONFIG`, merges the
  KVM guest settings on top, adds `$KERNEL_OPTIONS` and `CONFIG_RUST`, and
  compiles it. This takes a while the first time; it is cached in the work
  directory and reused afterwards. The order matters: the defconfig has to come
  first, because `kvm_guest.config` is a merge target and reads the `.config` it
  merges into, so without one it stops with `The base file '.config' does not
  exist`. Each step is checked separately, so a failure names the step that
  failed rather than surfacing much later as a module that will not build.
  The device tree blob is built from the same tree, as its own make target, so
  that a tree that has been built is not assumed to be one whose blob has been.
- **The box changes the image, offline, before every boot.** It sets the
  password, masks the units in `$GUEST_UNITS_TO_MASK`, and drops the `ssh`
  file in the boot partition. All of that is done on the host with `debugfs`
  and `mtools`, while the guest is not running, because the services that
  would do it at first boot want a framebuffer console this box has none of.
  Editing a mounted filesystem's metadata this way needs roughly as much free
  disk as the root partition is big, and the box says so if there is not
  enough.
- **`build` only reuses a kernel it considers the right one.** It checks both
  that the image exists and that `CONFIG_RUST` is still set, so a tree left
  half-configured by an earlier failure is reconfigured rather than quietly
  reused. It also checks the tree was extracted in full, so a download that was
  interrupted leaves nothing behind that looks usable.
- **Building a Rust kernel module is done by kbuild, not by cargo.** The
  kernel's build system invokes `rustc` on the Rust sources itself, with the
  flags the kernel needs, which is why the Makefile only names the Rust
  object and there is no `.cargo` directory here.
- **The image ships with every account locked.** There is no default
  password, so the login prompt is of no use until a password is set. Set
  `$GUEST_PASSWORD` near the top of `raspberry_pi_box.sh` and the box
  writes it straight into `/etc/shadow` in the image, before the first boot.
  Then you can log in over the serial console or over ssh
  (`ssh -p 2222 pi@localhost`).
- **The box enables sshd for you.** RPi OS only starts the ssh daemon when
  an empty file named `ssh` is present in the boot partition, so the box
  writes one there (with `mtools`) before every boot. Without it, ssh cannot
  get in however the network is set up.
- **QEMU does not emulate the Pi hardware.** It only provides just enough
  of it to run a Linux kernel, which is why a kernel and a device tree blob
  built for the emulated board have to be passed to QEMU alongside the disk
  image. The box takes the blob out of the kernel it builds rather than
  downloading one, since the two have to match. That is not a detail: a blob
  for this board from elsewhere describes no console at all — no
  `stdout-path` in `/chosen`, no PL011 — so the kernel comes up, mounts
  nothing and says absolutely nothing, which looks exactly like a box that
  booted and hung. Note the name: Raspberry Pi OS calls this board's blob
  `bcm2710-rpi-3-b-plus.dtb`, mainline calls it
  `bcm2837-rpi-3-b-plus.dtb`, and it is the mainline name that
  `$KERNEL_DTB` is set to.
- **The box masks the first-boot dialog.** RPi OS ships
  `userconfig.service`, a configuration dialog that wants `/dev/tty8` — the
  framebuffer console — and that systemd restarts on failure. This box has
  no framebuffer, so the unit fails, is retried forever, and
  `multi-user.target` never completes. Nothing after it starts, sshd least
  of all, and a guest that has booted quite happily looks like one that has
  hung. The box masks the units named in `$GUEST_UNITS_TO_MASK` in the image
  before booting. If the image already has something at the masking path,
  the box says so and leaves it alone rather than overwriting it.
- **Networking is TAP by default, and that is deliberate.** The emulated board
  has no PCI network card, so the only device QEMU offers is `usb-net` — and
  that device combined with QEMU's user-mode networking is reported broken
  for some hosts: it fails with `Slirp: Failed to send packet, ret: -1` and
  the guest never gets anywhere (QEMU issue
  [#1927408](https://gitlab.com/qemu-project/qemu/-/issues/1927408)). It
  does work on the machine this box was developed on, where the guest gets
  DHCP over slirp and answers on the forwarded ssh port. So `$NETWORK` is
  `tap` by default, and set it near the top of `raspberry_pi_box.sh` to
  change it:

  | `$NETWORK` | Effect |
  |------------|--------|
  | `tap` | A TAP device (`$TAP_DEVICE`, default `tap0`). The default: the box creates it, runs DHCP and NAT on it, and tells you the guest's address. |
  | `usb` | QEMU's `usb-net` device with a forwarded ssh port. Works where slirp does not fail; needs no privileges. |
  | `none` | No networking. The serial console is the only way in. |

  Whichever device is used, the guest talks over `usb-net`, so the kernel needs
  the USB networking driver. That is what `$KERNEL_OPTIONS` is for: it builds in
  `CONFIG_USB_USBNET` and `CONFIG_USB_NET_RNDIS_HOST`, neither of which arm64's
  `defconfig` has. They are built in rather than left as modules because
  nothing in the guest can load a module before the network is up, so a driver
  that is a module is a NIC the guest never has. The box checks they survived
  the configuration and stops if they did not.

  The box creates the device itself when it is not there yet: it uses `sudo`
  for that when it is not running as root, and gives the device to you so
  that QEMU can open it without root. It is removed again once QEMU exits,
  unless `$TAP_CLEANUP` is set to 'off'.

  A TAP device on its own gives the guest no address and no way out, so the
  box also runs a DHCP server (`dnsmasq`) on the device and masquerades the
  guest's traffic, which is what lets it reach the internet. The guest is
  given a fixed address, `$GUEST_IP` (default `10.0.2.15`), so the box always
  knows where to find it:

  ```
  › creating the tap0 TAP device
  ✓ tap0 is ready
  › running a DHCP server on tap0
  › masquerading the guest's traffic via eth0
  ✓ the guest can now get an address and reach the internet
  ```

  ```sh
  NETWORK=tap ./raspberry_pi_box.sh
  # then, from the host, once the guest has booted:
  ssh pi@10.0.2.15
  ```

  If you would rather create the device yourself — to add it to a bridge,
  for instance — set `$TAP_DEVICE` and `$TAP_ADDRESS` to match what you
  made, and the box reuses it as it stands. It still runs the DHCP server
  and the NAT, since those are what make the guest reachable.
