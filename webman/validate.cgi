#!/bin/sh

# load common functions (like url_decode) - we can source it directly since it's a simple sh script without any side effects
. /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh

# Paths
SRC_BASE="/volume1/.@plugins/AppCentral"
DST_FOLDER_NAME="AppCentral"

# HTTP Header
echo "Content-type: application/json"
echo ""

# Reading action and target from QUERY_STRING
# We use a simple way to parse parameters without external tools
ACTION_RAW=$(get_query_param "$QUERY_STRING" "act")
TARGET_VOL_RAW=$(get_query_param "$QUERY_STRING" "target")
APP_PARAM_RAW=$(get_query_param "$QUERY_STRING" "app")

ACTION=$(url_decode "$ACTION_RAW")
TARGET_VOL=$(url_decode "$TARGET_VOL_RAW")
APP_PARAM=$(url_decode "$APP_PARAM_RAW")

if [ "$ACTION" = "get" ]; then
    APPS_JSON=""
    FIRST=1

    # Check if source directory exists
    if [ ! -d "$SRC_BASE" ]; then
        echo "{\"success\": false, \"error\": \"Source directory $SRC_BASE not found\"}"
        exit 0
    fi

    # Determine which apps to process
    if [ -n "$APP_PARAM" ]; then
        # Process single app
        APP_LIST="$SRC_BASE/$APP_PARAM"
        if [ ! -d "$APP_LIST" ]; then
            echo "{\"success\": false, \"error\": \"App $APP_PARAM not found\"}"
            exit 0
        fi
    else
        # Process all apps
        APP_LIST="$SRC_BASE"/*
    fi

    # Iterate through folders
    for APP_DIR in $APP_LIST; do
        [ -d "$APP_DIR" ] || continue
        APP_NAME=$(basename "$APP_DIR")

        SRC_SIZE=$(get_size_human "$APP_DIR")
        SRC_SIZE_KB=$(get_size_kb "$APP_DIR")

        TARGET_SIZE="0"
        TARGET_SIZE_KB=0
        EXISTS_IN_TARGET="false"

        if [ -n "$TARGET_VOL" ]; then
            TARGET_PATH="$TARGET_VOL/AppCentral/$APP_NAME"
            if [ -d "$TARGET_PATH" ]; then
                EXISTS_IN_TARGET="true"
                TARGET_SIZE=$(get_size_human "$TARGET_PATH")
                TARGET_SIZE_KB=$(get_size_kb "$TARGET_PATH")
            fi
        fi

        [ $FIRST -eq 0 ] && APPS_JSON="$APPS_JSON,"
        FIRST=0

        APPS_JSON="$APPS_JSON{
            \"name\": \"$APP_NAME\",
            \"sourceSize\": \"$SRC_SIZE\",
            \"sourceSizeKb\": $SRC_SIZE_KB,
            \"existsInTarget\": $EXISTS_IN_TARGET,
            \"targetSize\": \"$TARGET_SIZE\",
            \"targetSizeKb\": $TARGET_SIZE_KB,
            \"mounted\": \"$MOUNTED\"
        }"
    done

    cat <<EOF
{
    "success": true,
    "apps": [$APPS_JSON]
}
EOF
else
    echo '{"success": false, "error": "Invalid action"}'
fi
