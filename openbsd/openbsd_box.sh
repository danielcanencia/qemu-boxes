#!/usr/bin/env sh

# Setup, install, and boot an OpenBSD QEMU virtual machine.

# Image details
MIRROR="https://cdn.openbsd.org/pub/OpenBSD"
RELEASE="snapshots"
ARCH="amd64"
IMAGE_NAME="miniroot80.img"
# Performance-related
QCOW2_DISK_CAPACITY="42G"
QCOW2_RAM="4G"
# Miscellaneous
QEMU_BIN="qemu-system-x86_64"
QCOW2_DISK_NAME="openbsd.qcow2"
# Connection details
SSH_PORT=2424
SSH_USER="bsd"
# Runtime details
DEBUG=0

# Output helpers, shared with every box in this repository
# shellcheck source=lib/output.sh
. "$(dirname "$0")/../lib/output.sh"


#
# ==== Setting things up ====
#
setup () {
	section "OpenBSD QEMU box" "setup · fetch the image and create the disk"

	# 1. Download the selected image (if applicable)
	if ! [ -f "$(pwd)/${IMAGE_NAME}" ]; then
		step "downloading ${IMAGE_NAME} from the ${RELEASE} mirror"

		# Not fetch(): this download gets a message naming the variables
		# worth looking at when the mirror does not hold the image
		if ! curl --fail --location --output-dir "$(pwd)" -O \
			"${MIRROR}/${RELEASE}/${ARCH}/${IMAGE_NAME}"; then
			fail "the ${IMAGE_NAME} image could not be downloaded" \
				"Check that \$MIRROR, \$RELEASE, and \$ARCH point at a" \
				"directory holding it."
		fi
		curl --fail --location --output-dir "$(pwd)" -O \
			"${MIRROR}/${RELEASE}/${ARCH}/SHA256"

		step "checking the integrity of ${IMAGE_NAME}"
		expected=$(awk -v f="${IMAGE_NAME}" \
			'$0 ~ "SHA256 \\(" f "\\) =" { print $4; exit }' \
			"$(pwd)/SHA256")
		actual=$(sha256_of "$(pwd)/${IMAGE_NAME}")

		if [ -z "${expected}" ] || [ "${expected}" != "${actual}" ]; then
			fail "the ${IMAGE_NAME} image file has been tampered with" \
				"expected sha256: ${expected}" \
				"actual sha256:   ${actual}"
		fi
		result "${OK_CHAR}" "sha256 matches the one published by the mirror"
	else
		step "reusing the ${IMAGE_NAME} image found in $(pwd)"
		result "${OK_CHAR}" "no download needed"
	fi

	# 2. Create an empty qcow2 disk
	if ! [ -f "$(pwd)/${QCOW2_DISK_NAME}" ]; then
		step "creating ${QCOW2_DISK_NAME} (${QCOW2_DISK_CAPACITY}) to hold the vm"
		qemu-img create -f qcow2 "${QCOW2_DISK_NAME}" "${QCOW2_DISK_CAPACITY}"
		result "${OK_CHAR}" "the disk is ready to be installed into"
	else
		step "reusing the ${QCOW2_DISK_NAME} disk found in $(pwd)"
		result "${OK_CHAR}" "no disk creation needed"
	fi

	# 3. Make sure that all pre-requisites are met
	if ! [ -f "$(pwd)/${IMAGE_NAME}" ] || \
		! [ -f "$(pwd)/${QCOW2_DISK_NAME}" ]; then
		fail "some prerequisites were not met" \
			"expected both ${IMAGE_NAME} and ${QCOW2_DISK_NAME} in $(pwd)"
	fi

	blank
	paragraph "The box is ready. Install OpenBSD into it with" \
		"'./openbsd_box.sh -i', or boot it as it is with './openbsd_box.sh'."
}


