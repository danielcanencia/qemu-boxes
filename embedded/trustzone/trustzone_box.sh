#!/usr/bin/env sh

# Setup and boot a Cortex-M33 TrustZone virtual machine (AN505).
#
# The mps2-an505 machine models the IoTKit FPGA image of application note
# AN505: a single Cortex-M33 with a Secure and a Non-secure world, which
# makes it the usual choice to play with TrustZone without any hardware.
#
# QEMU builds that machine on its own, so this box runs as it is, with no
# download involved. What QEMU cannot build is the firmware that gives the
# two worlds something to do, which is why loading one is optional rather
# than required: drop an ELF file named $ELF_NAME into $WORK_DIR, or point
# $ELF_URL at a mirror serving one, and it gets loaded on top of the bare
# machine. See README.md for the ways of getting hold of a firmware.
#
# No firmware is bundled, by the way: the CMSIS-CoreValidation demo this
# box was originally written against is not published anymore, since Arm
# archived ARM-software/CMSIS_5 and removed the branch that hosted the
# prebuilt binaries.

# Output helpers, shared with every box in this repository
# shellcheck source=lib/output.sh
. "$(dirname "$0")/../../lib/output.sh"

# Where the firmware is stored
WORK_DIR="."
# Optional firmware details
#
# Point ELF_URL to a mirror serving an ELF linked for the machine set
# below, or leave it empty and copy your own build as ELF_NAME.
ELF_NAME="AN505_TrustZone_Demo.elf"
ELF_URL=""
# Checksum of the firmware; set it to "" to skip the check
ELF_SHA256=""
# Miscellaneous
QEMU_BIN="qemu-system-arm"
MACHINE="mps2-an505"
CPU="cortex-m33"
# Where the firmware is loaded. QEMU resets the Secure core with its vector
# table at 0x10000000 on this family (the init-svtor of hw/arm/mps2-tz.c);
# mps2-an547 is the odd one out, at 0x00000000.
LOAD_ADDR="0x10000000"
# A firmware that does nothing but spin, for when there is none to load: the
# initial stack pointer, the reset vector pointing at the loop below it, and
# the loop itself, as 'b .' in Thumb. Written out as octal escapes, since
# printf(1) is the portable way of putting such bytes into a file.
IDLE_FIRMWARE="\000\000\000\020\011\000\000\020\376\347\376\347"


#
# ==== Setting things up ====
#
setup () {
	section "Cortex-M33 TrustZone box" "setup · fetch the firmware, if any"

	if ! [ -d "${WORK_DIR}" ]; then
		step "creating the ${WORK_DIR} directory"
		mkdir -p "${WORK_DIR}"
	fi
	work_dir=$(cd "${WORK_DIR}" && pwd)

	# The machine is built by QEMU itself, so all this setup does is
	# provide a firmware for it to run, when one is available
	if [ -f "${WORK_DIR}/${ELF_NAME}" ]; then
		step "reusing the ${ELF_NAME} firmware found in ${work_dir}"
		result "${OK_CHAR}" "no download needed"
	elif [ -z "${ELF_URL}" ]; then
		warn "no firmware to load, so the machine will boot empty" \
			"That is not an error: QEMU creates the ${MACHINE}" \
			"board on its own, and this box runs without anything" \
			"being downloaded. Firmware is what makes the Secure" \
			"and the Non-secure world do something after reset," \
			"though. To provide one:" \
			"" \
			"    - copy an ELF file of your own, named" \
			"      ${ELF_NAME}, into ${work_dir}, or" \
			"    - set \$ELF_URL to a mirror serving one" \
			"" \
			"README.md explains how to build one."
	else
		step "downloading ${ELF_NAME} from ${ELF_URL}"
		fetch "${ELF_URL}" "${WORK_DIR}/${ELF_NAME}"

		if [ -n "${ELF_SHA256}" ]; then
			step "checking the integrity of ${ELF_NAME}"
			actual=$(sha256_of "${WORK_DIR}/${ELF_NAME}")
			if [ "${ELF_SHA256}" != "${actual}" ]; then
				fail "the ${ELF_NAME} file has been tampered with" \
					"expected sha256: ${ELF_SHA256}" \
					"actual sha256:   ${actual}"
			fi
			result "${OK_CHAR}" "sha256 matches the expected one"
		fi
		result "${OK_CHAR}" "the firmware is ready"
	fi

	# Make sure that an interrupted download did not leave a stub behind
	if [ -e "${WORK_DIR}/${ELF_NAME}" ] && \
		! [ -s "${WORK_DIR}/${ELF_NAME}" ]; then
		fail "${WORK_DIR}/${ELF_NAME} is empty" \
			"The download may have been interrupted; remove the file" \
			"and try again."
	fi

	blank
	paragraph "The box is ready. Boot it with './trustzone_box.sh'."
}


