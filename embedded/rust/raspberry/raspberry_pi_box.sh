#!/usr/bin/env sh

# Setup, build, and boot a Raspberry Pi OS Lite virtual machine (aarch64).
#
# QEMU does not emulate the Raspberry Pi hardware, so the board is only
# good enough to run a Linux kernel: the disk image is accompanied by a
# kernel and a device tree blob built for the emulated machine, and the
# guest is told where to look for its root filesystem.
#
# This box is set up for Rust kernel module development. It builds a Linux
# kernel from source — the first with Rust support — and then builds the
# module against it. The kernel is cached, so the build only happens once.
#
# The image ships with every account locked, so a password has to be set
# before the first boot for the login prompt to be of any use. Set
# $GUEST_PASSWORD and the box writes it straight into /etc/shadow in the
# image. Leave it empty and the guest stays locked (README.md explains
# why).

# Output helpers, shared with every box in this repository
# shellcheck source=output.sh
. "$(dirname "$0")/output.sh"

# Where the image and the device tree blob are stored
WORK_DIR="."
# Image details
IMAGE_NAME="raspios_lite_arm64.img"
IMAGE_ARCHIVE="raspios_lite_arm64.img.xz"
IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-03-15/2024-03-15-raspios-bookworm-arm64-lite.img.xz"
# Checksum published next to the image; set it to "" to skip the check
IMAGE_SHA256_URL="${IMAGE_URL}.sha256"
# The device tree blob, as a make target inside the kernel tree.
#
# It is taken from the kernel the box builds rather than downloaded, because
# the two have to match and only the kernel's own is guaranteed to. That is not
# a detail: a blob from elsewhere for this board describes no console at all —
# no stdout-path in /chosen and no PL011 — so the kernel comes up, mounts
# nothing, and says absolutely nothing, which looks exactly like a box that
# booted and hung.
#
# Note the name. Raspberry Pi OS calls this board's blob bcm2710-rpi-3-b-plus;
# mainline calls it bcm2837-rpi-3-b-plus, and it is the mainline name that is
# what the kernel builds.
KERNEL_DTB="broadcom/bcm2837-rpi-3-b-plus.dtb"
# Performance-related
QEMU_RAM="1G"
QEMU_CPUS="4"
# Guest credentials
#
# The image ships with every account locked, so the login prompt is of no use
# until a password is set. Set $GUEST_PASSWORD and the box writes that
# password straight into /etc/shadow in the image, before the first boot.
# Leave it empty and the guest stays locked (README.md explains why).
GUEST_USER="pi"
GUEST_PASSWORD="pi"
# Guest units to mask before the first boot, one name per line, or empty for
# none.
#
# Raspberry Pi OS ships userconfig.service, a configuration dialog that wants
# /dev/tty8, the framebuffer console, and that systemd restarts on failure.
# This box has no framebuffer, so the unit fails, is retried forever, and
# multi-user.target never completes — which means sshd never starts, and a
# guest that has booted quite happily looks like one that has hung. Masking
# it is what lets the boot finish.
GUEST_UNITS_TO_MASK="userconfig.service"
# The shadow file holds a hash, never the password itself: this makes one
PASSWORD_HASH="openssl passwd -6"
# Where the root filesystem starts inside the image, in bytes. It is read
# from the partition table when sfdisk is available, and taken from this
# variable otherwise: the images published by Raspberry Pi Ltd. put the root
# filesystem at sector 1056768, i.e. 516 MiB in.
ROOTFS_OFFSET=541065216
# Tools
DEBUGFS="debugfs"
SFDISK="sfdisk"
DD="dd"
# Kernel build, for the Rust kernel module
#
# The kernel is built from source so that the module and the kernel it is
# loaded into are the same one. These variables control it:
#
#   KERNEL_VERSION  the version to build, as a string.
#   KERNEL_URL      the tarball to download it from. Derived from the version
#                   by default, but set it yourself if your mirror puts it
#                   somewhere else.
#   KERNEL_SRC      a kernel source tree that is already on disk. Set this to
#                   use your own tree — or the kernel you are already running
#                   — and neither the tarball nor the download is touched.
#
# The tree is cached in $WORK_DIR, so the build only happens once.
#
#   KERNEL_DEFCONFIG    the defconfig to start from. A defconfig has to come
#                       first of all: every other config target merges into
#                       the .config it creates, and refuses to run without
#                       one.
#   KERNEL_OPTIONS      anything else the box needs, one 'SYMBOL=value' per
#                       line, applied on top of that.
#   KERNEL_OPTIONS_OFF  symbols to switch off, one per line. The mirror
#                       image of $KERNEL_OPTIONS, and independent of it:
#                       what the box turns on and what it turns off need not
#                       be the same version's worth of symbols.
#
# Two things about Rust support are worth knowing, because neither is on by
# default and both fail quietly if you get them wrong.
#
# One is the kernel version. CONFIG_RUST needs HAVE_RUST, and arm64 only
# started selecting that in Linux 6.9. kconfig recalculates a promptless
# symbol like HAVE_RUST from whatever selects it, so there is no way to switch
# it on from .config: on anything older the box cannot build a kernel with
# Rust in it, and says so rather than carrying on and leaving it out.
#
# The other is that the kernel builds its own core from the Rust toolchain's
# sources, so the kernel's age and your rustc's age have to be compatible.
# From Linux 6.16 the kernel compiles core with edition 2024 whenever rustc is
# 1.87 or newer, which is what lets a current rustc build it. On an older
# kernel a current rustc fails on core with errors like "let chains are only
# allowed in Rust 2024 or later" — errors in the toolchain's sources, not in
# the kernel's, and pointing at a kernel version rather than at anything you
# did. So the default is a current stable, and older means older rustc.
KERNEL_VERSION="7.2.8"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${KERNEL_VERSION}.tar.xz"
KERNEL_SRC=""
KERNEL_DEFCONFIG="defconfig"
CROSS_COMPILE="aarch64-linux-gnu-"
# What CONFIG_RUST refuses to be built alongside. Its dependencies on these
# have moved around between kernel versions — it was !GCC_PLUGINS, and from
# 6.14 it is !RANDSTRUCT and !GCC_PLUGIN_RANDSTRUCT — so all of them are
# listed and switched off, and a kernel that has never heard of one just
# ignores the line. Nothing here is needed for anything the box does.
KERNEL_OPTIONS_OFF="CONFIG_GCC_PLUGINS
CONFIG_GCC_PLUGIN_RANDSTRUCT
CONFIG_RANDSTRUCT"
# The options the box needs on top of the defconfig and the KVM guest
# settings. They are built into the kernel image rather than left as modules,
# because nothing in the guest loads a module before the network is up — so a
# NIC driver that is a module is a NIC the guest never has.
#
# The emulated board has no PCI network card, so the only device QEMU offers
# is '-device usb-net', which presents an RNDIS gadget. Both halves of that
# are missing from arm64's defconfig: the USB networking core, and the RNDIS
# host driver that goes with it. CONFIG_USB_DWC2 is the controller on the
# emulated board. Without these the guest boots but never gets an address.
KERNEL_OPTIONS="CONFIG_USB_DWC2=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_USBNET=y
CONFIG_USB_NET_RNDIS_HOST=y"
# The Rust side of the module
RUST_TARGET="aarch64-unknown-linux-gnu"
# Connection details
#
# The emulated board has no PCI network card. QEMU's usb-net device, which is
# the only other option, is known to be broken with user-mode networking
# (QEMU issue #1927408: "Slirp: Failed to send packet"), so the default is no
# networking and the serial console is the interface. Set $NETWORK to 'tap'
# to use a TAP device instead, which needs root to set up; see README.md.
NETWORK="tap"
TAP_DEVICE="tap0"
# The address the TAP device is given, and the network the guest ends up on
TAP_ADDRESS="10.0.2.1/24"
# The address and MAC the guest is given, so that the box always knows where
# to find it. dnsmasq hands $GUEST_IP to the NIC with $GUEST_MAC, and QEMU is
# told to give the emulated NIC that MAC.
GUEST_IP="10.0.2.15"
GUEST_MAC="52:54:00:12:34:56"
# The host port the guest's ssh port is forwarded to, when $NETWORK is 'usb'
SSH_PORT=2222
# Miscellaneous
QEMU_BIN="qemu-system-aarch64"
MACHINE="raspi3b"
QEMU_CPU="cortex-a72"
# rootdelay gives the emulated card a moment to show up before the kernel
# goes looking for the root filesystem, and the console baud rate is spelled
# out because the getty on the other end of the line expects it
KERNEL_CMDLINE="rw earlyprintk console=ttyAMA0,115200 root=/dev/mmcblk0p2 rootdelay=1"


