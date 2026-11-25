#!/bin/sh

if [ -n "${MOUNTFIX_WEBMAN_COMMON_SH:-}" ] && [ -f "$MOUNTFIX_WEBMAN_COMMON_SH" ]; then
    . "$MOUNTFIX_WEBMAN_COMMON_SH"
elif [ -f "$(dirname "$0")/scripts/common.sh" ]; then
    . "$(dirname "$0")/scripts/common.sh"
elif [ -f "/usr/local/AppCentral/MountFix/webman/scripts/common.sh" ]; then
    . /usr/local/AppCentral/MountFix/webman/scripts/common.sh
elif [ -f "/volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh" ]; then
    . /volume1/.@plugins/AppCentral/MountFix/webman/scripts/common.sh
fi

require_adm_session

SRC_BASE="$DIR_VOL1/$DIR_PLUGINS/$DIR_APP_CENTRAL"

ACTION_RAW=$(get_query_param "${QUERY_STRING:-}" "act")
TARGET_VOL_RAW=$(get_query_param "${QUERY_STRING:-}" "target")
APP_PARAM_RAW=$(get_query_param "${QUERY_STRING:-}" "app")

ACTION=$(url_decode "$ACTION_RAW")
TARGET_VOL=$(url_decode "$TARGET_VOL_RAW")
APP_PARAM=$(url_decode "$APP_PARAM_RAW")

if [ "$ACTION" = "get" ]; then
    if [ -n "$TARGET_VOL" ] && ! validate_target_volume "$TARGET_VOL"; then
        send_json_error "Invalid target volume"
        exit 0
    fi

    if [ -n "$APP_PARAM" ] && ! validate_app_name "$APP_PARAM"; then
        send_json_error "Invalid app name"
        exit 0
    fi

    if [ ! -d "$SRC_BASE" ]; then
        send_json_error "Source directory $SRC_BASE not found"
        exit 0
    fi

    DU_BIN="${DU_BIN:-du}"
    SRC_DU_CACHE=""
    TGT_DU_CACHE=""

    if [ -n "$APP_PARAM" ]; then
        APP_SINGLE=$(get_app_plugin_path "$APP_PARAM")
        if [ ! -d "$APP_SINGLE" ]; then
            send_json_error "App $APP_PARAM not found"
            exit 0
        fi
        set -- "$APP_SINGLE"
    else
        set -- "$SRC_BASE"/*
        # Batch source and target du -sk into one invocation per volume
        SRC_DU_CACHE=$("$DU_BIN" -sk "$SRC_BASE"/* 2>/dev/null || true)
        if [ -n "$TARGET_VOL" ]; then
            TARGET_BASE="${VOLUME_ROOT:-}$TARGET_VOL/$DIR_APP_CENTRAL"
            if [ -d "$TARGET_BASE" ]; then
                TGT_DU_CACHE=$("$DU_BIN" -sk "$TARGET_BASE"/* 2>/dev/null || true)
            fi
        fi
    fi

    lookup_du_kb() {
        local cache="$1"
        local path="$2"
        printf '%s\n' "$cache" | awk -v p="$path" '
            {
                kb = $1
                sub(/^[0-9]+[[:space:]]+/, "")
                if ($0 == p) {
                    print kb
                    exit
                }
            }
        '
    }

    CONFIGURED_APPS=$(get_configured_apps_for_volume "$TARGET_VOL")
    APPS_JSON=""
    FIRST=1

    for APP_DIR in "$@"; do
        [ -d "$APP_DIR" ] || continue
        APP_NAME=$(basename "$APP_DIR")
        is_protected_app "$APP_NAME" && continue

        if [ -n "$APP_PARAM" ]; then
            SRC_SIZE_KB=$(get_size_kb "$APP_DIR")
        else
            SRC_SIZE_KB=$(lookup_du_kb "$SRC_DU_CACHE" "$APP_DIR")
        fi
        case "$SRC_SIZE_KB" in
            ''|*[!0-9]*) SRC_SIZE_KB=0 ;;
        esac
        SRC_SIZE=$(format_kb_human "$SRC_SIZE_KB")

        TARGET_SIZE="0"
        TARGET_SIZE_KB=0
        EXISTS_IN_TARGET="false"
        MOUNTED="null"

        if [ -n "$TARGET_VOL" ]; then
            TARGET_PATH=$(get_app_data_path "$TARGET_VOL" "$APP_NAME")
            if [ -d "$TARGET_PATH" ]; then
                EXISTS_IN_TARGET="true"
                if [ -n "$APP_PARAM" ]; then
                    TARGET_SIZE_KB=$(get_size_kb "$TARGET_PATH")
                else
                    TARGET_SIZE_KB=$(lookup_du_kb "$TGT_DU_CACHE" "$TARGET_PATH")
                fi
                case "$TARGET_SIZE_KB" in
                    ''|*[!0-9]*) TARGET_SIZE_KB=0 ;;
                esac
                TARGET_SIZE=$(format_kb_human "$TARGET_SIZE_KB")
            fi
            MOUNTED=$(check_app_mount_json "$TARGET_VOL" "$APP_NAME")
        fi

        CONFIGURED="false"
        if printf '%s\n' "$CONFIGURED_APPS" | grep -qxF "$APP_NAME"; then
            CONFIGURED="true"
        fi

        MISMATCH="null"
        if [ "$CONFIGURED" = "true" ] && [ "$MOUNTED" = "null" ]; then
            MISMATCH='"configured_not_mounted"'
        elif [ "$CONFIGURED" = "false" ] && [ "$MOUNTED" != "null" ]; then
            MISMATCH='"mounted_not_configured"'
        fi

        APP_NAME_ESC=$(json_escape "$APP_NAME")
        SRC_SIZE_ESC=$(json_escape "$SRC_SIZE")
        TARGET_SIZE_ESC=$(json_escape "$TARGET_SIZE")

        [ "$FIRST" -eq 0 ] && APPS_JSON="$APPS_JSON,"
        FIRST=0

        APPS_JSON="$APPS_JSON{
            \"name\": \"$APP_NAME_ESC\",
            \"sourceSize\": \"$SRC_SIZE_ESC\",
            \"sourceSizeKb\": $SRC_SIZE_KB,
            \"existsInTarget\": $EXISTS_IN_TARGET,
            \"targetSize\": \"$TARGET_SIZE_ESC\",
            \"targetSizeKb\": $TARGET_SIZE_KB,
            \"mounted\": $MOUNTED,
            \"configured\": $CONFIGURED,
            \"mismatch\": $MISMATCH
        }"
    done

    send_json "{
    \"success\": true,
    \"apps\": [$APPS_JSON]
}"
else
    send_json_error "Invalid action"
fi
