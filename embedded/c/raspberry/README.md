# A Raspberry Pi OS Lite QEMU box for C kernel module development

Raspberry Pi OS Lite (aarch64) running on the `raspi3b` machine emulated by
QEMU, set up to build and load a Linux kernel module.

## What this box does

1. Downloads the Raspberry Pi OS Lite image.
2. Builds a Linux kernel from source, and the device tree blob for the
   emulated board out of that same tree.
3. Builds every module in `modules/` and `drivers/` against that kernel.
4. Boots the guest with the freshly built kernel.

Because the modules and the kernel they are loaded into are the same one, they
load without `--force`, and you never have to worry about a version mismatch.

## Additional requirements (see root project folder)

- `curl`, `xz`, `e2fsprogs` (for `debugfs`), `openssl`
- `qemu-system-aarch64`
- `aarch64-linux-gnu-gcc` (cross compiler)
- `make`, `flex`, `bison`, and the OpenSSL headers (to build the kernel)
- `mtools` (to enable sshd in the guest; see below)
- `dnsmasq` and `nftables` (or `iptables`) — only for `$NETWORK=tap`

## Project structure

```
embedded/c/raspberry/          # Raspberry Pi OS Lite QEMU box (C)
├── raspberry_pi_box.sh        #   Main script (setup, build, boot)
├── Makefile                   #   Builds every module in modules/ and drivers/
├── modules/                   #   Your kernel modules — one directory each
├── drivers/                    #   Your drivers, if you keep them separate
├── .gitignore
└── README.md
```

The box is the skeleton: the script downloads the image, builds the kernel,
and boots, and the Makefile builds whatever you put in `modules/` and
`drivers/`. Both folders start empty.

## Options

| Option | Effect |
|--------|--------|
| `build` | Compile the kernel module and stop |
| `-s`, `--setup` | Download the files and stop |
| `-b`, `--boot` | Download, build, and boot (default) |
| `-d`, `--debug` | Boot with the cpu halted, waiting for gdb on port 1234 |
| `-h`, `--help` | Print the help message |

## Your modules

Every directory in `modules/` and `drivers/` is one module, with its own
Makefile in the kbuild style:

```
modules/
└── hello/
    ├── Makefile               #   obj-m += hello.o
    └── hello.c               #   the module
```

Add a directory, run `make` (or `./raspberry_pi_box.sh build`), and the module
is built against the kernel the box compiled. To load it:

```bash
scp -P 2222 modules/hello/hello.ko pi@localhost:/tmp/   # the box forwards the guest's ssh port
```

Then, inside the guest:

```bash
sudo insmod /tmp/hello.ko
dmesg | tail -n 1                 # "hello: the module is loaded"
sudo rmmod hello
dmesg | tail -n 1                 # "hello: the module is going away"
```

## Notes

- **The kernel is built from source, once.** The box downloads
  linux-5.4.51, configures it from `$KERNEL_DEFCONFIG` (`defconfig`, which is
  the only one mainline has for arm64 — names like `bcm2711_defconfig` exist
  only in Raspberry Pi's own kernels), adds `$KERNEL_OPTIONS` on top, and
  compiles it. This takes a while the first time; it is cached in the work
  directory and reused afterwards.
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
  has no PCI network card, so the only device QEMU offers is `usb-net`. That
  device with QEMU's user-mode networking is reported broken for some hosts:
  it fails with `Slirp: Failed to send packet, ret: -1` and the guest never
  gets anywhere (QEMU issue
  [#1927408](https://gitlab.com/qemu-project/qemu/-/issues/1927408)). It does
  work on the machine this box was developed on, where the guest gets DHCP
  over slirp and answers on the forwarded ssh port. So `$NETWORK` is `tap` by
  default, and set it near the top of `raspberry_pi_box.sh` to change it:

  | `$NETWORK` | Effect |
  |------------|--------|
  | `tap` | A TAP device (`$TAP_DEVICE`, default `tap0`). The default: the box creates it, runs DHCP and NAT on it, and tells you the guest's address. |
  | `usb` | QEMU's `usb-net` device with a forwarded ssh port. Works where slirp does not fail; needs no privileges. |
  | `none` | No networking. The serial console is the only way in. |

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

  ```sh
  sudo ip tuntap add dev tap0 mode tap user "$(id -un)"
  sudo ip addr add 10.0.2.1/24 dev tap0
  sudo ip link set tap0 up
  NETWORK=tap ./raspberry_pi_box.sh
  ```
- **Editing the kernel command line.** The default is
  `rw earlyprintk console=ttyAMA0,115200 root=/dev/mmcblk0p2 rootdelay=1`.
  `rootdelay=1` gives the emulated card a moment to show up before the
  kernel goes looking for the root filesystem, and the console baud rate is
  spelled out because the getty on the other end of the line expects it.