#
# ==== Setting things up ====
#
setup () {
	section "Raspberry Pi OS Lite box" "setup · fetch the image and the dtb"

	if ! [ -d "${WORK_DIR}" ]; then
		step "creating the ${WORK_DIR} directory"
		mkdir -p "${WORK_DIR}"
	fi
	work_dir=$(cd "${WORK_DIR}" && pwd)

	# 1. Download and extract the disk image (if applicable)
	if ! [ -f "${WORK_DIR}/${IMAGE_NAME}" ]; then
		step "downloading ${IMAGE_ARCHIVE} (about 415 MiB)"
		fetch "${IMAGE_URL}" "${WORK_DIR}/${IMAGE_ARCHIVE}"

		if [ -n "${IMAGE_SHA256_URL}" ]; then
			step "checking the integrity of ${IMAGE_ARCHIVE}"
			fetch "${IMAGE_SHA256_URL}" "${WORK_DIR}/SHA256"
			expected=$(awk '{ print $1; exit }' "${WORK_DIR}/SHA256")
			actual=$(sha256_of "${WORK_DIR}/${IMAGE_ARCHIVE}")
			if [ -z "${expected}" ] || [ "${expected}" != "${actual}" ]; then
				fail "the ${IMAGE_ARCHIVE} file has been tampered with" \
					"expected sha256: ${expected}" \
					"actual sha256:   ${actual}"
			fi
			result "${OK_CHAR}" "sha256 matches the one published by raspberrypi.com"
		fi

		step "extracting ${IMAGE_ARCHIVE}"
		if ! xz --decompress --stdout "${WORK_DIR}/${IMAGE_ARCHIVE}" \
			> "${WORK_DIR}/${IMAGE_NAME}"; then
			rm -f "${WORK_DIR}/${IMAGE_NAME}"
			fail "the ${IMAGE_ARCHIVE} file could not be extracted" \
				"is the 'xz' package installed?"
		fi
		rm -f "${WORK_DIR}/${IMAGE_ARCHIVE}"
		result "${OK_CHAR}" "${IMAGE_NAME} is ready"
	else
		step "reusing the ${IMAGE_NAME} image found in ${work_dir}"
		result "${OK_CHAR}" "no download needed"
	fi

	# 2. Make sure the pre-requisites are met. The device tree blob is not
	#    among them: it comes out of the kernel, and 'build' makes it.
	if ! [ -f "${WORK_DIR}/${IMAGE_NAME}" ]; then
		fail "some prerequisites were not met" \
			"expected ${IMAGE_NAME} in ${work_dir}"
	fi

	blank
	paragraph "The box is ready. Build the module with './raspberry_pi_box.sh" \
		"build', or boot it as it is with './raspberry_pi_box.sh'."
}


#
# ==== Setting up the TAP device ====
#
# Creating a TAP device needs root, so this goes through sudo when the box is
# not already running as it. The device is given to the user that runs the
# box, so QEMU can open it without root as well. Set $TAP_CLEANUP to 'off' to
# leave the device behind once QEMU has exited.
TAP_CLEANUP="on"

# Root runs the privileged commands directly, and everything else through
# sudo. This is needed whichever way the device was arrived at, because
# dnsmasq and the sysctl calls below need it either way.
#
# It is defined out here rather than inside setup_tap because the exit trap
# that cleans up runs from cleanup_tap, and dnsmasq itself is a root process,
# so stopping it needs this too.
if [ "$(id -u)" -eq 0 ]; then
	_as_root () { "$@"; }
else
	_as_root () { sudo "$@"; }
fi

# The same, but for the cleanup path, where waiting for a password is not
# an option. The sudo timestamp taken in setup_tap can well have expired by
# the time QEMU exits, and a prompt raised from inside an exit trap has
# nowhere to go, so this fails straight away instead. Everything the
# cleanup does is guarded anyway, and it failing only leaves state behind
# for the next run to report on.
if [ "$(id -u)" -eq 0 ]; then
	_as_root_now () { "$@"; }
else
	_as_root_now () { sudo -n "$@"; }
fi


