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
echo "Test 1: POSIX sh -n syntax, shebang, and executable mode checks..."
for script in \
    "$REPO_ROOT/CONTROL/lib.sh" \
    "$REPO_ROOT/CONTROL/common.sh" \
    "$REPO_ROOT/CONTROL/start-stop.sh" \
    "$REPO_ROOT/CONTROL/post-install.sh" \
    "$REPO_ROOT/webman/scripts/common.sh"
do
    sh -n "$script" || fail "Syntax check failed for $script"
done

CGI_LIST=(
    "$REPO_ROOT/webman/apps.cgi"
    "$REPO_ROOT/webman/config.cgi"
    "$REPO_ROOT/webman/migrate.cgi"
    "$REPO_ROOT/webman/mount.cgi"
    "$REPO_ROOT/webman/validate.cgi"
)
for cgi in "${CGI_LIST[@]}"; do
    [ -x "$cgi" ] || fail "CGI is not executable (expected 0755): $cgi"
    head_line=$(head -n 1 "$cgi")
    [ "$head_line" = "#!/bin/sh" ] || fail "Expected #!/bin/sh shebang in $cgi, got [$head_line]"
    sh -n "$cgi" || fail "Syntax check failed for $cgi"
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

# ---------------------------------------------------------------------------
# 7. save_mountfix_config strict validation, normalization & backup hygiene (F5)
# ---------------------------------------------------------------------------
echo "Test 7: save_mountfix_config validation, normalization, and backup hygiene..."
SAVE_ENV="$TMP_DIR/save_env"
SAVE_ETC="$SAVE_ENV/etc"
SAVE_VOL1="$SAVE_ENV/vol1"
mkdir -p "$SAVE_ETC" \
    "$SAVE_VOL1/.@plugins/AppCentral/docker-ce" \
    "$SAVE_VOL1/.@plugins/AppCentral/entware" \
    "$SAVE_VOL1/.@plugins/AppCentral/MountFix"

printf '{"targetVolume":"/volume2","selectedApps":[{"name":"entware"}]}\n' > "$SAVE_ETC/mountfix.conf"

(
    export DIR_VOL1="$SAVE_VOL1"
    export MF_CONFIG_DIR="$SAVE_ETC"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/webman/scripts/common.sh"

    for bad_payload in \
        '{invalid json' \
        '["not-an-object"]' \
        '{}' \
        '{"targetVolume":123,"selectedApps":[]}' \
        '{"targetVolume":"/volume2/../etc","selectedApps":[]}' \
        '{"targetVolume":"/volume2","selectedApps":"not-array"}' \
        '{"targetVolume":"/volume2","selectedApps":[{"name":""}]}' \
        '{"targetVolume":"/volume2","selectedApps":[{"name":"MountFix"}]}' \
        '{"targetVolume":"/volume2","selectedApps":[{"name":"../evil"}]}' \
        '{"targetVolume":"/volume2","selectedApps":[{"name":"ghost-app"}]}'
    do
        if save_mountfix_config "$bad_payload" 2>/dev/null; then
            fail "save_mountfix_config unexpectedly accepted payload: $bad_payload"
        fi
    done
)

# Ensure rejected payloads created zero backups and did not modify existing mountfix.conf
if ls "$SAVE_ETC"/mountfix.conf.bak_* >/dev/null 2>&1; then
    fail "Rejected payloads must not create backup files"
fi
[ "$(jq -r '.selectedApps[0].name' "$SAVE_ETC/mountfix.conf")" = "entware" ] || \
    fail "Rejected payloads mutated existing mountfix.conf"

# Accept valid config, strip extra keys, preserve enabled:false only, and sync mounts.list
(
    export DIR_VOL1="$SAVE_VOL1"
    export MF_CONFIG_DIR="$SAVE_ETC"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/webman/scripts/common.sh"

    save_mountfix_config '{"targetVolume":"/volume2","extraTop":"ignored","selectedApps":[{"name":"docker-ce","enabled":true,"extraField":123},{"name":"entware","enabled":false,"junk":"x"}]}' || \
        fail "Valid config rejected by save_mountfix_config"
)

