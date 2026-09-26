#!/usr/bin/env sh

# Setup and boot a Raspberry Pi OS Lite virtual machine (aarch64).
#
# QEMU does not emulate the Raspberry Pi hardware, so the board is only
# good enough to run a Linux kernel: the disk image is accompanied by a
# kernel and a device tree blob built for the emulated machine, and the
# guest is told where to look for its root filesystem.

# Output helpers, shared with every box in this repository
# shellcheck source=lib/output.sh
. "$(dirname "$0")/../../lib/output.sh"

# Where the image, the kernel, and the device tree blob are stored
WORK_DIR="."
# Image details
IMAGE_NAME="raspios_lite_arm64.img"
IMAGE_ARCHIVE="raspios_lite_arm64.img.xz"
IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-03-15/2024-03-15-raspios-bookworm-arm64-lite.img.xz"
# Checksum published next to the image; set it to "" to skip the check
IMAGE_SHA256_URL="${IMAGE_URL}.sha256"
# Kernel and device tree blob, as expected by the machine set below
KERNEL_NAME="kernel8.img"
KERNEL_URL="https://raw.githubusercontent.com/dhruvvyas90/qemu-rpi-kernel/master/native-emulation/5.4.51%20kernels/kernel8.img"
DTB_NAME="bcm2710-rpi-3-b-plus.dtb"
DTB_URL="https://raw.githubusercontent.com/dhruvvyas90/qemu-rpi-kernel/master/native-emulation/dtbs/${DTB_NAME}"
# Performance-related
QEMU_RAM="1G"
QEMU_CPUS="4"
# Connection details
#
# The board emulated here has no PCI network card, so the guest is given
# QEMU's USB network adapter instead, which the kernel and the device tree
# blob above do describe. This also forwards the guest's ssh port.
SSH_PORT=2222
# Guest credentials
#
# The image ships with every account locked, so the login prompt is of no use
# until a password is set. Set $GUEST_PASSWORD and the box writes that
# password straight into /etc/shadow in the image, before the first boot.
# Leave it empty and the guest stays locked (README.md explains why).
GUEST_USER="pi"
GUEST_PASSWORD="pi"
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
# Miscellaneous
QEMU_BIN="qemu-system-aarch64"
MACHINE="raspi3b"
QEMU_CPU="cortex-a72"
# rootdelay gives the emulated card a moment to show up before the kernel
# goes looking for the root filesystem, and the console baud rate is spelled
# out because the getty on the other end of the line expects it
KERNEL_CMDLINE="rw earlyprintk console=ttyAMA0,115200 root=/dev/mmcblk0p2 rootdelay=1"