# Print the dnsmasq processes on this host, one per line, as a pid and the pid
# file each was told to write. Read from /proc rather than from ss, because
# dnsmasq drops to nobody and ss cannot name a process it does not own.
_tap_dnsmasq_pids () {
	_tap_line=""
	for _tap_dir in /proc/[0-9]*; do
		_tap_pid=${_tap_dir#/proc/}
		[ "${_tap_pid}" -gt 1 ] 2>/dev/null || continue
		# argv is NUL separated, so turn each argument onto its own line.
		# Read with cat rather than with a redirection on tr, so that a
		# process exiting between the glob and the read stays quiet. The
		# name is spelled [d]nsmasq so that this very grep does not have
		# an argument of exactly "dnsmasq" and match itself, and the
		# match is on a whole argument rather than a substring, so that a
		# process merely carrying the word in its arguments is left out.
		_tap_argv=$(cat "${_tap_dir}/cmdline" 2>/dev/null | tr '\0' '\n')
		printf '%s\n' "${_tap_argv}" |
			grep -qx -e '[d]nsmasq' -e '.*/[d]nsmasq' || continue
		_tap_file=$(printf '%s\n' "${_tap_argv}" |
			sed -n 's/^--pid-file=//p')
		_tap_line="${_tap_line}  ${_tap_pid}  ${_tap_file:-wrote no pid file}
"
	done
	[ -n "${_tap_line}" ] || _tap_line="  (none found)
"
	printf '%s' "${_tap_line}"
}


setup_tap () {
	# Nothing to do unless TAP networking was asked for
	if [ "${NETWORK}" != "tap" ]; then
		return 0
	fi

	# Where the pid file goes, as an absolute path, and the working
	# directory it is resolved against. It has to be absolute rather than
	# the relative $WORK_DIR it usually is, because dnsmasq changes
	# directory to / before it writes the pid file. Handed "./.dnsmasq.pid"
	# it writes "/.dnsmasq.pid", which is neither where cleanup_tap looks
	# nor anywhere the box can tidy up, and the dnsmasq goes on holding
	# port 67 against the next run.
	_tap_workdir=$(cd "${WORK_DIR}" 2>/dev/null && pwd) ||
		fail "\$WORK_DIR is '${WORK_DIR}', which is not a directory" \
			"It has to be a path to the directory the box keeps its" \
			"files in, since the DHCP server writes its pid there."
	_tap_pidfile="${_tap_workdir}/.dnsmasq.pid"
	_tap_dnsmasq_log="${_tap_workdir}/.dnsmasq.log"

	# Ask for the password up front: dnsmasq is started in the background,
	# where sudo has no terminal to prompt on
	if [ "$(id -u)" -ne 0 ]; then
		sudo -v || fail "sudo is needed to set up ${TAP_DEVICE}" \
			"Either allow it without a password, or run the box as root."
	fi

	# Remember whether the device was there before, so that only the ones
	# this function creates get removed again
	_tap_created=0
	if ip link show "${TAP_DEVICE}" >/dev/null 2>&1; then
		step "reusing the ${TAP_DEVICE} TAP device"
	else
		step "creating the ${TAP_DEVICE} TAP device"
		if ! _as_root ip tuntap add dev "${TAP_DEVICE}" mode tap \
			user "$(id -un)"; then
			fail "the ${TAP_DEVICE} TAP device could not be created" \
				"Check that /dev/net/tun exists and is writable, and that" \
				"'ip' is installed."
		fi
		_tap_created=1

		if ! _as_root ip addr add "${TAP_ADDRESS}" dev "${TAP_DEVICE}"; then
			fail "${TAP_DEVICE} could not be given the address ${TAP_ADDRESS}"
		fi
		_as_root ip link set "${TAP_DEVICE}" up
		result "${OK_CHAR}" "${TAP_DEVICE} is ready"
	fi

	# A TAP device on its own gives the guest no address and no way out, so
	# run a DHCP server on it and masquerade its traffic. Both need root.
	if ! command -v dnsmasq >/dev/null 2>&1; then
		warn "'dnsmasq' was not found, so the guest will not get an" \
			"address automatically. Install it, or give the guest a" \
			"static one. The TAP device itself is ready."
		return 0
	fi

	# Look at port 67 before starting anything. Only one DHCP server can
	# have it, and the one that loses does not stop: dnsmasq logs "error
	# binding DHCP socket", carries on serving DNS, and stays up looking
	# perfectly healthy while the guest quietly gets no address. Asking
	# now turns that into a plain message naming what is in the way,
	# instead of a socket error the guest then runs into.
	#
	# Only the local address column is looked at. Naming the process needs
	# root, and without it ss prints one column fewer, so the process is
	# taken from the seventh field and simply comes out empty.
	if command -v ss >/dev/null 2>&1; then
		_tap_busy=$(ss -lun 2>/dev/null | awk '$4 ~ /:67$/ { print $4 }')
	else
		_tap_busy=""
	fi
	if [ -n "${_tap_busy}" ]; then
		_tap_who=$(ss -lunp 2>/dev/null | awk '$4 ~ /:67$/ { print $7 }' |
			tr '\n' ' ')
		# ss names a process only for one it owns, and dnsmasq is
		# nobody's, so the column comes back as whitespace rather than
		# as nothing. A name is still better than none, so the fallback
		# is used whenever there is no word in it.
		case "${_tap_who}" in
			*[!\ \	]*) ;;
			*) _tap_who="a dnsmasq, which runs as nobody" ;;
		esac
		fail "port 67 is already in use, so no DHCP server can run" \
			"It is held by: ${_tap_who}" \
			"seen on: ${_tap_busy}" \
			"Usually that is a dnsmasq left over from an earlier run." \
			"The dnsmasq processes on this host are:" \
			"$(_tap_dnsmasq_pids)" \
			"Stop the one holding it with 'sudo kill <pid>'. A dnsmasq" \
			"started by this box is stopped on the way out, so this" \
			"should not happen: a pid file of ./.dnsmasq.pid below is" \
			"the sign of one started by an older build, which handed" \
			"dnsmasq a relative path and left the file at /." \
			"If it is not yours, it is most likely a dnsmasq bound" \
			"to every interface, which cannot be served alongside" \
			"this one. Stop it, or use './raspberry_pi_box.sh -n usb'," \
			"which needs no privileges and no DHCP server at all."
	fi

	step "running a DHCP server on ${TAP_DEVICE}"
	# Build the option list once so it can be syntax checked before use
	set -- --interface="${TAP_DEVICE}" \
		--except-interface=lo \
		--bind-interfaces \
		--dhcp-range=10.0.2.10,10.0.2.200,255.255.255.0,12h \
		--dhcp-host="${GUEST_MAC},${GUEST_IP}" \
		--dhcp-option=3,10.0.2.1 \
		--dhcp-option=6,10.0.2.1 \
		--dhcp-leasefile="${_tap_workdir}/.dnsmasq.leases" \
		--pid-file="${_tap_pidfile}" \
		--keep-in-foreground \
		--log-facility=-
	if ! _as_root dnsmasq --test "$@" >/dev/null 2>&1; then
		fail "the DHCP server options were rejected by dnsmasq" \
			"Run 'dnsmasq --test $*' to see why. dnsmasq 2.76 or" \
			"newer is needed."
	fi
	# Started as root because binding ports 67 and 53 needs it. It keeps
	# running in the foreground, as a background job of this script, and
	# its log is kept so that the check below has something to read.
	_as_root dnsmasq "$@" >"${_tap_dnsmasq_log}" 2>&1 &
	_tap_dnsmasq=$!

	# Wait for it to bind, and check that it actually is serving DHCP.
	# A process being alive proves nothing here: when dnsmasq cannot bind
	# port 67 — because an earlier run left one behind, most often — it
	# logs "error binding DHCP socket" and carries straight on serving
	# DNS, so it stays up and looks healthy while the guest quietly gets
	# no address. What tells the two apart is the startup line, which
	# names the range only once the socket is bound.
	_tap_waited=0
	while [ "${_tap_waited}" -lt 5 ]; do
		if grep -q 'IP range' "${_tap_dnsmasq_log}" 2>/dev/null; then
			break
		fi
		if ! kill -0 "${_tap_dnsmasq}" 2>/dev/null; then
			break
		fi
		sleep 1
		_tap_waited=$((_tap_waited + 1))
	done
	if ! grep -q 'IP range' "${_tap_dnsmasq_log}" 2>/dev/null; then
		_tap_reason=$(sed -n '1,3p' "${_tap_dnsmasq_log}" 2>/dev/null |
			tr '\n' ' ')
		if kill -0 "${_tap_dnsmasq}" 2>/dev/null; then
			fail "dnsmasq did not take port 67 on ${TAP_DEVICE}" \
				"It says: ${_tap_reason:-nothing}" \
				"Almost always this is a dnsmasq left over from an" \
				"earlier run that did not get cleaned up. Find it" \
				"with 'sudo ss -lunp sport = :67' and stop it, or" \
				"reboot to clear it. The box removes its own on the" \
				"way out, so this should not happen."
		fi
		wait "${_tap_dnsmasq}" 2>/dev/null
		_tap_dnsmasq=""
		fail "the DHCP server on ${TAP_DEVICE} could not start" \
			"It says: ${_tap_reason:-nothing}"
	fi

	# Masquerade the guest's traffic so that it can reach the internet
	_tap_nat=0
	_host_iface=$(ip route show default 2>/dev/null |
		awk '{ print $5; exit }')
	if [ -n "${_host_iface}" ]; then
		step "masquerading the guest's traffic via ${_host_iface}"
		# Both of these need root, and both say nothing and fail
		# silently without it, so they are run through _as_root and then
		# looked for. Without the check the box goes on to report that the
		# guest can reach the internet having installed no rule that lets
		# it, and the first sign of that is the guest timing out.
		if command -v nft >/dev/null 2>&1; then
			_as_root nft add table ip qemu-tap 2>/dev/null
			_as_root nft flush table ip qemu-tap 2>/dev/null
			_as_root nft add chain ip qemu-tap post \
				'{ type nat hook postrouting priority 100 ; }' \
				2>/dev/null
			_as_root nft add rule ip qemu-tap post \
				oifname "${_host_iface}" masquerade 2>/dev/null
			if _as_root nft list table ip qemu-tap >/dev/null 2>&1; then
				_tap_nat=1
				_tap_host_iface="${_host_iface}"
			fi
		elif command -v iptables >/dev/null 2>&1; then
			_as_root iptables -t nat -A POSTROUTING \
				-o "${_host_iface}" -j MASQUERADE 2>/dev/null
			_as_root iptables -A FORWARD -i "${TAP_DEVICE}" \
				-j ACCEPT 2>/dev/null
			_as_root iptables -A FORWARD -o "${TAP_DEVICE}" \
				-j ACCEPT 2>/dev/null
			if _as_root iptables -t nat -C POSTROUTING \
				-o "${_host_iface}" -j MASQUERADE \
				>/dev/null 2>&1; then
				_tap_nat=1
				_tap_host_iface="${_host_iface}"
			fi
		fi
		if [ "${_tap_nat}" -eq 1 ]; then
			_as_root sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
			result "${OK_CHAR}" "the guest can now get an address and reach the internet"
		else
			warn "the guest will get an address, but will not reach the internet" \
				"The masquerade rule did not go in, so its traffic is" \
				"not translated. The host interface it would go on is" \
				"${_host_iface}. Both nft and iptables need root for" \
				"this, so check that sudo works for whichever of them" \
				"is installed. The guest is still usable on its own" \
				"network without this."
		fi
	else
		result "${OK_CHAR}" "the guest can now get an address"
	fi

	# From here on the box owns a root process, a network device and some
	# firewall rules, so make sure they go away however this ends: on the
	# normal path when QEMU exits, but also on Ctrl+C, on SIGTERM, and on
	# any of the steps after this one failing. Without this an interrupted
	# run leaves a dnsmasq holding port 67 and a TAP device behind, and
	# the next run then fails to bind with a message about a socket rather
	# than about the leftover that is actually the cause.
	#
	# The signal handlers have to exit themselves. A shell with a trap set
	# for a signal runs the handler and carries on, so without the exit a
	# Ctrl+C would tidy up and then walk straight back into QEMU.
	trap 'cleanup_tap' 0
	trap 'cleanup_tap; exit 129' 1
	trap 'cleanup_tap; exit 130' 2
	trap 'cleanup_tap; exit 143' 15
}

