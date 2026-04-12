#!/bin/sh

# Check the status
case "$APKG_PKG_STATUS" in
	install)
		#cp -raf $APKG_TEMP_DIR/etc $APKG_PKG_DIR
		;;
	upgrade)
		cp -raf $APKG_TEMP_DIR/etc $APKG_PKG_DIR
		;;
	*)
		;;
esac

exit 0
