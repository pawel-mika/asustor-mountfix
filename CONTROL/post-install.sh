#!/bin/sh

# Check the status
case "$APKG_PKG_STATUS" in
	install)
		;;
	upgrade)
		cp -af "$APKG_TEMP_DIR/etc" "$APKG_PKG_DIR"
		;;
	*)
		;;
esac

# Generate jq-free etc/mounts.list from mountfix.conf so boot/shutdown never depends on jq
if [ -f "$APKG_PKG_DIR/etc/mountfix.conf" ]; then
	if [ -f "$APKG_PKG_DIR/CONTROL/lib.sh" ]; then
		. "$APKG_PKG_DIR/CONTROL/lib.sh"
		generate_mounts_list "$APKG_PKG_DIR/etc/mountfix.conf" "$APKG_PKG_DIR/etc/mounts.list" || true
	elif [ -f "$APKG_PKG_DIR/CONTROL/common.sh" ]; then
		. "$APKG_PKG_DIR/CONTROL/common.sh"
		generate_mounts_list "$APKG_PKG_DIR/etc/mountfix.conf" "$APKG_PKG_DIR/etc/mounts.list" || true
	fi
fi

exit 0
