# shellcheck shell=sh
# shellcheck disable=SC2034  # the presentation details below are used by the sourcing scripts
#
# Output helpers shared by every QEMU box in this repository.
#
# This file is not meant to be executed, only sourced by a box script, which
# reaches it through a symlink named output.sh in the box's own directory:
#
#	. "$(dirname "$0")/output.sh"
#
# (the symlink points here, so the box and the helpers can be moved around
# together; 'shellcheck -x' follows it)
#

# Presentation details, tweak them here
RULE_WIDTH=72
RULE_CHAR="─"
STEP_CHAR="›"
OK_CHAR="✓"
WARN_CHAR="!"
ERR_CHAR="✗"


#
# ==== Informative output ====
#

# Print a horizontal rule, as wide as $RULE_WIDTH.
rule () {
	_rule=''
	while [ "${#_rule}" -lt "${RULE_WIDTH}" ]; do
		_rule="${_rule}${RULE_CHAR}"
	done
	printf '%s\n' "${_rule}"
}

# Print a section header: a title, an optional subtitle, and two rules.
section () {
	rule
	printf '  %s\n' "$1"
	if [ -n "$2" ]; then
		printf '  %s\n' "$2"
	fi
	rule
	printf '\n'
}

# Print a step, e.g. "Downloading kernel8.img".
step () {
	printf '  %s %s\n' "${STEP_CHAR}" "$1"
}

# Print the outcome of a step, e.g. "sha256 matches".
result () {
	printf '    %s %s\n' "$1" "$2"
}

# Print a note, e.g. a command the user has to copy verbatim.
note () {
	printf '    %s\n' "$1"
}

# Print an empty line, used to tell apart the different blocks of output.
blank () {
	printf '\n'
}

# Print a paragraph of text. Every argument is printed on its own line,
# wrapped to the rule width and indented so that it lines up with the steps
# above. Commands that have to be copied verbatim are better printed with
# 'note', as those are not wrapped.
paragraph () {
	printf '%s\n' "$@" |
		fold -sw $((RULE_WIDTH - 4)) -s |
		sed -e 's/^/    /' -e 's/[[:space:]]*$//'
}

