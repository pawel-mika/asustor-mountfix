#!/bin/sh

if [ -n "${MOUNTFIX_LIB_SH:-}" ] && [ -f "$MOUNTFIX_LIB_SH" ]; then
	. "$MOUNTFIX_LIB_SH"
elif [ -f "$(dirname "$0")/lib.sh" ]; then
	. "$(dirname "$0")/lib.sh"
elif [ -f "/usr/local/AppCentral/MountFix/CONTROL/lib.sh" ]; then
	. /usr/local/AppCentral/MountFix/CONTROL/lib.sh
elif [ -f "/volume1/.@plugins/AppCentral/MountFix/CONTROL/lib.sh" ]; then
	. /volume1/.@plugins/AppCentral/MountFix/CONTROL/lib.sh
fi

: "${DIR_VOL1:=/volume1}"
: "${DIR_PLUGINS:=.@plugins}"
: "${DIR_APP_CENTRAL:=AppCentral}"
: "${PROC_MOUNTS:=/proc/mounts}"
ADM_SYSLOG_BIN="${ADM_SYSLOG_BIN:-/usr/sbin/syslog}"

PLUGINS_PREFIX="${DIR_VOL1}/${DIR_PLUGINS}/${DIR_APP_CENTRAL}/"

active_apps=""
if [ -r "$PROC_MOUNTS" ]; then
	active_apps=$(awk -v pfx="$PLUGINS_PREFIX" '
		index($2, pfx) == 1 {
			rest = substr($2, length(pfx) + 1)
			if (rest != "" && index(rest, "/") == 0 && !seen[rest]++) {
				apps = (apps == "" ? rest : apps ", " rest)
			}
		}
		END { if (apps != "") print apps }
	' "$PROC_MOUNTS" 2>/dev/null || true)
fi

if [ -n "$active_apps" ]; then
	msg="Cannot uninstall MountFix while applications are still bind-mounted: ${active_apps}. Stop and unmount them in MountFix first."
	echo "Error: $msg" >&2
	if [ -x "$ADM_SYSLOG_BIN" ]; then
		"$ADM_SYSLOG_BIN" --log 0 --level 1 --user SYSTEM --event "[MountFix] $msg" 2>/dev/null || true
	fi
	exit 1
fi

exit 0
