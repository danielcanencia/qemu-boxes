#!/usr/bin/env sh

# Setup, install, and boot an OpenBSD QEMU virtual machine.

MIRROR="https://cdn.openbsd.org/pub/OpenBSD"
RELEASE="7.9"
ARCH="amd64"
IMAGE_NAME="miniroot79.img"
# Performance-related
QCOW2_DISK_CAPACITY="42G"
QCOW2_RAM="4G"
# Miscellaneous
QCOW2_DISK_NAME="openbsd.qcow2"
# Connection details
SSH_PORT=2424


#
# Setting things up
#
setup () {
	printf "======== Checking requisites ========\n"
	# 1. Download the selected image (if applicable)
	
	if ! [ -f "$(pwd)/${IMAGE_NAME}" ]; then
		printf "Downloading %s from remote mirror...\n" "${IMAGE_NAME}"
		curl --output-dir "$(pwd)" -O "${MIRROR}/${RELEASE}/${ARCH}/${IMAGE_NAME}"
		curl --output-dir "$(pwd)" -O "${MIRROR}/${RELEASE}/${ARCH}/SHA256"

		printf "%s\n" "Checking image integrity..."
		expected=$(awk -v f="${IMAGE_NAME}" \
			'$0 ~ "SHA256 \\(" f "\\) =" { print $4; exit }' \
			"$(pwd)/SHA256")

        # Obtain the correct sha256 binary
		if command -v sha256 >/dev/null 2>&1; then
			actual=$(sha256 -q "$(pwd)/${IMAGE_NAME}")
		elif command -v sha256sum >/dev/null 2>&1; then
			actual=$(sha256sum "$(pwd)/${IMAGE_NAME}")
			actual=${actual%% *}
		fi

		if [ -z "${expected}" ] || [ "${expected}" != "${actual}" ]; then
			printf "Error: the %s image file has been tampered with.\n" "${IMAGE_NAME}"
			exit 1
		fi
	fi

	# 2. Create an empty qcow2 disk
	if ! [ -f "$(pwd)/${QCOW2_DISK_NAME}" ]; then
		printf "Creating an empty disk to hold the vm...\n"
		qemu-img create -f qcow2 "${QCOW2_DISK_NAME}" "${QCOW2_DISK_CAPACITY}"
	fi

	# 3. Make sure that all pre-requisites are met
	if ! [ -f "$(pwd)/${IMAGE_NAME}" ] || \
		! [ -f "$(pwd)/${QCOW2_DISK_NAME}" ]; then
		printf "Error: Some prerequisites were not met.\n"
		exit 1
	fi
}


#
# Installation
#
install () {
	printf "======== Starting installation ========\n"
	printf '%s\n' \
		'To be able to use the provided ./install.conf file' \
		'correctly, please set up a web server in the current directory' \
		'prior to executing this program, and select "(A)utoinstall" when' \
		'prompt:' \
		'' \
		'	- python3 -m http.server 80' \
		'' \
		'Note: Remember to edit the disk layout parameters present in the' \
		'"custom_disklabel.conf" file according to the value of the' \
		'$QCOW2_DISK_CAPACITY variable.' | fold -sw 100

	# Safety check
	printf "
======== POTENTIAL REMOVAL. IMPORTANT!!!! ========
The installation is about to begin, and the current image will be overwritten.
Do you wish to continue? [Y(y)/N(n)]: "
	read -r reply
	case $reply in
		[Yy])
			:
			;;
		[Nn])
			printf "\n"
			exit 0
			;;
		*)
			exit 0
			;;
	esac


    # Installation command
    qemu-system-x86_64 \
            -machine q35 \
            -enable-kvm \
            -m "${QCOW2_RAM}" \
            -cpu host \
            -smp $(($(nproc)-1)) \
            -netdev user,id=net0,hostfwd=tcp::2424-:22 \
            -device virtio-net-pci,netdev=net0 \
            -drive file="$(pwd)/${QCOW2_DISK_NAME}",format=qcow2,if=none,id=drive1,index=1 \
            -drive file="$(pwd)/${IMAGE_NAME}",format=raw,if=ide,id=drive0,index=0 \
            -device virtio-blk-pci,drive=drive1 \
            -boot order=c,menu=on
}


#
# Booting process
#
boot () {
	printf "======== Booting into the VM ========\n"

	if [ "$DEBUG" ]; then
		qemu-system-x86_64 \
			-machine q35 \
			-enable-kvm \
			-m "${QCOW2_RAM}" \
			-cpu host \
			-smp $(($(nproc)-1)) \
			-nographic \
			-usb \
			-netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
			-device virtio-net-pci,netdev=net0,mac='52:54:00:12:34:56' \
			-drive file="$(pwd)/${QCOW2_DISK_NAME}",format=qcow2,if=none,id=drive1,index=0 \
			-device virtio-blk-pci,drive=drive1 \
			-boot order=c,menu=on \
			-s
	else
		printf "Use 'ssh %s@localhost -p %s' to connect to the VM\n\n" "bsd" "$SSH_PORT"
		printf "Note: use 'pkill qemu-system-x86' to kill the background process\n\n"
		qemu-system-x86_64 \
			-machine q35 \
			-enable-kvm \
			-m "${QCOW2_RAM}" \
			-cpu host \
			-smp $(($(nproc)-1)) \
			-usb \
			-daemonize \
			-display none \
			-netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
			-device virtio-net-pci,netdev=net0,mac='52:54:00:12:34:56' \
			-drive file="$(pwd)/${QCOW2_DISK_NAME}",format=qcow2,if=none,id=drive1,index=0 \
			-device virtio-blk-pci,drive=drive1 \
			-boot order=c,menu=on
	fi
}


#
# ==== Entry point ====
#

# Argument matching
for arg in "$@"; do
	case "$arg" in
		-d|--debug)
			DEBUG=1
			if [ $# -eq 1 ]; then
				setup
				boot
			fi
			;;
		-b|--boot)
			setup
			boot
			exit 0
			;;
		-i|--install)
			setup
			install
			;;
		--help|-h|*)
			printf '%s\n' \
				'QEMU wrapper used to setup, install, or boot a OpenBSD' \
				'system' \
				'' \
				'Usage: ./openbsd_box.sh [-b|--boot] [-d, --daemonize]' \
				'        [-i|--install] [-h|--help]' \
				'' \
				'Options:' \
				'	- -b, --boot [default] :  power on the VM' \
				'	- -d, --debug:  run with a gdb server' \
				'		Note that this option will only have effect if' \
				'		combined with [--boot|-b]' \
				'	- -i, --install :  install OpenBSD on a new qcow2 image' \
				'	- -h, --help :  print this help message' \
				'' | fold -sw 100
			exit 0
	esac
done


# [-b | --boot] is the default argument
if [ $# -eq 0 ]; then
	setup
	boot
	exit 0
fi
