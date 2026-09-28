#!/usr/bin/env sh

# Setup, build, and boot a Cortex-M33 TrustZone virtual machine (AN505).
#
# The mps2-an505 machine models the IoTKit FPGA image of application note
# AN505: a single Cortex-M33 with a Secure and a Non-secure world, which
# makes it the usual choice to play with TrustZone without any hardware.
#
# This box is set up for Rust firmware development. It builds the dual-world
# image from the Cargo project in this directory, with cargo, and boots the
# guest with it.
#
# QEMU builds that machine on its own, so this box runs as it is, with no
# download involved. What QEMU cannot build is the firmware that gives the
# two worlds something to do, which is why building it here is part of the
# box: run './trustzone_box.sh build', or point $ELF_URL at a mirror serving
# a prebuilt image and it gets loaded on top of the bare machine instead.

# Output helpers, shared with every box in this repository
# shellcheck source=output.sh
. "$(dirname "$0")/output.sh"

# Where the firmware is stored
WORK_DIR="."
# Firmware details
#
# The image built from the sources in this directory. Point ELF_URL at a
# mirror serving a prebuilt one instead, and leave it empty to build.
ELF_NAME="AN505_TrustZone_Demo.elf"
ELF_URL=""
# Checksum of a downloaded firmware; set it to "" to skip the check
ELF_SHA256=""
# Build details
#
# The Cargo project is this directory, and the image it produces is loaded
# from its target directory.
CRATE_NAME="an505_trustzone_demo"
RUST_TARGET="thumbv8m.main-none-eabihf"
CARGO="cargo"
# Whether the firmware hands the core over from the Secure world to the
# Non-secure one: "off" for a normal boot, "on" for a dual-world one.
#
# Off by default, so that building and booting this box does what any other
# box does. The handover is the TrustZone part, and it is what you turn on
# when that is what you are here for: the Secure world starts either way,
# and only with this set does it branch into the Non-secure world with a
# BLXNS. It is a build setting rather than a run-time one, so the firmware
# has to be rebuilt to change it.
HANDOVER="off"
# Where the firmware is loaded. QEMU resets the Secure core with its vector
# table at 0x10000000 on this family (the init-svtor of hw/arm/mps2-tz.c);
# mps2-an547 is the odd one out, at 0x00000000.
LOAD_ADDR="0x10000000"
# A firmware that does nothing but spin, for when there is none to load: the
# initial stack pointer, the reset vector pointing at the loop below it, and
# the loop itself, as 'b .' in Thumb. Written out as octal escapes, since
# printf(1) is the portable way of putting such bytes into a file.
IDLE_FIRMWARE="\000\000\000\020\011\000\000\020\376\347\376\347"
# Miscellaneous
QEMU_BIN="qemu-system-arm"
MACHINE="mps2-an505"
CPU="cortex-m33"


#
# ==== Setting things up ====
#
setup () {
	section "Cortex-M33 TrustZone box" "setup · prepare the firmware"

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
		warn "no firmware to load, so the machine will boot a loop that spins" \
			"That is not an error: QEMU creates the ${MACHINE}" \
			"board on its own, and this box runs without anything" \
			"being downloaded. Firmware is what makes the Secure" \
			"and the Non-secure world do something after reset," \
			"though. To provide one:" \
			"" \
			"    - build the image in this directory with" \
			"      './trustzone_box.sh build', or" \
			"    - copy a prebuilt ELF file of your own, named" \
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
	paragraph "The box is ready. Build the firmware with './trustzone_box.sh" \
		"build', or boot it as it is with './trustzone_box.sh'."
}


#
# ==== Building the firmware ====
#
build () {
	section "Cortex-M33 TrustZone box" "build · compile the firmware"

	# The handover is compiled in or left out, so cargo is told which one
	# this build is for
	case "${HANDOVER}" in
		on) _handover="--features handover" ;;
		off) _handover="" ;;
		*)
			fail "\$HANDOVER is '${HANDOVER}', which is neither on nor off" \
				"Set it to \"off\" for a normal boot, or \"on\" for one" \
				"that hands the core over to the Non-secure world."
			;;
	esac
	# shellcheck disable=SC2086  # _handover is empty or one flag on purpose
	if [ "${_handover}" = "" ]; then
		step "building ${CRATE_NAME} for ${RUST_TARGET} with ${CARGO}"
	else
		step "building ${CRATE_NAME} for ${RUST_TARGET} with ${CARGO}, with the handover"
	fi
	# shellcheck disable=SC2086  # again, deliberately empty or one flag
	if ! (cd "$(dirname "$0")" && "${CARGO}" build \
		--target "${RUST_TARGET}" --release ${_handover}) >/dev/null; then
		fail "the firmware could not be built" \
			"Run 'cargo build --target ${RUST_TARGET} --release ${_handover}'" \
			"by hand to see the compiler output. The crate is in" \
			"$(dirname "$0")."
	fi
	result "${OK_CHAR}" "${CRATE_NAME} is ready"
}


