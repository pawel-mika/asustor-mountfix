#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 1. POSIX sh syntax checks across shared library, CONTROL scripts & webman
# ---------------------------------------------------------------------------
echo "Test 1: POSIX sh -n syntax checks..."
for script in \
    "$REPO_ROOT/CONTROL/lib.sh" \
    "$REPO_ROOT/CONTROL/common.sh" \
    "$REPO_ROOT/CONTROL/start-stop.sh" \
    "$REPO_ROOT/CONTROL/post-install.sh" \
    "$REPO_ROOT/webman/scripts/common.sh"
do
    sh -n "$script" || fail "Syntax check failed for $script"
done

# Ensure dead helpers/constants were removed from webman/scripts/common.sh
if grep -qE 'DIR_MF_PLUGINS|is_ssd\(\)|readonly[[:space:]]+DIR_' "$REPO_ROOT/webman/scripts/common.sh"; then
    fail "Dead DIR_MF_PLUGINS, is_ssd(), or readonly DIR_* still present in webman/scripts/common.sh"
fi

# ---------------------------------------------------------------------------
# 2. Re-sourcing CONTROL/lib.sh and webman/scripts/common.sh twice succeeds
# ---------------------------------------------------------------------------
echo "Test 2: Re-sourcing CONTROL/lib.sh and webman/scripts/common.sh twice without readonly errors..."
sh -c '
    set -e
    . "$1/CONTROL/lib.sh"
    . "$1/CONTROL/lib.sh"
    . "$1/webman/scripts/common.sh"
    . "$1/webman/scripts/common.sh"
' _ "$REPO_ROOT" || fail "Re-sourcing failed"

