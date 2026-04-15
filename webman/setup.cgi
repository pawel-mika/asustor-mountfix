#!/bin/sh

# load common functions (like url_decode) - we can source it directly since it's a simple sh script without any side effects
. /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh

# Paths
SRC_BASE="/volume1/.@plugins/AppCentral"
START_STOP="start-stop.sh"






# HTTP Header
echo "Content-type: application/json"
echo ""

# Reading action and target from QUERY_STRING
ACTION_RAW=$(get_query_param "$QUERY_STRING" "act")
TARGET_VOL_RAW=$(get_query_param "$QUERY_STRING" "target")
APP_PARAM_RAW=$(get_query_param "$QUERY_STRING" "app")

ACTION=$(url_decode "$ACTION_RAW")
TARGET_VOL=$(url_decode "$TARGET_VOL_RAW")
APP_PARAM=$(url_decode "$APP_PARAM_RAW")

if [ "$ACTION" = "setup_app" ]; then





    cat <<EOF
{
    "success": true,
    "apps": [$APPS_JSON]
}
EOF
else
    echo '{"success": false, "error": "Invalid action"}'
fi
