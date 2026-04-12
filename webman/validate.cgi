#!/bin/sh

# Paths
SRC_BASE="/volume1/.@plugins/AppCentral"

# Function to get size in human readable format
get_size_human() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sh "$dir" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

# Function to get size in KB for sorting/comparison
get_size_kb() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sk "$dir" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

# Function to decode URL encoded strings
url_decode() {
    echo -e "$(echo "$1" | sed 's/+/ /g; s/%\([0-9A-F][0-9A-F]\)/\\x\1/g')"
}

# HTTP Header
echo "Content-type: application/json"
echo ""

# Reading action and target from QUERY_STRING
# We use a simple way to parse parameters without external tools
ACTION_RAW=$(echo "$QUERY_STRING" | grep -oE "(^|&)act=[^&]+" | cut -d'=' -f2)
TARGET_VOL_RAW=$(echo "$QUERY_STRING" | grep -oE "(^|&)target=[^&]+" | cut -d'=' -f2)
APP_PARAM_RAW=$(echo "$QUERY_STRING" | grep -oE "(^|&)app=[^&]+" | cut -d'=' -f2)

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
            \"targetSizeKb\": $TARGET_SIZE_KB
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