# ---------------------------------------------------------------------------
# 3. Validators & self-relocation protection (F14)
# ---------------------------------------------------------------------------
echo "Test 3: Validators & MountFix self-relocation protection..."
(
    # shellcheck disable=SC1091
    . "$REPO_ROOT/CONTROL/lib.sh"

    is_protected_app "MountFix" || fail "MountFix must be marked protected"
    ! is_protected_app "docker-ce" || fail "docker-ce must not be marked protected"
    ! is_protected_app "" || fail "empty string must not be marked protected"

    # Valid app names
    for valid_app in "docker-ce" "entware" "php8.3" "Forgejo-http-docker" "g++12" "app_1"; do
        validate_app_name "$valid_app" || fail "Expected valid app name: $valid_app"
    done

    # Invalid / protected app names
    for bad_app in "" "MountFix" "../evil" "a..b" ".." ".hidden" "-flag" "/etc/passwd" "app/sub" "app name" $'docker-ce\n/etc/passwd'; do
        if validate_app_name "$bad_app"; then
            fail "Expected invalid app name to be rejected: [$bad_app]"
        fi
    done

    # Valid target volumes
    for valid_vol in "/volume1" "/volume2" "/volume10"; do
        validate_target_volume "$valid_vol" || fail "Expected valid target volume: $valid_vol"
    done

    # Invalid target volumes
    for bad_vol in "" "/volume" "volume2" "/volume2/sub" "/volume2/../volume1" "/etc/passwd" $'/volume2\n/etc'; do
        if validate_target_volume "$bad_vol"; then
            fail "Expected invalid target volume to be rejected: [$bad_vol]"
        fi
    done

    # validate_mount_pair: production & temp-dir paths
    validate_mount_pair "/volume2/AppCentral/docker-ce" "/volume1/.@plugins/AppCentral/docker-ce" || \
        fail "Valid production mount pair rejected"
    validate_mount_pair "$TMP_DIR/vol2/AppCentral/entware" "$TMP_DIR/vol1/.@plugins/AppCentral/entware" || \
        fail "Valid temp-dir mount pair rejected"

    # validate_mount_pair rejections
    ! validate_mount_pair "" "" || fail "Empty mount pair accepted"
    ! validate_mount_pair "/volume2/AppCentral/MountFix" "/volume1/.@plugins/AppCentral/MountFix" || \
        fail "MountFix mount pair accepted"
    ! validate_mount_pair "/volume2/AppCentral/docker-ce" "/volume1/.@plugins/AppCentral/entware" || \
        fail "Mismatched app mount pair accepted"
    ! validate_mount_pair "/volume2/../volume2/AppCentral/docker-ce" "/volume1/.@plugins/AppCentral/docker-ce" || \
        fail "Traversal src mount pair accepted"
    ! validate_mount_pair "/volume2/AppCentral/docker-ce" "/volume1/.@plugins/../.@plugins/AppCentral/docker-ce" || \
        fail "Traversal tgt mount pair accepted"
    ! validate_mount_pair "/volume2:evil/AppCentral/docker-ce" "/volume1/.@plugins/AppCentral/docker-ce" || \
        fail "Colon in src accepted"
    ! validate_mount_pair "/etc/passwd" "/etc/passwd" || \
        fail "Arbitrary non-AppCentral mount pair accepted"
    ! validate_mount_pair "/volume2/AppCentral/a..b" "/volume1/.@plugins/AppCentral/a..b" || \
        fail "a..b mount pair accepted"

    # Empty targetVolume "" writes empty mounts.list cleanly
    EMPTY_CFG="$TMP_DIR/empty_vol.conf"
    EMPTY_LIST="$TMP_DIR/empty_vol.list"
    printf '{"targetVolume":"","selectedApps":[{"name":"docker-ce"}]}\n' > "$EMPTY_CFG"
    generate_mounts_list "$EMPTY_CFG" "$EMPTY_LIST" || fail "generate_mounts_list should allow empty targetVolume"
    [ -f "$EMPTY_LIST" ] && [ ! -s "$EMPTY_LIST" ] || fail "Expected empty mounts.list for empty targetVolume"

    # Tampered mounts.list lines are filtered by get_mount_configs (without jq)
    TAMPERED_LIST="$TMP_DIR/tampered.list"
    cat <<EOF > "$TAMPERED_LIST"
# comment line
/volume2/AppCentral/docker-ce:/volume1/.@plugins/AppCentral/docker-ce
/volume2/AppCentral/MountFix:/volume1/.@plugins/AppCentral/MountFix
/etc/passwd:/etc/shadow
/volume2/AppCentral/app1:/volume1/.@plugins/AppCentral/app2
/volume2/../volume2/AppCentral/entware:/volume1/.@plugins/AppCentral/entware
EOF
    FILTERED=$(MOUNTS_LIST_FILE="$TAMPERED_LIST" CONFIG_FILE="$TMP_DIR/missing.conf" get_mount_configs)
    [ "$FILTERED" = "/volume2/AppCentral/docker-ce:/volume1/.@plugins/AppCentral/docker-ce" ] || \
        fail "Tampered mounts.list was not properly filtered: [$FILTERED]"
)

# Verify webman helpers also reject MountFix self-relocation
(
    # shellcheck disable=SC1091
    . "$REPO_ROOT/webman/scripts/common.sh"
    for fn in mount_app unmount_app start_app_transfer start_app_sync_back; do
        out=$("$fn" "/volume2" "MountFix" 2>/dev/null || true)
        printf '%s\n' "$out" | grep -q "Invalid app name" || \
            fail "$fn did not reject MountFix: [$out]"
    done
)

