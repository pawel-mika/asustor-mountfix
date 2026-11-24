#!/bin/bash

source ./buildJs.sh

set -e # stop on error

OUT_FOLDER="${OUT_FOLDER:-./out}"

if [ ! -d "$OUT_FOLDER" ]; then
    mkdir -p "$OUT_FOLDER" 2>/dev/null || {
        if [ "$EUID" -ne 0 ]; then
            echo "Re-running script with sudo for write permissions to $OUT_FOLDER..."
            exec sudo "$0" "$@"
        fi
    }
fi

if [ -d "$OUT_FOLDER" ] && [ ! -w "$OUT_FOLDER" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Re-running script with sudo for write permissions to $OUT_FOLDER..."
        exec sudo "$0" "$@"
    fi
fi

# 0. Update version in CONTROL/config.json

CONFIG_FILE="./CONTROL/config.json"

if [ -f "$CONFIG_FILE" ]; then
    # get actual
    VERSION=$(jq -r '.general.version' "$CONFIG_FILE")

    # get parts of version
    IFS='.' read -r MAJOR MINOR BUILD REVISION <<< "$VERSION"
    REVISION=$((REVISION + 1))

    # build new version
    NEW_VERSION="$MAJOR.$MINOR.$BUILD.$REVISION"
    echo "Bump version: $VERSION -> $NEW_VERSION"

    # write back new version to config
    jq ".general.version = \"$NEW_VERSION\"" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

    # update version in webman/mf_core.js and sync local mountfix.js
    if [ -f "webman/mf_core.js" ]; then
        awk -v ver="$NEW_VERSION" '
            /fieldLabel:[[:space:]]*'\''Version'\''/ && /value:[[:space:]]*'\''[^'\'']*'\''/ {
                sub(/value:[[:space:]]*'\''[^'\'']*'\''/, "value: '\''" ver "'\''")
                print
                next
            }
            /fieldLabel:[[:space:]]*'\''Version'\''/ || /itemId:[[:space:]]*'\''displayVersion'\''/ {
                in_ver=1
                print
                next
            }
            in_ver && /value:[[:space:]]*'\''[^'\'']*'\''/ {
                sub(/value:[[:space:]]*'\''[^'\'']*'\''/, "value: '\''" ver "'\''")
                in_ver=0
            }
            { print }
        ' "webman/mf_core.js" > "webman/mf_core.js.tmp" && mv "webman/mf_core.js.tmp" "webman/mf_core.js"
        build_js . false >/dev/null 2>&1
    fi
else
    echo "File not found: $CONFIG_FILE"
fi

# 1. Create temp folder
TEMP_FOLDER=$(mktemp -d)
trap 'rm -rf "$TEMP_FOLDER"' EXIT
echo "Temp folder created: $TEMP_FOLDER"

# 2. Copy required
cp -r CONTROL "$TEMP_FOLDER/"
rm -f "$TEMP_FOLDER"/CONTROL/*.old
cp -r webman "$TEMP_FOLDER/"
cp -r etc "$TEMP_FOLDER/"

# 2.1. Check & create out folder
if [ ! -d "$OUT_FOLDER" ]; then
    echo "$OUT_FOLDER folder not found. Creating..."
    mkdir -p "$OUT_FOLDER"
fi

# --- 2.2. Concatenate JS files ---
build_js "$TEMP_FOLDER" true

# 3. Pack app (pure shell, zero Python)
if [ -x "./toolchain/apkg-tools.sh" ]; then
    ./toolchain/apkg-tools.sh create "$TEMP_FOLDER/" --destination "$OUT_FOLDER/"
else
    PKG_NAME=$(jq -r '.general.package // empty' "$TEMP_FOLDER/CONTROL/config.json")
    PKG_VER=$(jq -r '.general.version // empty' "$TEMP_FOLDER/CONTROL/config.json")
    PKG_ARCH=$(jq -r '.general.architecture // empty' "$TEMP_FOLDER/CONTROL/config.json")
    APK_FILE="$OUT_FOLDER/${PKG_NAME}_${PKG_VER}_${PKG_ARCH}.apk"

    PKG_TMP=$(mktemp -d)
    echo "2.0" > "$PKG_TMP/apkg-version"
    COPYFILE_DISABLE=1 tar -czf "$PKG_TMP/control.tar.gz" --exclude='.DS_Store' --exclude='._*' -C "$TEMP_FOLDER/CONTROL" .
    COPYFILE_DISABLE=1 tar -czf "$PKG_TMP/data.tar.gz" --exclude='./CONTROL' --exclude='CONTROL' --exclude='.DS_Store' --exclude='._*' -C "$TEMP_FOLDER" .
    (cd "$PKG_TMP" && zip -q "$APK_FILE" apkg-version control.tar.gz data.tar.gz)
    rm -rf "$PKG_TMP"
    echo "Created APK: $APK_FILE"
fi

echo "Temp folder removed"