#
# ==== Booting process ====
#
boot () {
	work_dir=$(cd "${WORK_DIR}" && pwd)
	section "Cortex-M33 TrustZone box" "boot · power on the virtual machine"

	elf="$(dirname "$0")/target/${RUST_TARGET}/release/${CRATE_NAME}"
	if [ -f "${WORK_DIR}/${ELF_NAME}" ]; then
		elf="${WORK_DIR}/${ELF_NAME}"
	fi

	if [ -f "${elf}" ]; then
		note "loading $(basename "${elf}") at ${LOAD_ADDR}"
		set -- -device "loader,file=${elf}"
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

	# There is no operating system here, so nothing is going to greet you on
	# the terminal and there is nothing to log in to. Say so before QEMU
	# takes the screen over, rather than leaving it looking like a guest
	# that has hung.
	blank
	paragraph "There is no operating system and no login. The firmware is bare" \
		"metal, so it prints nothing and there is no prompt to type at."
	paragraph "What you can type here is QEMU's own monitor, not the guest." \
		"'info registers' and 'x/8i \$pc' are the useful ones; 'help'" \
		"lists the rest. To run the guest yourself, use '-d' and drive" \
		"it through gdb instead."
	case "${HANDOVER}" in
		on)
			note "this build hands the core over to the Non-secure world"
			;;
		*)
			note "this build stays in the Secure world"
			note "rebuild with --handover for a dual-world image"
			;;
	esac

	note "leave QEMU with 'quit' at the monitor prompt"

	# The monitor is put on the terminal with -monitor stdio rather than
	# with the usual -serial mon:stdio. On this board the second form does
	# not work: the machine already claims stdio for its own UART, so the
	# mux never gets it, and what reaches the terminal is a dead line that
	# answers nothing. -monitor stdio is a separate request and is
	# honoured, so the monitor below really is typeable. The price is that
	# the guest's UART is thrown away instead of being muxed with it,
	# which costs nothing while the firmware prints nothing anyway, and
	# that Ctrl+A, then X no longer quits, hence the instruction above.
	"${QEMU_BIN}" \
		-machine "${MACHINE}" \
		-cpu "${CPU}" \
		-display none \
		-serial null \
		-monitor stdio \
		"$@"

	rm -f "${WORK_DIR}/.idle.bin"
}


#
# ==== Help message ====
#
usage () {
	section "Cortex-M33 TrustZone box" "build and boot an ARMv8-M TrustZone image"

	printf '  %s\n' "Usage: ./trustzone_box.sh [--handover] [-s|--setup]"
	printf '  %s\n' "                           [-b|--boot] [-d|--debug]"
	printf '  %s\n' "                           [-h|--help] [build]"

	printf '\n'
	printf '  %s\n' "Options:"
	printf '    %-14s %s\n' "--handover" "hand over to the Non-secure world"
	printf '    %-14s %s\n' "build" "compile the firmware and stop"
	printf '    %-14s %s\n' "-s, --setup" "prepare the box and stop"
	printf '    %-14s %s\n' "-b, --boot" "build and boot [default]"
	printf '    %-14s %s\n' "-d, --debug" "boot with the cpu halted, for gdb"
	printf '    %-14s %s\n' "-h, --help" "print this help message"
	note "--handover comes first: only the first option is taken into account"

	printf '\n'
	printf '  %s\n' "Settings:"
	setting "\$MACHINE" "emulated board" "${MACHINE}"
	setting "\$CPU" "emulated cpu" "${CPU}"
	setting "\$WORK_DIR" "where files are stored" "${WORK_DIR}"
	setting "\$CRATE_NAME" "the crate to build" "${CRATE_NAME}"
	setting "\$RUST_TARGET" "its target" "${RUST_TARGET}"
	setting "\$ELF_NAME" "firmware to load" "${ELF_NAME}"
	setting "\$LOAD_ADDR" "where it is loaded" "${LOAD_ADDR}"
	setting "\$HANDOVER" "world handover" "${HANDOVER}"

	printf '\n'
	paragraph "The firmware is a dual-world TrustZone image, built with" \
		"cargo. Edit src/main.rs, then run './trustzone_box.sh build'" \
		"to recompile it."
	paragraph "A normal boot stays in the Secure world. The handover is what" \
		"branches into the Non-secure one, and it is off unless you ask" \
		"for it with --handover, since it is compiled in rather than" \
		"chosen at run time."
	paragraph "There is no operating system and no login, so the firmware" \
		"prints nothing and there is no prompt. What the terminal takes" \
		"is QEMU's monitor; use -d and gdb to run the guest yourself."
}


#
# ==== Entry point ====
#
DEBUG=0

# Argument matching
#
# --handover is a modifier rather than an action: it sets $HANDOVER and hands
# the rest of the command line on, so that it has to come before the option
# it modifies, the same way -n does in the other boxes. Everything else ends
# the script, which is what makes "only the first option is taken into
# account" true: iterating over "$@" without that would go on to the second
# option and start the whole chain over again.
while [ "$#" -gt 0 ]; do
	arg="$1"
	case "$arg" in
		--handover)
			HANDOVER="on"
			shift
			;;
		-d|--debug)
			setup
			build
			DEBUG=1
			boot
			exit 0
			;;
		-b|--boot)
			setup
			build
			DEBUG=0
			boot
			exit 0
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
	build
	boot
fi