ls "$SAVE_ETC"/mountfix.conf.bak_* >/dev/null 2>&1 || fail "Expected backup after valid save_mountfix_config"
jq -e '. == {"targetVolume":"/volume2","selectedApps":[{"name":"docker-ce"},{"name":"entware","enabled":false}]}' "$SAVE_ETC/mountfix.conf" >/dev/null || \
    fail "Normalized mountfix.conf mismatch: $(cat "$SAVE_ETC/mountfix.conf")"
grep -qxF "/volume2/AppCentral/docker-ce:$SAVE_VOL1/.@plugins/AppCentral/docker-ce" "$SAVE_ETC/mounts.list" || \
    fail "mounts.list mismatch after save_mountfix_config: $(cat "$SAVE_ETC/mounts.list")"

# Empty targetVolume "" clears mounts.list cleanly
(
    export DIR_VOL1="$SAVE_VOL1"
    export MF_CONFIG_DIR="$SAVE_ETC"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/webman/scripts/common.sh"

    save_mountfix_config '{"targetVolume":"","selectedApps":[]}' || \
        fail "Empty targetVolume config rejected by save_mountfix_config"
)
[ -f "$SAVE_ETC/mounts.list" ] && [ ! -s "$SAVE_ETC/mounts.list" ] || \
    fail "Expected empty mounts.list after saving empty targetVolume"

# ---------------------------------------------------------------------------
# 8. ADM session auth, HTTP headers, and unknown act across all 5 CGIs (F5, F7)
# ---------------------------------------------------------------------------
echo "Test 8: ADM session authentication & unified JSON responses across all 5 CGIs..."
CGI_ENV="$TMP_DIR/cgi_env"
CGI_VOL1="$CGI_ENV/vol1"
CGI_VOL_ROOT="$CGI_ENV/volumes"
CGI_ETC="$CGI_ENV/etc"
AUTH_CALL_LOG="$CGI_ENV/auth_calls.log"
MOCK_ADM_AUTH="$CGI_ENV/mock_admin.cgi"

mkdir -p \
    "$CGI_VOL1/.@plugins/AppCentral/MountFix" \
    "$CGI_VOL1/.@plugins/AppCentral/docker-ce" \
    "$CGI_VOL1/.@plugins/AppCentral/entware" \
    "$CGI_VOL_ROOT/volume2/AppCentral/docker-ce" \
    "$CGI_ETC"
printf 'hello-src\n' > "$CGI_VOL1/.@plugins/AppCentral/docker-ce/data.txt"
printf 'hello-tgt\n' > "$CGI_VOL_ROOT/volume2/AppCentral/docker-ce/data.txt"
printf '{"targetVolume":"/volume2","selectedApps":[{"name":"docker-ce"}]}\n' > "$CGI_ETC/mountfix.conf"

cat <<EOF > "$MOCK_ADM_AUTH"
#!/bin/sh
echo "\$QUERY_STRING" >> "$AUTH_CALL_LOG"
printf 'Content-Type: application/json\r\n\r\n'
if [ "\$QUERY_STRING" = "sid=valid_admin_sid-1.0~ok" ]; then
    echo '{ "success": true }'
else
    echo '{ "success": false, "error_code": 5000 }'
fi
EOF
chmod 755 "$MOCK_ADM_AUTH"