# Remove the TAP device, the DHCP server, and the NAT rules again, if this
# box created them. Runs when QEMU exits, and from the trap above, so it has
# to cope with being run more than once.
cleanup_tap () {
	# The background job is sudo, and a sudo that is killed without passing
	# the signal on leaves the dnsmasq it started running as nobody, still
	# holding port 67. So nothing is stopped by job number: every process
	# running this box's dnsmasq is found and stopped, which is the dnsmasq
	# itself and each sudo in front of it.
	#
	# They are found by the pid file path in their own command line, which
	# is in /proc and readable by anyone. That is more reliable than the pid
	# file dnsmasq writes, which it only writes after changing directory to
	# /, and it is what makes this work even if the pid file has been
	# deleted or never written.
	if [ -n "${_tap_dnsmasq}" ]; then
		kill "${_tap_dnsmasq}" 2>/dev/null
	fi
	# Only when a pid file was asked for, which is only when dnsmasq was
	# started at all. Without this the marker would be "--pid-file=" and
	# the scan would be looking for any dnsmasq on the host that was
	# given an empty pid file, which is nobody's dnsmasq but ours.
	if [ -n "${_tap_pidfile}" ]; then
		_tap_marker="--pid-file=${_tap_pidfile}"
		_tap_round=0
		while [ "${_tap_round}" -lt 3 ]; do
			_tap_pids=""
			for _tap_dir in /proc/[0-9]*; do
				_tap_pid=${_tap_dir#/proc/}
				# pid 1 is init, and is never anybody's dnsmasq
				[ "${_tap_pid}" -gt 1 ] 2>/dev/null || continue
				# Read with cat rather than with a redirection on tr,
				# since a process that exits between the glob above and
				# the read here makes the shell itself complain, and
				# that is not something a redirection on the command
				# can silence. -e is needed because the marker starts
				# with "--", which grep would take for one of its own
				# options.
				if cat "${_tap_dir}/cmdline" 2>/dev/null |
					tr '\0' '\n' | grep -qxF -e "${_tap_marker}"; then
					_tap_pids="${_tap_pids} ${_tap_pid}"
				fi
			done
			[ -n "${_tap_pids}" ] || break
			# a polite request first, and a kill for whatever is still
			# there on the next round, since a dnsmasq that ignores
			# SIGTERM is a real thing and the point of this is that the
			# port is let go
			if [ "${_tap_round}" -eq 0 ]; then
				# shellcheck disable=SC2086  # a list of pids, on purpose
				_as_root_now kill ${_tap_pids} 2>/dev/null
			else
				# shellcheck disable=SC2086  # likewise
				_as_root_now kill -9 ${_tap_pids} 2>/dev/null
			fi
			sleep 1
			_tap_round=$((_tap_round + 1))
		done
		# Reaped once it is dead, so that this returns rather than waiting
		# for a dnsmasq that has not noticed it is being asked to leave
		if [ -n "${_tap_dnsmasq}" ]; then
			wait "${_tap_dnsmasq}" 2>/dev/null
			_tap_dnsmasq=""
		fi
		rm -f "${_tap_pidfile}"
	fi
	if [ "${_tap_nat}" -eq 1 ] 2>/dev/null; then
		if command -v nft >/dev/null 2>&1; then
			_as_root_now nft delete table ip qemu-tap 2>/dev/null
		elif command -v iptables >/dev/null 2>&1; then
			_as_root_now iptables -t nat -D POSTROUTING \
				-o "${_tap_host_iface}" -j MASQUERADE 2>/dev/null
			_as_root_now iptables -D FORWARD -i "${TAP_DEVICE}" \
				-j ACCEPT 2>/dev/null
			_as_root_now iptables -D FORWARD -o "${TAP_DEVICE}" \
				-j ACCEPT 2>/dev/null
		fi
		_tap_nat=0
	fi
	if [ "${_tap_created}" -eq 1 ] && [ "${TAP_CLEANUP}" = "on" ]; then
		_as_root_now ip link delete "${TAP_DEVICE}" 2>/dev/null
		_tap_created=0
	fi
}


#
# ==== Building the Rust kernel module ====
#
# The kernel is built from source first, with Rust support switched on, so
# that the module and the kernel it is loaded into are the same one. Both
# live in $WORK_DIR, and the kernel is only built once.


#
# ==== Enabling ssh in the guest ====
#
# RPi OS only starts the ssh daemon when an empty file named 'ssh' is present
# in the boot partition of the image, so that is what makes it reachable. The
# partition is the first one in the image, starting 4 MiB in, and mtools
# writes to it without needing root.
BOOT_OFFSET=4194304
MCOPY="mcopy"

enable_ssh () {
	if ! command -v "${MCOPY}" >/dev/null 2>&1; then
		warn "'${MCOPY}' was not found, so sshd will not be enabled" \
			"RPi OS only starts ssh when an empty file named 'ssh' is" \
			"in the boot partition. Install mtools, or create it by" \
			"hand: mcopy -o -i ${IMAGE_NAME}@@${BOOT_OFFSET} - ::ssh" \
			"< /dev/null"
		return 0
	fi

	step "enabling sshd in the boot partition"
	: > "${WORK_DIR}/.ssh"
	if ! "${MCOPY}" -o -i "${WORK_DIR}/${IMAGE_NAME}@@${BOOT_OFFSET}" \
		"${WORK_DIR}/.ssh" ::ssh; then
		rm -f "${WORK_DIR}/.ssh"
		fail "the boot partition of ${IMAGE_NAME} could not be written" \
			"sshd will not be enabled. Check that \$MCOPY points at a" \
			"working mcopy(1)."
	fi
	rm -f "${WORK_DIR}/.ssh"
	result "${OK_CHAR}" "the guest will start sshd"
}


# Whether the kernel tree in $1 is extracted in full. An interrupted
# download or extraction leaves a directory that is there but incomplete, and
# building that fails with errors that blame the missing files rather than the
# truncated tarball. The files below only exist in a complete tree, so they
# are what to look for.
kernel_tree_extracted () {
	[ -f "$1/Makefile" ] &&
	[ -f "$1/scripts/config" ] &&
	[ -f "$1/scripts/kconfig/merge_config.sh" ] &&
	[ -f "$1/kernel/configs/kvm_guest.config" ]
}

# Whether the kernel in $1 is built and usable as it stands, so that the
# build can be skipped. The options the box needs count towards that: a
# kernel without them is not the kernel this box asked for, and configuring
# it again is a good deal quicker than explaining the failure afterwards.
kernel_ready () {
	[ -f "$1/arch/arm64/boot/Image" ] &&
		grep -q '^CONFIG_RUST=y$' "$1/.config" 2>/dev/null &&
		kernel_check_options "$1" "${KERNEL_OPTIONS}" 2>/dev/null
}

# The path the device tree blob ends up at, inside the kernel tree in $1.
# $KERNEL_DTB is a make target, and it carries the vendor subdirectory the
# blob is built in, so it is used whole: the output lands under the same
# subdirectory of arch/arm64/boot/dts.
kernel_dtb_path () {
	printf '%s/arch/arm64/boot/dts/%s' "$1" "${KERNEL_DTB}"
}

# Build the device tree blob for the board, if it is not there yet. It is a
# separate step from the kernel proper, and a separate make target, so a tree
# that has been built is not always a tree whose blob has been.
kernel_dtb () {
	_dtb="$(kernel_dtb_path "$1")"
	if [ -f "${_dtb}" ]; then
		return 0
	fi
	step "building the device tree blob, ${KERNEL_DTB}"
	if ! make -C "$1" ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" \
		"${KERNEL_DTB}" >/dev/null; then
		fail "the device tree blob ${KERNEL_DTB} could not be built" \
			"It comes out of the kernel tree in $1, and that" \
			"directory has to be a configured one. Run 'make -C $1" \
			"ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} ${KERNEL_DTB}'" \
			"by hand to see why. \$KERNEL_DTB is set to" \
			"'${KERNEL_DTB}'; the board is described by a blob in" \
			"arch/arm64/boot/dts/broadcom/."
	fi
	if ! [ -f "${_dtb}" ]; then
		fail "${KERNEL_DTB##*/} is not in the kernel tree at ${_dtb}" \
			"Make said it was built, but it is not there."
	fi
}

# Add each 'SYMBOL=value' line of $2 to the .config in $1. scripts/config
# only rewrites the file, so it is the caller's job to run olddefconfig
# afterwards to work out what else has to change.
kernel_set_options () {
	while read -r _opt; do
		case "${_opt}" in
			'' | '#'*) continue ;;
		esac
		if ! "$1/scripts/config" --file "$1/.config" \
			--set-val "${_opt%%=*}" "${_opt#*=}"; then
			fail "${_opt%%=*} could not be set in the kernel" \
				"Edit \$KERNEL_OPTIONS in this script and run this" \
				"again."
		fi
	done <<EOF
$2
EOF
}

