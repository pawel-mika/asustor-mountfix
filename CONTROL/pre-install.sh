#!/bin/sh

ENTWARE_BIN_DIRS="${ENTWARE_BIN_DIRS:-/usr/local/AppCentral/entware/opt/bin:/opt/bin:/opt/sbin}"
export PATH="${PATH}:${ENTWARE_BIN_DIRS}"

ensure_required_tools() {
	missing=""
	for tool in jq bash rsync; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing="${missing:+$missing }$tool"
		fi
	done

	[ -z "$missing" ] && return 0

	if ! command -v opkg >/dev/null 2>&1; then
		echo "Error: missing required tool(s): $missing, and Entware opkg was not found in PATH" >&2
		return 1
	fi

	opkg update || return 1
	for pkg in $missing; do
		opkg install "$pkg" || return 1
	done
	return 0
}

case "$APKG_PKG_STATUS" in
	install)
		ensure_required_tools || exit 1
		;;
	upgrade)
		# Backup current config
		if [ -d "$APKG_PKG_DIR/etc" ]; then
			cp -raf "$APKG_PKG_DIR/etc" "$APKG_TEMP_DIR"
		fi
		;;
	*)
		;;
esac

exit 0