run_cgi() {
    local cgi_path="$1"
    local qs="$2"
    local auth_bin="${3:-$MOCK_ADM_AUTH}"
    local stdin_data="${4:-}"

    printf '%s' "$stdin_data" | \
        QUERY_STRING="$qs" \
        ADM_AUTH_CGI="$auth_bin" \
        MOUNTFIX_WEBMAN_COMMON_SH="$REPO_ROOT/webman/scripts/common.sh" \
        MOUNTFIX_LIB_SH="$REPO_ROOT/CONTROL/lib.sh" \
        INSTALLED_APPS_JSON="$INSTALLED_FIXTURE" \
        DIR_VOL1="$CGI_VOL1" \
        VOLUME_ROOT="$CGI_VOL_ROOT" \
        CONFIG_FILE="$CGI_ETC/mountfix.conf" \
        MF_CONFIG_DIR="$CGI_ETC" \
        STATUS_FILE="$CGI_ENV/transfer.status" \
        sh "$cgi_path"
}

assert_cgi_json() {
    local raw="$1"
    local label="$2"
    local header body

    header=$(printf '%s' "$raw" | awk 'BEGIN{RS="\r\n\r\n"} NR==1{print; exit}')
    [ "$header" = "Content-Type: application/json" ] || \
        fail "$label: expected Content-Type: application/json\\r\\n\\r\\n header, got [$header] in [$raw]"

    body=$(printf '%s' "$raw" | awk 'BEGIN{RS="\r\n\r\n"} NR==2{print; exit}')
    [ -n "$body" ] || fail "$label: empty HTTP response body"
    printf '%s\n' "$body" | jq empty >/dev/null 2>&1 || \
        fail "$label: invalid JSON body: [$body]"
    printf '%s\n' "$body"
}

for cgi in "${CGI_LIST[@]}"; do
    cgi_name=$(basename "$cgi")

    # 8a. Missing sid -> rejected before calling ADM_AUTH_CGI
    : > "$AUTH_CALL_LOG"
    raw_missing=$(run_cgi "$cgi" "act=get")
    body_missing=$(assert_cgi_json "$raw_missing" "$cgi_name missing sid")
    [ ! -s "$AUTH_CALL_LOG" ] || fail "$cgi_name called ADM_AUTH_CGI with missing sid"
    jq -e '.success == false and (.error | startswith("Unauthorized"))' >/dev/null <<<"$body_missing" || \
        fail "$cgi_name missing sid unexpected body: $body_missing"

    # 8b. Malformed sid (bad chars / parameter pollution / injected =) -> rejected BEFORE ADM_AUTH_CGI
    for bad_qs in "act=get&sid=bad=hack" "act=get&sid=bad!hack" "act=get&sid=bad;id" "act=get&sid=valid_admin_sid-1.0~ok&sid=second" "sid=bad space&act=get" 'act=get&sid=bad"quote'; do
        : > "$AUTH_CALL_LOG"
        raw_malformed=$(run_cgi "$cgi" "$bad_qs")
        body_malformed=$(assert_cgi_json "$raw_malformed" "$cgi_name malformed sid ($bad_qs)")
        [ ! -s "$AUTH_CALL_LOG" ] || fail "$cgi_name called ADM_AUTH_CGI on malformed sid ($bad_qs)"
        jq -e '.success == false and (.error | startswith("Unauthorized"))' >/dev/null <<<"$body_malformed" || \
            fail "$cgi_name malformed sid unexpected body: $body_malformed"
    done
    # Also verify raw unsplit sid containing '&' if passed via encoded '=' or malformed value is rejected
    : > "$AUTH_CALL_LOG"
    raw_verifier_missing=$(run_cgi "$cgi" "act=get&sid=valid_admin_sid-1.0~ok" "$CGI_ENV/missing_verifier.cgi")
    body_verifier_missing=$(assert_cgi_json "$raw_verifier_missing" "$cgi_name missing verifier")
    jq -e '.success == false and (.error | contains("verifier unavailable"))' >/dev/null <<<"$body_verifier_missing" || \
        fail "$cgi_name missing verifier unexpected body: $body_verifier_missing"

    # 8c. Invalid / non-admin sid -> rejected after verifier returns success:false
    : > "$AUTH_CALL_LOG"
    raw_bad_sid=$(run_cgi "$cgi" "act=get&sid=wrong_sid")
    body_bad_sid=$(assert_cgi_json "$raw_bad_sid" "$cgi_name invalid sid")
    [ -s "$AUTH_CALL_LOG" ] || fail "$cgi_name did not invoke ADM_AUTH_CGI for syntactically valid sid"
    jq -e '.success == false and (.error | contains("invalid or non-admin session"))' >/dev/null <<<"$body_bad_sid" || \
        fail "$cgi_name invalid sid unexpected body: $body_bad_sid"

    # 8d. Valid sid + unknown act=bogus -> valid JSON error with HTTP header
    raw_bogus=$(run_cgi "$cgi" "sid=valid_admin_sid-1.0~ok&act=bogus")
    body_bogus=$(assert_cgi_json "$raw_bogus" "$cgi_name act=bogus")
    jq -e '.success == false and (.error | length > 0)' >/dev/null <<<"$body_bogus" || \
        fail "$cgi_name act=bogus unexpected body: $body_bogus"