#
# ==== Setting the guest password ====
#
# Set the password of a guest account by rewriting /etc/shadow in the image.
# It is done from the host, offline, rather than by leaving a file for the
# guest to pick up at boot: the provisioning service of the image wants a
# console this box has none of, and so never gets to apply anything here.
# Needs roughly as much free space as the root partition is big.
set_password () {
	_image="${WORK_DIR}/${IMAGE_NAME}"
	_part="${WORK_DIR}/.rootfs.img"
	_shadow="${WORK_DIR}/.shadow"
	trap 'rm -f "${_part}" "${_shadow}" "${_shadow}.new"' 0

	# 1. Work out where the root filesystem starts inside the image
	_offset="${ROOTFS_OFFSET}"
	if command -v "${SFDISK}" >/dev/null 2>&1; then
		_detected=$("${SFDISK}" -d "${_image}" 2>/dev/null |
			awk -F'[ \t:]+' '$2 == "start=" { n++; if (n == 2) {
				gsub(/,/, "", $3); print $3 * 512; exit } }')
		if [ -n "${_detected}" ] && [ "${_detected}" -gt 0 ]; then
			_offset="${_detected}"
		fi
	fi
	if [ $((_offset % 1048576)) -ne 0 ]; then
		fail "the root filesystem does not start on a MiB boundary" \
			"${_offset} bytes into ${IMAGE_NAME} is not a multiple of" \
			"1 MiB, which is what cutting it out in big blocks needs."
	fi

	# The magic number of an ext4 superblock (0xef53, 61267 once read as
	# a little-endian 16-bit number) sits 1080 bytes into the partition,
	# so this catches a wrong offset before anything is written
	if [ "$("${DD}" if="${_image}" bs=1 skip=$((_offset + 1080)) \
		count=2 2>/dev/null | od -An -tu2 2>/dev/null | tr -d ' ')" \
		!= "61267" ]; then
		fail "there is no ext4 filesystem at offset ${_offset}" \
			"${IMAGE_NAME} is not the image this script expects, or" \
			"\$ROOTFS_OFFSET needs to be fixed."
	fi

	# 2. Cut the partition out, as there has to be room for a copy of it
	_needed=$(($(wc -c < "${_image}") - _offset))
	_free=$(df -Pk "${WORK_DIR}" 2>/dev/null | awk 'NR == 2 { print $4 }')
	if [ -z "${_free}" ] || [ "${_free}" -lt $((_needed / 1024)) ]; then
		fail "not enough free space in ${WORK_DIR}" \
			"Rewriting the password needs a temporary copy of the root" \
			"partition, about $((_needed / 1048576)) MiB of free space," \
			"and only $((_free / 1024)) MiB are available."
	fi

	step "cutting the root filesystem out of ${IMAGE_NAME}"
	if ! "${DD}" if="${_image}" of="${_part}" bs=1048576 \
		skip=$((_offset / 1048576)) 2>/dev/null; then
		fail "the root filesystem could not be cut out of ${IMAGE_NAME}" \
			"That usually means the copy did not fit in ${WORK_DIR}," \
			"which needs about $((_needed / 1048576)) MiB free."
	fi
	if ! "${DEBUGFS}" -R "stats" "${_part}" >/dev/null 2>&1; then
		fail "the copy of the root filesystem at ${_part} is not readable" \
			"Check that \$DEBUGFS ('${DEBUGFS}') is a working" \
			"debugfs(8), from the e2fsprogs package."
	fi

	# 3. Note what /etc/shadow looks like, as the file gets replaced whole
	# and its owner and mode have to be put back afterwards
	_meta=$("${DEBUGFS}" -R "stat /etc/shadow" "${_part}" 2>/dev/null |
		awk '{
			for (i = 1; i < NF; i++) {
				if ($i == "Mode:") mode = $(i + 1)
				if ($i == "User:") user = $(i + 1)
				if ($i == "Group:") group = $(i + 1)
			}
		} END { print mode, user, group }')
	# shellcheck disable=SC2086  # deliberate split into mode, user, group
	set -- ${_meta}
	_mode="$1"
	_uid="$2"
	_gid="$3"
	if [ -z "${_mode}" ] || [ -z "${_uid}" ] || [ -z "${_gid}" ]; then
		fail "/etc/shadow could not be inspected in ${IMAGE_NAME}" \
			"The copy of the root filesystem at ${_part} does not seem" \
			"to be readable by \$DEBUGFS ('${DEBUGFS}')."
	fi

	"${DEBUGFS}" -R "cat /etc/shadow" "${_part}" 2>/dev/null > "${_shadow}"
	if ! grep -q "^${GUEST_USER}:" "${_shadow}"; then
		# Say who the first user of the guest actually is, as the stock
		# 'pi' may well have been renamed by a first-boot of the image
		_first=$("${DEBUGFS}" -R "cat /etc/passwd" "${_part}" 2>/dev/null |
			awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }')
		if [ -n "${_first}" ] && [ "${_first}" != "${GUEST_USER}" ]; then
			fail "'${GUEST_USER}' is not an account of this guest" \
				"Its first user account is called '${_first}' instead." \
				"Set \$GUEST_USER to '${_first}' and run this again, or" \
				"delete ${IMAGE_NAME} to start from a fresh image, whose" \
				"account is called 'pi'."
		fi
		fail "'${GUEST_USER}' is not an account of this guest" \
			"/etc/shadow holds no such user. Pick another \$GUEST_USER," \
			"or see README.md for the alternatives."
	fi

	# 4. Swap the hash, keeping the rest of the line, and stamp today's day
	# count so that the password is not read as having been set in 1970
	# shellcheck disable=SC2086  # $PASSWORD_HASH may hold arguments
	_hash=$(${PASSWORD_HASH} "${GUEST_PASSWORD}" 2>/dev/null)
	case "${_hash}" in
		'$'*) ;;
		*)
			fail "the password was not hashed" \
				"\$PASSWORD_HASH ('${PASSWORD_HASH}') is what turns it" \
				"into the crypt(3) hash the shadow file wants, and it" \
				"returned '${_hash:-nothing}'. Check that it works, or" \
				"see README.md."
			;;
	esac

	if ! awk -F: -v OFS=: -v u="${GUEST_USER}" -v h="${_hash}" \
		-v d=$(($(date +%s) / 86400)) \
		'$1 == u { $2 = h; $3 = d } { print }' "${_shadow}" \
		> "${_shadow}.new"; then
		fail "the new ${_shadow##*/} could not be written"
	fi

	step "giving ${GUEST_USER} the password in /etc/shadow"
	if ! "${DEBUGFS}" -w -R "rm /etc/shadow" "${_part}" >/dev/null 2>&1 ||
		! "${DEBUGFS}" -w -R "write ${_shadow}.new /etc/shadow" \
			"${_part}" >/dev/null 2>&1; then
		fail "/etc/shadow could not be replaced in the copy at ${_part}"
	fi
	# put back what rm+write lost, and let debugfs fix up the inode checksum
	"${DEBUGFS}" -w -R "set_inode_field /etc/shadow uid ${_uid}" \
		"${_part}" >/dev/null 2>&1
	"${DEBUGFS}" -w -R "set_inode_field /etc/shadow gid ${_gid}" \
		"${_part}" >/dev/null 2>&1
	# the mode is wanted as 0<type><permissions>, e.g. 0100640 for a
	# regular file with rw-r-----: debugfs wants the octal digits only
	"${DEBUGFS}" -w -R "set_inode_field /etc/shadow mode 0100${_mode#0}" \
		"${_part}" >/dev/null 2>&1

	# 5. Read it back: the file is only useful if it is really in there
	_hash_back=$("${DEBUGFS}" -R "cat /etc/shadow" "${_part}" 2>/dev/null |
		awk -F: -v u="${GUEST_USER}" '$1 == u { print $2; exit }')
	_mode_back=$("${DEBUGFS}" -R "stat /etc/shadow" "${_part}" 2>/dev/null |
		awk '{ for (i = 1; i < NF; i++) if ($i == "Mode:") print $(i + 1) }')
	if [ "${_hash_back}" != "${_hash}" ] || [ "${_mode_back}" != "${_mode}" ]; then
		fail "/etc/shadow was not written the way it was meant to be" \
			"${GUEST_USER} hashes to '${_hash_back:-nothing}' and the file" \
			"is mode '${_mode_back:-nothing}' instead of '${_mode}'."
	fi
	result "${OK_CHAR}" "${GUEST_USER} will be able to log in with it"

	# 6. Put the partition back where it came from
	step "writing the root filesystem back into ${IMAGE_NAME}"
	if ! "${DD}" if="${_part}" of="${_image}" bs=1048576 \
		seek=$((_offset / 1048576)) conv=notrunc 2>/dev/null; then
		fail "the root filesystem could not be written back" \
			"${IMAGE_NAME} may be damaged; the untouched copy is at" \
			"${_part}, do not delete it."
	fi
}


