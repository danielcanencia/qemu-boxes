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
# Acceleration: "auto" uses KVM when /dev/kvm can be opened, and refuses
# to run when it cannot. "kvm" and "tcg" force one or the other; the vm
# runs under software emulation only when that is asked for explicitly.
# KVM_CPU only exists under KVM, and is impossible under TCG.
ACCEL="auto"
KVM_CPU="host"
TCG_CPU="max"
# QEMU rejects -smp 0, so the guest CPU count is clamped at 1 instead of
# being a bare $(nproc)-1 that fails on a single-core host.
if command -v nproc >/dev/null 2>&1; then
	QEMU_SMP=$(($(nproc) - 1))
	[ "${QEMU_SMP}" -ge 1 ] || QEMU_SMP=1
else
	QEMU_SMP=1
fi
# Miscellaneous
QEMU_BIN="qemu-system-x86_64"
QCOW2_DISK_NAME="openbsd.qcow2"
# Connection details
SSH_PORT=2424
SSH_USER="bsd"
# Runtime details
DEBUG=0

# Output helpers, shared with every box in this repository
# shellcheck source=output.sh
. "$(dirname "$0")/output.sh"


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
# ==== Acceleration ====
#

# Picks the accelerator and the CPU model that goes with it, by setting
# QEMU_ACCEL and QEMU_CPU. QEMU refuses to start with KVM requested when
# /dev/kvm cannot be opened, and this box only runs accelerated: "auto"
# stops with a message on a host without KVM rather than silently running
# an unaccelerated vm. "tcg" is the explicit way to ask for software
# emulation.
accel () {
	QEMU_ACCEL="${ACCEL}"
	case "${ACCEL}" in
		auto)
			if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
				QEMU_ACCEL=kvm
			else
				fail "no /dev/kvm on this host, and this box only runs" \
					"with hardware acceleration" \
					"" \
					"Load the kvm module for your cpu and check that" \
					"/dev/kvm appears:" \
					"    sudo modprobe kvm_amd   # amd cpus; kvm-amd since linux 6.8" \
					"    sudo modprobe kvm_intel  # intel cpus; kvm-intel since 6.8" \
					"If modprobe says the module is missing, the running" \
					"kernel has no modules of its own: install the kernel" \
					"package that matches '$(uname -r)' and reboot (on" \
					"Arch, the linux or linux-lts package)." \
					"" \
					"If modprobe reports 'Operation not supported', the" \
					"firmware has virtualization off: enable SVM mode /" \
					"AMD-V in the UEFI or BIOS and reboot, then retry." \
					"" \
					"To run under software emulation anyway, set" \
					"\$ACCEL=\"tcg\" in this script and retry."
			fi
			;;
		kvm|tcg) ;;
		*)
			fail "\$ACCEL is '${ACCEL}', which is neither auto, kvm, nor tcg" \
				"Set it to \"auto\", or force the choice with" \
				"\"kvm\" or \"tcg\"."
			;;
	esac

	# -cpu host names a CPU that only exists in KVM; under TCG the widest
	# feature set qemu can emulate is asked for instead
	if [ "${QEMU_ACCEL}" = "kvm" ]; then
		QEMU_CPU="${KVM_CPU}"
	else
		QEMU_CPU="${TCG_CPU}"
	fi
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
	accel
	note "select '(A)utoinstall' when prompted, then press Enter at the"
	note "'URL of the installation files' question (http://10.0.2.2:80)"
	"${QEMU_BIN}" \
		-machine q35 \
		-accel "${QEMU_ACCEL}" \
		-m "${QCOW2_RAM}" \
		-cpu "${QEMU_CPU}" \
		-smp "${QEMU_SMP}" \
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
		accel
		"${QEMU_BIN}" \
			-machine q35 \
			-accel "${QEMU_ACCEL}" \
			-m "${QCOW2_RAM}" \
			-cpu "${QEMU_CPU}" \
			-smp "${QEMU_SMP}" \
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
		accel
		"${QEMU_BIN}" \
			-machine q35 \
			-accel "${QEMU_ACCEL}" \
			-m "${QCOW2_RAM}" \
			-cpu "${QEMU_CPU}" \
			-smp "${QEMU_SMP}" \
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
	setting "\$ACCEL" "auto, kvm, or tcg" "${ACCEL}"
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
			DEBUG=1
			boot
			;;
		-b|--boot)
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
	boot
fi
