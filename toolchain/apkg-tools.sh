#!/usr/bin/env bash
# ASUSTOR APK package packager and extractor (pure shell, no Python dependency)
set -e

create_pkg() {
    local APP_DIR=""
    local DEST_DIR=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --destination|-d)
                DEST_DIR="$2"
                shift 2
                ;;
            *)
                if [ -z "$APP_DIR" ]; then
                    APP_DIR="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$APP_DIR" ]; then
        echo "Error: Application directory required." >&2
        echo "Usage: $0 create <app_dir> [--destination <dest_dir>]" >&2
        return 1
    fi

    if [ ! -d "$APP_DIR" ]; then
        echo "Directory does not exist: $APP_DIR" >&2
        return 1
    fi

    APP_DIR="$(cd "$APP_DIR" && pwd)"
    DEST_DIR="${DEST_DIR:-$(pwd)}"
    mkdir -p "$DEST_DIR"
    DEST_DIR="$(cd "$DEST_DIR" && pwd)"

    local CONTROL_DIR="$APP_DIR/CONTROL"
    local CONFIG_FILE="$CONTROL_DIR/config.json"

    if [ ! -d "$CONTROL_DIR" ]; then
        echo "[Not found] CONTROL folder: $CONTROL_DIR" >&2
        return 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[Not found] config file: $CONFIG_FILE" >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required to read $CONFIG_FILE" >&2
        return 1
    fi

    local PKG_NAME PKG_VER PKG_ARCH
    PKG_NAME=$(jq -r '.general.package // empty' "$CONFIG_FILE")
    PKG_VER=$(jq -r '.general.version // empty' "$CONFIG_FILE")
    PKG_ARCH=$(jq -r '.general.architecture // empty' "$CONFIG_FILE")

    if [ -z "$PKG_NAME" ] || [ -z "$PKG_VER" ] || [ -z "$PKG_ARCH" ]; then
        echo "Invalid App config: missing package, version, or architecture in $CONFIG_FILE" >&2
        return 1
    fi

    # Set appropriate permissions in CONTROL
    chmod 755 "$CONTROL_DIR" 2>/dev/null || true
    chmod 644 "$CONTROL_DIR"/* 2>/dev/null || true
    chmod 755 "$CONTROL_DIR"/*.sh 2>/dev/null || true
    if command -v dos2unix >/dev/null 2>&1; then
        dos2unix "$CONTROL_DIR"/*.sh >/dev/null 2>&1 || true
    fi

    local APK_FILENAME="${PKG_NAME}_${PKG_VER}_${PKG_ARCH}.apk"
    local DEST_APK="$DEST_DIR/$APK_FILENAME"

    local PKG_TMP
    PKG_TMP=$(mktemp -d)
    trap 'rm -rf "$PKG_TMP"' RETURN EXIT

    echo "2.0" > "$PKG_TMP/apkg-version"

    # Archive control files
    COPYFILE_DISABLE=1 tar -czf "$PKG_TMP/control.tar.gz" --exclude='.DS_Store' --exclude='._*' -C "$CONTROL_DIR" .

    # Archive data files (everything in app dir excluding CONTROL)
    COPYFILE_DISABLE=1 tar -czf "$PKG_TMP/data.tar.gz" --exclude='./CONTROL' --exclude='CONTROL' --exclude='.DS_Store' --exclude='._*' -C "$APP_DIR" .

    rm -f "$DEST_APK"
    (
        cd "$PKG_TMP" && zip -q "$DEST_APK" apkg-version control.tar.gz data.tar.gz
    )

    echo "Created APK: $DEST_APK"
}

extract_pkg() {
    local APK_FILE=""
    local DEST_DIR=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --destination|-d)
                DEST_DIR="$2"
                shift 2
                ;;
            *)
                if [ -z "$APK_FILE" ]; then
                    APK_FILE="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$APK_FILE" ]; then
        echo "Error: APK file required." >&2
        echo "Usage: $0 extract <apk_file> [--destination <dest_dir>]" >&2
        return 1
    fi

    if [ ! -f "$APK_FILE" ]; then
        echo "File does not exist: $APK_FILE" >&2
        return 1
    fi

    APK_FILE="$(cd "$(dirname "$APK_FILE")" && pwd)/$(basename "$APK_FILE")"
    DEST_DIR="${DEST_DIR:-$(pwd)}"
    mkdir -p "$DEST_DIR"
    DEST_DIR="$(cd "$DEST_DIR" && pwd)"

    local BASE_NAME
    BASE_NAME="$(basename "$APK_FILE" .apk)"
    local OUT_DIR="$DEST_DIR/$BASE_NAME"
    mkdir -p "$OUT_DIR/CONTROL"

    local PKG_TMP
    PKG_TMP=$(mktemp -d)
    trap 'rm -rf "$PKG_TMP"' RETURN EXIT

    unzip -q "$APK_FILE" -d "$PKG_TMP"
    tar -xzf "$PKG_TMP/control.tar.gz" -C "$OUT_DIR/CONTROL"
    tar -xzf "$PKG_TMP/data.tar.gz" -C "$OUT_DIR"

    echo "Extracted to: $OUT_DIR"
}

case "${1:-}" in
    create)
        shift
        create_pkg "$@"
        ;;
    extract)
        shift
        extract_pkg "$@"
        ;;
    *)
        echo "Usage: $0 {create|extract} [arguments...]" >&2
        exit 1
        ;;
esac