# Switch off each symbol named on its own line in $2, in the .config in $1.
# scripts/config writes the line even for a symbol the kernel has never heard
# of, and kconfig then drops it again without a word, so a list of everything
# that might need switching off works on any kernel version.
kernel_unset_options () {
	while read -r _opt; do
		case "${_opt}" in
			'' | '#'*) continue ;;
		esac
		if ! "$1/scripts/config" --file "$1/.config" --disable "${_opt}"; then
			fail "${_opt} could not be switched off in the kernel" \
				"Edit \$KERNEL_OPTIONS_OFF in this script and run" \
				"it again."
		fi
	done <<EOF
$2
EOF
}

# Check that every 'SYMBOL=value' line of $2 is still set in the .config in
# $1. olddefconfig quietly drops whatever it cannot satisfy, and the only sign
# of that is a build failure a long way from here. This says nothing and just
# returns non-zero, leaving the offending line in $_kernel_missing for the
# caller to report, so that it can also be used as a plain test.
kernel_check_options () {
	_kernel_missing=""
	while read -r _opt; do
		case "${_opt}" in
			'' | '#'*) continue ;;
		esac
		if ! grep -q "^${_opt}\$" "$1/.config" 2>/dev/null; then
			_kernel_missing="${_opt}"
			return 1
		fi
	done <<EOF
