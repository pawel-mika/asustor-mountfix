#!/usr/bin/env bash
set -e

# Test 1: Verify etc/mountfix.conf is valid JSON
echo "Testing etc/mountfix.conf syntax..."
jq empty etc/mountfix.conf || { echo "FAIL: etc/mountfix.conf is invalid JSON"; exit 1; }

# Test 2: Source CONTROL/common.sh and test get_mount_configs with both formats
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_CONF="$TMP_DIR/mountfix.conf"

# Format A: UI format without enabled: true
cat <<EOF > "$TEST_CONF"
{
  "targetVolume": "/volume2",
  "selectedApps": [
    {"name": "docker-ce"},
    {"name": "entware"}
  ]
}
EOF

source CONTROL/common.sh

RESULT_A=$(CONFIG_FILE="$TEST_CONF" get_mount_configs)
EXPECTED_A=$'/volume2/AppCentral/docker-ce:/volume1/.@plugins/AppCentral/docker-ce\n/volume2/AppCentral/entware:/volume1/.@plugins/AppCentral/entware'

if [ "$RESULT_A" != "$EXPECTED_A" ]; then
    echo "FAIL: Expected:"
    echo "$EXPECTED_A"
    echo "Got:"
    echo "$RESULT_A"
    exit 1
fi

# Format B: Legacy format with enabled: true / enabled: false
cat <<EOF > "$TEST_CONF"
{
  "targetVolume": "/volume2",
  "selectedApps": [
    {"name": "docker-ce", "enabled": true},
    {"name": "photogallery", "enabled": false}
  ]
}
EOF

RESULT_B=$(CONFIG_FILE="$TEST_CONF" get_mount_configs)
EXPECTED_B='/volume2/AppCentral/docker-ce:/volume1/.@plugins/AppCentral/docker-ce'

if [ "$RESULT_B" != "$EXPECTED_B" ]; then
    echo "FAIL: Legacy format check failed. Got:"
    echo "$RESULT_B"
    exit 1
fi

echo "PASS: Configuration parsing tests passed."

