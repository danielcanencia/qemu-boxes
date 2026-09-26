# shellcheck shell=sh
# shellcheck disable=SC2034  # the presentation details below are used by the sourcing scripts
#
# Output helpers shared by every QEMU box in this repository.
#
# This file is not meant to be executed, only sourced by a box script, which
# reaches it through its own location in the tree:
#
#	. "$(dirname "$0")/../lib/output.sh"
#
# It defines variables and functions only; nothing is printed, downloaded,
# or emulated until the sourcing script calls one of them.
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
