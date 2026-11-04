#!/usr/bin/env bash
set -e

# Verify required directories
[ -d "CONTROL" ] || { echo "CONTROL missing"; exit 1; }
[ -d "webman" ] || { echo "webman missing"; exit 1; }
[ -d "etc" ] || { echo "etc missing"; exit 1; }

# Verify obsolete files are removed
[ ! -f "webman/setup.cgi" ] || { echo "FAIL: webman/setup.cgi should be removed"; exit 1; }
[ ! -f "webman/progress.cgi" ] || { echo "FAIL: webman/progress.cgi should be removed"; exit 1; }

# Test packaging tool directly (pure shell, no python)
TMP_PKG_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_PKG_DIR"' EXIT

cp -r CONTROL "$TMP_PKG_DIR/"
cp -r webman "$TMP_PKG_DIR/"
cp -r etc "$TMP_PKG_DIR/"
./buildJs.sh "$TMP_PKG_DIR" true

./toolchain/apkg-tools.sh create "$TMP_PKG_DIR/" --destination "$TMP_PKG_DIR/"
ls "$TMP_PKG_DIR"/*.apk >/dev/null 2>&1 || { echo "FAIL: APK package creation failed"; exit 1; }

echo "PASS: End-to-end packaging check passed."