#
# ==== Setting things up ====
#
setup () {
	section "Raspberry Pi OS Lite box" "setup · fetch the image, the kernel, and the dtb"

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

	# 2. Download the kernel the machine expects to be given
	if ! [ -f "${WORK_DIR}/${KERNEL_NAME}" ]; then
		step "downloading ${KERNEL_NAME} (about 15 MiB)"
		fetch "${KERNEL_URL}" "${WORK_DIR}/${KERNEL_NAME}"
		result "${OK_CHAR}" "the kernel is ready"
	else
		step "reusing the ${KERNEL_NAME} kernel found in ${work_dir}"
		result "${OK_CHAR}" "no download needed"
	fi

	# 3. Download the device tree blob that describes the board
	if ! [ -f "${WORK_DIR}/${DTB_NAME}" ]; then
		step "downloading ${DTB_NAME}"
		fetch "${DTB_URL}" "${WORK_DIR}/${DTB_NAME}"
		result "${OK_CHAR}" "the device tree blob is ready"
	else
		step "reusing the ${DTB_NAME} blob found in ${work_dir}"
		result "${OK_CHAR}" "no download needed"
	fi

	# 4. Make sure that all pre-requisites are met
	if ! [ -f "${WORK_DIR}/${IMAGE_NAME}" ] || \
		! [ -f "${WORK_DIR}/${KERNEL_NAME}" ] || \
		! [ -f "${WORK_DIR}/${DTB_NAME}" ]; then
		fail "some prerequisites were not met" \
			"expected ${IMAGE_NAME}, ${KERNEL_NAME}, and ${DTB_NAME}" \
			"in ${work_dir}"
	fi

	# 5. Give the guest an account to log in with, if one was requested
	if [ -n "${GUEST_PASSWORD}" ]; then
		if ! command -v "${DEBUGFS}" >/dev/null 2>&1; then
			fail "'${DEBUGFS}' was not found" \
				"Rewriting the password in ${IMAGE_NAME} needs debugfs(8)," \
				"which the e2fsprogs package provides. Install it, or set" \
				"\$GUEST_PASSWORD to \"\" and see README.md."
		fi
		set_password
	fi

	blank
	paragraph "The box is ready. Boot it with './raspberry_pi_box.sh'."
}


