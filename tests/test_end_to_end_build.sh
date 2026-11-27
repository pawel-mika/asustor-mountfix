#!/usr/bin/env bash
set -e

# Verify required directories and license files
[ -d "CONTROL" ] || { echo "CONTROL missing"; exit 1; }
[ -d "webman" ] || { echo "webman missing"; exit 1; }
[ -d "etc" ] || { echo "etc missing"; exit 1; }
[ -f "LICENSE" ] || { echo "LICENSE missing"; exit 1; }
[ -f "THIRD_PARTY_LICENSES.md" ] || { echo "THIRD_PARTY_LICENSES.md missing"; exit 1; }
[ -f "licenses/GPL-2.0.txt" ] || { echo "licenses/GPL-2.0.txt missing"; exit 1; }

# Verify obsolete files are removed
[ ! -f "webman/setup.cgi" ] || { echo "FAIL: webman/setup.cgi should be removed"; exit 1; }
[ ! -f "webman/progress.cgi" ] || { echo "FAIL: webman/progress.cgi should be removed"; exit 1; }
[ ! -f "CONTROL/common.sh" ] || { echo "FAIL: CONTROL/common.sh shim should be removed"; exit 1; }
[ ! -f "toolchain/apkg-tools_py3.py" ] || { echo "FAIL: unused toolchain/apkg-tools_py3.py should be removed"; exit 1; }

command -v zip >/dev/null 2>&1 || { echo "FAIL: 'zip' is required to package APKs (install zip first)"; exit 1; }

# Test packaging tool directly (pure shell, no python)
TMP_PKG_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_PKG_DIR"' EXIT

cp -r CONTROL "$TMP_PKG_DIR/"
rm -f "$TMP_PKG_DIR"/CONTROL/*.old
cp -r webman "$TMP_PKG_DIR/"
cp -r etc "$TMP_PKG_DIR/"
cp LICENSE THIRD_PARTY_LICENSES.md "$TMP_PKG_DIR/"
cp -r licenses "$TMP_PKG_DIR/"
./buildJs.sh "$TMP_PKG_DIR" true

./toolchain/apkg-tools.sh create "$TMP_PKG_DIR/" --destination "$TMP_PKG_DIR/"
APK_PATH=$(ls "$TMP_PKG_DIR"/*.apk 2>/dev/null | head -n 1)
[ -n "$APK_PATH" ] || { echo "FAIL: APK package creation failed"; exit 1; }

# Verify license files are packaged inside data.tar.gz
unzip -p "$APK_PATH" data.tar.gz | tar -tzf - | grep -q "LICENSE" || { echo "FAIL: LICENSE missing from APK"; exit 1; }
unzip -p "$APK_PATH" data.tar.gz | tar -tzf - | grep -q "THIRD_PARTY_LICENSES.md" || { echo "FAIL: THIRD_PARTY_LICENSES.md missing from APK"; exit 1; }
unzip -p "$APK_PATH" data.tar.gz | tar -tzf - | grep -q "licenses/GPL-2.0.txt" || { echo "FAIL: licenses/GPL-2.0.txt missing from APK"; exit 1; }

echo "PASS: End-to-end packaging check passed."