#
# ==== Booting process ====
#
boot () {
	work_dir=$(cd "${WORK_DIR}" && pwd)
	section "Cortex-M33 TrustZone box" "boot · power on the virtual machine"

	step "starting ${QEMU_BIN} (${MACHINE}, ${CPU})"
	if [ -f "${WORK_DIR}/${ELF_NAME}" ]; then
		note "loading ${ELF_NAME} at ${LOAD_ADDR}"
		set -- -device "loader,file=${WORK_DIR}/${ELF_NAME}"
	else
		# The machine is built by QEMU, but not the code that would run
		# on it: with an empty vector table the core lockups, and QEMU
		# aborts the whole vm. A loop that spins is the smallest thing
		# that keeps the board alive, and gives gdb something to attach
		# to as well.
		note "no firmware to load, writing a loop that spins"
		# the escapes are meant to be interpreted, which is what only
		# the format operand of printf(1) does
		# shellcheck disable=SC2059
		printf "${IDLE_FIRMWARE}" > "${WORK_DIR}/.idle.bin"
		set -- -device "loader,file=${WORK_DIR}/.idle.bin,addr=${LOAD_ADDR}"
	fi

	if [ "${DEBUG}" -eq 1 ]; then
		section "Debug mode" "the cpu is halted, gdb is expected on :1234"
		note "attach with: 'gdb', 'target remote :1234', then 'continue'"
		set -- "$@" -S -gdb tcp::1234
	fi
	note "quit QEMU with Ctrl+A, then X"

	"${QEMU_BIN}" \
		-machine "${MACHINE}" \
		-cpu "${CPU}" \
		-nographic \
		-serial mon:stdio \
		"$@"

	rm -f "${WORK_DIR}/.idle.bin"
}


#
# ==== Help message ====
#
usage () {
	section "Cortex-M33 TrustZone box" "boot a Cortex-M33 with TrustZone enabled"

	printf '  %s\n' "Usage: ./trustzone_box.sh [-s|--setup] [-b|--boot]"
	printf '  %s\n' "                           [-d|--debug] [-h|--help]"

	printf '\n'
	printf '  %s\n' "Options:"
	printf '    %-14s %s\n' "-s, --setup" "download the firmware and stop"
	printf '    %-14s %s\n' "-b, --boot" "download the firmware and boot [default]"
	printf '    %-14s %s\n' "-d, --debug" "boot with the cpu halted, for gdb"
	printf '    %-14s %s\n' "-h, --help" "print this help message"
	note "only the first option is taken into account"

	printf '\n'
	printf '  %s\n' "Settings:"
	setting "\$MACHINE" "emulated board" "${MACHINE}"
	setting "\$CPU" "emulated cpu" "${CPU}"
	setting "\$WORK_DIR" "where files are stored" "${WORK_DIR}"
	setting "\$ELF_NAME" "firmware to load, optional" "${ELF_NAME}"
	setting "\$ELF_URL" "where to get it from" "${ELF_URL:-not set}"

	printf '\n'
	paragraph "QEMU builds the machine on its own, so the firmware above is" \
		"optional: without it the box boots an empty board that sits idle."
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