done

# ---------------------------------------------------------------------------
# 9. Endpoint-specific contracts with valid ADM session
# ---------------------------------------------------------------------------
echo "Test 9: Endpoint-specific validation & response contracts..."
VALID_SID="sid=valid_admin_sid-1.0~ok"

# 9a. apps.cgi?act=get
APPS_CGI_BODY=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/apps.cgi" "$VALID_SID&act=get")" "apps.cgi get")
jq -e '.success == true and (.apps | length == 2) and ([.apps[].package] | index("MountFix") == null)' >/dev/null <<<"$APPS_CGI_BODY" || \
    fail "apps.cgi?act=get unexpected response: $APPS_CGI_BODY"

# 9b. validate.cgi rejects invalid target, MountFix, and traversal app; succeeds on valid target and omits MountFix
VAL_BAD_TGT=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/validate.cgi" "$VALID_SID&act=get&target=../bad")" "validate.cgi bad target")
jq -e '.success == false and .error == "Invalid target volume"' >/dev/null <<<"$VAL_BAD_TGT" || \
    fail "validate.cgi bad target mismatch: $VAL_BAD_TGT"

VAL_MF=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/validate.cgi" "$VALID_SID&act=get&target=/volume2&app=MountFix")" "validate.cgi app=MountFix")
jq -e '.success == false and .error == "Invalid app name"' >/dev/null <<<"$VAL_MF" || \
    fail "validate.cgi app=MountFix mismatch: $VAL_MF"

VAL_TRAV=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/validate.cgi" "$VALID_SID&act=get&target=/volume2&app=../bad")" "validate.cgi app=../bad")
jq -e '.success == false and .error == "Invalid app name"' >/dev/null <<<"$VAL_TRAV" || \
    fail "validate.cgi app=../bad mismatch: $VAL_TRAV"

VAL_OK=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/validate.cgi" "$VALID_SID&act=get&target=%2Fvolume2")" "validate.cgi valid")
jq -e '
    .success == true and
    ([.apps[].name] == ["docker-ce", "entware"]) and
    ((.apps[] | select(.name == "docker-ce") | .existsInTarget) == true) and
    ((.apps[] | select(.name == "entware") | .existsInTarget) == false)
' >/dev/null <<<"$VAL_OK" || fail "validate.cgi valid response mismatch: $VAL_OK"

# 9c. migrate.cgi propagates outer success:false on start_app_transfer / start_app_sync_back failures
MIG_EXISTS=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/migrate.cgi" "$VALID_SID&act=migrate&target=/volume2&app=docker-ce")" "migrate.cgi target_exists")
jq -e '.success == false and .result.success == false and .result.target_exists == true' >/dev/null <<<"$MIG_EXISTS" || \
    fail "migrate.cgi target_exists propagation mismatch: $MIG_EXISTS"