# ---------------------------------------------------------------------------
# 4. url_decode (F17): case-insensitive hex, + -> space, literal backslashes
# ---------------------------------------------------------------------------
echo "Test 4: POSIX url_decode..."
(
    # shellcheck disable=SC1091
    . "$REPO_ROOT/webman/scripts/common.sh"

    dec1=$(url_decode '%2Fvolume2%2fApp%2BName%201')
    [ "$dec1" = "/volume2/App+Name 1" ] || fail "url_decode hex/+ mismatch: [$dec1]"

    dec2=$(url_decode 'hello+world%21')
    [ "$dec2" = "hello world!" ] || fail "url_decode plus-to-space mismatch: [$dec2]"

    # Must NOT expand \n, \t, \x41, or eat backslashes like `echo -e` did
    raw_bs='literal\n\t\x41\\path%2Fok'
    expected_bs='literal\n\t\x41\\path/ok'
    dec_bs=$(url_decode "$raw_bs")
    [ "$dec_bs" = "$expected_bs" ] || fail "url_decode corrupted backslashes: expected [$expected_bs], got [$dec_bs]"

    dec_empty=$(url_decode '')
    [ -z "$dec_empty" ] || fail "url_decode empty input should return empty string"
)

# ---------------------------------------------------------------------------
# 5. json_escape: quotes, backslashes, tabs, CR, and multi-line strings
# ---------------------------------------------------------------------------
echo "Test 5: json_escape produces valid JSON (default and POSIXLY_CORRECT=1 awk)..."
for posix_mode in "" "1"; do
    (
        if [ -n "$posix_mode" ]; then
            export POSIXLY_CORRECT=1
        else
            unset POSIXLY_CORRECT || true
        fi
        # shellcheck disable=SC1091
        . "$REPO_ROOT/CONTROL/lib.sh"

        tricky=$(printf 'Mount "Fix" \\ path\twith\ttabs\rand\nsecond "line" \\\\ end')
        escaped=$(json_escape "$tricky")
        json_doc=$(printf '{"msg":"%s"}\n' "$escaped")

        printf '%s\n' "$json_doc" | jq empty || fail "json_escape (POSIXLY_CORRECT=$posix_mode) output produced invalid JSON: $json_doc"

        roundtrip=$(printf '%s\n' "$json_doc" | jq -r '.msg')
        [ "$roundtrip" = "$tricky" ] || fail "json_escape (POSIXLY_CORRECT=$posix_mode) roundtrip mismatch: expected [$tricky], got [$roundtrip]"
    )
done

# ---------------------------------------------------------------------------
# 6. get_installed_apps_json excludes MountFix via INSTALLED_APPS_JSON fixture
# ---------------------------------------------------------------------------
echo "Test 6: get_installed_apps_json filters out MountFix..."
INSTALLED_FIXTURE="$TMP_DIR/installed.json"
cat <<'EOF' > "$INSTALLED_FIXTURE"
{
  "packages": [
    {
      "package": "MountFix",
      "name": "MountFix",
      "enabled": true,
      "icon": "mountfix.png"
    },
    {
      "package": "docker-ce",
      "name": "Docker Engine",
      "enabled": true,
      "icon": "docker.png"
    },
    {
      "package": "entware",
      "name": { "en-US": "Entware", "pl-PL": "Entware PL" },
      "enabled": false,
      "icon": "entware.png"
    }
  ]
}
EOF

APPS_OUT=$(
    # shellcheck disable=SC1091
    . "$REPO_ROOT/webman/scripts/common.sh"
    INSTALLED_APPS_JSON="$INSTALLED_FIXTURE" get_installed_apps_json
)

printf '%s\n' "$APPS_OUT" | jq empty || fail "get_installed_apps_json returned invalid JSON: $APPS_OUT"
PKG_LIST=$(printf '%s\n' "$APPS_OUT" | jq -r '.[].package')
EXPECTED_PKGS=$'docker-ce\nentware'
[ "$PKG_LIST" = "$EXPECTED_PKGS" ] || fail "Expected packages [$EXPECTED_PKGS], got [$PKG_LIST]"

ENTWARE_NAME=$(printf '%s\n' "$APPS_OUT" | jq -r '.[] | select(.package == "entware") | .name')
[ "$ENTWARE_NAME" = "Entware" ] || fail "Localized app name resolution failed: [$ENTWARE_NAME]"

echo "PASS: All shared library, F14 protection, url_decode, and JSON helper tests passed."
