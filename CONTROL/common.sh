#!/bin/sh
# shortcut: compatibility shim for 1 release, remove in Stage 2 Branch 4 cleanup
if [ -n "${MOUNTFIX_LIB_SH:-}" ] && [ -f "$MOUNTFIX_LIB_SH" ]; then
    . "$MOUNTFIX_LIB_SH"
elif [ -n "${BASH_SOURCE:-}" ] && [ -f "$(dirname "$BASH_SOURCE")/lib.sh" ]; then
    . "$(dirname "$BASH_SOURCE")/lib.sh"
elif [ -f "$(dirname "$0")/lib.sh" ]; then
    . "$(dirname "$0")/lib.sh"
elif [ -f "$(dirname "$0")/../CONTROL/lib.sh" ]; then
    . "$(dirname "$0")/../CONTROL/lib.sh"
elif [ -f "./CONTROL/lib.sh" ]; then
    . "./CONTROL/lib.sh"
elif [ -f "/usr/local/AppCentral/MountFix/CONTROL/lib.sh" ]; then
    . /usr/local/AppCentral/MountFix/CONTROL/lib.sh
elif [ -f "/volume1/.@plugins/AppCentral/MountFix/CONTROL/lib.sh" ]; then
    . /volume1/.@plugins/AppCentral/MountFix/CONTROL/lib.sh
fi
