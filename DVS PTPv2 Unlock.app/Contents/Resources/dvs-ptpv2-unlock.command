#!/bin/bash
#
# DVS PTPv2 Unlock -- one double-click control panel (macOS)
#
# Double-click this file in Finder. It opens a single dialog that switches PTPv2
# support on or off and shows the current status -- no Terminal, no compiler and
# no editing the config file by hand. The privileged step asks for your password
# once via the standard macOS dialog.
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

DVSDIR="/Library/Application Support/Audinate/DanteVirtualSoundcard"
CONF="$DVSDIR/dvs-ptpv2-unlock.conf"

# --- small helpers -------------------------------------------------------

# Run an AppleScript snippet and return its output.
# stderr is dropped on purpose: cancelling a dialog makes AppleScript fail with
# "User cancelled. (-128)", which is a normal outcome here, not something to
# show the user. Callers decide what to do via the exit status.
osa() { osascript -e "$1" 2>/dev/null; }

# Show a plain informational dialog.
info() {
	osa "display dialog \"$1\" buttons {\"OK\"} default button \"OK\" with title \"DVS PTPv2 Unlock\"" >/dev/null 2>&1 || true
}

# Read a boolean key ("1"/"0") from the config file; default 0 if absent.
conf_get() {
	local key="$1"
	if [ -f "$CONF" ]; then
		local v
		# "|| v=" keeps a missing key harmless: with pipefail a non-matching
		# grep would otherwise fail the assignment and abort under set -e.
		v=$(grep -iE "^[[:space:]]*$key[[:space:]]*=" "$CONF" | tail -1 | cut -d= -f2 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]') || v=""
		case "$v" in 1|y|yes|true|on) echo 1 ;; *) echo 0 ;; esac
	else
		echo 0
	fi
}

is_installed() { [ -f "$DVSDIR/ptp-original" ]; }

# Make sure a dvs-ptpv2-unlock binary is available.
# Prefer a prebuilt binary shipped alongside this script (from the GitHub
# release) so no compiler is needed. Only compile from source as a fallback,
# e.g. when running from a plain "git clone".
ensure_built() {
	if [ -f dvs-ptpv2-unlock ]; then
		return					# prebuilt (or previously built) binary present
	fi
	if [ ! -f dvs-ptpv2-unlock.c ]; then
		info "No dvs-ptpv2-unlock binary and no source to build it from. Please download a release."
		exit 1
	fi
	local cc
	cc=$(command -v cc || command -v clang || command -v gcc || true)
	if [ -z "$cc" ]; then
		info "No prebuilt binary found and no C compiler available.\n\nEither download a release (recommended) or run 'xcode-select --install' and try again."
		exit 1
	fi
	"$cc" -arch arm64 -arch x86_64 -o dvs-ptpv2-unlock dvs-ptpv2-unlock.c 2>/dev/null \
		|| "$cc" -o dvs-ptpv2-unlock dvs-ptpv2-unlock.c		# fall back to native-only if universal build fails
}

# Shell snippet (run as root) that restarts the DVS PTP service so changes take
# effect immediately. DVS supervises the ptp process and respawns it, picking up
# the new binary/config. Best-effort: silent if the process is not running.
RESTART_PTP='pkill -f "DanteVirtualSoundcard/ptp" 2>/dev/null || true'

# Run a shell script (passed as $1) as root behind ONE native password prompt.
#
# The script is written to a temp file and executed via
#   do shell script "/bin/bash '<tmp>'" with administrator privileges
# so the AppleScript string contains only a simple path -- never the script's
# own quotes or numbers. (Embedding the shell text directly inside the
# AppleScript string breaks its quoting and triggers osascript syntax errors.)
# Returns the elevated script's exit status; non-zero if the user cancels.
run_admin() {
	local tmp rc
	tmp="$(mktemp -t dvs-ptpv2-unlock)" || return 1
	printf '%s\n' "$1" > "$tmp"
	# stderr dropped: cancelling the password prompt is a -128 "User cancelled",
	# reported to the caller through the exit status instead.
	osascript -e "do shell script \"/bin/bash '$tmp'\" with administrator privileges" >/dev/null 2>&1
	rc=$?
	rm -f "$tmp"
	return $rc
}

# --- privileged actions (single password prompt each) --------------------