$2
EOF
}


build () {
	section "Raspberry Pi OS Lite box" "build · compile the Rust kernel module"

	# 1. Work out where the kernel is, and build it if it is not there yet
	if [ -n "${KERNEL_SRC}" ]; then
		# a source tree the user already has: use it as it stands
		kernel_dir="${KERNEL_SRC}"
		step "using the kernel source in ${kernel_dir}"
	elif kernel_ready "${WORK_DIR}/linux-${KERNEL_VERSION}"; then
		kernel_dir="${WORK_DIR}/linux-${KERNEL_VERSION}"
		step "reusing the linux ${KERNEL_VERSION} kernel found in ${WORK_DIR}"
		result "${OK_CHAR}" "no kernel build needed"
	else
		kernel_dir="${WORK_DIR}/linux-${KERNEL_VERSION}"
		step "building linux ${KERNEL_VERSION} (${KERNEL_DEFCONFIG})"
		step "this takes a while, and only happens once"

		archive="${WORK_DIR}/linux-${KERNEL_VERSION}.tar.xz"
		src="${WORK_DIR}/linux-${KERNEL_VERSION}"

		# Download the tarball if it is not there, and make sure it is
		# usable — a partial download from an earlier run would otherwise
		# leave a broken tree that fails later with a confusing error
		if ! [ -f "${archive}" ] || ! tar -tJf "${archive}" >/dev/null 2>&1; then
			rm -f "${archive}"
			fetch "${KERNEL_URL}" "${archive}"
			if ! tar -tJf "${archive}" >/dev/null 2>&1; then
				fail "the linux ${KERNEL_VERSION} tarball is corrupted" \
					"Delete ${archive} and run this again."
			fi
		fi

		# Extract it if it is not there — or is only half there. An
		# interrupted download or extraction leaves a directory that is
		# there but incomplete, and building that fails with errors that
		# point at the wrong thing entirely.
		if ! kernel_tree_extracted "${src}"; then
			step "extracting linux ${KERNEL_VERSION}"
			rm -rf "${src}"
			if ! tar -xJf "${archive}" -C "${WORK_DIR}"; then
				fail "the linux ${KERNEL_VERSION} tree could not be" \
					"extracted" \
					"There may not be enough room in ${WORK_DIR} for" \
					"it. Free some up, delete ${src}, and run this" \
					"again."
			fi
		fi

		# 1.1. Configure, in the order the kernel's build system wants it.
		#      A defconfig has to come first: kvm_guest.config is a merge
		#      target, and merge_config.sh reads the .config it merges into,
		#      so without one it stops with "The base file '.config' does
		#      not exist".
		step "configuring linux ${KERNEL_VERSION}"
		if ! make -C "${src}" ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" \
			"${KERNEL_DEFCONFIG}" >/dev/null; then
			fail "linux ${KERNEL_VERSION} could not be configured" \
				"Check that \$CROSS_COMPILE ('${CROSS_COMPILE}') points" \
				"at a working cross compiler, and that 'make', 'flex'" \
				"and 'bison' are installed. \$KERNEL_DEFCONFIG is set to" \
				"'${KERNEL_DEFCONFIG}'."
		fi
		# The KVM guest settings, from kernel/configs/kvm_guest.config
		if ! make -C "${src}" ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" \
			kvm_guest.config >/dev/null; then
			fail "the KVM guest settings could not be applied to" \
				"linux ${KERNEL_VERSION}" \
				"Run 'make -C ${src} ARCH=arm64" \
				"CROSS_COMPILE=${CROSS_COMPILE} kvm_guest.config' by" \
				"hand to see why."
		fi
		# What the box needs on top of those
		kernel_set_options "${src}" "${KERNEL_OPTIONS}"
		# Then Rust, for the module: the things it cannot be built
		# alongside go first, and the box checks afterwards that
		# CONFIG_RUST really made it in
		kernel_unset_options "${src}" "${KERNEL_OPTIONS_OFF}"
		kernel_set_options "${src}" "CONFIG_RUST=y"
		# olddefconfig then works out what else has to change to satisfy
		# all of it
		if ! make -C "${src}" ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" \
			olddefconfig >/dev/null; then
			fail "linux ${KERNEL_VERSION} could not be configured" \
				"Run 'make -C ${src} ARCH=arm64" \
				"CROSS_COMPILE=${CROSS_COMPILE} olddefconfig' by hand" \
				"to see why."
		fi

		# 1.2. olddefconfig drops any option it cannot satisfy. Say so now,
		#      while the reason is still known, rather than much later as a
		#      module build that cannot make sense of itself.
		if ! grep -q '^CONFIG_RUST=y$' "${src}/.config"; then
			fail "CONFIG_RUST could not be enabled in the kernel" \
				"kconfig drops an option it cannot satisfy, and says" \
				"nothing about which dependency was the problem." \
				"Three things can be:" \
				"  - the kernel is too old. CONFIG_RUST needs" \
				"    HAVE_RUST, and arm64 only selects that from 6.9." \
				"    \$KERNEL_VERSION is '${KERNEL_VERSION}'." \
				"  - no Rust toolchain. 'make -C ${src} ARCH=arm64" \
				"    CROSS_COMPILE=${CROSS_COMPILE} rustavailable'" \
				"    says what is wrong with the one you have." \
				"  - something else is on that CONFIG_RUST refuses to" \
				"    be built with. \${MODVERSIONS}, \${LTO} and" \
				"    \${DEBUG_INFO_BTF} all do; add it to" \
				"    \$KERNEL_OPTIONS_OFF and run this again."
		fi
		if ! kernel_check_options "${src}" "${KERNEL_OPTIONS}"; then
			fail "${_kernel_missing%%=*} is not set to" \
				"${_kernel_missing#*=} in the kernel" \
				"Linux ${KERNEL_VERSION} dropped it, most likely" \
				"because something it depends on is missing. Edit" \
				"\$KERNEL_OPTIONS in this script and run this again."
		fi

		# 1.3. Build it
		if ! make -C "${src}" ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" \
			-j"$(nproc)" >/dev/null; then
			fail "linux ${KERNEL_VERSION} could not be built" \
				"Check that \$CROSS_COMPILE ('${CROSS_COMPILE}') points" \
				"at a working cross compiler, and that 'make', 'flex'," \
				"'bison' and the OpenSSL headers are installed."
		fi
		result "${OK_CHAR}" "the kernel is ready"
	fi

	# 2. Make sure the tree is prepared to build external modules against,
	#    whether it was built here or pointed at by $KERNEL_SRC
	if ! [ -f "${kernel_dir}/include/generated/compile.h" ]; then
		step "preparing the kernel for external modules"
		if ! make -C "${kernel_dir}" ARCH=arm64 \
			CROSS_COMPILE="${CROSS_COMPILE}" modules_prepare >/dev/null; then
			fail "the kernel in ${kernel_dir} could not be prepared" \
				"It may need configuring first. Run 'make -C" \
				"${kernel_dir} ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE}" \
				"modules_prepare' by hand to see why."
		fi
	fi

	# 3. The device tree blob, out of the same tree, so that it describes the
	#    board to this exact kernel. It is built whether or not the kernel
	#    itself was, as $KERNEL_SRC may well be a tree built elsewhere
	kernel_dtb "${kernel_dir}"

	# 4. Build the modules against it
	step "building the Rust kernel modules"
	if ! make Kdir="${kernel_dir}" >/dev/null; then
		fail "the Rust kernel modules could not be built" \
			"Run 'make Kdir=${kernel_dir}' by hand to see the compiler" \
			"output."
	fi
	result "${OK_CHAR}" "the modules are ready"
}


