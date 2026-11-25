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
if [ -f "$APKG_PKG_DIR/etc/mountfix.conf" ] && [ -f "$APKG_PKG_DIR/CONTROL/lib.sh" ]; then
	. "$APKG_PKG_DIR/CONTROL/lib.sh"
	generate_mounts_list "$APKG_PKG_DIR/etc/mountfix.conf" "$APKG_PKG_DIR/etc/mounts.list" || true
fi

exit 0
