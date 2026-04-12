#!/bin/sh

case "$APKG_PKG_STATUS" in
	install)
		;;
	upgrade)
		# Backup current config
		cp -raf $APKG_PKG_DIR/etc $APKG_TEMP_DIR
		;;
	*)
		;;
esac

exit 0