#
# ==== Booting process ====
#
boot () {
	section "Raspberry Pi OS Lite box" "boot · power on the virtual machine"

	kernel_dir="${WORK_DIR}/linux-${KERNEL_VERSION}"
	if [ -n "${KERNEL_SRC}" ]; then
		kernel_dir="${KERNEL_SRC}"
	fi
	if [ ! -f "${kernel_dir}/arch/arm64/boot/Image" ]; then
		fail "there is no kernel to boot" \
			"Run './raspberry_pi_box.sh build' first."
	fi
	# The blob is what tells the kernel what hardware it is on and where its
	# console is, so booting without it produces a guest that says nothing at
	# all, which is hard to tell from a box that booted and hung
	dtb="$(kernel_dtb_path "${kernel_dir}")"
	if [ ! -f "${dtb}" ]; then
		fail "the kernel in ${kernel_dir} has no device tree blob" \
			"${KERNEL_DTB##*/} is missing from it, and without it" \
			"the guest has no console. Run './raspberry_pi_box.sh" \
			"build' to make it."
	fi

	step "starting ${QEMU_BIN} (${MACHINE}, ${QEMU_CPU}, ${QEMU_RAM})"
	if [ "${DEBUG}" -eq 1 ]; then
		section "Debug mode" "the cpu is halted, gdb is expected on :1234"
		note "attach with: 'gdb', 'target remote :1234', then 'continue'"
	else
		note "quit QEMU with Ctrl+A, then X"
		if [ -n "${GUEST_PASSWORD}" ]; then
			note "log in as '${GUEST_USER}' with \$GUEST_PASSWORD"
		else
			note "the image has no working credentials: '${GUEST_USER}' is"
			note "locked, so the login prompt turns down any password"
			note "set \$GUEST_PASSWORD in this script to have one set for you"
		fi
	fi

	# Halt the cpu and wait for a gdb client when debugging, and set up
	# networking if it was asked for
	if [ "${DEBUG}" -eq 1 ]; then
		set -- -S -gdb tcp::1234
	fi
	case "${NETWORK}" in
		none) ;;
		usb)
			set -- "$@" -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
				-device "usb-net,netdev=net0"
			;;
		tap)
			set -- "$@" -netdev "tap,id=net0,ifname=${TAP_DEVICE},script=no,downscript=no" \
				-device "usb-net,netdev=net0,mac=${GUEST_MAC}"
			;;
		*)
			fail "unknown \$NETWORK '${NETWORK}'" \
				"Expected 'none', 'usb', or 'tap'. See README.md."
			;;
	esac

	# Say exactly how to reach the guest, as the last thing before QEMU takes
	# over the terminal
	blank
	case "${NETWORK}" in
		tap)
			paragraph "Connect to the guest with: ssh ${GUEST_USER}@${GUEST_IP}"
			note "wait for the guest to boot — sshd only starts once it's up"
			;;
		usb)
			paragraph "Connect to the guest with: ssh -p ${SSH_PORT} ${GUEST_USER}@localhost"
			note "wait for the guest to boot — sshd only starts once it's up"
			;;
		*)
			paragraph "The guest is reachable on the serial console only"
			;;
	esac

	"${QEMU_BIN}" \
		-machine "${MACHINE}" \
		-cpu "${QEMU_CPU}" \
		-smp "${QEMU_CPUS}" \
		-m "${QEMU_RAM}" \
		-kernel "${kernel_dir}/arch/arm64/boot/Image" \
		-dtb "${dtb}" \
		-drive "file=${WORK_DIR}/${IMAGE_NAME},format=raw,if=sd,index=0" \
		-append "${KERNEL_CMDLINE}" \
		-nographic \
		"$@"

	cleanup_tap
}