#
# ==== Booting process ====
#
boot () {
	section "Raspberry Pi OS Lite box" "boot · power on the virtual machine"

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
		blank
		paragraph "The guest can also be reached over ssh:"
		note "ssh -p ${SSH_PORT} ${GUEST_USER}@localhost"
	fi

	# Halt the cpu and wait for a gdb client when debugging
	if [ "${DEBUG}" -eq 1 ]; then
		set -- -S -gdb tcp::1234
	fi

	"${QEMU_BIN}" \
		-machine "${MACHINE}" \
		-cpu "${QEMU_CPU}" \
		-smp "${QEMU_CPUS}" \
		-m "${QEMU_RAM}" \
		-kernel "${WORK_DIR}/${KERNEL_NAME}" \
		-dtb "${WORK_DIR}/${DTB_NAME}" \
		-sd "${WORK_DIR}/${IMAGE_NAME}" \
		-append "${KERNEL_CMDLINE}" \
		-netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
		-device usb-net,netdev=net0 \
		-nographic \
		"$@"
}


#
# ==== Help message ====
#
usage () {
	section "Raspberry Pi OS Lite box" "fetch and boot Raspberry Pi OS Lite (aarch64)"

	printf '  %s\n' "Usage: ./raspberry_pi_box.sh [-s|--setup] [-b|--boot]"
	printf '  %s\n' "                              [-d|--debug] [-h|--help]"

	printf '\n'
	printf '  %s\n' "Options:"
	printf '    %-14s %s\n' "-s, --setup" "download the files and stop"
	printf '    %-14s %s\n' "-b, --boot" "download the files and boot [default]"
	printf '    %-14s %s\n' "-d, --debug" "boot with the cpu halted, for gdb"
	printf '    %-14s %s\n' "-h, --help" "print this help message"
	note "only the first option is taken into account"

	printf '\n'
	printf '  %s\n' "Settings:"
	setting "\$WORK_DIR" "where files are stored" "${WORK_DIR}"
	setting "\$MACHINE" "emulated board" "${MACHINE}"
	setting "\$QEMU_CPU" "emulated cpu" "${QEMU_CPU}"
	setting "\$QEMU_CPUS" "number of cpus" "${QEMU_CPUS}"
	setting "\$QEMU_RAM" "guest memory" "${QEMU_RAM}"
	setting "\$SSH_PORT" "host ssh port" "${SSH_PORT}"
	setting "\$DTB_NAME" "device tree blob" "${DTB_NAME}"
	setting "\$IMAGE_NAME" "disk image" "${IMAGE_NAME}"
	setting "\$KERNEL_NAME" "guest kernel" "${KERNEL_NAME}"
	setting "\$KERNEL_CMDLINE" "root device" "/dev/mmcblk0p2"
	setting "\$GUEST_USER" "guest account" "${GUEST_USER}"
	# The password, and its hash, are never printed
	if [ -n "${GUEST_PASSWORD}" ]; then
		setting "\$GUEST_PASSWORD" "its password" "set"
	else
		setting "\$GUEST_PASSWORD" "its password" "not set"
	fi

	printf '\n'
	printf '  %s\n' "Edit this script to change any of the settings above."
}


#
# ==== Entry point ====
#
DEBUG=0

# Argument matching
for arg in "$@"; do
	case "$arg" in
		-d|--debug)
			setup
			DEBUG=1
			boot
			;;
		-b|--boot)
			setup
			DEBUG=0
			boot
			;;
		-s|--setup)
			setup
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
	boot
fi
