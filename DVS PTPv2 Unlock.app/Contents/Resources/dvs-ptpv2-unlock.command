#!/bin/bash
#
# DVS PTPv2 Unlock -- one double-click control panel (macOS)
#
# Double-click this file in Finder. It opens a small menu where you can
# activate/deactivate the PTP wrapper and toggle its options
# (PTPv2) without ever touching the Terminal, a compiler, or
# the config file by hand. Privileged steps ask for your password once via
# the standard macOS dialog.
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

DVSDIR="/Library/Application Support/Audinate/DanteVirtualSoundcard"
CONF="$DVSDIR/dvs-ptpv2-unlock.conf"

# --- small helpers -------------------------------------------------------

# Run an AppleScript snippet and return its output.
osa() { osascript -e "$1"; }

# Show a plain informational dialog.
info() {
	osa "display dialog \"$1\" buttons {\"OK\"} default button \"OK\" with title \"DVS PTPv2 Unlock\"" >/dev/null 2>&1 || true
}

# Read a boolean key ("1"/"0") from the config file; default 0 if absent.
conf_get() {
	local key="$1"
	if [ -f "$CONF" ]; then
		local v
		v=$(grep -iE "^[[:space:]]*$key[[:space:]]*=" "$CONF" | tail -1 | cut -d= -f2 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
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
	osascript -e "do shell script \"/bin/bash '$tmp'\" with administrator privileges" >/dev/null
	rc=$?
	rm -f "$tmp"
	return $rc
}

# --- privileged actions (single password prompt each) --------------------

do_activate() {
	ensure_built
	# All privileged steps run in one elevated shell = one password prompt.
	run_admin "set -e
cd \"$DIR\"
if [ ! -f \"$DVSDIR/ptp-original\" ]; then cp \"$DVSDIR/ptp\" \"$DVSDIR/ptp-original\"; fi
cp dvs-ptpv2-unlock \"$DVSDIR/ptp\"
chown root:admin \"$DVSDIR/ptp\"
chmod 755 \"$DVSDIR/ptp\"
if [ ! -f \"$CONF\" ]; then cp dvs-ptpv2-unlock.conf \"$CONF\"; chmod 644 \"$CONF\"; fi
$RESTART_PTP" \
		&& info "PTP wrapper activated and PTP service restarted." \
		|| info "Activation was cancelled or failed."
}

do_deactivate() {
	if ! is_installed; then
		info "Wrapper is not installed -- nothing to deactivate."
		return
	fi
	run_admin "set -e
mv \"$DVSDIR/ptp-original\" \"$DVSDIR/ptp\"
chown root:admin \"$DVSDIR/ptp\"
$RESTART_PTP" \
		&& info "Original ptp restored and PTP service restarted." \
		|| info "Deactivation was cancelled or failed."
}

# Toggle PTPv2 support and write the config file.
edit_options() {
	local cur answer new_ptpv2
	cur=$(conf_get ptpv2)

	answer=$(osa "set b to button returned of (display dialog \"PTPv2 support is currently $(yesno "$cur").\" \
		with title \"DVS PTPv2 Unlock options\" \
		buttons {\"Cancel\", \"Disable\", \"Enable\"} \
		default button \"$( [ "$cur" = "1" ] && echo Disable || echo Enable )\")
		return b") || return

	case "$answer" in
		Enable)  new_ptpv2=1 ;;
		Disable) new_ptpv2=0 ;;
		*)       return ;;			# Cancel
	esac

	# Write the config as root (it lives under /Library), restarting the service
	# only if the wrapper is currently active.
	local restart=""
	is_installed && restart="$RESTART_PTP"
	run_admin "set -e
cat > \"$CONF\" <<'CONFEOF'
# DVS PTPv2 Unlock configuration (written by dvs-ptpv2-unlock.command)
ptpv2 = $new_ptpv2
CONFEOF
chmod 644 \"$CONF\"
$restart" || { info "Saving options was cancelled or failed."; return; }
	if is_installed; then
		info "PTPv2 support $(yesno "$new_ptpv2") and PTP service restarted."
	else
		info "PTPv2 support $(yesno "$new_ptpv2"). It applies once you activate the wrapper."
	fi
}

# Inspect the currently running PTP process to report the EFFECTIVE state --
# what DVS is actually running right now, independent of the config file. Works
# whether or not the wrapper is installed (matches both ptp and ptp-original).
live_status() {
	local proc
	proc=$(ps -axo command= 2>/dev/null | grep 'DanteVirtualSoundcard/ptp' | grep -v grep | head -1)
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
	local state="installed" ; is_installed || state="not installed"
	info "Wrapper: $state\n\nConfigured (desired):\n    PTPv2: $(yesno "$(conf_get ptpv2)")\n\nLive (what DVS runs now):\n    $(live_status)\n\nConfig file: $CONF"
}

# --- main menu loop ------------------------------------------------------

while true; do
	state="not installed"
	is_installed && state="active"
	choice=$(osa "set c to choose from list \
		{\"Activate wrapper\", \"Deactivate wrapper\", \"Edit options (PTPv2)\", \"Show status\", \"Quit\"} \
		with title \"DVS PTPv2 Unlock  (currently: $state)\" \
		with prompt \"What would you like to do?\" \
		default items {\"Show status\"}
		if c is false then return \"Quit\"
		return item 1 of c") || exit 0

	case "$choice" in
		"Activate wrapper")   do_activate ;;
		"Deactivate wrapper") do_deactivate ;;
		"Edit options"*)      edit_options ;;
		"Show status")        show_status ;;
		"Quit"|"")            exit 0 ;;
	esac
done