#
# ==== Help message ====
#
usage () {
	section "Raspberry Pi OS Lite box" "build and boot Raspberry Pi OS Lite (aarch64)"

	printf '  %s\n' "Usage: ./raspberry_pi_box.sh [-s|--setup] [-b|--boot]"
	printf '  %s\n' "                              [-d|--debug] [-h|--help]"
	printf '  %s\n' "                              [-n|--network MODE] [build]"

	printf '\n'
	printf '  %s\n' "Options:"
	printf '    %-14s %s\n' "build" "compile the Rust kernel module and stop"
	printf '    %-14s %s\n' "-s, --setup" "download the files and stop"
	printf '    %-14s %s\n' "-b, --boot" "download, build, and boot [default]"
	printf '    %-14s %s\n' "-d, --debug" "boot with the cpu halted, for gdb"
	printf '    %-14s %s\n' "-n, --network" "none, usb, or tap [default: none]"
	printf '    %-14s %s\n' "-h, --help" "print this help message"
	note "only the first option is taken into account"

	printf '\n'
	printf '  %s\n' "Settings:"
	setting "\$MACHINE" "emulated board" "${MACHINE}"
	setting "\$QEMU_CPU" "emulated cpu" "${QEMU_CPU}"
	setting "\$QEMU_CPUS" "number of cpus" "${QEMU_CPUS}"
	setting "\$QEMU_RAM" "guest memory" "${QEMU_RAM}"
	setting "\$NETWORK" "networking to use" "${NETWORK}"
	setting "\$TAP_DEVICE" "tap device, if any" "${TAP_DEVICE}"
	setting "\$TAP_ADDRESS" "its address" "${TAP_ADDRESS}"
	setting "\$GUEST_IP" "the guest's address" "${GUEST_IP}"
	setting "\$GUEST_MAC" "its MAC" "${GUEST_MAC}"
	setting "\$TAP_CLEANUP" "remove it on exit" "${TAP_CLEANUP}"
	setting "\$SSH_PORT" "host ssh port" "${SSH_PORT}"
	setting "\$KERNEL_DTB" "device tree blob" "${KERNEL_DTB}"
	setting "\$IMAGE_NAME" "disk image" "${IMAGE_NAME}"
	setting "\$KERNEL_VERSION" "kernel to build" "${KERNEL_VERSION}"
	setting "\$KERNEL_URL" "its tarball" "${KERNEL_URL}"
	setting "\$KERNEL_SRC" "a source tree to use instead" "${KERNEL_SRC:-not set}"
	setting "\$KERNEL_DEFCONFIG" "its base configuration" "${KERNEL_DEFCONFIG}"
	setting "\$KERNEL_OPTIONS" "options the box needs" "$(printf '%s\n' "${KERNEL_OPTIONS}" | grep -c .) in the script"
	setting "\$KERNEL_OPTIONS_OFF" "options it needs off" "$(printf '%s\n' "${KERNEL_OPTIONS_OFF}" | grep -c .) in the script"
	setting "\$CROSS_COMPILE" "cross compiler prefix" "${CROSS_COMPILE}"
	setting "\$MCOPY" "tool that writes the boot partition" "${MCOPY}"
	setting "\$RUST_TARGET" "cargo target" "${RUST_TARGET}"
	setting "\$GUEST_USER" "guest account" "${GUEST_USER}"
	setting "\$GUEST_UNITS_TO_MASK" "guest units to mask" \
		"$(printf '%s\n' "${GUEST_UNITS_TO_MASK}" | grep -c .) in the script"
	# The password, and its hash, are never printed
	if [ -n "${GUEST_PASSWORD}" ]; then
		setting "\$GUEST_PASSWORD" "its password" "set"
	else
		setting "\$GUEST_PASSWORD" "its password" "not set"
	fi

	printf '\n'
	paragraph "The Rust kernel module is built against a kernel compiled from" \
		"source, so that the two always match. Set \$KERNEL_VERSION to move" \
		"to another kernel, \$KERNEL_SRC to use a tree you already have, and" \
		"\$GUEST_PASSWORD to be able to log in."
	paragraph "Before changing \$KERNEL_VERSION, read \"Why this kernel\" in" \
		"README.md: the kernel builds its own core from your rustc's" \
		"sources, so the two versions have to suit each other, and an" \
		"older kernel fails on your toolchain's code rather than on" \
		"anything in the kernel."
}


#
# ==== Entry point ====
#
DEBUG=0
# Set by setup_tap, read by cleanup_tap; initialised here so that the latter
# never tests an unset variable
_tap_created=0
_tap_nat=0
_tap_dnsmasq=""
# Written by setup_tap, read by cleanup_tap; initialised here so that the
# latter never looks for an unset path when the box never set one up
_tap_pidfile=""

# Argument matching
while [ "$#" -gt 0 ]; do
	arg="$1"
	case "$arg" in
		-d|--debug)
			setup
			set_password
			mask_guest_unit
			enable_ssh
			setup_tap
			build
			DEBUG=1
			boot
			exit 0
			;;
		-b|--boot)
			setup
			set_password
			mask_guest_unit
			enable_ssh
			setup_tap
			build
			DEBUG=0
			boot
			exit 0
			;;
		-n|--network)
			if [ "$#" -lt 2 ]; then
				fail "-n|--network needs an argument: none|usb|tap"
			fi
			NETWORK="$2"
			shift 2
			;;
		-s|--setup)
			setup
			exit 0
			;;
		build)
			build
			exit 0
			;;
		--help|-h|*)
			case "$arg" in
				--help|-h) ;;
				*) printf 'unknown option: %s\n' "${arg}" >&2 ;;
			esac
			usage
			exit 0
			;;
	esac
done


# [-b | --boot] is the default argument
if [ $# -eq 0 ]; then
	setup
	set_password
	mask_guest_unit
	enable_ssh
	setup_tap
	build
	boot
fi