MIG_BAD_TGT=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/migrate.cgi" "$VALID_SID&act=migrate&target=../bad&app=docker-ce")" "migrate.cgi bad target")
jq -e '.success == false and .result.success == false and .result.error == "Invalid target volume"' >/dev/null <<<"$MIG_BAD_TGT" || \
    fail "migrate.cgi bad target mismatch: $MIG_BAD_TGT"

SYNC_BAD_APP=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/migrate.cgi" "$VALID_SID&act=sync_back&target=/volume2&app=MountFix")" "migrate.cgi sync_back MountFix")
jq -e '.success == false and .result.success == false and .result.error == "Invalid app name"' >/dev/null <<<"$SYNC_BAD_APP" || \
    fail "migrate.cgi sync_back MountFix mismatch: $SYNC_BAD_APP"

MIG_STATUS=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/migrate.cgi" "$VALID_SID&act=status")" "migrate.cgi status")
jq -e '.success == true and .result.status == "idle"' >/dev/null <<<"$MIG_STATUS" || \
    fail "migrate.cgi status mismatch: $MIG_STATUS"

# 9d. mount.cgi rejects invalid app/target with unified JSON response
MNT_BAD=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/mount.cgi" "$VALID_SID&act=mount&target=/volume2&app=MountFix")" "mount.cgi MountFix")
jq -e '.success == false and .error == "Invalid app name"' >/dev/null <<<"$MNT_BAD" || \
    fail "mount.cgi MountFix mismatch: $MNT_BAD"

# 9e. config.cgi?act=get version resolution ("unknown" when config.json missing, never "0.0.0.95") & act=set
CFG_MISSING_VER_RAW=$(
    MF_CONTROL_CONFIG_JSON="$CGI_ENV/nonexistent_control_config.json" \
        run_cgi "$REPO_ROOT/webman/config.cgi" "$VALID_SID&act=get"
)
CFG_MISSING_VER=$(assert_cgi_json "$CFG_MISSING_VER_RAW" "config.cgi missing config.json")
jq -e '.success == true and .version == "unknown" and .config.targetVolume == "/volume2"' >/dev/null <<<"$CFG_MISSING_VER" || \
    fail "config.cgi missing config.json version mismatch: $CFG_MISSING_VER"
if grep -q "0\.0\.0\.95" "$REPO_ROOT/webman/config.cgi"; then
    fail "Stale fallback version 0.0.0.95 still present in webman/config.cgi"
fi

CFG_REAL_VER=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/config.cgi" "$VALID_SID&act=get")" "config.cgi real config.json")
EXPECTED_REPO_VER=$(jq -r '.general.version' "$REPO_ROOT/CONTROL/config.json")
jq -e --arg v "$EXPECTED_REPO_VER" '.success == true and .version == $v' >/dev/null <<<"$CFG_REAL_VER" || \
    fail "config.cgi repo version mismatch: $CFG_REAL_VER"

CFG_SET_BAD=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/config.cgi" "$VALID_SID&act=set" "$MOCK_ADM_AUTH" '{"targetVolume":"/volume2","selectedApps":[{"name":"MountFix"}]}')" "config.cgi set bad")
jq -e '.success == false and .error == "Failed to save config"' >/dev/null <<<"$CFG_SET_BAD" || \
    fail "config.cgi set bad mismatch: $CFG_SET_BAD"

CFG_SET_OK=$(assert_cgi_json "$(run_cgi "$REPO_ROOT/webman/config.cgi" "$VALID_SID&act=set" "$MOCK_ADM_AUTH" '{"targetVolume":"/volume2","selectedApps":[{"name":"entware"}]}')" "config.cgi set ok")
jq -e '.success == true and .msg == "Settings saved"' >/dev/null <<<"$CFG_SET_OK" || \
    fail "config.cgi set ok mismatch: $CFG_SET_OK"

echo "PASS: All shared library, F14 protection, url_decode, JSON helper, and CGI hardening tests passed."