#
# ==== Installation ====
#
install () {
	section "OpenBSD QEMU box" "install · write ${QCOW2_DISK_NAME} from scratch"

	paragraph "For the provided ./install.conf file to be used, its contents" \
		"have to be served over HTTP, and '(A)utoinstall' has to be picked" \
		"when the installer asks for it:"
	note "$(printf '%s' "${EDITOR:-vi}") ./install.conf   # review the answers"
	note "tar -czvf siteXX.tgz -C site_build .   # optional"
	note "python3 -m http.server 80   # serve this directory"
	blank
	paragraph "Keep the server running in another terminal, boot the box with" \
		"'./openbsd_box.sh -i', and wait until the installer reboots into" \
		"the installed system. Quit QEMU (Ctrl+A, then X) at that point."

	# Safety check
	blank
	rule
	printf '  %s About to overwrite %s\n' "${ERR_CHAR}" "${QCOW2_DISK_NAME}"
	rule
	blank
	paragraph "Everything stored in that disk will be lost, and this cannot" \
		"be undone. Do you wish to continue? [Y(y)/N(n)]"
	read -r reply
	case $reply in
		[Yy])
			:
			;;
		[Nn])
			blank
			exit 0
			;;
		*)
			exit 0
			;;
	esac

	# Installation command
	step "starting the installation vm"
	note "select '(A)utoinstall' when prompted, then press Enter at the"
	note "'URL of the installation files' question (http://10.0.2.2:80)"
	"${QEMU_BIN}" \
		-machine q35 \
		-enable-kvm \
		-m "${QCOW2_RAM}" \
		-cpu host \
		-smp $(($(nproc)-1)) \
		-netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
		-device virtio-net-pci,netdev=net0 \
		-drive file="$(pwd)/${QCOW2_DISK_NAME}",format=qcow2,if=none,id=drive1,index=1 \
		-drive file="$(pwd)/${IMAGE_NAME}",format=raw,if=ide,id=drive0,index=0 \
		-device virtio-blk-pci,drive=drive1 \
		-boot order=c,menu=on
}


#
# ==== Booting process ====
#
boot () {
	section "OpenBSD QEMU box" "boot · power on the virtual machine"

	if [ "${DEBUG}" -eq 1 ]; then
		section "Debug mode" "gdb is expected on 127.0.0.1:1234"
		note "attach with: 'gdb', 'target remote :1234', then 'continue'"
		"${QEMU_BIN}" \
			-machine q35 \
			-enable-kvm \
			-m "${QCOW2_RAM}" \
			-cpu host \
			-smp $(($(nproc)-1)) \
			-nographic \
			-usb \
			-netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
			-device virtio-net-pci,netdev=net0,mac='52:54:00:12:34:56' \
			-drive file="$(pwd)/${QCOW2_DISK_NAME}",format=qcow2,if=none,id=drive1,index=0 \
			-device virtio-blk-pci,drive=drive1 \
			-boot order=c,menu=on \
			-s
	else
		step "starting ${QEMU_BIN} in the background"
		blank
		paragraph "Connect to the vm with:"
		note "ssh -p ${SSH_PORT} ${SSH_USER}@localhost"
		blank
		paragraph "Shut it down with:"
		note "pkill ${QEMU_BIN}"
		"${QEMU_BIN}" \
			-machine q35 \
			-enable-kvm \
			-m "${QCOW2_RAM}" \
			-cpu host \
			-smp $(($(nproc)-1)) \
			-usb \
			-display none \
			-daemonize \
			-netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
			-device virtio-net-pci,netdev=net0,mac='52:54:00:12:34:56' \
			-drive file="$(pwd)/${QCOW2_DISK_NAME}",format=qcow2,if=none,id=drive1,index=0 \
			-device virtio-blk-pci,drive=drive1 \
			-boot order=c,menu=on
	fi

	exit 0
}


#
# ==== Help message ====
#
usage () {
	section "OpenBSD QEMU box" "setup, install, or boot an OpenBSD system"

	printf '  %s\n' "Usage: ./openbsd_box.sh [-b|--boot] [-d|--debug]"
	printf '  %s\n' "                       [-i|--install] [-h|--help]"

	printf '\n'
	printf '  %s\n' "Options:"
	printf '    %-14s %s\n' "-b, --boot" "power on the vm [default]"
	printf '    %-14s %s\n' "-d, --debug" "power it on and wait for gdb"
	printf '    %-14s %s\n' "-i, --install" "install OpenBSD into a new disk"
	printf '    %-14s %s\n' "-h, --help" "print this help message"
	note "only the first option is taken into account"
	note "'--debug' does not boot the vm twice; it replaces --boot"

	printf '\n'
	printf '  %s\n' "Settings:"
	setting "\$QEMU_BIN" "qemu executable" "${QEMU_BIN}"
	setting "\$RELEASE" "release to install" "${RELEASE}"
	setting "\$ARCH" "target architecture" "${ARCH}"
	setting "\$IMAGE_NAME" "installation image" "${IMAGE_NAME}"
	setting "\$QCOW2_DISK_NAME" "resulting disk" "${QCOW2_DISK_NAME}"
	setting "\$QCOW2_DISK_CAPACITY" "disk size" "${QCOW2_DISK_CAPACITY}"
	setting "\$QCOW2_RAM" "guest memory" "${QCOW2_RAM}"
	setting "\$SSH_PORT" "host ssh port" "${SSH_PORT}"
	setting "\$SSH_USER" "user created at install" "${SSH_USER}"

	printf '\n'
	printf '  %s\n' "Edit this script to change any of the settings above."
}


#
# ==== Entry point ====
#

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
		-i|--install)
			setup
			install
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