# Print a configurable setting as "name  description ....... value", e.g.
#
#	$RELEASE              release to install .......... snapshots
setting () {
	_description="$2"
	_value="$3"
	_leader=''
	_columns=$((RULE_WIDTH - 28 - ${#_description} - ${#_value}))
	while [ "${_columns}" -gt 0 ]; do
		_leader="${_leader}."
		_columns=$((_columns - 1))
	done
	printf '    %-20s %s %s %s\n' "$1" "${_description}" "${_leader}" "${_value}"
}

# Print a warning, and carry on.
warn () {
	printf '\n'
	rule
	printf '  %s Warning\n' "${WARN_CHAR}"
	rule
	printf '%s\n' "$@" |
		fold -sw $((RULE_WIDTH - 4)) -s |
		sed -e 's/^/    /' -e 's/[[:space:]]*$//'
}

# Print an error message and quit.
fail () {
	printf '\n'
	rule
	printf '  %s Error\n' "${ERR_CHAR}"
	rule
	printf '%s\n' "$@" |
		fold -sw $((RULE_WIDTH - 4)) -s |
		sed -e 's/^/    /' -e 's/[[:space:]]*$//'
	printf '\n'
	exit 1
}


#
# ==== Prerequisites ====
#

# Print the sha256 checksum of the file passed as argument, using whichever
# binary the system provides.
sha256_of () {
	if command -v sha256 >/dev/null 2>&1; then
		sha256 -q "$1"
	elif command -v sha256sum >/dev/null 2>&1; then
		_checksum=$(sha256sum "$1")
		printf '%s' "${_checksum%% *}"
	fi
}

# Download the URL passed as first argument into the file passed as second
# one, and quit if the transfer fails.
fetch () {
	if ! curl --fail --location --retry 3 \
		--output "$2" "$1"; then
		fail "could not download $1" \
			"Check that the URL is still valid, or place a file named" \
			"'${2##*/}' in $(cd "$(dirname "$2")" && pwd) by hand."
	fi
}


#
# ==== Changing files inside the guest image ====
#
# Anything below is done by cutting the root partition out of the disk image,
# changing the file with debugfs(8), and writing the partition back. There is
# no easier way to reach a file in a guest that is not running, and doing it
# offline rather than leaving a file for the guest to pick up at boot matters:
# the first-boot provisioning service of a Raspberry Pi OS image wants a
# console this box has none of, and so never gets to apply anything.
#
# Both helpers here need roughly as much free space as the root partition is
# big, and they use the same temporary file, so a box runs them one after
# another rather than at the same time. rootfs_extract leaves the copy in
# $ROOTFS_PART; rootfs_restore puts it back and removes it.
rootfs_extract () {
	_image="${WORK_DIR}/${IMAGE_NAME}"
	_part="${WORK_DIR}/.rootfs.img"
	trap 'rm -f "${_part}"' 0

	# Work out where the root filesystem starts inside the image
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

	# Cut the partition out, as there has to be room for a copy of it
	_needed=$(($(wc -c < "${_image}") - _offset))
	_free=$(df -Pk "${WORK_DIR}" 2>/dev/null | awk 'NR == 2 { print $4 }')
	if [ -z "${_free}" ] || [ "${_free}" -lt $((_needed / 1024)) ]; then
		fail "not enough free space in ${WORK_DIR}" \
			"Changing a file in the guest needs a temporary copy of the" \
			"root partition, about $((_needed / 1048576)) MiB of free" \
			"space, and only $((_free / 1024)) MiB are available."
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

	ROOTFS_PART="${_part}"
	ROOTFS_BACK="${WORK_DIR}/${IMAGE_NAME}"
	ROOTFS_SECTOR=$((_offset / 1048576))
}

# Put the root partition back where it came from, and clean up after it.
rootfs_restore () {
	if [ -z "${ROOTFS_PART}" ] || [ ! -f "${ROOTFS_PART}" ]; then
		return 0
	fi
	step "writing the root filesystem back into ${IMAGE_NAME}"
	if ! "${DD}" if="${ROOTFS_PART}" of="${ROOTFS_BACK}" bs=1048576 \
		seek="${ROOTFS_SECTOR}" conv=notrunc 2>/dev/null; then
		fail "the root filesystem could not be written back" \
			"${IMAGE_NAME} may be damaged; the untouched copy is at" \
			"${ROOTFS_PART}, do not delete it."
	fi
	rm -f "${ROOTFS_PART}"
	ROOTFS_PART=""
}

# Mask the systemd unit $1, so that systemd will not run it. A unit is masked
# by a symbolic link to /dev/null in /etc/systemd/system, which systemd honours
# wherever the unit would otherwise be wanted from.
#
# This is for the units that cannot work in a box like this one, and that stop
# everything after them when they fail. Raspberry Pi OS ships
# userconfig.service, a configuration dialog that wants /dev/tty8 — the
# framebuffer console — and that is restarted on failure, so on a guest with
# no framebuffer it fails, is retried forever, and multi-user.target never
# completes. Nothing after it starts, sshd least of all, and the box looks
# like a guest that booted and then hung.
mask_guest_unit () {
	[ -n "${GUEST_UNITS_TO_MASK}" ] || return 0

	rootfs_extract
	trap 'rm -f "${ROOTFS_PART}"' 0

	for _unit in ${GUEST_UNITS_TO_MASK}; do
		# Only mask what the image actually ships, so that a guest
		# without the unit is left alone rather than given a link
		# to a unit that does not exist
		if ! "${DEBUGFS}" -R "stat /lib/systemd/system/${_unit}" \
			"${ROOTFS_PART}" >/dev/null 2>&1; then
			note "${_unit} is not in this image, nothing to mask"
			continue
		fi

		# Whatever is at the masking path already is left as it is: a
		# file there is an override the image put there on purpose, and
		# overwriting one is not this box's call to make
		_have=$("${DEBUGFS}" -R "stat /etc/systemd/system/${_unit}" \
			"${ROOTFS_PART}" 2>/dev/null)
		_link=$(printf '%s\n' "${_have}" |
			sed -n 's/.*Fast link dest: "\(.*\)"/\1/p')
		case "${_have}" in
			*"Type: symlink"*)
				if [ "${_link}" = "/dev/null" ]; then
					note "${_unit} is already masked"
					continue
				fi
				fail "'${_unit}' is linked somewhere else in the guest" \
					"/etc/systemd/system/${_unit} points at" \
					"'${_link}' rather than at /dev/null, so systemd" \
					"will still run the unit. Point it at /dev/null, or" \
					"take it out of \$GUEST_UNITS_TO_MASK."
				;;
			*"Inode:"*)
				fail "something is at '/etc/systemd/system/${_unit}'" \
					"and it is not a mask. A file there overrides the" \
					"unit, so masking it would mean overwriting" \
					"something the image put there deliberately. Remove" \
					"or mask it by hand to let the box boot, or take" \
					"'${_unit}' out of \$GUEST_UNITS_TO_MASK."
				;;
		esac

		step "masking ${_unit} in the guest"
		# The target of the link is part of the -R string, not an
		# argument of its own: a line continued after the closing quote
		# starts a new word, and debugfs would take that word for another
		# filesystem to open
		if ! "${DEBUGFS}" -w -R \
			"symlink /etc/systemd/system/${_unit} /dev/null" \
			"${ROOTFS_PART}" >/dev/null 2>&1; then
			fail "${_unit} could not be masked in the guest" \
				"The copy of the root filesystem is at ${ROOTFS_PART};" \
				"it is intact and the image has not been changed yet."
		fi
		# Read it back, as debugfs reports success for writes that did
		# not land, and a mask that is not there is a guest that hangs
		_have=$("${DEBUGFS}" -R "stat /etc/systemd/system/${_unit}" \
			"${ROOTFS_PART}" 2>/dev/null)
		case "${_have}" in
			*"Type: symlink"*) ;;
			*) _have="" ;;
		esac
		_link=$(printf '%s\n' "${_have}" |
			sed -n 's/.*Fast link dest: "\(.*\)"/\1/p')
		if [ "${_link}" != "/dev/null" ]; then
			fail "${_unit} was not masked in the guest" \
				"debugfs said the link was made, but" \
				"/etc/systemd/system/${_unit} in the copy of the root" \
				"filesystem at ${ROOTFS_PART} is not a link to /dev/null."
		fi
	done

	result "${OK_CHAR}" "the guest will not wait for a console to be answered"
	rootfs_restore
}


#
# ==== Setting the guest password ====
#
# Set the password of a guest account by rewriting /etc/shadow in the image.
# See the note above on why this is done offline rather than by leaving a file
# for the guest to pick up at boot.
set_password () {
	# Nothing to do unless a password was set
	if [ -z "${GUEST_PASSWORD}" ]; then
		return 0
	fi

	rootfs_extract
	_part="${ROOTFS_PART}"
	_shadow="${WORK_DIR}/.shadow"
	trap 'rm -f "${_part}" "${_shadow}" "${_shadow}.new"' 0

	# 1. Note what /etc/shadow looks like, as the file gets replaced whole
	#    and its owner and mode have to be put back afterwards
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

	# 2. Make sure the account is there before going to the trouble of
	#    rewriting anything
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

	# 3. Swap the hash, keeping the rest of the line, and stamp today's day
	#    count so that the password is not read as having been set in 1970
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

	# 4. Read it back: the file is only useful if it is really in there
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

	# 5. Put the partition back where it came from
	rootfs_restore
}
