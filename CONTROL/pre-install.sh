#!/bin/sh

case "$APKG_PKG_STATUS" in
	install)
		if ! command -v jq >/dev/null 2>&1; then
			opkg update
			opkg install jq
		fi
		;;
	upgrade)
		# Backup current config
		cp -raf $APKG_PKG_DIR/etc $APKG_TEMP_DIR
		;;
	*)
		;;
esac

exit 0
