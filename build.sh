#!/bin/bash

set -e # stop on error

if [ "$EUID" -ne 0 ]; then
    echo "Re-running script with sudo..."
    exec sudo "$0" "$@"
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
else
    echo "File not found: $CONFIG_FILE"
fi

OUT_FOLDER="./out"

# 1. Create temp folder
TEMP_FOLDER=$(mktemp -d)
echo "Temp folder crated: $TEMP_FOLDER"

# 2. Copy required
cp -r CONTROL "$TEMP_FOLDER/"
cp -r webman "$TEMP_FOLDER/"

# 2.1. Check & create out folder

if [ ! -d "$OUT_FOLDER" ]; then
    echo "$OUT_FOLDER folder not found. Creating..."
    mkdir -p "$OUT_FOLDER"
fi

# 3. Pack app
./toolchain/apkg-tools_py3.py create "$TEMP_FOLDER/" --destination "$OUT_FOLDER/"

# 4. Remove temp
rm -rf "$TEMP_FOLDER"
echo "Temp folder removed"