# PTPv2 counts as enabled only when BOTH hold: the wrapper is in place AND the
# config asks for it. These used to be two separate menu entries, which let
# people install the wrapper and still get nothing, because the shipped config
# defaults to off. The single switch below always sets both together.
is_enabled() { is_installed && [ "$(conf_get ptpv2)" = "1" ]; }

do_enable() {
	ensure_built
	# All privileged steps run in one elevated shell = one password prompt.
	run_admin "set -e
cd \"$DIR\"
if [ ! -f \"$DVSDIR/ptp-original\" ]; then cp \"$DVSDIR/ptp\" \"$DVSDIR/ptp-original\"; fi
cp dvs-ptpv2-unlock \"$DVSDIR/ptp\"
chown root:admin \"$DVSDIR/ptp\"
chmod 755 \"$DVSDIR/ptp\"
cat > \"$CONF\" <<'CONFEOF'
# DVS PTPv2 Unlock configuration (written by dvs-ptpv2-unlock.command)
ptpv2 = 1
CONFEOF
chmod 644 \"$CONF\"
$RESTART_PTP" \
		&& info "PTPv2 is now enabled.\n\nThe PTP service was restarted." \
		|| info "Enabling PTPv2 was cancelled or failed."
}

do_disable() {
	if ! is_installed; then
		info "PTPv2 is already disabled -- DVS's original ptp is in place."
		return 0
	fi
	# Restore the original binary and set the config to match, so no state is
	# left behind claiming PTPv2 is wanted.
	run_admin "set -e
mv \"$DVSDIR/ptp-original\" \"$DVSDIR/ptp\"
chown root:admin \"$DVSDIR/ptp\"
cat > \"$CONF\" <<'CONFEOF'
# DVS PTPv2 Unlock configuration (written by dvs-ptpv2-unlock.command)
ptpv2 = 0
CONFEOF
chmod 644 \"$CONF\"
$RESTART_PTP" \
		&& info "PTPv2 is now disabled.\n\nDVS's original ptp was restored and the PTP service restarted." \
		|| info "Disabling PTPv2 was cancelled or failed."
}

# Inspect the currently running PTP process to report the EFFECTIVE state --
# what DVS is actually running right now, independent of the config file. Works
# whether or not the wrapper is installed (matches both ptp and ptp-original).
live_status() {
	local proc
	# "|| proc=" -- no running ptp means grep exits 1, which pipefail would turn
	# into a failed assignment; not running is a normal state, reported below.
	proc=$(ps -axo command= 2>/dev/null | grep 'DanteVirtualSoundcard/ptp' | grep -v grep | head -1) || proc=""
	if [ -z "$proc" ]; then
		echo "PTP service not running"
		return
	fi
	local p="disabled"
	case " $proc " in *" -y2"*) p="enabled" ;; esac	# wrapper appends -y2=-2 for PTPv2
	echo "PTPv2 $p"
}

# Turn a 0/1 config value into a readable word.
yesno() { if [ "$1" = "1" ]; then echo "enabled"; else echo "disabled"; fi; }

show_status() {
	local overall="disabled" inst="no"
	is_enabled && overall="enabled"
	is_installed && inst="yes"
	info "PTPv2: $overall\n\nDetails:\n    Wrapper installed: $inst\n    Config setting: $(yesno "$(conf_get ptpv2)")\n    Running service: $(live_status)\n\nConfig file: $CONF"
}

# --- main dialog ---------------------------------------------------------

while true; do
	if is_enabled; then
		state="enabled" ; action="Disable PTPv2"
	else
		state="disabled" ; action="Enable PTPv2"
	fi

	# "Quit" is also the cancel button, so Escape closes the panel. Clicking it
	# makes AppleScript return -128, which "|| exit 0" treats as a clean exit.
	button=$(osa "set b to button returned of (display dialog \"PTPv2 is currently $state.\" \
		with title \"DVS PTPv2 Unlock\" \
		buttons {\"Quit\", \"Show status\", \"$action\"} \
		default button \"$action\" \
		cancel button \"Quit\")
		return b") || exit 0

	case "$button" in
		"Enable PTPv2")  do_enable ;;
		"Disable PTPv2") do_disable ;;
		"Show status")   show_status ;;
		*)               exit 0 ;;
	esac
done
