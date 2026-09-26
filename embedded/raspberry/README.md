# Automated creation of a Raspberry Pi OS Lite QEMU box

Raspberry Pi OS Lite (aarch64) running on the `raspi3b` machine emulated by
QEMU, booted over the serial console.

## Additional requirements (see root project folder)

- `curl` (for downloading the image, the kernel, and the device tree blob)
- `xz` (to extract the disk image)
- `qemu-system-aarch64`
- `e2fsprogs` (for `debugfs`, only if you set `$GUEST_PASSWORD`) and
  `openssl` (to hash it) — see [Logging in](#logging-in)

**Note:** the guest runs under TCG emulation, so this box does not need KVM
and works on any machine QEMU itself runs on.

## Project structure

```
embedded/raspberry/          # Raspberry Pi OS Lite QEMU box
├── raspberry_pi_box.sh      #   Main script (setup, boot)
├── .gitignore               #   Ignores the image, the kernel, and the dtb
└── README.md
```

`setup` also leaves `raspios_lite_arm64.img`, `kernel8.img`,
`bcm2710-rpi-3-b-plus.dtb` and `SHA256` in this directory; they are all
ignored by `.gitignore`.

`raspberry_pi_box.sh` sources the output helpers shared by the whole
repository, which live in [../../lib/output.sh](../../lib/output.sh) — keep
that relative path in mind when copying the script somewhere else. The
presentation details (rule width, characters, wording of the messages) are
tweakable at the top of that file, and `./raspberry_pi_box.sh -h` lists
every setting of this box along with its current value.

## Options

| Option | Effect |
|--------|--------|
| `-s`, `--setup` | Download what is missing, and stop |
| `-b`, `--boot` | Download what is missing, and boot (default) |
| `-d`, `--debug` | Boot with the cpu halted, waiting for gdb on port 1234 |
| `-h`, `--help` | Print the help message |

## Quickstart

```bash
# From this directory
$EDITOR ./raspberry_pi_box.sh   # set $GUEST_PASSWORD, unless you enjoy locked images
./raspberry_pi_box.sh -h        # read the settings before downloading 415 MiB
./raspberry_pi_box.sh           # download everything and boot
```

The first run downloads three files into `$WORK_DIR` (the current directory
by default), checks the image against the checksum published by Raspberry Pi
Ltd., sets the guest credentials if `$GUEST_PASSWORD` is not empty, and then
boots:

| File | Size | Origin |
|------|------|--------|
| `raspios_lite_arm64.img` | 2.6 GiB | [raspios_lite_arm64.img.xz](https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-03-15/2024-03-15-raspios-bookworm-arm64-lite.img.xz) |
| `kernel8.img` | about 15 MiB | [dhruvvyas90/qemu-rpi-kernel](https://github.com/dhruvvyas90/qemu-rpi-kernel) |
| `bcm2710-rpi-3-b-plus.dtb` | about 30 KiB | [dhruvvyas90/qemu-rpi-kernel](https://github.com/dhruvvyas90/qemu-rpi-kernel) |

The compressed image is removed once it has been extracted; delete the
resulting `.img` file to download everything again.

## Notes

- **QEMU does not emulate the Pi hardware.** It only provides just enough of
  it to run a Linux kernel, which is why a kernel and a device tree blob
  built for the emulated board have to be passed to QEMU alongside the disk
  image. Both are taken from the community repository linked above. The
  kernel dates from 2020, so a few modern userspace features may misbehave
  against it.
- **The device tree blob is not interchangeable.** Only the
  `bcm2710-rpi-3-b-plus.dtb` one works with this machine: with
  `bcm2837-rpi-3-b.dtb` the kernel cannot find the card at all, and the boot
  dies on `Cannot open root device "mmcblk0p2"`. Worth knowing since the
  repository linked above carries a blob per board.
- **The emulated board has no PCI network card.** The guest is therefore
  given QEMU's USB network adapter (`-device usb-net`), which the kernel and
  the blob above do describe, and its ssh port is forwarded to `$SSH_PORT`
  on the host. Both the kernel command line (`rootdelay=1`) and the console
  baud rate (`console=ttyAMA0,115200`) are spelled out, as the emulated card
  can be a moment behind the kernel at boot.
- **An alternative to the community kernel** is to use the one the image
  ships with: `kernel8.img` and `bcm2710-rpi-3-b-plus.dtb` can be copied out
  of the boot partition of `raspios_lite_arm64.img` (with `mcopy -i
  <image>@@4194304 ::kernel8.img -`, or a loop mount as root), and then only
  `$KERNEL_URL` has to go. The two pair up either way, since both come out of
  the same repository or the same image.
- **The serial console is the only display.** The guest is booted with
  `console=ttyAMA0`, so the kernel messages and the login prompt show up on
  the terminal QEMU was started from. Quit with `Ctrl+A`, then `X`.
- **Logging in: the image ships with every account locked.** The only
  accounts with a shell are `root` and `pi` (uid 1000, member of `sudo`), and
  both have their password field set to a lock in `/etc/shadow` — `*` and `!`
  respectively. There is no default password (the `raspberry` one was dropped
  from the images in 2022), and the login prompt will refuse an empty
  password too. Three ways of getting in:

  1. **Let the box do it, which is what `$GUEST_PASSWORD` is for.** Set it
     near the top of `raspberry_pi_box.sh`:

     ```sh
     GUEST_USER="pi"
     GUEST_PASSWORD="whatever-you-like"
     ```

     and every `setup` run writes that password straight into `/etc/shadow`
     in the image, before the first boot. It cuts the root filesystem out of
     the image, replaces the file with `debugfs(8)` (no root needed, and no
     loop mount), puts back the `root:shadow` ownership and the `rw-r-----`
     mode that replacing a file whole loses, reads it back to be sure, and
     writes the partition back where it came from.

     The password is hashed with `$PASSWORD_HASH` (`openssl passwd -6` by
     default) and never written to disk in plain text. It needs `debugfs`
     from `e2fsprogs`, plus roughly as much free space in `$WORK_DIR` as the
     root partition is big — about 2 GiB for the stock image, while it is
     being done.

     Editing the shadow file from the host like this is the workaround the
     wider QEMU+Raspberry Pi community settled on: the guest's own
     `userconf.txt` provisioning is widely reported to accept the file and
     still not let anyone in, which is exactly the failure this box ran into.
     See [this write-up and its comments](https://gist.github.com/cGandom/23764ad5517c8ec1d7cd904b923ad863).

     Two things to know about:

     - **`$GUEST_USER` has to be the account the image actually has.** The
       stock image calls it `pi`, but the first boot of the image runs a
       provisioning service that *renames* the first user to whatever name it
       is handed, so an image that has already been booted may call it
       something else. When that happens the box says so and names the
       account it found. Deleting `raspios_lite_arm64.img` and running
       `setup` again gives you a fresh image, and `pi` back.
     - **The password is rewritten on every `setup` run**, so it is reset to
       `$GUEST_PASSWORD` whenever you run the box again after changing it
       from inside the guest.

  2. **Set it by hand**, which is the same edit without the box in the way.
     The root filesystem is `/dev/mmcblk0p2`, and starts 516 MiB into the
     image:

     ```sh
     # a crypt(3) hash, not the password itself
     hash=$(openssl passwd -6 whatever-you-like)

     dd if=raspios_lite_arm64.img of=rootfs.img bs=1M skip=516
     debugfs -w -R "rm /etc/shadow" rootfs.img
     # ... edit the account's line, replacing its second field with $hash ...
     debugfs -w -R "write new-shadow /etc/shadow" rootfs.img
     debugfs -w -R "set_inode_field /etc/shadow uid 0" rootfs.img
     debugfs -w -R "set_inode_field /etc/shadow gid 42" rootfs.img
     debugfs -w -R "set_inode_field /etc/shadow mode 0100640" rootfs.img
     dd if=rootfs.img of=raspios_lite_arm64.img bs=1M seek=516 conv=notrunc
     rm rootfs.img new-shadow
     ```

     The `rm` and `write` are needed because `debugfs` cannot overwrite a
     file in place, and between them they lose the ownership and the mode,
     which is what the three `set_inode_field` calls put back.

  3. **Boot into the emergency shell**, which needs no password at all, by
     adding `systemd.unit=emergency.target` to `$KERNEL_CMDLINE`:

     ```sh
     KERNEL_CMDLINE="rw earlycon=pl011,0x3f201000 console=ttyAMA0 root=/dev/mmcblk0p2 rootwait systemd.unit=emergency.target"
     ```

     systemd starts `emergency.target` instead of `multi-user.target` and
     drops a root shell on the serial console. From there, `passwd <user>`
     sets the password you will use on subsequent boots. It is also the way
     to look around a guest that will not boot far enough to be useful.
- **The root device is the second partition** of the image
  (`root=/dev/mmcblk0p2`), which is the layout Raspberry Pi Ltd. ships. If
  the image is ever replaced by one with a different layout, `$KERNEL_CMDLINE`
  has to be adjusted to match.
